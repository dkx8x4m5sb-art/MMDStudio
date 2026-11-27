//
//  MMDRenderTypes.swift
//  MMD Studio
//
//  渲染设置、统计与着色参数类型。
//

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
    /// x: 环境强度，y: 补光强度，z: 轮廓光强度，w: 曝光
    var lightParams: SIMD4<Float> = SIMD4<Float>(0.42, 0.45, 0.35, 1.0)
    /// x: 启用光源数；y: 环境强度；z: 曝光；w: 卡通阶数
    var lightCount: SIMD4<Float> = SIMD4<Float>(0, 0.42, 1.0, 3)
    /// x: 视口宽，y: 视口高，z/w: 保留
    var viewportSize: SIMD4<Float> = SIMD4<Float>(1, 1, 0, 0)
    /// x: 对比度，y: 泛光，z: 暗角，w: 反射强度
    var gradeParams: SIMD4<Float> = SIMD4<Float>(1, 0, 0, 1)
    /// x: 卡通透界柔和度，y: 阴影提亮，z: 轮廓光强度，w: 保留
    var toonParams: SIMD4<Float> = SIMD4<Float>(0.16, 0.62, 0.22, 0)
    /// rgb: 阴影色调；a: 着色强度
    var toonShadowTint: SIMD4<Float> = SIMD4<Float>(0.58, 0.55, 0.64, 0.72)
    /// x: 环绕散射，y: 世界光强度，z/w: 保留
    var worldParams: SIMD4<Float> = SIMD4<Float>(0.18, 0.32, 0, 0)
    var worldSkyColor: SIMD4<Float> = SIMD4<Float>(0.48, 0.62, 0.82, 1)
    var worldGroundColor: SIMD4<Float> = SIMD4<Float>(0.18, 0.14, 0.12, 1)
    /// x: 描边宽度（像素），y: 高光强度，z: 皮肤透光，
    /// w: 阴影色相偏移。
    var renderParams: SIMD4<Float> = SIMD4<Float>(2.6, 0.55, 0.35, 0.35)
    var lights: (MMDLightUniform, MMDLightUniform, MMDLightUniform, MMDLightUniform,
                 MMDLightUniform, MMDLightUniform, MMDLightUniform, MMDLightUniform) = MMDLightUniform.defaultTuple
}

/// GPU 侧布局。与 `Shaders.metal` 里的 `Light` 保持一致。
struct MMDLightUniform {
    var positionOrDirection: SIMD4<Float> = .zero
    var color: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
    /// x: 类型（0 平行光，1 点光，2 环境光，3 聚光），y: 强度，z: 范围，w: 是否启用
    var params: SIMD4<Float> = .zero
    /// xyz: 归一化的聚光方向；平行光也把方向存在这里，方便编辑器。
    var direction: SIMD4<Float> = .zero
    /// x: 外锥余弦，y: 内锥余弦，z/w: 保留。
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

/// 全屏摄影棚背景。四个 float4 让 Metal 布局
/// 保持简单，与网格场景的 uniform 互不相干。
struct MMDStudioBackdropUniforms {
    var topColor: SIMD4<Float> = SIMD4<Float>(0.16, 0.18, 0.23, 1)
    var bottomColor: SIMD4<Float> = SIMD4<Float>(0.035, 0.04, 0.055, 1)
    var glowColor: SIMD4<Float> = SIMD4<Float>(0.30, 0.46, 0.62, 1)
    /// x: 光晕强度，y: 暗角，z/w: 保留
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
    /// x: 高光强度倍率，y: 金属度，z: 皮肤标记（1 = 皮肤），
    /// w: 描边宽度倍率。
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

    /// 每帧每像素位数，用来推算自动码率。
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

    /// 用户切换预设时的风格默认值。它们只是起点；
    /// 之后渲染编辑器可以覆盖每一项。
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

    /// 环绕按视口尺寸归一化，而不是固定的
    /// 每点弧度值，划动在每台设备上手感一致。
    mutating func orbit(deltaX: Float, deltaY: Float, viewportWidth: Float, viewportHeight: Float) {
        let width = max(160, viewportWidth)
        let height = max(160, viewportHeight)
        yaw -= deltaX / width * 2.6
        pitch = max(-1.35, min(1.35, pitch + deltaY / height * 1.8))
    }

    /// 平移用目标深度处的真实透视足迹，
    /// 一指宽的移动正好对应屏幕上一指宽。
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
    /// 太阳方向（从表面指向光源），已归一化。
    var direction: SIMD3<Float>
    /// 点光的世界位置。
    var position: SIMD3<Float>
    var range: Float
    var enabled: Bool
    /// 聚光外锥角，单位度。内锥是它的 72%。
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

/// 武器/挂件保留为独立的 PMX 场景物体，不并进
/// 角色骨架：骨骼绑定施加角色骨骼相对静止姿势的增量，
/// 位置/旋转/缩放仍可在画布上编辑。
struct MMDAttachment: Identifiable {
    var id = UUID()
    var name: String
    var model: PMXModel
    var baseDirectory: URL
    var fallbackRoot: URL?
    var position: SIMD3<Float> = .zero
    /// 欧拉角，单位度，由变换手柄或数值检查器编辑。
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
    /// 物理阶段的调试线框：PMX 刚体按文件描述绘制，
    /// 以及求解器实际使用的碰撞球。
    /// 转换过的模型上这两者常常对不上，这就是
    /// 「明明有碰撞体、裙子还是穿过大腿」的原因。
    var showRigidBodies: Bool = false
    var showPhysicsColliders: Bool = false
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
    /// 半球世界光照。散射把直射光绕到交界之外；
    /// 天空/地面颜色提供随方向变化的环境光。
    var worldScattering: Float = 0.18
    var worldIntensity: Float = 0.32
    var worldSkyColor: SIMD4<Float> = SIMD4<Float>(0.48, 0.62, 0.82, 1)
    var worldGroundColor: SIMD4<Float> = SIMD4<Float>(0.18, 0.14, 0.12, 1)
    var photoScale: Float = 2.0
    /// 离屏静帧输出。与屏幕 drawable 无关，
    /// 所以相机渲染是这个尺寸下真正的 Metal 渲染。
    var photoWidth: Int = 1440
    var photoHeight: Int = 2560
    var photoTransparentBackground: Bool = false
    /// 离线视频默认值。与图片尺寸互不影响。
    var videoWidth: Int = 1080
    var videoHeight: Int = 1920
    var videoFPS: Int = 30
    var videoTransparentBackground: Bool = false
    /// 视频质量控制。`auto` 按分辨率与帧率挑码率；
    /// 正的 `videoBitrateMbps` 覆盖它。关键帧间隔单位是
    /// 秒，影响拖动定位与压缩效率。
    var videoQuality: MMDVideoQuality = .high
    var videoBitrateMbps: Double = 0
    var videoKeyframeInterval: Int = 2
    /// 可选的场景背景图。复制进 App 的 Documents/MMDStudio/Backgrounds
    /// 目录后，以绝对路径保存。
    var backgroundImagePath: String? = nil
    var photoIncludeGrid: Bool = false
    var photoIncludeBones: Bool = false
    var lights: [MMDLightSetting] = [.sun(), .fill(), .ambient()]
    var backgroundColor: SIMD4<Float> = SIMD4<Float>(0.075, 0.085, 0.115, 1.0)
    /// 卡通着色控制。默认值与 MMD 预设一致。
    var toonSoftness: Float = 0.20
    var toonShadowLift: Float = 0.66
    var toonRim: Float = 0.18
    var toonShadowTint: SIMD4<Float> = SIMD4<Float>(0.60, 0.57, 0.66, 0.60)
    /// 屏幕空间描边厚度（像素）。与外壳式描边不同，
    /// 任何相机距离下线宽都一致。
    var outlineWidth: Float = 2.6
    /// 卡通着色器的阶梯高光强度。
    var specularStrength: Float = 0.55
    /// 明暗交界处的暖光透光，用于皮肤与薄布。
    var skinScatter: Float = 0.35

    /// 裙子、袖口和胸口的 SDEF 球面蒙皮。默认关闭：
    /// 只有转换器把 C/R0/R1 写在模型空间时，球面解算
    /// 才符合作者意图，而有些转换器并没有。
    var useSDEFSkinning: Bool = false
    var toonEnabled: Bool = true
    var renderMode: MMDRenderMode = .toon
    var style: MMDRenderStyle = .mmd
    var qualityMode: MMDQualityMode = .auto
    var showPerformanceHUD: Bool = true
    /// 多数导出里，PMX/MMD 的 UV 与 Metal 的纹理原点
    /// V 方向相反。默认开启；偶有反着写 UV 的模型，
    /// 可以用开关关掉。
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
