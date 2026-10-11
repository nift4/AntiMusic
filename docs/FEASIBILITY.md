# 可行性评估与实施方案

> 评估对象：《让媒体键（F8）在冷启动时直接唤醒 QQ音乐并开始播放》需求文档
> 评估日期：2026-10-02　|　实测环境：**macOS 27.0.1 (26A434) / arm64 (14v CPU) / Xcode 27.0 / QQ音乐 11.10.0 (com.tencent.QQMusicMac)**

## 一、结论（TL;DR）

**需求总体可行，但不能按原文照搬。** 决定性 POC 实测发现：在 macOS 27 上，原需求所依赖的 MediaRemote 私有 API「读取侧」已全面失效，AntiMusic 原版架构中「检测其他 App 开始播放 → 释放控制权」的机制（第 3 节步骤④⑥）在 macOS 27 上**不可用**。本方案用 **CoreAudio 公开 API 的进程音频检测**替代该机制（已 POC 实测通过），保留 fake player 作为防止 Apple Music 被唤起的占位手段，并以 **CGEventTap 直通媒体键**作为第一优先的事件拦截通道。主推的 P1「模拟 QQ音乐全局快捷键」方案本身成立，但其验证与运行依赖一次性用户授权（辅助功能 + 输入监控），这是 macOS 安全模型所决定的，任何实现都绕不开。

## 二、逐项 POC 实测记录

POC 脚本全部在 `poc/` 目录，可复跑（`tests/run_poc_suite.sh`）。

**★ 2026-10-02 17:25 实弹回归（用户授权后真实按键，日志 `~/Library/Logs/AntiMusic/wake.log`）**：
真实 F8 → EventTap 拦截成功（未触发 Apple Music）→ 冷启动 QQ音乐（0.27s）→ P1 定向 3 次投递 posted 但 **未触发播放** → P0 定向 3 次同样无效 → **P2 `qqmusicmac://qq.com/media/playRadio` 1.2s 内触发真实播放（CoreAudio 验证）→ 完整交棒（HandedOff）**。此轮同时修正早前误判：P2 的 playRadio URL 此前因 MediaRemote 观察通道失效而被误记为"未触发播放"，CoreAudio 判据下确认**有效**（副作用：播放默认电台内容，而非恢复上次歌曲）。

| # | 验证点 | 方法 | 实测结果 | 结论 |
|---|---|---|---|---|
| 1 | MediaRemote 私有框架符号存在性 | `CFBundleGetFunctionPointerForName` | `MRMediaRemoteGetNowPlayingClient` / `MRNowPlayingClientGetBundleIdentifier` / `MRMediaRemoteRegisterForNowPlayingNotifications` / `MRMediaRemoteSendCommand` 符号**均存在** | 符号在，行为受限（见 #2/#3） |
| 2 | now-playing 读取（无播放时） | `npq`（poc/npq.swift） | 返回空字符串 | — |
| 3 | now-playing 读取（有存活 fake player `.playing` 时） | `fakeplayer` + `npq` 双进程实测 | **仍返回空** | **读取 API 已对第三方失效（macOS 27）**。AntiMusic 原版 `loadSongInfo()` 永远检测不到交棒时机 |
| 4 | now-playing 变更通知 | `notifprobe` + `fakeplayer` 注册/退出 | **无任何通知触发** | 通知路径也失效 |
| 5 | `MRMediaRemoteSendCommand`（Play/Toggle） | `sendcmd` 向 fake player 发命令 | 命令发出无报错，fake player **未收到**（Apple Music 也未被唤起） | 发送侧同样受限，不能作为自动化测试驱动 |
| 6 | mediaremote-adapter（macOS 15.4+ 绕过通道） | 检查 `/usr/libexec/mediaremote-adapter` | **文件不存在**（macOS 27 已移除） | 绕过通道关闭 |
| 7 | **CoreAudio 进程音频检测**（公开 API，macOS 14.2+） | `audioprobe`：`kAudioHardwarePropertyTranslatePIDToProcessObject`('id2p') + `kAudioProcessPropertyIsRunningOutput`('piro') | afplay 播放中 `outputRunning=1`，结束后归 0；QQ音乐暂停时为 0。**全流程无需任何 TCC 权限** | ✅ **可行且已实测**。「QQ音乐是否真的在出声」有了免权限、免私有 API 的可靠判据；亦成为注入链的成功判据（实弹回归采用） |
| 8 | URL scheme（P2） | `open` 实测 + 实弹回归 | `qqmusicmac://` 能拉起 QQ音乐；**`playRadio` URL 实测可在 1.2s 内触发真实播放**（早前误判系观察通道失效）；`qqmusic://` 在 Mac 端无 handler | ✅ **条件有效**：能触发播放，但播放的是 URL 指定电台（默认场景下非"恢复上次歌曲"），且无法暂停 → 定位为兜底/降级手段 |
| 9 | AppleScript（P4） | 需自动化权限 | **未验证**（待授权后由测试套件自动重测） | 不作依赖 |
| 10 | P1 注入（组合键） | 实弹回归 + `--observe` 纯观察验证 | **变体结论分化**：`broadcast`（广播进 HID 事件流）**实测有效**（App 内 84ms / CLI 均可触发播放与暂停）；`targeted`（postToPid 定向）**无效**（posted 但 QQ音乐不响应——其全局热键经系统层分发，定向投递绕过了该路径，符合 3.5.4 风险点1 预警）。早期"定向重试 3 次失败"与此一致；期间"广播无效"的中间结论系 CoreAudio 检测滞后造成的误判（见 #13） | ✅ **P1b 广播有效**（主推方案落地）；定向无效已记录 |
| 11 | P0 定向媒体键（systemDefined postToPid） | 实弹回归 + `--observe` 纯观察验证 | **无效**：QQ 音乐播放态响应的媒体键来自 rcd 的 now-playing 通道，进程内并无直接媒体键 CGEvent 处理器 | ❌ 无效，保留在链尾作为其他 QQ 音乐版本的兼容尝试 |
| 12 | fake player 注册 + EventTap 拦截 | **实弹回归**：授权后 `MediaKeyTap: active`，真实 F8 被拦截（source=tap:16），Apple Music 未弹 | ✅ 通道A 完整工作 | 实测确认 |
| 13 | **检测器语义**（新发现） | `ax_toggle` 对照实验 | QQ音乐暂停后 **CoreAudio 输出流滞后归零**（保持静音输出一段时间再拆除），不能单独作为暂停判据；「播放控制」菜单 toggle 项标题（“暂停”=在播/“播放”=已停）是**瞬时无歧义**判据 | 检测策略分层：开始播放用 CoreAudio（0→1 即时）；暂停/翻转验证用 AX 菜单标题（`Injector.axReadPlaying`） |

环境事实：本会话宿主（ZCode.app）无辅助功能/输入监控/完全磁盘访问授权 → 合成按键类 POC 在会话内被 TCC 静默丢弃。这不是缺陷，是 macOS 安全模型；测试架构对此做了显式门控（见第四节）。

## 三、原方案的问题与修正

| 原需求设计 | 实测发现 | 修正 |
|---|---|---|
| 依赖「AntiMusic 私有 API 检测到播放 → 自动释放」（步骤④⑥） | macOS 27 上该 API 读取永远为空、通知不触发（POC #2/#3/#4） | **改用 CoreAudio `IsRunningOutput` 轮询**（POC #7 实测通过）判定「QQ音乐真的在出声」后主动释放 |
| fake player 作为唯一媒体键来源 | fake player 的**命令路由**在 macOS 27 未验证（读取侧已死，注册侧待验证） | **双通道**：CGEventTap 直通拦截（主）+ fake player（防 Apple Music 占位 + 兼容旧系统） |
| `Ready→Injecting` 用固定 `readyDelay=1.5s` | 冷启动延迟不稳（需求 3.5.4 也承认） | 就绪探测为主、固定延迟兜底：**CoreAudio 出声检测即成功判据**，`readyDelay` 仅作为注入前最低等待，参数可调 |
| 注入成功判据未定义 | — | 明确：注入后 5s 内 `IsRunningOutput(pid)==true` 即成功；否则按 `injectRetry` 重试、按注入链降级 |
| 「正在播放→原样转发给系统」（步骤③第三分支） | rcd 路由行为在新系统未验证 | EventTap 模式下**直接放行事件**（让 rcd 路由给正在播放的 QQ音乐）；fake player 模式下靠命令自然到达 |

## 四、实施方案（已按此实现）

```
                        ┌────────────────────────────────────────────┐
  F7/F8/F9 按下 ──────► │ 通道A: CGEventTap(HID, listen+filter)       │◄── 需 输入监控+辅助功能
                        │  QQ音乐在出声? ── 是 → 放行(系统路由给QQ音乐) │
                        │                └─ 否 → 吞掉事件 → WakeEngine │
  (若 Tap 不可用) ────► │ 通道B: fake player + MPRemoteCommandCenter   │◄── 无需权限（原 AntiMusic 机制）
                        └────────────────────────────────────────────┘
                                        │
                  WakeEngine 状态机: Idle→Launching→Ready→Injecting→HandedOff
                                        │
        注入链（逐级降级）: P1 热键postToPid → P0 媒体键postToPid → P2 URL scheme → P3 AX按播放键
                                        │
        成功判据: AudioActivityMonitor 轮询 QQ音乐 pid 的 IsRunningOutput（≤5s）
                                        │
        成功 → 释放控制权（清 fake player / 停 Tap 拦截）→ 交棒，媒体键自然归 QQ音乐
        QQ音乐退出/长时间无声 → 重新持有，回到 Idle
```

- 全部时序参数（launchTimeout/readyDelay/injectRetry/retryInterval/settleWindow/热键组合/注入链开关）持久化配置、可调。
- 权限自检启动即做，缺失时弹窗 + 跳转系统设置；**特别检测 QQ音乐本体的输入监控授权状态**（P1 生效前提，文档醒目说明）。
- 菜单栏：状态机状态显示、设置窗口、权限检查（唤醒与测试注入均收在设置窗口内）。

## 五、闭环开发-测试-优化架构

```
  poc/ ──单点技术验证──┐
  tests/ ──场景与验收──┤──► reports/（每次运行生成 JSON+MD 报告，含时间戳与参数）
  XCTest ──状态机纯逻辑──┤           │
  CI（GitHub Actions）──┘           ▼
                        参数调优 tests/tune_params.sh（冷启动 N 轮 → 推荐 readyDelay）
                                   │
                                   ▼
                        反馈进默认配置 → 下一轮回归 → （持续循环）
```

- **TCC 门控**：每个测试声明所需权限；缺权限 → 标记 `SKIPPED(no-permission)` 并输出精确的授权指引，而不是假通过/假失败。授权后同一命令即全自动。
- **报告留痕**：`reports/latest.md` + 历史归档，供跨版本（QQ音乐/macOS 升级后）回归对比。
- **注入链自描述**：`tests/run_poc_suite.sh` 每轮重测 P0–P4，QQ音乐升级后重新生成实测结论表。

## 六、剩余风险与未验证项（诚实清单）

1. ~~P1 注入实弹验证~~ **已完成且成功**：P1b 广播变体实测有效（App 内与 CLI 均可触发，`--observe` 纯观察验证），冷启动全程 1.9–2.3s（5 轮实测，达标 ≤3s）。
2. ~~fake player 命令路由在 macOS 27 是否存活~~ EventTap 通道A 已实测工作（真实 F8 被拦截并触发唤醒）。**rcd 在交棒后是否把媒体键路由给 QQ 音乐无法用合成事件验证**（rcd 监听在 IOKit HID 层之下，合成事件进不了其分发）——需实体按键确认；已内置转发兜底（`enableForwardWhenPlaying`）：命令到达但目标在播时，引擎自动转发（热键广播 → AX 菜单点击二级降级）实现 toggle，并用 AX 菜单标题验证翻转。
3. 实体 F8 的完整验收（播放中暂停/恢复、F7/F9、蓝牙场景）待用户实弹确认；合成事件覆盖不到的部分已在验收报告中标注。
4. macOS 14/15 兼容性：代码按系统探测降级（MediaRemote 可用时优先用原机制），未在旧系统实测，README 已声明。
5. ~~冷启动总耗时~~ **已达标**：P1b 广播提前到首试位 + verifyTimeout 3s 后，5 轮实测 1.9–2.3s（原 37.4s 问题的修复闭环完成）。
6. ~~"合成事件效力取决于发布进程"的中间结论~~ **已推翻**：该误判源于 CoreAudio 对暂停的检测滞后；用 AX 菜单标题（`--observe` 纯观察）重新验证后，广播投递从 App 与 CLI 发布均有效。检测器的分层语义见 #13。
