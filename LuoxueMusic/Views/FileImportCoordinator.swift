import UIKit
import UniformTypeIdentifiers

/// 用命令式方式在一个【独立的 UIWindow】上 present 系统文档选择器。
///
/// 关键修复：UIDocumentPickerViewController 必须 present 在“简单、独立”的视图层级上。
/// 直接 present 在 SwiftUI 的 hosting controller / TabView 这种复杂层级上时，选择文件后的
/// 回调经常不触发——表现就是“选择器能打开、能翻文件夹、但点文件没反应”。
/// 这是 UIKit 文档选择器的已知坑，社区公认解法是单独开一个全新 UIWindow 来承载它
/// （见 https://stackoverflow.com/questions/54234901 ，高赞解法即新建 window 再 present）。
@MainActor
final class FileImportCoordinator: NSObject {

    static let shared = FileImportCoordinator()

    private var picker: UIDocumentPickerViewController?
    private var pickerWindow: UIWindow?
    private var previousKeyWindow: UIWindow?
    private var onPick: ((String, String) -> Void)?
    private var onCancel: (() -> Void)?

    func present(onPick: @escaping (String, String) -> Void, onCancel: @escaping () -> Void) {
        self.onPick = onPick
        self.onCancel = onCancel

        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else {
            onCancel()
            return
        }

        // 记住当前 key window，关掉选择器后还原，避免影响主界面交互。
        previousKeyWindow = scene.windows.first { $0.isKeyWindow }

        // 全新 window：干净、简单的层级，文档选择器的回调才能稳定触发。
        let window = UIWindow(windowScene: scene)
        let base = UIViewController()
        base.view.backgroundColor = .clear
        window.rootViewController = base
        window.windowLevel = .alert
        window.makeKeyAndVisible()
        self.pickerWindow = window

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data, .plainText])
        picker.allowsMultipleSelection = false
        picker.delegate = self
        self.picker = picker
        base.present(picker, animated: true)
    }

    private func cleanup() {
        picker?.dismiss(animated: false)
        picker = nil
        pickerWindow?.isHidden = true
        pickerWindow = nil
        previousKeyWindow?.makeKey()
        previousKeyWindow = nil
        onPick = nil
        onCancel = nil
    }
}

extension FileImportCoordinator: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { cleanup(); return }
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let name = url.deletingPathExtension().lastPathComponent
            controller.dismiss(animated: false)
            onPick?(content, name)
        } catch {
            controller.dismiss(animated: false)
            onCancel?()
        }
        cleanup()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        controller.dismiss(animated: false)
        onCancel?()
        cleanup()
    }
}
