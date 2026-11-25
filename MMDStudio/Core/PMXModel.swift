import Foundation
import simd

// MARK: - Model data structures

struct PMXVertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var uv: SIMD2<Float>
    var boneIndices: SIMD4<UInt32>
    var boneWeights: SIMD4<Float>
    var edgeScale: Float
}

struct PMXMaterial {
    var name: String
    var nameEn: String
    var diffuse: SIMD4<Float>
    var specular: SIMD3<Float>
    var specularPower: Float
    var ambient: SIMD3<Float>
    var drawFlags: UInt8
    var edgeColor: SIMD4<Float>
    var edgeSize: Float
    var textureIndex: Int
    var sphereIndex: Int
    var sphereMode: UInt8
    var toonReference: UInt8      // 0 = texture index, 1 = internal toon
    var toonValue: Int
    var memo: String
    var indexCount: Int

    var isDoubleSided: Bool { drawFlags & 0x01 != 0 }
    var castsGroundShadow: Bool { drawFlags & 0x02 != 0 }
    var receivesSelfShadow: Bool { drawFlags & 0x08 != 0 }
    var hasEdge: Bool { drawFlags & 0x10 != 0 }
}

struct PMXIKLink {
    var boneIndex: Int
    var hasLimit: Bool
    var lowerLimit: SIMD3<Float>
    var upperLimit: SIMD3<Float>
}

struct PMXIK {
    var targetIndex: Int
    var iterations: Int
    var angleLimit: Float
    var links: [PMXIKLink]
}

struct PMXBone {
    var name: String
    var nameEn: String
    var position: SIMD3<Float>
    var parentIndex: Int
    var layer: Int
    var flags: UInt16
    var tailIndex: Int
    var appendParent: Int
    var appendRatio: Float
    var fixedAxis: SIMD3<Float>?
    var localAxisX: SIMD3<Float>?
    var localAxisZ: SIMD3<Float>?
    var ik: PMXIK?

    var isRotatable: Bool { flags & 0x0002 != 0 }
    var isMovable: Bool { flags & 0x0004 != 0 }
    var isVisible: Bool { flags & 0x0008 != 0 }
    var inheritsRotation: Bool { flags & 0x0100 != 0 }
    var inheritsTranslation: Bool { flags & 0x0200 != 0 }
    var hasIK: Bool { flags & 0x0020 != 0 }
    var isLocalAppend: Bool { flags & 0x0080 != 0 }
}

struct PMXGroupItem {
    var morphIndex: Int
    var ratio: Float
}

struct PMXVertexOffset {
    var vertexIndex: Int
    var offset: SIMD3<Float>
}

struct PMXRigidBody {
    var name: String
    var nameEn: String
    var boneIndex: Int
    var group: UInt8
    var collisionMask: UInt16
    var shape: UInt8              // 0 sphere, 1 box, 2 capsule
    var size: SIMD3<Float>
    var position: SIMD3<Float>
    var rotation: SIMD3<Float>
    var mass: Float
    var linearDamping: Float
    var angularDamping: Float
    var restitution: Float
    var friction: Float
    var mode: UInt8               // 0 follow bone, 1 kinematic, 2 dynamic
}

struct PMXJoint {
    var name: String
    var nameEn: String
    var type: UInt8               // 0 spring 6DOF, 1 6DOF, 2 P2P, 3 cone twist, 4 slider, 5 hinge
    var bodyA: Int
    var bodyB: Int
    var position: SIMD3<Float>
    var rotation: SIMD3<Float>
    var springPosition: SIMD3<Float>
    var springRotation: SIMD3<Float>
}

struct PMXMorph {
    var name: String
    var nameEn: String
    var panel: UInt8
    var type: UInt8
    var groupItems: [PMXGroupItem]
    var vertexOffsets: [PMXVertexOffset]

    var isGroup: Bool { type == 0 }
    var isVertex: Bool { type == 1 }
}

struct PMXModel {
    var version: Float
    var name: String
    var nameEn: String
    var comment: String
    var vertices: [PMXVertex]
    var indices: [UInt32]
    var textures: [String]
    var materials: [PMXMaterial]
    var bones: [PMXBone]
    var morphs: [PMXMorph]
    var rigidBodies: [PMXRigidBody] = []
    var joints: [PMXJoint] = []
    var bounds: MMDBox
    var warnings: [String]

    var displayName: String {
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
        if !nameEn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nameEn }
        return "未命名模型"
    }
}

enum MMDLoadError: LocalizedError {
    case invalidData(String)
    case unsupported(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .invalidData(let message): return message
        case .unsupported(let message): return message
        case .io(let message): return message
        }
    }
}

/// Shared geometry hygiene for every loader. PMX and PMD both hand the mesh
/// builder a flat triangle list that is indexed straight into the vertex array,
/// and neither format guarantees the indices are in range — converted or merged
/// models regularly contain a handful of stale values. Dropping the affected
/// triangles keeps the model openable and leaves every material's index range
/// contiguous, which the renderer relies on.
enum MMDIndexSanitary {

    @discardableResult
    static func pruneOutOfRange(indices: inout [UInt32], vertexCount: Int,
                                materials: inout [PMXMaterial]) -> Int {
        guard vertexCount > 0, !indices.isEmpty else { return 0 }

        var sanitized = [UInt32]()
        sanitized.reserveCapacity(indices.count)
        var droppedTriangles = 0
        var cursor = 0

        for materialIndex in materials.indices {
            let start = min(indices.count, cursor)
            let end = min(indices.count, max(start, start + max(0, materials[materialIndex].indexCount)))
            var kept = 0
            var triangle = start
            while triangle + 2 < end {
                let a = Int(indices[triangle])
                let b = Int(indices[triangle + 1])
                let c = Int(indices[triangle + 2])
                if a < vertexCount, b < vertexCount, c < vertexCount {
                    sanitized.append(indices[triangle])
                    sanitized.append(indices[triangle + 1])
                    sanitized.append(indices[triangle + 2])
                    kept += 3
                } else {
                    droppedTriangles += 1
                }
                triangle += 3
            }
            materials[materialIndex].indexCount = kept
            cursor = end
        }

        if sanitized.count != indices.count {
            indices = sanitized
        }
        return droppedTriangles
    }
}
