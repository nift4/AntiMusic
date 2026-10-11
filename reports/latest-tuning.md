# AntiMusic 参数调优报告

- 时间：2026-10-02 20:09:03
- 环境：macOS 27.0.1 arm64 ｜ QQ音乐 11.10.0 (com.tencent.QQMusicMac)

| 结果 | 场景 | 说明 |
|---|---|---|
| PASS | trial-1 | 冷启动→出声 2.3s |
| PASS | trial-2 | 冷启动→出声 2.3s |
| PASS | trial-3 | 冷启动→出声 2.0s |
| PASS | trial-4 | 冷启动→出声 1.9s |
| PASS | trial-5 | 冷启动→出声 2.3s |
| INFO | summary | 成功 5 轮；中位 2.3s，P90 2.3s，最差 2.3s |
|  | 推荐：launchTimeout ≥ 4s（当前默认 5s） |  |
|  | 推荐：readyDelay 1.5s 起步；若 P90 > 5s，说明 P1b 广播未生效（查看日志 inject 段确认生效手段），优先排查热键配置而非加大延迟 |  |

- 5 PASS
