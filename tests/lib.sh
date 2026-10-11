#!/bin/bash
# tests/lib.sh — 闭环测试架构的公共库：编译、TCC 门控、结果记录、报告生成。
# 约定：每个测试输出一行 RESULT: PASS|FAIL|SKIPPED(...)，由 runner 收集进 reports/。

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${BIN:-/tmp/antimusic-testbin}"
REPORT_DIR="${REPORT_DIR:-$ROOT/reports}"
QQMUSIC_BUNDLE="${QQMUSIC_BUNDLE:-com.tencent.QQMusicMac}"
APP_PATH="${APP_PATH:-$ROOT/build/AntiMusic.app}"
mkdir -p "$BIN" "$REPORT_DIR"

# ---------- 工具编译 ----------
compile_poc() { # compile_poc <name> -> $BIN/<name>
    local name="$1"
    if [ ! -x "$BIN/$name" ] || [ "$ROOT/poc/$name.swift" -nt "$BIN/$name" ]; then
        swiftc -O -o "$BIN/$name" "$ROOT/poc/$name.swift" 2> "$BIN/$name.build.log" || {
            echo "COMPILE FAIL: poc/$name.swift"; sed -n '1,5p' "$BIN/$name.build.log"; return 1; }
    fi
}
compile_tool() {
    local name="$1"
    if [ ! -x "$BIN/$name" ] || [ "$ROOT/tools/$name.swift" -nt "$BIN/$name" ]; then
        swiftc -O -o "$BIN/$name" "$ROOT/tools/$name.swift" 2> "$BIN/$name.build.log" || {
            echo "COMPILE FAIL: tools/$name.swift"; sed -n '1,5p' "$BIN/$name.build.log"; return 1; }
    fi
}

# ---------- 环境查询 ----------
qqmusic_pid() { pgrep -x QQMusic | head -1; }
qqmusic_installed() { [ -d /Applications/QQMusic.app ]; }
macos_version() { sw_vers -productVersion; }
qqmusic_version() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" /Applications/QQMusic.app/Contents/Info.plist 2>/dev/null; }
app_pids() { pgrep -fl "AntiMusic.app/Contents/MacOS" | awk '{print $1}'; }

# ---------- QQ音乐播放状态（CoreAudio，免权限） ----------
qqmusic_playing() { # 0=在出声 1=没有
    local pid; pid="$(qqmusic_pid)"
    [ -n "$pid" ] && "$BIN/audioprobe" "$pid" >/dev/null 2>&1
}

wait_qqmusic_playing() { # wait_qqmusic_playing <timeout_s> -> 0=出声
    local timeout="${1:-15}"
    local iters=$(( ${timeout%.*} * 3 + 3 ))   # 0.3s 步进
    local i=0
    while [ $i -lt $iters ]; do
        if qqmusic_playing; then return 0; fi
        sleep 0.3; i=$((i+1))
    done
    return 1
}

wait_qqmusic_silent() {
    local timeout="${1:-10}"
    local iters=$(( ${timeout%.*} * 3 + 3 ))
    local i=0
    while [ $i -lt $iters ]; do
        if ! qqmusic_playing; then return 0; fi
        sleep 0.3; i=$((i+1))
    done
    return 1
}

# ---------- 进程管理 ----------
app_pids() { pgrep -fl "AntiMusic.app/Contents/MacOS" | awk '{print $1}'; }
app_running() { [ -n "$(app_pids)" ]; }
start_app() {
    if ! app_running; then
        open "$APP_PATH" 2>/dev/null || true
        sleep 4
    fi
}
stop_app() { pkill -f "AntiMusic.app/Contents/MacOS" 2>/dev/null; sleep 1; }
quit_qqmusic() { pkill -TERM -x QQMusic 2>/dev/null; sleep 2; }

# ---------- 结果记录 ----------
RESULTS=()
record() { # record <ID> <PASS|FAIL|SKIPPED> <说明>
    RESULTS+=("$1|$2|$3")
    printf '%-6s %-28s %s\n' "$2" "$1" "$3"
}
record_result_line() { # 解析子进程输出的 RESULT: 行
    local id="$1" output="$2"
    local line
    line="$(echo "$output" | grep -m1 '^RESULT:')"
    if [ -z "$line" ]; then record "$id" "FAIL" "no RESULT line (crash?)"; return; fi
    local rest="${line#RESULT: }"
    local kind="${rest%%(*}"
    case "$kind" in
        PASS*) record "$id" "PASS" "${rest#PASS}" ;;
        SKIPPED*) record "$id" "SKIPPED" "${rest#SKIPPED}" ;;
        *) record "$id" "FAIL" "${rest#FAIL}" ;;
    esac
}

# ---------- 报告生成 ----------
write_report() { # write_report <title> <slug> ; RESULTS 数组 -> reports/<ts>-<slug>.md + .json
    local title="$1" slug="$2"
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local fname; fname="$(date '+%Y%m%d-%H%M%S')-$slug"
    {
        echo "# $title"
        echo ""
        echo "- 时间：$ts"
        echo "- 环境：macOS $(macos_version) $(uname -m) ｜ QQ音乐 $(qqmusic_version || echo '未安装') ($QQMUSIC_BUNDLE)"
        echo ""
        echo "| 结果 | 场景 | 说明 |"
        echo "|---|---|---|"
        for r in ${RESULTS[@]+"${RESULTS[@]}"}; do
            printf '%s\n' "$r" | awk -F'|' '{ printf "| %s | %s | %s |\n", $2, $1, $3 }'
        done
        echo ""
        for r in ${RESULTS[@]+"${RESULTS[@]}"}; do
            case "$r" in *'|PASS|'*) echo "PASS";; *'|FAIL|'*) echo "FAIL";; *'|SKIPPED|'*) echo "SKIP";; esac
        done | sort | uniq -c | awk '{printf "- %s %s\n", $1, ($2=="PASS"?"PASS":($2=="FAIL"?"FAIL":"SKIPPED（权限/环境门控，授权后重跑即自动化）"))}'
    } > "$REPORT_DIR/$fname.md"
    {
        printf '{"title":"%s","ts":"%s","macos":"%s","results":[' "$title" "$ts" "$(macos_version)"
        local first=1
        for r in ${RESULTS[@]+"${RESULTS[@]}"}; do
            local id res note
            id="$(printf '%s' "$r" | awk -F'|' '{print $1}')"
            res="$(printf '%s' "$r" | awk -F'|' '{print $2}')"
            note="$(printf '%s' "$r" | awk -F'|' '{print $3}')"
            [ $first -eq 1 ] || printf ','
            printf '{"id":"%s","result":"%s","note":"%s"}' "$id" "$res" "$note"
            first=0
        done
        printf ']}\n'
    } > "$REPORT_DIR/$fname.json"
    cp "$REPORT_DIR/$fname.md" "$REPORT_DIR/latest-$slug.md"
    cp "$REPORT_DIR/$fname.json" "$REPORT_DIR/latest-$slug.json"
    echo "报告: $REPORT_DIR/$fname.md"
}
