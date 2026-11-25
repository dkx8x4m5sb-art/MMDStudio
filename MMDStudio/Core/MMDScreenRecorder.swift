import AVFoundation
import Foundation
import Photos
import UIKit

/// Records the Metal viewport through the renderer itself. Unlike ReplayKit,
/// this does not include SwiftUI toolbars or device status bars, and it keeps
/// the full render resolution instead of the system screen-recording size.
final class MMDScreenRecorder: ObservableObject {

    static let shared = MMDScreenRecorder()

    @Published private(set) var isRecording = false
    @Published private(set) var lastError: String?

    private let queue = DispatchQueue(label: "com.mmdstudio.engine-recorder")
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var outputURL: URL?
    private var frameIndex: Int64 = 0
    private var width = 0
    private var height = 0
    private var startedSession = false

    private init() {}

    func toggle() {
        if isRecording { stop() } else { start() }
    }

    func start() {
        guard !isRecording else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.resetWriter()
            self.frameIndex = 0
            self.startedSession = false
            self.outputURL = Self.makeOutputURL()
            DispatchQueue.main.async {
                self.isRecording = true
                self.lastError = nil
                NotificationCenter.default.post(name: .mmdStartEngineCapture, object: nil)
                MMDLog.shared.info("Engine recording started")
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        NotificationCenter.default.post(name: .mmdStopEngineCapture, object: nil)
        queue.async { [weak self] in
            self?.finishWriting()
        }
    }

    /// Called from the renderer after a frame has been copied into a shared
    /// Metal buffer. The queue serializes AVAssetWriter work off the GPU thread.
    func append(frame data: Data, width: Int, height: Int, bytesPerRow: Int) {
        queue.async { [weak self] in
            guard let self, self.isRecording || self.writer != nil else { return }
            let targetWidth = width - (width % 2)
            let targetHeight = height - (height % 2)
            guard targetWidth > 1, targetHeight > 1, bytesPerRow >= width * 4 else { return }
            if self.writer == nil {
                guard self.prepareWriter(width: targetWidth, height: targetHeight) else { return }
            }
            guard let input = self.input,
                  let adaptor = self.adaptor,
                  input.isReadyForMoreMediaData,
                  let pool = adaptor.pixelBufferPool else { return }
            var pixelBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
                  let pixelBuffer else { return }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let destinationRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
                data.withUnsafeBytes { raw in
                    guard let source = raw.baseAddress else { return }
                    for row in 0..<targetHeight {
                        let src = source.advanced(by: row * bytesPerRow)
                        let dst = base.advanced(by: row * destinationRow)
                        memcpy(dst, src, targetWidth * 4)
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            let time = CMTime(value: self.frameIndex, timescale: 30)
            if adaptor.append(pixelBuffer, withPresentationTime: time) {
                self.frameIndex += 1
            }
        }
    }

    private func prepareWriter(width: Int, height: Int) -> Bool {
        guard let outputURL else { return false }
        do {
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: outputURL)
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
            let bitrate = max(4_000_000, min(24_000_000, width * height * 5))
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoMaxKeyFrameIntervalKey: 60
                ]
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                ]
            )
            guard writer.canAdd(input) else { return false }
            writer.add(input)
            guard writer.startWriting() else { return false }
            writer.startSession(atSourceTime: .zero)
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            self.width = width
            self.height = height
            self.startedSession = true
            MMDLog.shared.info("Engine recorder ready: \(width)x\(height)")
            return true
        } catch {
            DispatchQueue.main.async {
                self.lastError = error.localizedDescription
                self.isRecording = false
                NotificationCenter.default.post(name: .mmdStopEngineCapture, object: nil)
            }
            MMDLog.shared.error("Engine recorder setup failed: \(error.localizedDescription)")
            return false
        }
    }

    private func finishWriting() {
        guard let writer, startedSession else {
            resetWriter()
            return
        }
        input?.markAsFinished()
        let url = outputURL
        writer.finishWriting { [weak self] in
            guard let self else { return }
            let success = writer.status == .completed
            if !success {
                MMDLog.shared.error("Engine recorder finish failed: \(writer.error?.localizedDescription ?? "unknown")")
                DispatchQueue.main.async {
                    self.lastError = writer.error?.localizedDescription ?? "视频写入失败"
                    NotificationCenter.default.post(name: .mmdRecordingSaved, object: false)
                }
            } else if let url {
                self.saveToPhotos(url: url)
            }
            self.resetWriter()
        }
    }

    private func saveToPhotos(url: URL) {
        MMDLog.shared.info("Engine recording finished: \(url.lastPathComponent)")
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                MMDLog.shared.error("Recording save denied, status=\(status.rawValue)")
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .mmdRecordingSaved, object: false)
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { success, error in
                if let error {
                    MMDLog.shared.error("Recording save failed: \(error.localizedDescription)")
                } else {
                    MMDLog.shared.info("Engine recording saved to Photos")
                }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .mmdRecordingSaved, object: success)
                }
            }
        }
    }

    private func resetWriter() {
        writer = nil
        input = nil
        adaptor = nil
        outputURL = nil
        startedSession = false
        width = 0
        height = 0
    }

    private static func makeOutputURL() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = documents.appendingPathComponent("MMDStudio/Recordings", isDirectory: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return directory.appendingPathComponent("MMDStudio-\(formatter.string(from: Date())).mov")
    }
}

extension Notification.Name {
    static let mmdStartEngineCapture = Notification.Name("MMDStartEngineCapture")
    static let mmdStopEngineCapture = Notification.Name("MMDStopEngineCapture")
    static let mmdRecordingSaved = Notification.Name("MMDRecordingSaved")
}
