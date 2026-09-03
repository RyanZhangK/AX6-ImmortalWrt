#!/bin/sh
# ============================================================
# gen-config.sh — campnet 配置生成/同步工具
#
# 用法:
#   ./scripts/gen-config.sh init    由 .config.example 生成 .config（若不存在）
#   ./scripts/gen-config.sh apply   将 .config 同步为 root/etc/campnet/.config.default
#                                   （打包进固件/镜像的默认值）
#   ./scripts/gen-config.sh show    打印当前 .config（不打印密码以外的注释）
# ============================================================
set -e

BASE_DIR=$(cd "$(dirname "$0")/.." && pwd)
EXAMPLE="$BASE_DIR/.config.example"
CONFIG="$BASE_DIR/.config"
TARGET="$BASE_DIR/root/etc/campnet/.config.default"

err() { echo "gen-config: $*" >&2; exit 1; }

case "${1:-init}" in
    init)
        [ -f "$CONFIG" ] && { echo "gen-config: .config 已存在，跳过"; exit 0; }
        [ -f "$EXAMPLE" ] || err "缺少 .config.example"
        cp "$EXAMPLE" "$CONFIG"
        chmod 600 "$CONFIG"
        echo "gen-config: 已由 .config.example 生成 .config"
        ;;
    apply)
        [ -f "$CONFIG" ] || err "缺少 .config，请先执行 ./scripts/gen-config.sh init"
        mkdir -p "$(dirname "$TARGET")"
        cp "$CONFIG" "$TARGET"
        chmod 600 "$TARGET"
        echo "gen-config: .config 已同步 -> $TARGET"
        ;;
    show)
        [ -f "$CONFIG" ] || err "缺少 .config"
        sed -e 's/^\(CAMP_[A-Z_]*PASSWORD=\).*/\1"********"/' "$CONFIG"
        ;;
    *)
        err "用法: $0 {init|apply|show}"
        ;;
esac
