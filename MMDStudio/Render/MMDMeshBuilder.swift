import Foundation
import Metal
import simd

struct MMDSubMesh {
    var materialIndex: Int
    var indexCount: Int
    var indexBufferOffset: Int
    var center: SIMD3<Float>
}

final class MMDMesh {

    let vertexCount: Int
    let positionsBuffer: MTLBuffer
    let normalsBuffer: MTLBuffer
    let uvsBuffer: MTLBuffer
    let boneIndicesBuffer: MTLBuffer
    let weightsBuffer: MTLBuffer
    let edgeScalesBuffer: MTLBuffer
    /// Three float4 per vertex: (C, isSDEF), R0, R1. Uploaded for every model
    /// so the vertex shader can branch on a single flag without a second
    /// pipeline state.
    let sdefBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    var subMeshes: [MMDSubMesh]
    var bounds: MMDBox
    let frontWinding: MTLWinding

    init(vertexCount: Int,
         positionsBuffer: MTLBuffer,
         normalsBuffer: MTLBuffer,
         uvsBuffer: MTLBuffer,
         boneIndicesBuffer: MTLBuffer,
         weightsBuffer: MTLBuffer,
         edgeScalesBuffer: MTLBuffer,
         sdefBuffer: MTLBuffer,
         indexBuffer: MTLBuffer,
         subMeshes: [MMDSubMesh],
         bounds: MMDBox,
         frontWinding: MTLWinding) {
        self.vertexCount = vertexCount
        self.positionsBuffer = positionsBuffer
        self.normalsBuffer = normalsBuffer
        self.uvsBuffer = uvsBuffer
        self.boneIndicesBuffer = boneIndicesBuffer
        self.weightsBuffer = weightsBuffer
        self.edgeScalesBuffer = edgeScalesBuffer
        self.sdefBuffer = sdefBuffer
        self.indexBuffer = indexBuffer
        self.subMeshes = subMeshes
        self.bounds = bounds
        self.frontWinding = frontWinding
    }

    func updatePositions(_ positions: [SIMD3<Float>]) {
        guard positions.count == vertexCount else { return }
        let destination = positionsBuffer.contents()
        positions.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                memcpy(destination, base, MemoryLayout<SIMD3<Float>>.stride * vertexCount)
            }
        }
    }
}

private struct MMDVertexPositionKey: Hashable {
    let x: Int
    let y: Int
    let z: Int
}

final class MMDMeshBuilder {

    private let device: MTLDevice

    init(device: MTLDevice) {
        self.device = device
    }

    func build(model: PMXModel, flipV: Bool = false) throws -> MMDMesh {
        let count = model.vertices.count
        guard count > 0 else {
            throw MMDLoadError.invalidData("模型没有顶点")
        }

        let positions = model.vertices.map { $0.position }
        // Many game-ripped PMX files carry split per-face normals. A smooth
        // realistic shader hides most of that, but a two/three-step toon ramp
        // turns every triangle into a hard polygonal shadow. Weld coincident
        // positions and average their normals for shading, while keeping the
        // original hard normal when the averaged direction disagrees strongly.
        let normals = Self.weldedShadingNormals(model.vertices)
        let uvs = model.vertices.map { vertex -> SIMD2<Float> in
            flipV ? SIMD2<Float>(vertex.uv.x, 1 - vertex.uv.y) : vertex.uv
        }
        // Defensive sanitation: some converted models ship bone indices past
        // the palette or weights that do not sum to 1. Reading those writes
        // garbage transforms (parts flying off) and unnormalised weights stretch
        // textures. Clamp indices and normalise the weight sum.
        let paletteCount = UInt32(max(1, model.bones.count))
        let boneIndices = model.vertices.map { vertex -> SIMD4<UInt32> in
            let index = vertex.boneIndices
            return SIMD4<UInt32>(min(index.x, paletteCount - 1),
                                 min(index.y, paletteCount - 1),
                                 min(index.z, paletteCount - 1),
                                 min(index.w, paletteCount - 1))
        }
        let weights = model.vertices.map { vertex -> SIMD4<Float> in
            var weight = vertex.boneWeights
            let total = weight.x + weight.y + weight.z + weight.w
            if total < 0.0001 { return SIMD4<Float>(1, 0, 0, 0) }
            if abs(total - 1) > 0.001 { weight /= total }
            return weight
        }
        let edgeScales = model.vertices.map { $0.edgeScale }

        var sdef = [SIMD4<Float>]()
        sdef.reserveCapacity(count * 3)
        for vertex in model.vertices {
            let flag: Float = vertex.isSDEF ? 1 : 0
            sdef.append(SIMD4<Float>(vertex.sdefCenter, flag))
            sdef.append(SIMD4<Float>(vertex.sdefRadius0, 0))
            sdef.append(SIMD4<Float>(vertex.sdefRadius1, 0))
        }

        let positionsBuffer = try makeBuffer(positions, label: "positions")
        let normalsBuffer = try makeBuffer(normals, label: "normals")
        let uvsBuffer = try makeBuffer(uvs, label: "uvs")
        let boneIndicesBuffer = try makeBuffer(boneIndices, label: "boneIndices")
        let weightsBuffer = try makeBuffer(weights, label: "weights")
        let edgeScalesBuffer = try makeBuffer(edgeScales, label: "edgeScales")
        let sdefBuffer = try makeBuffer(sdef, label: "sdef")

        guard !model.indices.isEmpty else {
            throw MMDLoadError.invalidData("模型没有面数据")
        }

        // PMX uses a left-handed coordinate system and several exporters disagree
        // about triangle winding. Flip triangles that face away from the vertex
        // normals, then detect the winding Metal should treat as front-facing.
        var indices = model.indices
        var windingScore: Float = 0
        var triangle = 0
        while triangle + 2 < indices.count {
            let i0 = Int(indices[triangle])
            let i1 = Int(indices[triangle + 1])
            let i2 = Int(indices[triangle + 2])
            let p0 = model.vertices[i0].position
            let p1 = model.vertices[i1].position
            let p2 = model.vertices[i2].position
            let faceNormal = simd_cross(p1 - p0, p2 - p0)
            let normalSum = model.vertices[i0].normal + model.vertices[i1].normal + model.vertices[i2].normal
            let alignment = simd_dot(faceNormal, normalSum)
            if alignment < 0 {
                indices.swapAt(triangle + 1, triangle + 2)
                windingScore -= alignment
            } else {
                windingScore += alignment
            }
            triangle += 3
        }
        let frontWinding: MTLWinding = windingScore >= 0 ? .counterClockwise : .clockwise
        let indexBuffer = try makeBuffer(indices, label: "indices")

        var subMeshes = [MMDSubMesh]()
        subMeshes.reserveCapacity(model.materials.count)
        var offset = 0
        for (materialIndex, material) in model.materials.enumerated() {
            let remaining = max(0, indices.count - offset)
            let indexCount = min(max(0, material.indexCount), remaining)
            guard indexCount > 0 else { continue }
            var center = SIMD3<Float>.zero
            var sampleCount = 0
            var index = offset
            while index + 2 < offset + indexCount && index + 2 < indices.count {
                center += model.vertices[Int(indices[index])].position
                sampleCount += 1
                index += 3
            }
            if sampleCount > 0 { center /= Float(sampleCount) }
            subMeshes.append(MMDSubMesh(materialIndex: materialIndex, indexCount: indexCount,
                                        indexBufferOffset: offset * 4, center: center))
            offset += indexCount
        }

        var bounds = MMDBox.empty
        for position in positions { bounds.expand(with: position) }

        return MMDMesh(vertexCount: count,
                       positionsBuffer: positionsBuffer,
                       normalsBuffer: normalsBuffer,
                       uvsBuffer: uvsBuffer,
                       boneIndicesBuffer: boneIndicesBuffer,
                       weightsBuffer: weightsBuffer,
                       edgeScalesBuffer: edgeScalesBuffer,
                       sdefBuffer: sdefBuffer,
                       indexBuffer: indexBuffer,
                       subMeshes: subMeshes,
                       bounds: bounds,
                       frontWinding: frontWinding)
    }

    /// Average normals over coincident vertices. PMX vertex positions are in
    /// model units and coincident seams are usually identical to 1e-3; using a
    /// 1e-4 grid avoids merging nearby but distinct surfaces.
    private static func weldedShadingNormals(_ vertices: [PMXVertex]) -> [SIMD3<Float>] {
        var buckets: [MMDVertexPositionKey: [SIMD3<Float>]] = [:]
        buckets.reserveCapacity(vertices.count)
        let scale: Float = 10_000
        for vertex in vertices {
            let key = MMDVertexPositionKey(
                x: Int((vertex.position.x * scale).rounded()),
                y: Int((vertex.position.y * scale).rounded()),
                z: Int((vertex.position.z * scale).rounded())
            )
            let normal = simd_length(vertex.normal) > 0.0001
                ? simd_normalize(vertex.normal)
                : SIMD3<Float>(0, 1, 0)
            buckets[key, default: []].append(normal)
        }

        var result = [SIMD3<Float>](repeating: SIMD3<Float>(0, 1, 0), count: vertices.count)
        for (index, vertex) in vertices.enumerated() {
            let original = simd_length(vertex.normal) > 0.0001
                ? simd_normalize(vertex.normal)
                : SIMD3<Float>(0, 1, 0)
            let key = MMDVertexPositionKey(
                x: Int((vertex.position.x * scale).rounded()),
                y: Int((vertex.position.y * scale).rounded()),
                z: Int((vertex.position.z * scale).rounded())
            )
            let nearby = buckets[key] ?? []
            let sum = nearby.reduce(SIMD3<Float>.zero, +)
            guard simd_length(sum) > 0.0001 else {
                result[index] = original
                continue
            }
            let average = simd_normalize(sum)
            // Preserve genuinely hard edges (cube corners, armor plates) but
            // replace the split normals that cause toon shadow facets on skin.
            result[index] = simd_dot(original, average) > 0.32 ? average : original
        }
        return result
    }

    private func makeBuffer<T>(_ array: [T], label: String) throws -> MTLBuffer {
        guard !array.isEmpty else {
            throw MMDLoadError.invalidData("空的顶点缓冲：\(label)")
        }
        let length = MemoryLayout<T>.stride * array.count
        guard let buffer = device.makeBuffer(bytes: array,
                                             length: length,
                                             options: .storageModeShared) else {
            throw MMDLoadError.io("无法创建 Metal 缓冲 \(label)")
        }
        buffer.label = label
        return buffer
    }
}
