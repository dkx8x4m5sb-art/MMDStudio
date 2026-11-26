//
//  MMDModelDocument.swift
//  MMD Studio
//
//  画布文档：模型、动作、物理与渲染设置的唯一持有者。
//

import Foundation
import SwiftUI
import Combine
import QuartzCore
import AVFoundation

final class MMDModelDocument: ObservableObject, Identifiable {

    let id = UUID()
    let displayName: String

    @Published var model: PMXModel
    @Published var modelRevision: Int = 1
    @Published var baseDirectory: URL
    /// Optional package root used as a secondary texture search root.
    @Published var fallbackRoot: URL?
    @Published var materialSettings: [MMDMaterialSettings]
    @Published var morphWeights: [Float]
    @Published var boneRotations: [Int: SIMD3<Float>] = [:]
    @Published var boneOffsets: [Int: SIMD3<Float>] = [:]
    @Published var selectedBoneIndex: Int = -1
    @Published var selectedMaterialIndex: Int = 0
    @Published var humanoidBindings: [MMDHumanoidJoint: Int] = [:]
    @Published var jointConstraintsEnabled: Bool = true
    @Published var ikEnabled: Bool = false
    @Published var physicsSettings = MMDPhysicsSettings()
    @Published var humanoidBindingNote: String = ""
    @Published var attachments: [MMDAttachment] = []
    @Published var sceneRevision: Int = 0
    @Published var selectedAttachmentID: UUID?
    @Published var selectedLightID: UUID?
    @Published var sceneEditEnabled = false
    @Published var transformMode: MMDTransformMode = .translate
    @Published var transformAxis: MMDTransformAxis = .free

    @Published var motion: VMDMotion?
    @Published var motionName: String = ""
    @Published var useCameraMotion: Bool = false
    /// A camera-only VMD chosen from the motion library. Kept apart from
    /// `motion` so picking a different shot never replaces the dance.
    @Published var cameraMotion: VMDMotion?
    @Published var cameraMotionName: String = ""
    /// Set while a video export owns the renderer. Physics then advances by a
    /// fixed 1/fps step instead of the wall-clock delta, so a 60 fps render
    /// simulates the same cloth on every run and does not jitter when a frame
    /// takes longer than 16 ms to encode.
    var isExporting: Bool = false
    @Published var currentFrame: Float = 0 {
        didSet { if renderFrame != currentFrame { renderFrame = currentFrame } }
    }
    /// Frame the renderer should draw. Video export drives this directly
    /// instead of `currentFrame`, so a 60 fps export does not rebuild the
    /// whole SwiftUI tree sixty times a second and starve the GPU.
    var renderFrame: Float = 0
    @Published var isPlaying: Bool = false
    @Published var loopPlayback: Bool = true
    @Published var playbackSpeed: Float = 1.0
    @Published var renderSettings = MMDRenderSettings()
    @Published var renderStats = MMDRenderStats()
    @Published var motionMappingNote: String = ""
    @Published var motionAudioName: String = ""
    @Published var missingTextureNames: [String] = []
    /// Off by default: most models already ship mouth morphs and almost every
    /// dance clip animates them, so an extra audio envelope reads as a
    /// twitching jaw. The choice is remembered per app, not per model.
    @Published var lipSyncEnabled = UserDefaults.standard.bool(forKey: MMDModelDocument.lipSyncKey) {
        didSet { UserDefaults.standard.set(lipSyncEnabled, forKey: Self.lipSyncKey) }
    }
    /// True when the current clip animates the mouth itself, which is why the
    /// audio envelope was switched off automatically.
    @Published var lipSyncAutoDisabled = false
    private(set) var sourceURL: URL?
    private(set) var motionAudioURL: URL?
    @Published var lipSyncStrength: Float = 0.65
    /// Collision spheres the cloth solver is actually testing against, for the
    /// debug overlay.
    var physicsColliderDebug: [MMDPhysicsColliderDebug] { springPhysics.debugColliders }
    /// True when Bullet is driving the current model (auto or explicit).
    var physicsRunsRigidBodies: Bool { springPhysics.bulletActive && physicsSettings.mode != .secondary && physicsSettings.mode != .off }
    @Published var errorMessage: String?
    /// 画布让位量：0 表示正常构图，>0 时把画面整体上移并轻微缩小，
    /// 让底部弹出的调试面板不会压住模型。渲染器会把这个值平滑过渡，
    /// 所以这里直接写目标值即可，不需要自己做动画。
    @Published var canvasLift: Float = 0

    private(set) var motionBoneTracks: [Int: VMDBoneTrack] = [:]
    private(set) var motionMorphTracks: [Int: VMDMorphTrack] = [:]

    private var timer: Timer?
    private var audioPlayer: AVAudioPlayer?
    private var lastTick: CFTimeInterval = 0
    private var springPhysics = MMDSpringPhysics()
    private var lastPhysicsEnabled = false
    private var lipSyncEnvelope: [Float] = []

    /// Cached lookups derived from the model. They used to be rebuilt inside
    /// `effectiveBoneAnimations` on every rendered frame: a full name→index
    /// dictionary plus a suffix scan of all bones, at up to 120 Hz. The model
    /// is immutable between loads, so build them once.
    private var boneIndexByName: [String: Int] = [:]
    private var mirroredBonePairs: [(source: Int, copy: Int)] = []
    private var mouthMorphIndices: [Int] = []

    static let lipSyncKey = "MMDStudio.lipSyncEnabled"

    private static let mouthMorphNames: Set<String> = [
        "あ", "あ2", "a", "mouth", "moutha", "mouthopen",
        "口", "口あ", "リップ", "lip", "jaw"
    ]

    init(model: PMXModel, baseDirectory: URL, fallbackRoot: URL? = nil, displayName: String,
         sourceURL: URL? = nil) {
        self.model = model
        self.sourceURL = sourceURL
        self.baseDirectory = baseDirectory
        self.fallbackRoot = fallbackRoot
        self.displayName = displayName.isEmpty ? model.displayName : displayName
        self.materialSettings = model.materials.enumerated().map { index, material in
            MMDMaterialSettings(material: material, index: index)
        }
        self.morphWeights = [Float](repeating: 0, count: model.morphs.count)
        self.selectedMaterialIndex = model.materials.isEmpty ? -1 : 0
        self.selectedBoneIndex = model.bones.isEmpty ? -1 : 0
        self.springPhysics.prepare(model: model)
        _ = self.autoBindHumanoid()
        rebuildCaches()
    }

    /// Rebuilds the name tables and morph lists that the render loop reads.
    /// Call this after the model or the morph list changes.
    private func rebuildCaches() {
        var byName: [String: Int] = [:]
        byName.reserveCapacity(model.bones.count)
        for (index, bone) in model.bones.enumerated() where !bone.name.isEmpty {
            if byName[bone.name] == nil { byName[bone.name] = index }
        }
        boneIndexByName = byName

        var pairs: [(source: Int, copy: Int)] = []
        pairs.reserveCapacity(16)
        for (index, bone) in model.bones.enumerated() {
            let name = bone.name
            guard name.count > 1, name.hasSuffix("D") || name.hasSuffix("Ｄ") else { continue }
            let baseName = String(name.dropLast())
            guard let baseIndex = byName[baseName], baseIndex != index else { continue }
            pairs.append((source: baseIndex, copy: index))
        }
        mirroredBonePairs = pairs

        var mouths: [Int] = []
        for (index, morph) in model.morphs.enumerated() where !morph.isGroup {
            let key = Self.normalizedBoneName(morph.name)
            if Self.mouthMorphNames.contains(key) || key.hasPrefix("mouth") {
                mouths.append(index)
            }
        }
        mouthMorphIndices = mouths
    }

    deinit {
        timer?.invalidate()
    }

    /// Playback and every animation sampler use VMD frame numbers. Keep this
    /// value in frames; exposing seconds here used to stop a 464-frame clip at
    /// frame 15.47 (about half a second).
    var duration: Float {
        // A library shot can be longer than the dance, and a camera-only
        // session has no dance at all; the timeline has to cover both or the
        // scrubber stops at 0.1 s while the camera keeps moving for 15 s.
        let boneEnd = motion?.maxFrame ?? 0
        let cameraEnd = cameraMotion?.maxFrame ?? 0
        guard boneEnd > 0 || cameraEnd > 0 else { return 0 }
        return max(0.1, Float(max(boneEnd, cameraEnd)))
    }

    var frameRate: Float { max(1, motion?.frameRate ?? 30) }

    var durationSeconds: Float { duration / frameRate }

    var hasMotion: Bool { motion != nil && !(motion?.isEmpty ?? true) }

    /// Camera keys actually used for rendering: the library shot if one is
    /// loaded, otherwise whatever the dance carries.
    var activeCameraKeys: [VMDCameraKeyframe] {
        if let cameraMotion, !cameraMotion.cameraKeys.isEmpty { return cameraMotion.cameraKeys }
        return motion?.cameraKeys ?? []
    }

    var hasCameraMotion: Bool { !activeCameraKeys.isEmpty }

    var timeText: String {
        Self.formatTime(currentFrame / frameRate)
    }

    var durationText: String {
        Self.formatTime(durationSeconds)
    }

    static func formatTime(_ seconds: Float) -> String {
        // Clamp defensively: a malformed VMD must never turn the scrubber
        // label into a multi-million-minute string.
        let value = max(0, min(seconds, 4 * 3600))
        let whole = Int(value.rounded(.down))
        let minutes = whole / 60
        let secs = whole % 60
        let frames = min(29, max(0, Int((value - Float(whole)) * 30)))
        return String(format: "%02d:%02d.%02d", minutes, secs, frames)
    }

    // MARK: - Motion

    /// Load a clip that already lives in `MMDMotionLibrary`. Nothing is copied
    /// into the session cache, so opening five models with the same dance
    /// leaves one file on disk instead of five.
    @discardableResult
    func loadMotion(asset: MMDMotionAsset, from library: MMDMotionLibrary) throws -> Int {
        let url = library.fileURL(for: asset)
        let loaded = try VMDParser(data: try Data(contentsOf: url)).parse()
        if asset.kind == .camera {
            // A camera file only carries keys. Installing it as the motion
            // would silently delete the dance that is already playing.
            guard !loaded.cameraKeys.isEmpty else {
                throw MMDLoadError.invalidData("这个文件没有相机关键帧")
            }
            cameraMotion = loaded
            cameraMotionName = asset.title
            useCameraMotion = true
            MMDLog.shared.info("Library camera loaded: \(asset.fileName), keys=\(loaded.cameraKeys.count)",
                               category: "Motion")
            objectWillChange.send()
            return loaded.cameraKeys.count
        }
        let mapped = try installMotion(loaded, name: asset.title)
        if let audioURL = library.audioURL(for: asset) {
            do {
                let player = try AVAudioPlayer(contentsOf: audioURL)
                player.prepareToPlay()
                audioPlayer = player
                motionAudioURL = audioURL
                motionAudioName = audioURL.lastPathComponent
                lipSyncEnvelope = Self.makeLipSyncEnvelope(url: audioURL)
                MMDLog.shared.info("Motion audio loaded: \(audioURL.lastPathComponent), duration=\(player.duration)",
                                   category: "Motion")
            } catch {
                MMDLog.shared.warning("Motion audio load failed: \(error.localizedDescription)", category: "Motion")
            }
        }
        MMDLog.shared.info("Library motion loaded: \(asset.fileName), mapped=\(mapped)/\(asset.boneTrackCount) bones",
                           category: "Motion")
        return mapped
    }

    /// Rank library clips by how many of their tracks land on this model. Two
    /// cuts of the same dance differ exactly here, so the score decides.
    func rankLibraryMotions(_ candidates: [MMDMotionAsset],
                            library: MMDMotionLibrary) -> [(asset: MMDMotionAsset, mapped: Int)] {
        candidates.map { asset -> (asset: MMDMotionAsset, mapped: Int) in
            guard let data = try? Data(contentsOf: library.fileURL(for: asset)),
                  let motion = try? VMDParser(data: data).parse() else { return (asset, 0) }
            return (asset, mapBoneTracks(motion).tracks.count)
        }
        .sorted { lhs, rhs in
            if lhs.mapped != rhs.mapped { return lhs.mapped > rhs.mapped }
            return lhs.asset.boneTrackCount > rhs.asset.boneTrackCount
        }
    }

    /// Install a generated motion directly, bypassing the VMD round-trip.
    /// The extractor writes tracks with this model's real bone names, so this
    /// path avoids Shift-JIS truncation and name-normalization failures.
    func loadGeneratedMotion(_ generated: VMDMotion, name: String) throws {
        guard !generated.isEmpty else {
            throw MMDLoadError.invalidData("生成的动作没有关键帧")
        }
        try installMotion(generated, name: name)
        guard !motionBoneTracks.isEmpty else {
            throw MMDLoadError.invalidData("生成的动作没有匹配到模型骨骼。请确认模型已完成自动绑定。")
        }
    }

    @discardableResult
    private func installMotion(_ newMotion: VMDMotion, name: String) throws -> Int {
        pause()
        audioPlayer?.stop()
        audioPlayer = nil
        motionAudioURL = nil
        motionAudioName = ""
        lipSyncEnvelope = []
        motion = newMotion
        motionName = name
        currentFrame = 0
        springPhysics.reset()
        springPhysics.prepare(model: model)
        // VMD camera motion is opt-in. Auto-enabling it makes a user's first
        // camera swipe appear to do nothing, because the VMD camera wins.
        // An explicitly chosen library shot survives a dance change.
        useCameraMotion = cameraMotion == nil ? false : useCameraMotion
        boneRotations.removeAll()
        boneOffsets.removeAll()
        buildMotionMaps(newMotion)
        // A clip that binds to nothing is indistinguishable from a broken
        // import, so fail loudly instead of leaving a dead timeline behind.
        if motionBoneTracks.isEmpty && motionMorphTracks.isEmpty && !newMotion.boneTracks.isEmpty {
            removeMotion()
            throw MMDLoadError.invalidData("《\(name)》的 \(newMotion.boneTracks.count) 根骨骼名称都和当前模型对不上，" +
                                           "无法驱动这个模型。请改用与模型同一角色的动作版本。")
        }
        // A clip that animates the mouth already owns the lip shape. Layering
        // the audio envelope on top doubles the deformation frame by frame and
        // is exactly the "嘴一直在抖" report. Turn it off and say why.
        let clipDrivesMouth = !mouthMorphIndices.isEmpty
            && motionMorphTracks.keys.contains { mouthMorphIndices.contains($0) }
        lipSyncAutoDisabled = clipDrivesMouth
        if clipDrivesMouth, lipSyncEnabled {
            lipSyncEnabled = false
            MMDLog.shared.info("Lip sync off: 《\(name)》 animates the mouth itself", category: "Motion")
        }
        return motionBoneTracks.count
    }

    /// Bone names suitable for generated tracks, taken from the current
    /// humanoid binding. A generated track uses these names verbatim.
    func humanoidBoneNameMap() -> [MMDHumanoidJoint: String] {
        var result: [MMDHumanoidJoint: String] = [:]
        for (joint, index) in humanoidBindings where index >= 0 && index < model.bones.count {
            result[joint] = model.bones[index].name
        }
        return result
    }

    func resetPhysics() {
        springPhysics.reset()
        objectWillChange.send()
    }

    var physicsBodyCount: Int { springPhysics.solvedRigidBodyCount }
    var physicsJointCount: Int { springPhysics.solvedJointCount }
    /// Every body in the PMX file, including the mode-0 colliders that never
    /// move. Telling "0 simulated" from "0 authored" matters when a model
    /// looks like physics does nothing.
    var totalRigidBodyCount: Int { springPhysics.totalRigidBodyCount }
    /// Bones the spring chains actually drive. Zero means the physics switch
    /// has nothing to move, which is what "physics does nothing" usually is.
    var clothBoneCount: Int { springPhysics.clothBoneCount }
    var clothChainCount: Int { springPhysics.clothChainCount }
    var physicsColliderCount: Int { springPhysics.colliderCount }
    /// "hair 6 · skirt 4" — what kinds of chains were found.
    var clothChainSummary: String {
        springPhysics.chainKindSummary.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }
    /// First few chain roots, so a model whose ribbons are not detected can be
    /// diagnosed from the settings page alone.
    var clothChainSamples: String { springPhysics.chainSamples.joined(separator: "、") }
    /// Short build stamp: "1.7 (17)".
    var appVersionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    func removeMotion() {
        pause()
        audioPlayer?.stop()
        audioPlayer = nil
        motionAudioURL = nil
        motionAudioName = ""
        lipSyncEnvelope = []
        motion = nil
        motionName = ""
        cameraMotion = nil
        cameraMotionName = ""
        motionMappingNote = ""
        motionBoneTracks = [:]
        motionMorphTracks = [:]
        lipSyncAutoDisabled = false
        springPhysics.reset()
        currentFrame = 0
        useCameraMotion = false
    }

    /// Resolve VMD track names onto bone indices for the current model.
    /// Shared by the importer (to score candidates) and by buildMotionMaps.
    private func mapBoneTracks(_ motion: VMDMotion) -> (tracks: [Int: VMDBoneTrack],
                                                        unmatched: [String],
                                                        ignored: Int) {
        var boneByName: [String: Int] = [:]
        var boneByNormalized: [String: Int] = [:]
        for (index, bone) in model.bones.enumerated() {
            if boneByName[bone.name] == nil { boneByName[bone.name] = index }
            if !bone.nameEn.isEmpty, boneByName[bone.nameEn] == nil { boneByName[bone.nameEn] = index }
            let key = Self.normalizedBoneName(bone.name)
            if !key.isEmpty, boneByNormalized[key] == nil { boneByNormalized[key] = index }
        }
        var boneTracks: [Int: VMDBoneTrack] = [:]
        var unmatched: [String] = []
        var ignoredControls = 0
        for track in motion.boneTracks {
            if let index = boneByName[track.name] ?? boneByNormalized[Self.normalizedBoneName(track.name)] {
                boneTracks[index] = track
                continue
            }
            if let joint = MMDHumanoidJoint.matching(trackName: track.name),
               let index = humanoidBindings[joint] {
                boneTracks[index] = track
                continue
            }
            // ZZZ / custom rigs often rename the standard MMD bones to
            // English or game-specific names. Retarget the generated tracks
            // through a conservative alias table before giving up.
            if let aliasIndex = Self.aliasBoneIndex(for: track.name, model: model,
                                                   normalized: boneByNormalized) {
                boneTracks[aliasIndex] = track
                continue
            }
            // VMD stores only 15 Shift-JIS bytes per name. A long PMX bone
            // name can therefore arrive truncated. Use a conservative prefix
            // match only when the stored name is long enough to be unique.
            let trimmed = track.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 4,
               let index = model.bones.firstIndex(where: {
                   $0.name.hasPrefix(trimmed) || (Self.normalizedBoneName($0.name).hasPrefix(Self.normalizedBoneName(trimmed)))
               }) {
                boneTracks[index] = track
                continue
            }
            // Control, cloth and prop tracks intentionally have no deform
            // target in many game rigs. They are driven by PMX physics or are
            // pure helpers; do not flood the UI/log with them.
            let normalizedTrack = Self.normalizedBoneName(track.name)
            let ignoredMarkers = ["prop", "phone", "ctr", "skn", "fskirt", "skirt",
                                  "スカート", "hair", "髪", "sleeve", "袖", "earring",
                                  "tail", "グルーブ", "全ての親", "dummy", "ダミー"]
            if ignoredMarkers.contains(where: { normalizedTrack.contains(Self.normalizedBoneName($0)) || track.name.contains($0) }) {
                ignoredControls += 1
            } else {
                unmatched.append(track.name)
            }
        }
        return (boneTracks, unmatched, ignoredControls)
    }

    private func buildMotionMaps(_ motion: VMDMotion) {
        let boneMapping = mapBoneTracks(motion)
        let boneTracks = boneMapping.tracks
        let unmatched = boneMapping.unmatched
        let ignoredControls = boneMapping.ignored
        motionBoneTracks = boneTracks

        var morphByName: [String: Int] = [:]
        for (index, morph) in model.morphs.enumerated() {
            if morphByName[morph.name] == nil { morphByName[morph.name] = index }
            if !morph.nameEn.isEmpty, morphByName[morph.nameEn] == nil { morphByName[morph.nameEn] = index }
        }
        var morphTracks: [Int: VMDMorphTrack] = [:]
        for track in motion.morphTracks {
            if let index = morphByName[track.name] {
                morphTracks[index] = track
            }
        }
        motionMorphTracks = morphTracks

        let mapped = boneTracks.count
        let total = motion.boneTracks.count
        if unmatched.isEmpty {
            motionMappingNote = ignoredControls > 0
                ? "动作已映射 \(mapped)/\(total) 根骨骼；忽略 \(ignoredControls) 根配饰/物理控制骨"
                : "动作已映射 \(mapped)/\(total) 根骨骼"
        } else {
            let sample = unmatched.prefix(5).joined(separator: "、")
            motionMappingNote = "动作映射 \(mapped)/\(total) 根骨骼；未匹配 \(unmatched.count) 根：\(sample)"
        }
        if mapped == 0 && !motion.boneTracks.isEmpty {
            motionMappingNote = "动作骨骼名称与模型不匹配，请确认 VMD 与 PMX 是否来自同一角色"
        }
        MMDLog.shared.info("Motion mapping: \(mapped)/\(total) bones, morphs=\(morphTracks.count)/\(motion.morphTracks.count)")
        if !unmatched.isEmpty {
            let sample = unmatched.prefix(8).joined(separator: ", ")
            MMDLog.shared.warning("Unmatched VMD bones (\(unmatched.count)): \(sample)")
        }
        if ignoredControls > 0 {
            MMDLog.shared.info("Ignored VMD control/accessory bones: \(ignoredControls)")
        }
    }

    private static let boneAliasGroups: [[String]] = [
        ["センター", "center", "centre", "pelvis", "hips", "hip", "root", "下半身"],
        ["上半身", "spine", "chest", "upperbody", "upper_body", "torso"],
        ["上半身2", "upperchest", "upper_chest", "chest2", "spine1"],
        // Some motion authors target 上半身1 (the ZZZ rig name) and tell users
        // to rename 上半身3. Bind that track to 上半身3 when the model has one,
        // and never to 上半身2 — that one carries its own track.
        ["上半身1", "上半身3", "upperbody1", "upperbody3", "spine2", "spine3"],
        ["頭", "head", "neck"],
        ["左腕", "leftupperarm", "left_upper_arm", "upperarm_l", "arm_l", "l_arm", "leftarm", "lupperarm", "l_upperarm"],
        ["右腕", "rightupperarm", "right_upper_arm", "upperarm_r", "arm_r", "r_arm", "rightarm", "rupperarm", "r_upperarm"],
        ["左ひじ", "leftforearm", "left_forearm", "forearm_l", "elbow_l", "l_elbow", "lforearm", "l_forearm", "lforear", "leftforear"],
        ["右ひじ", "rightforearm", "right_forearm", "forearm_r", "elbow_r", "r_elbow", "rforearm", "r_forearm", "rforear", "rightforear"],
        ["左手首", "lefthand", "left_hand", "hand_l", "wrist_l", "lhand", "l_hand", "lfinger", "lindex", "lmiddle", "lring", "lpinky", "lthumb"],
        ["右手首", "righthand", "right_hand", "hand_r", "wrist_r", "rhand", "r_hand", "rfinger", "rindex", "rmiddle", "rring", "rpinky", "rthumb"],
        ["左足", "leftthigh", "left_thigh", "thigh_l", "leg_l", "upperleg_l", "lthigh", "l_thigh"],
        ["右足", "rightthigh", "right_thigh", "thigh_r", "leg_r", "upperleg_r", "rthigh", "r_thigh"],
        ["左ひざ", "leftshin", "left_shin", "shin_l", "knee_l", "calf_l", "lshin", "lcalf", "l_calf"],
        ["右ひざ", "rightshin", "right_shin", "shin_r", "knee_r", "calf_r", "rshin", "rcalf", "r_calf"],
        ["左足首", "leftfoot", "left_foot", "foot_l", "ankle_l", "lfoot", "l_foot", "ltoe", "ltoe0", "lefttoe"],
        ["右足首", "rightfoot", "right_foot", "foot_r", "ankle_r", "rfoot", "r_foot", "rtoe", "rtoe0", "righttoe"],
    ]

    static func aliasBoneIndex(for trackName: String,
                               model: PMXModel,
                               normalized: [String: Int]) -> Int? {
        let key = normalizedBoneName(trackName)
        guard !key.isEmpty else { return nil }
        for group in boneAliasGroups {
            let aliases = group.map(normalizedBoneName)
            guard aliases.contains(key) else { continue }
            for alias in aliases {
                if let index = normalized[alias] { return index }
            }
            // Some rigs prefix every bone (e.g. "mixamorig:LeftArm").
            for (name, index) in normalized {
                if aliases.contains(where: { name.hasSuffix($0) || name.hasPrefix($0) }) {
                    return index
                }
            }
        }
        return nil
    }

    // MARK: - Humanoid rig

    /// Bind the standard MMD humanoid roles to this model's rig. Exact names
    /// win; common English/Chinese aliases and hierarchy prefixes are used as
    /// a second pass. The bindings are also used by VMD retargeting.
    @discardableResult
    func autoBindHumanoid() -> Int {
        var bindings: [MMDHumanoidJoint: Int] = [:]
        var used = Set<Int>()
        let modelBones = model.bones

        func normalizedNames(_ bone: PMXBone) -> [String] {
            var names: [String] = []
            let main = Self.normalizedBoneName(bone.name)
            let english = Self.normalizedBoneName(bone.nameEn)
            if !main.isEmpty { names.append(main) }
            if !english.isEmpty && english != main { names.append(english) }
            return names
        }

        func excluded(_ name: String) -> Bool {
            // MMD rigs frequently contain paired helper bones such as
            // 左肩P / 左腕捩 / 左足先. Matching those instead of the deform
            // bone makes the whole limb rotate around the wrong pivot.
            let markers = ["捩", "twist", "roll", "helper", "dummy", "ダミー",
                           "先", "親", "物理", "physics", "ik", "target", "終", "end", "tip"]
            if markers.contains(where: { name.contains($0) }) { return true }
            // A trailing "p" is the common MMD parent/helper suffix. Do not
            // reject a legitimate exact alias such as "hip" or "spine".
            if name.hasSuffix("p"), name.count > 2 { return true }
            return false
        }

        func expectedParents(for joint: MMDHumanoidJoint) -> [MMDHumanoidJoint] {
            switch joint {
            case .lowerBody: return [.center]
            case .upperBody: return [.lowerBody, .center]
            case .upperBody2: return [.upperBody]
            case .neck: return [.upperBody2, .upperBody]
            case .head: return [.neck]
            case .leftShoulder, .rightShoulder: return [.upperBody2, .upperBody]
            case .leftUpperArm: return [.leftShoulder, .upperBody2, .upperBody]
            case .rightUpperArm: return [.rightShoulder, .upperBody2, .upperBody]
            case .leftForearm: return [.leftUpperArm]
            case .rightForearm: return [.rightUpperArm]
            case .leftHand: return [.leftForearm]
            case .rightHand: return [.rightForearm]
            case .leftThigh, .rightThigh: return [.lowerBody, .center]
            case .leftShin: return [.leftThigh]
            case .rightShin: return [.rightThigh]
            case .leftFoot: return [.leftShin]
            case .rightFoot: return [.rightShin]
            case .center: return []
            }
        }

        func sideSign(_ joint: MMDHumanoidJoint) -> Int {
            switch joint {
            case .leftShoulder, .leftUpperArm, .leftForearm, .leftHand,
                 .leftThigh, .leftShin, .leftFoot:
                return -1
            case .rightShoulder, .rightUpperArm, .rightForearm, .rightHand,
                 .rightThigh, .rightShin, .rightFoot:
                return 1
            default:
                return 0
            }
        }

        func bestCandidate(for joint: MMDHumanoidJoint) -> Int? {
            let aliases = joint.aliases.map(Self.normalizedBoneName)
            let side = sideSign(joint)
            var bestIndex: Int?
            var bestScore = 0

            for (index, bone) in modelBones.enumerated() where !used.contains(index) {
                let names = normalizedNames(bone)
                guard !names.isEmpty else { continue }
                if names.contains(where: excluded) { continue }
                // A thigh alias such as 左足 must not steal 左足首 (the foot),
                // and a shin must not steal the ankle. These names are
                // common in MMD rigs where the alias is a prefix of a child.
                if joint == .leftThigh || joint == .rightThigh {
                    if names.contains(where: { $0.contains("足首") || $0.contains("ankle") || $0.contains("foot") }) {
                        continue
                    }
                }
                if joint == .leftShin || joint == .rightShin {
                    if names.contains(where: { $0.contains("足首") || $0.contains("ankle") || $0.contains("foot") }) {
                        continue
                    }
                }
                if joint == .leftHand || joint == .rightHand {
                    if names.contains(where: { $0.contains("指") || $0.contains("finger") || $0.contains("thumb") }) {
                        continue
                    }
                }

                var score = 0
                var exact = false
                for alias in aliases where !alias.isEmpty {
                    for name in names {
                        if name == alias {
                            exact = true
                            score = max(score, 1600 + alias.count * 8)
                        } else if name.hasPrefix(alias) || name.hasSuffix(alias) {
                            score = max(score, 1050 + alias.count * 5)
                        } else if alias.count >= 4 && name.contains(alias) {
                            score = max(score, 700 + alias.count * 3)
                        }
                    }
                }
                guard score > 0 else { continue }

                // A fuzzy match must not silently cross the body midline.
                if side != 0 {
                    let hasLeft = names.contains { $0.contains("left") || $0.hasSuffix("l") || $0.hasPrefix("l") }
                    let hasRight = names.contains { $0.contains("right") || $0.hasSuffix("r") || $0.hasPrefix("r") }
                    if side < 0 && hasRight && !hasLeft { score -= 900 }
                    if side > 0 && hasLeft && !hasRight { score -= 900 }
                }

                if !exact {
                    // Prefer the real deform bone over a shorter helper.
                    score -= 120
                }
                if let parent = bone.parentIndex >= 0 ? bone.parentIndex : nil {
                    let expected = expectedParents(for: joint)
                    if expected.contains(where: { bindings[$0] == parent }) {
                        score += 420
                    }
                    // A spine chain is usually upperBody -> upperBody2 ->
                    // neck; a direct child of center is less likely to be a
                    // limb deform bone but can still be valid for simple rigs.
                    if joint == .upperBody2,
                       let upper = bindings[.upperBody], parent == upper {
                        score += 260
                    }
                }

                if score > bestScore {
                    bestScore = score
                    bestIndex = index
                }
            }
            return bestIndex
        }

        for joint in MMDHumanoidJoint.allCases {
            if let index = bestCandidate(for: joint) {
                bindings[joint] = index
                used.insert(index)
            }
        }

        humanoidBindings = bindings
        let mapped = bindings.count
        humanoidBindingNote = mapped == 0
            ? "未找到人体骨骼；请检查模型骨骼命名。"
            : "已绑定 \(mapped) 个人体关节"
        let detail = MMDHumanoidJoint.allCases.compactMap { joint -> String? in
            guard let index = bindings[joint], index < modelBones.count else { return nil }
            return "\(joint.rawValue)=\(modelBones[index].name)"
        }.joined(separator: ", ")
        MMDLog.shared.info("Humanoid auto-bind: \(mapped)/\(MMDHumanoidJoint.allCases.count); \(detail)",
                           category: "Bones")
        return mapped
    }

    func setHumanoidBinding(_ joint: MMDHumanoidJoint, boneIndex: Int?) {
        if let boneIndex {
            guard model.bones.indices.contains(boneIndex) else { return }
            // A deform bone cannot drive two semantic joints at once. Preserve
            // the user's explicit choice and clear the previous role instead.
            for (other, index) in humanoidBindings where index == boneIndex && other != joint {
                humanoidBindings[other] = nil
            }
            humanoidBindings[joint] = boneIndex
        } else {
            humanoidBindings[joint] = nil
        }
        let mapped = humanoidBindings.count
        humanoidBindingNote = "已绑定 \(mapped) 个人体关节（含手动调整）"
        let boneName = boneIndex.map { model.bones[$0].name } ?? "未绑定"
        MMDLog.shared.info("Manual humanoid bind: \(joint.rawValue)=\(boneName)", category: "Bones")
        objectWillChange.send()
    }

    func humanoidBoneIndex(for joint: MMDHumanoidJoint) -> Int? {
        guard let index = humanoidBindings[joint],
              index >= 0, index < model.bones.count else { return nil }
        return index
    }

    func humanoidJoint(forBone index: Int) -> MMDHumanoidJoint? {
        humanoidBindings.first { $0.value == index }?.key
    }

    func applyPosePreset(_ preset: MMDPosePreset) {
        boneRotations.removeAll()
        boneOffsets.removeAll()
        switch preset {
        case .neutral:
            break
        case .aPose:
            setPreset(.leftUpperArm, SIMD3<Float>(0, 0, 35))
            setPreset(.rightUpperArm, SIMD3<Float>(0, 0, -35))
        case .tPose:
            setPreset(.leftUpperArm, SIMD3<Float>(0, 0, 88))
            setPreset(.rightUpperArm, SIMD3<Float>(0, 0, -88))
        case .wave:
            setPreset(.rightUpperArm, SIMD3<Float>(0, 0, -98))
            setPreset(.rightForearm, SIMD3<Float>(-45, 0, 0))
            setPreset(.rightHand, SIMD3<Float>(0, 0, -20))
        case .sit:
            // Positive X on these rigs swings the thigh backward; that made
            // the old preset fold both legs behind the body. Thigh forward
            // (negative X) + shin back (positive X) produces a normal seated
            // right angle with the feet below the knees.
            setPreset(.leftThigh, SIMD3<Float>(-82, 0, 0))
            setPreset(.rightThigh, SIMD3<Float>(-82, 0, 0))
            setPreset(.leftShin, SIMD3<Float>(82, 0, 0))
            setPreset(.rightShin, SIMD3<Float>(82, 0, 0))
            setPreset(.leftUpperArm, SIMD3<Float>(0, 0, 18))
            setPreset(.rightUpperArm, SIMD3<Float>(0, 0, -18))
            setPreset(.leftForearm, SIMD3<Float>(-24, 0, 0))
            setPreset(.rightForearm, SIMD3<Float>(-24, 0, 0))
            // Lower the whole rig by roughly one thigh length; otherwise
            // the seated pose floats at standing hip height.
            if let center = humanoidBoneIndex(for: .center) {
                boneOffsets[center] = SIMD3<Float>(0, -model.bounds.height * 0.24, 0)
            }
        }
    }

    private func setPreset(_ joint: MMDHumanoidJoint, _ degrees: SIMD3<Float>) {
        guard let index = humanoidBoneIndex(for: joint) else { return }
        // Presets are authored targets; do not let the conservative joint
        // clamp turn a valid knee bend into a nearly straight leg.
        boneRotations[index] = degrees
    }

    static func normalizedBoneName(_ name: String) -> String {
        var value = name.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "・", with: "")
            .replacingOccurrences(of: "･", with: "")
            .lowercased()
        // Unreal / Mixamo exports wrap every bone in a rig prefix. Strip it
        // before alias matching so "Bip001 L Thigh" resolves to "lthigh".
        for prefix in ["bip001", "bip01", "mixamorig", "armature"] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
        }
        value = value.replacingOccurrences(of: ":", with: "")
        return value
    }

    // MARK: - Playback

    func togglePlayback() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        guard hasMotion || hasCameraMotion else { return }
        if currentFrame >= duration - 0.05 { currentFrame = 0 }
        isPlaying = true
        if let audioPlayer {
            audioPlayer.numberOfLoops = loopPlayback ? -1 : 0
            audioPlayer.currentTime = min(audioPlayer.duration, TimeInterval(currentFrame / frameRate))
            audioPlayer.play()
        }
        lastTick = CACurrentMediaTime()
        timer?.invalidate()
        let newTimer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        newTimer.tolerance = 0.003
        timer = newTimer
        RunLoop.main.add(newTimer, forMode: .common)
    }

    func pause() {
        isPlaying = false
        audioPlayer?.pause()
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard isPlaying, hasMotion || hasCameraMotion else { return }
        let now = CACurrentMediaTime()
        let delta = Float(max(0, now - lastTick))
        lastTick = now
        currentFrame += delta * frameRate * max(0.1, playbackSpeed)
        if currentFrame >= duration {
            if loopPlayback {
                currentFrame = currentFrame.truncatingRemainder(dividingBy: max(duration, 0.1))
            } else {
                currentFrame = duration
                pause()
            }
        }
        if let audioPlayer, isPlaying {
            let expected = TimeInterval(currentFrame / frameRate)
            if abs(audioPlayer.currentTime - expected) > 0.12 {
                audioPlayer.currentTime = min(audioPlayer.duration, expected)
            }
            if !audioPlayer.isPlaying && currentFrame < duration {
                audioPlayer.play()
            }
        }
    }

    func seek(to frame: Float) {
        let target = max(0, min(duration, frame))
        if abs(target - currentFrame) > 2 { springPhysics.reset() }
        currentFrame = target
        audioPlayer?.currentTime = min(audioPlayer?.duration ?? 0, TimeInterval(currentFrame / frameRate))
    }

    /// Sub-frame playback position for the renderer.
    ///
    /// `currentFrame` is published at 30 Hz so SwiftUI does not rebuild the
    /// whole inspector tree on every display refresh. Rendering reads this
    /// value instead: on a 120 Hz ProMotion canvas the old code reused the same
    /// pose for four consecutive frames, which read as stutter even though the
    /// frame counter said 120.
    func interpolatedFrame(now: CFTimeInterval = CACurrentMediaTime()) -> Float {
        guard isPlaying, hasMotion || hasCameraMotion else { return currentFrame }
        let elapsed = Float(max(0, now - lastTick))
        var frame = currentFrame + elapsed * frameRate * max(0.1, playbackSpeed)
        if loopPlayback, duration > 0.1 {
            if frame >= duration { frame = frame.truncatingRemainder(dividingBy: duration) }
        } else {
            frame = min(frame, duration)
        }
        return frame
    }

    // MARK: - Animation sampling

    func effectiveBoneAnimations(frame: Float) -> [Int: MMDBoneAnimation] {
        var result: [Int: MMDBoneAnimation] = [:]
        for (boneIndex, track) in motionBoneTracks {
            if let sample = VMDMotion.evaluateBone(track: track, frame: frame) {
                result[boneIndex] = MMDBoneAnimation(position: sample.position, rotation: sample.rotation)
            }
        }
        for (boneIndex, degrees) in boneRotations {
            guard boneIndex >= 0 && boneIndex < model.bones.count else { continue }
            var animation = result[boneIndex] ?? MMDBoneAnimation()
            animation.rotation = quatFromEuler(SIMD3<Float>(mmdRadians(degrees.x), mmdRadians(degrees.y), mmdRadians(degrees.z)))
            result[boneIndex] = animation
        }
        for (boneIndex, offset) in boneOffsets {
            guard boneIndex >= 0 && boneIndex < model.bones.count else { continue }
            var animation = result[boneIndex] ?? MMDBoneAnimation()
            animation.position += offset
            result[boneIndex] = animation
        }
        // Converted models (Genshin style) often weight the legs/shoes to
        // physics-driven deform copies such as 足D / ひざD. Without a rigid-body
        // solve those copies stay at rest, so the foot slides out of the shoe
        // and the ankle texture stretches. Mirror the source bone whenever the
        // D bone has no authored track of its own.
        for pair in mirroredBonePairs where result[pair.copy] == nil {
            if let source = result[pair.source] {
                result[pair.copy] = source
            }
        }
        if physicsSettings.enabled != lastPhysicsEnabled {
            springPhysics.reset()
            lastPhysicsEnabled = physicsSettings.enabled
        }
        if physicsSettings.enabled {
            let step: Float? = isExporting ? 1 / max(1, frameRate) : nil
            result = springPhysics.apply(animations: result, model: model,
                                         settings: physicsSettings,
                                         time: Double(frame / max(1, frameRate)),
                                         forcedStep: step)
        }
        return result
    }

    /// Import a VPD static pose. Bone rotations and offsets are applied to the
    /// same manual-pose channels used by the bone gizmo, so a pose remains
    /// editable and can be layered under a VMD clip.
    @discardableResult
    func loadPose(url: URL) throws -> Int {
        pause()
        let pose = try MMDPoseParser.parse(url: url)
        boneRotations.removeAll()
        boneOffsets.removeAll()
        var matched = 0
        for item in pose.bones {
            guard let index = boneIndex(forName: item.name) else { continue }
            boneOffsets[index] = item.position
            boneRotations[index] = quatEulerDegrees(item.rotation)
            matched += 1
        }
        var morphMatched = 0
        for (name, weight) in pose.morphs {
            guard let index = model.morphs.firstIndex(where: {
                $0.name == name || $0.nameEn == name ||
                Self.normalizedBoneName($0.name) == Self.normalizedBoneName(name)
            }) else { continue }
            if morphWeights.count > index { morphWeights[index] = weight }
            morphMatched += 1
        }
        motionMappingNote = "VPD「\(pose.modelName)」：已套用 \(matched)/\(pose.bones.count) 骨骼，\(morphMatched) 个表情"
        MMDLog.shared.info(motionMappingNote, category: "Motion")
        objectWillChange.send()
        return matched
    }

    private func boneIndex(forName name: String) -> Int? {
        if let index = model.bones.firstIndex(where: { $0.name == name || (!$0.nameEn.isEmpty && $0.nameEn == name) }) {
            return index
        }
        let normalized = Self.normalizedBoneName(name)
        if !normalized.isEmpty,
           let index = model.bones.firstIndex(where: { Self.normalizedBoneName($0.name) == normalized }) {
            return index
        }
        if let joint = MMDHumanoidJoint.matching(trackName: name),
           let index = humanoidBindings[joint] {
            return index
        }
        return nil
    }

    private static func makeLipSyncEnvelope(url: URL, framesPerSecond: Double = 30) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let format = file.processingFormat
        let hop = max(1, Int(format.sampleRate / framesPerSecond))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { return [] }
        var energies: [Float] = []
        var accumulated: Float = 0
        var countInHop = 0
        while true {
            do { try file.read(into: buffer, frameCount: 4096) } catch { break }
            let length = Int(buffer.frameLength)
            if length == 0 { break }
            guard let channels = buffer.floatChannelData else { break }
            let channelCount = Int(format.channelCount)
            for frame in 0..<length {
                var sample: Float = 0
                for channel in 0..<channelCount {
                    sample += abs(channels[channel][frame])
                }
                accumulated += sample / Float(max(1, channelCount))
                countInHop += 1
                if countInHop >= hop {
                    energies.append(accumulated / Float(countInHop))
                    accumulated = 0
                    countInHop = 0
                }
            }
        }
        guard !energies.isEmpty else { return [] }
        let sorted = energies.sorted()
        let peak = max(0.001, sorted[min(sorted.count - 1, Int(Float(sorted.count) * 0.95))])
        return energies.map { min(1, max(0, $0 / peak * 0.85)) }
    }

    func effectiveMorphWeights(frame: Float? = nil) -> [Float] {
        let sampleFrame = frame ?? currentFrame
        var weights = morphWeights.count == model.morphs.count
            ? morphWeights
            : [Float](repeating: 0, count: model.morphs.count)
        if motion != nil {
            for (morphIndex, track) in motionMorphTracks {
                guard morphIndex >= 0 && morphIndex < weights.count else { continue }
                weights[morphIndex] += VMDMotion.evaluateMorph(track: track, frame: sampleFrame)
            }
        }
        if lipSyncEnabled, !lipSyncEnvelope.isEmpty, !mouthMorphIndices.isEmpty {
            let seconds = sampleFrame / max(1, frameRate)
            let position = max(0, min(lipSyncEnvelope.count - 1, Int(seconds * 30)))
            let amplitude = lipSyncEnvelope[position]
            let strength = max(0, min(1.5, lipSyncStrength))
            for index in mouthMorphIndices where index < weights.count {
                weights[index] += amplitude * strength
            }
        }
        for index in weights.indices {
            weights[index] = max(-2, min(2, weights[index]))
        }
        return weights
    }

    // MARK: - Scene objects and accessory binding

    /// Import an external PMX/folder/ZIP into app-owned storage so textures
    /// remain valid after the Files security scope is released.
    @discardableResult
    func importAttachment(from source: URL) throws -> UUID {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let root = documents.appendingPathComponent("MMDStudio/Attachments", isDirectory: true)
        let destination = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let ext = source.pathExtension.lowercased()
        let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDirectory {
            try FileManager.default.copyItem(at: source, to: destination.appendingPathComponent(source.lastPathComponent))
        } else if ext == "zip" {
            _ = try MMDZipArchive.extract(url: source, to: destination)
        } else if ["pmx", "pmd"].contains(ext) {
            try FileManager.default.copyItem(at: source, to: destination.appendingPathComponent(source.lastPathComponent))
        } else {
            throw MMDLoadError.unsupported("配饰只支持 PMX、模型文件夹或 ZIP")
        }
        guard let enumerator = FileManager.default.enumerator(at: destination, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles]) else {
            throw MMDLoadError.invalidData("无法读取配饰文件")
        }
        var pmxFiles = [URL]()
        for case let url as URL in enumerator where ["pmx", "pmd"].contains(url.pathExtension.lowercased()) {
            pmxFiles.append(url)
        }
        guard let pmx = pmxFiles.sorted(by: { $0.path < $1.path }).first else {
            throw MMDLoadError.invalidData("配饰包中没有找到 PMX")
        }
        return try addAttachment(url: pmx, autoBind: true)
    }

    /// Add an already persistent PMX, used by automatic package classification.
    @discardableResult
    func addAttachment(url: URL, autoBind: Bool = true) throws -> UUID {
        let model = try PMXParser(data: Data(contentsOf: url)).parse()
        let packageRoot = url.deletingLastPathComponent()
        var attachment = MMDAttachment(name: model.displayName == "未命名模型"
                                       ? url.deletingPathExtension().lastPathComponent : model.displayName,
                                       model: model,
                                       baseDirectory: packageRoot,
                                       fallbackRoot: baseDirectory == packageRoot ? fallbackRoot : baseDirectory)
        attachment.autoAssigned = autoBind
        attachment.sourceURL = url
        attachments.append(attachment)
        sceneRevision += 1
        let id = attachment.id
        if autoBind, let joint = suggestedAttachmentJoint(for: url.path),
           let bone = humanoidBoneIndex(for: joint) {
            bindAttachment(id: id, to: bone)
        }
        selectedAttachmentID = id
        selectedLightID = nil
        MMDLog.shared.info("Attachment imported: \(attachment.name), vertices=\(model.vertices.count), bone=\(attachment.boundBoneIndex ?? -1)", category: "Scene")
        return id
    }

    struct MMDPackageModelOption: Identifiable {
        let id: String
        let url: URL
        let name: String
        let alreadyAdded: Bool
    }

    /// PMX models shipped in the same imported archive that are not yet on
    /// the canvas. The library may intentionally show only the main model.
    func packageModelOptions() -> [MMDPackageModelOption] {
        let root = fallbackRoot ?? baseDirectory
        guard let enumerator = FileManager.default.enumerator(at: root,
                                                              includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles]) else { return [] }
        let loaded = Set(attachments.compactMap { $0.sourceURL?.standardizedFileURL.path })
        let selfPath = sourceURL?.standardizedFileURL.path
        var result: [MMDPackageModelOption] = []
        var seen = Set<String>()
        for case let url as URL in enumerator where ["pmx", "pmd"].contains(url.pathExtension.lowercased()) {
            let path = url.standardizedFileURL.path
            if path == selfPath || seen.contains(path) { continue }
            seen.insert(path)
            result.append(MMDPackageModelOption(id: path,
                                                url: url,
                                                name: url.deletingPathExtension().lastPathComponent,
                                                alreadyAdded: loaded.contains(path)))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    func addPackageModel(_ option: MMDPackageModelOption) throws -> UUID {
        try addAttachment(url: option.url, autoBind: true)
    }

    func suggestedAttachmentJoint(for name: String) -> MMDHumanoidJoint? {
        let value = name.lowercased()
        if ["hat", "cap", "crown", "helmet", "glasses", "mask", "帽", "冠", "眼镜", "面具"].contains(where: { value.contains($0) }) {
            return .head
        }
        if ["shoe", "boot", "foot", "鞋", "靴"].contains(where: { value.contains($0) }) {
            return .rightFoot
        }
        if ["bag", "backpack", "cape", "wing", "背包", "披风", "翼"].contains(where: { value.contains($0) }) {
            return .upperBody2
        }
        if ["left", "_l", ".l", "左手"].contains(where: { value.contains($0) }) {
            return .leftHand
        }
        return .rightHand
    }

    func bindAttachment(id: UUID, to boneIndex: Int?) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        if let boneIndex {
            guard model.bones.indices.contains(boneIndex) else { return }
            // Props authored around the origin should start at the selected
            // joint; assets authored in character coordinates stay untouched.
            if attachments[index].position == .zero && attachments[index].boundBoneIndex == nil {
                attachments[index].position = model.bones[boneIndex].position
            }
        }
        attachments[index].boundBoneIndex = boneIndex
        selectedAttachmentID = id
        selectedLightID = nil
        sceneEditEnabled = true
        objectWillChange.send()
    }

    func removeAttachment(id: UUID) {
        attachments.removeAll { $0.id == id }
        if selectedAttachmentID == id { selectedAttachmentID = nil }
        sceneRevision += 1
    }

    func selectAttachment(id: UUID?) {
        selectedAttachmentID = id
        selectedLightID = nil
        sceneEditEnabled = id != nil
    }

    func selectLight(id: UUID?) {
        selectedLightID = id
        selectedAttachmentID = nil
        sceneEditEnabled = id != nil
    }

    func updateAttachment(id: UUID, _ mutate: (inout MMDAttachment) -> Void) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        mutate(&attachments[index])
        objectWillChange.send()
    }

    // MARK: - Editing

    func setBoneRotation(index: Int, degrees: SIMD3<Float>) {
        guard index >= 0 && index < model.bones.count else { return }
        var value = degrees
        if jointConstraintsEnabled, let joint = humanoidJoint(forBone: index) {
            value = joint.constrained(value)
        }
        if abs(value.x) < 0.0001 && abs(value.y) < 0.0001 && abs(value.z) < 0.0001 {
            boneRotations[index] = nil
        } else {
            boneRotations[index] = value
        }
    }

    func resetBone(_ index: Int) {
        boneRotations[index] = nil
    }

    func resetAllBones() {
        boneRotations.removeAll()
        boneOffsets.removeAll()
    }

    func resetMorphs() {
        morphWeights = [Float](repeating: 0, count: model.morphs.count)
    }

    func resetMaterialSettings() {
        materialSettings = model.materials.enumerated().map { index, material in
            MMDMaterialSettings(material: material, index: index)
        }
    }

    func reloadModel() {
        springPhysics.prepare(model: model)
        modelRevision += 1
        if materialSettings.count != model.materials.count {
            materialSettings = model.materials.enumerated().map { index, material in
                MMDMaterialSettings(material: material, index: index)
            }
        }
        if morphWeights.count != model.morphs.count {
            morphWeights = [Float](repeating: 0, count: model.morphs.count)
        }
    }


    var availableBoneNames: [String] {
        model.bones.map { $0.name }
    }

    var materialNames: [String] {
        model.materials.map { $0.name }
    }
}
