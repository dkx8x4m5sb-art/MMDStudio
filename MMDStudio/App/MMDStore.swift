//
//  MMDStore.swift
//  MMD Studio
//
//  模型库：导入、按角色归类、持久化。
//

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
    /// 键：顶层导入包目录。逻辑分组不改动
    /// 压缩包内部的贴图路径。
    var packageGroups: [String: UUID] = [:]
}

struct MMDModelEntry: Identifiable, Hashable {
    /// 稳定标识：PMX 相对模型库的路径。
    let id: String
    /// 模型或文件里的完整写法，例如 `蕾米埃尔-白`。
    var displayName: String
    let pmxPath: String
    /// 顶层导入目录。多个 PMX 模型可能共用这个目录。
    let packageURL: URL
    /// 存放 PMX 的目录；贴图相对路径从这里开始。
    let assetDirectory: URL
    let relativePath: String
    var role: MMDModelRole = .character
    var groupID: UUID?
    /// 这个模型所在的目录：角色名。同一个角色的每套衣服
    /// 都共用它，哪怕衣服是分开的压缩包导入的 ——
    /// 白/黑/泳装 因此合成一个目录而不是三个。
    var characterName: String?
    /// 该目录内显示的款式或道具后缀：白 / 泳装 / 武器。
    var variantName: String?

    var folderName: String { packageURL.lastPathComponent }
    /// 角色目录里显示的行文本。只装角色本身的目录
    /// 会把标题藏起来，所以它同时充当列表标题。
    var rowName: String {
        if let variantName, !variantName.isEmpty { return variantName }
        return characterName ?? displayName
    }
}

struct MMDImportResult {
    let entries: [MMDModelEntry]
    let warnings: [String]
}

final class MMDStore: ObservableObject {

    @Published var entries: [MMDModelEntry] = []
    @Published var groups: [MMDModelGroup] = []
    @Published var errorMessage: String?

    /// 多模型包里只导入主 PMX。其余模型
    /// 留在磁盘上，可从场景编辑器添加。
    @Published var importAllModels: Bool {
        didSet { UserDefaults.standard.set(importAllModels, forKey: Self.importAllModelsKey) }
    }
    /// 打开角色时自动挂上武器/挂件。
    @Published var autoAttachPackageModels: Bool {
        didSet { UserDefaults.standard.set(autoAttachPackageModels, forKey: Self.autoAttachKey) }
    }
    private static let importAllModelsKey = "MMDStudio.importAllModels"
    private static let autoAttachKey = "MMDStudio.autoAttachPackageModels"

    let libraryURL: URL
    private var packageGroups: [String: UUID] = [:]
    private var metadataURL: URL { libraryURL.appendingPathComponent(".mmd-library.json") }

    init() {
        // 多角色包（绳匠 → 玲 + 哲）以前只导入最大的 PMX，
        // 看起来就是「导入失败：少了一个角色」。现在模型按角色归档，
        // 整包导入是安全的。
        let storedAll = UserDefaults.standard.object(forKey: Self.importAllModelsKey)
        importAllModels = storedAll == nil ? true : UserDefaults.standard.bool(forKey: Self.importAllModelsKey)
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

    // MARK: - 模型库

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
        result = Self.classify(result)
        result.sort { lhs, rhs in
            let left = lhs.characterName ?? lhs.displayName
            let right = rhs.characterName ?? rhs.displayName
            if left != right { return left.localizedStandardCompare(right) == .orderedAscending }
            // 角色行排在自己的挂件之上。
            if lhs.role != rhs.role { return lhs.role == .character }
            return lhs.rowName.localizedStandardCompare(rhs.rowName) == .orderedAscending
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

    /// 文件按相对导入包显示，用户删之前
    /// 能看清哪些贴图/PMX 是一套的。
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

    /// 删除整个导入包。存储管理器以包目录为删除单位，
    /// 而不是 PMX 条目列表。
    /// 目录的分组归属也一并清掉，否则以后再导入
    /// 同名包会悄悄落进旧分组。
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
        // 贴图通常和 PMX 放在一起，但多模型包常把
        // 共用贴图目录放在压缩包根目录。两个根都会
        // 搜，PMX 所在目录优先。
        let document = MMDModelDocument(model: model,
                                        baseDirectory: entry.assetDirectory,
                                        fallbackRoot: entry.packageURL == entry.assetDirectory ? nil : entry.packageURL,
                                        displayName: model.displayName,
                                        sourceURL: pmxURL)
        if entry.role == .character && autoAttachPackageModels {
            var imported = 0
            for candidate in findAllPMX(in: entry.packageURL) where candidate.path != pmxURL.path {
                // 普通包挂三个就够，而且每一个都是
                // 完整的 PMX 解析加各自的顶点/骨骼数组。
                // 重型角色上挂八个，还没画一帧
                // 就超出内存预算了。
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
        // 带舞蹈的包会把舞导入共享库一次
        // （按内容去重），再挑骨骼真正匹配
        // 这个模型的那一版加载。会话之间不复制文件。
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

    // MARK: - 导入

    private static func primaryModel(in files: [URL]) -> URL {
        files.max { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let right = (try? rhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if left == right { return lhs.path > rhs.path }
            return left < right
        } ?? files[0]
    }

    /// 导入一个目录、PMX 文件或 ZIP。导入目录里
    /// 找到的所有 PMX 都会登记，不只第一个。
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
                    let skipped = try MMDZipArchive.extract(url: source, to: destination)
                    MMDLog.shared.info("ZIP extracted -> \(destination.path), skipped=\(skipped.count)")
                    if !skipped.isEmpty {
                        MMDLog.shared.warning("ZIP items that could not be read: " +
                                              skipped.prefix(6).joined(separator: ", "))
                    }
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

    /// 把图片与嵌套贴图目录复制到单个 PMX 旁边。
    /// 源目录完全读不了时返回 false。
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

    // MARK: - 旧数据清理

    /// 早期版本自带一个示例 PMX/VMD。现在不再
    /// 随 App 提供；升级时从 Documents 删掉旧副本，
    /// 让模型库从干净状态开始。
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

    // MARK: - 角色归类

    /// 每个模型归到自己的角色下，而不是归到压缩包下。
    /// 原因见 `MMDCharacterNaming`：压缩包按系列命名
    /// （绳匠 里装着 玲 和 哲），一个角色的衣服也常分散在
    /// 几个压缩包里（蕾米埃尔 白/黑/泳装）。
    private static func classify(_ input: [MMDModelEntry]) -> [MMDModelEntry] {
        let namingInputs = input.map {
            MMDCharacterNaming.Input(id: $0.id,
                                     displayName: $0.displayName,
                                     pmxPath: $0.pmxPath,
                                     packagePath: $0.packageURL.path,
                                     relativePath: $0.relativePath)
        }
        let outputs = MMDCharacterNaming.classify(namingInputs)
        var result = input
        for index in result.indices where index < outputs.count {
            let output = outputs[index]
            result[index].characterName = output.characterName
            result[index].variantName = output.variantName
            result[index].role = (output.isProp || isAccessoryPath(result[index].relativePath))
                ? .accessory : .character
        }
        return result
    }

    // MARK: - 辅助

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
        // 保守兜底：只有小的、非人形静态网格
        // 才当挂件。另一种完整角色保持独立。
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
        var header = ""
        if let data = try? Data(contentsOf: pmx, options: [.mappedIfSafe]) {
            let raw = pmx.pathExtension.lowercased() == "pmd"
                ? PMDParser.readDisplayName(data: data)
                : PMXParser.readDisplayName(data: data)
            header = raw ?? ""
        }
        var file = pmx.deletingPathExtension().lastPathComponent
        // 如果压缩包存的是 CJK 文件名的 CP1252/Latin-1 解释，
        // macOS 会暴露 I+U+0302 这类组合附标。
        if file.unicodeScalars.contains(where: { (0x0300...0x036F).contains($0.value) }) {
            file = MMDZipArchive.repairedFilename(file) ?? ""
        }
        return MMDCharacterNaming.preferredDisplayName(header: header,
                                                       fileName: file,
                                                       packageName: packageName)
    }

}
