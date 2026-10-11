#!/bin/bash
# build_app.sh — 构建 Debug 版 AntiMusic.app 到 build/ 目录（供测试套件使用）
# 签名策略：优先用稳定自签身份 "AntiMusic Local Dev"（专用钥匙串 antimusic-build，
#   创建方法见 docs/TESTING.md）做构建后重签——TCC 授权按证书（而非内容哈希）识别，
#   重建不再导致授权失效。无该身份时退回 ad-hoc（重建后需重授权）。
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build"
IDENTITY="AntiMusic Local Dev"
HASH=$(security find-identity -v -p codesigning 2>/dev/null | grep "$IDENTITY" | awk '{print $2}' | head -1 || true)

xcodebuild -project "$ROOT/AntiMusic.xcodeproj" -scheme AntiMusic -configuration Debug \
    build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
    CONFIGURATION_BUILD_DIR="$OUT" -quiet "$@"

if [ -n "$HASH" ]; then
    security unlock-keychain -p antimusic-dev-keychain antimusic-build.keychain-db 2>/dev/null || true
    if codesign --force --sign "$HASH" "$OUT/AntiMusic.app" 2>/dev/null; then
        echo "已用稳定签名身份重签: $IDENTITY ($HASH)"
    else
        codesign --force --sign - "$OUT/AntiMusic.app"
        echo "警告: 稳定身份签名失败，已回退 ad-hoc（重建后 TCC 授权会失效）"
    fi
else
    echo "警告: 未找到稳定签名身份，使用 ad-hoc（重建后 TCC 授权会失效，详见 docs/TESTING.md）"
fi
echo "构建完成: $OUT/AntiMusic.app"
