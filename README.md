# 洛雪音乐 · iOS 版（Liquid Glass）

把开源音乐播放器「洛雪音乐 / LX Music」做成 iOS App：

- **液态玻璃（Liquid Glass）** 界面，基于 **iOS 26 + SwiftUI**，Xcode 26 编译；
- **自定义音源格式不变**——沿用洛雪的 JS 源脚本（`module.exports = {...}`），由 `JavaScriptCore` 在端上直接执行；
- 通过 [wenjinliuu/ios-ci-workflows](https://github.com/wenjinliuu/ios-ci-workflows) 这个工作流在 GitHub Actions（macOS runner）上**编译、测试、签名打包出 IPA**，本地不需要 Mac、不需要装 Xcode。

> ⚠️ 洛雪移动端官方明确「没有计划支持 iOS」。本项目是社区向的 iOS 重制，遵循洛雪相同的协议精神：**App 本身不内置任何平台的版权音频源**，所有音源由使用者自行导入，且应在 24 小时内清除版权数据。

---

## 1. 技术栈与工程

| 项 | 说明 |
| --- | --- |
| 语言 / UI | Swift 6 语言模式（兼容），SwiftUI |
| 系统 | iOS 26（部署目标 26.0），Liquid Glass 视觉 |
| 工程生成 | [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`project.yml` → `LuoxueMusic.xcodeproj`） |
| 音源运行时 | `JavaScriptCore`，执行洛雪格式 JS 源 |
| 播放 | `AVPlayer` + `AVAudioSession(.playback)`（支持后台播放） |
| 测试 | Swift Testing 逻辑测试 |

### 目录结构

```
.
├── project.yml                 # XcodeGen 工程定义
├── .ios-ci.yml                 # ios-ci-workflows 的 App 配置（工程名/签名/工具链）
├── .github/workflows/
│   ├── build-test.yml          # 入口：编译 + 测试（0 个 secrets）
│   └── testflight.yml          # 入口：签名打包上传 TestFlight（需 4 个 Apple secrets）
├── AGENTS.md                   # 给 AI 的协作规则
├── release-checklist.md        # TestFlight 发版验收清单
├── LuoxueMusic/
│   ├── App.swift               # @main 入口
│   ├── Info.plist
│   ├── Assets.xcassets/        # 颜色 / 图标占位（正式发布请用 App Icon 工作流生成 Liquid Glass 图标）
│   ├── Models/MusicModels.swift        # Song / MusicSource
│   ├── MusicSource/
│   │   ├── SourceRuntime.swift         # JavaScriptCore 执行洛雪音源
│   │   └── BuiltInDemoSource.swift     # 内置演示音源（仅用于验证，非真实版权源）
│   ├── Player/AudioPlayer.swift        # AVPlayer 封装
│   ├── Store/AppStore.swift            # 全局状态：搜索 / 播放 / 音源持久化
│   └── Views/                         # RootTabView / Search / Library / Sources / NowPlaying
└── LuoxueMusicTests/
    └── MusicSourceTests.swift          # Swift Testing 逻辑测试
```

---

## 2. 接入 ios-ci-workflows（一次性）

仓库已经把入口文件与配置准备好。你只需：

1. **准备一个自己的 GitHub 仓库**，把本目录内容（含隐藏文件 `.ios-ci.yml`、`.github/`）原样 push 上去。
2. **改 `.ios-ci.yml` 里的身份字段**：
   - `bundle_id`：改成你自己的（如 `com.yourname.luoxuemusic`）。注意 `project.yml` 里的 `PRODUCT_BUNDLE_IDENTIFIER` 也要同步改，否则 CI 校验不通过。
   - `scheme` / `project`：保持 `LuoxueMusic` / `LuoxueMusic.xcodeproj` 即可。
3. **XcodeGen 自动安装**：CI 的 `generate_command: xcodegen generate` 会自动拉取固定版本（2.46.0）的 XcodeGen，你不需要本地装。
4. push 到 `main` 或开 PR，**Actions → Build & Test** 就会开始：在 macOS runner 上生成工程、编译、跑逻辑测试，并给出测试报告（失败原因 / 无障碍问题）。

> 入口文件里的 `uses:` 固定引用了发布版 SHA `df71d6096d6d39ea799179cb2635703548b07ae0 # v1.1.0`，**不要改成 `@main`**（按工作流约定）。

---

## 3. 怎么得到 IPA

工作流分两档，按你有没有 Apple 开发者账号选择：

### 方案 A：只想验证能编译（无需 Apple 账号）
直接 push 即可。**Build & Test 不需要任何签名**就能编译 + 测试。它验证的是「代码能编过、测试能跑过」，但**不导出 IPA 文件**。

### 方案 B：真正产出可安装的签名 IPA（需要 Apple 开发者账号）
TestFlight 工作流负责签名打包并上传 TestFlight，最终产出可安装的 IPA：

1. 在 [Apple Developer](https://developer.apple.com) 注册 **$99/年** 的开发者账号。
2. 在 **App Store Connect** 新建一个 App（Bundle ID 与 `.ios-ci.yml` 的 `bundle_id` 一致）。
3. 在仓库 **Settings → Secrets and variables → Actions** 里添加 4 个 secrets：

   | Secret | 来源 |
   | --- | --- |
   | `APPLE_TEAM_ID` | developer.apple.com → Membership |
   | `APP_STORE_CONNECT_KEY_ID` | App Store Connect → 用户和访问 → 集成 → App Store Connect API → 生成（角色建议 Admin） |
   | `APP_STORE_CONNECT_ISSUER_ID` | 同一页面的 Issuer ID |
   | `APP_STORE_CONNECT_PRIVATE_KEY` | 下载的 `.p8` 文件全文（含首尾 `-----BEGIN/END-----` 两行） |

   > 不需要手动导出 `.p12` 或描述文件——CI 用 App Store Connect API Key + 自动签名，由 Xcode 云端管理证书。
4. **打一个 `v*` 标签**（`git tag v1.0.0 && git push --tags`），或手动在 Actions → TestFlight 运行。CI 会：核对 Apple 注册 → 跑完整测试 → 自动签名打包 → 上传 TestFlight → 开一个「发版验收」Issue。上传完成后即可在 TestFlight 里安装 IPA。
5. 想先**不签名不上传**只验证打包流程：手动运行 TestFlight 并勾选 `dry_run`。

---

## 4. 音源格式（保持不变）

音源就是一段**洛雪格式的 JS 脚本**，原样沿用，不做转换：

```js
const source = {
  name: '我的音源',
  version: '1.0.0',
  platform: 'myplatform',
  author: 'me',
  // 搜索：返回歌曲列表
  async musicSearch(query, page = 1, limit = 30) {
    const html = await request('https://example.com/search?q=' + encodeURIComponent(query))
    // 解析 html / json，返回 [{ songmid, songname, singer, albumname, interval }]
    return [...]
  },
  // 播放链接
  async getMusicUrl(musicInfo) {
    return { url: 'https://.../xxx.mp3' }
  },
  // 歌词（可选）
  async getLyric(musicInfo) {
    return { lyric: '[00:00.00]...' }
  }
}
module.exports = source
```

- `request(url, options?)` 是运行时注入的**同步**网络函数（`{ method, headers, body }`），对应洛雪音源里拉取各平台公开接口的用法。
- App 不内置任何音源文件；首次启动内置一个**演示音源**（返回一段公开示例音频，仅用于验证运行时）。
- 在 App 内「音源」页 → 右上角 `+」→ 粘贴上面的脚本即可导入；可启用 / 停用 / 删除。导入的音源以 JSON 形式保存在本地（`UserDefaults`）。

> 字段映射做了宽松兼容：`songname/name/title`、`singer/artist`、`albumname/album`、`songmid/id` 都能识别，保证大多数洛雪音源脚本无需改动即可使用。

---

## 5. 法律与免责

- 本 App 仅用于技术可行性的探索与研究，遵循洛雪项目协议：**禁止在违反当地法律法规的情况下使用**。
- App 不内置、不聚合任何平台的版权音频源；所有音源由使用者自行导入，使用产生的版权数据请于 24 小时内清除。
- 本项目非官方，与洛雪音乐原作者无关。

---

## 6. 本地开发（可选）

要在本地 Mac 上跑起来：

```bash
brew install xcodegen
xcodegen generate          # 由 project.yml 生成 LuoxueMusic.xcodeproj
open LuoxueMusic.xcodeproj # 需要 Xcode 26 + 一台 iOS 26 设备 / 模拟器
```

> 液态玻璃（Liquid Glass）是 iOS 26 的视觉特性，需 iOS 26 及以上系统才能看到完整效果。
