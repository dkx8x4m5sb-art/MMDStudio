import SwiftUI
import UIKit

struct LogViewer: View {
    @Environment(\.dismiss) private var dismiss

    @State private var rawText: String = ""
    @State private var lines: [LogLine] = []
    @State private var filter: LogFilter = .all
    @State private var query: String = ""
    @State private var sharePayload: SharePayload?
    @State private var showClearConfirm = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                Divider().overlay(Color.white.opacity(0.08))
                if filteredLines.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "text.magnifyingglass")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text(query.isEmpty ? "当前筛选没有日志。" : "没有匹配“\(query)”的日志。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filteredLines) { line in
                        LogRow(line: line)
                            .listRowBackground(Color(red: 0.07, green: 0.08, blue: 0.10))
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color(red: 0.05, green: 0.06, blue: 0.08))
            .navigationTitle("运行日志")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "搜索日志")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("刷新日志")

                    Button {
                        UIPasteboard.general.string = rawText.isEmpty ? "还没有日志。" : rawText
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityLabel("复制日志")

                    Button {
                        if let url = MMDLog.shared.exportURL() {
                            sharePayload = SharePayload(items: [url])
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("分享日志")

                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("清空日志")
                }
            }
            .onAppear { reload() }
            .sheet(item: $sharePayload) { payload in
                ActivityView(items: payload.items)
            }
            .alert("清空日志？", isPresented: $showClearConfirm) {
                Button("清空", role: .destructive) {
                    MMDLog.shared.clear()
                    rawText = "日志已清空。"
                    lines = []
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private var filterBar: some View {
        VStack(spacing: 8) {
            Picker("级别", selection: $filter) {
                ForEach(LogFilter.allCases) { item in
                    Text("\(item.title) \(count(for: item))").tag(item)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                Text("\(lines.count) 条记录")
                Text("·")
                Text(byteText)
                Spacer()
                Text("实时写入 Documents/MMDStudio/Logs")
                    .lineLimit(1)
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.white.opacity(0.48))
            .padding(.horizontal, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(red: 0.07, green: 0.08, blue: 0.10))
    }

    private var filteredLines: [LogLine] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return lines.filter { line in
            guard filter.matches(line) else { return false }
            guard !trimmed.isEmpty else { return true }
            return line.searchText.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var byteText: String {
        let bytes = MMDLog.shared.storedBytes()
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576)
        }
        return String(format: "%.1f KB", Double(bytes) / 1024)
    }

    private func count(for filter: LogFilter) -> Int {
        lines.filter(filter.matches).count
    }

    private func reload() {
        rawText = MMDLog.shared.readRecent()
        lines = LogLine.parse(rawText)
    }
}

private enum LogFilter: String, CaseIterable, Identifiable, Hashable {
    case all
    case info
    case warning
    case error

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .info: return "信息"
        case .warning: return "警告"
        case .error: return "错误"
        }
    }

    func matches(_ line: LogLine) -> Bool {
        switch self {
        case .all: return true
        case .info: return line.level == .info
        case .warning: return line.level == .warning
        case .error: return line.level == .error
        }
    }
}

private enum LogLevel: String, Equatable {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"

    var title: String {
        switch self {
        case .info: return "信息"
        case .warning: return "警告"
        case .error: return "错误"
        }
    }

    var color: Color {
        switch self {
        case .info: return Color(red: 0.45, green: 0.82, blue: 0.98)
        case .warning: return Color(red: 0.98, green: 0.74, blue: 0.32)
        case .error: return Color(red: 1.0, green: 0.42, blue: 0.40)
        }
    }
}

private struct LogLine: Identifiable {
    let id: Int
    let timestamp: String
    let level: LogLevel
    let category: String
    let source: String
    let message: String

    var searchText: String { "\(timestamp) \(level.rawValue) \(category) \(source) \(message)" }

    static func parse(_ text: String) -> [LogLine] {
        let pattern = #"^\[(.+?)\]\s+\[(INFO|WARN|ERROR)\]\s+(?:\[(.+?)\]\s+)?\[([^\]]+)\]\s+(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var result: [LogLine] = []
        result.reserveCapacity(512)
        for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            let line = String(rawLine)
            if line == "[previous log]" {
                result.append(LogLine(id: offset, timestamp: "—", level: .info,
                                      category: "Log", source: "previous", message: line))
                continue
            }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range) else {
                result.append(LogLine(id: offset, timestamp: "—", level: .info,
                                      category: "Log", source: "", message: line))
                continue
            }
            func group(_ index: Int) -> String {
                let nsRange = match.range(at: index)
                guard nsRange.location != NSNotFound, let range = Range(nsRange, in: line) else { return "" }
                return String(line[range])
            }
            let level = LogLevel(rawValue: group(2)) ?? .info
            result.append(LogLine(id: offset, timestamp: group(1), level: level,
                                  category: group(3).isEmpty ? "General" : group(3),
                                  source: group(4), message: group(5)))
        }
        return result
    }
}

private struct LogRow: View {
    let line: LogLine

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(line.level.color)
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 2))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(line.level.title)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(line.level.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(line.level.color.opacity(0.13), in: Capsule())
                    Text(line.category)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer(minLength: 4)
                    Text(line.timestamp)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.38))
                }
                Text(line.message)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
                if !line.source.isEmpty {
                    Text(line.source)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.30))
                }
            }
        }
        .padding(.vertical, 3)
        .textSelection(.enabled)
    }
}

/// Wrapper for the system share sheet. The share sheet used to come up empty
/// on the first tap because SwiftUI could present it before the item array had
/// propagated; callers now pass a `SharePayload` through `.sheet(item:)` so the
/// controller is only built once non-empty items exist.
struct SharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .mmdShareSheetFinished, object: nil)
            }
        }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first
            popover.sourceRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

extension Notification.Name {
    static let mmdShareSheetFinished = Notification.Name("MMDShareSheetFinished")
}
