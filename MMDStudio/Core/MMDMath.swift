//
//  MMDMath.swift
//  MMD Studio
//
//  向量、矩阵与四元数工具，MMD 坐标系转换。
//

import Foundation
import simd

typealias Float3 = SIMD3<Float>
typealias Float4 = SIMD4<Float>

@inline(__always) func mmdRadians(_ value: Float) -> Float { value * .pi / 180 }
@inline(__always) func mmdDegrees(_ value: Float) -> Float { value * 180 / .pi }

extension SIMD3 where Scalar == Float {

    var length: Float {
        simd_length(self)
    }

    /// Normalized vector, returns zero for degenerate input.
    var unit: SIMD3<Float> {
        let len = simd_length(self)
        if len < 1e-6 { return .zero }
        return self / len
    }
}

extension simd_float4x4 {

    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return m
    }

    static func uniformScale(_ s: Float) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4<Float>(s, 0, 0, 0),
            SIMD4<Float>(0, s, 0, 0),
            SIMD4<Float>(0, 0, s, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    init(quaternion q: simd_quatf) {
        let x = q.imag.x, y = q.imag.y, z = q.imag.z, w = q.real
        self.init(columns: (
            SIMD4<Float>(1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w), 0),
            SIMD4<Float>(2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w), 0),
            SIMD4<Float>(2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y), 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    var translation: SIMD3<Float> {
        SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z)
    }

    var rotationMatrix: simd_float3x3 {
        simd_float3x3(columns: (
            SIMD3<Float>(columns.0.x, columns.0.y, columns.0.z).unit,
            SIMD3<Float>(columns.1.x, columns.1.y, columns.1.z).unit,
            SIMD3<Float>(columns.2.x, columns.2.y, columns.2.z).unit
        ))
    }
}

// MARK: - Quaternion helpers

let mmdIdentityQuaternion = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))

func quatNormalize(_ q: simd_quatf) -> simd_quatf {
    let x = q.imag.x, y = q.imag.y, z = q.imag.z, w = q.real
    let len = sqrtf(x * x + y * y + z * z + w * w)
    if len < 1e-7 { return mmdIdentityQuaternion }
    return simd_quatf(ix: x / len, iy: y / len, iz: z / len, r: w / len)
}

func quatConjugate(_ q: simd_quatf) -> simd_quatf {
    simd_quatf(ix: -q.imag.x, iy: -q.imag.y, iz: -q.imag.z, r: q.real)
}

func quatNegate(_ q: simd_quatf) -> simd_quatf {
    simd_quatf(ix: -q.imag.x, iy: -q.imag.y, iz: -q.imag.z, r: -q.real)
}

func quatDot(_ a: simd_quatf, _ b: simd_quatf) -> Float {
    a.real * b.real + simd_dot(a.imag, b.imag)
}

func quatSlerp(_ a: simd_quatf, _ b: simd_quatf, _ t: Float) -> simd_quatf {
    var q1 = quatNormalize(a)
    var q2 = quatNormalize(b)
    var dot = quatDot(q1, q2)
    if dot < 0 {
        q2 = quatNegate(q2)
        dot = -dot
    }
    if dot > 0.9995 {
        let blended = simd_quatf(
            ix: q1.imag.x + (q2.imag.x - q1.imag.x) * t,
            iy: q1.imag.y + (q2.imag.y - q1.imag.y) * t,
            iz: q1.imag.z + (q2.imag.z - q1.imag.z) * t,
            r: q1.real + (q2.real - q1.real) * t
        )
        return quatNormalize(blended)
    }
    let theta0 = acosf(max(-1, min(1, dot)))
    let theta = theta0 * t
    let s0 = sinf(theta0 - theta) / sinf(theta0)
    let s1 = sinf(theta) / sinf(theta0)
    let q = simd_quatf(
        ix: q1.imag.x * s0 + q2.imag.x * s1,
        iy: q1.imag.y * s0 + q2.imag.y * s1,
        iz: q1.imag.z * s0 + q2.imag.z * s1,
        r: q1.real * s0 + q2.real * s1
    )
    return quatNormalize(q)
}

/// Euler angles in radians, applied as Rz * Ry * Rx (the same convention used by VMD camera).
func quatFromEuler(_ euler: SIMD3<Float>) -> simd_quatf {
    let qx = simd_quatf(angle: euler.x, axis: SIMD3<Float>(1, 0, 0))
    let qy = simd_quatf(angle: euler.y, axis: SIMD3<Float>(0, 1, 0))
    let qz = simd_quatf(angle: euler.z, axis: SIMD3<Float>(0, 0, 1))
    return qz * qy * qx
}

func quatFromRotationMatrix(_ m: simd_float3x3) -> simd_quatf {
    let m00 = m.columns.0.x, m01 = m.columns.1.x, m02 = m.columns.2.x
    let m10 = m.columns.0.y, m11 = m.columns.1.y, m12 = m.columns.2.y
    let m20 = m.columns.0.z, m21 = m.columns.1.z, m22 = m.columns.2.z
    let trace = m00 + m11 + m22
    let q: simd_quatf
    if trace > 0 {
        let s = sqrtf(trace + 1.0) * 2
        q = simd_quatf(ix: (m21 - m12) / s, iy: (m02 - m20) / s, iz: (m10 - m01) / s, r: 0.25 * s)
    } else if m00 > m11 && m00 > m22 {
        let s = sqrtf(1.0 + m00 - m11 - m22) * 2
        q = simd_quatf(ix: 0.25 * s, iy: (m01 + m10) / s, iz: (m02 + m20) / s, r: (m21 - m12) / s)
    } else if m11 > m22 {
        let s = sqrtf(1.0 + m11 - m00 - m22) * 2
        q = simd_quatf(ix: (m01 + m10) / s, iy: 0.25 * s, iz: (m12 + m21) / s, r: (m02 - m20) / s)
    } else {
        let s = sqrtf(1.0 + m22 - m00 - m11) * 2
        q = simd_quatf(ix: (m02 + m20) / s, iy: (m12 + m21) / s, iz: 0.25 * s, r: (m10 - m01) / s)
    }
    return quatNormalize(q)
}

/// Decompose a rotation matrix expressed as Rz * Ry * Rx into XYZ Euler angles (radians).
func quatToEuler(_ quat: simd_quatf) -> SIMD3<Float> {
    let m = simd_float4x4(quaternion: quat).rotationMatrix
    let m00 = m.columns.0.x, m10 = m.columns.0.y, m20 = m.columns.0.z
    let m21 = m.columns.1.z, m22 = m.columns.2.z
    let m01 = m.columns.1.x, m11 = m.columns.1.y, m12 = m.columns.2.y
    let sy = sqrtf(m00 * m00 + m10 * m10)
    if sy > 1e-5 {
        return SIMD3<Float>(atan2f(m21, m22), atan2f(-m20, sy), atan2f(m10, m00))
    }
    return SIMD3<Float>(atan2f(-m12, m11), atan2f(-m20, sy), 0)
}

/// Shortest-arc rotation that maps vector a onto vector b.
func quatBetween(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> simd_quatf {
    let u = a.unit
    let v = b.unit
    if simd_length(u) < 1e-6 || simd_length(v) < 1e-6 { return mmdIdentityQuaternion }
    let dot = max(-1, min(1, simd_dot(u, v)))
    if dot > 0.99999 { return mmdIdentityQuaternion }
    if dot < -0.99999 {
        // Pick any perpendicular axis.
        let axis = abs(u.x) < 0.9 ? simd_cross(u, SIMD3<Float>(1, 0, 0)) : simd_cross(u, SIMD3<Float>(0, 1, 0))
        return simd_quatf(angle: .pi, axis: axis.unit)
    }
    let axis = simd_cross(u, v).unit
    return simd_quatf(angle: acosf(dot), axis: axis)
}

func quatClampAngle(_ q: simd_quatf, maxAngle: Float) -> simd_quatf {
    let angle = q.angle
    let axis = q.axis
    if angle <= maxAngle || angle.isNaN { return q }
    return simd_quatf(angle: maxAngle, axis: axis)
}

// MARK: - Projection

func mmdPerspective(fovYRadians: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let f = 1 / tanf(max(fovYRadians, 0.01) * 0.5)
    let a = max(aspect, 0.0001)
    return simd_float4x4(columns: (
        SIMD4<Float>(f / a, 0, 0, 0),
        SIMD4<Float>(0, f, 0, 0),
        SIMD4<Float>(0, 0, far / (near - far), -1),
        SIMD4<Float>(0, 0, near * far / (near - far), 0)
    ))
}

func mmdLookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
    let z = (eye - center).unit
    let x = simd_cross(up, z).unit
    let y = simd_cross(z, x)
    return simd_float4x4(columns: (
        SIMD4<Float>(x.x, y.x, z.x, 0),
        SIMD4<Float>(x.y, y.y, z.y, 0),
        SIMD4<Float>(x.z, y.z, z.z, 0),
        SIMD4<Float>(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)
    ))
}

// MARK: - Bounds

struct MMDBox {
    var minPoint: SIMD3<Float>
    var maxPoint: SIMD3<Float>

    static let empty = MMDBox(minPoint: SIMD3<Float>(repeating: .greatestFiniteMagnitude),
                              maxPoint: SIMD3<Float>(repeating: -.greatestFiniteMagnitude))

    var center: SIMD3<Float> { (minPoint + maxPoint) * 0.5 }
    var size: SIMD3<Float> { maxPoint - minPoint }
    var height: Float { max(0.01, size.y) }
    var radius: Float {
        let s = size
        return max(0.1, 0.5 * sqrtf(s.x * s.x + s.y * s.y + s.z * s.z))
    }

    mutating func expand(with point: SIMD3<Float>, padding: Float = 0) {
        minPoint = simd_min(minPoint, point - SIMD3<Float>(repeating: padding))
        maxPoint = simd_max(maxPoint, point + SIMD3<Float>(repeating: padding))
    }

    static func containing(_ points: [SIMD3<Float>]) -> MMDBox {
        var box = MMDBox.empty
        for p in points { box.expand(with: p) }
        if box.minPoint.x > box.maxPoint.x { return MMDBox(minPoint: .zero, maxPoint: .zero) }
        return box
    }
}

// MARK: - Animation curves

/// A VMD-style cubic bezier easing curve. Control points are normalized to 0...1.
struct MMDBezierCurve: Equatable {
    var x1: Float
    var y1: Float
    var x2: Float
    var y2: Float

    static let linear = MMDBezierCurve(x1: 0, y1: 0, x2: 1, y2: 1)

    init(x1: Float, y1: Float, x2: Float, y2: Float) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }

    init(bytes: [UInt8], x1Index: Int, y1Index: Int, x2Index: Int, y2Index: Int) {
        func value(_ index: Int) -> Float {
            guard index >= 0 && index < bytes.count else { return 0 }
            return Float(bytes[index]) / 127.0
        }
        self.init(x1: value(x1Index), y1: value(y1Index), x2: value(x2Index), y2: value(y2Index))
    }

    private func bezierX(_ t: Float) -> Float {
        let mt = 1 - t
        return 3 * mt * mt * t * x1 + 3 * mt * t * t * x2 + t * t * t
    }

    private func bezierY(_ t: Float) -> Float {
        let mt = 1 - t
        return 3 * mt * mt * t * y1 + 3 * mt * t * t * y2 + t * t * t
    }

    /// Returns the interpolated progress for normalized time x (0...1).
    func value(at x: Float) -> Float {
        let progress = max(0, min(1, x))
        // Control points on the diagonal describe a perfectly linear curve.
        if abs(x1 - y1) < 0.0001 && abs(x2 - y2) < 0.0001 { return progress }
        var low: Float = 0
        var high: Float = 1
        for _ in 0..<22 {
            let mid = (low + high) * 0.5
            if bezierX(mid) < progress {
                low = mid
            } else {
                high = mid
            }
        }
        let t = (low + high) * 0.5
        return max(0, min(1, bezierY(t)))
    }
}

func quatEulerDegrees(_ quat: simd_quatf) -> SIMD3<Float> {
    let radians = quatToEuler(quat)
    return SIMD3<Float>(mmdDegrees(radians.x), mmdDegrees(radians.y), mmdDegrees(radians.z))
}
