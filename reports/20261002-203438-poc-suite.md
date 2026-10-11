# AntiMusic POC 套件报告

- 时间：2026-10-02 20:34:38
- 环境：macOS 27.0.1 arm64 ｜ QQ音乐 11.10.0 (com.tencent.QQMusicMac)

| 结果 | 场景 | 说明 |
|---|---|---|
| PASS | env-mediaRemote-symbols | 符号存在；current now-playing bundle id: ''（macOS 27 读取恒空 → 新架构已绕开） |
| INFO-ONLY | env-tcc-of-host | AXIsProcessTrusted (Accessibility): true CGPreflightListenEventAccess (Input Monitoring): true  |
| PASS | audioprobe-coreaudio | 进程音频检测可用（免权限） |
| PASS | p2-urlscheme-launch | qqmusicmac:// 能拉起 QQ音乐（无播放触发，见可行性报告#8） |
| PASS | p1-hotkey-cli-post | (observed-playing) |
| PASS | p1-hotkey-app-mediated | (observed-playing) |
| FAIL | p0-mediakey-injection | (observe-timeout waiting for playing) |
| PASS | p3-ax-toggle | (ax-toggle-verified toggle paused→playing) |
| SKIPPED | sendcmd-delivery | macOS 27 实测受限：命令不送达（POC #5，架构不依赖） |
| SKIPPED | nowplaying-notifications | macOS 27 实测失效（POC #4，架构不依赖） |

- 1 FAIL
- 6 PASS
- 2 SKIPPED（权限/环境门控，授权后重跑即自动化）
