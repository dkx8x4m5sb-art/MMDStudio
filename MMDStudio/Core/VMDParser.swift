import Foundation
import simd

struct VMDBoneKeyframe {
    var frame: Int
    var position: SIMD3<Float>
    var rotation: simd_quatf
    var curveX: MMDBezierCurve
    var curveY: MMDBezierCurve
    var curveZ: MMDBezierCurve
    var curveRotation: MMDBezierCurve
}

struct VMDBoneTrack {
    var name: String
    var keys: [VMDBoneKeyframe]
}

struct VMDMorphKeyframe {
    var frame: Int
    var weight: Float
}

struct VMDMorphTrack {
    var name: String
    var keys: [VMDMorphKeyframe]
}

struct VMDCameraKeyframe {
    var frame: Int
    var distance: Float
    var target: SIMD3<Float>
    var rotation: SIMD3<Float>      // radians, MMD left-handed Euler
    var fov: Float                  // degrees
    var curveX: MMDBezierCurve
    var curveY: MMDBezierCurve
    var curveZ: MMDBezierCurve
    var curveRotation: MMDBezierCurve
    var curveDistance: MMDBezierCurve
    var curveFOV: MMDBezierCurve
}

struct VMDCameraPose {
    var eye: SIMD3<Float>
    var target: SIMD3<Float>
    var fovDegrees: Float
}

struct VMDMotion {
    var name: String
    var boneTracks: [VMDBoneTrack]
    var morphTracks: [VMDMorphTrack]
    var cameraKeys: [VMDCameraKeyframe]
    var maxFrame: Int
    var frameRate: Float = 30

    var isEmpty: Bool {
        boneTracks.isEmpty && morphTracks.isEmpty && cameraKeys.isEmpty
    }

    var duration: TimeInterval {
        TimeInterval(maxFrame) / TimeInterval(frameRate)
    }

    var boneTrackNames: [String] { boneTracks.map { $0.name } }
    var morphTrackNames: [String] { morphTracks.map { $0.name } }

    static func evaluateBone(track: VMDBoneTrack, frame: Float) -> (position: SIMD3<Float>, rotation: simd_quatf)? {
        guard !track.keys.isEmpty else { return nil }
        if track.keys.count == 1 {
            return (track.keys[0].position, track.keys[0].rotation)
        }
        var lower = track.keys[0]
        var upper = track.keys[0]
        var found = false
        for key in track.keys {
            if key.frame <= Int(floorf(frame)) {
                lower = key
            } else {
                upper = key
                found = true
                break
            }
        }
        if !found {
            let last = track.keys[track.keys.count - 1]
            return (last.position, last.rotation)
        }
        if upper.frame <= lower.frame {
            return (upper.position, upper.rotation)
        }
        let t = max(0, min(1, (frame - Float(lower.frame)) / Float(upper.frame - lower.frame)))
        // MMD applies the curve stored on the arriving keyframe.
        let tx = upper.curveX.value(at: t)
        let ty = upper.curveY.value(at: t)
        let tz = upper.curveZ.value(at: t)
        let tr = upper.curveRotation.value(at: t)
        let position = SIMD3<Float>(
            lower.position.x + (upper.position.x - lower.position.x) * tx,
            lower.position.y + (upper.position.y - lower.position.y) * ty,
            lower.position.z + (upper.position.z - lower.position.z) * tz
        )
        let rotation = quatSlerp(lower.rotation, upper.rotation, tr)
        return (position, rotation)
    }

    static func evaluateMorph(track: VMDMorphTrack, frame: Float) -> Float {
        guard !track.keys.isEmpty else { return 0 }
        if track.keys.count == 1 { return track.keys[0].weight }
        var lower = track.keys[0]
        var upper = track.keys[0]
        var found = false
        for key in track.keys {
            if key.frame <= Int(floorf(frame)) {
                lower = key
            } else {
                upper = key
                found = true
                break
            }
        }
        if !found { return track.keys[track.keys.count - 1].weight }
        if upper.frame <= lower.frame { return upper.weight }
        let t = max(0, min(1, (frame - Float(lower.frame)) / Float(upper.frame - lower.frame)))
        return lower.weight + (upper.weight - lower.weight) * t
    }

    /// Computes a camera pose using MMD's convention: the eye sits on a sphere of
    /// radius `distance` around the look-at target, rotated by the camera Euler angles.
    static func evaluateCamera(keys: [VMDCameraKeyframe], frame: Float) -> VMDCameraPose? {
        guard !keys.isEmpty else { return nil }
        if keys.count == 1 { return pose(from: keys[0]) }
        var lower = keys[0]
        var upper = keys[0]
        var found = false
        for key in keys {
            if key.frame <= Int(floorf(frame)) {
                lower = key
            } else {
                upper = key
                found = true
                break
            }
        }
        if !found { return pose(from: keys[keys.count - 1]) }
        if upper.frame <= lower.frame { return pose(from: upper) }
        // One-frame gaps are camera cuts, not a one-frame interpolation ramp.
        if upper.frame - lower.frame <= 1 { return pose(from: upper) }
        let t = max(0, min(1, (frame - Float(lower.frame)) / Float(upper.frame - lower.frame)))

        func blend(_ a: Float, _ b: Float, _ curve: MMDBezierCurve) -> Float {
            a + (b - a) * curve.value(at: t)
        }

        let tx = upper.curveX.value(at: t)
        let ty = upper.curveY.value(at: t)
        let tz = upper.curveZ.value(at: t)
        let target = SIMD3<Float>(
            lower.target.x + (upper.target.x - lower.target.x) * tx,
            lower.target.y + (upper.target.y - lower.target.y) * ty,
            lower.target.z + (upper.target.z - lower.target.z) * tz
        )
        let rotation = SIMD3<Float>(
            lower.rotation.x + (upper.rotation.x - lower.rotation.x) * upper.curveRotation.value(at: t),
            lower.rotation.y + (upper.rotation.y - lower.rotation.y) * upper.curveRotation.value(at: t),
            lower.rotation.z + (upper.rotation.z - lower.rotation.z) * upper.curveRotation.value(at: t)
        )
        let distance = blend(lower.distance, upper.distance, upper.curveDistance)
        let fov = blend(lower.fov, upper.fov, upper.curveFOV)
        return makePose(target: target, rotation: rotation, distance: distance, fov: fov)
    }

    static func pose(from key: VMDCameraKeyframe) -> VMDCameraPose {
        makePose(target: key.target, rotation: key.rotation, distance: key.distance, fov: key.fov)
    }

    private static func makePose(target: SIMD3<Float>, rotation: SIMD3<Float>, distance: Float, fov: Float) -> VMDCameraPose {
        // MMD is left-handed, so build the offset there and mirror Z into our space.
        let q = quatFromEuler(rotation)
        let safeDistance = max(0.1, abs(distance))
        let offsetLH = q.act(SIMD3<Float>(0, 0, -safeDistance))
        let offsetRH = SIMD3<Float>(offsetLH.x, offsetLH.y, -offsetLH.z)
        return VMDCameraPose(eye: target + offsetRH, target: target,
                             fovDegrees: max(1, min(179, fov)))
    }
}

extension PMXByteReader {
    mutating func readFixedString(length: Int, encoding: String.Encoding, _ what: String = "") throws -> String {
        try require(length, what)
        let chunk = Array(bytes[offset..<(offset + length)])
        offset += length
        var trimmed = Array(chunk.prefix { $0 != 0 })
        // VMD truncates Shift-JIS names at a fixed byte boundary. A trailing
        // half-character would otherwise make the whole name decode as nil.
        while !trimmed.isEmpty {
            if let text = String(data: Data(trimmed), encoding: encoding) {
                return text
            }
            trimmed.removeLast()
        }
        return ""
    }
}

final class VMDParser {

    /// VMD frame numbers are 32-bit. A malformed or partially written file
    /// can contain multi-billion-frame values; cap the accepted timeline at
    /// one hour so the scrubber stays usable.
    static let saneFrameLimit = 108_000

    private var reader: PMXByteReader
    private var version = "0002"

    init(data: Data) {
        self.reader = PMXByteReader(data: data)
    }

    func parse() throws -> VMDMotion {
        let magic = try reader.readFixedString(length: 30, encoding: .shiftJIS, "VMD 文件头")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if magic.hasPrefix("Vocaloid Motion Data 0002") {
            version = "0002"
        } else if magic.hasPrefix("Vocaloid Motion Data 0001") || magic.hasPrefix("Vocaloid Motion Data file") {
            version = "0001"
        } else {
            throw MMDLoadError.invalidData("不是有效的 VMD 文件（文件头 “\(magic)”）")
        }

        let nameLength = version == "0002" ? 20 : 10
        let name = try reader.readFixedString(length: nameLength, encoding: .shiftJIS, "VMD 模型名")

        let boneCount = try reader.readInt32("骨骼关键帧数量")
        guard boneCount >= 0 && boneCount < 4_000_000 else {
            throw MMDLoadError.invalidData("VMD 骨骼关键帧数量异常（\(boneCount)）")
        }
        var boneTracks: [String: VMDBoneTrack] = [:]
        var vmdTruncated = false
        for _ in 0..<boneCount {
            guard reader.remaining >= 15 + 4 + 12 + 16 + 64 else {
                vmdTruncated = true
                MMDLog.shared.warning("VMD truncated at bone keyframe, read \(boneTracks.count) tracks")
                break
            }
            do {
                let boneName = try reader.readFixedString(length: 15, encoding: .shiftJIS, "骨骼名")
                let frame = Int(try reader.readUInt32("帧号"))
                var position = try reader.readVector3("骨骼位置")
                let qx = try reader.readFloat("四元数 X")
                let qy = try reader.readFloat("四元数 Y")
                let qz = try reader.readFloat("四元数 Z")
                let qw = try reader.readFloat("四元数 W")
                // Mirror the left-handed rotation into right-handed space.
                position.z = -position.z
                let rotation = quatNormalize(simd_quatf(ix: -qx, iy: -qy, iz: qz, r: qw))
    
                try reader.require(64, "骨骼插值")
                let interpOffset = reader.offset
                let bytes = Array(reader.bytes[interpOffset..<(interpOffset + 64)])
                reader.offset += 64
                let curveX = MMDBezierCurve(bytes: bytes, x1Index: 0, y1Index: 4, x2Index: 8, y2Index: 12)
                let curveY = MMDBezierCurve(bytes: bytes, x1Index: 1, y1Index: 5, x2Index: 9, y2Index: 13)
                let curveZ = MMDBezierCurve(bytes: bytes, x1Index: 17, y1Index: 6, x2Index: 10, y2Index: 14)
                let curveR = MMDBezierCurve(bytes: bytes, x1Index: 18, y1Index: 7, x2Index: 11, y2Index: 15)
                let key = VMDBoneKeyframe(frame: frame, position: position, rotation: rotation,
                                          curveX: curveX, curveY: curveY, curveZ: curveZ, curveRotation: curveR)
                if var track = boneTracks[boneName] {
                    track.keys.append(key)
                    boneTracks[boneName] = track
                } else {
                    boneTracks[boneName] = VMDBoneTrack(name: boneName, keys: [key])
                }
            } catch {
                vmdTruncated = true
                MMDLog.shared.warning("VMD bone keyframe parse stopped: \(error.localizedDescription)")
                break
            }
        }

        // A truncated experimental VMD should still be usable for the
        // frames that were written successfully.
        if vmdTruncated {
            let partialTracks = boneTracks.values.map { track -> VMDBoneTrack in
                var sorted = track
                sorted.keys.sort { $0.frame < $1.frame }
                return sorted
            }.sorted { $0.name < $1.name }
            let saneTracks = partialTracks.compactMap { track -> VMDBoneTrack? in
                var clean = track
                clean.keys = clean.keys.filter { $0.frame >= 0 && $0.frame <= Self.saneFrameLimit }
                return clean.keys.isEmpty ? nil : clean
            }
            var maxFrame = 0
            for track in saneTracks { maxFrame = max(maxFrame, track.keys.last?.frame ?? 0) }
            return VMDMotion(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                             boneTracks: saneTracks, morphTracks: [], cameraKeys: [], maxFrame: maxFrame)
        }

        let morphCount = try reader.readInt32("变形关键帧数量")
        guard morphCount >= 0 && morphCount < 4_000_000 else {
            throw MMDLoadError.invalidData("VMD 变形关键帧数量异常（\(morphCount)）")
        }
        var morphTracks: [String: VMDMorphTrack] = [:]
        for _ in 0..<morphCount {
            let morphName = try reader.readFixedString(length: 15, encoding: .shiftJIS, "变形名")
            let frame = Int(try reader.readUInt32("帧号"))
            let weight = try reader.readFloat("变形权重")
            let key = VMDMorphKeyframe(frame: frame, weight: weight)
            if var track = morphTracks[morphName] {
                track.keys.append(key)
                morphTracks[morphName] = track
            } else {
                morphTracks[morphName] = VMDMorphTrack(name: morphName, keys: [key])
            }
        }

        var cameraKeys = [VMDCameraKeyframe]()
        if reader.remaining >= 4 {
            let cameraCount = try reader.readInt32("相机关键帧数量")
            guard cameraCount >= 0 && cameraCount < 1_000_000 else {
                throw MMDLoadError.invalidData("VMD 相机关键帧数量异常（\(cameraCount)）")
            }
            for _ in 0..<cameraCount {
                let frame = Int(try reader.readUInt32("相机帧号"))
                let distance = try reader.readFloat("相机距离")
                var target = try reader.readVector3("相机目标位置")
                target.z = -target.z
                let rx = try reader.readFloat("相机 X 旋转")
                let ry = try reader.readFloat("相机 Y 旋转")
                let rz = try reader.readFloat("相机 Z 旋转")
                // MMD camera interpolation is 24 bytes: six channels of x1, x2, y1, y2.
                try reader.require(24, "相机插值")
                let offset = reader.offset
                let bytes = Array(reader.bytes[offset..<(offset + 24)])
                reader.offset += 24
                let curveX = MMDBezierCurve(bytes: bytes, x1Index: 0, y1Index: 2, x2Index: 1, y2Index: 3)
                let curveY = MMDBezierCurve(bytes: bytes, x1Index: 4, y1Index: 6, x2Index: 5, y2Index: 7)
                let curveZ = MMDBezierCurve(bytes: bytes, x1Index: 8, y1Index: 10, x2Index: 9, y2Index: 11)
                let curveR = MMDBezierCurve(bytes: bytes, x1Index: 12, y1Index: 14, x2Index: 13, y2Index: 15)
                let curveDistance = MMDBezierCurve(bytes: bytes, x1Index: 16, y1Index: 18, x2Index: 17, y2Index: 19)
                let curveFOV = MMDBezierCurve(bytes: bytes, x1Index: 20, y1Index: 22, x2Index: 21, y2Index: 23)
                let fov = try reader.readUInt32("相机 FOV")
                let perspective = try reader.readUInt8("相机透视标志")
                cameraKeys.append(VMDCameraKeyframe(frame: frame, distance: distance, target: target,
                                                    // MMD mirrors Z between left/right handed
                                                    // camera Euler angles; roll is kept for
                                                    // future use even though the renderer uses
                                                    // a stable Y-up view matrix.
                                                    rotation: SIMD3<Float>(rx, ry, -rz),
                                                    fov: Float(fov), curveX: curveX, curveY: curveY,
                                                    curveZ: curveZ, curveRotation: curveR,
                                                    curveDistance: curveDistance, curveFOV: curveFOV))
                _ = perspective
            }
        }

        var discardedOutliers = false
        var cleanBoneTracks: [String: VMDBoneTrack] = [:]
        for (name, track) in boneTracks {
            var clean = track
            let filtered = clean.keys.filter { $0.frame >= 0 && $0.frame <= Self.saneFrameLimit }
            if filtered.count != clean.keys.count { discardedOutliers = true }
            clean.keys = filtered
            if !clean.keys.isEmpty { cleanBoneTracks[name] = clean }
        }
        boneTracks = cleanBoneTracks
        var cleanMorphTracks: [String: VMDMorphTrack] = [:]
        for (name, track) in morphTracks {
            var clean = track
            let filtered = clean.keys.filter { $0.frame >= 0 && $0.frame <= Self.saneFrameLimit }
            if filtered.count != clean.keys.count { discardedOutliers = true }
            clean.keys = filtered
            if !clean.keys.isEmpty { cleanMorphTracks[name] = clean }
        }
        morphTracks = cleanMorphTracks
        cameraKeys = cameraKeys.filter { key in
            let valid = key.frame >= 0 && key.frame <= Self.saneFrameLimit
            if !valid { discardedOutliers = true }
            return valid
        }
        if discardedOutliers {
            MMDLog.shared.warning("VMD contained frame values beyond \(Self.saneFrameLimit); invalid tail keys were ignored")
        }

        let boneTracksSorted = boneTracks.values.map { track -> VMDBoneTrack in
            var sorted = track
            sorted.keys.sort { $0.frame < $1.frame }
            return sorted
        }.sorted { $0.name < $1.name }

        let morphTracksSorted = morphTracks.values.map { track -> VMDMorphTrack in
            var sorted = track
            sorted.keys.sort { $0.frame < $1.frame }
            return sorted
        }.sorted { $0.name < $1.name }

        cameraKeys.sort { $0.frame < $1.frame }

        var maxFrame = 0
        for track in boneTracksSorted {
            maxFrame = max(maxFrame, track.keys.last?.frame ?? 0)
        }
        maxFrame = min(maxFrame, Self.saneFrameLimit)
        for track in morphTracksSorted {
            maxFrame = max(maxFrame, track.keys.last?.frame ?? 0)
        }
        if let last = cameraKeys.last { maxFrame = max(maxFrame, last.frame) }

        return VMDMotion(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                         boneTracks: boneTracksSorted,
                         morphTracks: morphTracksSorted,
                         cameraKeys: cameraKeys,
                         maxFrame: maxFrame)
    }
}

// MARK: - Import candidates

/// One playable clip found in an imported motion source. A zip normally holds
/// a camera file plus one motion file per model the choreographer targeted, so
/// "the first .vmd in the archive" is not a safe answer.
struct MMDMotionCandidate: Identifiable {
    let id = UUID()
    let url: URL
    /// Name stored inside the VMD (usually the model it was made for).
    let title: String
    let fileName: String
    let boneTrackCount: Int
    let morphTrackCount: Int
    let cameraKeyCount: Int
    /// Tracks that resolve to a bone of the model being loaded. Zero means the
    /// clip exists but belongs to a different skeleton.
    let mappedBoneCount: Int
    let maxFrame: Int
    let frameRate: Float

    var durationSeconds: Double { Double(maxFrame) / Double(max(1, frameRate)) }

    /// A clip with only camera keys cannot move a model. Treating it as
    /// "imported successfully" is what made a valid motion look broken.
    var isPlayable: Bool { boneTrackCount > 0 || morphTrackCount > 0 }

    var summary: String {
        let seconds = Int(durationSeconds.rounded())
        let clock = String(format: "%d:%02d", seconds / 60, seconds % 60)
        return "\(clock) · 匹配 \(mappedBoneCount) 根骨骼 · 表情 \(morphTrackCount) · \(boneTrackCount) 条轨道"
    }
}

/// Result of scanning a picked .vmd or .zip.
struct MMDMotionImport {
    let folder: URL?
    let candidates: [MMDMotionCandidate]
    let audioFiles: [URL]
    /// Files inside the zip that carried camera keys but no bone motion.
    /// They are still useful: a camera VMD is how the author framed the shot.
    let cameraOnlyFiles: [URL]
    let unreadable: [String]

    var skippedCameraOnly: [String] { cameraOnlyFiles.map { $0.lastPathComponent } }
    var best: MMDMotionCandidate? { candidates.first }

    /// Two clips that both bind to this model: the user has to pick which cut
    /// of the dance to use (different model versions of the same motion).
    var needsChoice: Bool { candidates.count > 1 }
}
