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
    var mode: MMDPhysicsMode = .off
    var gravity: Float = 0.6
    var stiffness: Float = 0.4
    var damping: Float = 0.35
    var wind: Float = 0.15
    var inertia: Float = 0.8
    var collision: Bool = true
    var maxAngle: Float = 24
    var substeps: Int = 2

    var enabled: Bool { mode != .off }
}

final class MMDSpringPhysics {

    private struct ChainBone {
        var index: Int
        var parent: Int
        var depth: Int
        var maxAngle: Float        // degrees
        var phase: Float
        var restAxis: SIMD3<Float> // rest bone direction in world space
        var restQuat: simd_quatf   // approximation of the rest world rotation
        var length: Float          // bone length, used for the clip capsule test
        var hipOffset: SIMD3<Float> // rest position relative to the body axis
        var angle: Float = 0       // current spring angle in radians
        var velocity: Float = 0    // angular velocity in radians / second
        var smoothedTarget: Float = 0
    }

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
        var type: UInt8
        var a: Int
        var b: Int
        var offset: SIMD3<Float>
        var spring: SIMD3<Float>
        var springRotation: SIMD3<Float>
    }

    private var offsets: [Int: SIMD3<Float>] = [:]
    private var velocities: [Int: SIMD3<Float>] = [:]
    private var chainBones: [ChainBone] = []
    private var rigidStates: [RigidState] = []
    private var rigidStateByBody: [Int: Int] = [:]
    private var joints: [JointLink] = []
    private var lastTime: CFTimeInterval = 0
    private var lastBodyRotation: simd_quatf = mmdIdentityQuaternion
    private var rigidBoneIndices: Set<Int> = []
    private var secondaryBones: Set<Int> = []
    /// Bones touched by a PMX IK chain. Rotating these in the physics pass made
    /// the IK solver overshoot on the next frame, which is why models stopped
    /// exploding as soon as "IK 求解" was switched off. Physics now never writes
    /// to them, so the two solvers can stay on together.
    private var ikBones: Set<Int> = []
    private var hipCenter = SIMD3<Float>()
    private var stepAccumulator: Float = 0
    private(set) var solvedRigidBodyCount = 0
    private(set) var solvedJointCount = 0

    private let keywords = ["髪", "hair", "skirt", "スカート", "ribbon", "リボン",
                            "tail", "尾", "cape", "マント", "袖", "sleeve", "breast", "胸",
                            "wing", "羽", "翼", "feather", "羽根", "plume", "frill", "フリル",
                            "cloth", "裾", "垂", "发饰", "髪飾", "headdress", "dress", "ドレス",
                            "apron", "エプロン", "belt", "ベルト", "scarf", "マフラー", "ネクタイ"]

    func reset() {
        offsets.removeAll()
        velocities.removeAll()
        for index in chainBones.indices {
            chainBones[index].angle = 0
            chainBones[index].velocity = 0
        }
        lastTime = 0
        lastBodyRotation = mmdIdentityQuaternion
        stepAccumulator = 0
        for index in rigidStates.indices {
            rigidStates[index].position = rigidStates[index].restPosition
            rigidStates[index].rotation = rigidStates[index].restRotation
            rigidStates[index].velocity = .zero
            rigidStates[index].angularVelocity = .zero
        }
    }

    func prepare(model: PMXModel) {
        chainBones.removeAll()
        offsets.removeAll()
        velocities.removeAll()
        rigidStates.removeAll()
        rigidStateByBody.removeAll()
        joints.removeAll()
        rigidBoneIndices.removeAll()
        secondaryBones.removeAll()
        ikBones.removeAll()

        var byName = [String: Int]()
        for (index, bone) in model.bones.enumerated() {
            byName[bone.name] = index
            if !bone.nameEn.isEmpty { byName[bone.nameEn] = index }
        }

        // Collect every bone that an IK solver rewrites each frame.
        for (index, bone) in model.bones.enumerated() {
            guard let ik = bone.ik, ik.targetIndex >= 0 else { continue }
            ikBones.insert(index)
            if ik.targetIndex < model.bones.count { ikBones.insert(ik.targetIndex) }
            for link in ik.links where link.boneIndex >= 0 && link.boneIndex < model.bones.count {
                ikBones.insert(link.boneIndex)
            }
        }

        // Rest world transforms, used to derive each chain bone's rest direction
        // so gravity can pull it toward the floor instead of using a blind sine.
        var restWorldPos = [SIMD3<Float>](repeating: .zero, count: model.bones.count)
        var restWorldQuat = [simd_quatf](repeating: mmdIdentityQuaternion, count: model.bones.count)
        for index in model.bones.indices {
            let bone = model.bones[index]
            let parent = bone.parentIndex
            let parentPos = parent >= 0 && parent < model.bones.count ? restWorldPos[parent] : .zero
            let parentQuat = parent >= 0 && parent < model.bones.count ? restWorldQuat[parent] : mmdIdentityQuaternion
            let localPos = bone.position
            restWorldPos[index] = parentPos + parentQuat.act(localPos)
            restWorldQuat[index] = parentQuat
        }

        var secondary = Set<Int>()
        for (index, bone) in model.bones.enumerated() {
            let lower = bone.name.lowercased() + " " + bone.nameEn.lowercased()
            guard keywords.contains(where: { lower.contains($0) }) else { continue }
            // Control/helper bones (Ctr_/Skn_/dummy) are often already posed by
            // the VMD. Rotating them again in the physics pass folds cloth onto
            // itself.
            if lower.contains("ctr_") || lower.contains("skn_") || lower.contains("dummy") { continue }
            // Never fight the IK solver or deform the humanoid core.
            if ikBones.contains(index) || Self.isHumanoidDeformBone(bone) { continue }
            secondary.insert(index)
        }
        // Some rigs only name the chain root ("skirt_master") and leave child
        // bones generic. Walk upward from every bone and include a chain when
        // its parent is a known secondary root.
        for (index, bone) in model.bones.enumerated() {
            guard !ikBones.contains(index), !Self.isHumanoidDeformBone(bone) else { continue }
            var cursor = bone.parentIndex
            var guardCount = 0
            while cursor >= 0 && cursor < model.bones.count && guardCount < 8 {
                if secondary.contains(cursor) {
                    secondary.insert(index)
                    break
                }
                cursor = model.bones[cursor].parentIndex
                guardCount += 1
            }
        }

        secondaryBones = secondary

        for index in secondary.sorted() {
            guard index >= 0 && index < model.bones.count else { continue }
            let bone = model.bones[index]
            // Drive only the root of each secondary chain. Applying an angle to
            // every link compounds down the chain (10 links × 20° = 200°),
            // which is what made skirts, ribbons and hair fly apart.
            if bone.parentIndex >= 0, secondary.contains(bone.parentIndex) { continue }
            let lower = bone.name.lowercased() + " " + bone.nameEn.lowercased()
            var maxAngle: Float = 16
            if lower.contains("wing") || lower.contains("羽") || lower.contains("翼") { maxAngle = 18 }
            else if lower.contains("ribbon") || lower.contains("リボン") || lower.contains("尾") { maxAngle = 16 }
            else if lower.contains("skirt") || lower.contains("スカート") || lower.contains("裾") { maxAngle = 14 }
            else if lower.contains("hair") || lower.contains("髪") { maxAngle = 11 }
            else if lower.contains("sleeve") || lower.contains("袖") { maxAngle = 13 }
            var depth = 0
            var cursor = bone.parentIndex
            while cursor >= 0 && cursor < model.bones.count && depth < 12 {
                depth += 1
                cursor = model.bones[cursor].parentIndex
            }
            // Direction of the bone: prefer the authored tail bone, then the
            // first child in the chain, then world up.
            var tailDirection = SIMD3<Float>(0, 1, 0)
            if bone.tailIndex >= 0 && bone.tailIndex < model.bones.count {
                let delta = restWorldPos[bone.tailIndex] - restWorldPos[index]
                if simd_length(delta) > 0.0001 { tailDirection = simd_normalize(delta) }
            } else if let child = model.bones.firstIndex(where: { $0.parentIndex == index }) {
                let delta = restWorldPos[child] - restWorldPos[index]
                if simd_length(delta) > 0.0001 { tailDirection = simd_normalize(delta) }
            }
            // Used by the soft clip test: how far the bone reaches and where it
            // starts relative to the hips.
            hipCenter = SIMD3<Float>((model.bounds.minPoint.x + model.bounds.maxPoint.x) * 0.5,
                                     model.bounds.minPoint.y + model.bounds.height * 0.55,
                                     (model.bounds.minPoint.z + model.bounds.maxPoint.z) * 0.5)
            let boneLength: Float = {
                if bone.tailIndex >= 0 && bone.tailIndex < model.bones.count {
                    let delta = restWorldPos[bone.tailIndex] - restWorldPos[index]
                    let magnitude = simd_length(delta)
                    if magnitude > 0.0001 { return magnitude }
                }
                if let child = model.bones.firstIndex(where: { $0.parentIndex == index }) {
                    let delta = restWorldPos[child] - restWorldPos[index]
                    let magnitude = simd_length(delta)
                    if magnitude > 0.0001 { return magnitude }
                }
                return max(0.02, model.bounds.height * 0.01)
            }()
            let hipDistance = simd_length(restWorldPos[index] - hipCenter)
            if hipDistance < model.bounds.height * 0.14 {
                maxAngle = min(maxAngle, maxAngle * 0.6)
            }
            chainBones.append(ChainBone(index: index, parent: bone.parentIndex,
                                        depth: depth,
                                        maxAngle: maxAngle,
                                        phase: Float(index % 11) * 0.37,
                                        restAxis: tailDirection,
                                        restQuat: restWorldQuat[index],
                                        length: boneLength,
                                        hipOffset: restWorldPos[index] - hipCenter))
        }

        // Build rigid-body state. Static/kinematic bodies are anchors only.
        for (bodyIndex, body) in model.rigidBodies.enumerated() where body.mode >= 2 && body.boneIndex >= 0 {
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
        // Limit the O(n²) collision pass on very heavy models while retaining
        // the bodies closest to the hips/legs and hair.
        if rigidStates.count > 96 {
            rigidStates = Array(rigidStates.prefix(96))
            rigidBoneIndices = Set(rigidStates.map { $0.body.boneIndex })
        }
        for joint in model.joints {
            guard joint.bodyA >= 0, joint.bodyB >= 0,
                  joint.bodyA < model.rigidBodies.count,
                  joint.bodyB < model.rigidBodies.count else { continue }
            let a = model.rigidBodies[joint.bodyA].position
            let b = model.rigidBodies[joint.bodyB].position
            joints.append(JointLink(type: joint.type, a: joint.bodyA, b: joint.bodyB,
                                    offset: a - b,
                                    spring: joint.springPosition,
                                    springRotation: joint.springRotation))
        }
        solvedRigidBodyCount = rigidStates.count
        solvedJointCount = joints.count
        reset()
    }

    func apply(animations: [Int: MMDBoneAnimation], model: PMXModel,
               settings: MMDPhysicsSettings, time: CFTimeInterval,
               forcedStep: Float? = nil,
               driveRotation: simd_quatf? = nil) -> [Int: MMDBoneAnimation] {
        guard settings.mode != .off else { return animations }
        if forcedStep == nil && time < lastTime { reset() }
        let dt: Float
        if let forcedStep {
            dt = max(0.001, min(0.05, forcedStep))
        } else {
            if lastTime == 0 {
                lastTime = time
                return animations
            }
            guard time > lastTime + 0.00001 else {
                return animations
            }
            dt = Float(min(0.05, max(0.001, time - lastTime)))
        }
        lastTime = max(lastTime, time)

        // Upper body rotation is what actually swings cloth; the center bone
        // usually only carries translation and yaw.
        let centerIndex = model.bones.firstIndex {
            $0.name == "上半身" || $0.name.lowercased().contains("upper body")
                || $0.name.lowercased() == "spine"
        } ?? model.bones.firstIndex {
            $0.name == "センター" || $0.name.lowercased().contains("center")
        }
        let bodyRotation = driveRotation
            ?? centerIndex.flatMap { animations[$0]?.rotation }
            ?? mmdIdentityQuaternion
        // Axis-angle rather than euler: euler deltas flip sign near ±180°
        // and injected a per-frame jitter into hair and wings.
        let delta = bodyRotation * lastBodyRotation.inverse
        let deltaAngle = 2 * acosf(min(1, abs(delta.real)))
        let deltaAxis = simd_length(delta.imag) > 0.0001 ? simd_normalize(delta.imag) : SIMD3<Float>(0, 0, 0)
        let bodySwing = deltaAxis * (deltaAngle > 1e-4 ? deltaAngle : 0)
        lastBodyRotation = bodyRotation

        // Fixed-step accumulator: preview frame times vary with the display
        // refresh, which made the springs jitter while the fixed-rate video
        // export stayed smooth. Integrate at a constant 60 Hz instead.
        let fixedStep: Float = 1.0 / 60.0
        stepAccumulator += dt
        var stepCount = min(3, Int(stepAccumulator / fixedStep))
        stepAccumulator -= Float(stepCount) * fixedStep
        if stepCount < 0 { stepCount = 0 }

        var result = animations
        let gravity = max(0, settings.gravity)
        let stiffness = max(0.02, settings.stiffness)
        let damping = max(0.02, settings.damping)
        let wind = max(0, settings.wind)
        let inertia = max(0, settings.inertia)

        for nodeIndex in chainBones.indices {
            var node = chainBones[nodeIndex]
            let index = node.index
            guard !rigidBoneIndices.contains(index), !ikBones.contains(index) else { continue }
            // A VMD track on a cloth/hair bone is an explicit pose. Adding the
            // spring rotation on top of it doubles the deformation and is the
            // main cause of the "physics on" explosion.
            // VMD often writes an identity track for every bone. Skipping any
            // track at all silently disabled the cloth solver. Bones that are
            // genuinely posed still receive a damped additive swing instead of
            // being skipped entirely, otherwise wings animated by the VMD look
            // stiff.
            var additiveScale: Float = 1
            if let track = animations[index] {
                let trackAngle = 2 * acosf(min(1, abs(track.rotation.real)))
                if trackAngle > mmdRadians(8) { additiveScale = 0.5 }
            }

            // World orientation of this bone at rest, rotated by the body so
            // gravity is applied in world space rather than a blind sine wave.
            let worldQuat = bodyRotation * node.restQuat
            var down = SIMD3<Float>(0, -1, 0)
            let timeValue = Float(time)
            down += SIMD3<Float>(
                sinf(timeValue * (0.9 + wind * 1.6) + node.phase),
                0,
                cosf(timeValue * 1.3 + node.phase)
            ) * (wind * 0.55)
            down = simd_length(down) > 0.0001 ? simd_normalize(down) : SIMD3<Float>(0, -1, 0)

            let axis = simd_normalize(worldQuat.act(node.restAxis))
            let dotValue = max(-1, min(1, simd_dot(axis, down)))
            // Angle between the bone and the gravity direction. Gravity strength
            // scales how much of that angle the bone is allowed to give up.
            let droop = acosf(dotValue) * min(1.0, gravity)
            // Swing from the body's angular motion, expressed in radians.
            let swing = min(node.maxAngle * 0.8 * 0.017,
                            (bodySwing.x * 0.9 + bodySwing.z * 0.35) * inertia * 2.2)
            var target = max(-node.maxAngle * 1.4, min(node.maxAngle * 1.4,
                              (min(droop, mmdRadians(node.maxAngle)) + swing)))

            // Soft anti-clip test: if the bone tip would land inside the torso
            // cylinder, pull the target back toward rest instead of letting the
            // skirt or hair pass through the body.
            if settings.collision {
                let tip = hipCenter + bodyRotation.act(node.hipOffset + node.restAxis * node.length)
                let torsoRadius = max(0.03, model.bounds.height * 0.045)
                let torsoTop = hipCenter.y + model.bounds.height * 0.14
                let torsoBottom = hipCenter.y - model.bounds.height * 0.12
                let horizontal = SIMD3<Float>(tip.x - hipCenter.x, 0, tip.z - hipCenter.z)
                if tip.y > torsoBottom, tip.y < torsoTop {
                    // Continuous falloff instead of a binary in/out test: the
                    // hard cut switched the target between full and 45% every
                    // frame and read as jitter while playing.
                    let distance = simd_length(horizontal)
                    let penetration = max(0, torsoRadius * 1.5 - distance) / (torsoRadius * 1.5)
                    target *= 1 - 0.55 * min(1, penetration)
                }
            }
            target *= additiveScale
            // Low-pass the target so a discrete geometry test or a stepped
            // VMD curve cannot produce frame-to-frame target jumps.
            node.smoothedTarget += (target - node.smoothedTarget) * min(1, dt * 26)
            target = node.smoothedTarget

            var rotAxis = simd_cross(axis, down)
            if simd_length(rotAxis) < 0.0001 {
                rotAxis = simd_cross(axis, SIMD3<Float>(0, 0, 1))
                if simd_length(rotAxis) < 0.0001 { rotAxis = SIMD3<Float>(1, 0, 0) }
            }
            rotAxis = simd_normalize(rotAxis)

            // Spring-damper integration (semi-implicit Euler). Stiffness sets
            // the pull toward the gravity target and damping is normalised
            // against the spring so it stays stable at any frame rate.
            let substeps = max(1, min(4, settings.substeps))
            let h = fixedStep / Float(substeps)
            let k = 6.0 + stiffness * 18.0
            let critical = 2.0 * sqrtf(k)
            let dampingFactor = critical * (0.35 + damping * 1.1)
            if stepCount > 0 {
                for _ in 0..<(stepCount * substeps) {
                    let acceleration = (target - node.angle) * k - node.velocity * dampingFactor
                    node.velocity = max(-14, min(14, node.velocity + acceleration * h))
                    node.angle += node.velocity * h
                }
            }
            let hardLimit = mmdRadians(node.maxAngle) * 1.35
            node.angle = max(-hardLimit, min(hardLimit, node.angle))
            chainBones[nodeIndex] = node

            let localAxis = worldQuat.inverse.act(rotAxis)
            let localLength = simd_length(localAxis)
            guard localLength > 0.0001 else { continue }
            let offsetRotation = simd_quatf(angle: node.angle, axis: localAxis / localLength)
            var animation = result[index] ?? MMDBoneAnimation()
            animation.rotation = animation.rotation * offsetRotation
            result[index] = animation
        }

        if settings.mode == .rigid && !rigidStates.isEmpty {
            stepRigidBodies(model: model, settings: settings, dt: dt)
            applyRigidBodies(to: &result, model: model, settings: settings)
        }
        return result
    }

    // MARK: - Rigid bodies

    private func stepRigidBodies(model: PMXModel, settings: MMDPhysicsSettings, dt: Float) {
        let substeps = max(1, min(4, settings.substeps))
        let subDt = dt / Float(substeps)
        let gravity = SIMD3<Float>(0, -max(0, settings.gravity) * 1.7, 0)
        let floorY = model.bounds.minPoint.y

        for _ in 0..<substeps {
            for index in rigidStates.indices {
                var state = rigidStates[index]
                let mass = max(0.001, state.body.mass)
                var force = gravity * mass
                // Pull back to the authored body position. Without this a body
                // drifts away until the 1.2-unit clamp is reached.
                force += (state.restPosition - state.position) * (14.0 * mass)
                // Damped angular inertia from body rotation.
                force.x -= state.velocity.x * state.body.linearDamping * mass * 18
                force.y -= state.velocity.y * state.body.linearDamping * mass * 18
                force.z -= state.velocity.z * state.body.linearDamping * mass * 18

                // Joint springs pull dynamic bodies toward their anchored rest
                // offset. Bodies not referenced by joints keep their shape.
                for joint in joints {
                    guard joint.a < model.rigidBodies.count, joint.b < model.rigidBodies.count else { continue }
                    let isA = rigidStateByBody[joint.a] == index
                    let isB = rigidStateByBody[joint.b] == index
                    guard isA || isB else { continue }
                    let otherIndex = isA ? joint.b : joint.a
                    let otherPosition = model.rigidBodies[otherIndex].position
                    let anchor = otherPosition + (isA ? joint.offset : -joint.offset)
                    let stiffnessVector = SIMD3<Float>(abs(joint.spring.x), abs(joint.spring.y), abs(joint.spring.z))
                    let strength = 32.0 / (1.0 + stiffnessVector.x + stiffnessVector.y + stiffnessVector.z)
                    let delta = anchor - state.position
                    force += delta * strength * mass
                    let angularThis = state.angularVelocity
                    let springRot = (abs(joint.springRotation.x) + abs(joint.springRotation.y) + abs(joint.springRotation.z)) / 3
                    state.angularVelocity -= angularThis * min(0.95, 0.06 + springRot * 0.02)
                }

                state.velocity += force / mass * subDt
                let speed = simd_length(state.velocity)
                if speed > 8 { state.velocity *= 8 / speed }
                state.position += state.velocity * subDt
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
                        let maskForB = UInt16(1) << UInt16(b.body.group)
                        let maskForA = UInt16(1) << UInt16(a.body.group)
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
        for state in rigidStates {
            let boneIndex = state.body.boneIndex
            guard boneIndex >= 0 && boneIndex < model.bones.count,
                  !Self.isHumanoidDeformBone(model.bones[boneIndex]),
                  !ikBones.contains(boneIndex),
                  applied.insert(boneIndex).inserted else { continue }
            var deltaPosition = state.position - state.restPosition
            let length = simd_length(deltaPosition)
            // Cloth bodies can drift when joints are authored badly; clamping
            // the feedback keeps one runaway body from dragging a whole skirt.
            let limit = max(0.10, min(0.40, settings.maxAngle / 90))
            if length > limit { deltaPosition *= limit / length }
            let deltaRotation = state.rotation * state.restRotation.inverse
            var animation = animations[boneIndex] ?? MMDBoneAnimation()
            let parent = model.bones[boneIndex].parentIndex
            let parentRotation = parent >= 0 ? (animations[parent]?.rotation ?? mmdIdentityQuaternion)
                                             : mmdIdentityQuaternion
            animation.position += parentRotation.inverse.act(deltaPosition)
            let localRotation = parentRotation.inverse * deltaRotation * parentRotation
            animation.rotation = animation.rotation * localRotation
            animations[boneIndex] = animation
        }
    }

    /// MMD rigid bodies are normally authored for skirts, hair and props.
    /// Some converted rigs also put a dynamic body on a foot or shin; feeding
    /// that body back into a deforming humanoid bone bends the leg even when
    /// the VMD pose is straight. Keep physics feedback out of the core rig.
    private static func isHumanoidDeformBone(_ bone: PMXBone) -> Bool {
        let text = (bone.name + " " + bone.nameEn).lowercased()
        let markers = ["センター", "center", "上半身", "下半身", "upperbody", "upper_body",
                       "lowerbody", "lower_body", "spine", "chest", "torso", "hip", "hips",
                       "pelvis", "waist", "腰", "体幹", "torso", "root", "頭", "head",
                       "首", "neck", "肩", "shoulder", "腕", "arm", "ひじ", "elbow",
                       "手首", "wrist", "hand", "指", "finger", "thumb", "足", "leg",
                       "脚", "もも", "thigh", "ひざ", "knee", "calf", "shin", "すね",
                       "足首", "ankle", "かかと", "heel", "foot", "toe", "つま先"]
        return markers.contains(where: { text.contains($0) })
    }
}


/// MMD's IK "unit angle" is a multiplier on the alignment step. Clamp it to a
/// sane range so a malformed PMX cannot make one iteration jump 180 degrees.
func class_half_clamp(_ value: Float) -> Float {
    max(0.02, min(1.0, value))
}
