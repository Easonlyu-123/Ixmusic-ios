import SwiftUI

struct SourcesView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showAddSheet = false
    @State private var showDocumentPicker = false
    @State private var draftScript = ""
    @State private var draftName = ""
    @State private var draftAuthor = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("洛雪音乐 · iOS")
                                .font(.subheadline.weight(.semibold))
                            Text("当前版本 v\(AppInfo.appVersion)（构建 \(AppInfo.buildNumber)）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
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
        // 导入面板：与下方文档选择器【平级】，先关它再开选择器，不会嵌套。
        .sheet(isPresented: $showAddSheet) {
            AddSourceSheet(
                script: $draftScript,
                name: $draftName,
                author: $draftAuthor,
                onPickFile: {
                    // AddSourceSheet 内部已 dismiss() 关闭自己，
                    // 这里只需让 SourcesView 在主体层级弹出系统文件选择器（标准圆圈 + 打开按钮）。
                    showDocumentPicker = true
                }
            )
        }
        // 系统文件选择器：由 SwiftUI 在正常主体层级 present，显示标准选择 UI。
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPickerView(
                onPick: { url in
                    if let content = try? String(contentsOf: url, encoding: .utf8) {
                        draftScript = content
                        if draftName.isEmpty {
                            draftName = SourceRuntime.parseScriptInfo(content)["name"] as? String
                                ?? url.deletingPathExtension().lastPathComponent
                        }
                        if let author = SourceRuntime.parseScriptInfo(content)["author"] as? String {
                            draftAuthor = author
                        }
                    }
                    showDocumentPicker = false
                    showAddSheet = true
                },
                onCancel: {
                    showDocumentPicker = false
                    showAddSheet = true
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
    @Binding var author: String
    var onPickFile: () -> Void

    @State private var platform = ""
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
                    Text("弹出系统文件选择器后，每个文件左侧有选择圆圈，选中变蓝，右上角点「打开」即可导入（.js / .txt 均可）。")
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
        author = ""
        importError = nil
    }

    private func save() {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            importError = "请粘贴或导入洛雪音源脚本"
            return
        }
        // 两种洛雪官方格式都接受：
        // 1) module.exports = {...} 老式导出；2) globalThis.lx user-api（on(EVENT_NAMES.request, ...)）。
        let isModuleStyle = trimmed.contains("module.exports")
        let isLxApiStyle = trimmed.contains("globalThis.lx") || trimmed.contains("lx.on")
            || trimmed.contains("EVENT_NAMES")
        guard isModuleStyle || isLxApiStyle else {
            importError = "脚本需为洛雪音源格式：以 module.exports 导出，或调用 globalThis.lx 注册 request 处理器"
            return
        }
        let info = SourceRuntime.parseScriptInfo(trimmed)
        let headerVersion = info["version"] as? String
        let source = MusicSource(
            name: name.isEmpty ? ((info["name"] as? String) ?? "未命名音源") : name,
            version: headerVersion ?? "1.0.0",
            platform: platform.isEmpty ? "custom" : platform,
            author: author.isEmpty ? ((info["author"] as? String) ?? "未知") : author,
            script: trimmed,
            enabled: true
        )
        store.addSource(source)
        resetDrafts()
        dismiss()
    }
}
