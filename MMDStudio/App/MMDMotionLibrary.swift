import Combine
import Foundation

/// One imported VMD kept in the app's own motion library.
///
/// A motion and its camera are separate files in MMD and are used separately:
/// the dance drives bones, the camera drives the shot. Keeping them apart in
/// the library means the canvas can mix any motion with any camera instead of
/// re-importing a zip every time a model is opened.
struct MMDMotionAsset: Identifiable, Hashable, Codable {
    enum Kind: String, Codable {
        case motion
        case camera
    }

    /// Content hash. Importing the same file twice resolves to one entry.
    var id: String
    var title: String
    var fileName: String
    var kind: Kind
    var frameCount: Int
    var frameRate: Float
    var boneTrackCount: Int
    var morphTrackCount: Int
    var cameraKeyCount: Int
    /// Paths relative to the library root, so the folder can be moved.
    var relativePath: String
    var relativeAudioPath: String?
    /// Package or file the user picked, shown as provenance.
    var sourceName: String
    var importedAt: Date

    var durationSeconds: Double { Double(frameCount) / Double(max(1, frameRate)) }

    var durationText: String {
        let seconds = Int(durationSeconds.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    var summary: String {
        switch kind {
        case .motion:
            return "\(durationText) · 骨骼 \(boneTrackCount) · 表情 \(morphTrackCount)"
        case .camera:
            return "\(durationText) · 镜头 \(cameraKeyCount) 帧"
        }
    }
}

/// Persistent motion library: `Documents/MMDStudio/Motions/<hash>/<file>.vmd`.
/// Files are stored once per content hash, so re-importing a pack (or opening a
/// model that ships its own motion) never duplicates anything on disk.
final class MMDMotionLibrary: ObservableObject {
    static let shared = MMDMotionLibrary()

    @Published private(set) var assets: [MMDMotionAsset] = []
    @Published private(set) var isImporting = false

    let rootURL: URL
    private var indexURL: URL { rootURL.appendingPathComponent("index.json") }

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        rootURL = documents.appendingPathComponent("MMDStudio/Motions", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        load()
    }

    var motions: [MMDMotionAsset] { assets.filter { $0.kind == .motion } }
    var cameras: [MMDMotionAsset] { assets.filter { $0.kind == .camera } }

    func asset(withID id: String) -> MMDMotionAsset? { assets.first { $0.id == id } }

    func fileURL(for asset: MMDMotionAsset) -> URL {
        rootURL.appendingPathComponent(asset.relativePath)
    }

    func audioURL(for asset: MMDMotionAsset) -> URL? {
        guard let path = asset.relativeAudioPath else { return nil }
        let url = rootURL.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Import

    struct ImportReport {
        var addedMotions = 0
        var addedCameras = 0
        var skipped = 0
        var failed: [String] = []

        var isEmpty: Bool { addedMotions == 0 && addedCameras == 0 }
        var summary: String {
            var parts: [String] = []
            if addedMotions > 0 { parts.append("\(addedMotions) 个动作") }
            if addedCameras > 0 { parts.append("\(addedCameras) 个镜头") }
            if skipped > 0 { parts.append("跳过 \(skipped) 个重复") }
            if !failed.isEmpty { parts.append("\(failed.count) 个无法解析") }
            if parts.isEmpty {
                return failed.isEmpty ? "没有可导入的 VMD" : "\(failed.count) 个文件无法解析"
            }
            return parts.joined(separator: " · ")
        }
    }

    /// Import a zip, a loose .vmd, or a folder that already contains VMD files.
    /// Everything found is stored; camera-only files land in the camera area.
    @discardableResult
    func importSource(url: URL, sourceName: String? = nil) throws -> ImportReport {
        let fileManager = FileManager.default
        let label = sourceName ?? url.lastPathComponent
        var stage: URL?
        defer {
            if let stage { try? fileManager.removeItem(at: stage) }
        }

        let workingFolder: URL
        if url.pathExtension.lowercased() == "zip" {
            let temp = fileManager.temporaryDirectory
                .appendingPathComponent("MMDMotionStage/\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: temp, withIntermediateDirectories: true)
            _ = try MMDZipArchive.extract(url: url, to: temp)
            stage = temp
            workingFolder = temp
        } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            workingFolder = url
        } else {
            workingFolder = url.deletingLastPathComponent()
        }

        var vmdFiles: [URL] = []
        var audioFiles: [URL] = []
        if url.pathExtension.lowercased() == "zip" ||
            (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let enumerator = fileManager.enumerator(at: workingFolder, includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles])
            if let enumerator {
                for case let item as URL in enumerator {
                    switch item.pathExtension.lowercased() {
                    case "vmd": vmdFiles.append(item)
                    case "wav", "mp3", "m4a", "aac": audioFiles.append(item)
                    default: break
                    }
                }
            }
        } else if url.pathExtension.lowercased() == "vmd" {
            vmdFiles = [url]
            let siblings = (try? fileManager.contentsOfDirectory(at: workingFolder,
                                                                includingPropertiesForKeys: nil,
                                                                options: [.skipsHiddenFiles])) ?? []
            audioFiles = siblings.filter { ["wav", "mp3", "m4a", "aac"].contains($0.pathExtension.lowercased()) }
        }

        guard !vmdFiles.isEmpty else {
            throw MMDLoadError.invalidData("没有找到 VMD 文件")
        }

        var report = ImportReport()
        var known = Set(assets.map(\.id))
        for file in vmdFiles {
            guard let data = try? Data(contentsOf: file) else {
                report.failed.append(file.lastPathComponent)
                continue
            }
            let motion: VMDMotion
            do {
                motion = try VMDParser(data: data).parse()
            } catch {
                report.failed.append(file.lastPathComponent)
                MMDLog.shared.warning("Motion library: \(file.lastPathComponent) unreadable — \(error.localizedDescription)",
                                      category: "Motion")
                continue
            }
            let hash = Self.contentHash(data)
            if known.contains(hash) {
                report.skipped += 1
                continue
            }
            let kind: MMDMotionAsset.Kind =
                (motion.boneTracks.isEmpty && motion.morphTracks.isEmpty && !motion.cameraKeys.isEmpty) ? .camera : .motion
            let folder = rootURL.appendingPathComponent(hash, isDirectory: true)
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                let target = folder.appendingPathComponent(file.lastPathComponent)
                if !fileManager.fileExists(atPath: target.path) {
                    try fileManager.copyItem(at: file, to: target)
                }
                var audioRelative: String?
                if let audio = Self.matchingAudio(for: file, in: audioFiles),
                   let audioURL = storeAudio(audio) {
                    audioRelative = relativePath(of: audioURL)
                }
                let asset = MMDMotionAsset(id: hash,
                                           title: motion.name.isEmpty
                                               ? file.deletingPathExtension().lastPathComponent
                                               : motion.name,
                                           fileName: file.lastPathComponent,
                                           kind: kind,
                                           frameCount: motion.maxFrame,
                                           frameRate: motion.frameRate,
                                           boneTrackCount: motion.boneTracks.count,
                                           morphTrackCount: motion.morphTracks.count,
                                           cameraKeyCount: motion.cameraKeys.count,
                                           relativePath: "\(hash)/\(file.lastPathComponent)",
                                           relativeAudioPath: audioRelative,
                                           sourceName: label,
                                           importedAt: Date())
                assets.append(asset)
                known.insert(hash)
                if kind == .motion { report.addedMotions += 1 } else { report.addedCameras += 1 }
            } catch {
                report.failed.append(file.lastPathComponent)
                MMDLog.shared.warning("Motion library copy failed: \(error.localizedDescription)", category: "Motion")
            }
        }
        sort()
        save()
        MMDLog.shared.info("Motion library import \(label): \(report.summary)", category: "Motion")
        return report
    }

    /// Import a package folder when a model is opened, so its bundled dance is
    /// available from the canvas without importing the zip again.
    func importBundledMotions(in folder: URL, sourceName: String) {
        guard let enumerator = FileManager.default.enumerator(at: folder,
                                                              includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles]) else { return }
        var hasVMD = false
        for case let item as URL in enumerator where item.pathExtension.lowercased() == "vmd" {
            hasVMD = true
            break
        }
        guard hasVMD else { return }
        do {
            try importSource(url: folder, sourceName: sourceName)
        } catch {
            MMDLog.shared.warning("Bundled motion import failed: \(error.localizedDescription)", category: "Motion")
        }
    }

    /// One copy of a track, shared by every clip that references it. Four
    /// VMDs in one pack used to duplicate the same 3 MB wav four times.
    private func storeAudio(_ url: URL) -> URL? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let hash = Self.contentHash(data)
        let folder = rootURL.appendingPathComponent("_audio/\(hash)", isDirectory: true)
        let target = folder.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: target)
            return target
        } catch {
            MMDLog.shared.warning("Motion library audio copy failed: \(error.localizedDescription)", category: "Motion")
            return nil
        }
    }

    private func relativePath(of url: URL) -> String {
        let root = rootURL.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : url.lastPathComponent
    }

    private static func matchingAudio(for vmd: URL, in audioFiles: [URL]) -> URL? {
        let stem = vmd.deletingPathExtension().lastPathComponent.lowercased()
        if let match = audioFiles.first(where: {
            $0.deletingPathExtension().lastPathComponent.lowercased() == stem
        }) { return match }
        return audioFiles.count == 1 ? audioFiles.first : nil
    }

    private static func contentHash(_ data: Data) -> String {
        // FNV-1a over the file bytes: cheap, stable across launches, and good
        // enough to recognise the same VMD inside two different zips.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        data.withUnsafeBytes { buffer in
            for byte in buffer {
                hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
            }
        }
        return String(hash, radix: 16)
    }

    // MARK: - Delete

    func delete(_ asset: MMDMotionAsset) {
        let folder = rootURL.appendingPathComponent(asset.id, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        assets.removeAll { $0.id == asset.id }
        removeUnreferencedAudio()
        save()
        MMDLog.shared.info("Motion library removed \(asset.fileName)")
    }

    /// Audio is shared, so it can only go when the last clip referencing it
    /// is gone.
    private func removeUnreferencedAudio() {
        let referenced = Set(assets.compactMap { $0.relativeAudioPath })
        let folder = rootURL.appendingPathComponent("_audio", isDirectory: true)
        guard let hashFolders = try? FileManager.default.contentsOfDirectory(at: folder,
                                                                             includingPropertiesForKeys: nil,
                                                                             options: [.skipsHiddenFiles]) else { return }
        for hashFolder in hashFolders {
            let files = (try? FileManager.default.contentsOfDirectory(at: hashFolder,
                                                                     includingPropertiesForKeys: nil,
                                                                     options: [.skipsHiddenFiles])) ?? []
            if files.isEmpty { try? FileManager.default.removeItem(at: hashFolder) }
            for file in files where !referenced.contains(relativePath(of: file)) {
                try? FileManager.default.removeItem(at: file)
            }
            if let left = try? FileManager.default.contentsOfDirectory(at: hashFolder,
                                                                      includingPropertiesForKeys: nil,
                                                                      options: [.skipsHiddenFiles]),
               left.isEmpty {
                try? FileManager.default.removeItem(at: hashFolder)
            }
        }
    }

    /// Per-session copies made by the old per-document importer. The library
    /// keeps its own copy, so these can go when the canvas closes.
    func purgeSessionCache() {
        let fileManager = FileManager.default
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let imports = documents.appendingPathComponent("MMDStudio/GeneratedMotions/Imports", isDirectory: true)
        guard fileManager.fileExists(atPath: imports.path) else { return }
        let contents = (try? fileManager.contentsOfDirectory(at: imports, includingPropertiesForKeys: nil)) ?? []
        for item in contents { try? fileManager.removeItem(at: item) }
        if !contents.isEmpty {
            MMDLog.shared.info("Session motion cache cleared: \(contents.count) folder(s)", category: "Motion")
        }
    }

    // MARK: - Persistence

    private func sort() {
        assets.sort { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind == .motion }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([MMDMotionAsset].self, from: data) else { return }
        assets = decoded.filter { FileManager.default.fileExists(atPath: fileURL(for: $0).path) }
        sort()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(assets) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}
