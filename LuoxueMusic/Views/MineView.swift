import SwiftUI

/// 「我的」页：音源管理入口、主题颜色设置、关于信息。
struct MineView: View {
    @EnvironmentObject private var store: AppStore

    private let columns = [GridItem(.adaptive(minimum: 64), spacing: 14)]

    var body: some View {
        NavigationStack {
            List {
                // 音源管理（原底部「音源」Tab 的功能整体挪到这里）。
                Section("音源") {
                    NavigationLink {
                        SourcesView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "server.rack")
                                .foregroundStyle(store.accentColor)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("音源管理")
                                    .font(.body.weight(.medium))
                                Text("已导入 \(store.sources.count) 个音源")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                // 主题颜色设置。
                Section {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(AppTheme.allCases) { theme in
                            themeSwatch(theme)
                        }
                    }
                    .padding(.vertical, 6)
                } header: {
                    Text("主题颜色")
                } footer: {
                    Text("当前主题：\(store.accentTheme.name)。主题色会应用到整个 App（标签栏、播放页、收藏等）。")
                }

                // 关于。
                Section("关于") {
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundStyle(store.accentColor)
                            .frame(width: 28)
                        Text("版本")
                        Spacer()
                        Text("v\(AppInfo.appVersion)（构建 \(AppInfo.buildNumber)）")
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    }
                    HStack {
                        Image(systemName: "music.note")
                            .foregroundStyle(store.accentColor)
                            .frame(width: 28)
                        Text("关于本 App")
                        Spacer()
                        Text("洛雪音乐 · iOS")
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("我的")
        }
    }

    /// 主题色圆形色块，选中态带主题色描边与对勾。
    private func themeSwatch(_ theme: AppTheme) -> some View {
        let isSelected = store.accentTheme == theme
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                store.setAccentTheme(theme)
            }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(theme.color)
                        .frame(width: 40, height: 40)
                        .shadow(color: theme.color.opacity(0.4), radius: 5, y: 2)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                Text(theme.name)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("主题颜色 \(theme.name)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
