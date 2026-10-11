#!/bin/bash
# tune_params.sh — 时序参数调优（闭环优化环节）
# 方法：冷启动 N 轮，每轮：退出 QQ音乐 → trigger_wake 触发 App 内唤醒流程 →
#   测量「触发 → 出声」耗时；统计分布并给出 launchTimeout / readyDelay 推荐值。
# 只要求 AntiMusic.app 本身持有授权（测试终端免 TCC）。
# 用法: tests/tune_params.sh [轮数，默认5]

set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
N="${1:-5}"
RESULTS=()

compile_tool trigger_wake && compile_tool press_f8 && compile_poc audioprobe \
    || { record "env" "FAIL" "工具编译失败"; write_report "参数调优报告" "tuning"; exit 1; }

pkill -f "Music Decoy" 2>/dev/null
if ! app_running; then open "$APP_PATH" 2>/dev/null || true; sleep 4; fi
if ! app_running; then
    record "env" "FAIL" "AntiMusic.app 未运行且无法启动"
    write_report "参数调优报告" "tuning"; exit 1
fi

echo "══ 冷启动时序测量（$N 轮，经 App 内唤醒链）══"
TIMES=""
SUCC=0
for i in $(seq 1 "$N"); do
    pkill -TERM -x QQMusic 2>/dev/null; sleep 2
    if qqmusic_playing; then echo "  轮$i: QQ音乐未完全停止，跳过"; continue; fi
    local_t0=$(python3 -c 'import time; print(time.time())')
    "$BIN/trigger_wake" wake >/dev/null 2>&1
    ok=0
    iter=0
    while [ $iter -lt 66 ]; do
        if qqmusic_playing; then ok=1; break; fi
        sleep 0.3; iter=$((iter+1))
    done
    local_t1=$(python3 -c 'import time; print(time.time())')
    if [ "$ok" = "1" ]; then
        SUCC=$((SUCC+1))
        secs=$(python3 -c "print(f'{$local_t1 - $local_t0:.1f}')")
        TIMES="$TIMES $secs"
        echo "  轮$i: 成功 ${secs}s"
        record "trial-$i" "PASS" "冷启动→出声 ${secs}s"
    else
        echo "  轮$i: 失败(>20s)"
        record "trial-$i" "FAIL" "20s 内未出声（查 ~/Library/Logs/AntiMusic/wake.log）"
    fi
    sleep 2
done

SUMMARY=$(python3 - $TIMES <<'EOF' 2>/dev/null || echo "汇总计算失败（TIMES=$TIMES）"
import sys
vals = [float(x) for x in sys.argv[1:]] if len(sys.argv) > 1 else []
if not vals:
    print("无成功轮次，无法给出推荐（检查 App 授权与 QQ音乐快捷键配置）")
else:
    vals.sort()
    n = len(vals)
    p50 = vals[n // 2]
    p90 = vals[min(n - 1, int(n * 0.9))]
    print(f"成功 {n} 轮；中位 {p50:.1f}s，P90 {p90:.1f}s，最差 {max(vals):.1f}s")
    print(f"推荐：launchTimeout ≥ {max(vals) + 2:.0f}s（当前默认 5s）")
    print("推荐：readyDelay 1.5s 起步；若 P90 > 5s，说明 P1b 广播未生效（查看日志 inject 段确认生效手段），优先排查热键配置而非加大延迟")
EOF
)
echo ""
echo "$SUMMARY"
record "summary" "INFO" "$SUMMARY"

write_report "AntiMusic 参数调优报告" "tuning"
