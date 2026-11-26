import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var store: MMDStore

    @State private var showImporter = false
    @State private var importError: String?
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var showGroupCreator = false
    @State private var newGroupName = ""
    @State private var showGroupPicker = false
    @State private var renamingEntry: MMDModelEntry?
    @State private var renamingGroup: MMDModelGroup?
    @State private var renameText = ""
    @State private var fileManagerEntry: MMDModelEntry?
    @State private var pendingDelete: [MMDModelEntry] = []
    @State private var showLogs = false
    @State private var showStorage = false
    /// Presented as a full-screen cover instead of a navigation push: the
    /// canvas claims one-finger horizontal drags for orbiting, and a drag that
    /// started at the left edge was being consumed by the navigation stack's
    /// interactive pop, throwing the user back to the list mid-rotation. A
    /// cover has no pop gesture at all, so the only way out is the button.
    @State private var openedEntry: MMDModelEntry?

    private var selectedEntries: [MMDModelEntry] {
        store.entries.filter { selectedIDs.contains($0.id) }
    }

    private var ungroupedEntries: [MMDModelEntry] {
        store.entries.filter { entry in
            entry.groupID == nil || !store.groups.contains(where: { $0.id == entry.groupID })
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if store.entries.isEmpty {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "person.3.sequence")
                                .font(.system(size: 42))
                                .foregroundStyle(.cyan)
                            Text("导入 MMD 模型").font(.headline)
                            Text("支持 PMX、包含贴图的文件夹或 ZIP。一个压缩包保持为一组，可继续创建逻辑文件夹和批量分组。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("选择文件") { showImporter = true }
                                .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                    }
                }

                ForEach(store.groups) { group in
                    let items = store.entries.filter { $0.groupID == group.id }
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { modelRow($0) }
                        } header: {
                            HStack {
                                Label(group.name, systemImage: "folder")
                                Text("\(items.count)")
                                Spacer()
                                Menu {
                                    Button("重命名文件夹") {
                                        renamingGroup = group
                                        renameText = group.name
                                    }
                                    Button("删除文件夹（保留模型）", role: .destructive) {
                                        store.deleteGroup(group)
                                    }
                                } label: { Image(systemName: "ellipsis.circle") }
                            }
                        }
                    }
                }

                if !ungroupedEntries.isEmpty {
                    Section(header: Text(store.groups.isEmpty ? "模型库" : "未分组")) {
                        ForEach(ungroupedEntries) { modelRow($0) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("MMD Studio")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !store.entries.isEmpty {
                        Button(isSelecting ? "完成" : "选择") {
                            isSelecting.toggle()
                            if !isSelecting { selectedIDs.removeAll() }
                        }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Toggle("导入整包内全部模型", isOn: $store.importAllModels)
                        Toggle("打开角色时自动添加配饰", isOn: $store.autoAttachPackageModels)
                        Divider()
                        Button { showStorage = true } label: {
                            Label("存储与文件管理", systemImage: "internaldrive")
                        }
                        Button { showLogs = true } label: {
                            Label("运行日志", systemImage: "doc.text.magnifyingglass")
                        }
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("导入与日志设置")
                    Button {
                        newGroupName = ""
                        showGroupCreator = true
                    } label: { Image(systemName: "folder.badge.plus") }
                    .accessibilityLabel("创建模型文件夹")
                    Button { showImporter = true } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .accessibilityLabel("导入模型")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isSelecting {
                    HStack {
                        Button("全选") { selectedIDs = Set(store.entries.map(\.id)) }
                        Spacer()
                        Text("已选 \(selectedIDs.count)").font(.caption)
                        Spacer()
                        Button("分组") { showGroupPicker = true }
                            .disabled(selectedIDs.isEmpty)
                        Button("删除", role: .destructive) { pendingDelete = selectedEntries }
                            .disabled(selectedIDs.isEmpty)
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                }
            }
            .sheet(isPresented: $showImporter) {
                MMDDocumentPicker(contentTypes: MMDImportTypes.modelImport,
                                  allowsMultipleSelection: true,
                                  onPick: { urls in
                                      showImporter = false
                                      importModels(urls)
                                  },
                                  onCancel: { showImporter = false })
            }
            .sheet(isPresented: $showGroupPicker) {
                GroupPickerView(store: store, entries: selectedEntries) {
                    showGroupPicker = false
                    isSelecting = false
                    selectedIDs.removeAll()
                }
            }
            .sheet(item: $fileManagerEntry) { entry in
                PackageFilesView(store: store, entry: entry)
            }
            .sheet(isPresented: $showLogs) {
                LogViewer()
            }
            .sheet(isPresented: $showStorage) {
                StorageManagerView().environmentObject(store)
            }
            .fullScreenCover(item: $openedEntry) { entry in
                NavigationStack {
                    ModelScreen(entry: entry).environmentObject(store)
                }
            }
            .alert("创建模型文件夹", isPresented: $showGroupCreator) {
                TextField("文件夹名称", text: $newGroupName)
                Button("创建") { store.createGroup(name: newGroupName) }
                Button("取消", role: .cancel) {}
            }
            .alert("重命名模型", isPresented: Binding(get: { renamingEntry != nil }, set: { if !$0 { renamingEntry = nil } })) {
                TextField("PMX 文件名", text: $renameText)
                Button("重命名") {
                    if let entry = renamingEntry {
                        do { try store.rename(entry, to: renameText) }
                        catch { importError = error.localizedDescription }
                    }
                    renamingEntry = nil
                }
                Button("取消", role: .cancel) { renamingEntry = nil }
            }
            .alert("重命名文件夹", isPresented: Binding(get: { renamingGroup != nil }, set: { if !$0 { renamingGroup = nil } })) {
                TextField("文件夹名称", text: $renameText)
                Button("重命名") {
                    if let group = renamingGroup { store.renameGroup(group, to: renameText) }
                    renamingGroup = nil
                }
                Button("取消", role: .cancel) { renamingGroup = nil }
            }
            .alert("删除选中模型？", isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })) {
                Button("删除", role: .destructive) {
                    store.delete(entries: pendingDelete)
                    pendingDelete = []
                    selectedIDs.removeAll()
                }
                Button("取消", role: .cancel) { pendingDelete = [] }
            } message: {
                Text("删除整包会同时移除其中的贴图；共享包中只选择部分 PMX 时，仅删除选中的模型文件。")
            }
            .alert("导入 / 编辑失败", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(importError ?? "") }
        }
    }

    @ViewBuilder
    private func modelRow(_ entry: MMDModelEntry) -> some View {
        let row = HStack(spacing: 12) {
            if isSelecting {
                Image(systemName: selectedIDs.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedIDs.contains(entry.id) ? .cyan : .secondary)
            }
            Image(systemName: entry.role == .accessory ? "cube" : "person.fill")
                .font(.title2)
                .foregroundStyle(.cyan)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.displayName).font(.headline).lineLimit(2)
                Text("\(entry.folderName) · \(entry.role.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)

        if isSelecting {
            Button { toggleSelection(entry) } label: { row }
                .buttonStyle(.plain)
        } else {
            Button { openedEntry = entry } label: { row }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("查看 / 编辑包内文件") { fileManagerEntry = entry }
                    Button("重命名 PMX") {
                                        renamingEntry = entry
                                        renameText = URL(fileURLWithPath: entry.pmxPath).deletingPathExtension().lastPathComponent
                    }
                    Button("移动到模型文件夹") {
                        selectedIDs = [entry.id]
                        showGroupPicker = true
                    }
                    Button("删除", role: .destructive) { pendingDelete = [entry] }
                }
        }
    }

    private func toggleSelection(_ entry: MMDModelEntry) {
        if selectedIDs.contains(entry.id) { selectedIDs.remove(entry.id) }
        else { selectedIDs.insert(entry.id) }
    }

    private func importModels(_ urls: [URL]) {
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do { _ = try store.importModel(from: url) }
            catch { importError = error.localizedDescription }
        }
    }
}

private struct GroupPickerView: View {
    @ObservedObject var store: MMDStore
    let entries: [MMDModelEntry]
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Button("未分组") {
                    store.assign(entries: entries, to: nil)
                    onDone()
                }
                ForEach(store.groups) { group in
                    Button {
                        store.assign(entries: entries, to: group.id)
                        onDone()
                    } label: { Label(group.name, systemImage: "folder") }
                }
            }
            .navigationTitle("移动到模型文件夹")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct PackageFilesView: View {
    @ObservedObject var store: MMDStore
    let entry: MMDModelEntry
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var selectedPaths: Set<String> = []
    @State private var selecting = false
    @State private var showImporter = false
    @State private var showDelete = false
    @State private var errorMessage: String?

    init(store: MMDStore, entry: MMDModelEntry) {
        _store = ObservedObject(wrappedValue: store)
        self.entry = entry
    }

    var body: some View {
        NavigationStack {
            List {
                Section("压缩包 / 模型组") {
                    Label(entry.folderName, systemImage: "shippingbox")
                    Text("分组不会移动实际文件，避免破坏 PMX 内部的相对贴图路径。这里显示的是该包的真实文件。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("向此包追加模型 / 配饰 / 贴图") { showImporter = true }
                }
                Section("文件 \(files.count)") {
                    ForEach(files, id: \.path) { file in
                        Button {
                            guard selecting else { return }
                            if selectedPaths.contains(file.path) { selectedPaths.remove(file.path) }
                            else { selectedPaths.insert(file.path) }
                        } label: {
                            HStack {
                                if selecting {
                                    Image(systemName: selectedPaths.contains(file.path) ? "checkmark.circle.fill" : "circle")
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(relative(file)).foregroundStyle(.primary).lineLimit(2)
                                    Text(fileSize(file)).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(entry.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selecting ? "完成" : "选择") {
                        selecting.toggle()
                        if !selecting { selectedPaths.removeAll() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if selecting {
                        Button("删除", role: .destructive) { showDelete = true }
                            .disabled(selectedPaths.isEmpty)
                    } else {
                        Button("完成") { dismiss() }
                    }
                }
            }
            .sheet(isPresented: $showImporter) {
                MMDDocumentPicker(contentTypes: [.data, .zip, .folder], allowsMultipleSelection: true,
                                  onPick: { urls in
                                      showImporter = false
                                      for url in urls {
                                          let accessed = url.startAccessingSecurityScopedResource()
                                          defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                                          do { try store.importFiles([url], into: entry) }
                                          catch { errorMessage = error.localizedDescription }
                                      }
                                      reload()
                                  }, onCancel: { showImporter = false })
            }
            .alert("删除包内文件？", isPresented: $showDelete) {
                Button("删除", role: .destructive) {
                    do {
                        try store.deleteFiles(files.filter { selectedPaths.contains($0.path) }, in: entry)
                        selectedPaths.removeAll()
                        reload()
                    } catch { errorMessage = error.localizedDescription }
                }
                Button("取消", role: .cancel) {}
            } message: { Text("删除贴图可能导致模型显示异常；删除当前 PMX 后它会从模型库移除。") }
            .alert("文件操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
            .onAppear(perform: reload)
        }
    }

    private func reload() { files = store.packageFiles(for: entry) }

    private func relative(_ file: URL) -> String {
        let root = entry.packageURL.path + "/"
        return file.path.hasPrefix(root) ? String(file.path.dropFirst(root.count)) : file.lastPathComponent
    }

    private func fileSize(_ file: URL) -> String {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
