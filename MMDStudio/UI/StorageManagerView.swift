//
//  StorageManagerView.swift
//  MMD Studio
//
//  存储管理界面。
//

import SwiftUI

/// 存储概览 + 文件管理。这里有两个关键入口：
/// 一键清缓存，以及不经模型库就能看到并删除
/// 单个导出文件或整个模型包。
struct StorageManagerView: View {
    @EnvironmentObject private var store: MMDStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var monitor = MMDStorageMonitor()

    @State private var showClearConfirm = false
    @State private var activePackage: MMDStoragePackage?
    @State private var pendingPackageDelete: MMDStoragePackage?
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            List {
                summarySection
                if monitor.buckets.isEmpty {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在统计存储占用…").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    bucketSection(.cache)
                    bucketSection(.media)
                    bucketSection(.assets)
                    packageSection
                    explanationSection
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("存储与文件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await monitor.reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(monitor.isScanning)
                    .accessibilityLabel("重新统计")
                }
            }
            .refreshable { await monitor.reload() }
            .task { await monitor.reload() }
            .overlay(alignment: .bottom) { toastView }
            .confirmationDialog("清理缓存？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("清理 \(storageBytes(monitor.cacheBytes))") { clearCache() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("会删除临时文件、系统缓存和运行日志。模型库、导出视频、录屏与相册都不受影响。")
            }
            .alert("删除模型包？", isPresented: Binding(get: { pendingPackageDelete != nil },
                                                     set: { if !$0 { pendingPackageDelete = nil } })) {
                Button("删除", role: .destructive) { deletePendingPackage() }
                Button("取消", role: .cancel) { pendingPackageDelete = nil }
            } message: {
                Text("「\(pendingPackageDelete?.name ?? "")」里的 PMX、贴图与动作会一起删除，无法恢复。")
            }
            .sheet(item: $activePackage, onDismiss: { Task { await monitor.reload() } }) { package in
                if let entry = store.entries.first(where: {
                    $0.packageURL.standardizedFileURL.path == package.url.standardizedFileURL.path
                }) {
                    PackageFilesView(store: store, entry: entry)
                } else {
                    NavigationStack {
                        StorageFilesView(title: package.name,
                                         note: "这个文件夹里已经没有 PMX 模型，只留下贴图或残留文件。",
                                         roots: [package.url],
                                         onDeleted: { Task { await monitor.reload() } })
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("完成") { activePackage = nil }
                                }
                            }
                    }
                }
            }
        }
    }

    // MARK: 概览

    private var segments: [UsageSegment] {
        [UsageSegment(id: "models", label: "模型", value: monitor.modelBytes, color: .cyan),
         UsageSegment(id: "media", label: "导出", value: monitor.mediaBytes, color: .purple),
         UsageSegment(id: "assets", label: "素材", value: monitor.assetBytes, color: .green),
         UsageSegment(id: "cache", label: "缓存", value: monitor.cacheBytes, color: .orange)]
    }

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(storageBytes(monitor.appBytes))
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    if monitor.isScanning {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
                Text("MMD Studio 占用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                usageBar
                legend
                Divider().overlay(Color.white.opacity(0.08))
                HStack(spacing: 6) {
                    Image(systemName: "iphone")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("设备可用 \(storageBytes(monitor.freeBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if monitor.capacityBytes > 0 {
                        Text("共 \(storageBytes(monitor.capacityBytes))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.vertical, 4)

            Button {
                showClearConfirm = true
            } label: {
                HStack {
                    Label(monitor.cacheBytes > 0
                          ? "清理缓存（\(storageBytes(monitor.cacheBytes))）"
                          : "缓存已是最干净",
                          systemImage: "sparkles")
                    Spacer()
                    if monitor.isWorking {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(monitor.cacheBytes == 0 || monitor.isWorking)
        } header: {
            Text("概览")
        } footer: {
            Text("缓存是临时文件、系统缓存与运行日志的总和，清理不会丢失任何模型或导出成品。")
        }
    }

    private var usageBar: some View {
        GeometryReader { proxy in
            let total = max(1, monitor.appBytes)
            HStack(spacing: 0) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: proxy.size.width * CGFloat(Double(segment.value) / Double(total)))
                }
            }
            .background(Color.white.opacity(0.08))
            .clipShape(Capsule())
        }
        .frame(height: 12)
    }

    private var legend: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                            GridItem(.flexible(), alignment: .leading)],
                  alignment: .leading, spacing: 6) {
            ForEach(segments) { segment in
                HStack(spacing: 6) {
                    Circle().fill(segment.color).frame(width: 7, height: 7)
                    Text(segment.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 2)
                    Text(storageBytes(segment.value))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: 分类区块

    @ViewBuilder
    private func bucketSection(_ group: MMDStorageGroup) -> some View {
        let items = monitor.buckets.filter { $0.group == group }
        if !items.isEmpty {
            Section {
                ForEach(items) { bucket in
                    NavigationLink {
                        StorageFilesView(title: bucket.title,
                                         note: bucket.note,
                                         roots: bucket.roots,
                                         onDeleted: { Task { await monitor.reload() } })
                    } label: {
                        bucketRow(bucket)
                    }
                }
            } header: {
                HStack {
                    Text(group.rawValue)
                    Spacer()
                    Text(storageBytes(items.reduce(0) { $0 + $1.byteCount }))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                if group == .cache {
                    Text("这些文件删掉后会自动重建，可以放心清理。")
                        .font(.caption2)
                } else if group == .media {
                    Text("导出成品不会自动重新生成，删除前请先保存到相册或「文件」。")
                        .font(.caption2)
                } else {
                    Text("背景、配饰与动作是被引用的素材，删除后对应模型或动作会缺少文件。")
                        .font(.caption2)
                }
            }
        }
    }

    private func bucketRow(_ bucket: MMDStorageBucket) -> some View {
        HStack(spacing: 12) {
            Image(systemName: bucket.systemImage)
                .frame(width: 24)
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 3) {
                Text(bucket.title)
                    .foregroundStyle(.primary)
                Text(bucket.files.isEmpty ? bucket.note : "\(bucket.files.count) 个文件")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(bucket.files.isEmpty ? "空" : storageBytes(bucket.byteCount))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: 包

    private var packageSection: some View {
        Section {
            if monitor.packages.isEmpty {
                Text("模型库是空的。导入的 PMX 会以包为单位出现在这里。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(monitor.packages) { package in
                    Button {
                        open(package)
                    } label: {
                        packageRow(package)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            pendingPackageDelete = package
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button("查看包内文件") { open(package) }
                        Button("删除模型包", role: .destructive) { pendingPackageDelete = package }
                    }
                }
            }
        } header: {
            HStack {
                Text("模型库")
                Spacer()
                Text(storageBytes(monitor.modelBytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("模型包是自包含的 PMX + 贴图 + 动作。逻辑文件夹只做分组，不移动文件。")
                .font(.caption2)
        }
    }

    private func packageRow(_ package: MMDStoragePackage) -> some View {
        let entry = store.entries.first {
            $0.packageURL.standardizedFileURL.path == package.url.standardizedFileURL.path
        }
        return HStack(spacing: 12) {
            Image(systemName: "cube.box")
                .frame(width: 24)
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry?.displayName ?? package.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(package.modelCount) 个模型 · \(package.fileCount) 个文件")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(storageBytes(package.byteCount))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private var explanationSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("文件也保存在「文件」App 里", systemImage: "folder")
                    .font(.footnote.weight(.medium))
                Text("Documents 已对「文件」App 开放：我的 iPhone › MMD Studio 下可以直接拖入模型 ZIP、取出导出的视频与图片。这里的删除操作与文件 App 中的删除是同一份数据。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        } footer: {
            if let scannedAt = monitor.scannedAt {
                Text("统计时间 \(scannedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
            }
        }
    }

    // MARK: 操作

    private func open(_ package: MMDStoragePackage) {
        activePackage = package
    }

    private func clearCache() {
        Task {
            let freed = await monitor.clearCache()
            await MainActor.run {
                showToast(freed > 0 ? "已释放 \(storageBytes(freed))" : "没有可清理的缓存")
            }
        }
    }

    private func deletePendingPackage() {
        guard let package = pendingPackageDelete else { return }
        pendingPackageDelete = nil
        store.deletePackage(at: package.url)
        showToast("已删除「\(package.name)」")
        Task { await monitor.reload() }
    }

    private var toastView: some View {
        Group {
            if let toast {
                Text(toast)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if toast == text {
                withAnimation(.easeOut(duration: 0.2)) { toast = nil }
            }
        }
    }
}

private struct UsageSegment: Identifiable {
    let id: String
    let label: String
    let value: Int64
    let color: Color
}

// MARK: - 文件列表

/// 列出一个或多个目录下的真实文件。删除永远走
/// 和概览同一道保护，过期路径不可能删掉
/// App 沙箱之外的东西。
struct StorageFilesView: View {
    let title: String
    let note: String
    let roots: [URL]
    var onDeleted: () -> Void = {}

    @State private var files: [MMDStorageFile] = []
    @State private var selected: Set<String> = []
    @State private var isSelecting = false
    @State private var pendingDelete: [MMDStorageFile] = []
    @State private var errorText: String?
    @State private var isLoading = true

    init(title: String, note: String, roots: [URL], onDeleted: @escaping () -> Void = {}) {
        self.title = title
        self.note = note
        self.roots = roots
        self.onDeleted = onDeleted
    }

    private var totalBytes: Int64 { files.reduce(0) { $0 + $1.byteCount } }

    var body: some View {
        List {
            if !note.isEmpty {
                Section {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                if isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在读取…").font(.footnote).foregroundStyle(.secondary)
                    }
                } else if files.isEmpty {
                    Text("这里没有文件。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(files) { file in
                    row(file)
                }
            } header: {
                HStack {
                    Text("\(files.count) 个文件")
                    Spacer()
                    Text(storageBytes(totalBytes))
                        .font(.caption.monospacedDigit())
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !files.isEmpty {
                    Button(isSelecting ? "完成" : "选择") {
                        isSelecting.toggle()
                        if !isSelecting { selected.removeAll() }
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !isSelecting && !files.isEmpty {
                    Menu {
                        Button("全选") {
                            selected = Set(files.map(\.id))
                            isSelecting = true
                        }
                        Button("删除全部", role: .destructive) {
                            pendingDelete = files
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            // 原生底栏。上一版自定义 HStack 带着自己的材质
            // 浮在列表上方，和 App 其他部分放在一起
            // 像一根老式控制条 —— 而且它和导航栏里
            // 那个删除按钮还是重复的。
            ToolbarItemGroup(placement: .bottomBar) {
                if isSelecting {
                    Button("全选") { selected = Set(files.map(\.id)) }
                    Spacer(minLength: 0)
                    Text("已选 \(selected.count) 项")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("删除", role: .destructive) {
                        pendingDelete = files.filter { selected.contains($0.id) }
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
        .alert("删除 \(pendingDelete.count) 个文件？", isPresented: Binding(get: { !pendingDelete.isEmpty },
                                                                     set: { if !$0 { pendingDelete = [] } })) {
            Button("删除", role: .destructive) { performDelete(pendingDelete) }
            Button("取消", role: .cancel) { pendingDelete = [] }
        } message: {
            Text("共 \(storageBytes(pendingDelete.reduce(0) { $0 + $1.byteCount }))，删除后无法恢复。")
        }
        .alert("删除失败", isPresented: Binding(get: { errorText != nil },
                                              set: { if !$0 { errorText = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .task { await load() }
    }

    private func row(_ file: MMDStorageFile) -> some View {
        Button {
            guard isSelecting else { return }
            if selected.contains(file.id) { selected.remove(file.id) }
            else { selected.insert(file.id) }
        } label: {
            HStack(spacing: 10) {
                if isSelecting {
                    Image(systemName: selected.contains(file.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected.contains(file.id) ? .cyan : .secondary)
                }
                Image(systemName: fileIcon(for: file.url))
                    .frame(width: 22)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    HStack(spacing: 5) {
                        Text(storageBytes(file.byteCount))
                        if let date = file.modifiedAt {
                            Text("·")
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                pendingDelete = [file]
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .contextMenu {
            ShareLink(item: file.url) { Label("分享", systemImage: "square.and.arrow.up") }
            Button("删除", role: .destructive) { pendingDelete = [file] }
        }
    }

    private func load() async {
        isLoading = true
        let roots = self.roots
        let scanned = await Task.detached(priority: .userInitiated) {
            MMDStorageScanner.files(in: roots)
        }.value
        await MainActor.run {
            self.files = scanned
            self.isLoading = false
        }
    }

    private func performDelete(_ items: [MMDStorageFile]) {
        let fileManager = FileManager.default
        var failed = 0
        for item in items where MMDStorageScanner.isManaged(item.url) {
            do {
                try fileManager.removeItem(at: item.url)
            } catch {
                failed += 1
                MMDLog.shared.warning("Storage delete failed: \(item.url.path), \(error.localizedDescription)")
            }
        }
        pendingDelete = []
        selected.removeAll()
        isSelecting = false
        Task { await load() }
        onDeleted()
        if failed > 0 {
            errorText = "有 \(failed) 个文件无法删除，可能正在被占用。"
        }
    }
}

// MARK: - 辅助

private func storageBytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
}

private func fileIcon(for url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "mp4", "mov", "m4v": return "film"
    case "png", "jpg", "jpeg", "bmp", "tga", "webp", "dds", "gif": return "photo"
    case "pmx", "pmd": return "cube"
    case "vmd": return "figure.walk"
    case "wav", "mp3", "m4a", "aac": return "waveform"
    case "obj", "mtl": return "square.stack.3d.up"
    case "zip": return "doc.zipper"
    case "log", "txt": return "doc.text"
    default: return "doc"
    }
}
