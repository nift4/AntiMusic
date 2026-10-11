# 闭环开发-测试-优化架构（docs/TESTING.md）

## 一、闭环总览

```
┌─────────────────────────── 一次迭代 ───────────────────────────┐
│                                                                │
│  ① 构建   tests/build_app.sh          → build/AntiMusic.app    │
│  ② 纯逻辑单元测试   StateMachineTests（35 断言，免环境）        │
│  ③ POC 套件   run_poc_suite.sh        → 注入手段逐项实测结论    │
│  ④ 验收套件   acceptance.sh           → 需求 §6 的 12 条场景    │
│  ⑤ 报告   reports/<ts>-*.md/.json + latest-*                   │
│  ⑥ 调优   tune_params.sh              → 实测推荐时序参数        │
│  ⑦ 回灌   调参写回设置（或改默认值）→ 回到 ①                     │
│                                                                │
└────────────────────────────────────────────────────────────────┘
一键入口：tests/run_all.sh
```

设计原则：

1. **门控而非假通过**：每个测试声明所需 TCC 权限；缺失时输出 `SKIPPED(no-xxx-permission)` 与精确授权指引。授权后**重跑同一条命令**即自动完成——闭环不因 macOS 安全模型而断裂。
2. **成功判据客观化**：一律以 **CoreAudio 出声检测**（`poc/audioprobe`）为准，不采信"事件已发送"这类返回值。
3. **报告留痕**：每次运行生成带时间戳的 Markdown + JSON，`latest-*` 固定指向最近一次；QQ音乐/macOS 升级后重跑即可对比回归。
4. **日志数据化**：App 运行日志 `~/Library/Logs/AntiMusic/wake.log` 记录状态机迁移与各阶段耗时，供 `tune_params.sh` 解析。

## 二、目录与职责

```
poc/                    单点技术验证（可独立编译运行的 Swift CLI）
  envcheck.swift          系统版本 / TCC / MediaRemote 符号与读取 / fake player 初始化
  npq.swift               now-playing 查询（回归观察：macOS 27 恒空）
  fakeplayer.swift        自制 now-playing 占位（配合 npq/notifprobe 做对照实验）
  sendcmd.swift           MRMediaRemoteSendCommand 发送（回归观察：macOS 27 不送达）
  notifprobe.swift        now-playing 变更通知监听（回归观察：macOS 27 不触发）
  audioprobe.swift        ★ CoreAudio 进程出声检测（成功判据的实现，免权限）
  inject_hotkey.swift     ★ P1 注入实弹验证（TCC 门控）
  inject_mediakey.swift   ★ P0 注入实弹验证（TCC 门控）

tools/
  press_f8.swift          虚拟手指：向 HID 层广播真实媒体键事件（TCC 门控）
                          —— 自动化 E2E 的驱动器，等价于用户按 F8

tests/
  lib.sh                  公共库：编译缓存 / 门控 / 结果记录 / 报告生成(MD+JSON)
  StateMachineTests.swift 状态机纯逻辑单元测试（35 断言）
  build_app.sh            构建 App 到 build/
  run_poc_suite.sh        需求 §4 各注入手段 + 环境基线的逐项实测
  acceptance.sh           需求 §6 的 12 条验收场景（自动+人工混合）
  tune_params.sh          冷启动 N 轮实测 → 时序参数推荐值
  run_all.sh              一键闭环入口

reports/                 测试报告（latest-*.md 为最新）
```

## 三、各测试的权限需求矩阵

| 测试 | AntiMusic.app | 测试终端 | 其他 | 无权限时的行为 |
|---|---|---|---|---|
| StateMachineTests | — | — | — | 全自动可跑 |
| envcheck / audioprobe / npq | — | — | — | 全自动可跑 |
| URL scheme 拉起 | — | — | — | 全自动可跑 |
| **acceptance 主通道**（trigger_wake） | ✅ 辅助功能+输入监控 | **无需任何授权** | QQ音乐热键已配置 | 唤醒失败 → 日志诊断 |
| acceptance HID 场景（press_f8：真实按键模拟，验证 EventTap/rcd 路由） | ✅ | ✅ 终端辅助功能 | — | SKIPPED + 指引 |
| **P1/P0 注入 POC**（CLI 直测注入） | — | ✅ 终端辅助功能 | QQ音乐热键已配置 | SKIPPED + 指引 |
| **tune_params** | ✅ | **无需任何授权** | — | 唤醒失败 → 日志诊断 |
| 人工场景（蓝牙/重启/小组件…） | — | — | 人 | 交互确认 |

> 架构要点：**只有 AntiMusic.app 需要授权**。测试脚本通过 Darwin 通知（`notify_post` → App 内 DistributedNotificationCenter）远程触发唤醒流程，替代了"终端合成按键"的传统做法——闭环从此不受终端权限约束。`tools/press_f8.swift` 保留用于验证 HID 层真实按键路径（EventTap 拦截 + rcd 原生路由）。

## 四、标准循环（QQ音乐升级 / macOS 升级 / 参数调整后）

```bash
# 1. 全量闭环
tests/run_all.sh

# 2. 看 SKIPPED：给宿主授权（辅助功能），给 QQ音乐授权（输入监控）
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"

# 3. 重跑（此时注入类全部自动化）
tests/run_all.sh

# 4. 时序参数调优（可选，改动 readyDelay 等后回归）
tests/tune_params.sh 5

# 5. 对比报告
diff reports/latest-poc-suite.md reports/上一轮-poc-suite.md
```

## 五、扩展约定

- **新增注入手段**：`Injector.swift` 增加方法枚举与实现 → `WakeConfig.enabledChain` 注册 → `tests/run_poc_suite.sh` 增加 POC 项 → 首跑生成实测结论写入 README 注入链表。
- **新增验收场景**：`acceptance.sh` 按 `record <ID> <结果> <说明>` 追加；能自动化的用 `trigger_wake` / `press_f8` 驱动，不能的走 `ask_manual`。
- **判断标准**：任何"通过"必须来自 CoreAudio 出声检测或系统状态（进程存在/无 Music 进程），禁止用注入函数的布尔返回值冒充成功。

## 六、稳定签名（一次配置，重建不再需要重新授权 TCC）

macOS 对 ad-hoc 签名的 App 按**内容哈希**记 TCC 授权——每次重建都会使授权失效。
本项目用自签证书身份 `AntiMusic Local Dev`（专用钥匙串 `antimusic-build`）解决：
TCC 改按证书识别，`tests/build_app.sh` 每次构建后自动用同一证书重签。

一次性搭建步骤（本机已完成，重装系统后重跑）：

```bash
CERTDIR="$HOME/Library/Application Support/AntiMusic/devcert"
mkdir -p "$CERTDIR"
# 1. 生成带 codeSigning EKU 的自签证书（10 年）
cat > "$CERTDIR/openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
[dn]
CN = AntiMusic Local Dev
[v3]
keyUsage = digitalSignature
extendedKeyUsage = codeSigning
basicConstraints = CA:false
EOF
openssl req -x509 -newkey rsa:2048 -keyout "$CERTDIR/key.pem" -out "$CERTDIR/cert.pem" \
  -days 3650 -nodes -config "$CERTDIR/openssl.cnf" -subj "/CN=AntiMusic Local Dev"
openssl pkcs12 -export -out "$CERTDIR/ident.p12" -inkey "$CERTDIR/key.pem" -in "$CERTDIR/cert.pem" \
  -password pass:antimusic -name "AntiMusic Local Dev"
# 2. 导入专用钥匙串（独立密码，避免动登录钥匙串）
security create-keychain -p antimusic-dev-keychain antimusic-build.keychain-db
security import "$CERTDIR/ident.p12" -k ~/Library/Keychains/antimusic-build.keychain-db \
  -P antimusic -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k antimusic-dev-keychain antimusic-build.keychain-db
security list-keychains -s ~/Library/Keychains/login.keychain-db ~/Library/Keychains/antimusic-build.keychain-db
# 3. 用户域信任该证书用于代码签名
security add-trusted-cert -p codeSign "$CERTDIR/cert.pem"
```

注意：同名身份只能存在一个（多处导入会导致 `codesign` 报 ambiguous）。签名指纹随证书固定：
`5E2D2C3C19AA67506E801B778D620B13322AA0F0`。
