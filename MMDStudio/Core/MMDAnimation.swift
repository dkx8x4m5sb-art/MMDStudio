import Foundation
import simd

struct MMDBoneAnimation {
    var position: SIMD3<Float> = .zero
    var rotation: simd_quatf = mmdIdentityQuaternion
}

struct MMDSkeletonPose {
    var worldMatrices: [simd_float4x4]
    var palettes: [simd_float4x4]
}

/// Computes skinning matrices for the PMX skeleton.
///
/// Skinning matrices come from a plain topological walk (parent strictly
/// before child), which is the only ordering that is safe for every PMX file.
/// Append/inherit reads the source bone's *local* pose, matching MMD.
///
/// IK is a CCD pass that accumulates Euler angles, clamps them against the
/// PMX link limits and converts the world-space correction through the
/// *parent* rotation. Using the link's own rotation there rotated knees around
/// a tilted axis, which is the sideways leg deformation seen with IK on.
final class MMDSkeleton {

    let boneCount: Int
    private let parentIndices: [Int]
    private let restLocal: [SIMD3<Float>]
    /// Strict topological order: every parent precedes its children.
    private let order: [Int]
    private let orderRank: [Int]
    private let inverseBind: [simd_float4x4]
    let restWorld: [simd_float4x4]
    private let childIndices: [[Int]]
    /// Lazily built subtree lists. Only IK links need them, so building a full
    /// descendant table for a 3000-bone model would waste megabytes of memory.
    private var descendantCache: [Int: [Int]] = [:]

    init(model: PMXModel) {
        boneCount = model.bones.count
        parentIndices = model.bones.map { bone -> Int in
            let parent = bone.parentIndex
            return (parent >= 0 && parent < model.bones.count) ? parent : -1
        }
        var locals = [SIMD3<Float>](repeating: .zero, count: model.bones.count)
        for (index, bone) in model.bones.enumerated() {
            let parent = parentIndices[index]
            if parent >= 0 {
                locals[index] = bone.position - model.bones[parent].position
            } else {
                locals[index] = bone.position
            }
        }
        restLocal = locals

        var topological = [Int]()
        topological.reserveCapacity(model.bones.count)
        var visited = [Bool](repeating: false, count: model.bones.count)
        for bone in model.bones.indices where !visited[bone] {
            var chain = [Int]()
            var cursor = bone
            var guardCount = 0
            while cursor >= 0 && cursor < model.bones.count && !visited[cursor]
                    && guardCount <= model.bones.count {
                chain.append(cursor)
                cursor = parentIndices[cursor]
                guardCount += 1
            }
            while let item = chain.popLast() {
                if !visited[item] {
                    visited[item] = true
                    topological.append(item)
                }
            }
        }

        // Pure topological order. Grouping by PMX deform layer looks closer to
        // MMD on paper, but a child authored on layer 0 with a parent on
        // layer 1 is legal, and hoisting layer 0 broke the parent-before-child
        // guarantee: the child then read an identity world matrix and whole
        // limbs snapped to the origin. Correctness beats the layer nuance.
        order = topological

        var ranks = [Int](repeating: 0, count: model.bones.count)
        for (rank, index) in topological.enumerated() { ranks[index] = rank }
        orderRank = ranks

        var children = [[Int]](repeating: [], count: model.bones.count)
        for (index, parent) in parentIndices.enumerated() where parent >= 0 {
            children[parent].append(index)
        }
        childIndices = children

        var worlds = [simd_float4x4](repeating: matrix_identity_float4x4, count: model.bones.count)
        for index in topological {
            let local = simd_float4x4.translation(locals[index])
            let parent = parentIndices[index]
            worlds[index] = (parent >= 0 ? worlds[parent] : matrix_identity_float4x4) * local
        }
        restWorld = worlds
        inverseBind = worlds.map { simd_inverse($0) }
    }

    // MARK: - Evaluation

    func solve(animations: [Int: MMDBoneAnimation], model: PMXModel,
               ikEnabled: Bool = false) -> MMDSkeletonPose {
        guard boneCount > 0 else {
            return MMDSkeletonPose(worldMatrices: [], palettes: [matrix_identity_float4x4])
        }
        var working = animations
        var worlds = [simd_float4x4](repeating: matrix_identity_float4x4, count: boneCount)
        for index in order {
            update(index, animations: working, model: model, worlds: &worlds)
        }
        if ikEnabled {
            solveIK(animations: &working, model: model, worlds: &worlds)
        }
        var palettes = [simd_float4x4](repeating: matrix_identity_float4x4, count: boneCount)
        for index in 0..<boneCount {
            palettes[index] = worlds[index] * inverseBind[index]
        }
        return MMDSkeletonPose(worldMatrices: worlds, palettes: palettes)
    }

    /// Evaluates a single bone and writes its world matrix. `worlds` must hold
    /// valid parents at the time of the call; every caller walks `order`.
    @inline(__always)
    private func update(_ index: Int, animations: [Int: MMDBoneAnimation],
                        model: PMXModel, worlds: inout [simd_float4x4]) {
        let bone = model.bones[index]
        let animation = animations[index] ?? MMDBoneAnimation()
        var translation = restLocal[index] + animation.position
        var rotation = animation.rotation

        let appendParent = bone.appendParent
        if appendParent >= 0 && appendParent < boneCount && abs(bone.appendRatio) > 0.0001 {
            let ratio = bone.appendRatio
            let append = animations[appendParent] ?? MMDBoneAnimation()
            // Append/inherit is defined on the source bone's *local* pose in
            // MMD. Reading its world delta made the result depend on whether
            // the source happened to be evaluated earlier in the frame, which
            // reshuffled entire chains and detached skirts, collars and hair.
            let extra = quatSlerp(mmdIdentityQuaternion, append.rotation,
                                  max(-1.5, min(1.5, ratio)))
            rotation = quatNormalize(rotation * extra)
            if bone.inheritsTranslation {
                translation += append.position * ratio
            }
        }

        let local = simd_float4x4.translation(translation) * simd_float4x4(quaternion: rotation)
        let parent = parentIndices[index]
        worlds[index] = (parent >= 0 ? worlds[parent] : matrix_identity_float4x4) * local
    }

    /// Re-evaluates `index` plus every descendant, in topological order.
    private func refreshSubtree(_ index: Int, animations: [Int: MMDBoneAnimation],
                               model: PMXModel, worlds: inout [simd_float4x4]) {
        update(index, animations: animations, model: model, worlds: &worlds)
        for descendant in descendants(of: index) {
            update(descendant, animations: animations, model: model, worlds: &worlds)
        }
    }

    private func descendants(of index: Int) -> [Int] {
        if let cached = descendantCache[index] { return cached }
        var result = [Int]()
        var stack = childIndices[index]
        while let item = stack.popLast() {
            result.append(item)
            stack.append(contentsOf: childIndices[item])
        }
        result.sort { orderRank[$0] < orderRank[$1] }
        descendantCache[index] = result
        return result
    }

    // MARK: - IK

    private func solveIK(animations: inout [Int: MMDBoneAnimation], model: PMXModel,
                         worlds: inout [simd_float4x4]) {
        // Hard ceiling so a pathological file (hundreds of IK chains, 255
        // iterations each) cannot stall the render thread.
        var budget = 120_000

        for (ikIndex, bone) in model.bones.enumerated() {
            guard let ik = bone.ik, ik.targetIndex >= 0, ik.targetIndex < boneCount,
                  !ik.links.isEmpty else { continue }
            guard budget > 0 else { break }

            // PMX authors commonly use 40..255 iterations; capping far below
            // that leaves the foot short of its target ("soft knee"). 48 is
            // enough for a two-link leg at the usual 1 rad unit angle, and the
            // evaluation budget below still protects the frame.
            let iterations = max(1, min(48, ik.iterations))
            let stepLimit = max(0.15, min(1.2, ik.angleLimit > 0 ? ik.angleLimit : 1.0))

            // Euler state per link, in degrees. MMD limits are authored as
            // Euler angles, so accumulating quaternions and only clamping at
            // the end would ignore the limits entirely.
            var euler = [SIMD3<Float>]()
            euler.reserveCapacity(ik.links.count)
            for link in ik.links {
                let quaternion = (animations[link.boneIndex] ?? MMDBoneAnimation()).rotation
                euler.append(quatEulerDegrees(quaternion))
            }

            for _ in 0..<iterations {
                let target = worlds[ikIndex].translation
                if simd_distance(target, worlds[ik.targetIndex].translation) < 0.0002 { break }

                for (slot, link) in ik.links.enumerated() {
                    let linkIndex = link.boneIndex
                    guard linkIndex >= 0 && linkIndex < boneCount else { continue }

                    let pivot = worlds[linkIndex].translation
                    let targetPosition = worlds[ikIndex].translation
                    let effector = worlds[ik.targetIndex].translation
                    let current = effector - pivot
                    let desired = targetPosition - pivot
                    let currentLength = simd_length(current)
                    let desiredLength = simd_length(desired)
                    guard currentLength > 0.00001, desiredLength > 0.00001 else { continue }

                    let cosine = max(-1, min(1, simd_dot(current / currentLength,
                                                         desired / desiredLength)))
                    let angle = acosf(cosine)
                    guard angle > 0.00005 else { continue }

                    let cross = simd_cross(current, desired)
                    var axis = simd_length(cross) > 0.000001
                        ? cross / simd_length(cross)
                        : SIMD3<Float>(1, 0, 0)
                    if simd_length(cross) <= 0.000001 {
                        // Fully folded: pick a stable perpendicular so the
                        // chain does not collapse onto itself.
                        let fallback = abs(current.z) < 0.9 ? SIMD3<Float>(0, 0, 1)
                                                           : SIMD3<Float>(1, 0, 0)
                        let alt = simd_cross(current, fallback)
                        if simd_length(alt) > 0.000001 { axis = alt / simd_length(alt) }
                    }

                    let step = min(angle, stepLimit)
                    let worldDelta = simd_quatf(angle: step, axis: axis)

                    // A bone's local rotation lives in its parent's space, so
                    // the world correction has to be conjugated by the parent
                    // rotation — not by the link's own rotation.
                    let parent = parentIndices[linkIndex]
                    let parentRotation = parent >= 0 ? Self.rotation(of: worlds[parent])
                                                     : mmdIdentityQuaternion
                    let localDelta = parentRotation.inverse * worldDelta * parentRotation

                    let currentQuaternion = quatFromEuler(SIMD3<Float>(
                        mmdRadians(euler[slot].x),
                        mmdRadians(euler[slot].y),
                        mmdRadians(euler[slot].z)))
                    var updated = quatNormalize(localDelta * currentQuaternion)
                    var angles = quatEulerDegrees(updated)

                    if link.hasLimit {
                        angles = Self.clamped(angles, lower: link.lowerLimit, upper: link.upperLimit)
                    } else if Self.isKnee(linkIndex, model: model) {
                        // A knee is a hinge. Any Y/Z rotation added by CCD
                        // folds the calf sideways. Without an authored limit
                        // the bend direction is unknown (it depends on the
                        // model's facing), so both sides stay open but the
                        // sideways axes are removed.
                        angles.y = 0
                        angles.z = 0
                        angles.x = max(-165, min(165, angles.x))
                    } else if Self.isAnkle(linkIndex, model: model) {
                        angles.y = max(-25, min(25, angles.y))
                        angles.z = max(-25, min(25, angles.z))
                    } else {
                        angles.x = max(-170, min(170, angles.x))
                        angles.y = max(-170, min(170, angles.y))
                        angles.z = max(-170, min(170, angles.z))
                    }

                    euler[slot] = angles
                    updated = quatFromEuler(SIMD3<Float>(mmdRadians(angles.x),
                                                         mmdRadians(angles.y),
                                                         mmdRadians(angles.z)))
                    var animation = animations[linkIndex] ?? MMDBoneAnimation()
                    animation.rotation = updated
                    animations[linkIndex] = animation
                    refreshSubtree(linkIndex, animations: animations, model: model, worlds: &worlds)

                    budget -= descendants(of: linkIndex).count + 1
                    if budget <= 0 { return }
                }
            }
        }
    }

    private static func clamped(_ degrees: SIMD3<Float>,
                                lower: SIMD3<Float>, upper: SIMD3<Float>) -> SIMD3<Float> {
        let factor: Float = 57.29578
        let low = SIMD3<Float>(min(lower.x, upper.x), min(lower.y, upper.y), min(lower.z, upper.z)) * factor
        let high = SIMD3<Float>(max(lower.x, upper.x), max(lower.y, upper.y), max(lower.z, upper.z)) * factor
        return SIMD3<Float>(min(max(degrees.x, low.x), high.x),
                            min(max(degrees.y, low.y), high.y),
                            min(max(degrees.z, low.z), high.z))
    }

    private static func isKnee(_ index: Int, model: PMXModel) -> Bool {
        guard index >= 0 && index < model.bones.count else { return false }
        let name = (model.bones[index].name + " " + model.bones[index].nameEn).lowercased()
        return name.contains("ひざ") || name.contains("knee")
    }

    private static func isAnkle(_ index: Int, model: PMXModel) -> Bool {
        guard index >= 0 && index < model.bones.count else { return false }
        let name = (model.bones[index].name + " " + model.bones[index].nameEn).lowercased()
        return name.contains("足首") || name.contains("ankle")
    }

    private static func rotation(of matrix: simd_float4x4) -> simd_quatf {
        quatFromRotationMatrix(matrix.rotationMatrix)
    }

    func boneWorldPositions(_ pose: MMDSkeletonPose) -> [SIMD3<Float>] {
        pose.worldMatrices.map { $0.translation }
    }
}

/// Combines UI morph weights and VMD morph tracks.
final class MMDMorphController {

    static func resolvedWeights(model: PMXModel, base: [Float]) -> [Float] {
        guard !model.morphs.isEmpty else { return base }
        var weights = base.count == model.morphs.count ? base : [Float](repeating: 0, count: model.morphs.count)
        // Propagate group morphs a few levels down; PMX groups are normally shallow.
        for _ in 0..<3 {
            var additions = [Float](repeating: 0, count: model.morphs.count)
            for (index, morph) in model.morphs.enumerated() where morph.isGroup && abs(weights[index]) > 0.0001 {
                for item in morph.groupItems {
                    guard item.morphIndex >= 0 && item.morphIndex < additions.count else { continue }
                    additions[item.morphIndex] += weights[index] * item.ratio
                }
            }
            var changed = false
            for index in weights.indices where abs(additions[index]) > 0.00001 {
                weights[index] += additions[index]
                changed = true
            }
            if !changed { break }
        }
        return weights
    }

    static func positions(model: PMXModel, weights: [Float]) -> [SIMD3<Float>] {
        let base = model.vertices.map { $0.position }
        guard !model.morphs.isEmpty, weights.count == model.morphs.count else { return base }
        var result = base
        for (morphIndex, morph) in model.morphs.enumerated() {
            let weight = weights[morphIndex]
            guard morph.isVertex && abs(weight) > 0.00001 else { continue }
            for offset in morph.vertexOffsets {
                guard offset.vertexIndex >= 0 && offset.vertexIndex < result.count else { continue }
                result[offset.vertexIndex] += offset.offset * weight
            }
        }
        return result
    }
}

// MARK: - Humanoid rig mapping

enum MMDHumanoidJoint: String, CaseIterable, Identifiable, Hashable {
    case center
    case lowerBody
    case upperBody
    case upperBody2
    case neck
    case head
    case leftShoulder
    case rightShoulder
    case leftUpperArm
    case rightUpperArm
    case leftForearm
    case rightForearm
    case leftHand
    case rightHand
    case leftThigh
    case rightThigh
    case leftShin
    case rightShin
    case leftFoot
    case rightFoot

    var id: String { rawValue }

    var label: String {
        switch self {
        case .center: return "中心"
        case .lowerBody: return "下半身"
        case .upperBody: return "上半身"
        case .upperBody2: return "上半身2"
        case .neck: return "首"
        case .head: return "头"
        case .leftShoulder: return "左肩"
        case .rightShoulder: return "右肩"
        case .leftUpperArm: return "左腕"
        case .rightUpperArm: return "右腕"
        case .leftForearm: return "左肘"
        case .rightForearm: return "右肘"
        case .leftHand: return "左手"
        case .rightHand: return "右手"
        case .leftThigh: return "左腿"
        case .rightThigh: return "右腿"
        case .leftShin: return "左膝"
        case .rightShin: return "右膝"
        case .leftFoot: return "左足"
        case .rightFoot: return "右足"
        }
    }

    var aliases: [String] {
        switch self {
        case .center:
            return ["センター", "center", "centre", "pelvis", "hips", "hip", "root", "waist", "腰", "中心"]
        case .lowerBody:
            return ["下半身", "lowerbody", "lower_body", "hips", "pelvis", "骨盤", "腰下"]
        case .upperBody:
            return ["上半身", "spine", "chest", "upperbody", "upper_body", "torso", "abdomen", "背", "胸"]
        case .upperBody2:
            return ["上半身2", "upperchest", "upper_chest", "chest2", "spine2", "spine1", "胸2"]
        case .neck:
            return ["首", "neck", "脖子", "颈"]
        case .head:
            return ["頭", "head", "头", "头部"]
        case .leftShoulder:
            return ["左肩", "leftshoulder", "left_shoulder", "clavicle_l", "clavicleleft",
                    "shoulder_l", "shoulderleft", "lclavicle", "l_clavicle", "左锁骨", "左锁"]
        case .rightShoulder:
            return ["右肩", "rightshoulder", "right_shoulder", "clavicle_r", "clavicleright",
                    "shoulder_r", "shoulderright", "rclavicle", "r_clavicle", "右锁骨", "右锁"]
        case .leftUpperArm:
            return ["左腕", "左上臂", "左上腕", "左大臂", "leftupperarm", "left_upper_arm",
                    "upperarm_l", "upperarmleft", "arm_l", "armleft", "leftarm",
                    "lupperarm", "l_upperarm", "larm"]
        case .rightUpperArm:
            return ["右腕", "右上臂", "右上腕", "右大臂", "rightupperarm", "right_upper_arm",
                    "upperarm_r", "upperarmright", "arm_r", "armright", "rightarm",
                    "rupperarm", "r_upperarm", "rarm"]
        case .leftForearm:
            return ["左ひじ", "左肘", "左小臂", "左前臂", "leftforearm", "left_forearm",
                    "forearm_l", "forearmleft", "elbow_l", "elbowleft", "lforearm",
                    "l_forearm", "lowerarmleft", "larmlower"]
        case .rightForearm:
            return ["右ひじ", "右肘", "右小臂", "右前臂", "rightforearm", "right_forearm",
                    "forearm_r", "forearmright", "elbow_r", "elbowright", "rforearm",
                    "r_forearm", "lowerarmright", "rarmlower"]
        case .leftHand:
            return ["左手首", "左手", "左腕关节", "left hand", "left_hand", "hand_l", "handleft",
                    "wrist_l", "wristleft", "lhand", "l_hand"]
        case .rightHand:
            return ["右手首", "右手", "右腕关节", "right hand", "right_hand", "hand_r", "handright",
                    "wrist_r", "wristright", "rhand", "r_hand"]
        case .leftThigh:
            return ["左足", "左大腿", "左腿", "leftthigh", "left_thigh", "thigh_l",
                    "thighleft", "upperleg_l", "upperlegleft", "leg_l", "legleft",
                    "lthigh", "l_thigh", "lleg"]
        case .rightThigh:
            return ["右足", "右大腿", "右腿", "rightthigh", "right_thigh", "thigh_r",
                    "thighright", "upperleg_r", "upperlegright", "leg_r", "legright",
                    "rthigh", "r_thigh", "rleg"]
        case .leftShin:
            return ["左ひざ", "左膝", "左小腿", "leftshin", "left_shin", "shin_l",
                    "shinleft", "knee_l", "kneeleft", "calf_l", "calfleft",
                    "lshin", "lcalf", "l_calf", "lowerlegleft"]
        case .rightShin:
            return ["右ひざ", "右膝", "右小腿", "rightshin", "right_shin", "shin_r",
                    "shinright", "knee_r", "kneeright", "calf_r", "calfright",
                    "rshin", "rcalf", "r_calf", "lowerlegright"]
        case .leftFoot:
            return ["左足首", "左脚", "左足踝", "leftfoot", "left_foot", "foot_l",
                    "footleft", "ankle_l", "ankleleft", "lfoot", "l_foot"]
        case .rightFoot:
            return ["右足首", "右脚", "右足踝", "rightfoot", "right_foot", "foot_r",
                    "footright", "ankle_r", "ankleright", "rfoot", "r_foot"]
        }
    }

    static func matching(trackName: String) -> MMDHumanoidJoint? {
        let key = MMDModelDocument.normalizedBoneName(trackName)
        guard !key.isEmpty else { return nil }
        for joint in allCases {
            if joint.aliases.map(MMDModelDocument.normalizedBoneName).contains(key) {
                return joint
            }
        }
        return nil
    }

    /// Conservative local-Euler limits (degrees). X is the main bend axis for
    /// elbows/knees; the other axes are kept narrow to prevent twist.
    var rotationLimit: (x: (Float, Float), y: (Float, Float), z: (Float, Float)) {
        switch self {
        case .leftForearm, .rightForearm, .leftShin, .rightShin:
            return ((-165, 10), (-40, 40), (-30, 30))
        case .leftThigh, .rightThigh:
            return ((-125, 60), (-50, 50), (-45, 45))
        case .neck:
            return ((-45, 45), (-60, 60), (-35, 35))
        case .head:
            return ((-55, 55), (-70, 70), (-45, 45))
        case .leftShoulder, .rightShoulder:
            return ((-80, 80), (-45, 45), (-80, 80))
        case .leftUpperArm, .rightUpperArm:
            return ((-150, 150), (-90, 90), (-120, 120))
        case .leftHand, .rightHand, .leftFoot, .rightFoot:
            return ((-90, 90), (-60, 60), (-60, 60))
        case .center, .lowerBody, .upperBody, .upperBody2:
            return ((-60, 60), (-60, 60), (-60, 60))
        }
    }

    func constrained(_ degrees: SIMD3<Float>) -> SIMD3<Float> {
        let limit = rotationLimit
        return SIMD3<Float>(
            max(limit.x.0, min(limit.x.1, degrees.x)),
            max(limit.y.0, min(limit.y.1, degrees.y)),
            max(limit.z.0, min(limit.z.1, degrees.z))
        )
    }
}

enum MMDPosePreset: String, CaseIterable, Identifiable {
    case neutral = "自然站姿"
    case aPose = "A-Pose"
    case tPose = "T-Pose"
    case wave = "右手招手"
    case sit = "坐姿"

    var id: String { rawValue }
}

/// Physics modes. Cloth simulation is opt-in because many converted MMD rigs
/// ship broken rigid bodies or duplicate control bones; enabling it on those
/// models is what produced the "flying skirt" reports.
enum MMDPhysicsMode: String, CaseIterable, Identifiable {
    case off
    case secondary
    case rigid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "关闭"
        case .secondary: return "摆动（裙/发）"
        case .rigid: return "PMX 刚体"
        }
    }
}

/// Real-time secondary-motion and PMX rigid-body solver.
///
/// The chain solver drives skirt/ribbon/hair/wing bones with a gravity-driven
/// spring-damper. PMX dynamic rigid bodies (mode 2) are integrated as
/// spheres/boxes with joint springs, floor contact and body-body collision;
/// their motion is fed back into the bound bones. This is a compact Bullet-like
/// approximation, not a bit-exact port of Bullet's constraint solver.
struct MMDPhysicsSettings {
    var mode: MMDPhysicsMode = .secondary
    var gravity: Float = 0.6
    var stiffness: Float = 0.4
    var damping: Float = 0.35
    var wind: Float = 0.15
    var inertia: Float = 0.8
    var collision: Bool = true
    /// Cone limit for a single cloth link, in degrees. The link's own kind
    /// scales this (skirts swing widest), so the visible range is larger.
    var maxAngle: Float = 40
    var substeps: Int = 2

    var enabled: Bool { mode != .off }
}

final class MMDSpringPhysics {

    // MARK: - Skeleton mirror

    /// The solver needs the current world transform of every bone so a cloth
    /// link can hang off its real parent (which may itself be a cloth link).
    /// Rebuilding the whole skeleton each frame is cheap (a topological pass
    /// over ~200 bones) and it is what makes the chain actually follow the
    /// body: the previous version had no parent transform at all and drove
    /// only the root of each chain, so a skirt moved as one rigid plate.
    private var boneCount = 0
    private var parentIndices: [Int] = []
    private var restLocal: [SIMD3<Float>] = []
    private var topoOrder: [Int] = []
    private var childIndices: [[Int]] = []
    private var restWorldPos: [SIMD3<Float>] = []
    private var worldPos: [SIMD3<Float>] = []
    private var worldQuat: [simd_quatf] = []
    private var modelHeight: Float = 20
    private var floorY: Float = 0
    /// Skeleton positions captured right after `evaluate`, i.e. before any
    /// cloth feedback. The drag term reads the delta between two frames of
    /// *these*, so cloth never drives itself.
    private var skeletonPos: [SIMD3<Float>] = []
    private var lastSkeletonPos: [SIMD3<Float>] = []

    private enum ChainKind {
        case skirt, hair, sleeve, wing, ribbon, other

        /// How far the link may swing away from its parent-driven rest
        /// direction, as a multiple of the user's max-angle setting. Cloth and
        /// ribbons get the widest cone; hair is stiffer because long hair that
        /// flips past its rest pose looks broken.
        var angleScale: Float {
            switch self {
            case .skirt: return 2.1
            case .ribbon: return 2.0
            case .wing: return 1.8
            case .sleeve: return 1.6
            case .hair: return 1.45
            case .other: return 1.3
            }
        }

        /// Fraction of gravity the link actually feels. A skirt hem should be
        /// pulled down hard; hair keeps some shape.
        var gravityScale: Float {
            switch self {
            case .skirt: return 1.0
            case .ribbon: return 0.9
            case .sleeve: return 0.85
            case .wing: return 0.7
            case .hair: return 0.6
            case .other: return 0.8
            }
        }
    }

    private struct ClothNode {
        var bone: Int
        var parentBone: Int
        var length: Float
        /// Direction from the parent bone to this bone in model space. Because
        /// PMX bones carry no rest rotation, this is also the bone's rest
        /// world orientation.
        var restDir: SIMD3<Float>
        /// Current world-space direction, unit length.
        var dir: SIMD3<Float>
        /// World-space angular velocity in radians per second.
        var omega: SIMD3<Float>
        var angleScale: Float
        var gravityScale: Float
        /// Rest-shape spring. Lower for the hem so it swings freely.
        var stiffness: Float
        var kind: ChainKind
    }

    private var clothNodes: [ClothNode] = []

    // MARK: - Colliders

    private struct Capsule {
        var boneA: Int
        var boneB: Int
        var radius: Float
    }

    private var capsules: [Capsule] = []

    // MARK: - Rigid bodies

    private struct RigidState {
        var body: PMXRigidBody
        var position: SIMD3<Float>
        var restPosition: SIMD3<Float>
        var rotation: simd_quatf
        var restRotation: simd_quatf
        var velocity: SIMD3<Float> = .zero
        var angularVelocity: SIMD3<Float> = .zero
    }

    private struct JointLink {
        var bodyA: Int
        var bodyB: Int
        var offset: SIMD3<Float>
        var springPosition: SIMD3<Float>
        var springRotation: SIMD3<Float>
    }

    private var rigidStates: [RigidState] = []
    private var rigidStateByBody: [Int: Int] = [:]
    private var joints: [JointLink] = []
    private var rigidBoneIndices: Set<Int> = []
    private var ikBones: Set<Int> = []

    private var lastTime: CFTimeInterval = 0
    private var stepAccumulator: Float = 0

    private(set) var solvedRigidBodyCount = 0
    private(set) var solvedJointCount = 0
    /// Number of bones the spring/chain solver drives. Surfaced in the
    /// inspector so "physics does nothing" can be told apart from "this model
    /// has no cloth bones".
    private(set) var drivenBoneCount = 0
    /// Bones the spring chains actually steer. Shown in the inspector.
    var clothBoneCount: Int { clothNodes.count }

    // MARK: - Keywords

    private static let clothKeywords = [
        "髪", "hair", "skirt", "スカート", "ribbon", "リボン", "tail", "尾",
        "cape", "マント", "袖", "sleeve", "breast", "胸", "wing", "羽", "翼",
        "feather", "羽根", "plume", "frill", "フリル", "cloth", "裾", "垂",
        "发饰", "髪飾", "headdress", "dress", "ドレス", "apron", "エプロン",
        "belt", "ベルト", "scarf", "マフラー", "ネクタイ", "necktie",
        // Chinese-authored rigs (王者/原神国服提取) name bones in pinyin or
        // Chinese rather than Japanese, which the old table never matched.
        "裙", "衣摆", "飘带", "披风", "头发", "刘海", "马尾", "辫", "发梢",
        "围巾", "腰带", "领带", "下摆", "纱", "穗", "毛", "尾巴"
    ]

    private static let humanoidMarkers = [
        "センター", "center", "上半身", "下半身", "upperbody", "upper body",
        "lowerbody", "lower body", "spine", "chest", "torso", "hip", "hips",
        "pelvis", "waist", "腰", "体幹", "root", "頭", "head",
        "首", "neck", "肩", "shoulder", "腕", "arm", "ひじ", "elbow",
        "手首", "wrist", "hand", "指", "finger", "thumb", "足", "leg",
        "脚", "もも", "thigh", "ひざ", "knee", "calf", "shin", "すね",
        "足首", "ankle", "かかと", "heel", "foot", "toe", "つま先"
    ]

    // MARK: - Lifecycle

    func reset() {
        for index in clothNodes.indices {
            clothNodes[index].dir = clothNodes[index].restDir
            clothNodes[index].omega = .zero
        }
        lastTime = 0
        stepAccumulator = 0
        for index in rigidStates.indices {
            rigidStates[index].position = rigidStates[index].restPosition
            rigidStates[index].rotation = rigidStates[index].restRotation
            rigidStates[index].velocity = .zero
            rigidStates[index].angularVelocity = .zero
        }
    }

    func prepare(model: PMXModel) {
        boneCount = model.bones.count
        modelHeight = max(0.5, model.bounds.height)
        floorY = model.bounds.minPoint.y

        parentIndices = model.bones.enumerated().map { index, bone in
            let parent = bone.parentIndex
            if parent < 0 || parent >= model.bones.count || parent == index { return -1 }
            return parent
        }
        restLocal = model.bones.map { $0.position }
        restWorldPos = [SIMD3<Float>](repeating: .zero, count: boneCount)
        worldPos = [SIMD3<Float>](repeating: .zero, count: boneCount)
        worldQuat = [simd_quatf](repeating: mmdIdentityQuaternion, count: boneCount)

        // Children lists + a parent-before-child order. A malformed file can
        // contain a parent cycle; anything unreachable is appended afterwards
        // so the arrays stay fully populated instead of trapping.
        childIndices = [[Int]](repeating: [], count: boneCount)
        var roots: [Int] = []
        for index in 0..<boneCount {
            let parent = parentIndices[index]
            if parent >= 0 { childIndices[parent].append(index) } else { roots.append(index) }
        }
        topoOrder = []
        topoOrder.reserveCapacity(boneCount)
        var stack = Array(roots.reversed())
        var visited = [Bool](repeating: false, count: boneCount)
        while let index = stack.popLast() {
            if visited[index] { continue }
            visited[index] = true
            topoOrder.append(index)
            for child in childIndices[index].reversed() where !visited[child] {
                stack.append(child)
            }
        }
        if topoOrder.count < boneCount {
            for index in 0..<boneCount where !visited[index] {
                topoOrder.append(index)
            }
        }

        for index in topoOrder {
            let parent = parentIndices[index]
            restWorldPos[index] = (parent >= 0 ? restWorldPos[parent] : .zero) + restLocal[index]
        }
        skeletonPos = restWorldPos
        lastSkeletonPos = restWorldPos

        ikBones.removeAll()
        for (index, bone) in model.bones.enumerated() {
            guard let ik = bone.ik, ik.targetIndex >= 0 else { continue }
            ikBones.insert(index)
            if ik.targetIndex < boneCount { ikBones.insert(ik.targetIndex) }
            for link in ik.links where link.boneIndex >= 0 && link.boneIndex < boneCount {
                ikBones.insert(link.boneIndex)
            }
        }

        buildClothNodes(model: model)
        buildColliders(model: model)
        buildRigidBodies(model: model)
        reset()
    }

    // MARK: - Cloth graph

    private func buildClothNodes(model: PMXModel) {
        clothNodes.removeAll()

        var secondary = Set<Int>()
        for (index, bone) in model.bones.enumerated() {
            let lower = (bone.name + " " + bone.nameEn).lowercased()
            guard Self.clothKeywords.contains(where: { lower.contains($0) }) else { continue }
            // Control/helper bones (Ctr_/Skn_/dummy) are already posed by the
            // VMD. Rotating them again folds cloth onto itself.
            if lower.contains("ctr_") || lower.contains("skn_") || lower.contains("dummy") { continue }
            if ikBones.contains(index) || Self.isHumanoidDeformBone(bone) { continue }
            secondary.insert(index)
        }
        // Some rigs only name the chain root ("skirt_master") and leave the
        // child bones generic. Include a bone when one of its ancestors is a
        // known secondary root.
        for index in 0..<boneCount where !secondary.contains(index) {
            guard !ikBones.contains(index), !Self.isHumanoidDeformBone(model.bones[index]) else { continue }
            var cursor = parentIndices[index]
            var guardCount = 0
            while cursor >= 0 && guardCount < 8 {
                if secondary.contains(cursor) { secondary.insert(index); break }
                cursor = parentIndices[cursor]
                guardCount += 1
            }
        }
        guard !secondary.isEmpty else {
            drivenBoneCount = 0
            return
        }

        var chainRoots: [Int] = []
        for index in secondary.sorted() {
            let parent = parentIndices[index]
            if parent >= 0 && secondary.contains(parent) { continue }
            chainRoots.append(index)
        }

        // Breadth-first so a link is always created after its parent, which
        // lets `step` walk the array once and still see updated parents.
        var queue: [Int] = chainRoots
        var cursor = 0
        var depthOf = [Int: Int]()
        for root in chainRoots { depthOf[root] = 0 }
        while cursor < queue.count {
            let bone = queue[cursor]
            cursor += 1
            let parent = parentIndices[bone]
            let depth = depthOf[bone] ?? 0
            var direction = SIMD3<Float>(0, -1, 0)
            var length: Float = modelHeight * 0.04
            if parent >= 0 {
                let delta = restWorldPos[bone] - restWorldPos[parent]
                let magnitude = simd_length(delta)
                if magnitude > 0.0001 {
                    direction = delta / magnitude
                    length = magnitude
                }
            }
            let lower = (model.bones[bone].name + " " + model.bones[bone].nameEn).lowercased()
            let kind = Self.chainKind(lower)
            // The hem must swing freely, the root has to hold its shape.
            let taper = powf(0.80, Float(depth))
            clothNodes.append(ClothNode(bone: bone,
                                        parentBone: parent,
                                        length: max(0.002, length),
                                        restDir: direction,
                                        dir: direction,
                                        omega: .zero,
                                        angleScale: kind.angleScale * (1 + Float(depth) * 0.12),
                                        gravityScale: kind.gravityScale,
                                        stiffness: max(0.12, taper),
                                        kind: kind))
            for child in childIndices[bone] where secondary.contains(child) && depth < 12 {
                if depthOf[child] == nil {
                    depthOf[child] = depth + 1
                    queue.append(child)
                }
            }
        }
        drivenBoneCount = clothNodes.count
    }

    private static func chainKind(_ lower: String) -> ChainKind {
        if lower.contains("skirt") || lower.contains("スカート") || lower.contains("裾")
            || lower.contains("裙") || lower.contains("下摆") || lower.contains("衣摆") {
            return .skirt
        }
        if lower.contains("ribbon") || lower.contains("リボン") || lower.contains("尾")
            || lower.contains("飘带") || lower.contains("belt") || lower.contains("ベルト")
            || lower.contains("necktie") || lower.contains("ネクタイ") || lower.contains("领带") {
            return .ribbon
        }
        if lower.contains("wing") || lower.contains("羽") || lower.contains("翼") { return .wing }
        if lower.contains("sleeve") || lower.contains("袖") { return .sleeve }
        if lower.contains("hair") || lower.contains("髪") || lower.contains("头发")
            || lower.contains("刘海") || lower.contains("马尾") || lower.contains("辫") {
            return .hair
        }
        return .other
    }

    // MARK: - Colliders

    private func buildColliders(model: PMXModel) {
        capsules.removeAll()
        let height = modelHeight
        func first(_ keys: [String], side: Int = 0) -> Int {
            for (index, bone) in model.bones.enumerated() {
                let lower = (bone.name + " " + bone.nameEn).lowercased()
                guard keys.contains(where: { lower.contains($0) }) else { continue }
                if side != 0 {
                    let sign = Self.sideSign(lower)
                    if sign != side { continue }
                }
                return index
            }
            return -1
        }

        let hips = first(["下半身", "lowerbody", "lower body", "hips", "hip", "pelvis", "腰"])
        let chest = first(["上半身2", "upperbody2", "upper body2", "chest", "胸", "上半身", "upperbody", "spine"])
        // Both endpoints have to resolve. A capsule anchored at the link's own
        // root would push the whole skirt outward instead of stopping clipping.
        if hips >= 0 && chest >= 0 {
            capsules.append(Capsule(boneA: hips, boneB: chest, radius: height * 0.075))
        }
        for side in [-1, 1] {
            let thigh = first(["もも", "thigh", "upleg", "upperleg", "大腿"], side: side)
            let knee = first(["ひざ", "knee", "shin", "calf", "すね", "小腿"], side: side)
            let ankle = first(["足首", "ankle", "foot", "足"], side: side)
            if thigh >= 0 && knee >= 0 {
                capsules.append(Capsule(boneA: thigh, boneB: knee, radius: height * 0.042))
            }
            if knee >= 0 && ankle >= 0 {
                capsules.append(Capsule(boneA: knee, boneB: ankle, radius: height * 0.035))
            }
        }
    }

    private static func sideSign(_ lower: String) -> Int {
        let left = lower.contains("左") || lower.contains("left") || lower.contains("_l")
            || lower.hasPrefix("l_") || lower.contains(" l ") || lower.hasSuffix(" l")
            || lower.contains(".l")
        if left { return -1 }
        let right = lower.contains("右") || lower.contains("right") || lower.contains("_r")
            || lower.hasPrefix("r_") || lower.contains(" r ") || lower.hasSuffix(" r")
            || lower.contains(".r")
        if right { return 1 }
        return 0
    }

    // MARK: - Rigid bodies

    private func buildRigidBodies(model: PMXModel) {
        rigidStates.removeAll()
        rigidStateByBody.removeAll()
        joints.removeAll()
        rigidBoneIndices.removeAll()

        for (bodyIndex, body) in model.rigidBodies.enumerated() where body.mode >= 2 && body.boneIndex >= 0 {
            guard body.boneIndex < boneCount else { continue }
            let restRotation = quatFromEuler(SIMD3<Float>(mmdRadians(body.rotation.x),
                                                          mmdRadians(body.rotation.y),
                                                          mmdRadians(body.rotation.z)))
            rigidStateByBody[bodyIndex] = rigidStates.count
            rigidStates.append(RigidState(body: body, position: body.position,
                                          restPosition: body.position,
                                          rotation: restRotation,
                                          restRotation: restRotation))
            rigidBoneIndices.insert(body.boneIndex)
        }
        for joint in model.joints {
            guard joint.bodyA >= 0, joint.bodyB >= 0,
                  joint.bodyA < model.rigidBodies.count,
                  joint.bodyB < model.rigidBodies.count else { continue }
            let a = model.rigidBodies[joint.bodyA].position
            let b = model.rigidBodies[joint.bodyB].position
            joints.append(JointLink(bodyA: joint.bodyA, bodyB: joint.bodyB,
                                    offset: a - b,
                                    springPosition: joint.springPosition,
                                    springRotation: joint.springRotation))
        }
        solvedRigidBodyCount = rigidStates.count
        solvedJointCount = joints.count
    }

    // MARK: - Frame

    func apply(animations: [Int: MMDBoneAnimation], model: PMXModel,
               settings: MMDPhysicsSettings, time: CFTimeInterval,
               forcedStep: Float? = nil,
               driveRotation: simd_quatf? = nil) -> [Int: MMDBoneAnimation] {
        guard settings.mode != .off else { return animations }
        guard boneCount > 0 else { return animations }
        if time < lastTime { reset() }

        // `advance == false` means the renderer asked for the same instant
        // again: a 120 Hz redraw of a paused frame, or a second draw pass.
        // The pose still has to be emitted, otherwise the cloth snaps back to
        // its rest shape on every repaint and "physics does nothing" again.
        var advance = false
        var dt: Float = 0
        if let forcedStep {
            advance = true
            dt = max(0.001, min(0.05, forcedStep))
        } else if lastTime > 0 && time > lastTime + 0.00001 {
            advance = true
            dt = Float(min(0.05, max(0.001, time - lastTime)))
        }
        lastTime = max(lastTime, time)

        let fixedStep: Float = 1.0 / 60.0
        var stepLength: Float = 0
        if advance {
            if forcedStep != nil {
                stepLength = dt
            } else {
                // Fixed-step accumulator: preview frame times vary with the
                // display refresh, which made the springs jitter while the
                // fixed-rate video export stayed smooth. At least one step is
                // taken so a fast display cannot stall the solver.
                stepAccumulator += dt
                let stepCount = min(4, max(1, Int(stepAccumulator / fixedStep)))
                stepAccumulator = max(0, stepAccumulator - Float(stepCount) * fixedStep)
                stepLength = fixedStep * Float(stepCount)
            }
        }

        evaluate(animations: animations)
        lastSkeletonPos = skeletonPos
        skeletonPos = worldPos

        var result = animations
        // "PMX 刚体" on a model whose rigid-body section is empty (very common
        // for game-ripped characters) used to do nothing at all. Fall back to
        // the spring chains so the switch is never a no-op.
        let useCloth = settings.mode == .secondary
            || (settings.mode == .rigid && rigidStates.isEmpty)
        if useCloth && !clothNodes.isEmpty {
            stepCloth(settings: settings, dt: stepLength, time: Float(time))
            for node in clothNodes {
                let bone = node.bone
                let parent = node.parentBone
                let parentQuat = parent >= 0 ? worldQuat[parent] : mmdIdentityQuaternion
                let local = parentQuat.inverse * worldQuat[bone]
                var animation = result[bone] ?? MMDBoneAnimation()
                // A VMD clip or a hand-posed bone may carry a deliberate twist.
                // Keep it when it is substantial; otherwise physics owns the
                // bone outright. Multiplying blindly would rotate the solved
                // direction by the authored amount and bend the chain.
                let authoredAngle = 2 * acosf(min(1, abs(animation.rotation.real)))
                animation.rotation = authoredAngle > mmdRadians(15)
                    ? local * animation.rotation
                    : local
                result[bone] = animation
            }
        }

        if settings.mode == .rigid && !rigidStates.isEmpty {
            if advance { stepRigidBodies(model: model, settings: settings, dt: dt) }
            applyRigidBodies(to: &result, model: model, settings: settings)
        }
        return result
    }

    private func evaluate(animations: [Int: MMDBoneAnimation]) {
        for index in topoOrder {
            let parent = parentIndices[index]
            let animation = animations[index] ?? MMDBoneAnimation()
            let parentPos = parent >= 0 ? worldPos[parent] : .zero
            let parentQuat = parent >= 0 ? worldQuat[parent] : mmdIdentityQuaternion
            worldPos[index] = parentPos + parentQuat.act(restLocal[index] + animation.position)
            worldQuat[index] = parentQuat * animation.rotation
        }
    }

    // MARK: - Cloth integration

    private func stepCloth(settings: MMDPhysicsSettings, dt: Float, time: Float) {
        // dt == 0 means "emit the current pose without integrating". The
        // renderer asks for the same instant again whenever a frame is redrawn
        // (paused playback, a second draw pass), and re-emitting is the only
        // way the cloth does not snap back to its rest shape.
        let advance = dt > 0.00001
        let substeps = advance ? max(1, min(4, settings.substeps)) : 1
        let h = advance ? max(0.0005, min(0.02, dt / Float(substeps))) : 0
        let gravity = max(0, settings.gravity)
        let stiffness = max(0.02, settings.stiffness)
        let damping = max(0.05, settings.damping)
        let wind = max(0, settings.wind)
        let inertia = max(0, settings.inertia)
        let down = SIMD3<Float>(0, -1, 0)
        let windDir = SIMD3<Float>(
            sinf(time * 1.7) * 0.7 + sinf(time * 0.43) * 0.3,
            sinf(time * 0.9) * 0.15,
            cosf(time * 1.31) * 0.7 + cosf(time * 0.37) * 0.3
        ).unit

        for _ in 0..<substeps {
            for index in clothNodes.indices {
                var node = clothNodes[index]
                let parent = node.parentBone
                let anchor = parent >= 0 ? worldPos[parent] : .zero
                let anchorQuat = parent >= 0 ? worldQuat[parent] : mmdIdentityQuaternion
                // Where the bone would point if it were welded to its parent.
                // Gravity and the rest spring both act relative to this, so a
                // skirt still hangs correctly after the body turns.
                let restDirNow = anchorQuat.act(node.restDir).unit
                guard restDirNow != .zero else { continue }

                if advance {
                    // Gravity torque. `cross(dir, down)` is the lever arm: zero
                    // when the bone already hangs straight down, maximal when it
                    // is horizontal, which is how a pendulum behaves.
                    let gravityGain = 26 * gravity * node.gravityScale
                    var torque = simd_cross(node.dir, down) * gravityGain

                    if wind > 0.001 && windDir != .zero {
                        torque += simd_cross(node.dir, windDir) * (22 * wind * node.gravityScale)
                    }

                    // Shape memory. Without it a sleeve never returns to its
                    // authored silhouette; too much and the cloth reads as
                    // cardboard, which is the exact complaint this replaces.
                    let restGain = 30 * stiffness * node.stiffness * node.angleScale
                    torque += simd_cross(node.dir, restDirNow) * restGain

                    // Damping is normalised against the spring so the solver
                    // stays stable at any stiffness. 0.62 keeps a little
                    // overshoot, which is what sells cloth as cloth.
                    let omega0 = sqrtf(max(0.001, gravityGain + restGain))
                    let dampingFactor = 2 * omega0 * (0.18 + damping * 0.62) * node.stiffness
                    torque -= node.omega * dampingFactor

                    // Body drag: the anchor's velocity pushes the link, which is
                    // what makes a skirt trail when the character walks.
                    if inertia > 0.001, parent >= 0,
                       parent < skeletonPos.count, parent < lastSkeletonPos.count {
                        // Velocity of the *skeleton* anchor, not of the cloth
                        // link, otherwise a skirt would feed its own swing back
                        // in and slowly build up an oscillation.
                        let anchorVelocity = skeletonPos[parent] - lastSkeletonPos[parent]
                        if simd_length(anchorVelocity) > 1e-6 {
                            torque += simd_cross(node.dir, -anchorVelocity) * (inertia * 6)
                        }
                    }

                    node.omega += torque * h
                    let speed = simd_length(node.omega)
                    if speed > 45 { node.omega *= 45 / speed }

                    if speed > 1e-5 {
                        let rotation = simd_quatf(angle: speed * h, axis: node.omega / speed)
                        node.dir = rotation.act(node.dir).unit
                    }
                    if node.dir == .zero { node.dir = restDirNow }

                    // Cone limit against the parent-driven rest direction.
                    let limit = max(0.03, mmdRadians(settings.maxAngle) * node.angleScale)
                    let deviation = acosf(max(-1, min(1, simd_dot(node.dir, restDirNow))))
                    if deviation > limit {
                        let axis = simd_cross(restDirNow, node.dir)
                        if simd_length(axis) > 1e-5 {
                            node.dir = simd_quatf(angle: limit, axis: axis.unit).act(restDirNow).unit
                        } else {
                            node.dir = restDirNow
                        }
                        // Kill the outward component so the link rests on the
                        // cone instead of buzzing against it every step.
                        let normal = simd_cross(restDirNow, node.dir).unit
                        let outward = simd_dot(node.omega, normal)
                        if abs(outward) > 1e-5 { node.omega -= normal * outward }
                    }

                    if settings.collision {
                        var position = anchor + node.dir * node.length
                        position = resolveCollisions(position, anchor: anchor, length: node.length)
                        let resolved = position - anchor
                        let magnitude = simd_length(resolved)
                        if magnitude > 1e-5 { node.dir = resolved / magnitude }
                    }
                }

                worldPos[node.bone] = anchor + node.dir * node.length
                let delta = quatBetween(anchorQuat.act(node.restDir), node.dir)
                worldQuat[node.bone] = quatNormalize(delta * anchorQuat)
                clothNodes[index] = node
            }
        }
    }

    private func distanceToSegment(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let axis = b - a
        let lengthSquared = simd_dot(axis, axis)
        guard lengthSquared > 1e-8 else { return simd_length(p - a) }
        let t = max(0, min(1, simd_dot(p - a, axis) / lengthSquared))
        return simd_length(p - (a + axis * t))
    }

    private func resolveCollisions(_ position: SIMD3<Float>, anchor: SIMD3<Float>, length: Float) -> SIMD3<Float> {
        var point = position
        let minDistance = max(1e-4, length * 0.15)
        for capsule in capsules {
            let a = capsule.boneA >= 0 ? worldPos[capsule.boneA] : anchor
            let b = capsule.boneB >= 0 ? worldPos[capsule.boneB] : a
            // If the link hangs from a point already inside (or right next to)
            // the capsule, pushing it out would fling the whole skirt open
            // instead of stopping it from clipping. Skip that capsule.
            if distanceToSegment(anchor, a, b) < capsule.radius * 1.15 { continue }
            let axis = b - a
            let axisLengthSquared = simd_dot(axis, axis)
            let t: Float
            if axisLengthSquared < 1e-8 {
                t = 0
            } else {
                t = max(0, min(1, simd_dot(point - a, axis) / axisLengthSquared))
            }
            let closest = a + axis * t
            let offset = point - closest
            let distance = simd_length(offset)
            let radius = capsule.radius
            guard distance < radius else { continue }
            let normal = distance > 1e-5 ? offset / distance : SIMD3<Float>(0, 0, 1)
            let target = closest + normal * radius * 1.02
            let direction = target - anchor
            // Only accept the push when it actually moves the tip away.
            if simd_length(direction) > minDistance,
               simd_dot(direction, point - anchor) > 0 {
                point = anchor + direction.unit * length
            }
        }
        // Floor. Bones below the ground plane are the most obvious cloth bug.
        if point.y < floorY + modelHeight * 0.002 {
            point.y = floorY + modelHeight * 0.002
            let direction = point - anchor
            if simd_length(direction) > 1e-5 {
                point = anchor + direction.unit * length
            }
        }
        return point
    }

    // MARK: - Rigid integration

    private func stepRigidBodies(model: PMXModel, settings: MMDPhysicsSettings, dt: Float) {
        let substeps = max(1, min(4, settings.substeps))
        let subDt = dt / Float(substeps)
        let gravity = SIMD3<Float>(0, -max(0, settings.gravity) * 9.8 * 0.9, 0)

        for _ in 0..<substeps {
            for index in rigidStates.indices {
                var state = rigidStates[index]
                let mass = max(0.001, state.body.mass)
                var force = gravity * mass

                // A weak pull toward the authored position keeps a badly joined
                // body from drifting away. The old value (14 x mass) turned the
                // whole skirt into a stiff rubber band, which is why the rigid
                // mode looked frozen.
                force += (state.restPosition - state.position) * (1.6 * mass)

                force -= state.velocity * state.body.linearDamping * mass * 2.4

                for joint in joints {
                    let isA = rigidStateByBody[joint.bodyA] == index
                    let isB = rigidStateByBody[joint.bodyB] == index
                    guard isA || isB else { continue }
                    let otherIndex = isA ? joint.bodyB : joint.bodyA
                    guard otherIndex >= 0, otherIndex < model.rigidBodies.count else { continue }
                    let other = rigidStates[rigidStateByBody[otherIndex] ?? index]
                    let anchor = other.position + (isA ? joint.offset : -joint.offset)
                    // PMX spring values are 0...∞; 0 means "rigid". Map them so
                    // a fully rigid joint is strong and a soft one still holds.
                    let springSum = abs(joint.springPosition.x) + abs(joint.springPosition.y)
                        + abs(joint.springPosition.z)
                    let strength = 90 / (1 + springSum * 4)
                    force += (anchor - state.position) * strength * mass
                }

                state.velocity += force / mass * subDt
                let speed = simd_length(state.velocity)
                if speed > 6 { state.velocity *= 6 / speed }
                state.position += state.velocity * subDt

                // Positional joint projection: keeps links from stretching
                // without relying on a stiff force.
                for joint in joints {
                    let isA = rigidStateByBody[joint.bodyA] == index
                    let isB = rigidStateByBody[joint.bodyB] == index
                    guard isA || isB else { continue }
                    let otherIndex = isA ? joint.bodyB : joint.bodyA
                    guard otherIndex >= 0, otherIndex < model.rigidBodies.count,
                          let otherSlot = rigidStateByBody[otherIndex] else { continue }
                    let other = rigidStates[otherSlot]
                    let anchor = other.position + (isA ? joint.offset : -joint.offset)
                    let delta = state.position - anchor
                    let distance = simd_length(delta)
                    let maxDeviation = max(0.02, modelHeight * 0.02)
                    if distance > maxDeviation {
                        state.position = anchor + delta / distance * maxDeviation
                    }
                }

                let angularSpeed = simd_length(state.angularVelocity)
                if angularSpeed > 0.0001 {
                    let step = min(0.35, angularSpeed * subDt)
                    state.rotation = simd_quatf(angle: step,
                                                axis: state.angularVelocity / angularSpeed) * state.rotation
                }
                let angularDamping = max(0.0, min(1.0, state.body.angularDamping))
                state.angularVelocity *= max(0, 1 - angularDamping * subDt * 60 * 0.35)
                state.velocity *= max(0, 1 - state.body.linearDamping * subDt * 60 * 0.20)

                if settings.collision {
                    let radius = max(state.body.size.x, max(state.body.size.y, state.body.size.z))
                    if state.position.y - radius < floorY {
                        state.position.y = floorY + radius
                        if state.velocity.y < 0 {
                            state.velocity.y = -state.velocity.y * max(0, min(0.9, state.body.restitution))
                        }
                    }
                }
                rigidStates[index] = state
            }

            if settings.collision {
                for i in rigidStates.indices {
                    for j in (i + 1)..<rigidStates.count {
                        let a = rigidStates[i]
                        let b = rigidStates[j]
                        if a.body.group == b.body.group { continue }
                        let maskForB = UInt16(1) << UInt16(min(15, b.body.group))
                        let maskForA = UInt16(1) << UInt16(min(15, a.body.group))
                        if (a.body.collisionMask & maskForB) == 0 { continue }
                        if (b.body.collisionMask & maskForA) == 0 { continue }
                        let ra = max(a.body.size.x, max(a.body.size.y, a.body.size.z))
                        let rb = max(b.body.size.x, max(b.body.size.y, b.body.size.z))
                        let delta = b.position - a.position
                        let distance = simd_length(delta)
                        let minimum = ra + rb
                        guard distance < minimum, distance > 0.0001 else { continue }
                        let normal = delta / distance
                        let penetration = minimum - distance
                        rigidStates[i].position -= normal * penetration * 0.5
                        rigidStates[j].position += normal * penetration * 0.5
                        let relative = simd_dot(rigidStates[j].velocity - rigidStates[i].velocity, normal)
                        if relative < 0 {
                            let impulse = normal * (-relative * 0.5)
                            rigidStates[i].velocity -= impulse
                            rigidStates[j].velocity += impulse
                        }
                    }
                }
            }
        }
    }

    private func applyRigidBodies(to animations: inout [Int: MMDBoneAnimation], model: PMXModel,
                                  settings: MMDPhysicsSettings) {
        var applied: Set<Int> = []
        let limit = max(0.05, min(0.35, settings.maxAngle / 120))
        for state in rigidStates {
            let boneIndex = state.body.boneIndex
            guard boneIndex >= 0 && boneIndex < boneCount,
                  !Self.isHumanoidDeformBone(model.bones[boneIndex]),
                  !ikBones.contains(boneIndex),
                  applied.insert(boneIndex).inserted else { continue }

            var deltaPosition = state.position - state.restPosition
            let length = simd_length(deltaPosition)
            if length > limit { deltaPosition *= limit / length }

            let parent = parentIndices[boneIndex]
            let parentQuat = parent >= 0 ? worldQuat[parent] : mmdIdentityQuaternion
            var animation = animations[boneIndex] ?? MMDBoneAnimation()
            animation.position += parentQuat.inverse.act(deltaPosition)

            // PMX bones have no rest rotation, so the world delta maps straight
            // into the parent's frame. The old code conjugated by the parent's
            // *local* rotation, which rotated the whole offset by its own
            // inverse and made cloth bodies swing the wrong way.
            let deltaRotation = state.rotation * state.restRotation.inverse
            let local = parentQuat.inverse * deltaRotation * parentQuat
            animation.rotation = quatNormalize(animation.rotation * local)
            animations[boneIndex] = animation
        }
    }

    /// MMD rigid bodies are normally authored for skirts, hair and props.
    /// Some converted rigs also put a dynamic body on a foot or shin; feeding
    /// that body back into a deforming humanoid bone bends the leg even when
    /// the VMD pose is straight. Keep physics feedback out of the core rig.
    private static func isHumanoidDeformBone(_ bone: PMXBone) -> Bool {
        let text = (bone.name + " " + bone.nameEn).lowercased()
        return humanoidMarkers.contains(where: { text.contains($0) })
    }
}


/// MMD's IK "unit angle" is a multiplier on the alignment step. Clamp it to a
/// sane range so a malformed PMX cannot make one iteration jump 180 degrees.
func class_half_clamp(_ value: Float) -> Float {
    max(0.02, min(1.0, value))
}
