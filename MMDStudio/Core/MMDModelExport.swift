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

    /// Exports the current frame as a triangulated OBJ+MTL with per-vertex
    /// skinning/morph applied, and copies the original PMX/PMD unchanged plus
    /// all texture files in their original formats. OBJ is a universal
    /// interchange target; it is not a PMX round-trip and does not carry MMD
    /// bones, IK, rigid bodies or morph sliders.
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

    /// Writes the current local bone pose as VPD. VPD is the standard MMD
    /// static-pose format; names are Shift-JIS with a UTF-8 fallback.
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

/// Deterministic offscreen video export. Unlike the live screen recorder this
/// drives the document frame-by-frame at a fixed rate, so the output duration
/// matches the VMD and every frame is an offscreen Metal render. Optional VMD
/// audio is muxed into the final MP4.
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

    /// Renders the current frame at the configured video size and writes a PNG
    /// that keeps the alpha channel when transparent output is enabled.
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
            // Never render frame 0 into a texture that still holds the last
            // export's final frame.
            renderer.resetCaptureTargets()
            // The display link redraws at 120 Hz; letting it run during an
            // export halves the GPU budget available to the encoder.
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
                // HEVC with alpha spends most of its bit budget on the colour
                // plane and starves the alpha plane, which is what leaves the
                // first frame's silhouette hanging over the following ones.
                // Give transparent exports extra bitrate, keep the GOP at one
                // second so the alpha plane is refreshed often, and turn off
                // frame reordering so frame 0 cannot be held as a reference.
                let bitrate = Int(targetMbps * (transparentBackground ? 1.8 : 1.0) * 1_000_000)
                let keyframeSeconds = transparentBackground
                    ? 1
                    : max(1, min(10, keyframeInterval))
                let settings: [String: Any]
                if transparentBackground {
                    // HEVC with alpha is the only Apple encoder that survives
                    // an alpha channel through a .mov container.
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
                    settings = [
                        AVVideoCodecKey: AVVideoCodecType.h264,
                        AVVideoWidthKey: width,
                        AVVideoHeightKey: height,
                        AVVideoCompressionPropertiesKey: [
                            AVVideoAverageBitRateKey: bitrate,
                            AVVideoProfileLevelKey: width * height > 1920 * 1080
                                ? AVVideoProfileLevelH264HighAutoLevel
                                : AVVideoProfileLevelH264HighAutoLevel,
                            AVVideoMaxKeyFrameIntervalKey: keyframeSeconds * fps,
                            AVVideoExpectedSourceFrameRateKey: fps,
                            AVVideoAllowFrameReorderingKey: true
                        ]
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

                // HEVC with alpha treats the first intra frame as the baseline
                // for the alpha plane. If that frame already holds the
                // character, every later frame composites over its silhouette
                // — the "first frame stuck under the whole video" ghost that
                // survived the readback and memset fixes. Leading with one
                // fully transparent frame leaves the baseline empty.
                let frameOffset = transparentBackground ? 1 : 0
                if transparentBackground,
                   let clear = Self.transparentPixelBuffer(width: width, height: height,
                                                           pool: adaptor.pixelBufferPool) {
                    _ = adaptor.append(clear, withPresentationTime: .zero)
                }

                var zeroCopyEnabled = true
                for frame in 0..<frameCount {
                    if self.cancelled { break }
                    let frameTime = Float(frame) / Float(max(1, fps)) * document.frameRate
                    var buffer: CVPixelBuffer?
                    var probeBytes: [UInt8]?
                    var probeRowBytes = 0

                    // Fast path: the GPU draws straight into a buffer owned by
                    // the encoder. At 4K the old path moved 66 MB per frame
                    // through the CPU and could not hold 60 fps.
                    if zeroCopyEnabled, let pool = adaptor.pixelBufferPool {
                        var pooled: CVPixelBuffer?
                        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pooled)
                        if let pooled, let texture = renderer.makeCaptureTexture(for: pooled),
                           renderer.captureFrame(into: texture, frame: frameTime,
                                                 transparentBackground: transparentBackground) {
                            if frame == 0 {
                                // Verify the IOSurface path actually produced
                                // pixels; an all-clear first frame means the
                                // texture binding silently failed and the whole
                                // video would come out empty.
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
                        // Only the fallback path keeps the rows on the CPU, so
                        // probes are written from there.
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
                    while !input.isReadyForMoreMediaData {
                        if self.cancelled { break }
                        Thread.sleep(forTimeInterval: 0.005)
                    }
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

    /// Copies the rendered BGRA rows straight into a CVPixelBuffer.
    ///
    /// The previous implementation rebuilt a CGContext, cleared it and drew the
    /// frame with `.copy`. That depended on Core Graphics compositing behaving
    /// predictably against a recycled pool buffer, and it did not: the first
    /// frame stayed underneath every later frame. A memcpy of the full buffer
    /// cannot composite at all — whatever the pool hands back is overwritten
    /// byte for byte, including any row padding.
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
        // Clear first so the alignment padding rows hold nothing from an
        // earlier export even if the pool sized this buffer differently.
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

    /// Writes one raw rendered frame to PNG so a transparent export can be
    /// diagnosed against the encoder output.
    /// A pool-backed, fully cleared pixel buffer. Used for the transparent
    /// lead-in frame and as a fallback when the pool is unavailable.
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

    /// Fraction of sampled pixels whose alpha is above a small threshold.
    /// Used once per export to confirm the zero-copy path drew something.
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

    /// Samples the alpha byte of the rendered BGRA rows. Used only for the
    /// first few frames of a transparent export so a regression shows up in the
    /// log instead of in the delivered file.
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
