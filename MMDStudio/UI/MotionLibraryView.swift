import SwiftUI
import UniformTypeIdentifiers

/// Shared row for a library clip.
private struct MotionAssetRow: View {
    let asset: MMDMotionAsset
    var isCurrent = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: asset.kind == .camera ? "video" : "figure.walk")
                .font(.title3)
                .foregroundStyle(.cyan)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(asset.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if isCurrent {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.cyan)
                    }
                }
                Text(asset.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(asset.sourceName) · \(asset.fileName)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}

// MARK: - Canvas picker

/// Picks a clip for the open model. The motion and the camera are chosen
/// separately because MMD authors ship them as separate files.
struct MotionLibraryPicker: View {
    @ObservedObject var document: MMDModelDocument
    @ObservedObject private var library = MMDMotionLibrary.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showImporter = false
    @State private var errorText: String?
    @State private var importNote: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if library.motions.isEmpty {
                        Text("动作库还是空的。先在上面导入一个动作包或 VMD，之后每次进画布都能直接选。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(library.motions) { asset in
                        Button { load(asset) } label: {
                            MotionAssetRow(asset: asset, isCurrent: isCurrent(asset))
                        }
                        .buttonStyle(.plain)
                    }
                    if document.hasMotion {
                        Button("清除当前动作", role: .destructive) {
                            document.removeMotion()
                            dismiss()
                        }
                    }
                } header: {
                    Text("动作")
                } footer: {
                    if !document.motionMappingNote.isEmpty {
                        Text(document.motionMappingNote).font(.caption2)
                    }
                }

                Section {
                    if library.cameras.isEmpty {
                        Text("没有镜头文件。动作包里的 Camera_*.vmd 会自动放在这里。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(library.cameras) { asset in
                        Button { load(asset) } label: {
                            MotionAssetRow(asset: asset, isCurrent: document.useCameraMotion && isCurrent(asset))
                        }
                        .buttonStyle(.plain)
                    }
                    if document.useCameraMotion {
                        Button("关闭 VMD 相机") { document.useCameraMotion = false }
                    }
                } header: {
                    Text("镜头")
                } footer: {
                    Text("镜头只控制相机，不会让模型动。也可以在设置里关掉「使用 VMD 相机」。")
                        .font(.caption2)
                }

                Section {
                    Button {
                        showImporter = true
                    } label: {
                        Label("导入动作包 / VMD", systemImage: "square.and.arrow.down")
                    }
                    if let importNote {
                        Text(importNote).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("动作库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showImporter) {
                MMDDocumentPicker(contentTypes: MMDImportTypes.motionImport,
                                  allowsMultipleSelection: true,
                                  onPick: { urls in
                                      showImporter = false
                                      importFiles(urls)
                                  },
                                  onCancel: { showImporter = false })
            }
            .alert("动作加载失败", isPresented: Binding(get: { errorText != nil },
                                                     set: { if !$0 { errorText = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
        }
    }

    private func isCurrent(_ asset: MMDMotionAsset) -> Bool {
        document.motionName == asset.title && document.hasMotion
    }

    private func load(_ asset: MMDMotionAsset) {
        do {
            let mapped = try document.loadMotion(asset: asset, from: library)
            let note = asset.kind == .camera
                ? "已启用镜头《\(asset.title)》：相机运动，模型本身不动"
                : "已加载《\(asset.title)》：\(mapped) 根骨骼"
            NotificationCenter.default.post(name: .mmdMotionLoaded, object: note)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func importFiles(_ urls: [URL]) {
        var added = 0
        var messages: [String] = []
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let report = try library.importSource(url: url)
                added += report.addedMotions + report.addedCameras
                messages.append(report.summary)
            } catch {
                messages.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        importNote = messages.joined(separator: "；")
        if added == 0 { importNote = (importNote ?? "") + "（都已存在，未重复保存）" }
    }
}

// MARK: - Library management

/// The "待用区": every imported clip, motions and cameras kept apart.
struct MotionLibraryView: View {
    @ObservedObject private var library = MMDMotionLibrary.shared
    @State private var showImporter = false
    @State private var note: String?
    @State private var pendingDelete: MMDMotionAsset?

    var body: some View {
        List {
            if let note {
                Section {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                if library.motions.isEmpty {
                    Text("还没有动作。导入含 VMD 的 ZIP，或直接选一个 .vmd。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(library.motions) { asset in
                    MotionAssetRow(asset: asset)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { pendingDelete = asset } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            } header: {
                HStack {
                    Text("动作")
                    Spacer()
                    Text("\(library.motions.count)").font(.caption.monospacedDigit())
                }
            } footer: {
                Text("进入画布后可在这里任选一个动作；同一支舞的不同版本会分别列出，按匹配骨骼数挑选。")
                    .font(.caption2)
            }

            Section {
                if library.cameras.isEmpty {
                    Text("没有镜头文件。").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(library.cameras) { asset in
                    MotionAssetRow(asset: asset)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { pendingDelete = asset } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            } header: {
                HStack {
                    Text("镜头")
                    Spacer()
                    Text("\(library.cameras.count)").font(.caption.monospacedDigit())
                }
            } footer: {
                Text("Camera_*.vmd 之类的纯相机文件只放在这里，不会被当成动作加载。")
                    .font(.caption2)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("动作库")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showImporter = true } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .accessibilityLabel("导入动作")
            }
        }
        .sheet(isPresented: $showImporter) {
            MMDDocumentPicker(contentTypes: MMDImportTypes.motionImport,
                              allowsMultipleSelection: true,
                              onPick: { urls in
                                  showImporter = false
                                  importFiles(urls)
                              },
                              onCancel: { showImporter = false })
        }
        .alert("删除这个文件？", isPresented: Binding(get: { pendingDelete != nil },
                                                   set: { if !$0 { pendingDelete = nil } })) {
            Button("删除", role: .destructive) {
                if let asset = pendingDelete { library.delete(asset) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete.map { "「\($0.fileName)」会从动作库移除，已打开的画布不受影响。" } ?? "")
        }
    }

    private func importFiles(_ urls: [URL]) {
        var messages: [String] = []
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                messages.append(try library.importSource(url: url).summary)
            } catch {
                messages.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        note = messages.joined(separator: "；")
    }
}
