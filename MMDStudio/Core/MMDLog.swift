//
//  MMDLog.swift
//  MMD Studio
//
//  运行日志：内存环形缓冲 + 文件落盘。
//

import Foundation
import os.log

/// Lightweight, persistent in-app logger. Importing a model can fail for very
/// different reasons on device, so the app keeps a rotating text log that the
/// user can inspect or share directly from the UI.
final class MMDLog {

    static let shared = MMDLog()

    private let queue = DispatchQueue(label: "com.mmdstudio.log")
    private let fileManager = FileManager.default
    private let directoryURL: URL
    private let currentURL: URL
    private let previousURL: URL
    private let osLogger = Logger(subsystem: "com.mmdstudio.app", category: "MMDStudio")
    private let maxBytes: Int = 2 * 1024 * 1024
    private let formatter: DateFormatter

    private init() {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directoryURL = documents.appendingPathComponent("MMDStudio/Logs", isDirectory: true)
        currentURL = directoryURL.appendingPathComponent("MMDStudio.log")
        previousURL = directoryURL.appendingPathComponent("MMDStudio.previous.log")
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    }

    func info(_ message: String, category: String = "General",
              file: String = #fileID, line: Int = #line) {
        write("INFO", message, category: category, file: file, line: line)
    }

    func warning(_ message: String, category: String = "General",
                 file: String = #fileID, line: Int = #line) {
        write("WARN", message, category: category, file: file, line: line)
    }

    func error(_ message: String, category: String = "General",
               file: String = #fileID, line: Int = #line) {
        write("ERROR", message, category: category, file: file, line: line)
    }

    private func write(_ level: String, _ message: String, category: String,
                       file: String, line: Int) {
        let source = URL(fileURLWithPath: file).lastPathComponent
        let stamp = formatter.string(from: Date())
        let lineText = "[\(stamp)] [\(level)] [\(category)] [\(source):\(line)] \(message)\n"
        osLogger.info("\(lineText, privacy: .public)")
        queue.async { [weak self] in
            guard let self else { return }
            self.rotateIfNeeded()
            guard let data = lineText.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: self.currentURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: self.currentURL, options: .atomic)
            }
        }
    }

    private func rotateIfNeeded() {
        guard let attributes = try? fileManager.attributesOfItem(atPath: currentURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > maxBytes else { return }
        try? fileManager.removeItem(at: previousURL)
        try? fileManager.moveItem(at: currentURL, to: previousURL)
    }

    func readRecent(limit: Int = 240_000) -> String {
        queue.sync {
            var text = ""
            if let data = try? Data(contentsOf: previousURL), !data.isEmpty {
                text += "[previous log]\n" + (String(data: data, encoding: .utf8) ?? "") + "\n"
            }
            if let data = try? Data(contentsOf: currentURL), !data.isEmpty {
                let tail = data.count > limit ? data.suffix(limit) : data
                text += String(data: Data(tail), encoding: .utf8) ?? ""
            }
            return text.isEmpty ? "还没有日志。" : text
        }
    }

    func exportURL() -> URL? {
        queue.sync {
            var combined = Data()
            if let data = try? Data(contentsOf: previousURL), !data.isEmpty {
                combined.append("[previous log]\n".data(using: .utf8) ?? Data())
                combined.append(data)
                if data.last != 0x0A { combined.append(0x0A) }
            }
            if let data = try? Data(contentsOf: currentURL), !data.isEmpty {
                combined.append(data)
            }
            guard !combined.isEmpty else { return nil }
            let stamp = formatter.string(from: Date())
                .replacingOccurrences(of: " ", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            let export = fileManager.temporaryDirectory
                .appendingPathComponent("MMDStudio-Log-\(stamp).txt")
            try? fileManager.removeItem(at: export)
            do {
                try combined.write(to: export, options: .atomic)
                return export
            } catch {
                return nil
            }
        }
    }

    /// Bytes currently occupied by the active and previous log files.
    func storedBytes() -> Int {
        queue.sync {
            var total = 0
            for url in [currentURL, previousURL] {
                if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                   let size = attributes[.size] as? NSNumber {
                    total += size.intValue
                }
            }
            return total
        }
    }

    func clear() {
        queue.async { [weak self] in
            guard let self else { return }
            try? self.fileManager.removeItem(at: self.currentURL)
            try? self.fileManager.removeItem(at: self.previousURL)
        }
    }
}
