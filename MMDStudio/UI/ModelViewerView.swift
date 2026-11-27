//
//  ModelViewerView.swift
//  MMD Studio
//
//  画布：Metal 视图、底栏命令、检查器面板。
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ModelScreen: View {

    let entry: MMDModelEntry
    @EnvironmentObject private var store: MMDStore
    @Environment(\.dismiss) private var dismiss
    @State private var document: MMDModelDocument?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let document {
                ModelViewerView(document: document)
            } else if let loadError {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 34))
                        .foregroundStyle(.orange)
                    Text("模型加载失败")
                        .font(.headline)
                    Text(loadError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }
            } else {
                ProgressView("正在解析 PMX…")
                    .tint(.cyan)
            }
        }
        .navigationTitle(entry.displayName)
        .navigationBarTitleDisplayMode(.inline)
        // 这个界面以全屏 cover 呈现，本身就没有
        // 交互式返回手势。所以退出只有一条路：
        // 这个按钮。在 representable 里关掉
        // UINavigationController 的手势并不管用 —— SwiftUI 每次
        // 出现后又把它打开，这就是从左边缘绕轨道拖拽
        // 仍会把画布关掉的原因。
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                }
                .accessibilityLabel("返回模型库")
            }
        }
        .task {
            guard document == nil, loadError == nil else { return }
            let entry = self.entry
            let store = self.store
            do {
                // 4 万顶点的 PMX 加上它的挂件，解析要好几秒。
                // 放在主线程会把 UI 卡到看门狗杀进程，
                // 看起来就像「复杂模型」一开
                // 就崩。
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try store.open(entry)
                }.value
                document = loaded
            } catch {
                loadError = error.localizedDescription
            }
        }
        .onDisappear {
            document?.pause()
            // 现在每个片段只有库里的那一份；旧版按文档
            // 导入暂存的东西，画布关闭时都可以清掉。
            MMDMotionLibrary.shared.purgeSessionCache()
        }
    }
}

struct ModelViewerView: View {

    @ObservedObject var document: MMDModelDocument

    @State private var showMaterials = false
    @State private var showTextures = false
    @State private var showMorphs = false
    @State private var showBones = false
    @State private var showSettings = false
    @State private var showLights = false
    @State private var showRenderStudio = false
    @State private var showSceneEditor = false
    @State private var showMotionLibrary = false
    @State private var showExportStudio = false
    @State private var showPoseImporter = false
    @State private var motionError: String?
    @State private var showModelDetails = false
    @State private var toast: String?
    @State private var isScrubbingInspector = false
    /// 当前打开的浮层面板。用画布内浮层代替系统 Menu：菜单在每秒被性能
    /// 统计刷新的宿主里会不断重建，表现为闪一下、滚动位置弹回顶部。
    @State private var palettePage: CanvasPalette.Page?
    @StateObject private var recorder = MMDScreenRecorder.shared

    var body: some View {
        ZStack {
            MMDMetalView(document: document)
                .ignoresSafeArea(edges: .top)

            VStack {
                VStack(alignment: .leading, spacing: 5) {
                    StylePresetStrip(selection: $document.renderSettings.style,
                                     renderMode: $document.renderSettings.renderMode)
                    if (inspectorIsOpen || isScrubbingInspector) && document.hasMotion {
                        inspectorScrubBar
                    }
                    if document.sceneEditEnabled {
                        CanvasTransformBar(document: document)
                    }
                    HStack(alignment: .top) {
                        Spacer()
                        VStack(alignment: .trailing, spacing: 6) {
                            if document.renderSettings.showPerformanceHUD {
                                performanceBadge
                            }
                            displayToggles
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                Spacer()
            }
            if let toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.72), in: Capsule())
                        .padding(.bottom, 86)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .allowsHitTesting(false)
            }
            if let page = palettePage {
                paletteOverlay(page)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 6) {
                CanvasCommandBar(
                    hasMotion: document.hasMotion,
                    physicsActive: document.renderSettings.showRigidBodies
                        || document.physicsSettings.mode != .off,
                    activePage: palettePage,
                    showMaterials: showMaterials,
                    showMorphs: showMorphs,
                    showLights: showLights,
                    onMotion: { closePalette(); showMotionLibrary = true },
                    onMaterials: { closePalette(); showMaterials = true },
                    onMorphs: { closePalette(); showMorphs = true },
                    onLights: { closePalette(); showLights = true },
                    onPage: { openPalette($0) }
                )
                compactPlaybackBar
            }
            .padding(.top, 5)
            .background(.black.opacity(0.18))
        }
        .onReceive(NotificationCenter.default.publisher(for: .mmdPhotoCaptured)) { note in
            showToast(note.object as? Bool == true ? "渲染图已保存到相册" : "渲染失败，请查看日志")
        }
        .onChange(of: document.renderSettings.style) { _, style in
            document.renderSettings.applyStyleDefaults(style)
        }
        .onReceive(recorder.$lastError.compactMap { $0 }) { error in
            showToast("录制失败：\(error)")
        }
        .onReceive(NotificationCenter.default.publisher(for: .mmdRecordingSaved)) { note in
            showToast(note.object as? Bool == true ? "引擎录制已保存到相册" : "录制保存失败，请查看日志")
        }
        .onReceive(NotificationCenter.default.publisher(for: .mmdMotionLoaded)) { note in
            handleMotionLoaded(note)
        }
        .sheet(isPresented: $showMaterials) {
            InspectorPanel(document: document) {
                MaterialInspectorView(document: document)
            }
        }
        .sheet(isPresented: $showTextures) {
            InspectorPanel(document: document) {
                TextureExportView(document: document)
            }
        }
        .sheet(isPresented: $showMorphs) {
            InspectorPanel(document: document) {
                MorphInspectorView(document: document)
            }
        }
        .sheet(isPresented: $showBones) {
            InspectorPanel(document: document) {
                BoneInspectorView(document: document)
            }
        }
        .sheet(isPresented: $showLights) {
            InspectorPanel(document: document) {
                NavigationStack { LightingInspectorView(document: document) }
            }
        }
        .sheet(isPresented: $showRenderStudio) {
            RenderStudioView(document: document)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSceneEditor) {
            InspectorPanel(document: document) {
                SceneEditorView(document: document)
            }
        }
        .sheet(isPresented: $showSettings) {
            InspectorPanel(document: document) {
                SettingsInspectorView(document: document)
            }
        }
        .sheet(isPresented: $showExportStudio) {
            ExportStudioView(document: document)
        }
        .sheet(isPresented: $showPoseImporter) {
            MMDDocumentPicker(contentTypes: MMDImportTypes.poseImport,
                              allowsMultipleSelection: false,
                              onPick: { urls in
                                  showPoseImporter = false
                                  guard let url = urls.first else { return }
                                  loadPose(url: url)
                              },
                              onCancel: { showPoseImporter = false })
        }
        .sheet(isPresented: $showMotionLibrary) {
            MotionLibraryPicker(document: document)
        }
        // 原来这里还有一个「导出 / 导入姿势 / 重置物理」的导航栏 Menu。它的三项
        // 在「更多」浮层里都有；留着只是多一个会被画布刷新打断的下拉菜单。
        .alert("动作加载失败", isPresented: Binding(get: { motionError != nil },
                                                   set: { if !$0 { motionError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(motionError ?? "")
        }
        .alert("渲染错误", isPresented: Binding(get: { document.errorMessage != nil },
                                               set: { if !$0 { document.errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(document.errorMessage ?? "")
        }
    }

    /// 画布右上角的常驻显示开关。
    ///
    /// 这类开关是「边看边调」的，藏进设置里等于没有：每开一次要弹面板、
    /// 盖住模型、再关掉。放在画布上直接点，图标亮起即为开启。
    private var displayToggles: some View {
        HStack(spacing: 2) {
            overlayToggle("grid", "网格", isOn: $document.renderSettings.showGrid)
            overlayToggle("figure.arms.open", "骨架", isOn: $document.renderSettings.showBones)
            overlayToggle("circle.hexagongrid", "刚体", isOn: $document.renderSettings.showRigidBodies)
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func overlayToggle(_ symbol: String, _ label: String,
                               isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 26)
                .foregroundStyle(isOn.wrappedValue
                                 ? Color(red: 0.38, green: 0.90, blue: 0.98)
                                 : Color.white.opacity(0.7))
                .background(isOn.wrappedValue
                            ? Color(red: 0.38, green: 0.90, blue: 0.98).opacity(0.24)
                            : Color.clear,
                            in: Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : AccessibilityTraits())
    }

    private var performanceBadge: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 8) {
                Text("\(Int(document.renderStats.fps.rounded())) FPS")
                Text(String(format: "%.1f/%.1f ms", document.renderStats.cpuMilliseconds, document.renderStats.gpuMilliseconds))
                if document.renderStats.missingTextures > 0 {
                    Label("\(document.renderStats.missingTextures)", systemImage: "photo.badge.exclamationmark")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption2.monospacedDigit().weight(.semibold))
            Text("v\(document.appVersionText) · \(document.renderStats.resolution) · \(document.renderStats.qualityLabel)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
            if showModelDetails {
                Text("\(document.renderStats.triangles) tris · \(document.renderStats.drawCalls) calls")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.2)) { showModelDetails.toggle() }
        }
        .accessibilityLabel("实时渲染性能")
    }

    private var inspectorIsOpen: Bool {
        showMaterials || showTextures || showMorphs || showBones || showLights ||
        showRenderStudio || showSceneEditor || showSettings
    }

    private var inspectorScrubBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "timeline.selection")
                .font(.caption)
                .foregroundStyle(Color(red: 0.38, green: 0.90, blue: 0.98))
            Slider(value: Binding(get: { Double(min(document.currentFrame, document.duration)) },
                                  set: { document.seek(to: Float($0)) }),
                   in: 0...Double(max(document.duration, 0.1)),
                   onEditingChanged: { editing in
                       isScrubbingInspector = editing
                       if editing { closeAllInspectors() }
                   })
                .tint(Color(red: 0.38, green: 0.90, blue: 0.98))
            Text(document.timeText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
                .frame(minWidth: 42, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func closeAllInspectors() {
        showMaterials = false
        showTextures = false
        showMorphs = false
        showBones = false
        showLights = false
        showRenderStudio = false
        showSceneEditor = false
        showSettings = false
    }

    // MARK: - 画布浮层（物理 / 更多 / 播放）

    @ViewBuilder
    private func paletteOverlay(_ page: CanvasPalette.Page) -> some View {
        // 点画布空白处收起。这一层故意做成几乎透明的暗色：面板背后还能看清
        // 模型当前的样子，调参数不用来回开关。
        Color.black.opacity(0.16)
            .ignoresSafeArea()
            .onTapGesture { closePalette() }
            .transition(.opacity)

        VStack(spacing: 0) {
            Spacer(minLength: 0)
            CanvasPalette(page: page,
                          document: document,
                          isRecording: recorder.isRecording,
                          onAction: handlePaletteAction,
                          onClose: closePalette)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func openPalette(_ page: CanvasPalette.Page) {
        // 再点一次同一个入口就收起，和系统菜单的手感一致。
        if palettePage == page { closePalette(); return }
        if !inspectorIsOpen { document.canvasLift = 0.30 }
        withAnimation(.easeOut(duration: 0.2)) { palettePage = page }
    }

    private func closePalette() {
        guard palettePage != nil else { return }
        withAnimation(.easeIn(duration: 0.16)) { palettePage = nil }
        // 面板自己的 onAppear/onDisappear 不管抬升量，这里统一交还给画布。
        if !inspectorIsOpen { document.canvasLift = 0 }
    }

    private func handlePaletteAction(_ action: CanvasPalette.Action) {
        // 先收面板再开 sheet：两个呈现叠在一起时，sheet 的毛玻璃会拍到面板，
        // 看起来像闪了一下。
        closePalette()
        switch action {
        case .motionLibrary: showMotionLibrary = true
        case .bones: showBones = true
        case .textures: showTextures = true
        case .scene: showSceneEditor = true
        case .renderStudio: showRenderStudio = true
        case .exportStudio: showExportStudio = true
        case .pose: showPoseImporter = true
        case .settings: showSettings = true
        case .photo:
            NotificationCenter.default.post(name: .mmdCapturePhoto,
                                            object: NSNumber(value: document.renderSettings.photoScale))
        case .record:
            if recorder.isRecording {
                recorder.stop()
                showToast("正在保存引擎录制…")
            } else {
                recorder.start()
                showToast("开始引擎录制（不含界面控件）")
            }
        case .resetCamera:
            NotificationCenter.default.post(name: .mmdResetCamera, object: nil)
            showToast("视角已重置")
        case .resetPhysics:
            document.resetPhysics()
            showToast("物理已重置")
        case .removeMotion:
            document.removeMotion()
            showToast("已移除动作")
        }
    }

    private var compactPlaybackBar: some View {
        HStack(spacing: 8) {
            if document.hasMotion {
                Button {
                    document.togglePlayback()
                } label: {
                    Image(systemName: document.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(Color(red: 0.25, green: 0.82, blue: 0.9).opacity(0.24), in: Circle())
                }
                .foregroundStyle(.white)
                .accessibilityLabel(document.isPlaying ? "暂停" : "播放")

                Text(document.timeText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(minWidth: 44, alignment: .leading)

                Slider(value: Binding(get: { Double(min(document.currentFrame, document.duration)) },
                                      set: { document.seek(to: Float($0)) }),
                       in: 0...Double(max(document.duration, 0.1)))
                    .tint(Color(red: 0.25, green: 0.82, blue: 0.9))
                    .frame(minWidth: 80)

                Text(document.durationText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(minWidth: 36, alignment: .trailing)

                Button {
                    openPalette(.playback)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(palettePage == .playback
                                         ? Color(red: 0.38, green: 0.90, blue: 0.98)
                                         : Color.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("播放设置")
            } else {
                // 没动作时不再放一个「选择动作」按钮：底栏第一格就是动作，
                // 两个入口做同一件事只会让人犹豫点哪个。
                HStack(spacing: 6) {
                    Image(systemName: "figure.walk")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                    Text("未加载动作 · 点下方「动作」选择")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer(minLength: 2)
                    Text("30 FPS")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation(.easeIn(duration: 0.25)) { toast = nil }
        }
    }

    private func loadPose(url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let count = try document.loadPose(url: url)
            showToast("VPD 姿势已套用：\(count) 骨骼")
        } catch {
            motionError = error.localizedDescription
        }
    }

    /// 从库选择器载入片段后的提示：面板会在映射数
    /// 算出来之前就关掉，所以通过 NotificationCenter 回报。
    private func handleMotionLoaded(_ note: Notification) {
        if let text = note.object as? String { showToast(text) }
    }
}

extension Notification.Name {
    static let mmdResetCamera = Notification.Name("mmdResetCameraNotification")
    static let mmdCapturePhoto = Notification.Name("mmdCapturePhotoNotification")
    static let mmdPhotoCaptured = Notification.Name("mmdPhotoCapturedNotification")
    static let mmdMotionLoaded = Notification.Name("mmdMotionLoadedNotification")
}

/// 选中场景物体的类 Blender 变换控件。真正的
/// RGB 轴由 Metal 叠加层在世界空间绘制；
/// 这些控件决定单指拖拽如何改变选择。
private struct CanvasTransformBar: View {
    @ObservedObject var document: MMDModelDocument

    private var targetName: String {
        if let id = document.selectedAttachmentID,
           let item = document.attachments.first(where: { $0.id == id }) { return item.name }
        if let id = document.selectedLightID,
           let light = document.renderSettings.lights.first(where: { $0.id == id }) { return light.name }
        if document.model.bones.indices.contains(document.selectedBoneIndex) {
            return document.model.bones[document.selectedBoneIndex].name
        }
        return "未选择物件"
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(targetName).font(.system(size: 9, weight: .semibold)).lineLimit(1)
                .frame(maxWidth: 76, alignment: .leading)
            ForEach(MMDTransformMode.allCases) { mode in
                Button {
                    document.transformMode = mode
                } label: {
                    Image(systemName: mode.symbolName)
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 25, height: 25)
                        .background(document.transformMode == mode ? Color.cyan.opacity(0.30) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.rawValue)
            }
            Divider().frame(height: 18)
            ForEach(MMDTransformAxis.allCases) { axis in
                Button(axis.rawValue) { document.transformAxis = axis }
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(document.transformAxis == axis ? Color.cyan : Color.white.opacity(0.75))
                    .buttonStyle(.plain)
            }
            Button { document.sceneEditEnabled = false } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
    }
}

/// 常驻的风格胶囊。四种游戏观感直接放在画布上，
/// 常用的渲染风格切换一次点击，不用进嵌套菜单。
private struct StylePresetStrip: View {
    @Binding var selection: MMDRenderStyle
    @Binding var renderMode: MMDRenderMode

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(MMDRenderStyle.allCases) { style in
                    let active = renderMode == .toon && selection == style
                    Button {
                        selection = style
                        renderMode = .toon
                    } label: {
                        Text(style.rawValue)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(active ? .black : .white.opacity(0.82))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(active ? Color(red: 0.42, green: 0.91, blue: 0.98) : Color.black.opacity(0.40),
                                        in: Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(active ? 0.0 : 0.10), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    renderMode = .realistic
                } label: {
                    Text("写实")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(renderMode == .realistic ? .black : .white.opacity(0.82))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(renderMode == .realistic
                                    ? Color(red: 0.98, green: 0.78, blue: 0.42)
                                    : Color.black.opacity(0.40), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(renderMode == .realistic ? 0.0 : 0.10), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 286, alignment: .leading)
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

/// 底部主命令栏。
///
/// 旧版本把十二个入口塞进一条可横向滚动的窄条：不滑动根本看不到「骨架」
/// 「刚体」，而且材质、渲染、设置混在一起，没有分组。现在固定六格、一屏
/// 看全 —— 动作、材质、表情、灯光四个高频面板，加上物理和更多。
///
/// 这里只负责「打开什么」，不持有 document：命令栏以前观察着文档，画布的
/// 性能统计每 0.5 秒发布一次，整条栏连同里面的下拉菜单被重建，菜单刚展开
/// 就复位。
private struct CanvasCommandBar: View {

    let hasMotion: Bool
    let physicsActive: Bool
    let activePage: CanvasPalette.Page?
    let showMaterials: Bool
    let showMorphs: Bool
    let showLights: Bool
    let onMotion: () -> Void
    let onMaterials: () -> Void
    let onMorphs: () -> Void
    let onLights: () -> Void
    let onPage: (CanvasPalette.Page) -> Void

    private var accent: Color { Color(red: 0.38, green: 0.90, blue: 0.98) }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onMotion) {
                cell("figure.walk", "动作", active: hasMotion)
            }
            .buttonStyle(.plain)

            Button(action: onMaterials) {
                cell("paintpalette", "材质", active: showMaterials)
            }
            .buttonStyle(.plain)

            Button(action: onMorphs) {
                cell("face.smiling", "表情", active: showMorphs)
            }
            .buttonStyle(.plain)

            Button(action: onLights) {
                cell("lightbulb", "灯光", active: showLights)
            }
            .buttonStyle(.plain)

            Button { onPage(.physics) } label: {
                cell("circle.hexagongrid", "物理",
                     active: physicsActive || activePage == .physics)
            }
            .buttonStyle(.plain)

            Button { onPage(.more) } label: {
                cell("ellipsis.circle", "更多", active: activePage == .more)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.white.opacity(0.08), lineWidth: 1))
        .padding(.horizontal, 8)
    }

    private func cell(_ symbol: String, _ label: String, active: Bool = false) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .foregroundStyle(active ? accent : Color.white.opacity(0.85))
        .contentShape(Rectangle())
    }
}

/// 画布浮层面板：物理 / 更多 / 播放。
///
/// 为什么不用 `Menu`：下拉菜单由 UIKit 承载，SwiftUI 只是往里填内容。宿主
/// 视图被每秒刷新的性能统计重建时，菜单内容也跟着重建 —— 表现就是打开后
/// 不停闪烁、滚动位置反复回到顶部，「更多」里靠上的条目根本点不到。换成
/// 画布内的普通浮层之后，状态只存在 `@State` 里，重建只是重绘：能滚、能停、
/// 也不会把整块画布盖住。
private struct CanvasPalette: View {

    enum Page: String, Identifiable {
        case physics, more, playback

        var id: String { rawValue }

        var title: String {
            switch self {
            case .physics: return "物理"
            case .more: return "更多"
            case .playback: return "播放"
            }
        }

        /// 面板高度取内容量级：物理三项、播放四组、更多十几行（超出就滚动）。
        var height: CGFloat {
            switch self {
            case .physics: return 306
            case .playback: return 342
            case .more: return 420
            }
        }
    }

    /// 面板里除开关以外、需要由画布执行的动作。
    enum Action {
        case motionLibrary, bones, textures, scene, renderStudio, exportStudio
        case photo, record, pose, settings, resetCamera, resetPhysics, removeMotion
    }

    let page: Page
    @ObservedObject var document: MMDModelDocument
    let isRecording: Bool
    let onAction: (Action) -> Void
    let onClose: () -> Void

    private var accent: Color { Color(red: 0.38, green: 0.90, blue: 0.98) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
            ScrollView {
                VStack(spacing: 0) { content }
                    .padding(.bottom, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(height: page.height)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(Color.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(page.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(.white.opacity(0.10), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.75))
            .accessibilityLabel("关闭面板")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .physics: physicsContent
        case .more: moreContent
        case .playback: playbackContent
        }
    }

    // MARK: 物理

    @ViewBuilder
    private var physicsContent: some View {
        sectionHeader("解算模式")
        VStack(alignment: .leading, spacing: 7) {
            Picker("解算模式", selection: $document.physicsSettings.mode) {
                ForEach(MMDPhysicsMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text(document.physicsSettings.mode.detail)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)

        sectionHeader("显示")
        toggleRow("circle.hexagongrid", "显示刚体", isOn: $document.renderSettings.showRigidBodies)
        hairline
        toggleRow("circle.dotted", "显示碰撞球", isOn: $document.renderSettings.showPhysicsColliders)

        sectionHeader("操作")
        row("arrow.triangle.2.circlepath", "重置物理", detail: "把刚体与弹簧链放回初始状态") {
            onAction(.resetPhysics)
        }
    }

    // MARK: 更多

    @ViewBuilder
    private var moreContent: some View {
        sectionHeader("检查器")
        row("slider.horizontal.3", "渲染工作台") { onAction(.renderStudio) }
        hairline
        row("cube.transparent", "场景与背景") { onAction(.scene) }
        hairline
        row("photo.on.rectangle.angled", "贴图清单") { onAction(.textures) }
        hairline
        row("figure.stand", "骨骼列表") { onAction(.bones) }

        sectionHeader("画布")
        row("arrow.counterclockwise", "重置视角") { onAction(.resetCamera) }
        hairline
        toggleRow("grid", "地面网格", isOn: $document.renderSettings.showGrid)
        hairline
        toggleRow("circle.dashed", "地面阴影", isOn: $document.renderSettings.showGroundShadow)
        hairline
        toggleRow("speedometer", "性能监控", isOn: $document.renderSettings.showPerformanceHUD)

        sectionHeader("输出")
        row("camera.fill", "保存渲染图") { onAction(.photo) }
        hairline
        row(isRecording ? "stop.circle" : "record.circle",
            isRecording ? "停止录制" : "录制视频") { onAction(.record) }
        hairline
        row("square.and.arrow.up", "导出工作室") { onAction(.exportStudio) }

        sectionHeader("其它")
        row("figure.stand", "导入 VPD 姿势") { onAction(.pose) }
        hairline
        row("gearshape", "全部设置") { onAction(.settings) }
    }

    // MARK: 播放

    @ViewBuilder
    private var playbackContent: some View {
        sectionHeader("播放")
        toggleRow("repeat", "循环播放", isOn: $document.loopPlayback)
        hairline
        VStack(alignment: .leading, spacing: 6) {
            Text("播放速度")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.94))
            Picker("播放速度", selection: Binding(
                get: { Double(document.playbackSpeed) },
                set: { document.playbackSpeed = Float($0) })) {
                ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { speed in
                    Text(String(format: "%.1fx", speed)).tag(speed)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)

        if document.hasCameraMotion {
            sectionHeader("相机")
            toggleRow("video", "使用 VMD 相机", isOn: $document.useCameraMotion)
        }

        sectionHeader("动作")
        row("arrow.triangle.2.circlepath", "动作库 / 更换动作") { onAction(.motionLibrary) }
        hairline
        row("figure.stand", "导入 VPD 姿势") { onAction(.pose) }
        hairline
        row("trash", "移除动作", tint: .red) { onAction(.removeMotion) }
    }

    // MARK: 行样式

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.42))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 11)
            .padding(.bottom, 3)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 0.5)
            .padding(.leading, 50)
    }

    private func row(_ symbol: String, _ title: String, detail: String? = nil,
                     tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 24)
                    .foregroundStyle(tint ?? accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.94))
                    if let detail {
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 14)
            .frame(height: detail == nil ? 42 : 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleRow(_ symbol: String, _ title: String,
                           isOn: Binding<Bool>) -> some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 24)
                .foregroundStyle(isOn.wrappedValue ? accent : .white.opacity(0.55))
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.94))
            Spacer(minLength: 4)
            switchIndicator(isOn.wrappedValue)
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        // 整行可点。开关不交给 Toggle 控件：它自己的手势会和整行的手势打架，
        // 点一下被判定两次，等于没点。
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.16)) { isOn.wrappedValue.toggle() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn.wrappedValue ? .isButton : AccessibilityTraits())
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : AccessibilityTraits())
    }

    private func switchIndicator(_ on: Bool) -> some View {
        Capsule()
            .fill(on ? accent : Color.white.opacity(0.18))
            .frame(width: 42, height: 25)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: 19, height: 19)
                    .padding(.horizontal, 3)
            }
    }
}

/// 所有画布检查器（材质 / 表情 / 灯光 / 设置…）共用的外壳。
///
/// 1. 统一半高、圆角、毛玻璃，以前七处各写一遍，改一个间距要改七次；
/// 2. 面板出现时抬高 `canvasLift`，渲染器把画面上移并轻微缩小，模型不会
///    被面板压住，调参数时能直接看到结果。
private struct InspectorPanel<Content: View>: View {

    @ObservedObject var document: MMDModelDocument
    @ViewBuilder var content: () -> Content

    /// 每次打开都回到小窗。面板实体随 sheet 重建，这个状态也跟着重置，
    /// 所以上一次拖到全高不会留到下一次。
    @State private var detent: PresentationDetent = .fraction(0.46)

    var body: some View {
        content()
            // 两档高度，默认小窗；只有顶部横条能改高度。
            //
            // `presentationContentInteraction(.scrolls)` 是关键：默认的 .automatic
            // 会把「在内容上往上拖」解释成「把面板拉大」，于是滑一下材质列表，
            // 面板就自己涨到全屏、盖住模型。改成 .scrolls 之后，内容区域的拖动
            // 只滚列表，高度只认横条那一下。
            .presentationDetents([.fraction(0.46), .large], selection: $detent)
            .presentationContentInteraction(.scrolls)
            .presentationBackground(.ultraThinMaterial)
            .presentationCornerRadius(24)
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.46)))
            .onAppear { document.canvasLift = 0.34 }
            .onDisappear { document.canvasLift = 0 }
    }
}

// MARK: - 贴图导出

private struct TextureExportView: View {
    @ObservedObject var document: MMDModelDocument
    @Environment(\.dismiss) private var dismiss

    @State private var items: [MMDTextureExportItem] = []
    @State private var summary: MMDTextureExportSummary?
    @State private var errorText: String?
    @State private var exporting = false
    @State private var sharePayload: SharePayload?

    var body: some View {
        NavigationStack {
            List {
                Section("贴图清单") {
                    LabeledContent("模型贴图条目", value: "\(items.count)")
                    LabeledContent("已找到", value: "\(items.filter { !$0.isMissing }.count)")
                    if missingCount > 0 {
                        LabeledContent("缺失", value: "\(missingCount)")
                            .foregroundStyle(.orange)
                    }
                    Text("导出会按原始文件复制，保留 PNG/JPG/BMP/TGA/DDS 原格式，不转码、不压缩。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section("文件") {
                    if items.isEmpty {
                        Text("当前模型没有贴图条目。")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(items) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: item.isMissing ? "exclamationmark.triangle.fill" : "photo")
                                    .foregroundStyle(item.isMissing ? Color.orange : Color.cyan)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.fileName)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                    Text(item.path)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                    if let bytes = item.byteCount {
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(.white.opacity(0.35))
                                    }
                                }
                                Spacer(minLength: 2)
                                Text(item.isMissing ? "缺失" : "原图")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(item.isMissing ? Color.orange : Color.green)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if let summary {
                    Section("导出完成") {
                        LabeledContent("已导出", value: "\(summary.exported) 个文件")
                        if summary.missing > 0 {
                            LabeledContent("缺失/失败", value: "\(summary.missing)")
                                .foregroundStyle(.orange)
                        }
                        Text(summary.directory.path)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = summary.directory.path
                        } label: {
                            Label("复制导出目录", systemImage: "doc.on.doc")
                        }
                        Button {
                            sharePayload = SharePayload(items: [summary.manifestURL])
                        } label: {
                            Label("分享清单", systemImage: "square.and.arrow.up")
                        }
                        Text("也可以打开系统「文件」App → 浏览 → 我的 iPhone → MMD Studio → Exports → Textures 直接取用。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("贴图导出")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        exportAll()
                    } label: {
                        if exporting { ProgressView().scaleEffect(0.8) }
                        else { Label("导出", systemImage: "square.and.arrow.down") }
                    }
                    .disabled(exporting || items.isEmpty)
                }
            }
            .onAppear { reload() }
            .sheet(item: $sharePayload) { payload in
                ActivityView(items: payload.items)
            }
        }
    }

    private var missingCount: Int { items.filter { $0.isMissing }.count }

    private func reload() {
        items = MMDTextureExporter.items(model: document.model,
                                         baseDirectory: document.baseDirectory,
                                         fallbackRoot: document.fallbackRoot)
        errorText = nil
    }

    private func exportAll() {
        guard !exporting else { return }
        exporting = true
        errorText = nil
        let model = document.model
        let baseDirectory = document.baseDirectory
        let fallbackRoot = document.fallbackRoot
        let items = self.items
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try MMDTextureExporter.export(model: model,
                                                           baseDirectory: baseDirectory,
                                                           fallbackRoot: fallbackRoot,
                                                           items: items)
                DispatchQueue.main.async {
                    summary = result
                    exporting = false
                }
            } catch {
                DispatchQueue.main.async {
                    errorText = error.localizedDescription
                    exporting = false
                    MMDLog.shared.error("Texture export request failed: \(error.localizedDescription)",
                                        category: "Texture")
                }
            }
        }
    }
}
