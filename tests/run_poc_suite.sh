#!/bin/bash
# run_poc_suite.sh — 单点技术验证套件（需求 §4 每种注入手段 + 环境基线）
# 用法: tests/run_poc_suite.sh
# 输出: reports/<ts>-poc-suite.md/.json + latest-poc-suite.md
# TCC 门控：注入类 POC 在宿主无「辅助功能」授权时输出 SKIPPED 与授权指引（不假通过）。

set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
RESULTS=()

echo "══ AntiMusic POC 套件 ══"
echo ""

# POC-0 环境基线
if compile_poc envcheck; then
    out="$("$BIN/envcheck" 2>&1)"; rc=$?
    if echo "$out" | grep -q "MediaRemote private framework"; then
        mr=$(echo "$out" | grep "current now-playing bundle id" | head -1)
        record "env-mediaRemote-symbols" "PASS" "符号存在；${mr}（macOS 27 读取恒空 → 新架构已绕开）"
    else
        record "env-mediaRemote-symbols" "FAIL" "envcheck 输出异常"
    fi
    record "env-tcc-of-host" "INFO-ONLY" "$(echo "$out" | grep -E 'AXIsProcessTrusted|CGPreflightListen' | tr '\n' ' ')"
else
    record "env-mediaRemote-symbols" "FAIL" "envcheck 编译失败"
fi

# 检测器
if compile_poc audioprobe; then
    "$BIN/audioprobe" >/dev/null 2>&1
    rc=$?
    [ $rc -eq 0 ] && record "audioprobe-coreaudio" "PASS" "进程音频检测可用（免权限）" || record "audioprobe-coreaudio" "FAIL" "CoreAudio 查询失败 rc=$rc"
else
    record "audioprobe-coreaudio" "FAIL" "编译失败"
fi

# QQ音乐 URL scheme（P2）
if qqmusic_installed; then
    open 'qqmusicmac://today?mid=31&k1=2&k4=0' 2>/dev/null && sleep 3
    if [ -n "$(qqmusic_pid)" ]; then
        record "p2-urlscheme-launch" "PASS" "qqmusicmac:// 能拉起 QQ音乐（无播放触发，见可行性报告#8）"
    else
        record "p2-urlscheme-launch" "FAIL" "URL scheme 未能拉起"
    fi
else
    record "p2-urlscheme-launch" "SKIPPED" "QQ音乐未安装"
fi

# P1 模拟全局快捷键（主推）——两条验证路径：
#  A) CLI 广播投递：实测有效（验证必须用 --observe 纯观察；早期误判源于 CoreAudio
#     对暂停的检测滞后，见 docs/FEASIBILITY.md #13）
#  B) App 内广播（产品真实路径）：退出 QQ音乐 → trigger_wake 触发 App 唤醒链 →
#     ax_toggle --observe 观察到播放 = P1 生效
if compile_poc inject_hotkey && compile_poc ax_toggle; then
    "$BIN/ax_toggle" --set paused >/dev/null 2>&1
    "$BIN/inject_hotkey" --force >/dev/null 2>&1   # 广播投递（CLI 上下文）
    out="$("$BIN/ax_toggle" --observe playing --wait 6 2>&1)"
    record_result_line "p1-hotkey-cli-post" "$out"
else
    record "p1-hotkey-cli-post" "FAIL" "编译失败"
fi

if compile_tool trigger_wake && compile_poc ax_toggle; then
    pkill -TERM -x QQMusic 2>/dev/null; sleep 2
    "$BIN/trigger_wake" wake >/dev/null 2>&1
    QP=""
    for i in $(seq 1 20); do QP=$(pgrep -x QQMusic | head -1); [ -n "$QP" ] && break; sleep 0.5; done
    if [ -n "$QP" ]; then
        out="$("$BIN/ax_toggle" --pid "$QP" --observe playing --wait 10 2>&1)"
        record_result_line "p1-hotkey-app-mediated" "$out"
    else
        record "p1-hotkey-app-mediated" "FAIL" "QQ音乐未被唤醒"
    fi
else
    record "p1-hotkey-app-mediated" "FAIL" "编译失败"
fi

# P0 定向媒体键（TCC 门控）——CLI 投递，纯观察验证
if compile_poc inject_mediakey; then
    "$BIN/ax_toggle" --set paused >/dev/null 2>&1
    "$BIN/inject_mediakey" --force >/dev/null 2>&1
    out="$("$BIN/ax_toggle" --observe playing --wait 6 2>&1)"
    record_result_line "p0-mediakey-injection" "$out"
else
    record "p0-mediakey-injection" "FAIL" "编译失败"
fi

# P3 AX 菜单点击（独立的 toggle 能力验证）
if compile_poc ax_toggle; then
    out="$("$BIN/ax_toggle" --wait 4 2>&1)"
    record_result_line "p3-ax-toggle" "$out"
else
    record "p3-ax-toggle" "FAIL" "编译失败"
fi

# MRMediaRemoteSendCommand（已知受限，回归观察用）
if compile_poc sendcmd && compile_poc fakeplayer; then
    "$BIN/fakeplayer" 6 > "$BIN/fp.log" 2>&1 &
    FP=$!; sleep 2; "$BIN/sendcmd" play >/dev/null 2>&1; sleep 1
    recv=$(grep -c "RECEIVED" "$BIN/fp.log" || true)
    [ "$recv" -gt 0 ] && record "sendcmd-delivery" "PASS" "命令送达 fake player" || record "sendcmd-delivery" "SKIPPED" "macOS 27 实测受限：命令不送达（POC #5，架构不依赖）"
    kill $FP 2>/dev/null; wait $FP 2>/dev/null
fi

# now-playing 通知（已知失效，回归观察用）
if compile_poc notifprobe; then
    "$BIN/notifprobe" 5 > "$BIN/np.log" 2>&1 & NP=$!
    "$BIN/fakeplayer" 2 >/dev/null 2>&1
    sleep 6; kill $NP 2>/dev/null; wait $NP 2>/dev/null
    got=$(grep -c "GOT " "$BIN/np.log" || true)
    [ "$got" -gt 0 ] && record "nowplaying-notifications" "PASS" "通知可用（旧机制可启用）" || record "nowplaying-notifications" "SKIPPED" "macOS 27 实测失效（POC #4，架构不依赖）"
fi

write_report "AntiMusic POC 套件报告" "poc-suite"
