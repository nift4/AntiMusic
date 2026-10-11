# AntiMusic

在 macOS 上按下媒体键（F7/F8/F9）时，**唤醒你自己指定的音乐 App 并替你按下第一次播放**，而不是唤起 Apple Music。QQ 音乐出声后，媒体键自动交棒给系统正常路由。

基于 [nift4/AntiMusic](https://github.com/nift4/AntiMusic) 深度改造：新增 CGEventTap 直通拦截、注入式唤醒（模拟 QQ 音乐全局快捷键为主推）、CoreAudio 出声验证与闭环测试架构。

- 实测环境：**macOS 27.0.1 (arm64) · QQ音乐 11.10.0 · Xcode 27.0**
- 可行性依据与逐项 POC 实测结论：[docs/FEASIBILITY.md](docs/FEASIBILITY.md)
- 闭环测试架构说明：[docs/TESTING.md](docs/TESTING.md)

---

## ⚠️ 安装必读：三处权限，缺一不可

| 权限 | 授予给 | 在哪里 | 为什么 |
|---|---|---|---|
| **输入监控** | **AntiMusic** | 系统设置 → 隐私与安全性 → 输入监控 | 拦截媒体键（CGEventTap）、发送合成事件 |
| **辅助功能** | **AntiMusic** | 系统设置 → 隐私与安全性 → 辅助功能 | 向 QQ 音乐定向投递播放指令（postToPid / AX） |
| **输入监控** | **QQ音乐 本体** ★ | 系统设置 → 隐私与安全性 → 输入监控 | 让 QQ 音乐能收到它的「全局快捷键」——**最容易漏！缺了它的典型表现是"QQ 音乐启动了但就是不放歌"** |

程序启动时会自检前两项并弹窗引导；第三项无法用 API 直接读取，请这样自查：在 QQ 音乐 **设置 → 快捷键 → 启用全局快捷键** 绑定后，若 QQ 音乐**在任何前后台状态下**按该组合键都能控制播放 ⇒ 授权正常。

### 在 QQ 音乐里配置全局快捷键（主推方案的前提）

1. QQ 音乐 → 设置 → 快捷键 → 勾选「启用全局快捷键」
2. 给「播放/暂停」绑定一个组合键，**推荐 `⌘⌥P`**（AntiMusic 默认值，两端保持一致）
3. 避开系统占用：`⌘Space`（Spotlight/输入法）、`⌘⇧Space`（输入法切换）、`⌘,`、`⌘⌥Esc`
4. 在 AntiMusic「设置…」里录制**完全相同**的组合键

## 构建

```bash
# Xcode 打开 AntiMusic.xcodeproj，Cmd+R 直接运行
# 或命令行：
tests/build_app.sh        # 产物在 build/AntiMusic.app
```

## 使用

- 启动后常驻菜单栏（音符图标）。菜单显示状态机状态（Idle / Launching / Ready / Injecting / HandedOff）
- **冷启动**：QQ音乐未运行时按 F8 → 自动启动 + 注入播放
- **暂停恢复 / 播放暂停 / F7F9**：出声后媒体键全部由 QQ 音乐接管，与原生体验一致
- 设置「高级」页「**测试注入（诊断）**」：不按 F8 单独验证注入链路（排查权限/热键配置）
- 菜单栏「设置…」：「通用」页选音乐播放器、录播放快捷键、看权限状态、立即播放；「高级」页调注入链开关与时序参数
- 开机自启：沿用登录项机制，首次启动自动注册

## 注入链（按优先级自动降级，可在设置中开关）

| 优先级 | 手段 | 原理 | 实测结论（macOS 27 + QQ音乐 11.10.0，实弹回归） |
|---|---|---|---|
| P1 ★ | 模拟 QQ 音乐全局快捷键 | 组合键 CGEvent 投递。**变体顺序：广播(P1b) → 定向 privateState → 定向 hidSystemState** | **广播变体实测有效**（触发播放与暂停，App 内 84ms 命中）；定向投递无效（QQ 音乐全局热键经系统层分发，postToPid 定向事件绕过了该路径） |
| P0 | 定向系统媒体键 | NX systemDefined(subtype 8) 事件 `postToPid` | **实测无效**（QQ 音乐的媒体键来自 rcd now-playing 通道，进程内无直接处理器），留作其他版本兼容 |
| P2 | URL scheme | `qqmusicmac://qq.com/media/playRadio` | **实测有效**：1.2s 内触发真实播放。注意播放的是 URL 指定电台而非"恢复上次歌曲"，且无法暂停 → 作为 P1 之后的快速兜底 |
| P3 | AX 点击播放控制菜单 | Accessibility API 点击「播放控制」→「暂停/播放」 | **实测有效**（瞬时、可靠）；菜单标题同时是播放状态判据 |

实弹回归时间线（2026-10-02，日志与报告可查）：真实 F8 → tap 拦截 → 冷启动 QQ 音乐 0.27s → **P1b 广播首试命中（≤100ms 验证出声）→ 完整交棒**，全程 Apple Music 未被唤起。5 轮冷启动实测 1.9–2.3s（验收标准 ≤3s）。

成功判据不是"事件发出去了"，而是 **CoreAudio 检测到 QQ 音乐进程真实出声**（`kAudioProcessPropertyIsRunningOutput`，公开 API、免权限）。失败按 `injectRetry` 重试并逐级降级，全部失败则弹窗诊断。

## 架构：为什么和原版 AntiMusic 不一样

原版靠 MediaRemote 私有 API「读取 now-playing → 检测到别的 App 播放就释放」。**macOS 15.4+ 该读取接口对第三方收紧，macOS 27 实测读取恒为空、通知不触发、mediaremote-adapter 已移除**——原版在此系统上既拿不到播放状态也不会释放。改造后：

- **通道A（主）**：CGEventTap 在 HID 层拦截媒体键。目标在出声 → 事件放行（rcd 自然路由给 QQ 音乐）；未出声 → 吞掉事件并触发唤醒流程。Apple Music 因此不会被 rcd 拉起
- **通道B（兜底）**：原版 fake player + MPRemoteCommandCenter 保留（无需权限；同时是旧系统的防 Music 弹出占位）
- **出声检测**：CoreAudio 进程音频查询（替代失效的 MediaRemote 读取，已 POC 实测通过）
- **旧系统兼容**：启动时自探测 MediaRemote 读取是否可用，可用则自动启用原版释放逻辑

```
F7/F8/F9 ─► 通道A CGEventTap ─┬─ 目标在出声 → 放行 → rcd → QQ音乐
                             └─ 未出声 → 吞掉 → WakeEngine 状态机
F8 命令 ──► 通道B fake player ─┘        │
            Idle→Launching→Ready→Injecting→HandedOff
                                        │
        注入链 P1→P0→P2→P3，CoreAudio 出声=成功判据，settleWindow 防自触发
```

## 时序参数（设置界面可调，`tune_params.sh` 自动推荐）

| 参数 | 默认 | 说明 |
|---|---|---|
| launchTimeout | 5s | 等待 QQ 音乐进程出现 |
| readyDelay | 1.5s | 进程出现后注入前的最低等待 |
| injectRetry | 2 | 每种注入手段的重试次数 |
| retryInterval | 0.8s | 重试间隔 |
| verifyTimeout | 5s | 注入后等待出声的超时 |
| settleWindow | 3s | 交棒后的静默期（防自触发/抖动） |

## 排查指南

| 现象 | 最可能原因 |
|---|---|
| QQ 音乐启动了但不出声 | ① QQ 音乐本体没有「输入监控」授权（最常见）② 全局快捷键未绑定或与 AntiMusic 设置不一致 ③ 组合键被其他 App 占用 |
| 按 F8 毫无反应 | AntiMusic 没在运行/没开机自启；查看菜单栏图标与状态 |
| F8 弹出了 Apple Music | AntiMusic 未运行且无占位（装好并设自启即解决） |
| 注入后播放了但 F8 再按无反应 | 交棒未完成：查 `~/Library/Logs/AntiMusic/wake.log` 中 state 是否到 HandedOff |
| 日志位置 | `~/Library/Logs/AntiMusic/wake.log`（闭环测试脚本自动解析该日志） |

## 测试与持续优化

```bash
tests/run_all.sh          # 一键闭环：构建→单元测试→POC套件→验收→报告
tests/tune_params.sh 5    # 冷启动 5 轮实测，自动推荐时序参数
```

报告写入 `reports/`（Markdown + JSON）。部分测试依赖 TCC 授权，未授权时标记 SKIPPED 并给出指引，授权后重跑同一命令即全自动——详见 [docs/TESTING.md](docs/TESTING.md)。

## 已知限制

1. **合成媒体键测不了 rcd 路由**：`press_f8`/CLI 合成的媒体键事件进不了 rcd 的分发（rcd 监听在 IOKit HID 层之下），因此「播放中按 F8 = 暂停」只能用**实体按键**验证。作为兜底，App 内置转发机制（`enableForwardWhenPlaying`，默认开）：若 rcd 把命令路由给本程序的 fake player，引擎会自动向 QQ 音乐转发热键实现 toggle，并用出声→静默验证
2. macOS 27 上 fake player 的 rcd 命令路由未单独验证（合成事件无法测试，见上条）；通道A（EventTap）不依赖它
3. Now Playing 小组件在交棒前显示 AntiMusic 占位条目（原版行为，未破坏；快速展开控制中心可能同时看到占位与真实条目——原版已知限制）
4. 未签名/自签构建在系统重装后可能需要重新授权 TCC；使用稳定签名身份（docs/TESTING.md 第六节）后，重建不再影响授权
5. 本工程在 macOS 27 开发；macOS 14/15 走兼容路径（legacy MediaRemote）但未实测
6. P2 URL scheme 触发的是 URL 指定电台而非"恢复上次歌曲"，且无法暂停——仅在热键转发链全部失效时才会轮到
7. 原 App 图标致谢 [Music Decoy](https://github.com/FuzzyIdeas/MusicDecoy)

## License

MIT（沿用上游 nift4/AntiMusic）
