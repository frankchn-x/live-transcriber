import SwiftUI
import UIKit

struct HistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var shareItems: [Any]?

    var body: some View {
        NavigationStack {
            Group {
                if files.isEmpty {
                    ContentUnavailableView("还没有转录记录", systemImage: "tray",
                                           description: Text("停止转录后会自动保存到这里"))
                } else {
                    List {
                        ForEach(files, id: \.self) { url in
                            NavigationLink {
                                TranscriptDetail(url: url)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(title(for: url)).font(.system(size: 15, weight: .medium))
                                    Text(subtitle(for: url)).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("历史记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        let dir = TranscriptionEngine.transcriptsDirectory
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        files = items.filter { $0.pathExtension == "md" }
            .sorted { (modified($0) ?? .distantPast) > (modified($1) ?? .distantPast) }
    }

    private func delete(_ offsets: IndexSet) {
        for i in offsets { try? FileManager.default.removeItem(at: files[i]) }
        reload()
    }

    private func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func title(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.split(separator: "_")
        if parts.count >= 3, parts[2].count >= 4 {
            let t = parts[2]
            return "\(parts[1]) \(t.prefix(2)):\(t.dropFirst(2).prefix(2))"
        }
        return name
    }

    private func subtitle(for url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return "\(max(1, size / 1024)) KB"
    }
}

struct TranscriptDetail: View {
    let url: URL
    @State private var content = ""
    @State private var shareItems: [Any]?

    var body: some View {
        ScrollView {
            Text(content)
                .font(.system(size: 14))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .navigationTitle(url.deletingPathExtension().lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { shareItems = [url] } label: { Image(systemName: "square.and.arrow.up") }
            }
        }
        .onAppear { content = (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        .sheet(item: Binding(
            get: { shareItems.map { ShareItems(items: $0) } },
            set: { shareItems = $0?.items }
        )) { wrapper in
            ShareSheet(items: wrapper.items)
        }
    }
}
