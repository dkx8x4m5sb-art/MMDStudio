import SwiftUI
import simd

struct SettingsInspectorView: View {

    @ObservedObject var document: MMDModelDocument
    @Environment(\.dismiss) private var dismiss
    @State private var showLog = false

    var body: some View {
        NavigationStack {
            Form {
                Section("渲染方式") {
                    Picker("模式", selection: $document.renderSettings.renderMode) {
                        ForEach(MMDRenderMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    Picker("画风预设", selection: $document.renderSettings.style) {
                        ForEach(MMDRenderStyle.allCases) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                    .onChange(of: document.renderSettings.style) { _, _ in
                        document.renderSettings.renderMode = .toon
                    }
                    Text(document.renderSettings.style.accent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(document.renderSettings.renderMode == .wireframe
                         ? "线框模式会关闭描边和贴图着色，仅显示三角网格。"
                         : "卡通预设使用量化色阶和风格化描边；写实光照使用连续明暗、补光与镜面反射。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("画面调色") {
                    HStack {
                        Text("对比度")
                        Slider(value: contrastBinding, in: 0.70...1.60)
                        Text(String(format: "%.2f", document.renderSettings.contrast)).captionValue()
                    }
                    HStack {
                        Text("饱和度")
                        Slider(value: saturationBinding, in: 0.55...1.75)
                        Text(String(format: "%.2f", document.renderSettings.saturation)).captionValue()
                    }
                    HStack {
                        Text("泛光")
                        Slider(value: bloomBinding, in: 0...2)
                        Text(String(format: "%.2f", document.renderSettings.bloom)).captionValue()
                    }
                    HStack {
                        Text("暗角")
                        Slider(value: vignetteBinding, in: 0...1.4)
                        Text(String(format: "%.2f", document.renderSettings.vignette)).captionValue()
                    }
                    HStack {
                        Text("反射")
                        Slider(value: reflectionBinding, in: 0...2)
                        Text(String(format: "%.2f", document.renderSettings.reflection)).captionValue()
                    }
                }

                Section("视图") {
                    Toggle("显示地面网格", isOn: $document.renderSettings.showGrid)
                    Toggle("显示地面阴影", isOn: $document.renderSettings.showGroundShadow)
                    Toggle("显示骨骼", isOn: $document.renderSettings.showBones)
                    Toggle("启用描边", isOn: $document.renderSettings.edgesEnabled)
                    Toggle("卡通渐变着色", isOn: $document.renderSettings.toonEnabled)
                    Toggle("贴图 V 翻转（MMD 默认开启）", isOn: $document.renderSettings.uvFlipV)
                }

                Section("性能") {
                    Picker("渲染质量", selection: $document.renderSettings.qualityMode) {
                        ForEach(MMDQualityMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    Toggle("显示性能监控", isOn: $document.renderSettings.showPerformanceHUD)
                    LabeledContent("实时帧率", value: String(format: "%.0f FPS", document.renderStats.fps))
                    LabeledContent("CPU / GPU", value: String(format: "%.2f / %.2f ms", document.renderStats.cpuMilliseconds, document.renderStats.gpuMilliseconds))
                    LabeledContent("渲染分辨率", value: document.renderStats.resolution)
                    LabeledContent("三角面 / Draw", value: "\(document.renderStats.triangles) / \(document.renderStats.drawCalls)")
                    if document.renderStats.missingTextures > 0 {
                        LabeledContent("缺失贴图", value: "\(document.renderStats.missingTextures) 张")
                            .foregroundStyle(.orange)
                    }
                }

                Section("光照系统") {
                    NavigationLink {
                        LightingInspectorView(document: document)
                    } label: {
                        Label("光源编辑器（太阳光 / 点光 / 环境光）", systemImage: "lightbulb")
                    }
                    HStack {
                        Text("环境光")
                        Slider(value: ambientBinding, in: 0.05...0.8)
                        Text(String(format: "%.2f", document.renderSettings.lightAmbient))
                            .captionValue()
                    }
                    HStack {
                        Text("补光")
                        Slider(value: fillBinding, in: 0...1)
                        Text(String(format: "%.2f", document.renderSettings.lightFill))
                            .captionValue()
                    }
                    HStack {
                        Text("轮廓光")
                        Slider(value: rimBinding, in: 0...1)
                        Text(String(format: "%.2f", document.renderSettings.lightRim))
                            .captionValue()
                    }
                    HStack {
                        Text("曝光")
                        Slider(value: exposureBinding, in: 0.7...1.8)
                        Text(String(format: "%.2f", document.renderSettings.exposure))
                            .captionValue()
                    }
                    Text("光源编辑器可添加、删除和编辑最多 4 盏光；太阳光提供主方向，点光源可调位置/范围，环境光补充暗部。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("物理系统") {
                    Picker("物理模式", selection: $document.physicsSettings.mode) {
                        ForEach(MMDPhysicsMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Toggle("VMD / PMX IK 求解", isOn: $document.ikEnabled)
                    Text("摆动模式只驱动裙、髪、飘带、翅膀、袖子等二级骨骼，且会跳过所有 IK 链骨骼与人体主骨；默认关闭，导入新模型后可先开「摆动」确认效果。IK 求解默认关闭：部分模型的踝/膝在求解后会扭曲，需要足部贴地时再单独打开。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if document.physicsSettings.mode == .rigid {
                        Toggle("刚体与地面碰撞", isOn: $document.physicsSettings.collision)
                    }
                    if document.physicsSettings.mode != .off {
                        HStack {
                            Text("重力")
                            Slider(value: physicsGravityBinding, in: 0...1.5)
                            Text(String(format: "%.2f", document.physicsSettings.gravity))
                                .captionValue()
                        }
                        HStack {
                            Text("刚度")
                            Slider(value: physicsStiffnessBinding, in: 0.05...1.5)
                            Text(String(format: "%.2f", document.physicsSettings.stiffness))
                                .captionValue()
                        }
                        HStack {
                            Text("阻尼")
                            Slider(value: physicsDampingBinding, in: 0.1...1.5)
                            Text(String(format: "%.2f", document.physicsSettings.damping))
                                .captionValue()
                        }
                        HStack {
                            Text("风力")
                            Slider(value: physicsWindBinding, in: 0...0.8)
                            Text(String(format: "%.2f", document.physicsSettings.wind))
                                .captionValue()
                        }
                        HStack {
                            Text("惯性")
                            Slider(value: physicsInertiaBinding, in: 0...2)
                            Text(String(format: "%.2f", document.physicsSettings.inertia))
                                .captionValue()
                        }
                        HStack {
                            Text("最大摆角")
                            Slider(value: physicsMaxAngleBinding, in: 4...45)
                            Text(String(format: "%.0f°", document.physicsSettings.maxAngle))
                                .captionValue()
                        }
                        Stepper("子步 \(document.physicsSettings.substeps)",
                                value: $document.physicsSettings.substeps, in: 1...4)
                    }
                    LabeledContent("PMX 动态刚体", value: "\(document.physicsBodyCount)")
                    LabeledContent("PMX 关节", value: "\(document.physicsJointCount)")
                    Text("摆动模式用世界坐标下的重力目标角 + 弹簧阻尼积分，骨骼会朝地面下垂并随身体转动产生惯性；刚体模式额外做重力、关节弹簧、地面与同组外碰撞。两者都不会写入 IK 链骨骼。柔软体（PMX 2.1 soft body）仍按骨骼链近似，不是 Bullet 逐顶点软体。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("音频与口型") {
                    Toggle("音频驱动口型", isOn: $document.lipSyncEnabled)
                    HStack {
                        Text("口型幅度")
                        Slider(value: lipSyncStrengthBinding, in: 0...1.2)
                        Text(String(format: "%.2f", document.lipSyncStrength))
                            .captionValue()
                    }
                    if document.motionAudioName.isEmpty {
                        Text("动作 ZIP 内同名 WAV/MP3/M4A/AAC 会在导入时生成 30 Hz 口型包络；也可以只有 VMD 而无音频。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        LabeledContent("同步音频", value: document.motionAudioName)
                        Text("按音频 RMS 包络驱动名字为「あ / 口 / mouth / lip」的顶点表情；不会伪造音素级对齐。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("线条") {
                    HStack {
                        Text("描边倍率")
                        Slider(value: edgeBinding, in: 0...3)
                        Text(String(format: "%.2f", document.renderSettings.edgeScale))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                    ColorPicker("背景颜色", selection: backgroundBinding, supportsOpacity: false)
                    Button("重置相机") {
                        NotificationCenter.default.post(name: .mmdResetCamera, object: nil)
                    }
                }

                Section("动作") {
                    if document.hasMotion {
                        LabeledContent("名称", value: document.motionName)
                        LabeledContent("总帧数", value: "\(document.motion?.maxFrame ?? 0)")
                        LabeledContent("相机关键帧", value: "\(document.motion?.cameraKeys.count ?? 0)")
                        Toggle("使用 VMD 相机动作", isOn: $document.useCameraMotion)
                            .disabled(document.motion?.cameraKeys.isEmpty ?? true)
                        Button("移除动作", role: .destructive) {
                            document.removeMotion()
                        }
                    } else {
                        Text("尚未加载 VMD 动作。可在播放栏点「导入 VMD 动作」。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("模型信息") {
                    LabeledContent("模型格式", value: document.model.version < 1.5
                                   ? "PMD 1.0（兼容导入）"
                                   : String(format: "PMX %.1f", document.model.version))
                    LabeledContent("顶点", value: "\(document.model.vertices.count)")
                    LabeledContent("三角面", value: "\(document.model.indices.count / 3)")
                    LabeledContent("材质", value: "\(document.model.materials.count)")
                    LabeledContent("骨骼", value: "\(document.model.bones.count)")
                    LabeledContent("变形", value: "\(document.model.morphs.count)")
                    LabeledContent("IK 骨骼", value: "\(document.model.bones.filter { $0.ik != nil }.count)")
                    LabeledContent("刚体 / 关节", value: "\(document.model.rigidBodies.count) / \(document.model.joints.count)")
                    LabeledContent("贴图引用", value: "\(document.model.textures.count)")
                    LabeledContent("尺寸", value: String(format: "%.1f × %.1f × %.1f",
                                                        document.model.bounds.size.x,
                                                        document.model.bounds.size.y,
                                                        document.model.bounds.size.z))
                }

                if !document.missingTextureNames.isEmpty {
                    Section("缺失贴图") {
                        ForEach(document.missingTextureNames, id: \.self) { name in
                            Text(name)
                                .font(.caption.monospaced())
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                        }
                    }
                }

                Section("诊断") {
                    Button {
                        showLog = true
                    } label: {
                        Label("查看运行日志", systemImage: "doc.text.magnifyingglass")
                    }
                }

                if !document.model.warnings.isEmpty {
                    Section("解析提示") {
                        ForEach(document.model.warnings.indices, id: \.self) { index in
                            Text("• \(document.model.warnings[index])")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Section("说明") {
                    Text("支持导入模型文件夹、PMX、PMD 或 ZIP（自动解压并保留贴图子目录）。PMX 刚体/关节已解析并参与实时求解；PMD 转为 PMX 内部数据；SDEF 权重按 BDEF2 近似；PMX 2.1 柔软体为骨骼链近似。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showLog) {
                LogViewer()
            }
        }
    }

    private var lightBinding: Binding<Double> {
        Binding(
            get: { Double(document.renderSettings.lightIntensity) },
            set: { document.renderSettings.lightIntensity = Float($0) }
        )
    }

    private var ambientBinding: Binding<Double> {
        Binding(get: { Double(document.renderSettings.lightAmbient) },
                set: { document.renderSettings.lightAmbient = Float($0) })
    }

    private var contrastBinding: Binding<Double> {
        Binding(get: { Double(document.renderSettings.contrast) },
                set: { document.renderSettings.contrast = Float($0) })
    }

    private var saturationBinding: Binding<Double> {
        Binding(get: { Double(document.renderSettings.saturation) },
                set: { document.renderSettings.saturation = Float($0) })
    }

    private var bloomBinding: Binding<Double> {
        Binding(get: { Double(document.renderSettings.bloom) },
                set: { document.renderSettings.bloom = Float($0) })
    }

    private var vignetteBinding: Binding<Double> {
        Binding(get: { Double(document.renderSettings.vignette) },
                set: { document.renderSettings.vignette = Float($0) })
    }

    private var reflectionBinding: Binding<Double> {
        Binding(get: { Double(document.renderSettings.reflection) },
                set: { document.renderSettings.reflection = Float($0) })
    }

    private var fillBinding: Binding<Double> {
        Binding(get: { Double(document.renderSettings.lightFill) },
                set: { document.renderSettings.lightFill = Float($0) })
    }

    private var rimBinding: Binding<Double> {
        Binding(get: { Double(document.renderSettings.lightRim) },
                set: { document.renderSettings.lightRim = Float($0) })
    }

    private var exposureBinding: Binding<Double> {
        Binding(get: { Double(document.renderSettings.exposure) },
                set: { document.renderSettings.exposure = Float($0) })
    }

    private var physicsGravityBinding: Binding<Double> {
        Binding(get: { Double(document.physicsSettings.gravity) },
                set: { document.physicsSettings.gravity = Float($0) })
    }

    private var physicsStiffnessBinding: Binding<Double> {
        Binding(get: { Double(document.physicsSettings.stiffness) },
                set: { document.physicsSettings.stiffness = Float($0) })
    }

    private var physicsDampingBinding: Binding<Double> {
        Binding(get: { Double(document.physicsSettings.damping) },
                set: { document.physicsSettings.damping = Float($0) })
    }

    private var physicsWindBinding: Binding<Double> {
        Binding(get: { Double(document.physicsSettings.wind) },
                set: { document.physicsSettings.wind = Float($0) })
    }

    private var physicsInertiaBinding: Binding<Double> {
        Binding(get: { Double(document.physicsSettings.inertia) },
                set: { document.physicsSettings.inertia = Float($0) })
    }

    private var physicsMaxAngleBinding: Binding<Double> {
        Binding(get: { Double(document.physicsSettings.maxAngle) },
                set: { document.physicsSettings.maxAngle = Float($0) })
    }

    private var lipSyncStrengthBinding: Binding<Double> {
        Binding(get: { Double(document.lipSyncStrength) },
                set: { document.lipSyncStrength = Float($0) })
    }

    private var edgeBinding: Binding<Double> {
        Binding(
            get: { Double(document.renderSettings.edgeScale) },
            set: { document.renderSettings.edgeScale = Float($0) }
        )
    }

    private var backgroundBinding: Binding<Color> {
        Binding(
            get: { Color(simd4: document.renderSettings.backgroundColor) },
            set: { document.renderSettings.backgroundColor = $0.simd4 }
        )
    }
}

private extension View {
    func captionValue() -> some View {
        self.font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 42, alignment: .trailing)
    }
}

struct LightingInspectorView: View {

    @ObservedObject var document: MMDModelDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("世界光照与散射") {
                HStack {
                    Text("环境强度")
                    Slider(value: bind(\.worldIntensity), in: 0...1.5)
                    Text(String(format: "%.2f", document.renderSettings.worldIntensity)).captionValue()
                }
                HStack {
                    Text("漫反射散射")
                    Slider(value: bind(\.worldScattering), in: 0...0.8)
                    Text(String(format: "%.2f", document.renderSettings.worldScattering)).captionValue()
                }
                ColorPicker("天空半球色", selection: Binding(
                    get: { Color(simd4: document.renderSettings.worldSkyColor) },
                    set: { document.renderSettings.worldSkyColor = $0.simd4 }))
                ColorPicker("地面半球色", selection: Binding(
                    get: { Color(simd4: document.renderSettings.worldGroundColor) },
                    set: { document.renderSettings.worldGroundColor = $0.simd4 }))
                Text("使用天空/地面半球环境光、环绕漫反射和逐灯高光；不把屏幕空间近似标为完整光线追踪。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section {
                Text("最多 8 盏光。支持太阳、点光、聚光与环境光；在“场景”页可选中并用画布 Gizmo 移动。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(document.renderSettings.lights.indices, id: \.self) { index in
                    NavigationLink {
                        LightDetailView(light: Binding(
                            get: {
                                guard document.renderSettings.lights.indices.contains(index) else {
                                    return MMDLightSetting.sun()
                                }
                                return document.renderSettings.lights[index]
                            },
                            set: { value in
                                guard document.renderSettings.lights.indices.contains(index) else { return }
                                document.renderSettings.lights[index] = value
                            }
                        ))
                    } label: {
                        let light = document.renderSettings.lights[index]
                        HStack(spacing: 10) {
                            Image(systemName: light.kind.symbolName)
                                .foregroundStyle(Color(simd4: light.color))
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(light.name)
                                Text("\(light.kind.rawValue) · 强度 \(String(format: "%.2f", light.intensity))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !light.enabled {
                                Text("关闭")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    document.renderSettings.lights.remove(atOffsets: offsets)
                }
            } header: {
                Text("光源列表")
            } footer: {
                Text("左滑删除光源；点进单个光源可编辑颜色、强度和方向/位置。")
            }

            if document.renderSettings.lights.count < 8 {
                Section("添加光源") {
                    Button {
                        add(.sun)
                    } label: {
                        Label("太阳光", systemImage: "sun.max.fill")
                    }
                    Button {
                        add(.point)
                    } label: {
                        Label("点光源", systemImage: "lightbulb.fill")
                    }
                    Button {
                        add(.spot)
                    } label: {
                        Label("聚光灯", systemImage: "flashlight.on.fill")
                    }
                    Button {
                        add(.ambient)
                    } label: {
                        Label("环境光", systemImage: "circle.lefthalf.filled")
                    }
                }
            }
        }
        .navigationTitle("光源编辑")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
    }

    private func bind(_ keyPath: WritableKeyPath<MMDRenderSettings, Float>) -> Binding<Double> {
        Binding(get: { Double(document.renderSettings[keyPath: keyPath]) },
                set: { document.renderSettings[keyPath: keyPath] = Float($0) })
    }

    private func add(_ kind: MMDLightKind) {
        guard document.renderSettings.lights.count < 8 else { return }
        let light: MMDLightSetting
        switch kind {
        case .sun:
            light = .sun(name: "太阳光 \(document.renderSettings.lights.count + 1)")
        case .point:
            light = .fill(name: "点光源 \(document.renderSettings.lights.count + 1)")
        case .spot:
            light = .spot(name: "聚光灯 \(document.renderSettings.lights.count + 1)")
        case .ambient:
            light = .ambient(name: "环境光 \(document.renderSettings.lights.count + 1)")
        }
        document.renderSettings.lights.append(light)
    }
}

private struct LightDetailView: View {

    @Binding var light: MMDLightSetting

    var body: some View {
        Form {
            Section("光源") {
                TextField("名称", text: $light.name)
                Picker("类型", selection: $light.kind) {
                    ForEach(MMDLightKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                Toggle("启用", isOn: $light.enabled)
                ColorPicker("颜色", selection: colorBinding, supportsOpacity: false)
                HStack {
                    Text("强度")
                    Slider(value: floatBinding(\.intensity), in: 0...3)
                    Text(String(format: "%.2f", light.intensity))
                        .captionValue()
                }
            }

            if light.kind == .sun || light.kind == .spot {
                Section(header: Text(light.kind == .sun ? "方向（从表面指向光源）" : "聚光照射方向")) {
                    vectorSlider("X", axis: 0, keyPath: \.direction)
                    vectorSlider("Y", axis: 1, keyPath: \.direction)
                    vectorSlider("Z", axis: 2, keyPath: \.direction)
                    Text(light.kind == .sun ? "例如 (0.4, 0.8, 0.5) 表示光从左上前方照来。" : "聚光灯方向从灯的位置指向被照物体。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if light.kind == .point || light.kind == .spot {
                Section("世界坐标与范围") {
                    vectorSlider("X", axis: 0, keyPath: \.position, range: -30...30)
                    vectorSlider("Y", axis: 1, keyPath: \.position, range: -10...40)
                    vectorSlider("Z", axis: 2, keyPath: \.position, range: -30...30)
                    HStack {
                        Text("范围")
                        Slider(value: floatBinding(\.range), in: 1...80)
                        Text(String(format: "%.0f", light.range)).captionValue()
                    }
                    if light.kind == .spot {
                        HStack {
                            Text("锥角")
                            Slider(value: floatBinding(\.coneAngle), in: 4...80)
                            Text(String(format: "%.0f°", light.coneAngle)).captionValue()
                        }
                    }
                }
            } else if light.kind == .ambient {
                Section {
                    Text("环境光没有方向，颜色 × 强度会加到所有材质的暗部。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(light.name.isEmpty ? "光源" : light.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var colorBinding: Binding<Color> {
        Binding(get: { Color(simd4: light.color) }, set: { light.color = $0.simd4 })
    }

    private func floatBinding(_ keyPath: WritableKeyPath<MMDLightSetting, Float>) -> Binding<Double> {
        Binding(get: { Double(light[keyPath: keyPath]) },
                set: { light[keyPath: keyPath] = Float($0) })
    }

    private func vectorSlider(_ title: String, axis: Int,
                              keyPath: WritableKeyPath<MMDLightSetting, SIMD3<Float>>,
                              range: ClosedRange<Double> = -1...1) -> some View {
        HStack {
            Text(title)
            Slider(value: Binding(
                get: { Double(light[keyPath: keyPath][axis]) },
                set: { value in
                    var vector = light[keyPath: keyPath]
                    vector[axis] = Float(value)
                    light[keyPath: keyPath] = vector
                }
            ), in: range)
            Text(String(format: "%.2f", light[keyPath: keyPath][axis]))
                .captionValue()
        }
    }
}

/// Camera Studio: a DCC-style photo mode that keeps the live viewport visible
/// behind a compact, direct-control panel. It intentionally avoids a hierarchy
/// of menus; focal length, camera orbit, grade, and shutter are one touch away.
struct CameraStudioView: View {

    @ObservedObject var document: MMDModelDocument
    @Environment(\.dismiss) private var dismiss

    @State private var fov: Double = 30
    @State private var distance: Double = 30
    @State private var autoOrbit = false
    @State private var lastPhotoOK: Bool?

    private let outputPresets: [(title: String, width: Int, height: Int)] = [
        ("竖屏 1440 × 2560", 1440, 2560),
        ("竖屏 1080 × 1920", 1080, 1920),
        ("竖屏 2160 × 3840", 2160, 3840),
        ("方图 2048 × 2048", 2048, 2048),
    ]

    private let presets: [(id: String, title: String, icon: String)] = [
        ("front", "正面", "person.crop.rectangle"),
        ("close", "特写", "person.crop.circle"),
        ("wide", "广角", "camera.viewfinder"),
        ("left", "左侧", "arrow.left"),
        ("right", "右侧", "arrow.right"),
        ("top", "俯视", "arrow.down"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    cameraSection
                    lookSection
                    gradeSection
                    outputSection
                    shutterButton
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
            .background(Color(red: 0.055, green: 0.062, blue: 0.078))
            .navigationTitle("Camera Studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .onChange(of: fov) { _, value in
            NotificationCenter.default.post(name: .mmdCameraFOV, object: NSNumber(value: Float(value)))
        }
        .onChange(of: distance) { _, value in
            NotificationCenter.default.post(name: .mmdCameraDistance, object: NSNumber(value: Float(value)))
        }
        .onChange(of: autoOrbit) { _, value in
            NotificationCenter.default.post(name: .mmdCameraAutoOrbit, object: value)
        }
        .onReceive(NotificationCenter.default.publisher(for: .mmdPhotoCaptured)) { note in
            lastPhotoOK = note.object as? Bool
        }
        .onDisappear {
            if autoOrbit {
                autoOrbit = false
                NotificationCenter.default.post(name: .mmdCameraAutoOrbit, object: false)
            }
        }
    }

    private var cameraSection: some View {
        panel("相机", subtitle: "拖动画面旋转，双指缩放；滑杆可精调") {
            HStack {
                Text("视场角")
                Slider(value: $fov, in: 12...85)
                Text(String(format: "%.0f°", fov)).captionValue()
            }
            HStack {
                Text("距离")
                Slider(value: $distance, in: 2...90)
                Text(String(format: "%.0f", distance)).captionValue()
            }
            Toggle("自动环绕", isOn: $autoOrbit)
                .tint(Color(red: 0.35, green: 0.88, blue: 0.96))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(presets.indices, id: \.self) { index in
                        let preset = presets[index]
                        Button {
                            NotificationCenter.default.post(name: .mmdCameraPreset, object: preset.id)
                        } label: {
                            Label(preset.title, systemImage: preset.icon)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 7)
                                .background(Color.white.opacity(0.10), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.9))
                    }
                    Button {
                        NotificationCenter.default.post(name: .mmdResetCamera, object: nil)
                    } label: {
                        Label("重置", systemImage: "arrow.counterclockwise")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .background(Color.white.opacity(0.10), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
    }

    private var lookSection: some View {
        panel("渲染风格", subtitle: document.renderSettings.style.accent) {
            Picker("画风", selection: $document.renderSettings.style) {
                ForEach(MMDRenderStyle.allCases) { style in
                    Text(style.rawValue).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: document.renderSettings.style) { _, _ in
                document.renderSettings.renderMode = .toon
            }
            Picker("模式", selection: $document.renderSettings.renderMode) {
                Text("卡通").tag(MMDRenderMode.toon)
                Text("写实").tag(MMDRenderMode.realistic)
                Text("无光照").tag(MMDRenderMode.unlit)
            }
            .pickerStyle(.segmented)
            Picker("质量", selection: $document.renderSettings.qualityMode) {
                ForEach(MMDQualityMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var gradeSection: some View {
        panel("光影与调色", subtitle: "这些参数会直接进入最终渲染图") {
            sliderRow("曝光", value: bind(\.exposure), range: 0.5...2.0, format: "%.2f")
            sliderRow("对比度", value: bind(\.contrast), range: 0.70...1.60, format: "%.2f")
            sliderRow("饱和度", value: bind(\.saturation), range: 0.55...1.75, format: "%.2f")
            sliderRow("泛光", value: bind(\.bloom), range: 0.0...2.0, format: "%.2f")
            sliderRow("暗角", value: bind(\.vignette), range: 0.0...1.4, format: "%.2f")
            sliderRow("反射强度", value: bind(\.reflection), range: 0.0...2.0, format: "%.2f")
            sliderRow("描边粗细", value: bind(\.edgeScale), range: 0.5...2.0, format: "%.2f")
        }
    }

    private var outputSection: some View {
        panel("输出", subtitle: "离屏 Metal 渲染，不使用屏幕截图") {
            Picker("渲染尺寸", selection: outputPresetBinding) {
                ForEach(outputPresets, id: \.title) { preset in
                    Text(preset.title).tag(preset.title)
                }
            }
            .pickerStyle(.menu)
            Toggle("透明背景（PNG 保留 Alpha）", isOn: $document.renderSettings.photoTransparentBackground)
            Toggle("渲染图包含地面网格", isOn: $document.renderSettings.photoIncludeGrid)
            Toggle("渲染图包含骨骼线", isOn: $document.renderSettings.photoIncludeBones)
            if let lastPhotoOK {
                Text(lastPhotoOK ? "渲染图已保存到相册" : "渲染失败，请查看日志")
                    .font(.caption)
                    .foregroundStyle(lastPhotoOK ? .green : .orange)
            }
        }
    }

    private var outputPresetBinding: Binding<String> {
        Binding(
            get: {
                let width = document.renderSettings.photoWidth
                let height = document.renderSettings.photoHeight
                return outputPresets.first(where: { $0.width == width && $0.height == height })?.title
                    ?? "\(width) × \(height)"
            },
            set: { title in
                guard let preset = outputPresets.first(where: { $0.title == title }) else { return }
                document.renderSettings.photoWidth = preset.width
                document.renderSettings.photoHeight = preset.height
            }
        )
    }

    private var shutterButton: some View {
        Button {
            NotificationCenter.default.post(name: .mmdCapturePhoto,
                                            object: NSNumber(value: document.renderSettings.photoScale))
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "camera.fill")
                Text("渲染当前相机")
                    .fontWeight(.bold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .foregroundStyle(.black)
            .background(Color(red: 0.38, green: 0.90, blue: 0.97), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
    }

    private func panel<Content: View>(_ title: String, subtitle: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.bold))
                Text(subtitle).font(.caption2).foregroundStyle(.white.opacity(0.55))
            }
            content()
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(12)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func sliderRow(_ title: String, value: Binding<Double>,
                           range: ClosedRange<Double>, format: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue)).captionValue()
        }
    }

    private func bind(_ keyPath: WritableKeyPath<MMDRenderSettings, Float>) -> Binding<Double> {
        Binding(
            get: { Double(document.renderSettings[keyPath: keyPath]) },
            set: { document.renderSettings[keyPath: keyPath] = Float($0) }
        )
    }
}

// MARK: - Render studio

/// A compact DCC-style render workspace. It keeps the most important
/// two-tone controls (shadow tint, terminator softness, rim, grading and
/// output size) in one place; the older Settings form remains the low-level
/// inspector for physics, diagnostics and model metadata.
struct RenderStudioView: View {

    @ObservedObject var document: MMDModelDocument
    @Environment(\.dismiss) private var dismiss

    @State private var showCamera = false
    @State private var lastPhotoOK: Bool?

    private let outputPresets: [(title: String, width: Int, height: Int)] = [
        ("1440 × 2560", 1440, 2560),
        ("1080 × 1920", 1080, 1920),
        ("2160 × 3840", 2160, 3840),
        ("2048 × 2048", 2048, 2048),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("画风") {
                    Picker("预设", selection: $document.renderSettings.style) {
                        ForEach(MMDRenderStyle.allCases) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                    .onChange(of: document.renderSettings.style) { _, style in
                        document.renderSettings.applyStyleDefaults(style)
                        document.renderSettings.renderMode = .toon
                    }
                    Picker("模式", selection: $document.renderSettings.renderMode) {
                        Text("卡通").tag(MMDRenderMode.toon)
                        Text("写实").tag(MMDRenderMode.realistic)
                        Text("无光照").tag(MMDRenderMode.unlit)
                    }
                    .pickerStyle(.segmented)
                    Picker("质量", selection: $document.renderSettings.qualityMode) {
                        ForEach(MMDQualityMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                }

                Section("卡通阴影") {
                    Text("只使用主太阳光塑造明暗交界，点光和补光不再制造第二层硬阴影。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("交界柔化")
                        Slider(value: bind(\.toonSoftness), in: 0...0.45)
                        Text(String(format: "%.2f", document.renderSettings.toonSoftness)).captionValue()
                    }
                    HStack {
                        Text("暗部抬亮")
                        Slider(value: bind(\.toonShadowLift), in: 0...1)
                        Text(String(format: "%.2f", document.renderSettings.toonShadowLift)).captionValue()
                    }
                    HStack {
                        Text("轮廓光")
                        Slider(value: bind(\.toonRim), in: 0...1)
                        Text(String(format: "%.2f", document.renderSettings.toonRim)).captionValue()
                    }
                    ColorPicker("阴影色调 / 强度", selection: shadowTintBinding, supportsOpacity: true)
                    Toggle("启用卡通渐变", isOn: $document.renderSettings.toonEnabled)
                    Toggle("启用反壳描边", isOn: $document.renderSettings.edgesEnabled)
                    HStack {
                        Text("描边粗细")
                        Slider(value: edgeBinding, in: 0...3)
                        Text(String(format: "%.2f", document.renderSettings.edgeScale)).captionValue()
                    }
                }

                Section("光照与调色") {
                    NavigationLink {
                        LightingInspectorView(document: document)
                    } label: {
                        Label("灯光编辑器（太阳 / 点光 / 聚光 / 环境）", systemImage: "lightbulb")
                    }
                    HStack {
                        Text("世界环境")
                        Slider(value: bind(\.worldIntensity), in: 0...1.5)
                        Text(String(format: "%.2f", document.renderSettings.worldIntensity)).captionValue()
                    }
                    HStack {
                        Text("光照散射")
                        Slider(value: bind(\.worldScattering), in: 0...0.8)
                        Text(String(format: "%.2f", document.renderSettings.worldScattering)).captionValue()
                    }
                    ColorPicker("天空散射色", selection: Binding(
                        get: { Color(simd4: document.renderSettings.worldSkyColor) },
                        set: { document.renderSettings.worldSkyColor = $0.simd4 }))
                    ColorPicker("地面散射色", selection: Binding(
                        get: { Color(simd4: document.renderSettings.worldGroundColor) },
                        set: { document.renderSettings.worldGroundColor = $0.simd4 }))
                    HStack {
                        Text("对比度")
                        Slider(value: contrastBinding, in: 0.70...1.60)
                        Text(String(format: "%.2f", document.renderSettings.contrast)).captionValue()
                    }
                    HStack {
                        Text("饱和度")
                        Slider(value: saturationBinding, in: 0.55...1.75)
                        Text(String(format: "%.2f", document.renderSettings.saturation)).captionValue()
                    }
                    HStack {
                        Text("曝光")
                        Slider(value: exposureBinding, in: 0.5...2.0)
                        Text(String(format: "%.2f", document.renderSettings.exposure)).captionValue()
                    }
                    HStack {
                        Text("暗角")
                        Slider(value: vignetteBinding, in: 0...1.4)
                        Text(String(format: "%.2f", document.renderSettings.vignette)).captionValue()
                    }
                }

                Section("输出") {
                    Picker("渲染尺寸", selection: outputPresetBinding) {
                        ForEach(outputPresets, id: \.title) { preset in
                            Text(preset.title).tag(preset.title)
                        }
                    }
                    Toggle("透明背景（Alpha）", isOn: $document.renderSettings.photoTransparentBackground)
                    Toggle("包含地面网格", isOn: $document.renderSettings.photoIncludeGrid)
                    Toggle("包含骨骼线", isOn: $document.renderSettings.photoIncludeBones)
                    Text("渲染会创建独立的 Metal 离屏目标，不复用屏幕 drawable，也不使用 UIGraphics 截图。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section("渲染") {
                    Button {
                        NotificationCenter.default.post(name: .mmdCapturePhoto,
                                                        object: NSNumber(value: document.renderSettings.photoScale))
                    } label: {
                        Label("渲染当前相机", systemImage: "camera.fill")
                            .font(.headline)
                    }
                    Button {
                        showCamera = true
                    } label: {
                        Label("打开 Camera Studio（构图/焦距）", systemImage: "camera.aperture")
                    }
                    if let lastPhotoOK {
                        Text(lastPhotoOK ? "渲染图已保存到相册" : "渲染失败，请查看日志")
                            .font(.caption)
                            .foregroundStyle(lastPhotoOK ? .green : .orange)
                    }
                }

                Section("诊断") {
                    NavigationLink {
                        LogViewer()
                    } label: {
                        Label("查看运行日志", systemImage: "doc.text.magnifyingglass")
                    }
                }
            }
            .navigationTitle("渲染工作台")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showCamera) {
                CameraStudioView(document: document)
                    .presentationDetents([.height(430), .large])
                    .presentationDragIndicator(.visible)
            }
            .onReceive(NotificationCenter.default.publisher(for: .mmdPhotoCaptured)) { note in
                lastPhotoOK = note.object as? Bool
            }
        }
    }

    private var outputPresetBinding: Binding<String> {
        Binding(
            get: {
                let width = document.renderSettings.photoWidth
                let height = document.renderSettings.photoHeight
                return outputPresets.first(where: { $0.width == width && $0.height == height })?.title
                    ?? "\(width) × \(height)"
            },
            set: { title in
                guard let preset = outputPresets.first(where: { $0.title == title }) else { return }
                document.renderSettings.photoWidth = preset.width
                document.renderSettings.photoHeight = preset.height
            }
        )
    }

    private var shadowTintBinding: Binding<Color> {
        Binding(
            get: { Color(simd4: document.renderSettings.toonShadowTint) },
            set: { document.renderSettings.toonShadowTint = $0.simd4 }
        )
    }

    private var edgeBinding: Binding<Double> {
        Binding(
            get: { Double(document.renderSettings.edgeScale) },
            set: { document.renderSettings.edgeScale = Float($0) }
        )
    }

    private var contrastBinding: Binding<Double> {
        Binding(
            get: { Double(document.renderSettings.contrast) },
            set: { document.renderSettings.contrast = Float($0) }
        )
    }

    private var saturationBinding: Binding<Double> {
        Binding(
            get: { Double(document.renderSettings.saturation) },
            set: { document.renderSettings.saturation = Float($0) }
        )
    }

    private var exposureBinding: Binding<Double> {
        Binding(
            get: { Double(document.renderSettings.exposure) },
            set: { document.renderSettings.exposure = Float($0) }
        )
    }

    private var vignetteBinding: Binding<Double> {
        Binding(
            get: { Double(document.renderSettings.vignette) },
            set: { document.renderSettings.vignette = Float($0) }
        )
    }

    private func bind(_ keyPath: WritableKeyPath<MMDRenderSettings, Float>) -> Binding<Double> {
        Binding(
            get: { Double(document.renderSettings[keyPath: keyPath]) },
            set: { document.renderSettings[keyPath: keyPath] = Float($0) }
        )
    }
}

// MARK: - Scene objects / transform editor

struct SceneEditorView: View {
    @ObservedObject var document: MMDModelDocument
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    @State private var showBackgroundImporter = false
    @State private var importError: String?

    private var selectedAttachment: MMDAttachment? {
        guard let id = document.selectedAttachmentID else { return nil }
        return document.attachments.first { $0.id == id }
    }

    private var packageOptions: [MMDModelDocument.MMDPackageModelOption] {
        document.packageModelOptions()
    }

    @ViewBuilder
    private var packageModelsSection: some View {
        if !packageOptions.isEmpty {
            Section {
                ForEach(packageOptions) { option in
                    Button {
                        guard !option.alreadyAdded else { return }
                        do { _ = try document.addPackageModel(option) }
                        catch { importError = error.localizedDescription }
                    } label: {
                        HStack {
                            Image(systemName: option.alreadyAdded ? "checkmark.circle" : "plus.circle")
                                .foregroundStyle(option.alreadyAdded ? Color.secondary : Color.cyan)
                            Text(option.name).foregroundStyle(option.alreadyAdded ? Color.secondary : Color.primary)
                            Spacer()
                            Text(option.alreadyAdded ? "已添加" : "加入画布")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(option.alreadyAdded)
                }
            } header: {
                Text("当前模型包内的其他模型")
            } footer: {
                Text("压缩包内其余 PMX/PMD 仍保留在本地，可按需逐个加入场景。")
                    .font(.caption2)
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showImporter = true } label: {
                        Label("导入武器 / 配饰 / 静态模型", systemImage: "square.and.arrow.down")
                    }
                    Text("支持 PMX、文件夹和 ZIP。导入后可绑定到手、头、脚等任意骨骼，也可保持为世界物件。")
                        .font(.caption2).foregroundStyle(.secondary)
                    if document.attachments.isEmpty {
                        Text("当前没有配饰。可在上方从当前模型包添加，或单独导入武器/配饰。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(document.attachments) { attachment in
                            Button { document.selectAttachment(id: attachment.id) } label: {
                                HStack {
                                    Image(systemName: attachment.boundBoneIndex == nil ? "cube" : "link").foregroundStyle(.cyan)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(attachment.name).foregroundStyle(.primary)
                                        Text(bindingLabel(attachment)).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if document.selectedAttachmentID == attachment.id {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.cyan)
                                    }
                                }
                            }
                        }
                        .onDelete { offsets in
                            offsets.map { document.attachments[$0].id }.forEach(document.removeAttachment)
                        }
                    }
                } header: { Text("场景物件") }

                packageModelsSection

                if let attachment = selectedAttachment {
                    Section("选中物件：\(attachment.name)") {
                        Toggle("显示物件", isOn: Binding(
                            get: { selectedAttachment?.visible ?? false },
                            set: { value in document.updateAttachment(id: attachment.id) { $0.visible = value } }))
                        Picker("绑定骨骼", selection: Binding(
                            get: { selectedAttachment?.boundBoneIndex ?? -1 },
                            set: { index in document.bindAttachment(id: attachment.id, to: index >= 0 ? index : nil) })) {
                            Text("不绑定（世界坐标）").tag(-1)
                            ForEach(document.model.bones.indices, id: \.self) { index in
                                Text(document.model.bones[index].name).tag(index)
                            }
                        }
                        Button("按名称自动选择骨骼") {
                            if let joint = document.suggestedAttachmentJoint(for: attachment.name),
                               let bone = document.humanoidBoneIndex(for: joint) {
                                document.bindAttachment(id: attachment.id, to: bone)
                            }
                        }
                        Button("在画布编辑") {
                            document.selectAttachment(id: attachment.id)
                            dismiss()
                        }
                        attachmentVector("位置", keyPath: \.position, range: -40...40, id: attachment.id)
                        attachmentVector("旋转 °", keyPath: \.rotation, range: -180...180, id: attachment.id)
                        attachmentVector("缩放", keyPath: \.scale, range: 0.02...5, id: attachment.id)
                        Button("重置变换") {
                            document.updateAttachment(id: attachment.id) {
                                $0.position = .zero; $0.rotation = .zero; $0.scale = SIMD3<Float>(1, 1, 1)
                            }
                        }
                        Button("移出场景", role: .destructive) { document.removeAttachment(id: attachment.id) }
                    }
                }

                Section("场景背景") {
                    if let path = document.renderSettings.backgroundImagePath,
                       FileManager.default.fileExists(atPath: path) {
                        LabeledContent("当前背景", value: (path as NSString).lastPathComponent)
                        Button("移除背景图") {
                            document.renderSettings.backgroundImagePath = nil
                        }
                        .foregroundStyle(.red)
                    } else {
                        Text("未设置背景图，使用当前渐变背景色。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button { showBackgroundImporter = true } label: {
                        Label("导入背景图片", systemImage: "photo")
                    }
                    Text("支持 PNG / JPEG / HEIC；按比例填充画面，不改变模型与相机。透明视频导出时背景图会一并跳过。")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Section("灯光物件") {
                    ForEach(document.renderSettings.lights.indices, id: \.self) { index in
                        let light = document.renderSettings.lights[index]
                        Button { document.selectLight(id: light.id) } label: {
                            HStack {
                                Image(systemName: light.kind.symbolName).foregroundStyle(Color(simd4: light.color))
                                Text(light.name).foregroundStyle(.primary)
                                Spacer()
                                if document.selectedLightID == light.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.cyan)
                                }
                            }
                        }
                    }
                    if let id = document.selectedLightID,
                       let index = document.renderSettings.lights.firstIndex(where: { $0.id == id }) {
                        let kind = document.renderSettings.lights[index].kind
                        if kind == .point || kind == .spot {
                            lightVector("灯光位置", index: index, keyPath: \.position, range: -40...40)
                        }
                        if kind == .sun || kind == .spot {
                            lightVector("照射方向", index: index, keyPath: \.direction, range: -1...1)
                        }
                        Button("在画布移动灯光") {
                            document.selectLight(id: id)
                            dismiss()
                        }
                    }
                    NavigationLink { LightingInspectorView(document: document) } label: {
                        Label("完整灯光参数", systemImage: "lightbulb")
                    }
                }

                Section("画布操作") {
                    Toggle("启用变换 Gizmo", isOn: $document.sceneEditEnabled)
                    Text("单指拖动执行移动/旋转/缩放，顶部工具条切换模式和 X/Y/Z 轴；双指平移，捏合缩放相机。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("场景与配饰")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .sheet(isPresented: $showBackgroundImporter) {
                MMDDocumentPicker(contentTypes: MMDImportTypes.imageImport, allowsMultipleSelection: false,
                                  onPick: { urls in
                                      showBackgroundImporter = false
                                      guard let url = urls.first else { return }
                                      importBackground(from: url)
                                  }, onCancel: { showBackgroundImporter = false })
            }
            .sheet(isPresented: $showImporter) {
                MMDDocumentPicker(contentTypes: MMDImportTypes.modelImport, allowsMultipleSelection: false,
                                  onPick: { urls in
                                      showImporter = false
                                      guard let url = urls.first else { return }
                                      let accessed = url.startAccessingSecurityScopedResource()
                                      defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                                      do { _ = try document.importAttachment(from: url) }
                                      catch { importError = error.localizedDescription }
                                  }, onCancel: { showImporter = false })
            }
            .alert("配饰导入失败", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(importError ?? "") }
        }
    }

    private func importBackground(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let directory = documents.appendingPathComponent("MMDStudio/Backgrounds", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
            let destination = directory.appendingPathComponent("bg-\(UUID().uuidString).\(ext)")
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            document.renderSettings.backgroundImagePath = destination.path
        } catch {
            importError = "背景导入失败：\(error.localizedDescription)"
        }
    }

    private func bindingLabel(_ attachment: MMDAttachment) -> String {
        guard let index = attachment.boundBoneIndex, document.model.bones.indices.contains(index) else { return "世界物件" }
        return "绑定：\(document.model.bones[index].name)"
    }

    @ViewBuilder
    private func attachmentVector(_ title: String, keyPath: WritableKeyPath<MMDAttachment, SIMD3<Float>>,
                                  range: ClosedRange<Double>, id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            ForEach(0..<3, id: \.self) { axis in
                HStack {
                    Text(["X", "Y", "Z"][axis]).frame(width: 16)
                    Slider(value: Binding<Double>(
                        get: { Double(document.attachments.first { $0.id == id }?[keyPath: keyPath][axis] ?? 0) },
                        set: { value in document.updateAttachment(id: id) { $0[keyPath: keyPath][axis] = Float(value) } }
                    ), in: range)
                }
            }
        }
    }

    private func lightVector(_ title: String, index: Int,
                             keyPath: WritableKeyPath<MMDLightSetting, SIMD3<Float>>,
                             range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            ForEach(0..<3, id: \.self) { axis in
                HStack {
                    Text(["X", "Y", "Z"][axis]).frame(width: 16)
                    Slider(value: Binding<Double>(
                        get: { Double(document.renderSettings.lights[index][keyPath: keyPath][axis]) },
                        set: { value in document.renderSettings.lights[index][keyPath: keyPath][axis] = Float(value) }
                    ), in: range)
                }
            }
        }
    }
}
