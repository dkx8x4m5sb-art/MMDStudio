import Foundation
import simd

/// Low level reader for the little-endian PMX binary format.
struct PMXByteReader {
    let bytes: [UInt8]
    var offset: Int = 0

    init(data: Data) {
        self.bytes = [UInt8](data)
    }

    var remaining: Int { max(0, bytes.count - offset) }

    mutating func require(_ count: Int, _ what: String = "") throws {
        guard count >= 0, offset >= 0, offset + count <= bytes.count else {
            throw MMDLoadError.invalidData("PMX 文件不完整：读取\(what.isEmpty ? "数据" : what)时在偏移 \(offset) 处越界")
        }
    }

    mutating func readUInt8(_ what: String = "") throws -> UInt8 {
        try require(1, what)
        let value = bytes[offset]
        offset += 1
        return value
    }

    mutating func readUInt16(_ what: String = "") throws -> UInt16 {
        try require(2, what)
        let value = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        offset += 2
        return value
    }

    mutating func readUInt32(_ what: String = "") throws -> UInt32 {
        try require(4, what)
        let value = UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
        offset += 4
        return value
    }

    mutating func readInt32(_ what: String = "") throws -> Int {
        Int(Int32(bitPattern: try readUInt32(what)))
    }

    mutating func readFloat(_ what: String = "") throws -> Float {
        Float(bitPattern: try readUInt32(what))
    }

    mutating func readVector2(_ what: String = "") throws -> SIMD2<Float> {
        let x = try readFloat(what)
        let y = try readFloat(what)
        return SIMD2<Float>(x, y)
    }

    mutating func readVector3(_ what: String = "") throws -> SIMD3<Float> {
        let x = try readFloat(what)
        let y = try readFloat(what)
        let z = try readFloat(what)
        return SIMD3<Float>(x, y, z)
    }

    mutating func readVector4(_ what: String = "") throws -> SIMD4<Float> {
        let x = try readFloat(what)
        let y = try readFloat(what)
        let z = try readFloat(what)
        let w = try readFloat(what)
        return SIMD4<Float>(x, y, z, w)
    }

    mutating func readIndex(size: Int, signed: Bool, _ what: String = "") throws -> Int {
        switch size {
        case 1:
            let raw = try readUInt8(what)
            return signed ? Int(Int8(bitPattern: raw)) : Int(raw)
        case 2:
            let raw = try readUInt16(what)
            return signed ? Int(Int16(bitPattern: raw)) : Int(raw)
        case 4:
            let raw = try readUInt32(what)
            return signed ? Int(Int32(bitPattern: raw)) : Int(raw)
        default:
            throw MMDLoadError.unsupported("PMX 索引宽度 \(size) 不受支持")
        }
    }

    mutating func readString(encoding: String.Encoding, _ what: String = "") throws -> String {
        let length = try readInt32(what)
        guard length >= 0 else {
            throw MMDLoadError.invalidData("PMX 字符串长度非法（\(what.isEmpty ? "字符串" : what)：\(length)）")
        }
        guard length < 8_000_000 else {
            throw MMDLoadError.invalidData("PMX 字符串过长（\(length) 字节）")
        }
        try require(length, what)
        let chunk = Array(bytes[offset..<(offset + length)])
        offset += length
        guard let text = String(data: Data(chunk), encoding: encoding) else {
            throw MMDLoadError.invalidData("PMX 文本解码失败（\(what)）")
        }
        return text.replacingOccurrences(of: "\0", with: "")
    }

    mutating func skip(_ count: Int, _ what: String = "") throws {
        try require(count, what)
        offset += count
    }
}

final class PMXParser {

    private var reader: PMXByteReader
    private var version: Float = 2.0
    private var textEncoding: String.Encoding = .utf16LittleEndian
    private var vertexIndexSize = 4
    private var textureIndexSize = 4
    private var materialIndexSize = 4
    private var boneIndexSize = 4
    private var morphIndexSize = 4
    private var rigidBodyIndexSize = 4
    private var additionalUVCount = 0
    private var warnings: [String] = []

    init(data: Data) {
        self.reader = PMXByteReader(data: data)
    }

    /// Reads only the header/model-name fields. Used by the library list so a
    /// PMX whose file name was mojibaked by an old ZIP decoder still displays
    /// the correct model name written inside the PMX.
    static func readDisplayName(data: Data) -> String? {
        var reader = PMXByteReader(data: data)
        do {
            try reader.require(4, "文件头")
            let magic = Array(reader.bytes[reader.offset..<(reader.offset + 4)])
            reader.offset += 4
            guard magic == [0x50, 0x4D, 0x58, 0x20] else { return nil }
            _ = try reader.readFloat("版本")
            let headerSize = Int(try reader.readUInt8("头部长度"))
            guard headerSize >= 1, headerSize <= 64 else { return nil }
            var globals = [UInt8]()
            for _ in 0..<headerSize { globals.append(try reader.readUInt8("全局标志")) }
            guard globals.count >= 1 else { return nil }
            let encoding: String.Encoding = globals[0] == 0 ? .utf16LittleEndian : .utf8
            let name = try reader.readString(encoding: encoding, "模型名")
            let english = try reader.readString(encoding: encoding, "英文模型名")
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            let trimmedEn = english.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedEn.isEmpty ? nil : trimmedEn
        } catch {
            return nil
        }
    }

    func parse() throws -> PMXModel {
        try parseHeader()
        var vertices = try parseVertices()
        var indices = try parseIndices(vertexCount: vertices.count)
        let textures = try parseTextures()
        var materials = try parseMaterials(textureCount: textures.count)
        var bones = try parseBones()
        var morphs: [PMXMorph] = []
        var morphSectionFailed = false
        do {
            morphs = try parseMorphs(vertexCount: vertices.count, boneCount: bones.count, materialCount: materials.count)
        } catch {
            // PMX 2.1 Flip/Impulse morphs (type 9/10) are not implemented. They
            // used to abort the whole load, so a model that used them could not
            // be opened at all. Keep the mesh, materials and bones instead; the
            // byte offset is now unknown, so the optional sections are skipped.
            morphSectionFailed = true
            morphs = []
            warnings.append("变形（Morph）段解析失败，已跳过表情；模型其余部分仍可正常显示：\(error.localizedDescription)")
        }
        var rigidBodies: [PMXRigidBody] = []
        var joints: [PMXJoint] = []
        let optionalSectionStart = reader.offset
        if morphSectionFailed {
            // The byte offset is no longer trustworthy, so nothing after the
            // morph section can be parsed safely.
            rigidBodies = []
            joints = []
        } else {
            do {
                try parseDisplayFrames(boneCount: bones.count, morphCount: morphs.count)
                rigidBodies = try parseRigidBodies(boneCount: bones.count)
                joints = try parseJoints(rigidBodyCount: rigidBodies.count)
            } catch {
                // Display frames / rigid bodies / joints are optional for rendering.
                // A model must still open when a vendor writes a non-standard
                // optional section; keep the core mesh, bones and morphs.
                reader.offset = optionalSectionStart
                rigidBodies = []
                joints = []
                warnings.append("PMX 物理段解析失败，已跳过刚体/关节：\(error.localizedDescription)")
            }
        }
        try postProcess(vertices: &vertices, indices: &indices, materials: &materials, bones: &bones, morphs: &morphs)

        var bounds = MMDBox.empty
        for vertex in vertices {
            bounds.expand(with: vertex.position)
        }
        if bounds.minPoint.x > bounds.maxPoint.x {
            bounds = MMDBox(minPoint: .zero, maxPoint: .zero)
        }

        return PMXModel(
            version: version,
            name: try parseModelNamePlaceholder(),
            nameEn: modelNameEn,
            comment: modelComment,
            vertices: vertices,
            indices: indices,
            textures: textures,
            materials: materials,
            bones: bones,
            morphs: morphs,
            rigidBodies: rigidBodies,
            joints: joints,
            bounds: bounds,
            warnings: warnings
        )
    }

    // Header strings are captured while parsing the header; keep them here.
    private var modelName = ""
    private var modelNameEn = ""
    private var modelComment = ""

    private func parseModelNamePlaceholder() throws -> String {
        modelName.isEmpty ? modelNameEn : modelName
    }

    private func parseHeader() throws {
        try reader.require(4, "文件头")
        let magicBytes = Array(reader.bytes[reader.offset..<(reader.offset + 4)])
        reader.offset += 4
        guard magicBytes == [0x50, 0x4D, 0x58, 0x20] else {
            throw MMDLoadError.invalidData("不是有效的 PMX 文件（文件头不是 “PMX ”）")
        }

        version = try reader.readFloat("版本号")
        guard version >= 1.99 && version <= 2.15 else {
            throw MMDLoadError.unsupported("暂不支持 PMX 版本 \(version)")
        }

        let headerSize = Int(try reader.readUInt8("头部长度"))
        guard headerSize >= 8 else {
            throw MMDLoadError.invalidData("PMX 头部长度异常（\(headerSize)）")
        }
        var globals = [UInt8]()
        for _ in 0..<headerSize {
            globals.append(try reader.readUInt8("全局标志"))
        }

        switch globals[0] {
        case 0: textEncoding = .utf16LittleEndian
        case 1: textEncoding = .utf8
        default:
            throw MMDLoadError.unsupported("未知的 PMX 文本编码标志 \(globals[0])")
        }

        additionalUVCount = Int(globals[1])
        vertexIndexSize = Int(globals[2])
        textureIndexSize = Int(globals[3])
        materialIndexSize = Int(globals[4])
        boneIndexSize = Int(globals[5])
        morphIndexSize = Int(globals[6])
        rigidBodyIndexSize = Int(globals[7])
        for size in [vertexIndexSize, textureIndexSize, materialIndexSize, boneIndexSize, morphIndexSize, rigidBodyIndexSize] {
            guard size == 1 || size == 2 || size == 4 else {
                throw MMDLoadError.invalidData("PMX 索引宽度异常（\(size)）")
            }
        }
        if additionalUVCount > 4 {
            throw MMDLoadError.unsupported("PMX 附加 UV 数量异常（\(additionalUVCount)）")
        }

        modelName = try reader.readString(encoding: textEncoding, "模型名")
        modelNameEn = try reader.readString(encoding: textEncoding, "英文模型名")
        modelComment = try reader.readString(encoding: textEncoding, "模型注释")
        _ = try reader.readString(encoding: textEncoding, "英文注释")
    }

    private func parseVertices() throws -> [PMXVertex] {
        let count = try reader.readInt32("顶点数量")
        guard count >= 0 && count < 20_000_000 else {
            throw MMDLoadError.invalidData("顶点数量异常（\(count)）")
        }
        var vertices = [PMXVertex]()
        vertices.reserveCapacity(count)

        for index in 0..<count {
            if index % 4096 == 0 { try reader.require(1, "顶点数据") }
            var position = try reader.readVector3("顶点坐标")
            var normal = try reader.readVector3("顶点法线")
            let uv = try reader.readVector2("顶点 UV")
            // PMX uses a left-handed coordinate system; mirror Z into our right-handed renderer.
            position.z = -position.z
            normal.z = -normal.z

            if additionalUVCount > 0 {
                try reader.skip(additionalUVCount * 16, "附加 UV")
            }

            let weightType = try reader.readUInt8("顶点权重类型")
            var boneIndices = SIMD4<UInt32>(0, 0, 0, 0)
            var boneWeights = SIMD4<Float>(1, 0, 0, 0)
            var sdefCenter = SIMD3<Float>.zero
            var sdefRadius0 = SIMD3<Float>.zero
            var sdefRadius1 = SIMD3<Float>.zero

            switch weightType {
            case 0: // BDEF1
                let bone = try reader.readIndex(size: boneIndexSize, signed: true, "骨骼索引")
                boneIndices = SIMD4<UInt32>(UInt32(max(0, bone)), 0, 0, 0)
                boneWeights = SIMD4<Float>(1, 0, 0, 0)
            case 1: // BDEF2
                let bone1 = try reader.readIndex(size: boneIndexSize, signed: true, "骨骼索引")
                let bone2 = try reader.readIndex(size: boneIndexSize, signed: true, "骨骼索引")
                let weight = try reader.readFloat("骨骼权重")
                boneIndices = SIMD4<UInt32>(UInt32(max(0, bone1)), UInt32(max(0, bone2)), 0, 0)
                boneWeights = SIMD4<Float>(weight, 1 - weight, 0, 0)
            case 2, 4: // BDEF4 / QDEF
                var indices = SIMD4<UInt32>(0, 0, 0, 0)
                for slot in 0..<4 {
                    let bone = try reader.readIndex(size: boneIndexSize, signed: true, "骨骼索引")
                    indices[slot] = UInt32(max(0, bone))
                }
                var weights = SIMD4<Float>(0, 0, 0, 0)
                for slot in 0..<4 {
                    weights[slot] = try reader.readFloat("骨骼权重")
                }
                boneIndices = indices
                boneWeights = weights
            case 3: // SDEF: spherical deformation, authored for skirts, cuffs and chest
                let bone1 = try reader.readIndex(size: boneIndexSize, signed: true, "骨骼索引")
                let bone2 = try reader.readIndex(size: boneIndexSize, signed: true, "骨骼索引")
                let weight = try reader.readFloat("骨骼权重")
                var center = try reader.readVector3("SDEF C")
                var radius0 = try reader.readVector3("SDEF R0")
                var radius1 = try reader.readVector3("SDEF R1")
                // SDEF data lives in the same left-handed model space as the
                // vertices, so it needs the identical Z mirror.
                center.z = -center.z
                radius0.z = -radius0.z
                radius1.z = -radius1.z
                sdefCenter = center
                sdefRadius0 = radius0
                sdefRadius1 = radius1
                boneIndices = SIMD4<UInt32>(UInt32(max(0, bone1)), UInt32(max(0, bone2)), 0, 0)
                boneWeights = SIMD4<Float>(weight, 1 - weight, 0, 0)
            default:
                throw MMDLoadError.unsupported("不支持的顶点权重类型 \(weightType)")
            }

            let edgeScale = try reader.readFloat("边缘倍率")
            vertices.append(PMXVertex(position: position, normal: normal, uv: uv,
                                     boneIndices: boneIndices, boneWeights: boneWeights,
                                     edgeScale: edgeScale, skinType: weightType,
                                     sdefCenter: sdefCenter,
                                     sdefRadius0: sdefRadius0,
                                     sdefRadius1: sdefRadius1))
        }
        return vertices
    }

    private func parseIndices(vertexCount: Int) throws -> [UInt32] {
        let count = try reader.readInt32("面索引数量")
        guard count >= 0, count % 3 == 0, count < 60_000_000 else {
            throw MMDLoadError.invalidData("面索引数量异常（\(count)）")
        }
        var indices = [UInt32]()
        indices.reserveCapacity(count)
        for _ in 0..<count {
            let index = try reader.readIndex(size: vertexIndexSize, signed: false, "顶点索引")
            guard index >= 0 && index < vertexCount else {
                throw MMDLoadError.invalidData("面引用了不存在的顶点（索引 \(index)，顶点数 \(vertexCount)）")
            }
            indices.append(UInt32(index))
        }
        return indices
    }

    private func parseTextures() throws -> [String] {
        let count = try reader.readInt32("贴图数量")
        guard count >= 0 && count < 200_000 else {
            throw MMDLoadError.invalidData("贴图数量异常（\(count)）")
        }
        var textures = [String]()
        for _ in 0..<count {
            textures.append(try reader.readString(encoding: textEncoding, "贴图路径"))
        }
        return textures
    }

    private func parseMaterials(textureCount: Int) throws -> [PMXMaterial] {
        let count = try reader.readInt32("材质数量")
        guard count >= 0 && count < 200_000 else {
            throw MMDLoadError.invalidData("材质数量异常（\(count)）")
        }
        var materials = [PMXMaterial]()
        materials.reserveCapacity(count)

        for _ in 0..<count {
            let name = try reader.readString(encoding: textEncoding, "材质名")
            let nameEn = try reader.readString(encoding: textEncoding, "英文材质名")
            let diffuse = try reader.readVector4("漫反射颜色")
            let specular = try reader.readVector3("镜面颜色")
            let specularPower = try reader.readFloat("镜面强度")
            let ambient = try reader.readVector3("环境色")
            let flags = try reader.readUInt8("材质绘制标志")
            let edgeColor = try reader.readVector4("描边颜色")
            let edgeSize = try reader.readFloat("描边宽度")
            let textureIndex = try reader.readIndex(size: textureIndexSize, signed: true, "材质贴图索引")
            let sphereIndex = try reader.readIndex(size: textureIndexSize, signed: true, "球面贴图索引")
            let sphereMode = try reader.readUInt8("球面贴图模式")
            let toonReference = try reader.readUInt8("卡通贴图模式")
            let toonValue: Int
            if toonReference == 0 {
                toonValue = try reader.readIndex(size: textureIndexSize, signed: true, "卡通贴图索引")
            } else {
                toonValue = Int(try reader.readUInt8("内置卡通索引"))
            }
            let memo = try reader.readString(encoding: textEncoding, "材质备注")
            let surfaceCount = try reader.readInt32("材质面索引数量")
            guard surfaceCount >= 0, surfaceCount % 3 == 0 else {
                throw MMDLoadError.invalidData("材质面索引数量异常（\(surfaceCount)）")
            }

            var material = PMXMaterial(
                name: name.isEmpty ? nameEn : name,
                nameEn: nameEn,
                diffuse: diffuse,
                specular: specular,
                specularPower: specularPower,
                ambient: ambient,
                drawFlags: flags,
                edgeColor: edgeColor,
                edgeSize: edgeSize,
                textureIndex: (textureIndex >= 0 && textureIndex < textureCount) ? textureIndex : -1,
                sphereIndex: (sphereIndex >= 0 && sphereIndex < textureCount) ? sphereIndex : -1,
                sphereMode: sphereMode,
                toonReference: toonReference,
                toonValue: toonValue,
                memo: memo,
                indexCount: surfaceCount
            )
            if toonReference == 0 && (toonValue < 0 || toonValue >= textureCount) {
                material.toonValue = -1
            }
            materials.append(material)
        }
        return materials
    }

    private func parseBones() throws -> [PMXBone] {
        let count = try reader.readInt32("骨骼数量")
        guard count >= 0 && count < 100_000 else {
            throw MMDLoadError.invalidData("骨骼数量异常（\(count)）")
        }
        var bones = [PMXBone]()
        bones.reserveCapacity(count)

        for _ in 0..<count {
            let name = try reader.readString(encoding: textEncoding, "骨骼名")
            let nameEn = try reader.readString(encoding: textEncoding, "英文骨骼名")
            var position = try reader.readVector3("骨骼位置")
            position.z = -position.z
            let parent = try reader.readIndex(size: boneIndexSize, signed: true, "父骨骼索引")
            let layer = try reader.readInt32("变形层级")
            let flags = try reader.readUInt16("骨骼标志")

            var tailIndex = -1
            if flags & 0x0001 != 0 {
                tailIndex = try reader.readIndex(size: boneIndexSize, signed: true, "骨骼连接索引")
            } else {
                _ = try reader.readVector3("骨骼连接偏移")
            }

            var appendParent = -1
            var appendRatio: Float = 0
            if flags & 0x0100 != 0 || flags & 0x0200 != 0 {
                appendParent = try reader.readIndex(size: boneIndexSize, signed: true, "付与父骨骼")
                appendRatio = try reader.readFloat("付与率")
            }

            var fixedAxis: SIMD3<Float>?
            if flags & 0x0400 != 0 {
                var axis = try reader.readVector3("固定轴")
                axis.z = -axis.z
                if simd_length(axis) > 0.0001 { fixedAxis = simd_normalize(axis) }
            }

            var localAxisX: SIMD3<Float>?
            var localAxisZ: SIMD3<Float>?
            if flags & 0x0800 != 0 {
                var axisX = try reader.readVector3("局部 X 轴")
                var axisZ = try reader.readVector3("局部 Z 轴")
                axisX.z = -axisX.z
                axisZ.z = -axisZ.z
                localAxisX = axisX
                localAxisZ = axisZ
            }

            if flags & 0x2000 != 0 {
                // PMX 2.1 "external parent": the key is a bone index, so it must
                // follow boneIndexSize like every other index field. Reading a
                // fixed 4 bytes desynchronised every following bone.
                _ = try reader.readIndex(size: boneIndexSize, signed: true, "外部父变形键")
            }

            var ik: PMXIK?
            if flags & 0x0020 != 0 {
                let target = try reader.readIndex(size: boneIndexSize, signed: true, "IK 目标骨骼")
                let iterations = try reader.readInt32("IK 循环次数")
                let angleLimit = try reader.readFloat("IK 单位角")
                let linkCount = try reader.readInt32("IK 链接数量")
                guard linkCount >= 0 && linkCount < 4096 else {
                    throw MMDLoadError.invalidData("IK 链接数量异常（\(linkCount)）")
                }
                var links = [PMXIKLink]()
                for _ in 0..<linkCount {
                    let linkIndex = try reader.readIndex(size: boneIndexSize, signed: true, "IK 链接骨骼")
                    let hasLimit = try reader.readUInt8("IK 角度限制标志")
                    var lower = SIMD3<Float>.zero
                    var upper = SIMD3<Float>.zero
                    var limitEnabled = hasLimit != 0
                    if limitEnabled {
                        lower = try reader.readVector3("IK 角度下限")
                        upper = try reader.readVector3("IK 角度上限")
                        // The whole model is mirrored on Z, and a mirror turns a
                        // rotation about X/Y into its negative. Limits were kept
                        // in the original handedness, so a knee authored as
                        // "bend backwards only" ended up clamping the solver to
                        // the opposite direction and the leg folded forwards.
                        let lowX = min(-lower.x, -upper.x)
                        let highX = max(-lower.x, -upper.x)
                        let lowY = min(-lower.y, -upper.y)
                        let highY = max(-lower.y, -upper.y)
                        let lowZ = min(lower.z, upper.z)
                        let highZ = max(lower.z, upper.z)
                        lower = SIMD3<Float>(lowX, lowY, lowZ)
                        upper = SIMD3<Float>(highX, highY, highZ)
                        // A limit of exactly zero locks the bone completely.
                        // Some converters write the flag with an empty range,
                        // which used to freeze the whole leg chain.
                        if simd_length(upper - lower) < 0.0005 { limitEnabled = false }
                    }
                    links.append(PMXIKLink(boneIndex: linkIndex, hasLimit: limitEnabled,
                                           lowerLimit: lower, upperLimit: upper))
                }
                ik = PMXIK(targetIndex: target, iterations: max(1, iterations),
                           angleLimit: angleLimit, links: links)
            }

            bones.append(PMXBone(name: name.isEmpty ? nameEn : name, nameEn: nameEn,
                                 position: position, parentIndex: parent, layer: layer,
                                 flags: flags, tailIndex: tailIndex,
                                 appendParent: appendParent, appendRatio: appendRatio,
                                 fixedAxis: fixedAxis, localAxisX: localAxisX,
                                 localAxisZ: localAxisZ, ik: ik))
        }
        return bones
    }

    private func parseMorphs(vertexCount: Int, boneCount: Int, materialCount: Int) throws -> [PMXMorph] {
        let count = try reader.readInt32("变形数量")
        guard count >= 0 && count < 100_000 else {
            throw MMDLoadError.invalidData("变形数量异常（\(count)）")
        }
        var morphs = [PMXMorph]()
        morphs.reserveCapacity(count)

        for _ in 0..<count {
            let name = try reader.readString(encoding: textEncoding, "变形名")
            let nameEn = try reader.readString(encoding: textEncoding, "英文变形名")
            let panel = try reader.readUInt8("变形面板")
            let type = try reader.readUInt8("变形类型")
            let itemCount = try reader.readInt32("变形项目数量")
            guard itemCount >= 0 && itemCount < 8_000_000 else {
                throw MMDLoadError.invalidData("变形项目数量异常（\(itemCount)）")
            }

            var morph = PMXMorph(name: name.isEmpty ? nameEn : name, nameEn: nameEn,
                                 panel: panel, type: type, groupItems: [], vertexOffsets: [])

            switch type {
            case 0: // group
                for _ in 0..<itemCount {
                    let index = try reader.readIndex(size: morphIndexSize, signed: true, "组变形索引")
                    let ratio = try reader.readFloat("组变形权重")
                    if index >= 0 && index < count {
                        morph.groupItems.append(PMXGroupItem(morphIndex: index, ratio: ratio))
                    } else {
                        _ = index
                    }
                }
            case 1: // vertex
                for _ in 0..<itemCount {
                    let index = try reader.readIndex(size: vertexIndexSize, signed: false, "变形顶点索引")
                    var offset = try reader.readVector3("变形顶点偏移")
                    offset.z = -offset.z
                    if index >= 0 && index < vertexCount {
                        morph.vertexOffsets.append(PMXVertexOffset(vertexIndex: index, offset: offset))
                    }
                }
            case 2: // bone
                for _ in 0..<itemCount {
                    _ = try reader.readIndex(size: boneIndexSize, signed: true, "骨骼变形索引")
                    _ = try reader.readVector3("骨骼变形位移")
                    _ = try reader.readVector4("骨骼变形旋转")
                }
            case 3, 4, 5, 6, 7: // UV / additional UV
                for _ in 0..<itemCount {
                    _ = try reader.readIndex(size: vertexIndexSize, signed: false, "UV 变形顶点索引")
                    _ = try reader.readVector4("UV 变形偏移")
                }
            case 8: // material
                for _ in 0..<itemCount {
                    _ = try reader.readIndex(size: materialIndexSize, signed: true, "材质变形索引")
                    _ = try reader.readUInt8("材质变形方式")
                    _ = try reader.readVector4("材质漫反射偏移")
                    _ = try reader.readVector3("材质镜面偏移")
                    _ = try reader.readFloat("材质镜面强度偏移")
                    _ = try reader.readVector3("材质环境色偏移")
                    _ = try reader.readVector4("材质描边颜色偏移")
                    _ = try reader.readFloat("材质描边宽度偏移")
                    _ = try reader.readVector4("材质贴图色偏移")
                    _ = try reader.readVector4("材质球面色偏移")
                    _ = try reader.readVector4("材质卡通色偏移")
                }
            case 9, 10:
                throw MMDLoadError.unsupported("暂不支持 PMX 2.1 的 Flip/Impulse 变形（类型 \(type)）")
            default:
                throw MMDLoadError.unsupported("未知的变形类型 \(type)")
            }
            morphs.append(morph)
        }
        return morphs
    }


    private func parseDisplayFrames(boneCount: Int, morphCount: Int) throws {
        let count = Int(try reader.readInt32("表示枠数量"))
        guard count >= 0 && count < 10000 else { return }
        for _ in 0..<count {
            _ = try reader.readString(encoding: textEncoding, "表示枠名称")
            _ = try reader.readString(encoding: textEncoding, "表示枠英文名称")
            _ = try reader.readUInt8("表示枠特殊标志")
            let items = Int(try reader.readInt32("表示枠项目数量"))
            guard items >= 0 && items < 1_000_000 else { return }
            for _ in 0..<items {
                let type = try reader.readUInt8("表示枠项目类型")
                if type == 0 {
                    let index = try reader.readIndex(size: boneIndexSize, signed: true, "表示枠骨骼索引")
                    _ = min(max(index, -1), boneCount - 1)
                } else {
                    let index = try reader.readIndex(size: morphIndexSize, signed: true, "表示枠变形索引")
                    _ = min(max(index, -1), morphCount - 1)
                }
            }
        }
    }

    private func parseRigidBodies(boneCount: Int) throws -> [PMXRigidBody] {
        guard reader.remaining >= 4 else { return [] }
        let count = Int(try reader.readInt32("刚体数量"))
        guard count >= 0 && count < 100_000 else { return [] }
        if count == 0 { return [] }
        var result: [PMXRigidBody] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            let name = try reader.readString(encoding: textEncoding, "刚体名称")
            let nameEn = try reader.readString(encoding: textEncoding, "刚体英文名称")
            var bone = try reader.readIndex(size: boneIndexSize, signed: true, "刚体骨骼索引")
            if bone < 0 || bone >= boneCount { bone = -1 }
            let group = try reader.readUInt8("刚体组")
            let mask = try reader.readUInt16("刚体碰撞掩码")
            let shape = try reader.readUInt8("刚体形状")
            var size = try reader.readVector3("刚体尺寸")
            size.x = max(0.001, abs(size.x)); size.y = max(0.001, abs(size.y)); size.z = max(0.001, abs(size.z))
            var position = try reader.readVector3("刚体位置")
            position.z = -position.z
            var rotation = try reader.readVector3("刚体旋转")
            rotation.x = -rotation.x; rotation.y = -rotation.y
            let mass = try reader.readFloat("刚体质量")
            let linearDamping = try reader.readFloat("刚体线性阻尼")
            let angularDamping = try reader.readFloat("刚体角阻尼")
            let restitution = try reader.readFloat("刚体反弹")
            let friction = try reader.readFloat("刚体摩擦")
            let mode = try reader.readUInt8("刚体物理模式")
            result.append(PMXRigidBody(name: name, nameEn: nameEn, boneIndex: bone,
                                       group: group, collisionMask: mask, shape: shape,
                                       size: size, position: position, rotation: rotation,
                                       mass: max(0.001, mass), linearDamping: linearDamping,
                                       angularDamping: angularDamping, restitution: restitution,
                                       friction: friction, mode: mode))
        }
        return result
    }

    private func parseJoints(rigidBodyCount: Int) throws -> [PMXJoint] {
        guard reader.remaining >= 4 else { return [] }
        let count = Int(try reader.readInt32("关节数量"))
        guard count >= 0 && count < 100_000 else { return [] }
        if count == 0 { return [] }
        var result: [PMXJoint] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            let name = try reader.readString(encoding: textEncoding, "关节名称")
            let nameEn = try reader.readString(encoding: textEncoding, "关节英文名称")
            let type = try reader.readUInt8("关节类型")
            var bodyA = try reader.readIndex(size: rigidBodyIndexSize, signed: true, "关节刚体 A")
            var bodyB = try reader.readIndex(size: rigidBodyIndexSize, signed: true, "关节刚体 B")
            if bodyA < 0 || bodyA >= rigidBodyCount { bodyA = -1 }
            if bodyB < 0 || bodyB >= rigidBodyCount { bodyB = -1 }
            var position = try reader.readVector3("关节位置")
            position.z = -position.z
            var rotation = try reader.readVector3("关节旋转")
            rotation.x = -rotation.x; rotation.y = -rotation.y
            _ = try reader.readVector3("关节移动下限")
            _ = try reader.readVector3("关节移动上限")
            _ = try reader.readVector3("关节旋转下限")
            _ = try reader.readVector3("关节旋转上限")
            let springPosition = try reader.readVector3("关节位移弹簧")
            let springRotation = try reader.readVector3("关节旋转弹簧")
            result.append(PMXJoint(name: name, nameEn: nameEn, type: type,
                                   bodyA: bodyA, bodyB: bodyB, position: position,
                                   rotation: rotation, springPosition: springPosition,
                                   springRotation: springRotation))
        }
        return result
    }

    private func postProcess(vertices: inout [PMXVertex], indices: inout [UInt32],
                             materials: inout [PMXMaterial], bones: inout [PMXBone],
                             morphs: inout [PMXMorph]) throws {
        let boneCount = bones.count

        for index in bones.indices {
            if bones[index].parentIndex < -1 || bones[index].parentIndex >= boneCount {
                warnings.append("骨骼「\(bones[index].name)」的父骨骼索引越界，已按根骨骼处理")
                bones[index].parentIndex = -1
            }
            if bones[index].appendParent < -1 || bones[index].appendParent >= boneCount {
                bones[index].appendParent = -1
            }
            if var ik = bones[index].ik {
                if ik.targetIndex < 0 || ik.targetIndex >= boneCount {
                    bones[index].ik = nil
                } else {
                    ik.links = ik.links.filter { $0.boneIndex >= 0 && $0.boneIndex < boneCount }
                    bones[index].ik = ik
                }
            }
        }

        for index in vertices.indices {
            var indices4 = vertices[index].boneIndices
            var weights4 = vertices[index].boneWeights
            var invalid = false
            for slot in 0..<4 {
                let boneIndex = Int(indices4[slot])
                if boneIndex < 0 || boneIndex >= boneCount {
                    indices4[slot] = 0
                    weights4[slot] = 0
                    invalid = true
                }
            }
            if invalid {
                let sum = weights4.x + weights4.y + weights4.z + weights4.w
                if sum < 1e-5 && boneCount > 0 {
                    indices4 = SIMD4<UInt32>(0, 0, 0, 0)
                    weights4 = SIMD4<Float>(1, 0, 0, 0)
                }
            }
            let sum = weights4.x + weights4.y + weights4.z + weights4.w
            if sum > 1e-5 {
                weights4 /= sum
            } else if boneCount > 0 {
                indices4 = SIMD4<UInt32>(0, 0, 0, 0)
                weights4 = SIMD4<Float>(1, 0, 0, 0)
            }
            vertices[index].boneIndices = indices4
            vertices[index].boneWeights = weights4
        }

        let totalIndices = indices.count
        if materials.isEmpty && totalIndices > 0 {
            materials.append(PMXMaterial(
                name: "默认材质",
                nameEn: "Default",
                diffuse: SIMD4<Float>(1, 1, 1, 1),
                specular: SIMD3<Float>(0.1, 0.1, 0.1),
                specularPower: 5,
                ambient: SIMD3<Float>(0.2, 0.2, 0.22),
                drawFlags: 0x1A,
                edgeColor: SIMD4<Float>(0, 0, 0, 1),
                edgeSize: 0.5,
                textureIndex: -1,
                sphereIndex: -1,
                sphereMode: 0,
                toonReference: 1,
                toonValue: 0,
                memo: "",
                indexCount: totalIndices
            ))
            warnings.append("模型没有材质，已创建默认材质")
        }
        let declared = materials.reduce(0) { $0 + $1.indexCount }
        if declared != totalIndices {
            warnings.append("材质声明的面索引总数（\(declared)）与模型索引数（\(totalIndices)）不一致，已自动修正")
            var offset = 0
            for index in materials.indices {
                let remaining = totalIndices - offset
                if index == materials.count - 1 {
                    materials[index].indexCount = max(0, remaining)
                } else {
                    materials[index].indexCount = min(materials[index].indexCount, max(0, remaining))
                }
                offset += materials[index].indexCount
            }
            if offset < totalIndices && !materials.isEmpty {
                materials[materials.count - 1].indexCount += totalIndices - offset
            }
        }

        for index in morphs.indices {
            if morphs[index].isGroup {
                morphs[index].groupItems = morphs[index].groupItems.filter { $0.morphIndex < morphs.count }
            }
            if morphs[index].isVertex {
                morphs[index].vertexOffsets = morphs[index].vertexOffsets.filter { $0.vertexIndex < vertices.count }
            }
        }

        // Vertex indices were the only parsed index field left unchecked. The
        // mesh builder dereferences them directly (model.vertices[i]) and one
        // out-of-range value killed the whole app with EXC_BAD_ACCESS — which
        // is why only complex, converted models died on open while simple props
        // loaded fine. Drop the offending triangles and re-derive the material
        // ranges so the surviving faces stay contiguous.
        let droppedTriangles = MMDIndexSanitary.pruneOutOfRange(indices: &indices,
                                                               vertexCount: vertices.count,
                                                               materials: &materials)
        if droppedTriangles > 0 {
            warnings.append("丢弃 \(droppedTriangles) 个引用了越界顶点的三角形（顶点表只有 \(vertices.count) 个），其余面正常显示")
        }

        if bones.isEmpty {
            warnings.append("模型没有骨骼，将以静态模型方式渲染")
            for index in vertices.indices {
                vertices[index].boneIndices = SIMD4<UInt32>(0, 0, 0, 0)
                vertices[index].boneWeights = SIMD4<Float>(1, 0, 0, 0)
            }
        }
    }
}
