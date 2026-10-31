import SwiftUI
import UniformTypeIdentifiers

struct SourcesView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showAddSheet = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.sources) { src in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(src.name)
                                .font(.headline)
                            Spacer(minLength: 8)
                            Toggle("启用", isOn: Binding(
                                get: { src.enabled },
                                set: { newValue in
                                    if let idx = store.sources.firstIndex(where: { $0.id == src.id }) {
                                        store.sources[idx].enabled = newValue
                                        store.saveSources()
                                    }
                                }
                            ))
                            .labelsHidden()
                        }
                        Text("platform: \(src.platform) · v\(src.version) · by \(src.author)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .swipeActions {
                        Button(role: .destructive) {
                            store.removeSource(src)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("音源管理")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddSourceSheet()
        }
    }
}

/// 导入一段洛雪格式的音源脚本（module.exports = {...}），格式保持不变。
struct AddSourceSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var platform = ""
    @State private var author = ""
    @State private var script = ""
    @State private var errorMessage: String?
    @State private var showFileImporter = false

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("音源名称", text: $name)
                    TextField("platform 标识", text: $platform)
                    TextField("作者", text: $author)
                }
                Section("洛雪音源脚本") {
                    TextEditor(text: $script)
                        .frame(minHeight: 200)
                        .font(.system(.caption, design: .monospaced))
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("导入音源")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("导入文件", systemImage: "doc.badge.plus")
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [UTType(filenameExtension: "js") ?? .plainText, .plainText],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let granted = url.startAccessingSecurityScopedResource()
                    defer { if granted { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let content = try String(contentsOf: url, encoding: .utf8)
                        script = content
                        if name.isEmpty {
                            name = url.deletingPathExtension().lastPathComponent
                        }
                        errorMessage = nil
                    } catch {
                        errorMessage = "读取文件失败：\(error.localizedDescription)"
                    }
                case .failure(let error):
                    errorMessage = "选择文件失败：\(error.localizedDescription)"
                }
            }
        }
        .presentationDetents([.large, .medium])
    }

    private func save() {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "请粘贴洛雪音源脚本"
            return
        }
        guard trimmed.contains("module.exports") else {
            errorMessage = "脚本需以 module.exports 导出音源对象"
            return
        }
        let source = MusicSource(
            name: name.isEmpty ? "未命名音源" : name,
            version: "1.0.0",
            platform: platform.isEmpty ? "custom" : platform,
            author: author.isEmpty ? "未知" : author,
            script: trimmed,
            enabled: true
        )
        store.addSource(source)
        dismiss()
    }
}
