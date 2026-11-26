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
        // This screen is presented in a full-screen cover, which has no
        // interactive pop gesture at all. Exiting therefore has exactly one
        // route: this button. Disabling the UINavigationController gesture from
        // a representable did not hold — SwiftUI re-enabled it after each
        // appearance, which is why an orbit drag from the left edge still
        // dismissed the canvas.
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
                // A 40k-vertex PMX plus its accessory set takes seconds to
                // parse. Doing that on the main thread blocked the UI long
                // enough for the watchdog to kill the app, which read as a
                // crash on "complex" models only.
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
            // The library owns the only copy of each clip now; anything the
            // old per-document importer staged can go when the canvas closes.
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
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 6) {
                CanvasCommandBar(
                    document: document,
                    showMaterials: $showMaterials,
                    showMorphs: $showMorphs,
                    showLights: $showLights,
                    isRecording: recorder.isRecording,
                    onMotion: { showMotionLibrary = true },
                    onBones: { showBones = true },
                    onTextures: { showTextures = true },
                    onScene: { showSceneEditor = true },
                    onRenderStudio: { showRenderStudio = true },
                    onExport: { showExportStudio = true },
                    onSettings: { showSettings = true },
                    onPose: { showPoseImporter = true },
                    onResetCamera: {
                        NotificationCenter.default.post(name: .mmdResetCamera, object: nil)
                        toast = "视角已重置"
                    },
                    onPhoto: {
                        NotificationCenter.default.post(name: .mmdCapturePhoto,
                                                        object: NSNumber(value: document.renderSettings.photoScale))
                    },
                    onRecord: {
                        if recorder.isRecording {
                            recorder.stop()
                            toast = "正在保存引擎录制…"
                        } else {
                            recorder.start()
                            toast = "开始引擎录制（不含界面控件）"
                        }
                    }
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showExportStudio = true } label: {
                        Label("导出工作室", systemImage: "square.and.arrow.up.on.square")
                    }
                    Button { showPoseImporter = true } label: {
                        Label("导入 VPD 姿势", systemImage: "figure.stand")
                    }
                    Button { document.resetPhysics() } label: {
                        Label("重置物理", systemImage: "arrow.counterclockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
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

                Menu {
                    Toggle("循环播放", isOn: Binding(get: { document.loopPlayback },
                                                    set: { document.loopPlayback = $0 }))
                    Menu("播放速度") {
                        ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { speed in
                            Button(String(format: "%.1fx", speed)) {
                                document.playbackSpeed = Float(speed)
                            }
                        }
                    }
                    if document.hasCameraMotion {
                        Toggle("使用 VMD 相机", isOn: Binding(get: { document.useCameraMotion },
                                                            set: { document.useCameraMotion = $0 }))
                    }
                    Button { showMotionLibrary = true } label: {
                        Label("动作库 / 更换动作", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button { showPoseImporter = true } label: {
                        Label("导入 VPD 姿势", systemImage: "figure.stand")
                    }
                    Button { document.removeMotion() } label: {
                        Label("移除动作", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18))
                        .frame(width: 30, height: 30)
                }
                .foregroundStyle(.white.opacity(0.85))
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

    /// Toast when the library picker loads a clip: the sheet dismisses before
    /// the mapping count is known, so it reports back through NotificationCenter.
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

/// Blender-like transform controls for the selected scene object. The actual
/// RGB axes are rendered in world space by the Metal overlay; these controls
/// choose how a one-finger drag changes the selection.
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

/// Persistent style chips. The four game looks live on the canvas so the
/// common render-style switch is one tap, not a nested settings menu.
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
private struct CanvasCommandBar: View {

    @ObservedObject var document: MMDModelDocument
    @Binding var showMaterials: Bool
    @Binding var showMorphs: Bool
    @Binding var showLights: Bool
    let isRecording: Bool
    let onMotion: () -> Void
    let onBones: () -> Void
    let onTextures: () -> Void
    let onScene: () -> Void
    let onRenderStudio: () -> Void
    let onExport: () -> Void
    let onSettings: () -> Void
    let onPose: () -> Void
    let onResetCamera: () -> Void
    let onPhoto: () -> Void
    let onRecord: () -> Void

    private var accent: Color { Color(red: 0.38, green: 0.90, blue: 0.98) }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onMotion) {
                cell("figure.walk", "动作", active: document.hasMotion)
            }
            .buttonStyle(.plain)

            Button { showMaterials = true } label: {
                cell("paintpalette", "材质", active: showMaterials)
            }
            .buttonStyle(.plain)

            Button { showMorphs = true } label: {
                cell("face.smiling", "表情", active: showMorphs)
            }
            .buttonStyle(.plain)

            Button { showLights = true } label: {
                cell("lightbulb", "灯光", active: showLights)
            }
            .buttonStyle(.plain)

            physicsMenu
            moreMenu
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.white.opacity(0.08), lineWidth: 1))
        .padding(.horizontal, 8)
    }

    /// 物理既是最常调的调试项，也是「显示刚体」的开关所在地，
    /// 所以做成菜单，省掉「进设置 → 找物理 → 再翻回来」的往返。
    private var physicsMenu: some View {
        Menu {
            Picker("物理模式", selection: $document.physicsSettings.mode) {
                ForEach(MMDPhysicsMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Divider()
            Toggle(isOn: $document.renderSettings.showRigidBodies) {
                Label("显示刚体", systemImage: "circle.hexagongrid")
            }
            Toggle(isOn: $document.renderSettings.showPhysicsColliders) {
                Label("显示碰撞球", systemImage: "circle.dotted")
            }
            Divider()
            Button { document.resetPhysics() } label: {
                Label("重置物理", systemImage: "arrow.triangle.2.circlepath")
            }
        } label: {
            cell("circle.hexagongrid",
                 "物理",
                 active: document.renderSettings.showRigidBodies || document.physicsSettings.mode != .off)
        }
        .tint(.white)
    }

    private var moreMenu: some View {
        Menu {
            Section("检查器") {
                Button(action: onBones) { Label("骨骼列表", systemImage: "figure.stand") }
                Button(action: onTextures) { Label("贴图清单", systemImage: "photo.on.rectangle.angled") }
                Button(action: onScene) { Label("场景与背景", systemImage: "cube.transparent") }
                Button(action: onRenderStudio) { Label("渲染工作台", systemImage: "slider.horizontal.3") }
            }
            Section("画布") {
                Button(action: onResetCamera) { Label("重置视角", systemImage: "arrow.counterclockwise") }
                Toggle(isOn: $document.renderSettings.showGrid) {
                    Label("地面网格", systemImage: "grid")
                }
                Toggle(isOn: $document.renderSettings.showGroundShadow) {
                    Label("地面阴影", systemImage: "circle.dashed")
                }
                Toggle(isOn: $document.renderSettings.showPerformanceHUD) {
                    Label("性能监控", systemImage: "speedometer")
                }
            }
            Section("输出") {
                Button(action: onPhoto) { Label("保存渲染图", systemImage: "camera.fill") }
                Button(action: onRecord) {
                    Label(isRecording ? "停止录制" : "录制视频",
                          systemImage: isRecording ? "stop.circle" : "record.circle")
                }
                Button(action: onExport) { Label("导出工作室", systemImage: "square.and.arrow.up") }
            }
            Section {
                Button(action: onPose) { Label("导入 VPD 姿势", systemImage: "figure.stand") }
                Button(action: onSettings) { Label("全部设置", systemImage: "gearshape") }
            }
        } label: {
            cell("ellipsis.circle", "更多")
        }
        .tint(.white)
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

/// 所有画布检查器（材质 / 表情 / 灯光 / 设置…）共用的外壳。
///
/// 1. 统一半高、圆角、毛玻璃，以前七处各写一遍，改一个间距要改七次；
/// 2. 面板出现时抬高 `canvasLift`，渲染器把画面上移并轻微缩小，模型不会
///    被面板压住，调参数时能直接看到结果。
private struct InspectorPanel<Content: View>: View {

    @ObservedObject var document: MMDModelDocument
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .presentationDetents([.fraction(0.46), .large])
            .presentationBackground(.ultraThinMaterial)
            .presentationCornerRadius(24)
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.46)))
            .onAppear { document.canvasLift = 0.34 }
            .onDisappear { document.canvasLift = 0 }
    }
}

// MARK: - Texture export

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
