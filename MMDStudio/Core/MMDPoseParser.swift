//
//  MMDPoseParser.swift
//  MMD Studio
//
//  VPD 姿势解析。
//

import Foundation
import CoreFoundation
import simd

/// VPD（Vocaloid Pose Data）读取器。VPD 把静态姿势存成骨骼名
/// + 局部平移 + 四元数，后面可选地跟 Morph 权重。
/// MMD 还用 `.vac` 存挂件变换；这个解析器
/// 不假装能读那种格式。
struct MMDPoseBone {
    var name: String
    var position: SIMD3<Float>
    var rotation: simd_quatf
}

struct MMDPose {
    var modelName: String
    var bones: [MMDPoseBone]
    var morphs: [(name: String, weight: Float)]
}

enum MMDPoseParser {

    static let shiftJIS: String.Encoding = {
        let cf = CFStringEncoding(CFStringEncodings.shiftJIS.rawValue)
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }()

    static func parse(url: URL) throws -> MMDPose {
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: shiftJIS)
            ?? String(data: data, encoding: .utf8)
            ?? ""
        guard !text.isEmpty else {
            throw MMDLoadError.invalidData("无法读取 VPD 文本（文件可能不是 Shift-JIS/UTF-8）")
        }
        return try parse(text: text)
    }

    static func parse(text: String) throws -> MMDPose {
        let rawLines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var index = 0
        // 实际文件头有两种："Vocaloid Pose Data file (VPD)" 和
        // "Vocaloid Pose Data file"。宽容导入下两种都可以没有。
        while index < rawLines.count,
              rawLines[index].lowercased().contains("vocaloid pose data") {
            index += 1
        }
        while index < rawLines.count, rawLines[index].hasPrefix(";") {
            index += 1
        }
        var modelName = "VPD Pose"
        if index < rawLines.count, rawLines[index].hasSuffix(";"), !isInteger(rawLines[index]) {
            modelName = String(rawLines[index].dropLast()).trimmingCharacters(in: .whitespaces)
            index += 1
        }
        guard index < rawLines.count, let boneCount = Int(rawLines[index]) else {
            throw MMDLoadError.invalidData("VPD 缺少骨骼数量")
        }
        index += 1
        guard boneCount >= 0 && boneCount < 200_000 else {
            throw MMDLoadError.invalidData("VPD 骨骼数量异常（\(boneCount)）")
        }
        var bones: [MMDPoseBone] = []
        for _ in 0..<boneCount {
            guard index < rawLines.count else {
                throw MMDLoadError.invalidData("VPD 骨骼数据提前结束")
            }
            let line = rawLines[index]
            guard let separator = line.lastIndex(of: ";") else {
                throw MMDLoadError.invalidData("VPD 骨骼行格式错误：\(line)")
            }
            let name = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let values = line[line.index(after: separator)...]
                .split(separator: ",")
                .compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
            guard values.count == 7 else {
                throw MMDLoadError.invalidData("VPD 骨骼「\(name)」需要 7 个数值（位置 3 + 四元数 4）")
            }
            var position = SIMD3<Float>(values[0], values[1], -values[2])
            position = sanitize(position)
            // 把 MMD 的左手四元数转成渲染器的右手空间：
            // 取反 X 与 Y 的旋转分量。
            var quaternion = simd_quatf(ix: -values[3], iy: -values[4], iz: values[5], r: values[6])
            if simd_length(quaternion.vector) < 0.0001 {
                quaternion = mmdIdentityQuaternion
            } else {
                quaternion = simd_quatf(vector: simd_normalize(quaternion.vector))
            }
            bones.append(MMDPoseBone(name: name, position: position, rotation: quaternion))
            index += 1
        }
        var morphs: [(String, Float)] = []
        if index < rawLines.count, let morphCount = Int(rawLines[index]) {
            index += 1
            for _ in 0..<max(0, morphCount) where index < rawLines.count {
                let line = rawLines[index]
                let parts = line.split(separator: ";", maxSplits: 1).map(String.init)
                if parts.count == 2, let weight = Float(parts[1]) {
                    morphs.append((parts[0], weight))
                }
                index += 1
            }
        }
        return MMDPose(modelName: modelName, bones: bones, morphs: morphs.map { ($0.0, $0.1) })
    }

    private static func isInteger(_ text: String) -> Bool {
        Int(text) != nil
    }

    private static func sanitize(_ value: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(value.x.isFinite ? value.x : 0,
                     value.y.isFinite ? value.y : 0,
                     value.z.isFinite ? value.z : 0)
    }
}
