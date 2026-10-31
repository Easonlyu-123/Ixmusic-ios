import SwiftUI

struct SourcesView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showAddSheet = false
    @State private var draftScript = ""
    @State private var draftName = ""

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
            .overlay {
                if store.sources.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("还没有音源，点右上角 + 添加")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddSourceSheet(
                script: $draftScript,
                name: $draftName,
                onPickFile: {
                    // 先关掉导入面板，再（延迟等面板动画结束）从【根 VC】弹出系统文件选择器。
                    // 不能在面板之上再弹——那样点文件会被底层面板拦截、选不中。
                    // 选完/取消后再把面板重新打开并回填内容。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        FileImportCoordinator.shared.present(
                            onPick: { content, filename in
                                draftScript = content
                                if draftName.isEmpty { draftName = filename }
                                showAddSheet = true
                            },
                            onCancel: {
                                showAddSheet = true
                            }
                        )
                    }
                }
            )
        }
    }
}

/// 导入一段洛雪格式的音源脚本（module.exports = {...}），格式保持不变。
struct AddSourceSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Binding var script: String
    @Binding var name: String
    var onPickFile: () -> Void

    @State private var platform = ""
    @State private var author = ""
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button(action: {
                        dismiss()
                        onPickFile()
                    }) {
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
