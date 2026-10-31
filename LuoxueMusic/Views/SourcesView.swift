import SwiftUI
import UniformTypeIdentifiers

struct SourcesView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showAddSheet = false
    // 文件导入放在外层视图，避免 .fileImporter 嵌在 .sheet 内导致选中回调不触发。
    @State private var showFileImporter = false
    @State private var draftScript = ""
    @State private var draftName = ""
    @State private var importError: String?

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
            AddSourceSheet(
                script: $draftScript,
                name: $draftName,
                importError: $importError,
                onPickFile: { showFileImporter = true }
            )
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.data, .plainText],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                do {
                    let content = try String(contentsOf: url, encoding: .utf8)
                    draftScript = content
                    if draftName.isEmpty {
                        draftName = url.deletingPathExtension().lastPathComponent
                    }
                    importError = nil
                } catch {
                    importError = "读取文件失败：\(error.localizedDescription)"
                }
            case .failure(let error):
                importError = "选择文件失败：\(error.localizedDescription)"
            }
        }
    }
}

/// 导入一段洛雪格式的音源脚本（module.exports = {...}），格式保持不变。
struct AddSourceSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Binding var script: String
    @Binding var name: String
    @Binding var importError: String?
    var onPickFile: () -> Void

    @State private var platform = ""
    @State private var author = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button(action: onPickFile) {
                        Label("从「文件」导入 .js 音源", systemImage: "doc.badge.plus")
                    }
                } footer: {
                    Text("支持从 iPhone「文件」App 选择音源脚本（.js / .txt 均可）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("基本信息") {
                    TextField("音源名称", text: $name)
                    TextField("platform 标识", text: $platform)
                    TextField("作者", text: $author)
                }
                Section("洛雪音源脚本") {
                    if script.isEmpty {
                        Text("点上方「从文件导入」，或在此直接粘贴脚本")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    TextEditor(text: $script)
                        .frame(minHeight: 200)
                        .font(.system(.caption, design: .monospaced))
                }
                if let importError {
                    Section {
                        Text(importError)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("导入音源")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        resetDrafts()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
        }
        .presentationDetents([.large, .medium])
    }

    private func resetDrafts() {
        script = ""
        name = ""
        importError = nil
    }

    private func save() {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            importError = "请粘贴或导入洛雪音源脚本"
            return
        }
        guard trimmed.contains("module.exports") else {
            importError = "脚本需以 module.exports 导出音源对象"
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
        resetDrafts()
        dismiss()
    }
}
