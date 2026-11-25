import SwiftUI
import UIKit

struct ExportStudioView: View {

    @ObservedObject var document: MMDModelDocument
    @Environment(\.dismiss) private var dismiss
    @StateObject private var videoExporter = MMDVideoExporter()

    @State private var modelSummary: MMDModelExportSummary?
    @State private var modelError: String?
    @State private var modelExporting = false
    @State private var sharePayload: SharePayload?

    var body: some View {
        NavigationStack {
            List {
                Section("模型与姿态") {
                    Button {
                        exportModel()
                    } label: {
                        HStack {
                            Label(modelExporting ? "正在导出当前姿态…" : "导出当前姿态 OBJ + MTL + VPD",
                                  systemImage: "cube.transparent")
                            Spacer()
                            if modelExporting { ProgressView().scaleEffect(0.8) }
                        }
                    }
                    .disabled(modelExporting)
                    Text("OBJ 会烘焙当前帧的骨骼蒙皮与顶点表情，附原格式贴图和原始 PMX/PMD 副本；VPD 可导回 MMD。OBJ 不携带骨骼、IK、刚体、材质变形滑块，PMX 副本保持原样未修改。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let summary = modelSummary {
                        LabeledContent("贴图/资源", value: "\(summary.copiedAssets) 个")
                        LabeledContent("原始模型", value: summary.copiedSourceModel ? "已复制" : "无源文件")
                        Text(summary.directory.path)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button {
                            sharePayload = SharePayload(items: [summary.objURL, summary.mtlURL, summary.directory])
                        } label: {
                            Label("分享 OBJ 与目录", systemImage: "square.and.arrow.up")
                        }
                    }
                    if let modelError {
                        Text(modelError).font(.caption).foregroundStyle(.red)
                    }
                }

                Section("视频画面") {
                    HStack {
                        Text("分辨率")
                        Spacer()
                        TextField("宽", value: Binding(
                            get: { document.renderSettings.videoWidth },
                            set: { document.renderSettings.videoWidth = Self.clamp($0, 64, 4096) }
                        ), format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 66)
                        Text("×").foregroundStyle(.secondary)
                        TextField("高", value: Binding(
                            get: { document.renderSettings.videoHeight },
                            set: { document.renderSettings.videoHeight = Self.clamp($0, 64, 4096) }
                        ), format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 66)
                        Text("px").font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("帧率")
                        Spacer()
                        TextField("FPS", value: Binding(
                            get: { document.renderSettings.videoFPS },
                            set: { document.renderSettings.videoFPS = Self.clamp($0, 1, 120) }
                        ), format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                        Text("FPS").font(.caption2).foregroundStyle(.secondary)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach([(1080, 1920), (720, 1280), (1440, 2560), (2160, 3840), (1920, 1080), (1080, 1080)], id: \.0) { preset in
                                Button("\(preset.0)×\(preset.1)") {
                                    document.renderSettings.videoWidth = preset.0
                                    document.renderSettings.videoHeight = preset.1
                                }
                                .font(.caption2)
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    Toggle("透明背景（HEVC Alpha .mov）", isOn: $document.renderSettings.videoTransparentBackground)
                    Picker("画质", selection: $document.renderSettings.videoQuality) {
                        ForEach(MMDVideoQuality.allCases) { quality in
                            Text(quality.title).tag(quality)
                        }
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Text("码率")
                        Spacer()
                        TextField("自动", value: Binding(
                            get: { document.renderSettings.videoBitrateMbps },
                            set: { document.renderSettings.videoBitrateMbps = Self.clampDouble($0, 0, 200) }
                        ), format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        Text("Mbps").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("留 0 时按画质与分辨率自动计算：当前约 \(String(format: "%.1f", effectiveBitrate)) Mbps。")
                        .font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        Text("关键帧间隔")
                        Slider(value: Binding(
                            get: { Double(document.renderSettings.videoKeyframeInterval) },
                            set: { document.renderSettings.videoKeyframeInterval = Int($0.rounded()) }
                        ), in: 1...10, step: 1)
                        Text("\(document.renderSettings.videoKeyframeInterval) 秒")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("透明输出会跳过背景层，使用 HEVC with Alpha 封装为 .mov；普通输出为 H.264 .mp4。分辨率上限 4096，帧率 1–120。")
                        .font(.caption2).foregroundStyle(.secondary)
                    LabeledContent("时长", value: document.durationText)
                    LabeledContent("总帧数", value: "\(Int(ceil(Double(document.durationSeconds) * Double(document.renderSettings.videoFPS))) + 1)")
                    LabeledContent("预估体积", value: String(format: "约 %.1f MB", estimatedMegabytes))
                    if videoExporter.isExporting {
                        ProgressView(value: videoExporter.progress)
                        Text(videoExporter.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("取消导出", role: .destructive) {
                            videoExporter.cancel()
                        }
                    } else {
                        Button {
                            startVideoExport()
                        } label: {
                            Label("按 VMD 时间轴导出 MP4", systemImage: "film.stack")
                        }
                        .disabled(!document.hasMotion)
                        Text(videoExporter.statusText.isEmpty
                             ? "逐帧驱动当前帧并离屏 Metal 渲染，不是屏幕录制；有同步音频时会合并音轨。导出期间请保持页面在前台。"
                             : videoExporter.statusText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let url = videoExporter.outputURL {
                        Text(url.path)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button {
                            sharePayload = SharePayload(items: [url])
                        } label: {
                            Label("分享 MP4", systemImage: "square.and.arrow.up")
                        }
                    }
                    if let error = videoExporter.errorText {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }

                Section("单帧渲染") {
                    Button {
                        renderStill()
                    } label: {
                        Label("渲染当前帧 PNG（\(document.renderSettings.videoWidth)×\(document.renderSettings.videoHeight)）",
                              systemImage: "photo")
                    }
                    .disabled(videoExporter.isExporting || videoExporter.isRenderingStill)
                    Text("按上面的视频分辨率与透明设置离屏渲染一帧，不经过相机拍屏，也不压缩；透明开启时 PNG 保留 alpha 通道。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let url = videoExporter.stillURL {
                        Text(url.path)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button {
                            sharePayload = SharePayload(items: [url])
                        } label: {
                            Label("分享 PNG", systemImage: "square.and.arrow.up")
                        }
                    }
                    if !videoExporter.stillText.isEmpty {
                        Text(videoExporter.stillText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("说明") {
                    Text("视频导出使用上方手动设置的分辨率与帧率；普通输出为 H.264 .mp4，透明输出为 HEVC with Alpha .mov。模型导出格式为 OBJ（当前姿态）与原始 PMX/PMD 副本、VPD 姿态，不做 PMX 重写。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("导出工作室")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $sharePayload) { payload in
                ActivityView(items: payload.items)
            }
        }
    }

    private func exportModel() {
        guard !modelExporting else { return }
        modelExporting = true
        modelError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let summary = try MMDModelExporter.exportCurrentPose(document: document)
                DispatchQueue.main.async {
                    modelSummary = summary
                    modelExporting = false
                }
            } catch {
                DispatchQueue.main.async {
                    modelError = error.localizedDescription
                    modelExporting = false
                }
            }
        }
    }

    private func startVideoExport() {
        guard let renderer = MMDRenderer.active else {
            videoExporter.errorText = "找不到 Metal 渲染器，请返回模型页面后重试"
            return
        }
        document.pause()
        videoExporter.export(document: document, renderer: renderer,
                             width: document.renderSettings.videoWidth,
                             height: document.renderSettings.videoHeight,
                             fps: document.renderSettings.videoFPS,
                             transparentBackground: document.renderSettings.videoTransparentBackground,
                             quality: document.renderSettings.videoQuality,
                             bitrateMbps: document.renderSettings.videoBitrateMbps,
                             keyframeInterval: document.renderSettings.videoKeyframeInterval)
    }

    private func renderStill() {
        guard let renderer = MMDRenderer.active else {
            videoExporter.errorText = "找不到 Metal 渲染器，请返回模型页面后重试"
            return
        }
        document.pause()
        videoExporter.exportStill(document: document, renderer: renderer,
                                  width: document.renderSettings.videoWidth,
                                  height: document.renderSettings.videoHeight,
                                  transparentBackground: document.renderSettings.videoTransparentBackground)
    }

    private var effectiveBitrate: Double {
        MMDVideoExporter.resolvedBitrate(width: document.renderSettings.videoWidth,
                                         height: document.renderSettings.videoHeight,
                                         fps: document.renderSettings.videoFPS,
                                         quality: document.renderSettings.videoQuality,
                                         requested: document.renderSettings.videoBitrateMbps)
    }

    private var estimatedMegabytes: Double {
        max(0, effectiveBitrate * Double(document.durationSeconds) / 8)
    }

    private static func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int {
        min(upper, max(lower, value))
    }

    private static func clampDouble(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(upper, max(lower, value))
    }
}
