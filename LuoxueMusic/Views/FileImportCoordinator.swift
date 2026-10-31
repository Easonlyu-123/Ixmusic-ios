import UIKit
import UniformTypeIdentifiers

/// 用命令式方式直接在当前最上层 VC 上 present 系统文档选择器。
///
/// 之前把 UIDocumentPickerViewController 交给 SwiftUI 的 sheet / fullScreenCover 承载，
/// 或由「被 sheet present 出来的 VC」再 present 一次，都会形成双层 present，导致选中文件后
/// 回调经常不触发（点文件没反应）。这里改为运行时找到真正的 topMost VC，由 UIKit 直接 present，
/// 完全绕开 SwiftUI 的弹窗调度，最稳定可靠。
@MainActor
final class FileImportCoordinator: NSObject {

    static let shared = FileImportCoordinator()

    private var picker: UIDocumentPickerViewController?
    private var onPick: ((String, String) -> Void)?
    private var onCancel: (() -> Void)?

    /// 弹出文件选择器。选中后回传 (脚本内容, 文件名)；取消或出错则走 onCancel。
    /// 选择器会呈现在当前最上层 VC 之上（例如正在显示的导入面板），选完关闭后下层面板仍在，
    /// 可直接把内容回填进去。
    func present(onPick: @escaping (String, String) -> Void, onCancel: @escaping () -> Void) {
        self.onPick = onPick
        self.onCancel = onCancel

        guard let top = topViewController() else {
            onCancel()
            cleanup()
            return
        }

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data, .plainText])
        picker.allowsMultipleSelection = false
        picker.delegate = self
        self.picker = picker
        top.present(picker, animated: true)
    }

    private func topViewController() -> UIViewController? {
        let windowScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let activeScene = windowScenes.first { $0.activationState == .foregroundActive }
            ?? windowScenes.first
        guard let scene = activeScene else { return nil }
        let window = scene.windows.first { $0.isKeyWindow } ?? scene.windows.first
        // 必须 present 在【根 VC】上：若叠在 SwiftUI 的 sheet（UISheetPresentationController）
        // 之上，底层面板会拦截“点文件”的手势，导致选不中。先关掉面板、再从根 VC 弹，
        // 选择器才是真正的顶层，点选才会触发回调。
        return window?.rootViewController
    }

    private func cleanup() {
        picker = nil
        onPick = nil
        onCancel = nil
    }
}

extension FileImportCoordinator: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else {
            controller.dismiss(animated: false)
            onCancel?()
            cleanup()
            return
        }
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
