# AI 协作规则

- 本项目用 [ios-ci-workflows](https://github.com/wenjinliuu/ios-ci-workflows) 编译和测试；本地不跑 Xcode。改完代码 push，读 Build & Test 的测试报告再修。
- 新功能必须带测试；能用逻辑测试验证的不写成 UI 测试；UI 测试按条件等待，不用 sleep 固定等。
- 删测试只有三种理由：功能已删除、和另一个测试完全重复、已被更便宜的测试覆盖；删测试、改断言的预期值都要在提交里写明理由。
- 涉及界面：本 App 是 iOS 26 Liquid Glass 风格，改动 UI 时保持 `.glassEffect` 等玻璃质感，并按工作流要求重录快照。
- 洛雪音乐的“自定义音源”保持原格式（洛雪 JS 源脚本），由 `LuoxueMusic/MusicSource/SourceRuntime.swift` 通过 JavaScriptCore 执行；不要改动音源脚本的解析契约。
- 部署只走 git → CI；不要引用中央仓库的 `@main`，用固定的提交加版本注释：`@<SHA> # v1.1.0`。
- 更多细节见 ios-ci-workflows 的 Skill：skills/ios-ci-workflows/SKILL.md。
