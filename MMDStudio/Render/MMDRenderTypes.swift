import Foundation
import simd

struct MMDSceneUniforms {
    var viewProjection: simd_float4x4 = matrix_identity_float4x4
    var view: simd_float4x4 = matrix_identity_float4x4
    var model: simd_float4x4 = matrix_identity_float4x4
    var normalMatrix: simd_float4x4 = matrix_identity_float4x4
    var lightDirection: SIMD4<Float> = SIMD4<Float>(0.4, 0.8, 0.5, 0)
    var lightColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
    var ambientColor: SIMD4<Float> = SIMD4<Float>(0.35, 0.35, 0.4, 1)
    var cameraPosition: SIMD4<Float> = SIMD4<Float>(0, 2, 30, 1)
    var params: SIMD4<Float> = SIMD4<Float>(0, 1, 1, 0)
    /// x: ambient strength, y: fill strength, z: rim strength, w: exposure
    var lightParams: SIMD4<Float> = SIMD4<Float>(0.42, 0.45, 0.35, 1.0)
    /// x: active light count; y: ambient strength; z: exposure; w: toon step count
    var lightCount: SIMD4<Float> = SIMD4<Float>(0, 0.42, 1.0, 3)
    /// x: viewport width, y: viewport height, z/w: reserved
    var viewportSize: SIMD4<Float> = SIMD4<Float>(1, 1, 0, 0)
    /// x: contrast, y: bloom, z: vignette, w: reflection strength
    var gradeParams: SIMD4<Float> = SIMD4<Float>(1, 0, 0, 1)
    /// x: toon terminator softness, y: shadow lift, z: rim strength, w: reserved
    var toonParams: SIMD4<Float> = SIMD4<Float>(0.16, 0.62, 0.22, 0)
    /// rgb: shadow tint; a: tint strength
    var toonShadowTint: SIMD4<Float> = SIMD4<Float>(0.58, 0.55, 0.64, 0.72)
    /// x: wrap scattering, y: world intensity, z/w: reserved
    var worldParams: SIMD4<Float> = SIMD4<Float>(0.18, 0.32, 0, 0)
    var worldSkyColor: SIMD4<Float> = SIMD4<Float>(0.48, 0.62, 0.82, 1)
    var worldGroundColor: SIMD4<Float> = SIMD4<Float>(0.18, 0.14, 0.12, 1)
    /// x: outline width in pixels, y: specular strength, z: skin scatter,
    /// w: shadow hue shift.
    var renderParams: SIMD4<Float> = SIMD4<Float>(1.6, 0.55, 0.35, 0.35)
    var lights: (MMDLightUniform, MMDLightUniform, MMDLightUniform, MMDLightUniform,
                 MMDLightUniform, MMDLightUniform, MMDLightUniform, MMDLightUniform) = MMDLightUniform.defaultTuple
}

/// GPU-side layout. Keep this in sync with `Light` in Shaders.metal.
struct MMDLightUniform {
    var positionOrDirection: SIMD4<Float> = .zero
    var color: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
    /// x: type (0 sun, 1 point, 2 ambient, 3 spot), y: intensity, z: range, w: enabled
    var params: SIMD4<Float> = .zero
    /// xyz: normalized spot direction; sun also keeps it here for editors.
    var direction: SIMD4<Float> = .zero
    /// x: outer cosine, y: inner cosine, z/w: reserved.
    var spotParams: SIMD4<Float> = .zero

    static let zero = MMDLightUniform()
    static let defaultTuple: (MMDLightUniform, MMDLightUniform, MMDLightUniform, MMDLightUniform,
                              MMDLightUniform, MMDLightUniform, MMDLightUniform, MMDLightUniform) =
        (MMDLightUniform(positionOrDirection: SIMD4<Float>(0.4, 0.8, 0.5, 0),
                         color: SIMD4<Float>(1, 1, 1, 1),
                         params: SIMD4<Float>(0, 1, 100, 1)),
         MMDLightUniform(positionOrDirection: SIMD4<Float>(-4, 7, 8, 0),
                         color: SIMD4<Float>(0.55, 0.7, 1.0, 1),
                         params: SIMD4<Float>(1, 0.35, 22, 1)),
         MMDLightUniform(positionOrDirection: SIMD4<Float>(0, 0, 0, 0),
                         color: SIMD4<Float>(0.62, 0.62, 0.68, 1),
                         params: SIMD4<Float>(2, 0.42, 0, 1)),
         MMDLightUniform.zero, MMDLightUniform.zero, MMDLightUniform.zero,
         MMDLightUniform.zero, MMDLightUniform.zero)
}

/// Full-screen studio backdrop. Four float4 values keep the Metal layout
/// trivial and independent from the mesh scene uniforms.
struct MMDStudioBackdropUniforms {
    var topColor: SIMD4<Float> = SIMD4<Float>(0.16, 0.18, 0.23, 1)
    var bottomColor: SIMD4<Float> = SIMD4<Float>(0.035, 0.04, 0.055, 1)
    var glowColor: SIMD4<Float> = SIMD4<Float>(0.30, 0.46, 0.62, 1)
    /// x: glow strength, y: vignette, z/w: reserved
    var params: SIMD4<Float> = SIMD4<Float>(0.55, 0.38, 0, 0)
}

struct MMDMaterialUniforms {
    var diffuse: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
    var specular: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1)
    var ambient: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1)
    var edgeColor: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1)
    var textureTint: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
    var sphereTint: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1)
    var toonTint: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
    /// x: specular strength multiplier, y: metalness, z: skin flag (1 = skin),
    /// w: outline width multiplier.
    var toonControl: SIMD4<Float> = SIMD4<Float>(1, 0, 0, 1)
    var edgeSize: Float = 1
    var alphaTest: Float = 0.03
    var sphereMode: Int32 = 0
    var flags: UInt32 = 0
    var renderMode: Int32 = 0
}

enum MMDVideoQuality: String, CaseIterable, Identifiable {
    case compact
    case standard
    case high
    case ultra

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: return "省空间"
        case .standard: return "标准"
        case .high: return "高质量"
        case .ultra: return "极高"
        }
    }

    /// Bits per pixel per frame used to derive an automatic bitrate.
    var bitsPerPixel: Double {
        switch self {
        case .compact: return 0.055
        case .standard: return 0.095
        case .high: return 0.16
        case .ultra: return 0.26
        }
    }
}

enum MMDRenderMode: String, CaseIterable, Identifiable {
    case toon = "标准卡通"
    case realistic = "写实光照"
    case unlit = "无光照"
    case normals = "法线"
    case uv = "UV 检查"
    case wireframe = "线框"

    var id: String { rawValue }
    var index: Int32 {
        switch self {
        case .toon: return 0
        case .realistic: return 1
        case .unlit: return 2
        case .normals: return 3
        case .uv: return 4
        case .wireframe: return 5
        }
    }
    var usesEdges: Bool { self == .toon || self == .realistic }
}

enum MMDRenderStyle: String, CaseIterable, Identifiable {
    case mmd = "MMD 标准"
    case genshin = "原神"
    case starRail = "星穹铁道"
    case zenless = "绝区零"

    var id: String { rawValue }

    var index: Float {
        switch self {
        case .mmd: return 0
        case .genshin: return 1
        case .starRail: return 2
        case .zenless: return 3
        }
    }

    var toonSteps: Float {
        switch self {
        case .mmd: return 2
        case .genshin: return 3
        case .starRail: return 4
        case .zenless: return 2
        }
    }

    var accent: String {
        switch self {
        case .mmd: return "中性双色阶，克制的明暗过渡"
        case .genshin: return "暖色阴影、柔和高光、清晰但不过重的描边"
        case .starRail: return "冷色暗部、冷色轮廓光、较高对比"
        case .zenless: return "硬边双色阶、强饱和、较重描边"
        }
    }

    /// Style defaults used when the user switches presets. They are starting
    /// points only; the render editor can override every value afterwards.
    var defaultToonSoftness: Float {
        switch self {
        case .mmd: return 0.20
        case .genshin: return 0.28
        case .starRail: return 0.14
        case .zenless: return 0.04
        }
    }

    var defaultShadowLift: Float {
        switch self {
        case .mmd: return 0.66
        case .genshin: return 0.72
        case .starRail: return 0.58
        case .zenless: return 0.46
        }
    }

    var defaultRimStrength: Float {
        switch self {
        case .mmd: return 0.18
        case .genshin: return 0.28
        case .starRail: return 0.38
        case .zenless: return 0.20
        }
    }

    var defaultShadowTint: SIMD4<Float> {
        switch self {
        case .mmd: return SIMD4<Float>(0.60, 0.57, 0.66, 0.60)
        case .genshin: return SIMD4<Float>(0.62, 0.48, 0.50, 0.64)
        case .starRail: return SIMD4<Float>(0.40, 0.49, 0.66, 0.72)
        case .zenless: return SIMD4<Float>(0.30, 0.26, 0.33, 0.82)
        }
    }
}

struct MMDOrbitCamera {
    var target: SIMD3<Float> = .zero
    var distance: Float = 30
    var yaw: Float = 0
    var pitch: Float = 0.15
    var fovDegrees: Float = 30

    var eye: SIMD3<Float> {
        let cp = cosf(pitch)
        return SIMD3<Float>(
            target.x + distance * cp * sinf(yaw),
            target.y + distance * sinf(pitch),
            target.z + distance * cp * cosf(yaw)
        )
    }

    mutating func fit(bounds: MMDBox) {
        target = bounds.center
        distance = max(bounds.radius * 3.9, 4)
        pitch = 0.08
        yaw = 0
        fovDegrees = 30
    }

    /// Orbit is normalized by the viewport size instead of using a fixed
    /// radians-per-point value, so a swipe feels the same on every device.
    mutating func orbit(deltaX: Float, deltaY: Float, viewportWidth: Float, viewportHeight: Float) {
        let width = max(160, viewportWidth)
        let height = max(160, viewportHeight)
        yaw -= deltaX / width * 2.6
        pitch = max(-1.35, min(1.35, pitch + deltaY / height * 1.8))
    }

    /// Pan uses the actual perspective footprint at the target depth, which
    /// makes one finger-width of movement match one finger-width on screen.
    mutating func pan(deltaX: Float, deltaY: Float, viewportWidth: Float, viewportHeight: Float) {
        let width = max(160, viewportWidth)
        let height = max(160, viewportHeight)
        let worldPerPoint = 2 * distance * tanf(mmdRadians(fovDegrees) * 0.5) / height
        let right = SIMD3<Float>(cosf(yaw), 0, -sinf(yaw))
        let up = SIMD3<Float>(0, 1, 0)
        target -= right * (deltaX / width * height) * worldPerPoint
        target += up * deltaY * worldPerPoint
    }

    mutating func zoom(scale: Float) {
        distance = max(0.25, min(2000, distance / max(scale, 0.05)))
    }
}

enum MMDQualityMode: String, CaseIterable, Identifiable {
    case auto = "自动"
    case high = "高质量"
    case balanced = "均衡"
    case performance = "性能优先"

    var id: String { rawValue }

    var baseScale: Double {
        switch self {
        case .auto, .high: return 1.0
        case .balanced: return 0.85
        case .performance: return 0.7
        }
    }

    var allowsAdaptiveScale: Bool {
        self == .auto || self == .balanced
    }

    var targetFPS: Int {
        switch self {
        case .auto, .high: return 120
        case .balanced: return 60
        case .performance: return 60
        }
    }
}

struct MMDRenderStats: Equatable {
    var fps: Double = 0
    var frameMilliseconds: Double = 0
    var cpuMilliseconds: Double = 0
    var gpuMilliseconds: Double = 0
    var drawCalls: Int = 0
    var triangles: Int = 0
    var renderScale: Double = 1.0
    var resolution: String = "—"
    var qualityLabel: String = "自动"
    var missingTextures: Int = 0
}

enum MMDLightKind: String, CaseIterable, Identifiable, Codable {
    case sun = "太阳光"
    case point = "点光源"
    case spot = "聚光灯"
    case ambient = "环境光"

    var id: String { rawValue }
    var symbolName: String {
        switch self {
        case .sun: return "sun.max.fill"
        case .point: return "lightbulb.fill"
        case .spot: return "flashlight.on.fill"
        case .ambient: return "circle.lefthalf.filled"
        }
    }
}

struct MMDLightSetting: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var kind: MMDLightKind
    var color: SIMD4<Float>
    var intensity: Float
    /// Sun direction (direction from the surface toward the light), normalized.
    var direction: SIMD3<Float>
    /// Point-light world position.
    var position: SIMD3<Float>
    var range: Float
    var enabled: Bool
    /// Spot outer cone angle in degrees. The inner cone is 72% of this value.
    var coneAngle: Float = 35

    static func sun(name: String = "主太阳光") -> MMDLightSetting {
        MMDLightSetting(name: name, kind: .sun,
                        color: SIMD4<Float>(1, 1, 1, 1), intensity: 1.0,
                        direction: SIMD3<Float>(0.4, 0.8, 0.5),
                        position: .zero, range: 100, enabled: true)
    }

    static func fill(name: String = "冷色补光") -> MMDLightSetting {
        MMDLightSetting(name: name, kind: .point,
                        color: SIMD4<Float>(0.55, 0.7, 1.0, 1), intensity: 0.35,
                        direction: SIMD3<Float>(0, 1, 0),
                        position: SIMD3<Float>(-4, 7, 8), range: 22, enabled: true)
    }

    static func ambient(name: String = "环境光") -> MMDLightSetting {
        MMDLightSetting(name: name, kind: .ambient,
                        color: SIMD4<Float>(0.62, 0.62, 0.68, 1), intensity: 0.42,
                        direction: SIMD3<Float>(0, 1, 0),
                        position: .zero, range: 0, enabled: true)
    }

    static func spot(name: String = "聚光灯") -> MMDLightSetting {
        MMDLightSetting(name: name, kind: .spot,
                        color: SIMD4<Float>(1.0, 0.82, 0.62, 1), intensity: 1.4,
                        direction: SIMD3<Float>(0, -1, 0),
                        position: SIMD3<Float>(3, 8, 6), range: 28, enabled: true,
                        coneAngle: 32)
    }

    var uniform: MMDLightUniform {
        let normalizedDirection = simd_length(direction) > 0.0001
            ? simd_normalize(direction)
            : SIMD3<Float>(0.4, 0.8, 0.5)
        let position = kind == .sun
            ? SIMD4<Float>(normalizedDirection.x, normalizedDirection.y, normalizedDirection.z, 0)
            : SIMD4<Float>(self.position.x, self.position.y, self.position.z, 0)
        let type: Float
        switch kind {
        case .sun: type = 0
        case .point: type = 1
        case .ambient: type = 2
        case .spot: type = 3
        }
        let outer = cosf(mmdRadians(max(2, min(85, coneAngle))))
        let inner = cosf(mmdRadians(max(1, min(84, coneAngle * 0.72))))
        return MMDLightUniform(positionOrDirection: position,
                               color: color,
                               params: SIMD4<Float>(type, max(0, intensity), max(0.01, range), enabled ? 1 : 0),
                               direction: SIMD4<Float>(normalizedDirection.x, normalizedDirection.y, normalizedDirection.z, 0),
                               spotParams: SIMD4<Float>(outer, inner, 0, 0))
    }
}

enum MMDTransformMode: String, CaseIterable, Identifiable {
    case translate = "移动"
    case rotate = "旋转"
    case scale = "缩放"
    var id: String { rawValue }
    var symbolName: String {
        switch self {
        case .translate: return "arrow.up.and.down.and.arrow.left.and.right"
        case .rotate: return "rotate.3d"
        case .scale: return "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left"
        }
    }
}

enum MMDTransformAxis: String, CaseIterable, Identifiable {
    case free = "自由"
    case x = "X"
    case y = "Y"
    case z = "Z"
    var id: String { rawValue }
}

/// A weapon/prop is kept as its own PMX scene object. It is not merged into the
/// character skeleton: a bone binding applies the character bone's delta from
/// its rest pose, while position/rotation/scale remain editable in the canvas.
struct MMDAttachment: Identifiable {
    var id = UUID()
    var name: String
    var model: PMXModel
    var baseDirectory: URL
    var fallbackRoot: URL?
    var position: SIMD3<Float> = .zero
    /// Euler degrees, edited by the transform gizmo or numeric inspector.
    var rotation: SIMD3<Float> = .zero
    var scale: SIMD3<Float> = SIMD3<Float>(1, 1, 1)
    var boundBoneIndex: Int?
    var visible = true
    var autoAssigned = false
    var sourceURL: URL?

    var transformMatrix: simd_float4x4 {
        let q = quatFromEuler(SIMD3<Float>(mmdRadians(rotation.x),
                                           mmdRadians(rotation.y),
                                           mmdRadians(rotation.z)))
        let scaleMatrix = simd_float4x4(diagonal: SIMD4<Float>(scale.x, scale.y, scale.z, 1))
        return simd_float4x4.translation(position) * simd_float4x4(quaternion: q) * scaleMatrix
    }
}

struct MMDRenderSettings {
    var showGrid: Bool = false
    var showBones: Bool = false
    var showGroundShadow: Bool = true
    var edgesEnabled: Bool = true
    var edgeScale: Float = 1.0
    var lightIntensity: Float = 1.0
    var lightAmbient: Float = 0.42
    var lightFill: Float = 0.45
    var lightRim: Float = 0.35
    var exposure: Float = 1.0
    var contrast: Float = 1.0
    var saturation: Float = 1.0
    var bloom: Float = 0.0
    var vignette: Float = 0.0
    var reflection: Float = 1.0
    /// Hemispheric world illumination. Scattering wraps direct light around
    /// the terminator; sky/ground colors provide direction-dependent ambient.
    var worldScattering: Float = 0.18
    var worldIntensity: Float = 0.32
    var worldSkyColor: SIMD4<Float> = SIMD4<Float>(0.48, 0.62, 0.82, 1)
    var worldGroundColor: SIMD4<Float> = SIMD4<Float>(0.18, 0.14, 0.12, 1)
    var photoScale: Float = 2.0
    /// Offscreen still output. These are independent from the on-screen
    /// drawable, so a camera render is a real Metal render at this size.
    var photoWidth: Int = 1440
    var photoHeight: Int = 2560
    var photoTransparentBackground: Bool = false
    /// Offline video defaults. These are independent from the photo size.
    var videoWidth: Int = 1080
    var videoHeight: Int = 1920
    var videoFPS: Int = 30
    var videoTransparentBackground: Bool = false
    /// Video quality control. `auto` picks a bitrate from resolution and frame
    /// rate; a positive `videoBitrateMbps` overrides it. Keyframe distance is in
    /// seconds and affects seeking plus compression efficiency.
    var videoQuality: MMDVideoQuality = .high
    var videoBitrateMbps: Double = 0
    var videoKeyframeInterval: Int = 2
    /// Optional scene backdrop image. Stored as an absolute file path after
    /// being copied into the app's Documents/MMDStudio/Backgrounds folder.
    var backgroundImagePath: String? = nil
    var photoIncludeGrid: Bool = false
    var photoIncludeBones: Bool = false
    var lights: [MMDLightSetting] = [.sun(), .fill(), .ambient()]
    var backgroundColor: SIMD4<Float> = SIMD4<Float>(0.075, 0.085, 0.115, 1.0)
    /// Toon shading controls. The defaults match the MMD preset.
    var toonSoftness: Float = 0.20
    var toonShadowLift: Float = 0.66
    var toonRim: Float = 0.18
    var toonShadowTint: SIMD4<Float> = SIMD4<Float>(0.60, 0.57, 0.66, 0.60)
    /// Screen-space outline thickness in pixels. Unlike a world-space shell this
    /// keeps the line weight identical at every camera distance.
    var outlineWidth: Float = 1.6
    /// Ladder highlight strength for the cel shader.
    var specularStrength: Float = 0.55
    /// Warm light bleeding at the terminator, used by skin and thin cloth.
    var skinScatter: Float = 0.35
    var toonEnabled: Bool = true
    var renderMode: MMDRenderMode = .toon
    var style: MMDRenderStyle = .mmd
    var qualityMode: MMDQualityMode = .auto
    var showPerformanceHUD: Bool = true
    /// PMX/MMD UVs and Metal's texture origin use opposite V directions for
    /// most exports. Keep this on by default; the toggle remains available
    /// for the occasional model that was authored with flipped UVs.
    var uvFlipV: Bool = true

    mutating func applyStyleDefaults(_ style: MMDRenderStyle) {
        self.style = style
        toonSoftness = style.defaultToonSoftness
        toonShadowLift = style.defaultShadowLift
        toonRim = style.defaultRimStrength
        toonShadowTint = style.defaultShadowTint
        contrast = style == .starRail ? 1.10 : (style == .zenless ? 1.16 : 1.0)
        saturation = style == .genshin ? 1.12 : (style == .zenless ? 1.22 : 1.0)
    }
}

struct MMDMaterialSettings: Identifiable {
    var id: Int
    var diffuse: SIMD4<Float>
    var edgeColor: SIMD4<Float>
    var edgeSize: Float
    var doubleSided: Bool
    var castsShadow: Bool
    var hasEdge: Bool
    var visible: Bool
    var sphereMode: UInt8
    var useTexture: Bool
    var useToon: Bool

    init(material: PMXMaterial, index: Int) {
        id = index
        diffuse = material.diffuse
        edgeColor = material.edgeColor
        edgeSize = material.edgeSize
        doubleSided = material.isDoubleSided
        castsShadow = material.castsGroundShadow
        hasEdge = material.hasEdge
        visible = true
        sphereMode = material.sphereMode
        useTexture = material.textureIndex >= 0
        useToon = true
    }
}
