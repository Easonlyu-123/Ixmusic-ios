import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 用 UIViewControllerRepresentable 包装系统文档选择器，由 SwiftUI 在【正常主体层级】present。
///
/// 为什么不用命令式独立 UIWindow / 不用 .fileImporter：
/// - 命令式独立 window + 空 rootVC 承载时，选择器的导航栏与“小圆圈 + 打开按钮”经常不渲染
///   （表现就是能看到文件夹却选不中、没有任何选择 UI）。
/// - Apple 官方论坛确认 .fileImporter 在真实 iPhone 上会“无法选择文件 / sheet 不关闭 / 回调不触发”。
/// 用本 Representable 让 UIKit 正常 present，才能显示标准的圆圈选择 + 右上角“打开”按钮。
struct DocumentPickerView: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // asCopy: true —— 系统会把选中的文件复制进 App 沙盒，回调的 URL 指向沙盒副本，
        // 直接 String(contentsOf:) 读取即可，绕开 security-scoped 资源访问的坑。
        // .data 是 public.data 超类，.js / .txt 等均为其子类型，会正常显示且可选中；
        // 不写 UTType.javascript（部分 SDK 无此静态成员，会编译失败）。
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.data, .plainText],
            asCopy: true
        )
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first {
                onPick(url)
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
