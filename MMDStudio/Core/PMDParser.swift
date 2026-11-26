//
//  PMDParser.swift
//  MMD Studio
//
//  PMD 1.0 解析，转换为内部 PMX 结构。
//

import Foundation
import CoreFoundation
import simd

/// Legacy PMD (Polygon Model Data) reader. PMD is the pre-PMX MMD model
/// format: fixed-width Shift-JIS names, 16-bit vertex indices and up to two
/// bone weights per vertex. The parser converts it into the same PMXModel
/// representation used by the PMX pipeline so the existing renderer, physics,
/// IK and motion retargeting work unchanged.
final class PMDParser {

    private struct Reader {
        let data: Data
        var offset = 0
        var remaining: Int { max(0, data.count - offset) }

        mutating func need(_ count: Int, _ what: String) throws {
            guard count >= 0, offset >= 0, offset + count <= data.count else {
                throw MMDLoadError.invalidData("PMD 文件不完整：读取\(what)时越界")
            }
        }

        mutating func u8(_ what: String) throws -> UInt8 {
            try need(1, what)
            defer { offset += 1 }
            return data[data.startIndex + offset]
        }

        mutating func u16(_ what: String) throws -> UInt16 {
            try need(2, what)
            let value = data.withUnsafeBytes { raw -> UInt16 in
                let base = raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                return UInt16(base[0]) | (UInt16(base[1]) << 8)
            }
            offset += 2
            return value
        }

        mutating func u32(_ what: String) throws -> UInt32 {
            try need(4, what)
            let value = data.withUnsafeBytes { raw -> UInt32 in
                let base = raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                return UInt32(base[0]) | (UInt32(base[1]) << 8) |
                       (UInt32(base[2]) << 16) | (UInt32(base[3]) << 24)
            }
            offset += 4
            return value
        }

        mutating func i32(_ what: String) throws -> Int32 { Int32(bitPattern: try u32(what)) }

        mutating func f32(_ what: String) throws -> Float {
            Float(bitPattern: try u32(what))
        }

        mutating func vec2(_ what: String) throws -> SIMD2<Float> {
            SIMD2<Float>(try f32(what), try f32(what))
        }

        mutating func vec3(_ what: String) throws -> SIMD3<Float> {
            SIMD3<Float>(try f32(what), try f32(what), try f32(what))
        }

        func peekString(length: Int, at position: Int, encoding: String.Encoding) -> String {
            guard position >= 0, position + length <= data.count else { return "" }
            let start = data.startIndex + position
            let slice = data[start..<(start + length)]
            var bytes = [UInt8](slice)
            if let zero = bytes.firstIndex(of: 0) { bytes = Array(bytes.prefix(upTo: zero)) }
            let text = String(data: Data(bytes), encoding: encoding) ?? ""
            return text.replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private var reader: Reader
    private var warnings: [String] = []

    init(data: Data) {
        self.reader = Reader(data: data)
    }

    /// Header-only name read used by the library list before a full parse.
    static func readDisplayName(data: Data) -> String? {
        guard data.count >= 27 else { return nil }
        let bytes = Array(data[7..<27])
        let cf = CFStringEncoding(CFStringEncodings.shiftJIS.rawValue)
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        var payload = bytes
        if let zero = payload.firstIndex(of: 0) { payload = Array(payload.prefix(upTo: zero)) }
        let name = String(data: Data(payload), encoding: encoding)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }

    static let shiftJIS: String.Encoding = {
        let cf = CFStringEncoding(CFStringEncodings.shiftJIS.rawValue)
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }()

    func parse() throws -> PMXModel {
        guard reader.remaining >= 7 else { throw MMDLoadError.invalidData("PMD 文件过短") }
        let magic0 = try reader.u8("文件头")
        let magic1 = try reader.u8("文件头")
        let magic2 = try reader.u8("文件头")
        guard magic0 == 0x50, magic1 == 0x6D, magic2 == 0x64 else {
            throw MMDLoadError.invalidData("不是有效的 PMD 文件（文件头不是 “Pmd”）")
        }
        let version = try reader.f32("版本")
        guard version >= 0.9 && version <= 1.1 else {
            throw MMDLoadError.unsupported("暂不支持 PMD 版本 \(version)")
        }

        let rawName = readFixedString(20, "模型名")
        let rawComment = readFixedString(256, "模型注释")

        var vertices = try parseVertices()
        var indices = try parseIndices(vertexCount: vertices.count)
        var materials = try parseMaterialsAndTextures()
        let textures = materialTextures
        var bones = try parseBones()
        let iks = try parseIK()
        let morphs = try parseMorphs(vertexCount: vertices.count)
        try parseDisplayInfo()
        // Optional sections. A truncated PMD (or one saved without English /
        // toon / physics data) is still usable.
        if reader.remaining > 0 { try parseEnglishAndToon(boneCount: bones.count, morphCount: faceDisplayCountValue) }
        let rigidBodies = reader.remaining > 0 ? (try parseRigidBodies(boneCount: bones.count)) : []
        let joints = reader.remaining > 0 ? (try parseJoints(bodyCount: rigidBodies.count)) : []

        var ikBones: Set<Int> = []
        for ik in iks {
            guard ik.bone >= 0, ik.bone < bones.count else { continue }
            var links: [PMXIKLink] = []
            for link in ik.links where link >= 0 && link < bones.count {
                links.append(PMXIKLink(boneIndex: link, hasLimit: false,
                                       lowerLimit: .zero, upperLimit: .zero))
            }
            bones[ik.bone].ik = PMXIK(targetIndex: ik.target,
                                      iterations: max(1, min(64, Int(ik.iterations))),
                                      angleLimit: max(0.02, min(1.0, ik.weight)),
                                      links: links)
            bones[ik.bone].flags |= 0x0020
            ikBones.insert(ik.bone)
        }

        let droppedTriangles = MMDIndexSanitary.pruneOutOfRange(indices: &indices,
                                                               vertexCount: vertices.count,
                                                               materials: &materials)
        if droppedTriangles > 0 {
            warnings.append("丢弃 \(droppedTriangles) 个引用了越界顶点的三角形（顶点表只有 \(vertices.count) 个）")
        }
        normalize(vertices: &vertices, materials: materials, bones: bones)
        var bounds = MMDBox.empty
        for vertex in vertices { bounds.expand(with: vertex.position) }
        if bounds.minPoint.x > bounds.maxPoint.x { bounds = MMDBox(minPoint: .zero, maxPoint: .zero) }

        let title = rawName.isEmpty ? "未命名 PMD 模型" : rawName
        return PMXModel(version: version,
                        name: title,
                        nameEn: "",
                        comment: rawComment,
                        vertices: vertices,
                        indices: indices,
                        textures: textures,
                        materials: materials,
                        bones: bones,
                        morphs: morphs,
                        rigidBodies: rigidBodies,
                        joints: joints,
                        bounds: bounds,
                        warnings: ["PMD 兼容导入：\(ikBones.count) 个 IK、\(vertices.count) 顶点、\(bones.count) 骨骼"] + warnings)
    }

    private func readFixedString(_ length: Int, _ what: String) -> String {
        let text = reader.peekString(length: length, at: reader.offset, encoding: Self.shiftJIS)
        reader.offset += length
        return text
    }

    private func parseVertices() throws -> [PMXVertex] {
        let count = Int(try reader.u32("顶点数量"))
        guard count >= 0 && count < 20_000_000 else {
            throw MMDLoadError.invalidData("PMD 顶点数量异常（\(count)）")
        }
        var result: [PMXVertex] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            var position = try reader.vec3("顶点位置")
            position.z = -position.z
            var normal = try reader.vec3("顶点法线")
            normal.z = -normal.z
            let uv = try reader.vec2("顶点 UV")
            let bone0 = Int(try reader.u16("骨骼索引 0"))
            let bone1 = Int(try reader.u16("骨骼索引 1"))
            let weightByte = try reader.u8("骨骼权重")
            _ = try reader.u8("边缘标志")
            let weight0 = Float(weightByte) / 100
            let weight1 = 1 - weight0
            result.append(PMXVertex(position: position,
                                    normal: normal,
                                    uv: uv,
                                    boneIndices: SIMD4<UInt32>(UInt32(bone0), UInt32(bone1), 0, 0),
                                    boneWeights: SIMD4<Float>(weight0, weight1, 0, 0),
                                    edgeScale: 1))
        }
        return result
    }

    private func parseIndices(vertexCount: Int) throws -> [UInt32] {
        let count = Int(try reader.u32("索引数量"))
        guard count >= 0 && count < 60_000_000, count % 3 == 0 else {
            throw MMDLoadError.invalidData("PMD 索引数量异常（\(count)）")
        }
        var result: [UInt32] = []
        result.reserveCapacity(count)
        for _ in 0..<(count / 3) {
            let a = UInt32(try reader.u16("索引"))
            let b = UInt32(try reader.u16("索引"))
            let c = UInt32(try reader.u16("索引"))
            // PMD is left-handed; flip one edge to preserve front faces.
            result.append(a)
            result.append(c)
            result.append(b)
        }
        if result.contains(where: { Int($0) >= vertexCount }) {
            warnings.append("PMD 索引越界，已过滤非法三角形")
            var fixed: [UInt32] = []
            fixed.reserveCapacity(result.count)
            for index in stride(from: 0, to: result.count, by: 3) where index + 2 < result.count {
                let a = result[index], b = result[index + 1], c = result[index + 2]
                if Int(a) < vertexCount && Int(b) < vertexCount && Int(c) < vertexCount {
                    fixed.append(contentsOf: [a, b, c])
                }
            }
            return fixed
        }
        return result
    }

    private func parseMaterialsAndTextures() throws -> [PMXMaterial] {
        let count = Int(try reader.u32("材质数量"))
        guard count >= 0 && count < 100_000 else {
            throw MMDLoadError.invalidData("PMD 材质数量异常（\(count)）")
        }
        var result: [PMXMaterial] = []
        var textureNames: [String] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            // The PMD material record is exactly 70 bytes; parse it as a
            // packed block so field offsets stay unambiguous.
            var record: [UInt8] = []
            record.reserveCapacity(70)
            for _ in 0..<70 { record.append(try reader.u8("材质记录")) }
            func f(_ index: Int) -> Float {
                let o = index * 4
                return Float(bitPattern: UInt32(record[o]) | (UInt32(record[o + 1]) << 8) |
                             (UInt32(record[o + 2]) << 16) | (UInt32(record[o + 3]) << 24))
            }
            let rgba = SIMD4<Float>(f(0), f(1), f(2), f(3))
            let specular = SIMD3<Float>(f(4), f(5), f(6))
            let specularPower = f(7)
            let ambient = SIMD3<Float>(f(8), f(9), f(10))
            let toon = record[44]
            _ = record[45] // edge flag
            let indexCount = Int(UInt32(record[46]) | (UInt32(record[47]) << 8) |
                                 (UInt32(record[48]) << 16) | (UInt32(record[49]) << 24))
            let textureBytes = Array(record[50..<70])
            var textureName = String(data: Data(textureBytes), encoding: Self.shiftJIS) ?? ""
            textureName = textureName.replacingOccurrences(of: "\0", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var sphereIndex = -1
            if textureName.contains("*") {
                let parts = textureName.components(separatedBy: "*")
                textureName = parts.first ?? ""
                let sphere = parts.count > 1 ? parts[1] : ""
                if !sphere.isEmpty {
                    sphereIndex = textureNames.count
                    textureNames.append(sphere)
                }
            } else if textureName.lowercased().hasSuffix(".spa") || textureName.lowercased().hasSuffix(".sph") {
                sphereIndex = textureNames.count
                textureNames.append(textureName)
                textureName = ""
            }
            var textureIndex = -1
            if !textureName.isEmpty {
                textureIndex = textureNames.count
                textureNames.append(textureName)
            }
            result.append(PMXMaterial(name: "材质 \(result.count + 1)",
                                      nameEn: "",
                                      diffuse: rgba,
                                      specular: specular,
                                      specularPower: specularPower,
                                      ambient: ambient,
                                      drawFlags: 0x1B,
                                      edgeColor: SIMD4<Float>(0, 0, 0, 1),
                                      edgeSize: 0.5,
                                      textureIndex: textureIndex,
                                      sphereIndex: sphereIndex,
                                      sphereMode: sphereIndex >= 0 ? 1 : 0,
                                      toonReference: toon < 10 ? 1 : 0,
                                      toonValue: Int(toon),
                                      memo: "",
                                      indexCount: indexCount))
        }
        self.materialTextures = textureNames
        return result
    }

    private var materialTextures: [String] = []

    private func parseBones() throws -> [PMXBone] {
        let count = Int(try reader.u16("骨骼数量"))
        guard count >= 0 && count < 100_000 else {
            throw MMDLoadError.invalidData("PMD 骨骼数量异常（\(count)）")
        }
        var result: [PMXBone] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            let name = readFixedString(20, "骨骼名称")
            let parent = Int(try reader.u16("父骨骼"))
            let tail = Int(try reader.u16("显示子骨骼"))
            let type = try reader.u8("骨骼类型")
            let ikTarget = Int(try reader.u16("IK 目标骨骼"))
            var position = try reader.vec3("骨骼位置")
            position.z = -position.z
            var flags: UInt16 = 0x0002 | 0x0008
            if type == 1 { flags |= 0x0004 }
            if type == 2 { flags |= 0x0020 }
            result.append(PMXBone(name: name,
                                  nameEn: "",
                                  position: position,
                                  parentIndex: parent == 0xFFFF ? -1 : parent,
                                  layer: 0,
                                  flags: flags,
                                  tailIndex: tail == 0xFFFF ? -1 : tail,
                                  appendParent: -1,
                                  appendRatio: 0,
                                  fixedAxis: nil,
                                  localAxisX: nil,
                                  localAxisZ: nil,
                                  ik: nil))
            _ = ikTarget
        }
        for index in result.indices {
            if result[index].parentIndex < 0 || result[index].parentIndex >= count {
                result[index].parentIndex = -1
            }
        }
        return result
    }

    private struct PMDIK {
        var bone: Int
        var target: Int
        var iterations: UInt16
        var weight: Float
        var links: [Int]
    }

    private func parseIK() throws -> [PMDIK] {
        let count = Int(try reader.u16("IK 数量"))
        guard count >= 0 && count < 4096 else { return [] }
        var result: [PMDIK] = []
        for _ in 0..<count {
            let bone = Int(try reader.u16("IK 骨骼"))
            let target = Int(try reader.u16("IK 目标"))
            let linkCount = Int(try reader.u8("IK 链接数量"))
            let iterations = try reader.u16("IK 迭代次数")
            let weight = try reader.f32("IK 单位角")
            var links: [Int] = []
            for _ in 0..<linkCount { links.append(Int(try reader.u16("IK 链接骨骼"))) }
            result.append(PMDIK(bone: bone, target: target, iterations: iterations,
                                weight: weight, links: links))
        }
        return result
    }

    private func parseMorphs(vertexCount: Int) throws -> [PMXMorph] {
        let count = Int(try reader.u16("表情数量"))
        guard count >= 0 && count < 100_000 else { return [] }
        var result: [PMXMorph] = []
        for _ in 0..<count {
            let name = readFixedString(20, "表情名称")
            let type = try reader.u8("表情类型")
            let vertexCountForMorph = Int(try reader.u32("表情顶点数量"))
            guard vertexCountForMorph >= 0 && vertexCountForMorph < 10_000_000 else {
                throw MMDLoadError.invalidData("PMD 表情顶点数量异常")
            }
            var morph = PMXMorph(name: name, nameEn: "", panel: type,
                                 type: 1, groupItems: [], vertexOffsets: [])
            for _ in 0..<vertexCountForMorph {
                let index = Int(try reader.u32("表情顶点索引"))
                var offset = try reader.vec3("表情顶点偏移")
                offset.z = -offset.z
                if index >= 0 && index < vertexCount {
                    morph.vertexOffsets.append(PMXVertexOffset(vertexIndex: index, offset: offset))
                }
            }
            result.append(morph)
        }
        return result
    }

    private var faceDisplayCountValue = 0
    private var boneDisplayNameCountValue = 0

    private func parseDisplayInfo() throws {
        guard reader.remaining >= 1 else { return }
        let faceDisplayCount = Int(try reader.u8("表情显示数量"))
        faceDisplayCountValue = faceDisplayCount
        for _ in 0..<faceDisplayCount { _ = try reader.u16("表情显示索引") }
        guard reader.remaining >= 1 else { return }
        let boneDisplayNameCount = Int(try reader.u8("骨骼显示名称数量"))
        boneDisplayNameCountValue = boneDisplayNameCount
        for _ in 0..<boneDisplayNameCount { reader.offset += min(50, reader.remaining) }
        guard reader.remaining >= 4 else { return }
        let boneDisplayCount = Int(try reader.u32("骨骼显示数量"))
        guard boneDisplayCount >= 0 && boneDisplayCount < 1_000_000 else { return }
        for _ in 0..<boneDisplayCount {
            _ = try reader.u16("骨骼显示索引")
            _ = try reader.u8("骨骼显示框")
        }
    }

    private func parseEnglishAndToon(boneCount: Int, morphCount: Int) throws {
        guard reader.remaining >= 1 else { return }
        let hasEnglish = try reader.u8("英文兼容标志")
        if hasEnglish != 0 {
            reader.offset += min(20 + 256, reader.remaining)
            reader.offset += min(20 * boneCount, reader.remaining)
            reader.offset += min(20 * max(0, morphCount), reader.remaining)
            reader.offset += min(50 * boneDisplayNameCountValue, reader.remaining)
        }
        // Ten built-in toon names, 100 bytes each. Some files omit this table.
        if reader.remaining >= 1000 { reader.offset += 1000 }
    }

    private func parseRigidBodies(boneCount: Int) throws -> [PMXRigidBody] {
        guard reader.remaining >= 4 else { return [] }
        let count = Int(try reader.u32("刚体数量"))
        guard count >= 0 && count < 100_000 else { return [] }
        var result: [PMXRigidBody] = []
        for _ in 0..<count {
            let name = readFixedString(20, "刚体名称")
            var bone = Int(try reader.u16("刚体骨骼"))
            if bone == 0xFFFF || bone >= boneCount { bone = -1 }
            let group = try reader.u8("刚体组")
            let mask = try reader.u16("刚体碰撞掩码")
            let shape = try reader.u8("刚体形状")
            var size = try reader.vec3("刚体尺寸")
            size = SIMD3<Float>(max(0.001, abs(size.x)), max(0.001, abs(size.y)), max(0.001, abs(size.z)))
            var position = try reader.vec3("刚体位置")
            position.z = -position.z
            var rotation = try reader.vec3("刚体旋转")
            rotation.x = -rotation.x; rotation.y = -rotation.y
            let mass = try reader.f32("刚体质量")
            let linearDamping = try reader.f32("刚体线性阻尼")
            let angularDamping = try reader.f32("刚体角阻尼")
            let restitution = try reader.f32("刚体反弹")
            let friction = try reader.f32("刚体摩擦")
            let mode = try reader.u8("刚体模式")
            result.append(PMXRigidBody(name: name, nameEn: "", boneIndex: bone,
                                       group: group, collisionMask: mask, shape: shape,
                                       size: size, position: position, rotation: rotation,
                                       mass: max(0.001, mass), linearDamping: linearDamping,
                                       angularDamping: angularDamping,
                                       restitution: restitution, friction: friction, mode: mode))
        }
        return result
    }

    private func parseJoints(bodyCount: Int) throws -> [PMXJoint] {
        guard reader.remaining >= 4 else { return [] }
        let count = Int(try reader.u32("关节数量"))
        guard count >= 0 && count < 100_000 else { return [] }
        var result: [PMXJoint] = []
        for _ in 0..<count {
            let name = readFixedString(20, "关节名称")
            var bodyA = Int(try reader.u32("关节刚体 A"))
            var bodyB = Int(try reader.u32("关节刚体 B"))
            if bodyA >= bodyCount { bodyA = -1 }
            if bodyB >= bodyCount { bodyB = -1 }
            var position = try reader.vec3("关节位置")
            position.z = -position.z
            var rotation = try reader.vec3("关节旋转")
            rotation.x = -rotation.x; rotation.y = -rotation.y
            _ = try reader.vec3("关节位置下限")
            _ = try reader.vec3("关节位置上限")
            _ = try reader.vec3("关节旋转下限")
            _ = try reader.vec3("关节旋转上限")
            let springPosition = try reader.vec3("关节位移弹簧")
            let springRotation = try reader.vec3("关节旋转弹簧")
            result.append(PMXJoint(name: name, nameEn: "", type: 0,
                                   bodyA: bodyA, bodyB: bodyB,
                                   position: position, rotation: rotation,
                                   springPosition: springPosition,
                                   springRotation: springRotation))
        }
        return result
    }

    private func normalize(vertices: inout [PMXVertex], materials: [PMXMaterial], bones: [PMXBone]) {
        let boneCount = bones.count
        for index in vertices.indices {
            var indices4 = vertices[index].boneIndices
            var weights4 = vertices[index].boneWeights
            for slot in 0..<4 {
                if Int(indices4[slot]) >= boneCount {
                    indices4[slot] = 0
                    weights4[slot] = 0
                }
            }
            let sum = weights4.x + weights4.y + weights4.z + weights4.w
            if sum > 1e-5 { weights4 /= sum }
            else if boneCount > 0 { indices4 = SIMD4<UInt32>(0, 0, 0, 0); weights4 = SIMD4<Float>(1, 0, 0, 0) }
            vertices[index].boneIndices = indices4
            vertices[index].boneWeights = weights4
        }
    }
}
