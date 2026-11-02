import SwiftUI

/// App 主题色预设：「我的」页可切换，持久化到 UserDefaults。
enum AppTheme: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, teal, blue, purple, pink

    var id: String { rawValue }

    var name: String {
        switch self {
        case .red: return "红色"
        case .orange: return "橙色"
        case .yellow: return "黄色"
        case .green: return "绿色"
        case .teal: return "青色"
        case .blue: return "蓝色"
        case .purple: return "紫色"
        case .pink: return "粉色"
        }
    }

    var color: Color {
        switch self {
        case .red: return Color(red: 250 / 255.0, green: 35 / 255.0, blue: 59 / 255.0) // Apple Music 红
        case .orange: return Color(red: 255 / 255.0, green: 149 / 255.0, blue: 0 / 255.0)
        case .yellow: return Color(red: 255 / 255.0, green: 204 / 255.0, blue: 0 / 255.0)
        case .green: return Color(red: 52 / 255.0, green: 199 / 255.0, blue: 89 / 255.0)
        case .teal: return Color(red: 64 / 255.0, green: 200 / 255.0, blue: 224 / 255.0)
        case .blue: return Color(red: 10 / 255.0, green: 132 / 255.0, blue: 255 / 255.0)
        case .purple: return Color(red: 191 / 255.0, green: 90 / 255.0, blue: 242 / 255.0)
        case .pink: return Color(red: 255 / 255.0, green: 55 / 255.0, blue: 148 / 255.0)
        }
    }

    static let defaultTheme: AppTheme = .red
}
