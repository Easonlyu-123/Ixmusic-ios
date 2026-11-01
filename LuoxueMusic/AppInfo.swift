import Foundation

/// 集中读取 App 版本信息，供界面展示与产物核对。
enum AppInfo {
    /// 语义化版本号（如 1.0.3），取自 Info.plist 的 CFBundleShortVersionString
    static let appVersion: String = {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }()

    /// 构建号（CFBundleVersion）
    static let buildNumber: String = {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1"
    }()
}
