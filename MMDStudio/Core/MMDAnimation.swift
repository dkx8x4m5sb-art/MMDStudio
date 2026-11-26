//
//  MMDAnimation.swift
//  MMD Studio
//
//  骨骼求解：蒙皮矩阵、IK、骨骼链弹簧与 PMX 刚体（Bullet）。
//

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
    case auto
    case secondary
    case rigid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "关闭"
        case .auto: return "自动"
        case .secondary: return "摆动（裙/发）"
        case .rigid: return "PMX 刚体"
        }
    }

    var detail: String {
        switch self {
        case .off: return "完全跟随动作，不做二次解算"
        case .auto: return "模型带可用刚体时用 PMX 刚体，否则退回摆动"
        case .secondary: return "只跑裙/发/飘带的弹簧链，不吃刚体数据"
        case .rigid: return "把 PMX 的刚体与 6DOF 关节交给 Bullet"
        }
    }
}

/// One collision sphere the cloth solver actually tests against, exposed for
/// the debug overlay. Not the PMX rigid bodies: those live on the model.
struct MMDPhysicsColliderDebug {
    var bone: Int
    var offset: SIMD3<Float>
    var radius: Float
}

/// Real-time secondary-motion and PMX rigid-body solver.
///
/// The chain solver drives skirt/ribbon/hair/wing bones with a gravity-driven
/// spring-damper. PMX dynamic rigid bodies (mode 2) are integrated as
/// spheres/boxes with joint springs, floor contact and body-body collision;
/// their motion is fed back into the bound bones. This is a compact Bullet-like
/// approximation, not a bit-exact port of Bullet's constraint solver.
struct MMDPhysicsSettings {
    var mode: MMDPhysicsMode = .auto
    var gravity: Float = 0.75
    var stiffness: Float = 0.4
    var damping: Float = 0.35
    var wind: Float = 0.15
    var inertia: Float = 0.8
    var collision: Bool = true
    /// Cone limit for a single cloth link, in degrees. The link's own kind
    /// scales this (skirts swing widest), so the visible range is larger.
    var maxAngle: Float = 50
    var substeps: Int = 2

    var enabled: Bool { mode != .off }
}

final class MMDSpringPhysics {

    // MARK: - Skeleton mirror

    /// The solver needs the current world transform of every bone so a cloth
    /// chain can hang off its real parent (which may itself be a cloth link).
    /// The mirror is rebuilt from the pose on every frame, one topological
    /// pass over the bone array.
    private var boneCount = 0
    private var parentIndices: [Int] = []
    private var restLocal: [SIMD3<Float>] = []
    private var topoOrder: [Int] = []
    private var childIndices: [[Int]] = []
    private var restWorldPos: [SIMD3<Float>] = []
    private var worldPos: [SIMD3<Float>] = []
    /// World rotation straight from the animation, before any swing.
    private var poseQuat: [simd_quatf] = []
    /// World rotation including the swing this solver adds.
    private var solvedQuat: [simd_quatf] = []
    private var modelHeight: Float = 20
    private var floorY: Float = 0

    private var chains: [Chain] = []
    private var colliderSpheres: [ColliderSphere] = []
    private var ikBones: Set<Int> = []

    private var lastTime: CFTimeInterval = 0
    private var substepAccumulator: Float = 0
    private var simTime: Float = 0

    private(set) var solvedRigidBodyCount = 0
    private(set) var solvedJointCount = 0

    /// Copy of the solver's collision spheres for the debug overlay.
    var debugColliders: [MMDPhysicsColliderDebug] {
        colliderSpheres.map {
            MMDPhysicsColliderDebug(bone: $0.bone, offset: $0.offset, radius: $0.radius)
        }
    }
    /// Every body in the PMX file, simulated or purely a collider.
    private(set) var totalRigidBodyCount = 0
    /// Number of bones the chain solver drives. Surfaced in the inspector so
    /// "physics does nothing" can be told apart from "this model has no cloth
    /// bones".
    private(set) var drivenBoneCount = 0
    /// Bones the solver actually steers.
    var clothBoneCount: Int { drivenBoneCount }
    private(set) var clothChainCount = 0
    private(set) var colliderCount = 0
    /// "skirt 4 · hair 2" — chain count per kind, for the inspector.
    private(set) var chainKindSummary: [(String, Int)] = []
    /// Root bone names of the first few chains, so a model whose accessories
    /// are *not* being detected can be diagnosed from a screenshot.
    private(set) var chainSamples: [String] = []

    // MARK: - Chain model

    /// What kind of thing is hanging. Controls how limp it is, how far it may
    /// deviate and how hard it is pulled back to its authored silhouette.
    private enum ChainKind {
        case skirt, hair, sleeve, wing, ribbon, other

        var title: String {
            switch self {
            case .skirt: return "skirt"
            case .hair: return "hair"
            case .sleeve: return "sleeve"
            case .wing: return "wing"
            case .ribbon: return "ribbon"
            case .other: return "other"
            }
        }

        /// Radians a single link may deviate from the direction the animation
        /// gives it. The previous version allowed `maxAngle x 2.2` = 110°, and
        /// a ribbon folded 110° at every joint is a crumpled sheet — that is
        /// the creasing reported on hair and sashes. 10–20° per joint still
        /// adds up to 60–120° over a whole chain.
        var linkLimit: Float {
            switch self {
            case .skirt: return 0.34
            case .ribbon: return 0.26
            case .sleeve: return 0.24
            case .wing: return 0.30
            case .hair: return 0.16
            case .other: return 0.22
            }
        }

        /// Radians a single link may deviate from the authored silhouette,
        /// carried into the current pose by the chain anchor. This is the hard
        /// bound that makes "deformation grows over time" impossible.
        var chainLimit: Float {
            switch self {
            case .skirt: return 1.15
            case .ribbon: return 0.95
            case .sleeve: return 0.80
            case .wing: return 0.90
            case .hair: return 0.55
            case .other: return 0.75
            }
        }

        /// Angular spring pulling the link back onto the animated pose.
        var spring: Float {
            switch self {
            case .skirt: return 26
            case .ribbon: return 34
            case .sleeve: return 40
            case .wing: return 22
            case .hair: return 55
            case .other: return 32
            }
        }

        /// How strongly the anchor's own motion trails the links behind it.
        var drag: Float {
            switch self {
            case .skirt: return 0.9
            case .ribbon: return 1.3
            case .sleeve: return 0.6
            case .wing: return 0.5
            case .hair: return 1.1
            case .other: return 0.7
            }
        }
    }

    /// One segment of a chain. The whole state of a link is a unit direction
    /// and an angular velocity: there is no position to drift, no length to
    /// stretch and no scale to collapse, which is why this cannot deform the
    /// mesh a little more on every frame.
    private struct Link {
        var bone: Int
        /// Rest direction in model space.
        var restDir: SIMD3<Float>
        /// Authored bend between the previous link and this one, radians.
        var bend: Float
        var length: Float
        var limitLink: Float
        var limitChain: Float
        var spring: Float
        var damp: Float
        var droop: Float
        var drag: Float
        /// False for links that rest *inside* a body capsule (the top of a
        /// skirt sits on the hip): pushing those out inflates the cloth.
        var collides: Bool
        var dir: SIMD3<Float>
        var omega: SIMD3<Float>
    }

    private struct Chain {
        /// Bone the first link hangs from. -1 only for a rig with no torso.
        var anchor: Int
        var links: [Link]
        var kind: ChainKind
        var name: String
        var seeded: Bool
        var lastAnchor: SIMD3<Float>
        /// Anchor velocity for this frame, clamped. Sampled once per frame so
        /// the trailing drag does not depend on how many substeps run.
        var velocity: SIMD3<Float>
        /// Anchor acceleration for this frame, clamped. This is what makes a
        /// hem swing when the body starts or stops moving instead of sagging
        /// behind it, and it is the slider named "惯性".
        var accel: SIMD3<Float> = .zero
    }

    // MARK: - Rigid bodies

    private var rigidBoneIndices: Set<Int> = []
    /// Bodies authored on eyes/brows/limbs that were kept kinematic.
    private var protectedDynamicBodyCount = 0
    private var protectedBoneSamples: [String] = []

    // MARK: - Keywords

    private static let clothKeywords = [
        "髪", "hair", "ヘア", "ahoge", "skirt", "スカート", "ribbon",
        "リボン", "tail", "尾", "cape", "マント", "袖", "sleeve", "wing",
        "羽", "翼", "feather", "羽根", "plume", "frill", "フリル", "cloth",
        "裾", "垂", "ドレス", "dress", "apron", "エプロン", "belt", "ベルト",
        "scarf", "マフラー", "ネクタイ", "necktie", "テープ", "ストラップ",
        "strap", "ハネ", "ポニー", "ponytail", "braid", "三つ編",
        // Chinese / pinyin rigs (Genshin, 王者 rips).
        "裙", "衣摆", "飘带", "披风", "头发", "马尾", "辫", "发梢",
        "围巾", "腰带", "领带", "下摆", "纱", "穗", "尾巴", "带", "挂饰"
    ]

    private static let humanoidMarkers = [
        "センター", "center", "上半身", "下半身", "upperbody", "upper body",
        "lowerbody", "lower body", "spine", "chest", "torso", "hip", "hips",
        "pelvis", "waist", "腰", "体幹", "root", "頭", "head",
        "首", "neck", "肩", "shoulder", "腕", "arm", "ひじ", "elbow",
        "手首", "wrist", "hand", "指", "finger", "thumb", "足", "leg",
        "脚", "もも", "thigh", "ひざ", "knee", "calf", "shin", "すね",
        "足首", "ankle", "かかと", "heel", "foot", "toe", "つま先", "ひざ",
        "clavicle", "armature", "全ての親", "allparent",
        // Chinese rigs (原神 / 星穹铁道 / 绝区零 提取) name limbs 臂/肘/腕/腿/膝.
        // Without these a whole arm counted as "dangling cloth" and the solver
        // swung it, which is the arm deformation reported on v1.7.
        "臂", "肘", "腕", "手", "掌", "腿", "膝", "脚", "踝", "胯", "臀",
        "胸", "腹", "脊", "脖", "頭", "头", "颈", "肩胛", "锁骨", "手指",
        "足", "脚趾", "大腿", "小腿", "上臂", "前臂", "股", "胫",
        // Bust: a game-rip chest usually has 2–4 wobble bones that the model
        // author expects to stay put. Swinging them was the "chest moves
        // wrongly" report.
        "breast", "bust", "おっぱい", "乳房", "乳", "boob"
    ]

    /// Bones that must never be driven by physics: eyes, mouth, brows and the
    /// like. They are small, dangling and otherwise indistinguishable from a
    /// hair strand, and rotating them folds the face.
    private static let faceKeywords = [
        "目", "眼", "eye", "瞳", "hitomi", "歯", "齿", "tooth", "teeth",
        "舌", "tongue", "眉", "brow", "mayu", "睫", "lash", "口", "mouth",
        "唇", "lip", "kuchi", "頬", "cheek", "鼻", "nose", "耳", "ear",
        "face", "顔", "jaw", "顎", "あご", "表情"
    ]

    /// Bangs are welded to the forehead in MMD too. Letting them swing is what
    /// looked like "刘海乱飞".
    private static let rigidKeywords = [
        "刘海", "前髪", "前发", "bang", "眉", "睫", "ひたい", "forelock"
    ]

    private static let helperPrefixes = [
        "ctr", "ctrl", "control", "skn", "dummy", "ダミー", "op_", "adj",
        "adjust", "物理", "phys", "ik_", "motion", "kci", "コントロール",
        // Chinese rigs from 原神 / 星穹铁道 exports start with a 操作中心
        // ("operation centre") bone that carries the whole model. It has no
        // skin weights, but the old name-only rule turned it into a cloth
        // chain and it ate part of the 600-bone budget.
        "操作", "制御", "リグ", "shadow", "影", "ground", "床", "gizmo",
        "ボーン"
    ]

    // MARK: - Lifecycle

    func reset() {
        substepAccumulator = 0
        simTime = 0
        lastTime = 0
        for index in chains.indices {
            chains[index].seeded = false
        }
        if let world = bulletWorld {
            for record in bulletBodies {
                MMDPhysSetBodyTransform(world, record.handle,
                                        record.restPosition.f3, record.restRotation.f4)
                MMDPhysResetBody(world, record.handle)
            }
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
        // PMX 的「骨骼位置」是模型空间里的绝对坐标，不是相对父骨骼的偏移。
        // 这里要的是局部偏移：只把绝对值直接塞进 restLocal，下面按父骨骼累加
        // 时就会把祖先的位置再算一遍 —— 一个 20 单位高的角色，胸口会被算到
        // 40 以上，碰撞球整片飘到头顶上方，弹簧链的锚点也跟着跑出体外。
        restLocal = model.bones.enumerated().map { index, bone in
            let parent = parentIndices[index]
            guard parent >= 0, parent < model.bones.count else { return bone.position }
            return bone.position - model.bones[parent].position
        }
        restWorldPos = [SIMD3<Float>](repeating: .zero, count: boneCount)
        worldPos = [SIMD3<Float>](repeating: .zero, count: boneCount)
        poseQuat = [simd_quatf](repeating: mmdIdentityQuaternion, count: boneCount)
        solvedQuat = [simd_quatf](repeating: mmdIdentityQuaternion, count: boneCount)

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
            worldPos[index] = restWorldPos[index]
        }

        ikBones.removeAll()
        for (index, bone) in model.bones.enumerated() {
            guard let ik = bone.ik, ik.targetIndex >= 0 else { continue }
            ikBones.insert(index)
            if ik.targetIndex < boneCount { ikBones.insert(ik.targetIndex) }
            for link in ik.links where link.boneIndex >= 0 && link.boneIndex < boneCount {
                ikBones.insert(link.boneIndex)
            }
        }

        buildColliders(model: model)
        buildChains(model: model)
        protectedDynamicBodyCount = 0
        protectedBoneSamples = []
        buildBulletWorld(model: model)
        if protectedDynamicBodyCount > 0 {
            MMDLog.shared.info("Physics: \(protectedDynamicBodyCount) rigid bodies on face/core bones kept kinematic"
                               + (protectedBoneSamples.isEmpty ? "" : " (\(protectedBoneSamples.joined(separator: ", ")))"),
                               category: "Physics")
        }
        reset()

        MMDLog.shared.info("Physics: \(clothChainCount) chains / \(drivenBoneCount) cloth bones, "
                           + "\(colliderCount) colliders, \(solvedRigidBodyCount) rigid bodies, "
                           + "\(solvedJointCount) joints, \(ikBones.count) IK bones",
                           category: "Physics")
        if !chainSamples.isEmpty {
            MMDLog.shared.info("Physics chains: " + chainSamples.joined(separator: ", "),
                               category: "Physics")
        }
    }

    // MARK: - Colliders

    /// One collision sphere on a body bone.
    ///
    /// A single capsule per limb has one radius for its whole length, so a
    /// thigh is either too fat at the knee or too thin at the hip — the hem
    /// clips through the gap in both cases. A chain of spheres lets the radius
    /// follow the limb, and the radius is measured from the mesh instead of
    /// guessed from the model height.
    private struct ColliderSphere {
        var bone: Int
        /// Centre in the bone's frame (bones carry no rest rotation, so this
        /// is a plain offset from the bone's rest world position).
        var offset: SIMD3<Float>
        var radius: Float
    }

    private func buildColliders(model: PMXModel) {
        colliderSpheres.removeAll()
        let height = modelHeight

        func first(_ keys: [String], side: Int = 0) -> Int {
            for (index, bone) in model.bones.enumerated() {
                let lower = (bone.name + " " + bone.nameEn).lowercased()
                guard keys.contains(where: { lower.contains($0) }) else { continue }
                if side != 0 {
                    guard Self.sideSign(lower) == side else { continue }
                }
                return index
            }
            return -1
        }

        // Vertices bucketed by every bone that claims at least 15% of them, in
        // one pass. A skirt panel usually keeps a slice of its weight on the
        // thigh, so a segment has to look at both of its bones.
        var byBone = [Int: [Int]]()
        for (index, vertex) in model.vertices.enumerated() {
            for slot in 0..<4 where vertex.boneWeights[slot] > 0.15 {
                let bone = Int(vertex.boneIndices[slot])
                guard bone >= 0 && bone < boneCount else { continue }
                byBone[bone, default: []].append(index)
            }
        }

        /// 65th percentile distance from the bone axis. The mean is pulled
        /// around by a handful of skirt verts; the max is worse. 65% is the
        /// knee of the distribution for a limb.
        func meshRadius(_ boneA: Int, _ boneB: Int,
                        _ start: SIMD3<Float>, _ axis: SIMD3<Float>, _ length: Float,
                        _ t0: Float, _ t1: Float, fallback: Float) -> Float {
            var samples: [Float] = []
            var seen = Set<Int>()
            for bone in [boneA, boneB] where bone >= 0 {
                for vertex in byBone[bone] ?? [] where seen.insert(vertex).inserted {
                    let relative = model.vertices[vertex].position - start
                    let t = simd_dot(relative, axis) / max(length, 1e-5)
                    guard t >= t0 - 0.1 && t <= t1 + 0.1 else { continue }
                    samples.append(simd_length(relative - axis * simd_dot(relative, axis)))
                }
            }
            guard samples.count >= 10 else { return fallback }
            samples.sort()
            let pick = min(samples.count - 1, Int(Float(samples.count) * 0.65))
            // Hard ceiling: cloth that keeps a slice of thigh weight sits well
            // outside the leg, and letting it set the radius inflates the
            // collider until the skirt is pushed away from the body.
            return min(samples[pick], height * 0.10)
        }

        func addSegment(_ boneA: Int, _ boneB: Int, pieces: Int, fallback: Float) {
            guard boneA >= 0, boneA < restWorldPos.count else { return }
            let start = restWorldPos[boneA]
            let target = (boneB >= 0 && boneB < restWorldPos.count) ? restWorldPos[boneB] : start
            var direction = target - start
            var length = simd_length(direction)
            if length < 1e-5 {
                // Head and similar zero-length anchors: aim up so the spheres
                // still cover a volume instead of stacking on one point.
                direction = SIMD3<Float>(0, 1, 0)
                length = max(height * 0.05, 0.1)
            }
            direction /= length

            for piece in 0..<pieces {
                let t0 = Float(piece) / Float(pieces)
                let t1 = Float(piece + 1) / Float(pieces)
                let centre = start + direction * (length * (t0 + t1) * 0.5)
                let radius = meshRadius(boneA, boneB, start, direction, length,
                                        t0, t1, fallback: fallback)
                colliderSpheres.append(ColliderSphere(bone: boneA,
                                                      offset: centre - start,
                                                      radius: max(height * 0.008, radius)))
            }
        }

        let hips = first(["下半身", "lowerbody", "lower body", "hips", "hip", "pelvis", "腰"])
        let chest = first(["上半身2", "upperbody2", "upper body2", "chest", "胸", "上半身", "upperbody", "spine"])
        let head = first(["頭", "head"])
        let neck = first(["首", "neck"])
        addSegment(hips, chest, pieces: 4, fallback: height * 0.070)
        addSegment(head, head, pieces: 2, fallback: height * 0.058)
        addSegment(neck, head, pieces: 2, fallback: height * 0.030)

        for side in [-1, 1] {
            let shoulder = first(["肩", "shoulder", "clavicle"], side: side)
            let upperArm = first(["腕", "upperarm", "upper arm", "arm"], side: side)
            let elbow = first(["ひじ", "肘", "elbow", "forearm"], side: side)
            let wrist = first(["手首", "wrist", "hand"], side: side)
            let thigh = first(["もも", "thigh", "upleg", "upperleg", "大腿"], side: side)
            let knee = first(["ひざ", "knee", "shin", "calf", "すね", "小腿"], side: side)
            let ankle = first(["足首", "ankle", "foot", "足"], side: side)

            if shoulder >= 0 && upperArm >= 0 && upperArm != shoulder {
                addSegment(shoulder, upperArm, pieces: 2, fallback: height * 0.030)
            }
            if upperArm >= 0 && elbow >= 0 && elbow != upperArm {
                addSegment(upperArm, elbow, pieces: 3, fallback: height * 0.028)
            }
            if elbow >= 0 && wrist >= 0 && wrist != elbow {
                addSegment(elbow, wrist, pieces: 3, fallback: height * 0.022)
            }
            if thigh >= 0 && knee >= 0 {
                addSegment(thigh, knee, pieces: 3, fallback: height * 0.042)
            }
            if knee >= 0 && ankle >= 0 {
                addSegment(knee, ankle, pieces: 3, fallback: height * 0.034)
            }
        }
        colliderCount = colliderSpheres.count
    }

    private static func sideSign(_ lower: String) -> Int {
        let left = lower.contains("左") || lower.contains("left") || lower.contains("_l")
            || lower.hasPrefix("l_") || lower.contains(" l ") || lower.hasSuffix(" l")
            || lower.contains(".l") || lower.contains("_l_")
        if left { return -1 }
        let right = lower.contains("右") || lower.contains("right") || lower.contains("_r")
            || lower.hasPrefix("r_") || lower.contains(" r ") || lower.hasSuffix(" r")
            || lower.contains(".r") || lower.contains("_r_")
        if right { return 1 }
        return 0
    }

    // MARK: - Chain detection

    /// Builds the secondary-motion chains.
    ///
    /// Name matching alone is not enough: a converted Genshin rig may call its
    /// sash `Bip001 Accessory 04` or `Bone.017`, and then nothing moves at all
    /// — the "hard cardboard" complaint. So a bone is treated as secondary
    /// when it is *structurally* dangling (nothing below it belongs to the
    /// humanoid skeleton) as well as when its name says skirt/hair/ribbon.
    /// Both rules are skipped when the rig does not name a single humanoid
    /// bone, because then "dangling" would include the arms and legs.
    private func buildChains(model: PMXModel) {
        chains.removeAll()
        drivenBoneCount = 0
        clothChainCount = 0
        chainKindSummary.removeAll()
        chainSamples.removeAll()
        guard boneCount > 0 else { return }

        var isCore = [Bool](repeating: false, count: boneCount)
        var coreCount = 0
        for index in 0..<boneCount {
            let bone = model.bones[index]
            let lower = (bone.name + " " + bone.nameEn).lowercased()
            // "頭髪" is hair, not head: a cloth keyword wins over a humanoid
            // marker, otherwise every hair strand under the head bone is
            // classified as skeleton and never sways.
            let clothNamed = Self.clothKeywords.contains(where: { lower.contains($0) })
            let humanoid = Self.isHumanoidDeformBone(bone) && !clothNamed
            if ikBones.contains(index) || humanoid || Self.isHelperBone(lower) {
                isCore[index] = true
                coreCount += 1
            }
        }

        // A bone that owns a core bone deeper in its subtree belongs to the
        // skeleton too (the armature root, an accessory holder), so it must
        // never be treated as cloth.
        var hasCoreBelow = [Bool](repeating: false, count: boneCount)
        for index in topoOrder.reversed() {
            for child in childIndices[index] where isCore[child] || hasCoreBelow[child] {
                hasCoreBelow[index] = true
            }
        }
        let trustGeometry = coreCount >= 6

        // How many vertices depend on a bone, own plus subtree. A control bone
        // (操作中心, a dummy, an IK target) owns none, and rotating it can only
        // corrupt the rig — never the cloth. This is the filter that keeps a
        // 911-bone model from feeding 600 "cloth" bones into the solver.
        var skinnedBelow = [Int](repeating: 0, count: boneCount)
        for vertex in model.vertices {
            for slot in 0..<4 {
                guard vertex.boneWeights[slot] > 0.02 else { continue }
                let bone = Int(vertex.boneIndices[slot])
                guard bone >= 0, bone < boneCount else { continue }
                skinnedBelow[bone] += 1
            }
        }
        for index in topoOrder.reversed() {
            let parent = parentIndices[index]
            if parent >= 0 { skinnedBelow[parent] += skinnedBelow[index] }
        }

        var secondary = Set<Int>()
        for index in 0..<boneCount {
            let bone = model.bones[index]
            let lower = (bone.name + " " + bone.nameEn).lowercased()
            if isCore[index] || hasCoreBelow[index] { continue }
            if Self.faceKeywords.contains(where: { lower.contains($0) }) { continue }
            if Self.rigidKeywords.contains(where: { lower.contains($0) }) { continue }
            // Nothing is skinned to it, so it cannot be cloth.
            if skinnedBelow[index] < 4 { continue }
            let named = Self.clothKeywords.contains(where: { lower.contains($0) })
            if named || trustGeometry { secondary.insert(index) }
        }
        guard !secondary.isEmpty else { return }

        // Chains are *paths*, not subtrees. A skirt root has one child per
        // panel and hair forks at every strand; flattening a subtree into a
        // single array put distance constraints between bones that are not
        // linked at all, and the solver tore the garment into spikes. A bone
        // extends its parent's chain only when it is that chain's current tip,
        // otherwise it starts a new chain hanging off that bone.
        var depth = [Int](repeating: 0, count: boneCount)
        for index in topoOrder {
            let parent = parentIndices[index]
            depth[index] = parent >= 0 ? depth[parent] + 1 : 0
        }
        let ordered = secondary.sorted { depth[$0] < depth[$1] }
        var chainOf = [Int: Int]()
        var bonesOf: [[Int]] = []
        var lastOf: [Int] = []
        for bone in ordered {
            let parent = parentIndices[bone]
            if parent >= 0, let chain = chainOf[parent], lastOf[chain] == parent {
                bonesOf[chain].append(bone)
                chainOf[bone] = chain
                lastOf[chain] = bone
            } else {
                bonesOf.append([bone])
                lastOf.append(bone)
                chainOf[bone] = bonesOf.count - 1
            }
        }
        guard !bonesOf.isEmpty else { return }

        let minSegment = max(0.004, modelHeight * 0.0015)
        let minChain = max(0.02, modelHeight * 0.012)
        var kindCounts: [String: Int] = [:]

        for bones in bonesOf where !bones.isEmpty && bones.count <= 16 {
            guard let root = bones.first else { continue }
            let rootPos = restWorldPos[root]
            let lower = (model.bones[root].name + " " + model.bones[root].nameEn).lowercased()
            let heightFraction = (rootPos.y - floorY) / max(0.001, modelHeight)
            let kind = Self.chainKind(lower, heightFraction: heightFraction)

            var links: [Link] = []
            links.reserveCapacity(bones.count)
            var total: Float = 0

            for (i, bone) in bones.enumerated() {
                var tail: SIMD3<Float>? = nil
                if i + 1 < bones.count {
                    tail = restWorldPos[bones[i + 1]]
                } else if let child = childIndices[bone].first {
                    // A procedural child can sit on the other side of the
                    // model; using it as the tip stretches the last link into
                    // the spikes seen on skirts.
                    let delta = restWorldPos[child] - restWorldPos[bone]
                    let limit = max(modelHeight * 0.08, links.last.map { $0.length * 4 } ?? 0)
                    if simd_length(delta) <= limit { tail = restWorldPos[child] }
                }
                var length = modelHeight * 0.02
                var dir = SIMD3<Float>(0, -1, 0)
                if let tail {
                    let delta = tail - restWorldPos[bone]
                    let magnitude = simd_length(delta)
                    if magnitude > 1e-5 {
                        length = magnitude
                        dir = delta / magnitude
                    }
                }
                let clamped = max(minSegment, length)
                let tailPoint = restWorldPos[bone] + dir * clamped
                total += clamped
                let bend = links.last.map { previous in
                    acosf(max(-1, min(1, simd_dot(previous.restDir, dir))))
                } ?? 0
                links.append(Link(bone: bone,
                                  restDir: dir,
                                  bend: bend,
                                  length: clamped,
                                  limitLink: 1,
                                  limitChain: kind.chainLimit,
                                  spring: kind.spring,
                                  damp: 2 * sqrtf(kind.spring) * 0.85,
                                  droop: 0,
                                  drag: kind.drag,
                                  collides: !restsInside(tailPoint),
                                  dir: dir,
                                  omega: .zero))
            }
            guard total >= minChain else { continue }

            // A chain's total swing has to stay inside `chainLimit`, so a
            // 10-link skirt gets ~7° per joint and a 3-link sash gets 25°.
            // Without this a long skirt summed 8 x 19° and folded inside out.
            let perLink = min(kind.linkLimit, kind.chainLimit * 0.9 / Float(links.count))
            for i in links.indices {
                links[i].limitLink = perLink
                // Gravity sags each joint to ~50% of its budget at rest: enough
                // to read as weight, not enough to crush the authored shape.
                // The 1.4 is not a fudge: gravity torque goes as
                // sin(angle to vertical) while the spring goes as sin(angle to
                // pose), so a linear coefficient has to over-drive.
                links[i].droop = links[i].spring * perLink * 1.4
            }

            chains.append(Chain(anchor: parentIndices[root],
                                links: links,
                                kind: kind,
                                name: model.bones[root].name,
                                seeded: false,
                                lastAnchor: .zero,
                                velocity: .zero))
            kindCounts[kind.title, default: 0] += 1
            if chainSamples.count < 8 {
                chainSamples.append("\(model.bones[root].name)×\(links.count)")
            }
        }

        // Keep the budget in depth order: a child chain solved before its
        // anchor would hang off a bone that never moves.
        if chains.reduce(0, { $0 + $1.links.count }) > 480 {
            var budget = 480
            var kept: [Chain] = []
            for chain in chains where chain.links.count <= budget {
                budget -= chain.links.count
                kept.append(chain)
            }
            chains = kept
        }
        drivenBoneCount = chains.reduce(0) { $0 + $1.links.count }
        clothChainCount = chains.count
        chainKindSummary = kindCounts.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    private static func chainKind(_ lower: String, heightFraction: Float) -> ChainKind {
        if lower.contains("skirt") || lower.contains("スカート") || lower.contains("裾")
            || lower.contains("裙") || lower.contains("下摆") || lower.contains("衣摆")
            || lower.contains("dress") || lower.contains("ドレス") || lower.contains("apron") {
            return .skirt
        }
        if lower.contains("ribbon") || lower.contains("リボン") || lower.contains("テープ")
            || lower.contains("飘带") || lower.contains("belt") || lower.contains("ベルト")
            || lower.contains("necktie") || lower.contains("ネクタイ") || lower.contains("领带")
            || lower.contains("strap") || lower.contains("scarf") || lower.contains("マフラー")
            || lower.contains("尾") || lower.contains("带") {
            return .ribbon
        }
        if lower.contains("wing") || lower.contains("羽") || lower.contains("翼") { return .wing }
        if lower.contains("sleeve") || lower.contains("袖") { return .sleeve }
        if lower.contains("hair") || lower.contains("髪") || lower.contains("头发")
            || lower.contains("刘海") || lower.contains("马尾") || lower.contains("辫")
            || lower.contains("ponytail") || lower.contains("braid") { return .hair }
        // No usable name: fall back to where the chain hangs. Anything above
        // the shoulders is hair, anything below the waist is skirt.
        if heightFraction > 0.74 { return .hair }
        if heightFraction < 0.42 { return .skirt }
        return .other
    }

    private static func isHelperBone(_ lower: String) -> Bool {
        helperPrefixes.contains { lower.hasPrefix($0) || lower.contains("_" + $0) }
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

        evaluate(animations: animations)

        var result = animations
        // "PMX 刚体" on a model whose rigid-body section is empty (very common
        // for game-ripped characters) used to do nothing at all. Fall back to
        // the chain solver so the switch is never a no-op.
        //
        // "自动" takes the same decision by itself: a model with a real
        // jointed body chain is simulated by Bullet, which is how the author
        // tuned it, and everything else uses the chain solver.
        let rigidUsable = bulletActive && solvedRigidBodyCount >= 4 && solvedJointCount >= 2
        let useRigid = settings.mode == .rigid || (settings.mode == .auto && rigidUsable)
        let useChains = settings.mode == .secondary || !useRigid
        if useChains && !chains.isEmpty {
            if advance {
                stepChains(settings: settings, dt: dt)
            } else if chains.contains(where: { !$0.seeded }) {
                seedAllChains()
            }
            emitChains(into: &result)
        }

        if useRigid && bulletActive {
            if advance { stepBullet(dt: dt) }
            applyBullet(to: &result, model: model)
        }
        return result
    }

    private func evaluate(animations: [Int: MMDBoneAnimation]) {
        for index in topoOrder {
            let parent = parentIndices[index]
            let animation = animations[index] ?? MMDBoneAnimation()
            let parentPos = parent >= 0 ? worldPos[parent] : .zero
            let parentQuat = parent >= 0 ? poseQuat[parent] : mmdIdentityQuaternion
            worldPos[index] = parentPos + parentQuat.act(restLocal[index] + animation.position)
            let quat = quatNormalize(parentQuat * animation.rotation)
            poseQuat[index] = quat
            solvedQuat[index] = quat
        }
    }

    // MARK: - Chain integration

    /// Angular spring-damper secondary motion.
    ///
    /// Every link owns a *unit direction* and an angular velocity. Gravity,
    /// wind and the anchor's own motion torque the direction away from the
    /// pose the animation gives it; a spring pulls it back. Nothing else is
    /// stored, so there is no position to drift, no length to stretch and no
    /// scale to collapse — the failure mode "the skirt deforms a bit more
    /// every second" is structurally impossible here.
    ///
    /// The previous version integrated world *positions* with Verlet plus a
    /// collision push that wrote back only the positions. Each push therefore
    /// handed the particle a fresh outward velocity, and a hem resting against
    /// a thigh capsule pumped energy at the step rate: the hem jittered,
    /// creased, and crept further out over time.
    private func stepChains(settings: MMDPhysicsSettings, dt: Float) {
        guard !chains.isEmpty else { return }
        if chains.contains(where: { !$0.seeded }) { seedAllChains() }
        guard dt > 0.00001 else { return }

        // Fixed 120 Hz, at most 6 catch-up steps. A slow frame can no longer
        // hand the solver a huge dt and blow the chain apart.
        for index in chains.indices {
            let anchorPos = chains[index].anchor >= 0 ? worldPos[chains[index].anchor] : .zero
            var velocity = (anchorPos - chains[index].lastAnchor) / dt
            let speed = simd_length(velocity)
            // A seek or a teleport must not fling the chain across the scene.
            if speed > 12 { velocity *= 12 / speed }
            var accel = (velocity - chains[index].velocity) / dt
            let accelLength = simd_length(accel)
            if accelLength > 60 { accel *= 60 / accelLength }
            chains[index].velocity = velocity
            chains[index].accel = accel
            chains[index].lastAnchor = anchorPos
        }

        let h: Float = 1.0 / 120.0
        substepAccumulator = min(substepAccumulator + dt, h * 6)
        var steps = 0
        while substepAccumulator >= h && steps < 6 {
            simTime += h
            subStep(settings: settings, h: h, time: simTime)
            substepAccumulator -= h
            steps += 1
        }
    }

    private func seedAllChains() {
        for index in chains.indices {
            var chain = chains[index]
            let anchorPos = chain.anchor >= 0 ? worldPos[chain.anchor] : .zero
            let anchorQuat = chain.anchor >= 0 ? solvedQuat[chain.anchor] : mmdIdentityQuaternion
            seed(&chain, anchorPos: anchorPos, anchorQuat: anchorQuat)
            chains[index] = chain
        }
    }

    private func seed(_ chain: inout Chain, anchorPos: SIMD3<Float>, anchorQuat: simd_quatf) {
        for j in chain.links.indices {
            chain.links[j].dir = anchorQuat.act(chain.links[j].restDir).unit
            chain.links[j].omega = .zero
        }
        chain.lastAnchor = anchorPos
        chain.velocity = .zero
        chain.accel = .zero
        chain.seeded = true
    }

    private func subStep(settings: MMDPhysicsSettings, h: Float, time: Float) {
        let down = SIMD3<Float>(0, -1, 0)
        let windStrength = max(0, settings.wind)
        var windDir = SIMD3<Float>.zero
        if windStrength > 0.001 {
            windDir = SIMD3<Float>(sinf(time * 1.7) * 0.7 + sinf(time * 0.43) * 0.3,
                                   sinf(time * 0.9) * 0.2,
                                   cosf(time * 1.31) * 0.7 + cosf(time * 0.37) * 0.3).unit
        }
        let gravityScale = max(0, settings.gravity) / 0.75
        let dampingScale = max(0.4, min(2.2, settings.damping / 0.35))
        let stiffnessScale = max(0.5, min(2.0, settings.stiffness / 0.4))
        let swingScale = max(0.5, min(1.8, settings.maxAngle / 50))

        for chainIndex in chains.indices {
            var chain = chains[chainIndex]
            let anchorPos = chain.anchor >= 0 ? worldPos[chain.anchor] : .zero
            let anchorQuat = chain.anchor >= 0 ? solvedQuat[chain.anchor] : mmdIdentityQuaternion
            if !chain.seeded {
                seed(&chain, anchorPos: anchorPos, anchorQuat: anchorQuat)
            }
            // Linear velocity of the anchor drives the trailing drag.
            let anchorVel = chain.velocity
            let anchorSpeed = simd_length(anchorVel)
            let trailing: SIMD3<Float> = anchorSpeed > 0.05
                ? -anchorVel / max(anchorSpeed, 1e-5) : SIMD3<Float>.zero

            var head = anchorPos
            var previousDir = anchorQuat.act(chain.links[0].restDir).unit
            for j in chain.links.indices {
                var link = chain.links[j]
                let poseDir = poseQuat[link.bone].act(link.restDir).unit
                let silhouette = anchorQuat.act(link.restDir).unit
                let linkLimit = link.limitLink * swingScale

                var dir = link.dir
                if simd_length_squared(dir) < 0.25 { dir = poseDir }

                var torque = simd_cross(dir, down) * (link.droop * gravityScale)
                if windStrength > 0.001 {
                    torque += simd_cross(dir, windDir) * (link.drag * 8 * windStrength)
                }
                // The faster the body moves, the harder the link is pulled
                // back onto the animated silhouette. A constant spring lets a
                // quick turn leave the hem a whole link behind, which reads as
                // "衣服跟不上动作" and is also when it cuts through a thigh.
                let followBoost = 1 + min(anchorSpeed, 24) * 0.06
                torque += simd_cross(dir, poseDir) * (link.spring * stiffnessScale * followBoost)
                if trailing != SIMD3<Float>.zero {
                    torque += simd_cross(dir, trailing) * (anchorSpeed * link.drag * 4)
                }
                // Inertial kick: the anchor's own acceleration pushes the link
                // the opposite way, which is what a skirt does when its owner
                // starts walking. Without this the hem only ever trails,
                // because gravity and the pose spring are the only forces.
                let accelLength = simd_length(chain.accel)
                if accelLength > 0.05, settings.inertia > 0.001 {
                    let gain = min(accelLength, 40) * 0.05 * settings.inertia
                    torque += simd_cross(dir, -chain.accel / accelLength) * (link.drag * gain)
                }

                var omega = link.omega + torque * h
                // Implicit damping: unconditionally stable for any dt.
                omega /= (1 + link.damp * dampingScale * h)
                let spin = simd_length(omega)
                if spin > 1e-5 {
                    let angle = min(spin * h, 0.5)
                    dir = simd_quatf(angle: angle, axis: omega / spin).act(dir)
                    // Bleed the velocity that was actually *used*, so a
                    // clamped step cannot leave a huge omega behind.
                    omega *= angle / (spin * h)
                }

                // Two hard bounds. The first is the *joint*: this link may
                // bend no more than the authored bend plus its share of the
                // budget away from the link it hangs off, which is what keeps
                // a ribbon from creasing. The second is the *chain*: no link
                // may leave the authored silhouette by more than the chain
                // budget, which is what keeps the skirt from flipping inside
                // out or creeping away over a long take.
                //
                // Both are measured against solved neighbours, not against a
                // fixed rest direction. Bounding every joint against the rest
                // direction (v12.7) pinned the whole chain onto one cone and
                // made it project out of the body like a board.
                dir = clampDir(dir, to: previousDir, maxAngle: link.bend + linkLimit)
                dir = clampDir(dir, to: silhouette, maxAngle: link.limitChain * swingScale)

                if link.collides {
                    // Sample along the link, not only at its tail. A hem that
                    // touches a thigh at 60% of the link still has its tip
                    // inside the leg, and pushing the tip alone lets the
                    // middle swim through the body — the visible "穿模".
                    var collided = false
                    for _ in 0..<2 {
                        var hit = false
                        for fraction in [Float(0.4), 0.75, 1.0] {
                            let sample = head + dir * (link.length * fraction)
                            let pushed = pushOut(sample)
                            guard simd_length_squared(pushed - sample) > 1e-8 else { continue }
                            var corrected = (pushed - head).unit
                            if corrected == SIMD3<Float>.zero { corrected = dir }
                            corrected = clampDir(corrected, to: previousDir,
                                                 maxAngle: link.bend + linkLimit)
                            corrected = clampDir(corrected, to: silhouette,
                                                 maxAngle: link.limitChain * swingScale)
                            // Never trade a body clip for a silhouette break:
                            // if the clamp undid the push, keep the push and
                            // let the cone absorb it on the next step.
                            if simd_length_squared((head + corrected * link.length) - pushed) > 1e-6 {
                                corrected = (pushed - head).unit
                            }
                            dir = corrected
                            hit = true
                            collided = true
                            break
                        }
                        if !hit { break }
                    }
                    // Sliding contact must bleed energy, otherwise the hem
                    // vibrates against the collider at the step rate.
                    if collided { omega *= 0.55 }
                }

                link.dir = dir.unit
                link.omega = omega
                chain.links[j] = link
                previousDir = link.dir
                head += link.dir * link.length
            }
            chains[chainIndex] = chain
        }
    }

    /// Rotates `dir` back onto `ref` when the angle between them exceeds
    /// `maxAngle`, keeping the azimuth. This is a *cone claw*, not a
    /// renormalisation: the direction keeps whatever freedom it had inside
    /// the cone, which is what stops a chain from folding flat.
    @inline(__always)
    private func clampDir(_ dir: SIMD3<Float>, to ref: SIMD3<Float>, maxAngle: Float) -> SIMD3<Float> {
        let cosine = max(-1, min(1, simd_dot(dir, ref)))
        guard acosf(cosine) > maxAngle else { return dir }
        let axis = simd_cross(ref, dir)
        let axisLength = simd_length(axis)
        guard axisLength > 1e-6 else { return ref }
        return simd_quatf(angle: maxAngle, axis: axis / axisLength).act(ref).unit
    }

    private func pushOut(_ point: SIMD3<Float>) -> SIMD3<Float> {
        var result = point
        for sphere in colliderSpheres {
            let bone = sphere.bone
            guard bone >= 0 && bone < boneCount else { continue }
            // Posed, not solved: a collider belongs to the body, and letting a
            // cloth bone drag its own collider around would chase the very
            // particles it is supposed to stop.
            let centre = worldPos[bone] + poseQuat[bone].act(sphere.offset)
            let offset = result - centre
            let distanceSquared = simd_dot(offset, offset)
            // 4% of skin clearance: cloth is a surface, not a point, and the
            // 65th-percentile mesh radius already sits inside the silhouette.
            let radius = sphere.radius * 1.04
            guard distanceSquared < radius * radius else { continue }
            let distance = sqrt(distanceSquared)
            let normal = distance > 1e-5 ? offset / distance : SIMD3<Float>(0, 0, 1)
            result = centre + normal * radius
        }
        let floor = floorY + modelHeight * 0.002
        if result.y < floor { result.y = floor }
        return result
    }

    /// True when a point's rest position already lies inside a body capsule.
    /// A skirt root sits on the hips; pushing it out would inflate the whole
    /// skirt, so those particles opt out of collision.
    private func restsInside(_ point: SIMD3<Float>) -> Bool {
        for sphere in colliderSpheres {
            let bone = sphere.bone
            guard bone >= 0 && bone < restWorldPos.count else { continue }
            let centre = restWorldPos[bone] + sphere.offset
            if simd_length(point - centre) < sphere.radius * 1.05 { return true }
        }
        return false
    }

    /// Turns the solved directions into bone rotations.
    ///
    /// The rotation is the shortest arc that maps the bone's rest direction
    /// onto the solved one, expressed in the parent's frame — a flat sash
    /// keeps its roll instead of twisting on its own axis.
    private func emitChains(into result: inout [Int: MMDBoneAnimation]) {
        for chain in chains {
            guard chain.seeded else { continue }
            var parentQuat = chain.anchor >= 0 ? solvedQuat[chain.anchor] : mmdIdentityQuaternion
            var head = chain.anchor >= 0 ? worldPos[chain.anchor] : .zero
            for j in chain.links.indices {
                let link = chain.links[j]
                let bone = link.bone
                // Keep whatever the animation asked for and add only the
                // *difference* between the solved direction and the posed one.
                // Composing the correction onto the animated rotation keeps
                // the bone's roll, and means that a link sitting exactly on
                // its pose is bit-for-bit the pose — switching physics on can
                // no longer restyle a bone that is not moving.
                let animated = result[bone]?.rotation ?? mmdIdentityQuaternion
                let posedDir = animated.act(link.restDir).unit
                let targetDir = parentQuat.inverse.act(link.dir).unit
                let correction = quatBetween(posedDir == .zero ? link.restDir : posedDir,
                                             targetDir == .zero ? link.restDir : targetDir)
                let rotation = quatNormalize(correction * animated)
                parentQuat = quatNormalize(parentQuat * rotation)
                solvedQuat[bone] = parentQuat
                worldPos[bone] = head
                var animation = result[bone] ?? MMDBoneAnimation()
                animation.rotation = rotation
                result[bone] = animation
                head += link.dir * link.length
            }
        }
    }

    // MARK: - Bullet rigid bodies

    /// One PMX rigid body mapped into Bullet.
    ///
    /// PMX stores a body's rest transform in world space and binds it to a
    /// bone; the solver needs the same relation expressed in the bone's local
    /// frame, so both directions are precomputed once at load time.
    private struct BulletBody {
        var handle: Int32
        var bone: Int
        var dynamic: Bool
        var mode: UInt8
        var restPosition: SIMD3<Float>
        var restRotation: simd_quatf
        /// R_rest expressed in the bone's frame: R = B ∘ offset.
        var offsetPosition: SIMD3<Float>
        var offsetRotation: simd_quatf
        /// B_rest expressed in the body's frame: B = R ∘ inverse.
        var inversePosition: SIMD3<Float>
        var inverseRotation: simd_quatf
        var movable: Bool
    }

    private var bulletWorld: OpaquePointer?
    private var bulletBodies: [BulletBody] = []
    /// True when the model ships rigid bodies and Bullet is driving them.
    private(set) var bulletActive = false

    private func destroyBulletWorld() {
        if let world = bulletWorld { MMDPhysWorldDestroy(world) }
        bulletWorld = nil
        bulletBodies.removeAll()
        bulletActive = false
    }

    /// Builds the Bullet scene from the PMX rigid-body and joint sections.
    ///
    /// This is the whole reason the project carries Bullet: a PMX body is
    /// authored against Bullet 2.x, so shape, mass, damping, restitution,
    /// friction, collision group/mask and the 6DOF spring joints all map one
    /// to one. Re-deriving them by hand is what produced the "skirt stretches
    /// more every second" behaviour.
    private func buildBulletWorld(model: PMXModel) {
        destroyBulletWorld()
        solvedRigidBodyCount = 0
        solvedJointCount = 0
        rigidBoneIndices.removeAll()

        let bodies = model.rigidBodies
        guard !bodies.isEmpty else { return }
        guard let world = MMDPhysWorldCreate(-98.0) else { return }
        bulletWorld = world

        var records: [BulletBody] = []
        records.reserveCapacity(bodies.count)
        var handleForBody: [Int: Int32] = [:]
        var slotForHandle: [Int32: Int] = [:]

        for (index, body) in bodies.enumerated() {
            let bone = (body.boneIndex >= 0 && body.boneIndex < boneCount) ? body.boneIndex : -1
            let boneRest = bone >= 0 ? restWorldPos[bone] : .zero
            // PMX 里的刚体旋转按规范存的是弧度，不是角度；当成角度再转一次
            // 只会在 0 附近抖动，裙摆刚体的初始朝向就被抹平了。
            let bodyRotation = quatFromEuler(body.rotation)
            // Mode 0 follows its bone and exists only to be collided with;
            // modes 1 and 2 are simulated and write back.
            //
            // XR / ZZZ conversions also put bodies on face and core bones. A
            // dynamic body there overrides the clip every frame: the eyes roll
            // and the brows jump while the character is standing still. Those
            // bodies stay kinematic — still collidable, never authoritative.
            let boneText = bone >= 0 ? (model.bones[bone].name + " " + model.bones[bone].nameEn).lowercased() : ""
            let protectedBone = bone >= 0 &&
                (Self.isHumanoidDeformBone(model.bones[bone]) ||
                 Self.faceKeywords.contains(where: { boneText.contains($0) }) ||
                 ikBones.contains(bone))
            if protectedBone && body.mode >= 1 {
                protectedDynamicBodyCount += 1
                if protectedBoneSamples.count < 6 {
                    protectedBoneSamples.append(model.bones[bone].name)
                }
            }
            let dynamic = body.mode >= 1 && bone >= 0 && !protectedBone
            let mass: Float = dynamic ? max(0.001, body.mass) : 0
            // PMX group is 0...15 and the mask is a bitfield over those same
            // groups, which is exactly Bullet's (group, mask) pair — no
            // translation needed beyond turning the index into a bit.
            let group = Int32(1 << min(15, Int(body.group)))

            let handle = MMDPhysAddBody(world,
                                        Int32(min(2, Int(body.shape))),
                                        [body.size.x, body.size.y, body.size.z],
                                        Int32(bone),
                                        group,
                                        Int32(body.collisionMask),
                                        mass,
                                        body.linearDamping,
                                        body.angularDamping,
                                        body.restitution,
                                        body.friction,
                                        [body.position.x, body.position.y, body.position.z],
                                        [bodyRotation.imag.x, bodyRotation.imag.y,
                                         bodyRotation.imag.z, bodyRotation.real])
            guard handle >= 0 else { continue }
            handleForBody[index] = handle
            slotForHandle[handle] = records.count

            // PMX bones carry translation only, so the rest pose of every bone
            // is an identity rotation and the offset is a plain subtraction.
            let offsetPosition = body.position - boneRest
            let inversePosition = bodyRotation.inverse.act(boneRest - body.position)

            records.append(BulletBody(handle: handle,
                                      bone: bone,
                                      dynamic: dynamic,
                                      mode: body.mode,
                                      restPosition: body.position,
                                      restRotation: bodyRotation,
                                      offsetPosition: offsetPosition,
                                      offsetRotation: bodyRotation,
                                      inversePosition: inversePosition,
                                      inverseRotation: bodyRotation.inverse,
                                      movable: bone >= 0 ? model.bones[bone].isMovable : false))
            if dynamic { rigidBoneIndices.insert(bone) }
            if dynamic { solvedRigidBodyCount += 1 }
        }

        for joint in model.joints {
            guard joint.bodyB >= 0, let handleB = handleForBody[joint.bodyB],
                  let slotB = slotForHandle[handleB] else { continue }
            let handleA = joint.bodyA >= 0 ? (handleForBody[joint.bodyA] ?? -1) : -1

            // 同刚体：关节旋转同样是弧度。
            let jointRotation = quatFromEuler(joint.rotation)
            let bodyB = bodies[joint.bodyB]
            let frameB = Self.localFrame(position: joint.position,
                                         rotation: jointRotation,
                                         bodyPosition: bodyB.position,
                                         bodyRotation: records[slotB].restRotation)
            var frameA: (SIMD3<Float>, simd_quatf) = (.zero, mmdIdentityQuaternion)
            if handleA >= 0, let slotA = slotForHandle[handleA], joint.bodyA < bodies.count {
                frameA = Self.localFrame(position: joint.position,
                                         rotation: jointRotation,
                                         bodyPosition: bodies[joint.bodyA].position,
                                         bodyRotation: records[slotA].restRotation)
            }

            // A PMX joint whose bounds are all zero means "no limit"; Bullet
            // would otherwise lock that axis at zero travel.
            let travel = Self.jointBounds(joint.limitLower, joint.limitUpper,
                                          unlimited: modelHeight)
            let swing = Self.jointBounds(joint.limitLowerAngle, joint.limitUpperAngle,
                                         unlimited: .pi)

            _ = MMDPhysAdd6DofJoint(world, handleA, handleB,
                                    frameA.0.f3, frameA.1.f4,
                                    frameB.0.f3, frameB.1.f4,
                                    travel.0.f3, travel.1.f3,
                                    swing.0.f3, swing.1.f3,
                                    joint.springPosition.f3, joint.springRotation.f3)
            solvedJointCount += 1
        }

        bulletBodies = records
        // A model whose bodies are all mode 0 has nothing to simulate; the
        // colliders stay in the world for the chain solver to reuse, but the
        // "rigid body" switch must fall back rather than look broken.
        bulletActive = records.contains(where: { $0.dynamic })
        totalRigidBodyCount = records.count
    }

    private static func localFrame(position: SIMD3<Float>, rotation: simd_quatf,
                                   bodyPosition: SIMD3<Float>, bodyRotation: simd_quatf)
        -> (SIMD3<Float>, simd_quatf) {
        (bodyRotation.inverse.act(position - bodyPosition),
         quatNormalize(bodyRotation.inverse * rotation))
    }

    private static func jointBounds(_ lower: SIMD3<Float>, _ upper: SIMD3<Float>,
                                    unlimited: Float) -> (SIMD3<Float>, SIMD3<Float>) {
        if lower == .zero && upper == .zero {
            return (SIMD3<Float>(repeating: -unlimited), SIMD3<Float>(repeating: unlimited))
        }
        // Guard against a malformed file with lower > upper, which Bullet
        // treats as a fully locked joint.
        return (simd_min(lower, upper), simd_max(lower, upper))
    }

    private func stepBullet(dt: Float) {
        guard let world = bulletWorld else { return }
        guard dt > 0.00001 else { return }

        // Kinematic bodies are placed on their bone before the solve; Bullet
        // derives their velocity from the delta, which is what lets a moving
        // thigh sweep a skirt panel out of the way.
        for record in bulletBodies where !record.dynamic && record.bone >= 0 {
            let bone = record.bone
            let boneQuat = solvedQuat[bone]
            let position = worldPos[bone] + boneQuat.act(record.offsetPosition)
            let rotation = quatNormalize(boneQuat * record.offsetRotation)
            MMDPhysSetBodyTransform(world, record.handle, position.f3, rotation.f4)
        }

        // 120 Hz fixed step, at most four catch-up steps. A 4K export frame
        // that took 60 ms must not be handed to Bullet as a single 60 ms step.
        MMDPhysWorldStep(world, min(dt, 0.1), 4, 1.0 / 120.0)
    }

    private func applyBullet(to animations: inout [Int: MMDBoneAnimation], model: PMXModel) {
        guard let world = bulletWorld else { return }
        // Topological order: a child body's bone transform has to be derived
        // from its parent's *already updated* world rotation, otherwise two
        // simulated bodies in a chain read a stale parent and shear apart.
        let ordered = bulletBodies.enumerated()
            .filter { $0.element.dynamic }
            .sorted { depth(of: $0.element.bone) < depth(of: $1.element.bone) }

        for (_, record) in ordered {
            let bone = record.bone
            guard bone >= 0 && bone < boneCount else { continue }

            var position = [Float](repeating: 0, count: 3)
            var rotation = [Float](repeating: 0, count: 4)
            position.withUnsafeMutableBufferPointer { p in
                rotation.withUnsafeMutableBufferPointer { r in
                    MMDPhysGetBodyTransform(world, record.handle, p.baseAddress, r.baseAddress)
                }
            }
            let bodyQuat = simd_quatf(ix: rotation[0], iy: rotation[1],
                                      iz: rotation[2], r: rotation[3])
            guard bodyQuat.real.isFinite, simd_length(bodyQuat.imag).isFinite else { continue }
            let bodyPos = SIMD3<Float>(position[0], position[1], position[2])
            guard bodyPos.x.isFinite, bodyPos.y.isFinite, bodyPos.z.isFinite else { continue }

            let bonePos = bodyPos + bodyQuat.act(record.inversePosition)
            let boneQuat = quatNormalize(bodyQuat * record.inverseRotation)
            let parent = parentIndices[bone]
            let parentQuat = parent >= 0 ? solvedQuat[parent] : mmdIdentityQuaternion

            var animation = animations[bone] ?? MMDBoneAnimation()
            animation.rotation = quatNormalize(parentQuat.inverse * boneQuat)

            // Mode 2 is "physics + bone position alignment": the body may also
            // drag the bone along, which is how a long skirt keeps its hem on
            // the authored shape. Bound it so a solver hiccup cannot pull a
            // bone out of the model.
            if record.mode >= 2 && record.movable {
                let parentPos = parent >= 0 ? worldPos[parent] : .zero
                var local = parentQuat.inverse.act(bonePos - parentPos)
                local -= restLocal[bone]
                let limit = max(0.05, modelHeight * 0.02)
                let distance = simd_length(local)
                if distance > limit { local *= limit / distance }
                animation.position = local
            }

            animations[bone] = animation
            solvedQuat[bone] = boneQuat
            worldPos[bone] = bonePos
        }
    }

    private func depth(of bone: Int) -> Int {
        guard bone >= 0 && bone < parentIndices.count else { return 0 }
        var level = 0
        var cursor = bone
        while cursor >= 0 && level < 256 {
            cursor = parentIndices[cursor]
            level += 1
        }
        return level
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

/// Small bridges to the C surface, which takes plain float arrays.
extension SIMD3 where Scalar == Float {
    var f3: [Float] { [x, y, z] }
}

extension simd_quatf {
    var f4: [Float] { [imag.x, imag.y, imag.z, real] }
}
