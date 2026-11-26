import Combine
import Foundation

// MARK: - Snapshot types

struct MMDStorageFile: Identifiable, Hashable {
    let url: URL
    /// Path relative to the scanned folder, so the list stays readable even
    /// when an exported package has deeply nested texture directories.
    let name: String
    let byteCount: Int64
    let modifiedAt: Date?

    var id: String { url.path }
}

enum MMDStorageGroup: String, CaseIterable, Identifiable {
    case cache = "缓存与临时文件"
    case media = "导出与录制"
    case assets = "素材与动作"

    var id: String { rawValue }
}

struct MMDStorageBucket: Identifiable, Hashable {
    let id: String
    let title: String
    let note: String
    let systemImage: String
    let group: MMDStorageGroup
    /// Cached / disposable data. Only these buckets are wiped by "清理缓存".
    let isCache: Bool
    let roots: [URL]
    var files: [MMDStorageFile]

    var byteCount: Int64 { files.reduce(0) { $0 + $1.byteCount } }
}

/// One imported package folder inside `Documents/MMDModels`. The library is
/// never bulk-cleared: packages are deleted one at a time because each one is
/// a self-contained PMX + texture + motion set.
struct MMDStoragePackage: Identifiable, Hashable {
    let url: URL
    let name: String
    let modelCount: Int
    let fileCount: Int
    let byteCount: Int64

    var id: String { url.path }
}

struct MMDStorageSnapshot {
    let buckets: [MMDStorageBucket]
    let packages: [MMDStoragePackage]
    let freeBytes: Int64
    let capacityBytes: Int64
    let scannedAt: Date
}

// MARK: - Scanner

/// Read-only inventory of everything the app writes to disk. All of it lives
/// under Documents (visible in the Files app) or the app's own Caches/tmp, so
/// sizes are computed from allocated bytes rather than logical file length.
enum MMDStorageScanner {

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    static var libraryDirectory: URL {
        documentsDirectory.appendingPathComponent("MMDModels", isDirectory: true)
    }

    static var studioDirectory: URL {
        documentsDirectory.appendingPathComponent("MMDStudio", isDirectory: true)
    }

    static var temporaryDirectory: URL {
        FileManager.default.temporaryDirectory
    }

    static var cachesDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? temporaryDirectory.appendingPathComponent("Caches", isDirectory: true)
    }

    private static func studio(_ path: String) -> URL {
        studioDirectory.appendingPathComponent(path, isDirectory: true)
    }

    private struct Definition {
        let id: String
        let title: String
        let note: String
        let icon: String
        let group: MMDStorageGroup
        let isCache: Bool
        let roots: [URL]
    }

    private static func definitions() -> [Definition] {
        [
            Definition(id: "temp",
                       title: "临时文件",
                       note: "解压、分享与导出过程中的中间文件",
                       icon: "hourglass",
                       group: .cache, isCache: true,
                       roots: [temporaryDirectory]),
            Definition(id: "caches",
                       title: "系统缓存",
                       note: "图像解码与网络请求的磁盘缓存",
                       icon: "memorychip",
                       group: .cache, isCache: true,
                       roots: [cachesDirectory]),
            Definition(id: "logs",
                       title: "运行日志",
                       note: "排查问题时生成的滚动日志",
                       icon: "doc.text.magnifyingglass",
                       group: .cache, isCache: true,
                       roots: [studio("Logs")]),
            Definition(id: "videos",
                       title: "导出视频",
                       note: "MP4 / MOV · 离屏渲染结果",
                       icon: "film",
                       group: .media, isCache: false,
                       roots: [studio("Exports/Videos")]),
            Definition(id: "frames",
                       title: "单帧 PNG",
                       note: "导出工作室渲染的静帧",
                       icon: "photo.on.rectangle",
                       group: .media, isCache: false,
                       roots: [studio("Exports/Frames")]),
            Definition(id: "obj",
                       title: "模型导出",
                       note: "OBJ / MTL 与原始 PMX 副本",
                       icon: "shippingbox",
                       group: .media, isCache: false,
                       roots: [studio("Exports/Models")]),
            Definition(id: "textures",
                       title: "贴图导出",
                       note: "按原始格式复制的贴图目录",
                       icon: "photo.stack",
                       group: .media, isCache: false,
                       roots: [studio("Exports/Textures")]),
            Definition(id: "recordings",
                       title: "引擎录屏",
                       note: "渲染器直录的 MOV",
                       icon: "record.circle",
                       group: .media, isCache: false,
                       roots: [studio("Recordings")]),
            Definition(id: "backgrounds",
                       title: "自定义背景",
                       note: "导入的背景图片",
                       icon: "photo",
                       group: .assets, isCache: false,
                       roots: [studio("Backgrounds")]),
            Definition(id: "attachments",
                       title: "导入的配饰",
                       note: "单独导入的 PMX 配饰与武器",
                       icon: "paperclip",
                       group: .assets, isCache: false,
                       roots: [studio("Attachments")]),
            Definition(id: "motions",
                       title: "导入的动作",
                       note: "VMD 与音频副本",
                       icon: "figure.walk",
                       group: .assets, isCache: false,
                       roots: [studio("GeneratedMotions")])
        ]
    }

    // MARK: Scan

    static func scan() -> MMDStorageSnapshot {
        var buckets: [MMDStorageBucket] = []
        for definition in definitions() {
            let bucketFiles = self.files(in: definition.roots)
            buckets.append(MMDStorageBucket(id: definition.id,
                                            title: definition.title,
                                            note: definition.note,
                                            systemImage: definition.icon,
                                            group: definition.group,
                                            isCache: definition.isCache,
                                            roots: definition.roots,
                                            files: bucketFiles))
        }
        let space = volumeSpace()
        return MMDStorageSnapshot(buckets: buckets,
                                  packages: scanPackages(),
                                  freeBytes: space.free,
                                  capacityBytes: space.capacity,
                                  scannedAt: Date())
    }

    /// Every regular file under the given roots, newest first.
    static func files(in roots: [URL]) -> [MMDStorageFile] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey,
                                         .totalFileAllocatedSizeKey,
                                         .fileSizeKey,
                                         .contentModificationDateKey]
        var result: [MMDStorageFile] = []
        var seen = Set<String>()
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root,
                                                                  includingPropertiesForKeys: Array(keys),
                                                                  options: [.skipsHiddenFiles],
                                                                  errorHandler: { _, _ in true }) else { continue }
            let rootPath = root.standardizedFileURL.path
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true else { continue }
                let path = url.standardizedFileURL.path
                guard seen.insert(path).inserted else { continue }
                var name = url.lastPathComponent
                if path.hasPrefix(prefix) { name = String(path.dropFirst(prefix.count)) }
                result.append(MMDStorageFile(url: url,
                                             name: name,
                                             byteCount: Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0),
                                             modifiedAt: values.contentModificationDate))
            }
        }
        return result.sorted { lhs, rhs in
            let left = lhs.modifiedAt ?? .distantPast
            let right = rhs.modifiedAt ?? .distantPast
            if left == right { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            return left > right
        }
    }

    private static func scanPackages() -> [MMDStoragePackage] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(at: libraryDirectory,
                                                                          includingPropertiesForKeys: Array(keys),
                                                                          options: [.skipsHiddenFiles]) else {
            return []
        }
        var result: [MMDStoragePackage] = []
        for url in contents {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                result.append(MMDStoragePackage(url: url,
                                                name: url.lastPathComponent,
                                                modelCount: countModels(in: url),
                                                fileCount: countFiles(in: url),
                                                byteCount: size(of: url)))
            } else if ["pmx", "pmd"].contains(url.pathExtension.lowercased()) {
                let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                result.append(MMDStoragePackage(url: url,
                                                name: url.deletingPathExtension().lastPathComponent,
                                                modelCount: 1,
                                                fileCount: 1,
                                                byteCount: Int64(fileSize)))
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func countModels(in folder: URL) -> Int {
        var count = 0
        guard let enumerator = FileManager.default.enumerator(at: folder,
                                                              includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles]) else { return 0 }
        for case let url as URL in enumerator where ["pmx", "pmd"].contains(url.pathExtension.lowercased()) {
            count += 1
        }
        return count
    }

    private static func countFiles(in folder: URL) -> Int {
        var count = 0
        guard let enumerator = FileManager.default.enumerator(at: folder,
                                                              includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles]) else { return 0 }
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { count += 1 }
        }
        return count
    }

    /// Allocated size of a file or a whole folder tree.
    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(at: url,
                                                              includingPropertiesForKeys: Array(keys),
                                                              options: [.skipsHiddenFiles],
                                                              errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    private static func volumeSpace() -> (free: Int64, capacity: Int64) {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey,
                                         .volumeTotalCapacityKey]
        let values = try? documentsDirectory.resourceValues(forKeys: keys)
        let free = Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
        let capacity = Int64(values?.volumeTotalCapacity ?? 0)
        return (free, capacity)
    }

    // MARK: Cleanup

    /// Temporary data only: tmp, Caches, rolling logs and orphaned `-temp`
    /// export files. Library, exports, recordings and the photo library are
    /// untouched.
    static func clearCaches() -> Int64 {
        var freed: Int64 = 0
        let logDirectory = studio("Logs")
        freed += size(of: logDirectory)
        logDirectoryPurge()
        for directory in [temporaryDirectory, cachesDirectory] {
            freed += removeContents(of: directory)
        }
        freed += removeLeftoverExports()
        return freed
    }

    /// Log first, then wipe: the record is useful if anything below throws, and
    /// clearing last leaves an empty log directory instead of a hundred-byte
    /// file that makes the cache number look non-zero right after a purge.
    private static func logDirectoryPurge() {
        MMDLog.shared.info("Storage cache purge requested")
        MMDLog.shared.clear()
    }

    @discardableResult
    static func removeContents(of directory: URL) -> Int64 {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                          includingPropertiesForKeys: nil,
                                                                          options: [.skipsHiddenFiles]) else {
            return 0
        }
        var freed: Int64 = 0
        for item in contents {
            freed += size(of: item)
            try? FileManager.default.removeItem(at: item)
        }
        return freed
    }

    /// A cancelled or crashed video export can leave `<name>-temp.mp4` behind;
    /// those are never meant to be kept.
    private static func removeLeftoverExports() -> Int64 {
        let directory = studio("Exports/Videos")
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                          includingPropertiesForKeys: [.fileSizeKey, .totalFileAllocatedSizeKey],
                                                                          options: [.skipsHiddenFiles]) else {
            return 0
        }
        var freed: Int64 = 0
        for url in contents {
            let name = url.lastPathComponent.lowercased()
            guard name.contains("-temp.") || name.hasSuffix(".tmp") else { continue }
            freed += size(of: url)
            try? FileManager.default.removeItem(at: url)
        }
        return freed
    }

    /// Deletion guard: only files below the roots the app owns.
    static func isManaged(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let roots = [libraryDirectory, studioDirectory, temporaryDirectory, cachesDirectory]
        return roots.contains { root in
            let rootPath = root.standardizedFileURL.path
            return path == rootPath || path.hasPrefix(rootPath + "/")
        }
    }
}

// MARK: - Monitor

/// Owns the scanned snapshot so both the overview and the per-folder lists
/// read one consistent inventory. Scanning runs off the main thread: a library
/// with a few thousand texture files would otherwise hitch the list.
final class MMDStorageMonitor: ObservableObject {

    @Published private(set) var buckets: [MMDStorageBucket] = []
    @Published private(set) var packages: [MMDStoragePackage] = []
    @Published private(set) var freeBytes: Int64 = 0
    @Published private(set) var capacityBytes: Int64 = 0
    @Published private(set) var isScanning = false
    @Published private(set) var isWorking = false
    @Published private(set) var scannedAt: Date?

    var modelBytes: Int64 { packages.reduce(0) { $0 + $1.byteCount } }
    var mediaBytes: Int64 {
        buckets.filter { $0.group == .media }.reduce(0) { $0 + $1.byteCount }
    }
    var assetBytes: Int64 {
        buckets.filter { $0.group == .assets }.reduce(0) { $0 + $1.byteCount }
    }
    var cacheBytes: Int64 {
        buckets.filter(\.isCache).reduce(0) { $0 + $1.byteCount }
    }
    /// Everything the app itself accounts for. Model library included, so the
    /// big number matches what the user has to free to uninstall cleanly.
    var appBytes: Int64 { modelBytes + mediaBytes + assetBytes + cacheBytes }

    func reload() async {
        isScanning = true
        let snapshot = await Task.detached(priority: .userInitiated) {
            MMDStorageScanner.scan()
        }.value
        // A non-isolated async function resumes on the concurrent executor,
        // not on the main thread. @Published must be touched on main or
        // SwiftUI will trap on the next layout pass.
        await MainActor.run {
            self.buckets = snapshot.buckets
            self.packages = snapshot.packages
            self.freeBytes = snapshot.freeBytes
            self.capacityBytes = snapshot.capacityBytes
            self.scannedAt = snapshot.scannedAt
            self.isScanning = false
        }
    }

    @discardableResult
    func clearCache() async -> Int64 {
        guard !isWorking else { return 0 }
        isWorking = true
        let freed = await Task.detached(priority: .userInitiated) {
            MMDStorageScanner.clearCaches()
        }.value
        URLCache.shared.removeAllCachedResponses()
        await reload()
        await MainActor.run { self.isWorking = false }
        return freed
    }

    func delete(files: [MMDStorageFile]) throws {
        for file in files where MMDStorageScanner.isManaged(file.url) {
            try FileManager.default.removeItem(at: file.url)
        }
    }
}
