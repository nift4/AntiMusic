#!/bin/bash
# run_all.sh — 闭环测试架构总入口
#   编译产物 → 状态机单元测试 → POC 套件 → 验收测试（自动部分）→ 汇总报告
#   授权缺失的测试会被门控为 SKIPPED 并给出指引；授权后重跑同一命令即自动化。
# 用法: tests/run_all.sh

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "══ ① 构建 App ══"
bash "$ROOT/tests/build_app.sh"

echo ""
echo "══ ② 状态机单元测试 ══"
TDIR="$(mktemp -d)"
cp "$ROOT/AntiMusic/WakeStateMachine.swift" "$TDIR/"
cp "$ROOT/tests/StateMachineTests.swift" "$TDIR/main.swift"
if swiftc "$TDIR/WakeStateMachine.swift" "$TDIR/main.swift" -o "$TDIR/smt" 2>&1 \
   && "$TDIR/smt"; then
    UNIT_RESULT=PASS
else
    UNIT_RESULT=FAIL
fi
echo "单元测试: $UNIT_RESULT"

echo ""
echo "══ ③ POC 套件 ══"
bash "$ROOT/tests/run_poc_suite.sh"

echo ""
echo "══ ④ 验收测试（自动部分）══"
bash "$ROOT/tests/acceptance.sh" --auto-only

echo ""
echo "闭环完成。报告见 reports/latest-*.md"
echo "下一步：按报告中的 SKIPPED 项授权（辅助功能/输入监控），重跑本命令即全自动化；"
echo "        QQ音乐升级后同样重跑，重新生成注入手段实测结论表。"
