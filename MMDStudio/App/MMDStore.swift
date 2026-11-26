import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum MMDModelRole: String, Codable {
    case character = "角色"
    case accessory = "配饰"
}

struct MMDModelGroup: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
}

private struct MMDLibraryMetadata: Codable {
    var groups: [MMDModelGroup] = []
    /// Key: top-level imported package folder. Logical grouping leaves the
    /// archive's internal texture paths untouched.
    var packageGroups: [String: UUID] = [:]
}

struct MMDModelEntry: Identifiable, Hashable {
    /// Stable identity: the PMX path relative to the model library.
    let id: String
    /// Recomputed when a package is classified: props are renamed to
    /// `角色-道具` so they read as children of their character.
    var displayName: String
    let pmxPath: String
    /// Top-level imported folder. Several PMX models may share this folder.
    let packageURL: URL
    /// Directory containing the PMX; texture relative paths start here.
    let assetDirectory: URL
    let relativePath: String
    var role: MMDModelRole = .character
    var groupID: UUID?
    /// Character this model belongs to. Props imported in the same archive get
    /// folded under their character so the library reads like folders instead
    /// of one flat pile of PMX files.
    var ownerName: String?

    var folderName: String { packageURL.lastPathComponent }
}

struct MMDImportResult {
    let entries: [MMDModelEntry]
    let warnings: [String]
}

final class MMDStore: ObservableObject {

    @Published var entries: [MMDModelEntry] = []
    @Published var groups: [MMDModelGroup] = []
    @Published var errorMessage: String?

    /// Import only the primary PMX from a multi-model archive. The other
    /// models stay on disk and can be added from the scene editor.
    @Published var importAllModels: Bool {
        didSet { UserDefaults.standard.set(importAllModels, forKey: Self.importAllModelsKey) }
    }
    /// Automatically attach weapons/props when a character is opened.
    @Published var autoAttachPackageModels: Bool {
        didSet { UserDefaults.standard.set(autoAttachPackageModels, forKey: Self.autoAttachKey) }
    }
    private static let importAllModelsKey = "MMDStudio.importAllModels"
    private static let autoAttachKey = "MMDStudio.autoAttachPackageModels"

    let libraryURL: URL
    private var packageGroups: [String: UUID] = [:]
    private var metadataURL: URL { libraryURL.appendingPathComponent(".mmd-library.json") }

    init() {
        importAllModels = UserDefaults.standard.bool(forKey: Self.importAllModelsKey)
        autoAttachPackageModels = UserDefaults.standard.bool(forKey: Self.autoAttachKey)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        libraryURL = documents.appendingPathComponent("MMDModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        MMDLog.shared.info("MMDStore init, library=\(libraryURL.path)")
        removeLegacySampleIfNeeded()
        loadMetadata()
        refresh()
    }

    private func loadMetadata() {
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(MMDLibraryMetadata.self, from: data) else { return }
        groups = metadata.groups
        packageGroups = metadata.packageGroups
    }

    private func saveMetadata() {
        let metadata = MMDLibraryMetadata(groups: groups, packageGroups: packageGroups)
        if let data = try? JSONEncoder().encode(metadata) {
            try? data.write(to: metadataURL, options: .atomic)
        }
    }

    // MARK: - Library

    func refresh() {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: libraryURL,
                                                      includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) else {
            entries = []
            return
        }
        var result: [MMDModelEntry] = []
        let rootPath = libraryURL.standardizedFileURL.path
        for case let url as URL in enumerator {
            guard ["pmx", "pmd"].contains(url.pathExtension.lowercased()) else { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relative = String(path.dropFirst(rootPath.count + 1))
            var components = relative.split(separator: "/").map(String.init)
            guard let fileName = components.popLast(), !fileName.isEmpty else { continue }
            let packageName = components.first ?? url.deletingLastPathComponent().lastPathComponent
            let packageURL = libraryURL.appendingPathComponent(packageName, isDirectory: true)
            let display = Self.friendlyDisplayName(pmx: url, packageName: packageName)
            result.append(MMDModelEntry(id: relative,
                                        displayName: display,
                                        pmxPath: url.path,
                                        packageURL: packageURL,
                                        assetDirectory: url.deletingLastPathComponent(),
                                        relativePath: relative,
                                        role: Self.isAccessoryPath(relative) ? .accessory : .character,
                                        groupID: packageGroups[packageName]))
        }
        result = Self.classifyPackages(result)
        result.sort { lhs, rhs in
            let left = lhs.ownerName ?? lhs.displayName
            let right = rhs.ownerName ?? rhs.displayName
            if left != right { return left.localizedStandardCompare(right) == .orderedAscending }
            // The character row goes above its own props.
            if lhs.role != rhs.role { return lhs.role == .character }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
        entries = result
        MMDLog.shared.info("Library refreshed: \(result.count) model(s)")
    }

    @discardableResult
    func createGroup(name: String) -> MMDModelGroup {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = MMDModelGroup(name: trimmed.isEmpty ? "新建模型文件夹" : trimmed)
        groups.append(group)
        saveMetadata()
        return group
    }

    func renameGroup(_ group: MMDModelGroup, to name: String) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        groups[index].name = trimmed
        saveMetadata()
    }

    func deleteGroup(_ group: MMDModelGroup) {
        groups.removeAll { $0.id == group.id }
        packageGroups = packageGroups.filter { $0.value != group.id }
        saveMetadata()
        refresh()
    }

    func assign(entries selected: [MMDModelEntry], to groupID: UUID?) {
        for entry in selected {
            packageGroups[entry.packageURL.lastPathComponent] = groupID
        }
        saveMetadata()
        refresh()
    }

    func groupName(for entry: MMDModelEntry) -> String {
        groups.first { $0.id == entry.groupID }?.name ?? "未分组"
    }

    func rename(_ entry: MMDModelEntry, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let ext = URL(fileURLWithPath: entry.pmxPath).pathExtension
        let destination = entry.assetDirectory.appendingPathComponent(trimmed).appendingPathExtension(ext)
        if destination.path != entry.pmxPath {
            try FileManager.default.moveItem(at: URL(fileURLWithPath: entry.pmxPath), to: destination)
        }
        refresh()
    }

    /// Files are shown relative to the imported package so users can inspect
    /// exactly which textures/PMX files belong together before deleting them.
    func packageFiles(for entry: MMDModelEntry) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: entry.packageURL,
                                                              includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles]) else { return [] }
        var result = [URL]()
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { result.append(url) }
        }
        return result.sorted { $0.path < $1.path }
    }

    func deleteFiles(_ files: [URL], in entry: MMDModelEntry) throws {
        let root = entry.packageURL.standardizedFileURL.path + "/"
        for file in files {
            guard file.standardizedFileURL.path.hasPrefix(root) else { continue }
            try FileManager.default.removeItem(at: file)
        }
        refresh()
    }

    func importFiles(_ files: [URL], into entry: MMDModelEntry) throws {
        let destination = entry.packageURL.appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for file in files {
            if file.pathExtension.lowercased() == "zip" {
                _ = try MMDZipArchive.extract(url: file, to: destination)
            } else {
                try FileManager.default.copyItem(at: file, to: destination.appendingPathComponent(file.lastPathComponent))
            }
        }
        refresh()
    }

    func delete(entries selected: [MMDModelEntry]) {
        let allByPackage = Dictionary(grouping: entries, by: { $0.packageURL.path })
        let selectedByPackage = Dictionary(grouping: selected, by: { $0.packageURL.path })
        for (package, selectedInPackage) in selectedByPackage {
            guard let first = selectedInPackage.first else { continue }
            let selectedIDs = Set(selectedInPackage.map(\.id))
            let allIDs = Set(allByPackage[package]?.map(\.id) ?? [])
            if selectedIDs == allIDs {
                try? FileManager.default.removeItem(at: first.packageURL)
            } else {
                for item in selectedInPackage {
                    try? FileManager.default.removeItem(at: URL(fileURLWithPath: item.pmxPath))
                }
            }
        }
        refresh()
    }

    /// Remove a whole imported package, used by the storage manager where the
    /// unit of deletion is the package folder rather than a PMX entry list.
    /// The folder's group assignment is dropped too, otherwise a later import
    /// that reuses the name would silently land in the old group.
    func deletePackage(at url: URL) {
        let root = libraryURL.standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(root) else { return }
        try? FileManager.default.removeItem(at: url)
        packageGroups.removeValue(forKey: url.lastPathComponent)
        saveMetadata()
        MMDLog.shared.info("Deleted package: \(url.lastPathComponent)")
        refresh()
    }

    func open(_ entry: MMDModelEntry) throws -> MMDModelDocument {
        MMDLog.shared.info("Open model: \(entry.relativePath), assetDir=\(entry.assetDirectory.path)")
        let pmxURL = URL(fileURLWithPath: entry.pmxPath)
        let data = try Data(contentsOf: pmxURL)
        let model = try Self.parseModel(data: data, url: pmxURL)
        MMDLog.shared.info("Model parsed (\(pmxURL.pathExtension.uppercased())): vertices=\(model.vertices.count), materials=\(model.materials.count), bones=\(model.bones.count), morphs=\(model.morphs.count), textures=\(model.textures.count)")
        // Textures normally live beside the PMX, but multi-model packages often
        // keep a shared texture folder at the archive root. Both roots are
        // searched, with the PMX directory taking priority.
        let document = MMDModelDocument(model: model,
                                        baseDirectory: entry.assetDirectory,
                                        fallbackRoot: entry.packageURL == entry.assetDirectory ? nil : entry.packageURL,
                                        displayName: model.displayName,
                                        sourceURL: pmxURL)
        if entry.role == .character && autoAttachPackageModels {
            var imported = 0
            for candidate in findAllPMX(in: entry.packageURL) where candidate.path != pmxURL.path {
                // Three accessories is enough for a normal package, and each one
                // is a full PMX parse plus its own vertex/bone arrays. Eight of
                // them on a heavy character tipped the load over the memory
                // budget before a single frame was drawn.
                guard imported < 3, Self.shouldAutoAttach(candidate, relativeTo: model) else { continue }
                let size = (try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size < 12 * 1024 * 1024 else {
                    MMDLog.shared.info("Skipped oversized accessory: \(candidate.lastPathComponent) (\(size / 1024 / 1024) MB)", category: "Scene")
                    continue
                }
                do {
                    let id = try document.addAttachment(url: candidate, autoBind: true)
                    document.updateAttachment(id: id) { $0.fallbackRoot = entry.packageURL }
                    imported += 1
                } catch {
                    MMDLog.shared.warning("Auto accessory failed: \(candidate.lastPathComponent): \(error.localizedDescription)", category: "Scene")
                }
            }
            if imported > 0 {
                MMDLog.shared.info("Package auto-assigned \(imported) accessory model(s)", category: "Scene")
                document.sceneEditEnabled = false
            }
        }
        // A package that ships a dance gets it imported into the shared
        // library once (deduplicated by content) and then loads the cut whose
        // bones actually match this model. Nothing is copied per session.
        let motionLibrary = MMDMotionLibrary.shared
        motionLibrary.importBundledMotions(in: entry.packageURL, sourceName: entry.folderName)
        let bundled = motionLibrary.motions.filter { $0.sourceName == entry.folderName }
        if let best = document.rankLibraryMotions(bundled, library: motionLibrary).first,
           best.mapped > 0 {
            do {
                try document.loadMotion(asset: best.asset, from: motionLibrary)
                MMDLog.shared.info("Auto-loaded library motion: \(best.asset.fileName), mapped \(best.mapped) bones")
            } catch {
                MMDLog.shared.warning("Auto motion load failed: \(error.localizedDescription)")
            }
        }
        return document
    }

    func delete(_ entry: MMDModelEntry) {
        delete(entries: [entry])
    }

    // MARK: - Import

    private static func primaryModel(in files: [URL]) -> URL {
        files.max { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let right = (try? rhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if left == right { return lhs.path > rhs.path }
            return left < right
        } ?? files[0]
    }

    /// Import one folder, PMX file, or ZIP archive. All PMX files found inside
    /// the imported folder are registered, not just the first one.
    func importModel(from source: URL) throws -> MMDModelEntry {
        let result = try importModels(from: [source])
        guard let first = result.entries.first else {
            throw MMDLoadError.invalidData("没有找到可导入的模型")
        }
        return first
    }

    func importModels(from sources: [URL]) throws -> MMDImportResult {
        var entries = [MMDModelEntry]()
        var warnings = [String]()
        for source in sources {
            let accessed = source.startAccessingSecurityScopedResource()
            defer { if accessed { source.stopAccessingSecurityScopedResource() } }
            MMDLog.shared.info("Import source: \(source.lastPathComponent), securityScope=\(accessed)")

            let fileManager = FileManager.default
            let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let extensionName = source.pathExtension.lowercased()
            let stem = source.deletingPathExtension().lastPathComponent
            let baseName = stem.isEmpty ? "导入模型" : stem
            let destination = uniqueFolder(named: baseName)
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

            do {
                if isDirectory {
                    let contents = try fileManager.contentsOfDirectory(at: source,
                                                                       includingPropertiesForKeys: nil,
                                                                       options: [.skipsHiddenFiles])
                    for item in contents {
                        let target = destination.appendingPathComponent(item.lastPathComponent)
                        if !fileManager.fileExists(atPath: target.path) {
                            try fileManager.copyItem(at: item, to: target)
                        }
                    }
                    MMDLog.shared.info("Copied folder: \(contents.count) top-level item(s)")
                } else if extensionName == "zip" {
                    let extracted = try MMDZipArchive.extract(url: source, to: destination)
                    MMDLog.shared.info("ZIP extracted: \(extracted) file(s) -> \(destination.path)")
                } else if ["pmx", "pmd"].contains(extensionName) {
                    try fileManager.copyItem(at: source,
                                             to: destination.appendingPathComponent(source.lastPathComponent))
                    if !copySiblingResources(from: source.deletingLastPathComponent(), to: destination) {
                        warnings.append("单个 PMX 可能缺少同目录贴图；如贴图缺失，请改选模型文件夹或 ZIP。")
                    }
                } else {
                    throw MMDLoadError.unsupported("不支持的文件类型 .\(extensionName)")
                }
            } catch {
                MMDLog.shared.error("Import copy/extract failed: \(error.localizedDescription)")
                try? fileManager.removeItem(at: destination)
                throw error
            }

            let pmxFiles = findAllPMX(in: destination)
            guard !pmxFiles.isEmpty else {
                try? fileManager.removeItem(at: destination)
                throw MMDLoadError.invalidData("导入内容中没有找到 .pmx / .pmd 模型文件")
            }
            MMDLog.shared.info("Found \(pmxFiles.count) PMX model(s) in \(destination.lastPathComponent)")
            let selectedModels: [URL]
            if pmxFiles.count > 1 && !importAllModels {
                selectedModels = [Self.primaryModel(in: pmxFiles)]
                warnings.append("\(source.lastPathComponent) 中发现 \(pmxFiles.count) 个模型，默认只导入主模型；其余模型可在画布“场景与配饰”中手动添加。")
            } else {
                selectedModels = pmxFiles
                if pmxFiles.count > 1 {
                    warnings.append("\(source.lastPathComponent) 中发现 \(pmxFiles.count) 个模型，已全部加入模型库。")
                }
            }

            for pmx in selectedModels {
                let path = pmx.standardizedFileURL.path
                let rootPath = libraryURL.standardizedFileURL.path
                let relative = path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : pmx.lastPathComponent
                let display = Self.friendlyDisplayName(pmx: pmx, packageName: destination.lastPathComponent)
                entries.append(MMDModelEntry(id: relative,
                                             displayName: display,
                                             pmxPath: pmx.path,
                                             packageURL: destination,
                                             assetDirectory: pmx.deletingLastPathComponent(),
                                             relativePath: relative))
            }
        }
        refresh()
        return MMDImportResult(entries: entries, warnings: warnings)
    }

    /// Copy images and nested texture folders next to a single PMX. Returns
    /// false when the source directory cannot be read at all.
    @discardableResult
    private func copySiblingResources(from parent: URL, to destination: URL) -> Bool {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(at: parent,
                                                                  includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: [.skipsHiddenFiles]) else {
            return false
        }
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "bmp", "tga", "gif", "webp", "dds"]
        for item in contents {
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let target = destination.appendingPathComponent(item.lastPathComponent)
            if fileManager.fileExists(atPath: target.path) { continue }
            if isDirectory {
                try? fileManager.copyItem(at: item, to: target)
            } else if imageExtensions.contains(item.pathExtension.lowercased()) {
                try? fileManager.copyItem(at: item, to: target)
            }
        }
        return true
    }

    private func uniqueFolder(named rawName: String) -> URL {
        let sanitized = rawName.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "..", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = sanitized.isEmpty ? "导入模型" : sanitized
        var candidate = libraryURL.appendingPathComponent(name, isDirectory: true)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = libraryURL.appendingPathComponent("\(name) \(index)", isDirectory: true)
            index += 1
        }
        return candidate
    }

    // MARK: - Legacy cleanup

    /// Earlier builds shipped a generated sample PMX/VMD. It is no longer
    /// part of the app; remove the old copy from Documents on upgrade so the
    /// library starts clean.
    private func removeLegacySampleIfNeeded() {
        let fileManager = FileManager.default
        let destination = libraryURL.appendingPathComponent("SampleModel", isDirectory: true)
        guard fileManager.fileExists(atPath: destination.path) else { return }
        do {
            try fileManager.removeItem(at: destination)
            MMDLog.shared.info("Removed legacy SampleModel")
        } catch {
            MMDLog.shared.warning("Legacy SampleModel removal failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Package classification

    /// One archive usually holds one character plus a handful of weapons and
    /// props, all with names like `weapon.pmx`, `武器.pmx`, `body_01.pmx`.
    /// Presenting those as siblings is why the library looked like a junk
    /// drawer. Group them: character first, props named `角色-道具`.
    private static func classifyPackages(_ input: [MMDModelEntry]) -> [MMDModelEntry] {
        var result = input
        let byPackage = Dictionary(grouping: input.indices, by: { input[$0].packageURL.path })
        for (_, indices) in byPackage where indices.count > 1 {
            let characters = indices.filter { input[$0].role == .character }
            guard !characters.isEmpty else { continue }

            for index in indices {
                let entry = input[index]
                guard let owner = ownerModel(for: entry, among: characters, all: input) else { continue }
                if owner.id == entry.id {
                    result[index].ownerName = entry.displayName
                    continue
                }
                let label = propLabel(for: entry, character: owner, all: input)
                result[index].ownerName = owner.displayName
                if !label.isEmpty, !owner.displayName.hasSuffix(label) {
                    result[index].displayName = "\(owner.displayName)-\(label)"
                }
            }
        }
        return result
    }

    private static func ownerModel(for entry: MMDModelEntry,
                                   among characters: [Int],
                                   all: [MMDModelEntry]) -> MMDModelEntry? {
        let path = entry.relativePath.lowercased()
        let directory = entry.assetDirectory.standardizedFileURL.path + "/"

        // 1. A prop stored in the same sub-folder as a character belongs to it.
        let sameFolder = characters.filter {
            let candidate = all[$0].assetDirectory.standardizedFileURL.path + "/"
            return directory.hasPrefix(candidate) && candidate != directory
        }
        if sameFolder.count == 1, let index = sameFolder.first { return all[index] }

        // 2. The character name appears in the prop's path (common for rips
        //    that keep `菲欧尼/武器/剑.pmx` together).
        for index in characters {
            let name = all[index].displayName.lowercased()
            if name.count >= 2 && path.contains(name) { return all[index] }
        }

        // 3. Only one character in the archive: everything else is its prop.
        if characters.count == 1, let index = characters.first { return all[index] }
        return nil
    }

    private static func propLabel(for entry: MMDModelEntry,
                                  character: MMDModelEntry,
                                  all: [MMDModelEntry]) -> String {
        var stem = URL(fileURLWithPath: entry.pmxPath).deletingPathExtension().lastPathComponent
        if stem.unicodeScalars.contains(where: { (0x0300...0x036F).contains($0.value) }),
           let repaired = MMDZipArchive.repairedFilename(stem) {
            stem = repaired
        }
        for token in [character.displayName, entry.folderName, entry.packageURL.lastPathComponent]
        where token.count >= 2 {
            if stem.lowercased().hasPrefix(token.lowercased()) {
                stem = String(stem.dropFirst(token.count))
            }
        }
        stem = stem.replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-—·. ").union(.whitespaces))
        if stem.isEmpty || stem.lowercased() == character.displayName.lowercased() {
            stem = entry.displayName
        }
        if stem.count > 20 { stem = String(stem.prefix(20)) }
        return stem
    }

    // MARK: - Helpers

    private func findAllPMX(in folder: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: folder,
                                                      includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        var files = [URL]()
        for case let url as URL in enumerator {
            guard ["pmx", "pmd"].contains(url.pathExtension.lowercased()) else { continue }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files.append(url)
            }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func isAccessoryPath(_ path: String) -> Bool {
        let value = path.lowercased()
        let keywords = ["weapon", "sword", "katana", "gun", "rifle", "prop", "accessor",
                        "hat", "cap", "crown", "glasses", "mask", "bag", "backpack",
                        "武器", "配饰", "道具", "剑", "刀", "枪", "帽", "眼镜", "面具", "背包"]
        return keywords.contains { value.contains($0) }
    }

    private static func shouldAutoAttach(_ url: URL, relativeTo character: PMXModel) -> Bool {
        if isAccessoryPath(url.path) { return true }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let model = try? Self.parseModel(data: data, url: url) else { return false }
        // Conservative fallback: only small, non-humanoid static meshes are
        // treated as props. Alternative full characters stay independent.
        let hasHead = model.bones.contains {
            let name = MMDModelDocument.normalizedBoneName($0.name)
            return ["head", "頭", "头"].contains { name == $0 || name.contains($0) }
        }
        let hasThigh = model.bones.contains {
            let name = MMDModelDocument.normalizedBoneName($0.name)
            return ["thigh", "leg", "足", "腿"].contains { name.contains($0) }
        }
        let smallEnough = model.vertices.count < max(500, character.vertices.count / 3)
        return smallEnough && (!hasHead || !hasThigh) && model.bones.count <= 8
    }

    private func findPMX(in folder: URL) -> URL? {
        findAllPMX(in: folder).first
    }

    static func parseModel(data: Data, url: URL) throws -> PMXModel {
        switch url.pathExtension.lowercased() {
        case "pmd": return try PMDParser(data: data).parse()
        default: return try PMXParser(data: data).parse()
        }
    }

    private static func friendlyDisplayName(pmx: URL, packageName: String) -> String {
        if let data = try? Data(contentsOf: pmx, options: [.mappedIfSafe]),
           let headerName = (pmx.pathExtension.lowercased() == "pmd"
                             ? PMDParser.readDisplayName(data: data)
                             : PMXParser.readDisplayName(data: data)) {
            let trimmed = headerName.trimmingCharacters(in: .whitespacesAndNewlines)
            let generic: Set<String> = ["model", "mesh", "body", "character", "mmd", "main", "untitled", "pmx", "default", "モデル"]
            if !trimmed.isEmpty && !generic.contains(trimmed.lowercased()) {
                return trimmed
            }
        }
        let stem = pmx.deletingPathExtension().lastPathComponent
        // If the archive stored a CP1252/Latin-1 interpretation of a CJK
        // filename, macOS exposes combining marks such as I+U+0302. Do not
        // show that garbage in the library; the package name is a better
        // fallback until the user re-imports the archive.
        if stem.unicodeScalars.contains(where: { (0x0300...0x036F).contains($0.value) }) {
            return packageName
        }
        if let repaired = MMDZipArchive.repairedFilename(stem), repaired != stem {
            return repaired
        }
        let generic: Set<String> = ["model", "mesh", "body", "character", "mmd", "main", "untitled", "pmx", "default"]
        if generic.contains(stem.lowercased()) || stem.isEmpty {
            return packageName
        }
        return stem.replacingOccurrences(of: "_", with: " ")
    }
}
