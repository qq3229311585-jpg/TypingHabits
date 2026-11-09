# TypingHabits

macOS 原生小 App(SwiftUI + CGEventTap):手动开始/结束,记录一段时间内的打字习惯与 Fn 语音时长,可视化并可导出 CSV/JSON。

- 打字:按键量、速度、节奏、退格率、出错键、常用键/词、快捷键、App 分布、鼠标点击
- 语音:监听 Fn 键,统计次数与时长(不含语音内容)
- 数据只存本机 `~/Library/Application Support/TypingHabits/`,不联网
- 需要「输入监控」权限;密码框等系统安全输入不会被记录

构建:`./build.sh`(需 Xcode 命令行工具),产出 `TypingHabits.app`。图标由 `make_icon.swift` 生成。
