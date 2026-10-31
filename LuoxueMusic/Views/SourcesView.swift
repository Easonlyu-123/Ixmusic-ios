import SwiftUI
import UniformTypeIdentifiers

struct SourcesView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showAddSheet = false
    // 文件选择器用系统原生 UIDocumentPickerViewController（外层 fullScreenCover 触发），
    // 避免 SwiftUI .fileImporter 嵌在 sheet 内时「双重 present」导致弹不出 / 选中无响应。
    @State private var showFilePicker = false
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
                importError: $importError,
                onPickFile: {
                    // 关键：先关闭 import 弹窗，再（延迟）打开文件选择器，
                    // 避免 sheet 与文件选择器同时 present。
                    showAddSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        showFilePicker = true
                    }
                }
            )
        }
        .fullScreenCover(isPresented: $showFilePicker) {
            DocumentPicker(
                onPick: { content, filename in
                    draftScript = content
                    if draftName.isEmpty { draftName = filename }
                    importError = nil
                    showFilePicker = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showAddSheet = true
                    }
                },
                onCancel: {
                    showFilePicker = false
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

/// 系统原生文档选择器包装。直接 present UIDocumentPickerViewController，
/// 不依赖 SwiftUI .fileImporter，规避 sheet 嵌套冲突。
struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: (String, String) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data, .plainText])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIDocumentPickerViewControllerDelegate {
        let onPick: (String, String) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (String, String) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                let name = url.deletingPathExtension().lastPathComponent
                onPick(content, name)
            } catch {
                // 读取失败时不回填，由调用方决定后续处理
                onCancel()
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
