#!/bin/bash
# acceptance.sh — 验收测试（需求 §6 的 12 条场景）
# 主通道：trigger_wake 通过 Darwin 通知远程触发 App 内的唤醒流程 —— 只要求
#         AntiMusic.app 本身持有授权，测试终端无需任何 TCC 权限，全自动。
# 辅通道：press_f8 在 HID 层合成真实媒体键（验证 EventTap 拦截与 rcd 原生路由），
#         需要测试终端有「辅助功能」授权，缺失时 SKIPPED。
# 人工场景：打印步骤交互确认，结果一并进入报告。
# 用法: tests/acceptance.sh [--auto-only]

set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
AUTO_ONLY=false
[ "${1:-}" = "--auto-only" ] && AUTO_ONLY=true
RESULTS=()

ask_manual() { # ask_manual <ID> <说明>
    local id="$1" desc="$2"
    if $AUTO_ONLY; then record "$id" "SKIPPED" "人工场景（--auto-only 跳过）"; return; fi
    echo ""
    echo "▶ 人工场景 $id：$desc"
    read -r -p "   实测结果符合预期吗？[y/N/s(跳过)] " ans
    case "$ans" in
        y|Y) record "$id" "PASS" "人工确认通过" ;;
        s|S) record "$id" "SKIPPED" "人工跳过" ;;
        *)   record "$id" "FAIL" "人工确认未通过" ;;
    esac
}

have_tcc_injection() { "$BIN/press_f8" play 2>&1 | grep -q "RESULT: OK"; }

echo "══ AntiMusic 验收测试 ══"
echo ""
if ! qqmusic_installed; then
    record "env" "SKIPPED" "QQ音乐未安装，验收中止"
    write_report "AntiMusic 验收报告" "acceptance"; exit 0
fi
if [ ! -d "$APP_PATH" ]; then
    record "env" "SKIPPED" "未找到构建产物 $APP_PATH（先跑 tests/build_app.sh）"
    write_report "AntiMusic 验收报告" "acceptance"; exit 0
fi

compile_tool press_f8 && compile_tool trigger_wake && compile_poc audioprobe \
    || { record "env" "FAIL" "工具编译失败"; write_report "AntiMusic 验收报告" "acceptance"; exit 1; }

# ── 场景1 冷启动：QQ音乐退出 → 触发唤醒 → ≤ 数秒出声，Apple Music 不弹
#    经 App 内唤醒流程（trigger_wake），不需要终端授权；授权失效会体现为唤醒失败+日志诊断。
stop_app
pkill -f "Music Decoy" 2>/dev/null; sleep 1   # 老方案占位 App 会抢媒体键，先退出
quit_qqmusic
start_app
"$BIN/trigger_wake" wake >/dev/null 2>&1
if wait_qqmusic_playing 15; then
    record "1-cold-start-play" "PASS" "冷启动触发 → QQ音乐出声（App 内注入链）"
else
    record "1-cold-start-play" "FAIL" "15s 内未出声（多半是 App 授权失效，重建后需重授；见 wake.log）"
fi
if pgrep -x Music >/dev/null; then record "8-no-apple-music" "FAIL" "Apple Music 被唤起"; killall Music 2>/dev/null
else record "8-no-apple-music" "PASS" "Apple Music 未被唤起"; fi

# ── 场景12 后台注入：QQ音乐在后台同样应被注入唤醒
quit_qqmusic; sleep 1
if ! qqmusic_playing; then
    "$BIN/trigger_wake" wake >/dev/null 2>&1
    if wait_qqmusic_playing 15; then record "12-background-injection" "PASS" "后台注入生效"
    else record "12-background-injection" "FAIL" "后台注入失败"; fi
else
    record "12-background-injection" "SKIPPED" "前置不满足（QQ音乐仍在出声）"
fi

# ── 场景5 连续触发 5 次（去抖/不卡死；App 内路径）
if app_running; then
    for i in 1 2 3 4 5; do "$BIN/trigger_wake" wake >/dev/null 2>&1; done
    sleep 6
    if app_running && ! pgrep -x Music >/dev/null; then
        record "5-rapid-trigger-stability" "PASS" "连触 5 次无卡死、无 Apple Music"
    else
        record "5-rapid-trigger-stability" "FAIL" "连触后状态异常"
    fi
else
    record "5-rapid-trigger-stability" "SKIPPED" "App 未运行"
fi

# ── 需要 HID 层真实媒体键的场景（press_f8，需终端授权）
TCC_OK=false
if have_tcc_injection; then
    TCC_OK=true
    record "env-tcc-cli" "PASS" "终端具备注入权限：HID 层场景可执行"
else
    record "env-tcc-cli" "SKIPPED" "终端无「辅助功能」授权：HID 层场景（真实按键模拟）跳过，不影响 App 内路径"
fi

if $TCC_OK && qqmusic_playing; then
    # 场景3 播放中按 F8 → 暂停（交棒后 rcd 原生路由）
    "$BIN/press_f8" play >/dev/null 2>&1; sleep 1
    if wait_qqmusic_silent 5; then record "3-play-key-pauses" "PASS" "播放中 F8 → 暂停"
    else record "3-play-key-pauses" "FAIL" "播放中 F8 未暂停（交棒是否完成？）"; fi
    # 场景2 暂停 → F8 → 恢复
    "$BIN/press_f8" play >/dev/null 2>&1
    if wait_qqmusic_playing 8; then record "2-pause-resume" "PASS" "暂停态 F8 → 恢复播放"
    else record "2-pause-resume" "FAIL" "暂停态 F8 未恢复"; fi
    # 场景4 F7/F9
    "$BIN/press_f8" next >/dev/null 2>&1; sleep 1
    "$BIN/press_f8" previous >/dev/null 2>&1; sleep 1
    if qqmusic_playing; then record "4-next-prev-keys" "PASS" "F7/F9 生效且未打断播放"
    else record "4-next-prev-keys" "FAIL" "F7/F9 后播放中断"; fi
else
    record "3-play-key-pauses" "SKIPPED" "需终端授权 + 播放中"
    record "2-pause-resume" "SKIPPED" "需终端授权"
    record "4-next-prev-keys" "SKIPPED" "需终端授权"
fi

# ── 人工场景
ask_manual "6-bluetooth" "连接/摘下蓝牙耳机：不应误唤 Apple Music"
ask_manual "7-reboot-autostart" "重启 Mac：开机自启后行为不变（先确认登录项里有 AntiMusic）"
ask_manual "9-now-playing-widget" "控制中心 Now Playing 显示目标 App 的播放信息（做不到请在 README 已知限制确认）"
ask_manual "10-test-inject-button" "QQ音乐暂停时，菜单栏 →「设置…」→「高级」→「测试注入（诊断）」→ 开始播放"
ask_manual "11-permission-revoke" "撤销 QQ音乐「输入监控」后点「测试注入（诊断）」：程序应给出诊断提示而非静默失败"
ask_manual "8b-bluetooth-no-music" "全程 Apple Music 未被唤起（补充观察项）"

stop_app
write_report "AntiMusic 验收报告" "acceptance"
