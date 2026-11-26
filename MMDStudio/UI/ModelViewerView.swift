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
        .onDisappear { document?.pause() }
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
    @State private var showCamera = false
    @State private var showRenderStudio = false
    @State private var showSceneEditor = false
    @State private var showMotionImporter = false
    @State private var motionImport: MMDMotionImport?
    @State private var motionChoice: UUID?
    @State private var showMotionPicker = false
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
                    HStack {
                        Spacer()
                        if document.renderSettings.showPerformanceHUD {
                            performanceBadge
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
                StudioCommandBar(
                    showMaterials: $showMaterials,
                    showTextures: $showTextures,
                    showMorphs: $showMorphs,
                    showBones: $showBones,
                    showLights: $showLights,
                    showCamera: $showCamera,
                    showRenderStudio: $showRenderStudio,
                    showSceneEditor: $showSceneEditor,
                    showSettings: $showSettings,
                    showBonesOverlay: document.renderSettings.showBones,
                    isRecording: recorder.isRecording,
                    onResetCamera: {
                        NotificationCenter.default.post(name: .mmdResetCamera, object: nil)
                    },
                    onToggleBones: {
                        document.renderSettings.showBones.toggle()
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
        .sheet(isPresented: $showMaterials) {
            MaterialInspectorView(document: document)
                .presentationDetents([.fraction(0.35), .large])
                .presentationBackground(.ultraThinMaterial)
                .presentationCornerRadius(22)
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.35)))
        }
        .sheet(isPresented: $showTextures) {
            TextureExportView(document: document)
                .presentationDetents([.fraction(0.35), .large])
                .presentationBackground(.ultraThinMaterial)
                .presentationCornerRadius(22)
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.35)))
        }
        .sheet(isPresented: $showMorphs) {
            MorphInspectorView(document: document)
                .presentationDetents([.fraction(0.35), .large])
                .presentationBackground(.ultraThinMaterial)
                .presentationCornerRadius(22)
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.35)))
        }
        .sheet(isPresented: $showBones) {
            BoneInspectorView(document: document)
                .presentationDetents([.fraction(0.35), .large])
                .presentationBackground(.ultraThinMaterial)
                .presentationCornerRadius(22)
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.35)))
        }
        .sheet(isPresented: $showLights) {
            NavigationStack { LightingInspectorView(document: document) }
                .presentationDetents([.fraction(0.35), .large])
                .presentationBackground(.ultraThinMaterial)
                .presentationCornerRadius(22)
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.35)))
        }
        .sheet(isPresented: $showCamera) {
            CameraStudioView(document: document)
                .presentationDetents([.fraction(0.4), .large])
                .presentationBackground(.ultraThinMaterial)
                .presentationCornerRadius(22)
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.4)))
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showRenderStudio) {
            RenderStudioView(document: document)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSceneEditor) {
            SceneEditorView(document: document)
                .presentationDetents([.fraction(0.35), .large])
                .presentationBackground(.ultraThinMaterial)
                .presentationCornerRadius(22)
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.35)))
        }
        .sheet(isPresented: $showSettings) {
            SettingsInspectorView(document: document)
                .presentationDetents([.fraction(0.35), .large])
                .presentationBackground(.ultraThinMaterial)
                .presentationCornerRadius(22)
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.35)))
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
        .sheet(isPresented: $showMotionImporter) {
            MMDDocumentPicker(contentTypes: MMDImportTypes.motionImport,
                              allowsMultipleSelection: false,
                              onPick: { urls in
                                  showMotionImporter = false
                                  guard let url = urls.first else { return }
                                  prepareMotion(url: url)
                              },
                              onCancel: { showMotionImporter = false })
        }
        .sheet(isPresented: $showMotionPicker) {
            if let job = motionImport {
                MotionCandidatePicker(job: job,
                                      selection: $motionChoice,
                                      onCancel: {
                                          showMotionPicker = false
                                          motionImport = nil
                                      },
                                      onLoad: { candidate in
                                          showMotionPicker = false
                                          confirmMotion(candidate, from: job)
                                      })
            }
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
        showCamera || showRenderStudio || showSceneEditor || showSettings
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
        showCamera = false
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
                    if !(document.motion?.cameraKeys.isEmpty ?? true) {
                        Toggle("使用 VMD 相机", isOn: Binding(get: { document.useCameraMotion },
                                                            set: { document.useCameraMotion = $0 }))
                    }
                    Button { showMotionImporter = true } label: {
                        Label("更换动作", systemImage: "arrow.triangle.2.circlepath")
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
                Button {
                    showMotionImporter = true
                } label: {
                    Label("导入 VMD / ZIP", systemImage: "square.and.arrow.down")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.white)
                Spacer(minLength: 2)
                Text("30 FPS")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
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

    /// Scan first, load second. A motion zip holds a camera VMD next to the
    /// dance, and sometimes one dance per model; picking "the first .vmd" is
    /// how an import can succeed while playback stays frozen.
    private func prepareMotion(url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let job = try document.scanMotion(url: url)
            guard let best = job.best else { throw MMDModelDocument.noPlayableMotion(in: job) }
            if job.needsChoice {
                motionImport = job
                motionChoice = best.id
                // The document picker is still dismissing; presenting the next
                // sheet in the same run loop drops it on iOS 16.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    showMotionPicker = true
                }
            } else {
                motionImport = nil
                let mapped = try document.loadMotion(candidate: best, from: job)
                var note = "已加载《\(best.title)》：\(mapped) 根骨骼 · \(best.summary)"
                if !job.skippedCameraOnly.isEmpty {
                    note += "（跳过 \(job.skippedCameraOnly.count) 个镜头文件）"
                }
                showToast(note)
            }
        } catch {
            motionError = error.localizedDescription
        }
    }

    private func confirmMotion(_ candidate: MMDMotionCandidate, from job: MMDMotionImport) {
        motionImport = nil
        do {
            let mapped = try document.loadMotion(candidate: candidate, from: job)
            showToast("已加载《\(candidate.title)》：\(mapped) 根骨骼 · \(candidate.summary)")
        } catch {
            motionError = error.localizedDescription
        }
    }
}

extension Notification.Name {
    static let mmdResetCamera = Notification.Name("mmdResetCameraNotification")
    static let mmdCapturePhoto = Notification.Name("mmdCapturePhotoNotification")
    static let mmdPhotoCaptured = Notification.Name("mmdPhotoCapturedNotification")
    static let mmdCameraPreset = Notification.Name("mmdCameraPresetNotification")
    static let mmdCameraFOV = Notification.Name("mmdCameraFOVNotification")
    static let mmdCameraDistance = Notification.Name("mmdCameraDistanceNotification")
    static let mmdCameraAutoOrbit = Notification.Name("mmdCameraAutoOrbitNotification")
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

/// Bottom command bar modelled on a DCC application: direct access to the
/// inspectors used most often. It scrolls horizontally on narrow iPhones.
private struct StudioCommandBar: View {
    @Binding var showMaterials: Bool
    @Binding var showTextures: Bool
    @Binding var showMorphs: Bool
    @Binding var showBones: Bool
    @Binding var showLights: Bool
    @Binding var showCamera: Bool
    @Binding var showRenderStudio: Bool
    @Binding var showSceneEditor: Bool
    @Binding var showSettings: Bool
    let showBonesOverlay: Bool
    let isRecording: Bool
    let onResetCamera: () -> Void
    let onToggleBones: () -> Void
    let onPhoto: () -> Void
    let onRecord: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                tool("paintpalette", label: "材质") { showMaterials = true }
                tool("photo.on.rectangle.angled", label: "贴图") { showTextures = true }
                tool("face.smiling", label: "表情") { showMorphs = true }
                tool("figure.walk", label: "骨骼") { showBones = true }
                tool("lightbulb", label: "灯光") { showLights = true }
                tool("camera.aperture", label: "相机") { showCamera = true }
                tool("slider.horizontal.3", label: "渲染") { showRenderStudio = true }
                tool("cube.transparent", label: "场景") { showSceneEditor = true }
                tool("ellipsis.circle", label: "设置") { showSettings = true }
                divider
                tool("arrow.counterclockwise", label: "重置") { onResetCamera() }
                tool(showBonesOverlay ? "eye.fill" : "eye", label: "骨架",
                     active: showBonesOverlay) { onToggleBones() }
            }
            .padding(.horizontal, 6)
        }
        .frame(height: 48)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.white.opacity(0.08), lineWidth: 1))
        .padding(.horizontal, 8)
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 24).padding(.horizontal, 3)
    }

    private func tool(_ systemName: String, label: String, active: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemName)
                    .font(.system(size: 14, weight: .semibold))
                Text(label)
                    .font(.system(size: 9, weight: .medium))
            }
            .frame(width: 46, height: 42)
            .foregroundStyle(active ? Color(red: 0.38, green: 0.90, blue: 0.98) : .white.opacity(0.84))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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

/// Two cuts of the same dance in one zip: one for a YYB Miku rig, one for an
/// Alice rig. Bone names differ, so the user has to say which model the clip
/// is for; guessing silently is what produced "imported but nothing moves".
private struct MotionCandidatePicker: View {
    let job: MMDMotionImport
    @Binding var selection: UUID?
    let onCancel: () -> Void
    let onLoad: (MMDMotionCandidate) -> Void

    private var chosen: MMDMotionCandidate? {
        job.candidates.first { $0.id == selection } ?? job.candidates.first
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(job.candidates) { candidate in
                        Button {
                            selection = candidate.id
                        } label: {
                            row(candidate)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("压缩包里有 \(job.candidates.count) 个动作")
                } footer: {
                    Text("同一支舞针对不同模型做的版本，骨骼名称并不通用。请选与当前模型同一角色的那个，或按包里的说明选择。")
                        .font(.caption2)
                }

                if !job.skippedCameraOnly.isEmpty || !job.unreadable.isEmpty {
                    Section("已跳过") {
                        ForEach(job.skippedCameraOnly, id: \.self) { name in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name).font(.caption.monospaced()).lineLimit(1)
                                Text("只有相机关键帧，导入后模型不会动")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ForEach(job.unreadable, id: \.self) { name in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name).font(.caption.monospaced()).lineLimit(1)
                                Text("无法解析，已忽略").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("选择动作")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("载入") { if let chosen { onLoad(chosen) } }
                        .disabled(chosen == nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ candidate: MMDMotionCandidate) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: selection == candidate.id ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selection == candidate.id ? Color.accentColor : Color.secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(candidate.fileName)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(candidate.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if candidate.mappedBoneCount == 0 {
                    Label("与当前模型骨骼不匹配", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}
