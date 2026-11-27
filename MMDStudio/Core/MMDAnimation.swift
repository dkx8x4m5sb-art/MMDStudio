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

/// 为 PMX 骨架计算蒙皮矩阵。
///
/// 蒙皮矩阵来自一次朴素的拓扑遍历（父骨严格排在子骨之前），
/// 这也是对任何 PMX 文件都安全的唯一顺序。
/// 追加/继承读取源骨骼的*局部*姿势，与 MMD 的行为一致。
///
/// IK 是一遍 CCD：累计欧拉角、按 PMX 链限位夹取，再把世界空间
/// 修正量经*父骨*旋转转换回去。这里若改用链自身的旋转，膝盖就会
/// 绕一根倾斜的轴转动 —— 开启 IK 时看到的腿向外撇，
/// 正是这个原因。
final class MMDSkeleton {

    let boneCount: Int
    private let parentIndices: [Int]
    private let restLocal: [SIMD3<Float>]
    /// 严格的拓扑顺序：每个父骨都排在它的子骨之前。
    private let order: [Int]
    private let orderRank: [Int]
    private let inverseBind: [simd_float4x4]
    let restWorld: [simd_float4x4]
    private let childIndices: [[Int]]
    /// 子树列表按需构建。只有 IK 链需要它，若为 3000 根骨骼的模型
    /// 预先建全量后代表，会白白吃掉几 MB 内存。
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

        // 纯拓扑顺序。按 PMX 变形层分组，纸面上更接近 MMD，
        // 但「子骨在第 0 层、父骨在第 1 层」是合法写法，
        // 把第 0 层整体提前会破坏「父先于子」的保证：
        // 子骨读到的是单位世界矩阵，整条肢体
        // 会瞬间塌到原点。正确性优先于层次细节。
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

    // MARK: - 求值

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

    /// 求值单根骨骼并写入它的世界矩阵。调用时 `worlds` 中必须
    /// 已有合法的父骨结果；所有调用方都按 `order` 遍历。
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
            // MMD 的追加/继承定义在源骨骼的*局部*姿势上。若改读它的
            // 世界增量，结果就取决于源骨在这一帧里是否已被求值，
            // 整个链条会被重排，裙子、领子和头发
            // 因此从身上脱开。
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

    /// 按拓扑顺序重新求值 `index` 及其全部后代。
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

    // MARK: - IK 求解

    private func solveIK(animations: inout [Int: MMDBoneAnimation], model: PMXModel,
                         worlds: inout [simd_float4x4]) {
        // 设一个硬上限，避免病态文件（几百条 IK 链、每条 255 次
        // 迭代）把渲染线程拖死。
        var budget = 120_000

        for (ikIndex, bone) in model.bones.enumerated() {
            guard let ik = bone.ik, ik.targetIndex >= 0, ik.targetIndex < boneCount,
                  !ik.links.isEmpty else { continue }
            guard budget > 0 else { break }

            // PMX 作者常用 40..255 次迭代；上限压得太低，脚就够不到
            // 目标（俗称「软膝盖」）。两节腿在常见的 1 弧度单位角下，
            // 48 次已经够用，下面的求值预算
            // 仍能保住帧时间。
            let iterations = max(1, min(48, ik.iterations))
            let stepLimit = max(0.15, min(1.2, ik.angleLimit > 0 ? ik.angleLimit : 1.0))

            // 每条链保存欧拉角状态，单位是度。MMD 的限位就是按欧拉角
            // 写的；若一路用四元数累加、最后才夹取，
            // 这些限位等于完全失效。
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
                        // 完全折叠时：取一根稳定的垂线，避免
                        // 链条塌到自己身上。
                        let fallback = abs(current.z) < 0.9 ? SIMD3<Float>(0, 0, 1)
                                                           : SIMD3<Float>(1, 0, 0)
                        let alt = simd_cross(current, fallback)
                        if simd_length(alt) > 0.000001 { axis = alt / simd_length(alt) }
                    }

                    let step = min(angle, stepLimit)
                    let worldDelta = simd_quatf(angle: step, axis: axis)

                    // 骨骼的局部旋转位于父骨空间，所以世界修正量
                    // 必须用父骨旋转做共轭变换，
                    // 而不是用链自身的旋转。
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
                        // 膝盖是铰链。CCD 加进来的任何 Y/Z 旋转
                        // 都会把小横向侧面折过去。没有作者写的限位时，
                        // 弯曲方向无从判断（取决于模型朝向），
                        // 因此两个方向都保留，但
                        // 侧向轴被去掉。
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

/// 合并界面上的 Morph 权重与 VMD 的 Morph 轨道。
final class MMDMorphController {

    static func resolvedWeights(model: PMXModel, base: [Float]) -> [Float] {
        guard !model.morphs.isEmpty else { return base }
        var weights = base.count == model.morphs.count ? base : [Float](repeating: 0, count: model.morphs.count)
        // 组 Morph 向下传播几层即可；PMX 的组通常很浅。
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

// MARK: - 人形骨架映射

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

    /// 保守的局部欧拉限位（度）。X 是肘/膝的主弯曲轴，
    /// 其余轴收窄，防止扭转。
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

/// 物理模式。布料模拟默认不开启：许多转换来的 MMD 骨架带着
/// 损坏的刚体或重复的控制骨，在这些模型上强行开启，
/// 就是「裙子乱飞」反馈的来源。
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

/// 布料求解器真正参与测试的一颗碰撞球，导出给调试线框用。
/// 它不是 PMX 刚体 —— 刚体在模型那一侧。
struct MMDPhysicsColliderDebug {
    var bone: Int
    var offset: SIMD3<Float>
    var radius: Float
}

/// 实时二级运动与 PMX 刚体求解器。
///
/// 链式求解器用重力驱动的弹簧-阻尼模型驱动裙摆、飘带、头发和翅膀骨。
/// PMX 动态刚体（模式 2）以球/盒形状积分，带关节弹簧、
/// 地面接触与刚体间碰撞，解算结果再写回绑定的骨骼。
/// 这是一个精简的类 Bullet 近似，
/// 不是 Bullet 约束求解器的逐位移植。
struct MMDPhysicsSettings {
    var mode: MMDPhysicsMode = .auto
    var gravity: Float = 0.75
    var stiffness: Float = 0.4
    var damping: Float = 0.35
    var wind: Float = 0.15
    var inertia: Float = 0.8
    var collision: Bool = true
    /// 单节布料的锥角上限，单位度。链自身的类型会缩放它
    /// （裙摆摆幅最大），所以实际可见的范围更大。
    var maxAngle: Float = 50
    var substeps: Int = 2

    var enabled: Bool { mode != .off }
}

final class MMDSpringPhysics {

    // MARK: - 骨架镜像

    /// 求解器需要每根骨骼当前的世界变换，布料链才能挂在真正的
    /// 父骨上（父骨本身也可能是链条的一节）。
    /// 镜像每帧从姿势重建，对骨骼数组做一次
    /// 拓扑遍历。
    private var boneCount = 0
    private var parentIndices: [Int] = []
    private var restLocal: [SIMD3<Float>] = []
    private var topoOrder: [Int] = []
    private var childIndices: [[Int]] = []
    private var restWorldPos: [SIMD3<Float>] = []
    private var worldPos: [SIMD3<Float>] = []
    /// 直接来自动画的世界旋转，尚未叠加摆动。
    private var poseQuat: [simd_quatf] = []
    /// 叠加了本求解器摆动的世界旋转。
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

    /// 求解器碰撞球的副本，供调试线框使用。
    var debugColliders: [MMDPhysicsColliderDebug] {
        colliderSpheres.map {
            MMDPhysicsColliderDebug(bone: $0.bone, offset: $0.offset, radius: $0.radius)
        }
    }
    /// PMX 文件里的全部刚体，无论参与模拟还是只当碰撞体。
    private(set) var totalRigidBodyCount = 0
    /// 链式求解器驱动的骨骼数量。显示在检查器里，
    /// 方便区分「物理没起作用」和「这个模型没有布料
    /// （或者物理被关掉了）」。
    private(set) var drivenBoneCount = 0
    /// 求解器实际操控的骨骼。
    var clothBoneCount: Int { drivenBoneCount }
    private(set) var clothChainCount = 0
    private(set) var colliderCount = 0
    /// 「裙摆 4 · 头发 2」—— 按类型统计的链条数，给检查器用。
    private(set) var chainKindSummary: [(String, Int)] = []
    /// 前几条链的根骨名。这样某个模型的挂件*没有*被识别时，
    /// 凭一张截图就能判断原因。
    private(set) var chainSamples: [String] = []

    // MARK: - 链条模型

    /// 挂着的是什么。它决定这串东西有多软、能偏离多远，
    /// 以及被拉回作者设定轮廓的力度。
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

        /// 单节相对动画给出方向的允许偏角（弧度）。上一版放到
        /// `maxAngle x 2.2` = 110°，每节都折 110° 的飘带
        /// 就是一张揉皱的纸 —— 头发和腰带上那些死褶
        /// 正是这么来的。每节 10–20°，
        /// 整条链下来仍有 60–120° 的余量。
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

        /// 单节相对作者轮廓的允许偏角（弧度），由链锚点带入
        /// 当前姿势。这是一条硬边界，
        /// 「形变随时间越走越大」因此不可能发生。
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

        /// 把链拉回动画姿势的角弹簧。
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

        /// 锚点自身运动拖拽后续链节的强度。
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

    /// 链条的一节。一节的完整状态就是一个单位方向加一个角速度：
    /// 没有位置可以漂移、没有长度可以拉伸、
    /// 也没有缩放可以塌陷，所以它不会让网格
    /// 每帧都多变形一点。
    private struct Link {
        var bone: Int
        /// 模型空间下的静止方向。
        var restDir: SIMD3<Float>
        /// 与上一节之间作者设定的弯折角（弧度）。
        var bend: Float
        var length: Float
        var limitLink: Float
        var limitChain: Float
        var spring: Float
        var damp: Float
        var droop: Float
        var drag: Float
        /// 静止时*在*身体胶囊内部的链节设为 false（裙腰就贴在胯上）：
        /// 把它们推出去会让布料鼓起来。
        var collides: Bool
        var dir: SIMD3<Float>
        var omega: SIMD3<Float>
    }

    private struct Chain {
        /// 第一节挂靠的骨骼。只有找不到躯干的骨架才会是 -1。
        var anchor: Int
        var links: [Link]
        var kind: ChainKind
        var name: String
        var seeded: Bool
        var lastAnchor: SIMD3<Float>
        /// 本帧的锚点速度，已夹取。每帧只采样一次，
        /// 拖拽量不会随子步数量变化。
        var velocity: SIMD3<Float>
        /// 本帧的锚点加速度，已夹取。它让裙摆在身体启动或
        /// 停止时甩出去，
        /// 而不是垂直下垂。
        var accel: SIMD3<Float> = .zero
    }

    // MARK: - 刚体

    private var rigidBoneIndices: Set<Int> = []
    /// 作者写在眼、眉、四肢上、被保持为运动学的刚体。
    private var protectedDynamicBodyCount = 0
    private var protectedBoneSamples: [String] = []

    // MARK: - 关键词

    private static let clothKeywords = [
        "髪", "hair", "ヘア", "ahoge", "skirt", "スカート", "ribbon",
        "リボン", "tail", "尾", "cape", "マント", "袖", "sleeve", "wing",
        "羽", "翼", "feather", "羽根", "plume", "frill", "フリル", "cloth",
        "裾", "垂", "ドレス", "dress", "apron", "エプロン", "belt", "ベルト",
        "scarf", "マフラー", "ネクタイ", "necktie", "テープ", "ストラップ",
        "strap", "ハネ", "ポニー", "ponytail", "braid", "三つ編",
        // 中文 / 拼音骨架（原神、王者 提取）。
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
        // 中文骨架（原神 / 星穹铁道 / 绝区零 提取）把四肢叫 臂/肘/腕/腿/膝。
        // 没有这些规则，整条手臂会被当成「垂着的布」，
        // 求解器一摆就是 v1.7 反馈的手臂变形。
        "臂", "肘", "腕", "手", "掌", "腿", "膝", "脚", "踝", "胯", "臀",
        "胸", "腹", "脊", "脖", "頭", "头", "颈", "肩胛", "锁骨", "手指",
        "足", "脚趾", "大腿", "小腿", "上臂", "前臂", "股", "胫",
        // 胸部：游戏提取的胸腔通常带 2–4 根抖动骨，作者
        // 是指望它们别动的。让它们摆起来，
        // 就是「胸口动得很怪」那条反馈。
        "breast", "bust", "おっぱい", "乳房", "乳", "boob"
    ]

    /// 绝不能交给物理的骨骼：眼、口、眉之类。它们又小又悬，
    /// 否则和一根头发丝没有区别，
    /// 一转起来脸就皱成一团。
    private static let faceKeywords = [
        "目", "眼", "eye", "瞳", "hitomi", "歯", "齿", "tooth", "teeth",
        "舌", "tongue", "眉", "brow", "mayu", "睫", "lash", "口", "mouth",
        "唇", "lip", "kuchi", "頬", "cheek", "鼻", "nose", "耳", "ear",
        "face", "顔", "jaw", "顎", "あご", "表情"
    ]

    /// 在 MMD 里刘海也是焊在额头上的。让它们摆，
    /// 就是「刘海支棱出来」那条反馈。
    private static let rigidKeywords = [
        "刘海", "前髪", "前发", "bang", "眉", "睫", "ひたい", "forelock"
    ]

    private static let helperPrefixes = [
        "ctr", "ctrl", "control", "skn", "dummy", "ダミー", "op_", "adj",
        "adjust", "物理", "phys", "ik_", "motion", "kci", "コントロール",
        // 原神 / 星穹铁道 提取的中文骨架以 操作中心
        // 骨骼开头，它承载整个模型。它没有蒙皮权重，但旧版
        // 只看名字的规则把它当成了一条布料链，
        // 还占掉了 600 根骨骼预算的一部分。
        "操作", "制御", "リグ", "shadow", "影", "ground", "床", "gizmo",
        "ボーン"
    ]

    // MARK: - 生命周期

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

        // 子骨列表 + 父先于子的顺序。畸形文件可能有父级环；
        // 遍历不到的骨骼随后追加到末尾，
        // 数组保持完整，而不是崩溃。
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

    // MARK: - 碰撞体

    /// 身体骨骼上的一颗碰撞球。
    ///
    /// 一条腿只用一根胶囊，全长共用一个半径：大腿要么在膝盖处太粗、
    /// 要么在胯处太细，两种情况裙摆都会
    /// 从缝里穿过去。改成一串球，半径就能跟着腿走，
    /// 而且半径是从网格实测的，
    /// 不再按模型身高去猜。
    private struct ColliderSphere {
        var bone: Int
        /// 球心在骨骼坐标系下（骨骼不带静止旋转，
        /// 所以这就是相对骨骼静止世界位置的普通偏移）。
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

        // 一趟遍历，把顶点按「权重不低于 15% 的骨骼」分桶。
        // 裙片通常会在大腿上留一点权重，
        // 所以一节要看它的两根骨骼。
        var byBone = [Int: [Int]]()
        for (index, vertex) in model.vertices.enumerated() {
            for slot in 0..<4 where vertex.boneWeights[slot] > 0.15 {
                let bone = Int(vertex.boneIndices[slot])
                guard bone >= 0 && bone < boneCount else { continue }
                byBone[bone, default: []].append(index)
            }
        }

        /// 到骨轴距离的 65 分位。均值会被少数几个裙摆顶点拉偏，
        /// 最大值更糟。对肢体来说，65%
        /// 正好是分布的拐点。
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
            // 硬上限：带一点大腿权重的布料，位置其实离腿很远，
            // 让它决定半径会把碰撞体撑大，
            // 直到裙子被顶离身体。
            return min(samples[pick], height * 0.10)
        }

        func addSegment(_ boneA: Int, _ boneB: Int, pieces: Int, fallback: Float) {
            guard boneA >= 0, boneA < restWorldPos.count else { return }
            let start = restWorldPos[boneA]
            let target = (boneB >= 0 && boneB < restWorldPos.count) ? restWorldPos[boneB] : start
            var direction = target - start
            var length = simd_length(direction)
            if length < 1e-5 {
                // 头这类零长度锚点：朝上取方向，球才能
                // 覆盖出一段体积，而不是全叠在一点上。
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

    // MARK: - 链条识别

    /// 构建二级运动链。
    ///
    /// 只看名字不够：转换过的原神骨架可能把腰带叫
    /// `Bip001 Accessory 04` 或 `Bone.017`，于是一点都不动 —— 这就是
    /// 「硬纸板」那条反馈。所以一根骨骼只要*结构上*是悬垂的
    /// （它下面没有任何骨骼属于人形骨架），
    /// 就当作二级骨骼；名字命中裙/发/飘带的同样处理。
    /// 如果整套骨架一个人形骨都没命名，这两条规则都跳过，
    /// 否则「悬垂」会把手臂和腿也算进去。
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
            // 「頭髪」是头发而不是头：布料关键词优先于人形骨
            // 标记，否则头骨下面每一缕头发都会被判成骨架，
            // 永远不摆。
            let clothNamed = Self.clothKeywords.contains(where: { lower.contains($0) })
            let humanoid = Self.isHumanoidDeformBone(bone) && !clothNamed
            if ikBones.contains(index) || humanoid || Self.isHelperBone(lower) {
                isCore[index] = true
                coreCount += 1
            }
        }

        // 子树深处含有核心骨骼的骨骼也属于骨架
        // （比如骨架根、挂件座），
        // 绝不能当成布料。
        var hasCoreBelow = [Bool](repeating: false, count: boneCount)
        for index in topoOrder.reversed() {
            for child in childIndices[index] where isCore[child] || hasCoreBelow[child] {
                hasCoreBelow[index] = true
            }
        }
        let trustGeometry = coreCount >= 6

        // 每根骨骼依赖多少顶点，含自身与子树。控制骨
        // （操作中心、dummy、IK 目标）一个顶点都没有，转它
        // 只会弄坏骨架，永远不是布料。这道过滤让
        // 911 根骨骼的模型不会把 600 根「布料」骨丢进求解器。
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
            // 没有任何顶点蒙皮到它，自然不可能是布料。
            if skinnedBelow[index] < 4 { continue }
            let named = Self.clothKeywords.contains(where: { lower.contains($0) })
            if named || trustGeometry { secondary.insert(index) }
        }
        guard !secondary.isEmpty else { return }

        // 链条是*路径*，不是子树。裙根每个裙片一个子骨，
        // 头发在每缕发丝处分叉；把子树压成一个
        // 数组，会给根本没有相连的骨骼之间加上距离约束，
        // 求解器于是把衣服撕成一堆尖刺。一根骨骼
        // 只有正好是所在链的末端时，才延长那条链，
        // 否则它就从这根骨骼上另起一条新链。
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
                    // 程序生成的子骨可能落在模型另一侧；
                    // 拿它当末端，最后一节会被拉成
                    // 裙子上见过的那种尖刺。
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

            // 一条链的总摆幅必须落在 `chainLimit` 内：10 节的裙子
            // 每节约 7°，3 节的腰带是 25°。
            // 否则长裙 8 节各 19°，一加就翻到里朝外。
            let perLink = min(kind.linkLimit, kind.chainLimit * 0.9 / Float(links.count))
            for i in links.indices {
                links[i].limitLink = perLink
                // 重力在静止时把每节压到预算的 ~50%：够读出重量感，
                // 又不至于压坏作者设定的形状。
                // 那个 1.4 不是凑数：重力力矩按
                // sin(与竖直的夹角) 增长，弹簧按 sin(与姿势的
                // 夹角) 增长，线性系数必须过驱动才能平衡。
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

        // 预算要按深度顺序下发：子链若先于锚点求解，
        // 就会挂在一根永远不动的骨骼上。
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
        // 名字不可用：按链条悬挂的位置判断。肩以上
        // 算头发，腰以下算裙摆。
        if heightFraction > 0.74 { return .hair }
        if heightFraction < 0.42 { return .skirt }
        return .other
    }

    private static func isHelperBone(_ lower: String) -> Bool {
        helperPrefixes.contains { lower.hasPrefix($0) || lower.contains("_" + $0) }
    }

    // MARK: - 每帧

    func apply(animations: [Int: MMDBoneAnimation], model: PMXModel,
               settings: MMDPhysicsSettings, time: CFTimeInterval,
               forcedStep: Float? = nil,
               driveRotation: simd_quatf? = nil) -> [Int: MMDBoneAnimation] {
        guard settings.mode != .off else { return animations }
        guard boneCount > 0 else { return animations }
        if time < lastTime { reset() }

        // `advance == false` 表示渲染器又要了同一个时刻：
        // 暂停帧的 120 Hz 重绘，或者第二道绘制。
        // 姿势仍然要输出，否则每次重绘布料都弹回
        // 静止形状，「物理没反应」就又回来了。
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
        // 在刚体段为空的模型上选「PMX 刚体」（游戏提取角色
        // 很常见），以前会什么都不做。改为退回链式求解器，
        // 这个开关就不再是空操作。
        //
        // 「自动」自己作同样的判断：真有带关节刚体链的模型
        // 交给 Bullet 模拟，那是作者调好的状态；
        // 其余的走链式求解器。
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

    // MARK: - 链条积分

    /// 角弹簧-阻尼的二级运动。
    ///
    /// 每一节只持有一个*单位方向*和一个角速度。重力、
    /// 风与锚点自身的运动把方向扭离动画给出的姿势；
    /// 弹簧再把它拉回来。除此之外不存任何东西，
    /// 所以没有位置可漂移、没有长度可拉伸、
    /// 没有缩放可塌陷 ——「裙子每秒都多变形一点」
    /// 这种失效模式在结构上就不可能发生。
    ///
    /// 上一版用 Verlet 积分世界*位置*，碰撞推挤也只
    /// 写回位置。于是每次推挤都给了质点一个新的向外速度，
    /// 贴着大腿胶囊的裙摆按步频不断注入能量：裙摆抖动、
    /// 起褶，
    /// 还会一点点往外爬。
    private func stepChains(settings: MMDPhysicsSettings, dt: Float) {
        guard !chains.isEmpty else { return }
        if chains.contains(where: { !$0.seeded }) { seedAllChains() }
        guard dt > 0.00001 else { return }

        // 固定 120 Hz，最多 6 步追赶。慢帧再也不会
        // 给求解器一个巨大的 dt 把链子崩开。
        for index in chains.indices {
            let anchorPos = chains[index].anchor >= 0 ? worldPos[chains[index].anchor] : .zero
            var velocity = (anchorPos - chains[index].lastAnchor) / dt
            let speed = simd_length(velocity)
            // 跳转或瞬移不能把链子甩到场景另一头。
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
            // 锚点的线速度驱动拖拽量。
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
                // 身体动得越快，链节被拉回动画轮廓的力就越强。
                // 弹簧若恒定，一个急转身就会把裙摆甩在身后整整一节 ——
                // 这就是
                // 「衣服跟不上动作」，也是它切开大腿的时候。
                let followBoost = 1 + min(anchorSpeed, 24) * 0.06
                torque += simd_cross(dir, poseDir) * (link.spring * stiffnessScale * followBoost)
                if trailing != SIMD3<Float>.zero {
                    torque += simd_cross(dir, trailing) * (anchorSpeed * link.drag * 4)
                }
                // 惯性踢：锚点自身的加速度把链节往反方向推，
                // 人迈步时裙摆就是这么甩的。
                // 没有这一项，裙摆只会永远滞后，
                // 因为重力与姿势弹簧是仅有的两个力。
                let accelLength = simd_length(chain.accel)
                if accelLength > 0.05, settings.inertia > 0.001 {
                    let gain = min(accelLength, 40) * 0.05 * settings.inertia
                    torque += simd_cross(dir, -chain.accel / accelLength) * (link.drag * gain)
                }

                var omega = link.omega + torque * h
                // 隐式阻尼：任何 dt 下都无条件稳定。
                omega /= (1 + link.damp * dampingScale * h)
                let spin = simd_length(omega)
                if spin > 1e-5 {
                    let angle = min(spin * h, 0.5)
                    dir = simd_quatf(angle: angle, axis: omega / spin).act(dir)
                    // 把实际*用到*的速度冲掉，这样被夹取的
                    // 这一步不会留下一个巨大的 omega。
                    omega *= angle / (spin * h)
                }

                // 两条硬边界。第一条是*关节*：这一节相对它挂靠的
                // 上一节，弯曲不得超过作者弯折角加上它那份预算，
                // 飘带因此不会起死褶。第二条是*整链*：
                // 任何一节偏离作者轮廓都不得超过整链预算，
                // 裙子因此不会翻成里朝外，
                // 也不会在长时间动作里
                // 一点点跑偏。
                //
                // 两者都是拿已解算的邻节作参照，而不是
                // 固定的静止方向。把每个关节都对着静止
                // 方向夹取（v12.7），整条链会被钉在一个锥面上，
                // 像一块板一样从身体上支棱出去。
                dir = clampDir(dir, to: previousDir, maxAngle: link.bend + linkLimit)
                dir = clampDir(dir, to: silhouette, maxAngle: link.limitChain * swingScale)

                if link.collides {
                    // 沿整节采样，不能只看末端。裙摆在链节 60% 处
                    // 碰到大腿时，末端其实还在腿里面，
                    // 只推末端，中段就会游进身体 ——
                    // 也就是肉眼看到的「穿模」。
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
                            // 绝不能拿穿模换轮廓：夹取若抵消了推挤，
                            // 就保留推挤，让锥角
                            // 下一步再吸收它。
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
                    // 滑动接触必须泄掉能量，否则裙摆
                    // 会按步频贴着碰撞体抖。
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

    /// 当 `dir` 与 `ref` 的夹角超过 `maxAngle` 时，
    /// 把 `dir` 转回 `ref`，保持方位角。这是*锥面钩爪*，
    /// 不是重新归一化：方向在锥内原本有多少自由度就保留多少，
    /// 链条因此不会折成一片。
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
            // 算姿势，不算碰撞：碰撞体属于身体，让布料骨
            // 拖着自己的碰撞体跑，它会去追那些它本该挡住的
            // 质点。
            let centre = worldPos[bone] + poseQuat[bone].act(sphere.offset)
            let offset = result - centre
            let distanceSquared = simd_dot(offset, offset)
            // 4% 的皮肤余量：布料是面，不是点，
            // 65 分位的网格半径本来就落在轮廓之内。
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

    /// 当某点的静止位置已经在身体胶囊内部时返回 true。
    /// 裙腰就坐在胯上；把它推出去会把整条裙子
    /// 撑起来，所以这些质点不参与碰撞。
    private func restsInside(_ point: SIMD3<Float>) -> Bool {
        for sphere in colliderSpheres {
            let bone = sphere.bone
            guard bone >= 0 && bone < restWorldPos.count else { continue }
            let centre = restWorldPos[bone] + sphere.offset
            if simd_length(point - centre) < sphere.radius * 1.05 { return true }
        }
        return false
    }

    /// 把解算出的方向变成骨骼旋转。
    ///
    /// 旋转取最短弧，把骨骼的静止方向映射到解算方向，
    /// 并在父骨坐标系下表达 —— 平的腰带因此
    /// 能保住自己的滚转角，而不是绕自身轴拧过去。
    private func emitChains(into result: inout [Int: MMDBoneAnimation]) {
        for chain in chains {
            guard chain.seeded else { continue }
            var parentQuat = chain.anchor >= 0 ? solvedQuat[chain.anchor] : mmdIdentityQuaternion
            var head = chain.anchor >= 0 ? worldPos[chain.anchor] : .zero
            for j in chain.links.indices {
                let link = chain.links[j]
                let bone = link.bone
                // 保留动画给的一切，只叠加
                // 解算方向与姿势方向之间的*差*。
                // 把修正复合到动画旋转上，
                // 骨骼的滚转角得以保留，而且意味着
                // 正好落在姿势上的链节与姿势逐位相同 ——
                // 打开物理，再也不能改写一根没在动的骨骼。
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

    // MARK: - Bullet 刚体

    /// 一个映射进 Bullet 的 PMX 刚体。
    ///
    /// PMX 把刚体的静止变换存在世界空间，再绑到一根骨骼上；
    /// 求解器需要同一关系在骨骼局部坐标系下的表达，
    /// 所以两个方向都在加载时预先算好。
    private struct BulletBody {
        var handle: Int32
        var bone: Int
        var dynamic: Bool
        var mode: UInt8
        var restPosition: SIMD3<Float>
        var restRotation: simd_quatf
        /// R_rest 在骨骼坐标系下：R = B ∘ offset。
        var offsetPosition: SIMD3<Float>
        var offsetRotation: simd_quatf
        /// B_rest 在刚体坐标系下：B = R ∘ inverse。
        var inversePosition: SIMD3<Float>
        var inverseRotation: simd_quatf
        var movable: Bool
    }

    private var bulletWorld: OpaquePointer?
    private var bulletBodies: [BulletBody] = []
    /// 模型带刚体、且由 Bullet 驱动时为 true。
    private(set) var bulletActive = false

    private func destroyBulletWorld() {
        if let world = bulletWorld { MMDPhysWorldDestroy(world) }
        bulletWorld = nil
        bulletBodies.removeAll()
        bulletActive = false
    }

    /// 从 PMX 的刚体段与关节段构建 Bullet 场景。
    ///
    /// 项目之所以内置 Bullet，就是为了这个：PMX 刚体是按
    /// Bullet 2.x 调出来的，形状、质量、阻尼、恢复系数、
    /// 摩擦、碰撞组/掩码和 6DOF 弹簧关节一一对应。
    /// 手写重推这些参数，就是「裙子越动越长」
    /// 那种表现的来源。
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
            // 模式 0 跟随骨骼，只作为被碰撞的对象存在；
            // 模式 1、2 参与模拟并写回。
            //
            // XR / ZZZ 转换的骨架还会把刚体放到脸和核心骨上。
            // 那里的动态刚体会每帧覆盖动画：人站着不动，
            // 眼珠却在转、眉毛在跳。
            // 这些刚体保持运动学 —— 仍可碰撞，但永不主导。
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
            // PMX 的组是 0...15，掩码就是这些组的位域，
            // 正好等于 Bullet 的 (group, mask) 对 ——
            // 除了把索引变成位，不需要任何转换。
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

            // PMX 骨骼只带平移，所以每根骨骼的静止姿势
            // 都是单位旋转，偏移量就是一次普通减法。
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

            // PMX 关节的上下限全为零表示「无限位」；
            // 否则 Bullet 会把该轴锁死在零行程上。
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
        // 所有刚体都是模式 0 的模型没有东西可模拟；
        // 碰撞体仍留在世界里供链式求解器复用，但
        // 「刚体」开关必须退回其他模式，而不是看起来坏掉。
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
        // 防止畸形文件出现 lower > upper ——
        // Bullet 会把它当成完全锁死的关节。
        return (simd_min(lower, upper), simd_max(lower, upper))
    }

    private func stepBullet(dt: Float) {
        guard let world = bulletWorld else { return }
        guard dt > 0.00001 else { return }

        // 运动学刚体在求解前就摆到骨骼上；Bullet
        // 从位移增量推导速度，移动的大腿因此
        // 能把裙片扫开。
        for record in bulletBodies where !record.dynamic && record.bone >= 0 {
            let bone = record.bone
            let boneQuat = solvedQuat[bone]
            let position = worldPos[bone] + boneQuat.act(record.offsetPosition)
            let rotation = quatNormalize(boneQuat * record.offsetRotation)
            MMDPhysSetBodyTransform(world, record.handle, position.f3, rotation.f4)
        }

        // 固定 120 Hz 步长，最多 4 步追赶。一帧 4K 导出
        // 花了 60 ms，绝不能当成一个 60 ms 的单步丢给 Bullet。
        MMDPhysWorldStep(world, min(dt, 0.1), 4, 1.0 / 120.0)
    }

    private func applyBullet(to animations: inout [Int: MMDBoneAnimation], model: PMXModel) {
        guard let world = bulletWorld else { return }
        // 拓扑顺序：子刚体的骨骼变换必须从父级
        // *已经更新*的世界旋转推导，否则链上两个
        // 参与模拟的刚体会读到过期的父级而错位撕开。
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

            // 模式 2 是「物理 + 骨骼位置对齐」：刚体还能
            // 拖着骨骼走，长裙的裙摆就是这样守住
            // 作者形状的。给它加上限，求解器打个嗝
            // 也不能把骨骼拽出模型。
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

    /// MMD 刚体通常是为裙子、头发和挂件写的。
    /// 一些转换骨架还会在脚或胫骨上放动态刚体；
    /// 把它写回一根形变中的人形骨，即使 VMD 姿势是直的，
    /// 腿也会弯。核心骨架一律不接受物理回写。
    private static func isHumanoidDeformBone(_ bone: PMXBone) -> Bool {
        let text = (bone.name + " " + bone.nameEn).lowercased()
        return humanoidMarkers.contains(where: { text.contains($0) })
    }
}

/// MMD 的 IK「单位角」是对齐步长的倍率。把它夹到
/// 合理范围，畸形 PMX 才不能靠一次迭代跳 180 度。
func class_half_clamp(_ value: Float) -> Float {
    max(0.02, min(1.0, value))
}

/// 通往 C 接口的小桥接，那边只吃普通 float 数组。
extension SIMD3 where Scalar == Float {
    var f3: [Float] { [x, y, z] }
}

extension simd_quatf {
    var f4: [Float] { [imag.x, imag.y, imag.z, real] }
}
