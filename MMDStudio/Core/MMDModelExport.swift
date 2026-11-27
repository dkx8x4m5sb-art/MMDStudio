//
//  MMDModelExport.swift
//  MMD Studio
//
//  模型与动作的导出（PMX 复制、清单生成）。
//

import Foundation
import AVFoundation
import CoreGraphics
import UIKit
import ImageIO
import UniformTypeIdentifiers
import simd

struct MMDModelExportSummary {
    let directory: URL
    let objURL: URL
    let mtlURL: URL
    let copiedAssets: Int
    let copiedSourceModel: Bool
}

enum MMDModelExporter {

    private static let fileManager = FileManager.default

    /// 把当前帧导出为带逐顶点蒙皮/形变的三角化 OBJ+MTL，
    /// 并把原始 PMX/PMD 原样复制，外加全部贴图
    /// 的原始格式文件。OBJ 是通用的
    /// 交换格式，不是 PMX 往返：它不带 MMD
    /// 骨骼、IK、刚体或 Morph 滑杆。
    static func exportCurrentPose(document: MMDModelDocument) throws -> MMDModelExportSummary {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let safeName = sanitize(document.model.displayName)
        let directory = documents
            .appendingPathComponent("MMDStudio/Exports/Models", isDirectory: true)
            .appendingPathComponent("\(safeName)-Pose-\(formatter.string(from: Date()))", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let model = document.model
        let skeleton = MMDSkeleton(model: model)
        let animations = document.effectiveBoneAnimations(frame: document.currentFrame)
        let pose = skeleton.solve(animations: animations, model: model, ikEnabled: document.ikEnabled)
        let morphPositions = MMDMorphController.positions(model: model,
                                                          weights: document.effectiveMorphWeights())

        var positions = morphPositions
        var normals = model.vertices.map { $0.normal }
        for index in positions.indices {
            let vertex = model.vertices[index]
            let p = morphPositions[index]
            var skinned = SIMD3<Float>.zero
            var skinnedNormal = SIMD3<Float>.zero
            for slot in 0..<4 {
                let weight = vertex.boneWeights[slot]
                guard weight > 0.00001 else { continue }
                let bone = Int(vertex.boneIndices[slot])
                guard bone >= 0 && bone < pose.palettes.count else { continue }
                let matrix = pose.palettes[bone]
                let transformed = matrix * SIMD4<Float>(p.x, p.y, p.z, 1)
                skinned += SIMD3<Float>(transformed.x, transformed.y, transformed.z) * weight
                let normal = matrix * SIMD4<Float>(vertex.normal.x, vertex.normal.y, vertex.normal.z, 0)
                skinnedNormal += SIMD3<Float>(normal.x, normal.y, normal.z) * weight
            }
            if simd_length(skinned) < 1e-8 { skinned = p }
            positions[index] = skinned
            if simd_length(skinnedNormal) > 1e-6 { normals[index] = simd_normalize(skinnedNormal) }
        }

        let textureItems = MMDTextureExporter.items(model: model,
                                                     baseDirectory: document.baseDirectory,
                                                     fallbackRoot: document.fallbackRoot)
        var copiedAssets = 0
        for item in textureItems {
            guard let source = item.sourceURL, fileManager.fileExists(atPath: source.path) else { continue }
            let target = directory.appendingPathComponent(item.fileName)
            do {
                if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
                try fileManager.copyItem(at: source, to: target)
                copiedAssets += 1
            } catch {
                MMDLog.shared.warning("OBJ asset copy failed: \(item.path): \(error.localizedDescription)",
                                      category: "Export")
            }
        }

        let objURL = directory.appendingPathComponent("\(safeName)-pose.obj")
        let mtlURL = directory.appendingPathComponent("\(safeName)-pose.mtl")
        var mtl = "# MMD Studio OBJ material library\n"
        for (index, material) in model.materials.enumerated() {
            mtl += "\nnewmtl material_\(index)\n"
            mtl += String(format: "Kd %.6f %.6f %.6f\n", material.diffuse.x, material.diffuse.y, material.diffuse.z)
            mtl += String(format: "Ks %.6f %.6f %.6f\n", material.specular.x, material.specular.y, material.specular.z)
            mtl += String(format: "Ns %.3f\nd %.3f\n", max(1, material.specularPower), material.diffuse.w)
            if material.textureIndex >= 0,
               let item = textureItems.first(where: { $0.id == material.textureIndex }) {
                mtl += "map_Kd \(item.fileName)\n"
            }
        }
        try mtl.write(to: mtlURL, atomically: true, encoding: .utf8)

        var obj = "# MMD Studio current pose export\n"
        obj += "# model: \(model.displayName)\n"
        obj += "# frame: \(String(format: "%.2f", document.currentFrame))\n"
        obj += "mtllib \(mtlURL.lastPathComponent)\n"
        for position in positions {
            obj += String(format: "v %.6f %.6f %.6f\n", position.x, position.y, position.z)
        }
        for vertex in model.vertices {
            obj += String(format: "vt %.6f %.6f\n", vertex.uv.x, 1 - vertex.uv.y)
        }
        for normal in normals {
            obj += String(format: "vn %.6f %.6f %.6f\n", normal.x, normal.y, normal.z)
        }
        var cursor = 0
        for (materialIndex, material) in model.materials.enumerated() {
            let count = material.indexCount
            guard count >= 3, cursor + count <= model.indices.count else {
                cursor = min(model.indices.count, cursor + max(0, count))
                continue
            }
            obj += "usemtl material_\(materialIndex)\ng\n"
            var offset = cursor
            while offset + 2 < cursor + count {
                let a = Int(model.indices[offset]) + 1
                let b = Int(model.indices[offset + 1]) + 1
                let c = Int(model.indices[offset + 2]) + 1
                obj += "f \(a)/\(a)/\(a) \(b)/\(b)/\(b) \(c)/\(c)/\(c)\n"
                offset += 3
            }
            cursor += count
        }
        try obj.write(to: objURL, atomically: true, encoding: .utf8)

        var copiedSource = false
        if let source = document.sourceURL, fileManager.fileExists(atPath: source.path) {
            let target = directory.appendingPathComponent(source.lastPathComponent)
            do {
                try fileManager.copyItem(at: source, to: target)
                copiedSource = true
            } catch {
                MMDLog.shared.warning("Original model copy failed: \(error.localizedDescription)", category: "Export")
            }
        }
        try exportVPD(document: document, directory: directory, safeName: safeName)
        MMDLog.shared.info("Model export: \(directory.path), assets=\(copiedAssets), source=\(copiedSource)",
                           category: "Export")
        return MMDModelExportSummary(directory: directory, objURL: objURL, mtlURL: mtlURL,
                                     copiedAssets: copiedAssets, copiedSourceModel: copiedSource)
    }

    /// 把当前局部骨骼姿势写成 VPD。VPD 是 MMD 标准的
    /// 静态姿势格式；名字用 Shift-JIS，UTF-8 兜底。
    private static func exportVPD(document: MMDModelDocument, directory: URL, safeName: String) throws {
        let animations = document.effectiveBoneAnimations(frame: document.currentFrame)
        var lines = ["Vocaloid Pose Data file", "; exported by MMD Studio",
                     "\(document.model.displayName);", "\(document.model.bones.count);"]
        let shiftJIS = MMDPoseParser.shiftJIS
        for (index, bone) in document.model.bones.enumerated() {
            let animation = animations[index] ?? MMDBoneAnimation()
            let q = animation.rotation
            let position = SIMD3<Float>(animation.position.x, animation.position.y, -animation.position.z)
            let values = [position.x, position.y, position.z, -q.imag.x, -q.imag.y, q.imag.z, q.real]
            let valueText = values.map { String(format: "%.6f", $0) }.joined(separator: ",")
            lines.append("\(bone.name);\(valueText)")
        }
        lines.append("0;")
        let text = lines.joined(separator: "\r\n")
        let data = text.data(using: shiftJIS) ?? text.data(using: .utf8)!
        try data.write(to: directory.appendingPathComponent("\(safeName)-pose.vpd"), options: .atomic)
    }

    private static func sanitize(_ value: String) -> String {
        let clean = value.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "Model" : clean
    }
}

/// 确定性的离屏视频导出。与屏幕录制不同，
/// 它以固定帧率逐帧驱动文档，输出时长
/// 与 VMD 一致，每一帧都是离屏 Metal 渲染。
/// 可选的 VMD 音频会混进最终 MP4。
final class MMDVideoExporter: ObservableObject {

    @Published var isExporting = false
    @Published var progress: Double = 0
    @Published var statusText = ""
    @Published var errorText: String?
    @Published private(set) var outputURL: URL?
    @Published private(set) var stillURL: URL?
    @Published var stillText = ""
    @Published private(set) var isRenderingStill = false

    private var cancelled = false
    private var queue = DispatchQueue(label: "mmd.video.export", qos: .userInitiated)

    static func resolvedBitrate(width: Int, height: Int, fps: Int,
                                quality: MMDVideoQuality, requested: Double) -> Double {
        if requested > 0 { return min(200, max(1, requested)) }
        let pixels = Double(max(1, width) * max(1, height))
        let raw = pixels * Double(max(1, fps)) * quality.bitsPerPixel / 1_000_000
        return min(200, max(2, raw))
    }

    /// 按设定好的视频尺寸渲染当前帧，写出 PNG；
    /// 开启透明输出时保留 alpha 通道。
    func exportStill(document: MMDModelDocument, renderer: MMDRenderer,
                     width: Int, height: Int, transparentBackground: Bool) {
        guard !isExporting, !isRenderingStill else { return }
        isRenderingStill = true
        stillText = "正在渲染单帧…"
        errorText = nil
        let safeName = Self.sanitize(document.displayName)
        let directories = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let documents = directories.first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = documents.appendingPathComponent("MMDStudio/Exports/Frames", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("\(safeName)-\(stamp).png")
        let frame = document.currentFrame
        renderer.captureFrame(frame: frame, width: width, height: height,
                              transparentBackground: transparentBackground) { [weak self] image in
            guard let self else { return }
            DispatchQueue.main.async {
                defer { self.isRenderingStill = false }
                guard let data = image?.pngData() else {
                    self.errorText = "单帧渲染失败"
                    self.stillText = "渲染失败"
                    return
                }
                do {
                    try data.write(to: url, options: .atomic)
                    self.stillURL = url
                    self.stillText = "已渲染 \(width)×\(height) PNG：\(url.lastPathComponent)"
                    MMDLog.shared.info("Still export: \(url.path)", category: "Export")
                } catch {
                    self.errorText = error.localizedDescription
                    self.stillText = "写入失败"
                }
            }
        }
    }

    func cancel() {
        cancelled = true
        statusText = "正在取消…"
    }

    func export(document: MMDModelDocument, renderer: MMDRenderer,
                width: Int = 1080, height: Int = 1920, fps: Int = 30,
                transparentBackground: Bool = false,
                quality: MMDVideoQuality = .high,
                bitrateMbps: Double = 0,
                keyframeInterval: Int = 2) {
        guard !isExporting else { return }
        guard document.hasMotion else {
            errorText = "请先导入 VMD 动作再导出视频"
            return
        }
        let frameCount = max(1, Int(ceil(Double(document.duration) / Double(document.frameRate) * Double(fps))) + 1)
        isExporting = true
        cancelled = false
        progress = 0
        errorText = nil
        statusText = "准备离屏渲染 \(frameCount) 帧…"
        let audioURL = document.motionAudioURL
        let safeName = Self.sanitize(document.displayName)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let videoDirectory = documents.appendingPathComponent("MMDStudio/Exports/Videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: videoDirectory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let fileExtension = transparentBackground ? "mov" : "mp4"
        let tempURL = videoDirectory.appendingPathComponent("\(safeName)-\(stamp)-temp.\(fileExtension)")
        let finalURL = videoDirectory.appendingPathComponent("\(safeName)-\(stamp).\(fileExtension)")

        queue.async { [weak self] in
            guard let self else { return }
            let originalFrame = document.currentFrame
            // 绝不能把第 0 帧画进还留着上一次导出
            // 最后一帧的纹理。
            renderer.resetCaptureTargets()
            // display link 按 120 Hz 重绘；导出期间让它继续跑，
            // 会吃掉编码器一半的 GPU 预算。
            renderer.setPreviewPaused(true)
            document.isExporting = true
            defer {
                renderer.setPreviewPaused(false)
                document.isExporting = false
            }
            do {
                try FileManager.default.removeItemIfExists(tempURL)
                let writer = try AVAssetWriter(outputURL: tempURL,
                                               fileType: transparentBackground ? .mov : .mp4)
                let targetMbps = Self.resolvedBitrate(width: width, height: height, fps: fps,
                                                      quality: quality, requested: bitrateMbps)
                // 带 alpha 的 HEVC 会把大部分码率花在颜色平面上，
                // alpha 平面因此被饿死 ——
                // 这就是第一帧剪影一直挂在后面所有帧上的原因。
                // 给透明导出更高的码率，GOP 压到一秒，
                // alpha 平面才能被频繁刷新；再关掉帧重排，
                // 第 0 帧就没法被当成参考帧扣住。
                let bitrate = Int(targetMbps * (transparentBackground ? 1.8 : 1.0) * 1_000_000)
                let keyframeSeconds = transparentBackground
                    ? 1
                    : max(1, min(10, keyframeInterval))
                let settings: [String: Any]
                if transparentBackground {
                    // 带 alpha 的 HEVC 是 Apple 唯一能把 alpha 通道
                    // 完整塞进 .mov 容器的编码器。
                    settings = [
                        AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
                        AVVideoWidthKey: width,
                        AVVideoHeightKey: height,
                        AVVideoCompressionPropertiesKey: [
                            AVVideoAverageBitRateKey: bitrate,
                            AVVideoMaxKeyFrameIntervalKey: keyframeSeconds * fps,
                            AVVideoExpectedSourceFrameRateKey: fps,
                            AVVideoAllowFrameReorderingKey: false
                        ]
                    ]
                } else {
                    // Apple 的 H.264 硬件编码器上限是 4K30
                    // （High profile level 5.1）。在那里要 2160p60 会
                    // 悄悄产出 30 fps 的文件 —— 就是「帧率不达标」
                    // 那条反馈。HEVC 能稳住 4K60，所以按像素率
                    // 挑编码器，而不是一律上 H.264。
                    let needsHEVC = width * height > 1920 * 1080 || fps > 30
                    var compression: [String: Any] = [
                        AVVideoAverageBitRateKey: bitrate,
                        AVVideoMaxKeyFrameIntervalKey: keyframeSeconds * fps,
                        AVVideoExpectedSourceFrameRateKey: fps,
                        AVVideoAllowFrameReorderingKey: true
                    ]
                    if !needsHEVC {
                        compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
                    }
                    settings = [
                        AVVideoCodecKey: needsHEVC ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
                        AVVideoWidthKey: width,
                        AVVideoHeightKey: height,
                        AVVideoCompressionPropertiesKey: compression
                    ]
                }
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
                input.expectsMediaDataInRealTime = false
                let attributes: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                ]
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                                    sourcePixelBufferAttributes: attributes)
                guard writer.canAdd(input) else { throw MMDLoadError.invalidData("无法创建 H.264 视频轨") }
                writer.add(input)
                guard writer.startWriting() else {
                    throw MMDLoadError.invalidData(writer.error?.localizedDescription ?? "视频写入器启动失败")
                }
                writer.startSession(atSourceTime: .zero)

                // 带 alpha 的 HEVC 把第一个帧内帧当作 alpha 平面的
                // 基准。这一帧里要是有角色，后面每一帧都会
                // 合成在它的剪影上 —— 就是那条「第一帧卡在整个视频
                // 底下」的残影，回读和 memset 都没修掉。
                // 开头先放一帧全透明，
                // 基准就是空的。
                let frameOffset = transparentBackground ? 1 : 0
                if transparentBackground,
                   let clear = Self.transparentPixelBuffer(width: width, height: height,
                                                           pool: adaptor.pixelBufferPool) {
                    _ = adaptor.append(clear, withPresentationTime: .zero)
                }

                var zeroCopyEnabled = true
                // 渲染耗时 vs 编码器背压。没有这个数字，
                // 「只有 30 fps」就说不清是 GPU 还是编码器的问题，
                // 两者要的修法完全不同。
                var renderTotalMs: Double = 0
                var waitTotalMs: Double = 0
                for frame in 0..<frameCount {
                    if self.cancelled { break }
                    let frameStart = CACurrentMediaTime()
                    let frameTime = Float(frame) / Float(max(1, fps)) * document.frameRate
                    var buffer: CVPixelBuffer?
                    var probeBytes: [UInt8]?
                    var probeRowBytes = 0

                    // 快路径：GPU 直接画进编码器持有的缓冲。
                    // 4K 下旧路径每帧要通过 CPU 搬 66 MB，
                    // 根本稳不住 60 fps。
                    if zeroCopyEnabled, let pool = adaptor.pixelBufferPool {
                        var pooled: CVPixelBuffer?
                        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pooled)
                        if let pooled, let texture = renderer.makeCaptureTexture(for: pooled),
                           renderer.captureFrame(into: texture, frame: frameTime,
                                                 transparentBackground: transparentBackground) {
                            if frame == 0 {
                                // 确认 IOSurface 路径真的产出了像素；
                                // 第一帧全空意味着纹理绑定
                                // 悄悄失败了，整段视频
                                // 会是空的。
                                let coverage = Self.pixelBufferCoverage(pooled)
                                if coverage > 0.001 || !transparentBackground {
                                    buffer = pooled
                                } else {
                                    zeroCopyEnabled = false
                                    MMDLog.shared.error("Zero-copy capture produced an empty frame (coverage \(String(format: "%.3f", coverage))); falling back to readback",
                                                        category: "Export")
                                }
                            } else {
                                buffer = pooled
                            }
                        }
                    }

                    if buffer == nil {
                        let semaphore = DispatchSemaphore(value: 0)
                        var frameBytes: [UInt8]?
                        var frameRowBytes = 0
                        renderer.captureFrameRaw(frame: frameTime, width: width, height: height,
                                                 transparentBackground: transparentBackground) { bytes, rowBytes in
                            frameBytes = bytes
                            frameRowBytes = rowBytes
                            semaphore.signal()
                        }
                        semaphore.wait()
                        guard let bytes = frameBytes, frameRowBytes > 0,
                              let made = Self.pixelBuffer(fromBGRA: bytes, rowBytes: frameRowBytes,
                                                          width: width, height: height,
                                                          pool: adaptor.pixelBufferPool) else {
                            throw MMDLoadError.invalidData("第 \(frame) 帧渲染失败")
                        }
                        probeBytes = bytes
                        probeRowBytes = frameRowBytes
                        buffer = made
                    }

                    if transparentBackground, let bytes = probeBytes,
                       frame == 0 || frame == frameCount / 3 {
                        // 只有兜底路径把行留在 CPU 上，
                        // 探测也就从那里写。
                        let probeURL = videoDirectory.appendingPathComponent(
                            "\(safeName)-\(stamp)-probe\(String(format: "%03d", frame)).png")
                        Self.writeFrameProbe(bytes, rowBytes: probeRowBytes,
                                             width: width, height: height, to: probeURL)
                        MMDLog.shared.info("Transparent probe frame \(frame): \(probeURL.path)",
                                           category: "Export")
                    }
                    if transparentBackground, frame < 3, let bytes = probeBytes {
                        MMDLog.shared.info("Transparent frame \(frame) alpha coverage: \(String(format: "%.2f", Self.alphaCoverage(bytes, rowBytes: probeRowBytes)))",
                                           category: "Export")
                    }
                    guard let buffer else {
                        throw MMDLoadError.invalidData("第 \(frame) 帧渲染失败")
                    }
                    let readyStart = CACurrentMediaTime()
                    renderTotalMs += (readyStart - frameStart) * 1000
                    while !input.isReadyForMoreMediaData {
                        if self.cancelled { break }
                        Thread.sleep(forTimeInterval: 0.002)
                    }
                    waitTotalMs += (CACurrentMediaTime() - readyStart) * 1000
                    guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame + frameOffset),
                                                                               timescale: CMTimeScale(fps))) else {
                        throw MMDLoadError.invalidData("第 \(frame) 帧写入失败：\(writer.error?.localizedDescription ?? "unknown")")
                    }
                    let fraction = Double(frame + 1) / Double(frameCount)
                    DispatchQueue.main.async {
                        self.progress = fraction
                        self.statusText = "渲染 \(frame + 1)/\(frameCount) 帧"
                    }
                }
                if frameCount > 0 {
                    let rendered = Double(frameCount)
                    MMDLog.shared.info(String(format: "Export timing: %.1f ms/frame render, %.1f ms/frame encoder wait, %.1f fps ceiling",
                                               renderTotalMs / rendered, waitTotalMs / rendered,
                                               1000.0 / max(0.001, (renderTotalMs + waitTotalMs) / rendered)),
                                       category: "Export")
                }
                input.markAsFinished()
                if self.cancelled {
                    writer.cancelWriting()
                    try? FileManager.default.removeItemIfExists(tempURL)
                    DispatchQueue.main.async {
                        renderer.restoreFrame(originalFrame)
                        self.isExporting = false
                        self.statusText = "已取消"
                    }
                    return
                }
                let finishSemaphore = DispatchSemaphore(value: 0)
                writer.finishWriting { finishSemaphore.signal() }
                finishSemaphore.wait()
                guard writer.status == .completed else {
                    throw MMDLoadError.invalidData(writer.error?.localizedDescription ?? "视频封装失败")
                }
                if let audioURL, FileManager.default.fileExists(atPath: audioURL.path) {
                    try Self.mux(video: tempURL, audio: audioURL, output: finalURL,
                                 transparent: transparentBackground)
                    try? FileManager.default.removeItemIfExists(tempURL)
                } else {
                    try? FileManager.default.removeItemIfExists(finalURL)
                    try FileManager.default.moveItem(at: tempURL, to: finalURL)
                }
                DispatchQueue.main.async {
                    renderer.restoreFrame(originalFrame)
                    self.outputURL = finalURL
                    self.isExporting = false
                    self.progress = 1
                    self.statusText = "导出完成：\(finalURL.lastPathComponent)"
                    MMDLog.shared.info("Video export: \(finalURL.path)", category: "Export")
                }
            } catch {
                DispatchQueue.main.async {
                    renderer.restoreFrame(document.currentFrame)
                    self.errorText = error.localizedDescription
                    self.isExporting = false
                    self.statusText = "导出失败"
                    MMDLog.shared.error("Video export failed: \(error.localizedDescription)", category: "Export")
                }
            }
        }
    }

    /// 把渲染好的 BGRA 行直接拷进 CVPixelBuffer。
    ///
    /// 上一版重建 CGContext、清空再用 `.copy` 画进去。
    /// 这依赖 Core Graphics 合成对回收池缓冲的行为
    /// 可预测，而它并不可预测：第一帧就一直
    /// 留在后面每一帧底下。整块 memcpy 根本
    /// 不做合成 —— 池子给回什么就逐字节覆盖什么，
    /// 包括行填充。
    private static func pixelBuffer(fromBGRA bytes: [UInt8], rowBytes: Int,
                                    width: Int, height: Int,
                                    pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard rowBytes >= width * 4, bytes.count >= rowBytes * height else { return nil }
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        }
        if buffer == nil {
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                                &buffer)
        }
        guard let pixelBuffer = buffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let destinationRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        // 先清空，这样对齐填充行里不会留着
        // 上一次导出的内容，哪怕池子给这个缓冲换了尺寸。
        memset(base, 0, destinationRowBytes * height)
        bytes.withUnsafeBytes { raw in
            guard let source = raw.baseAddress else { return }
            if destinationRowBytes == rowBytes {
                memcpy(base, source, rowBytes * height)
            } else {
                for row in 0..<height {
                    memcpy(base + row * destinationRowBytes,
                           source + row * rowBytes,
                           min(rowBytes, destinationRowBytes))
                }
            }
        }
        return pixelBuffer
    }

    /// 把一帧原始渲染写成 PNG，方便拿透明导出
    /// 和编码器输出对照排查。
    /// 由池子支撑、完全清空的像素缓冲。用于透明
    /// 导出的引导帧，也在池子不可用时兜底。
    private static func transparentPixelBuffer(width: Int, height: Int,
                                               pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        }
        if buffer == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                attributes as CFDictionary, &buffer)
        }
        guard let pixelBuffer = buffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, 0, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    /// alpha 高于小阈值的采样像素占比。
    /// 每次导出确认一次，证明零拷贝路径确实画了东西。
    private static func pixelBufferCoverage(_ buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        var covered = 0
        var total = 0
        var y = 0
        while y < height {
            let row = pointer + y * rowBytes
            var x = 0
            while x < width {
                if row[x * 4 + 3] > 8 { covered += 1 }
                total += 1
                x += 4
            }
            y += 4
        }
        return total > 0 ? Double(covered) / Double(total) : 0
    }

    private static func writeFrameProbe(_ bytes: [UInt8], rowBytes: Int,
                                        width: Int, height: Int, to url: URL) {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height,
                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: rowBytes, space: colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    /// 采样渲染后 BGRA 行的 alpha 字节。只在透明导出的
    /// 前几帧用，回归问题因此出现在日志里，
    /// 而不是交付出去的文件里。
    private static func alphaCoverage(_ bytes: [UInt8], rowBytes: Int) -> Double {
        guard rowBytes > 4, bytes.count > rowBytes else { return 0 }
        let rows = bytes.count / rowBytes
        var opaque = 0
        var sampled = 0
        for row in stride(from: 0, to: rows, by: max(1, rows / 32)) {
            var column = 3
            while column < rowBytes {
                if bytes[row * rowBytes + column] > 8 { opaque += 1 }
                sampled += 1
                column += 64
            }
        }
        return sampled > 0 ? Double(opaque) / Double(sampled) : 0
    }

    private static func mux(video: URL, audio: URL, output: URL,
                            transparent: Bool = false) throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)
        guard let videoTrack = videoAsset.tracks(withMediaType: .video).first,
              let compositionVideo = composition.addMutableTrack(withMediaType: .video,
                                                                 preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MMDLoadError.invalidData("无法读取临时视频轨")
        }
        try compositionVideo.insertTimeRange(CMTimeRange(start: .zero, duration: videoAsset.duration),
                                             of: videoTrack, at: .zero)
        if let audioTrack = audioAsset.tracks(withMediaType: .audio).first,
           let compositionAudio = composition.addMutableTrack(withMediaType: .audio,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid) {
            let duration = CMTimeMinimum(audioAsset.duration, videoAsset.duration)
            try? compositionAudio.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                                  of: audioTrack, at: .zero)
        }
        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: transparent ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality
        ) else {
            throw MMDLoadError.invalidData("无法创建音视频合成会话")
        }
        try? FileManager.default.removeItemIfExists(output)
        session.outputURL = output
        session.outputFileType = transparent ? .mov : .mp4
        let semaphore = DispatchSemaphore(value: 0)
        session.exportAsynchronously { semaphore.signal() }
        semaphore.wait()
        guard session.status == .completed else {
            throw MMDLoadError.invalidData(session.error?.localizedDescription ?? "音视频合成失败")
        }
    }

    private static func sanitize(_ value: String) -> String {
        let clean = value.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "MMDVideo" : clean
    }
}

private extension FileManager {
    func removeItemIfExists(_ url: URL) throws {
        if fileExists(atPath: url.path) { try removeItem(at: url) }
    }
}
