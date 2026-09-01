#!/bin/bash
# ============================================================================
# ImmortalWrt 一键编译脚本（本地工作区专用）
#   - 内存临时盘：默认使用 /dev/shm（系统自带 tmpfs，零 sudo），把 OpenWrt 的
#                 tmp/ 符号链接到内存盘，TMPDIR 同步指向（可选 --ram-build-dir 把
#                 build_dir 也放内存，更快但重启/清空后需全量重编）
#   - ccache：使用家目录缓存（默认 ~/.cache/ccache，自动开启 CONFIG_CCACHE=y）
#   - 报错收集：编译结束从日志抽取错误行，生成 errors-*.txt 与构建摘要
#   - 产物推送：镜像/校验/清单/日志复制到 eDisk 新建文件夹
#   - 全程默认不需要 sudo；仅当检测到旧版脚本残留的 sudo 挂载时，清理会要一次 sudo
#
# 用法：
#   bash build-ax6.sh                 # 常规编译
#   bash build-ax6.sh --dry-run       # 只打印将执行的动作，不真正编译/推送
#   bash build-ax6.sh --no-ram        # 不用内存盘
#   bash build-ax6.sh --ram-build-dir # build_dir 也放内存（注意全量重编）
#   bash build-ax6.sh --no-push       # 不推送 eDisk
#   bash build-ax6.sh --clean-ram     # 结束后恢复磁盘 tmp/build_dir（默认保留内存盘符号链接）
#   bash build-ax6.sh --help
# 环境变量（可覆盖）：
#   JOBS=8 RAM_ROOT=/dev/shm/xxx RAM_BUILD_DIR=1 CCACHE_DIR=/path EDISK_BASE=/path
# ============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOPDIR="$(cd "$SCRIPT_DIR" && pwd)"
cd "$TOPDIR"

# ---------------- 可调参数 ----------------
JOBS="${JOBS:-$(nproc)}"
RAM_ROOT="${RAM_ROOT:-/dev/shm/immortalwrt-build}"   # 内存盘根目录（默认系统 tmpfs）
RAM_BUILD_DIR="${RAM_BUILD_DIR:-0}"                  # 1 = build_dir 也上内存盘
CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/ccache}"
EDISK_BASE="${EDISK_BASE:-/home/ryanz/eDisk}"
NO_PUSH=0
DRY_RUN=0
CLEAN_RAM=0

usage() {
  sed -n '2,/^# ====/{s/^# \{0,1\}//;p}' "$0"
  exit 0
}
for arg in "$@"; do
  case "$arg" in
    --dry-run)       DRY_RUN=1 ;;
    --no-ram)        RAM_ROOT="" ;;
    --ram-build-dir) RAM_BUILD_DIR=1 ;;
    --no-push)       NO_PUSH=1 ;;
    --clean-ram)     CLEAN_RAM=1 ;;
    -h|--help)       usage ;;
  esac
done

# 打印并执行（dry-run 只打印）
run() {
  if [ "$DRY_RUN" = 1 ]; then echo "  [dry-run] $*"; else "$@"; fi
}
info() { echo "==> $*"; }

# ---------------- 1. 前置检查 ----------------
command -v make >/dev/null || { echo "错误: 缺少 make"; exit 1; }
[ -f .config ] || {
  echo "错误: .config 不存在。请先: cp docs/ax6-config.seed .config && make defconfig"
  exit 1
}
grep -q 'CONFIG_TARGET_qualcommax_ipq807x_DEVICE_redmi_ax6=y' .config \
  || echo "警告: .config 未选中 redmi_ax6（扩容）设备，将按当前配置编译"

# ---------------- 2. ccache（家目录缓存） ----------------
if command -v ccache >/dev/null; then
  mkdir -p "$CCACHE_DIR"
  export CCACHE_DIR
  info "ccache: $CCACHE_DIR ($(du -sh "$CCACHE_DIR" 2>/dev/null | cut -f1 | tr -d ' ') 已缓存)"
  if ! grep -q '^CONFIG_CCACHE=y' .config; then
    if [ "$DRY_RUN" = 1 ]; then
      echo "  [dry-run] 将向 .config 追加 CONFIG_CCACHE=y"
    else
      info "启用 CONFIG_CCACHE=y"
      sed -i '/^# CONFIG_CCACHE is not set$/d; /^CONFIG_CCACHE=/d' .config
      echo 'CONFIG_CCACHE=y' >> .config
    fi
  fi
else
  echo "警告: 未安装 ccache（建议 pacman -S ccache），继续使用无缓存编译"
fi

# ---------------- 3. 内存临时盘（/dev/shm，默认零 sudo） ----------------
cleanup_old_mount() {
  # 旧版脚本用 sudo 挂载了 tmpfs/bind，检测到则提示清理（一次性 sudo）
  if mountpoint -q "$TOPDIR/tmp"; then
    echo "==> 检测到旧版残留：tmp/ 仍被 sudo 挂载，清理需要一次 sudo 密码"
    run sudo umount "$TOPDIR/tmp" || true
  fi
  if mountpoint -q /mnt/immortalwrt-ram 2>/dev/null; then
    echo "==> 清理旧版残留挂载 /mnt/immortalwrt-ram"
    run sudo umount /mnt/immortalwrt-ram || true
  fi
}

ram_avail_mb=0
if [ -n "$RAM_ROOT" ]; then
  if [ -d /dev/shm ] && mountpoint -q /dev/shm 2>/dev/null; then
    ram_avail_mb=$(df -m /dev/shm 2>/dev/null | awk 'NR==2{print $4}'); ram_avail_mb="${ram_avail_mb:-0}"
  fi
  if [ "$ram_avail_mb" -le 1024 ]; then
    echo "警告: /dev/shm 不可用或过小(${ram_avail_mb}M)，回退到磁盘 tmp"
    RAM_ROOT=""
  fi
fi

if [ -z "$RAM_ROOT" ]; then
  [ "$DRY_RUN" = 1 ] || cleanup_old_mount
else
  info "内存临时盘: $RAM_ROOT（/dev/shm 可用 ${ram_avail_mb}M）"
  [ "$DRY_RUN" = 1 ] || cleanup_old_mount
  run mkdir -p "$RAM_ROOT/tmp"
  export TMPDIR="$RAM_ROOT/tmp"

  # tmp → 内存盘（符号链接，幂等）
  if [ -L "$TOPDIR/tmp" ] && [ "$(readlink "$TOPDIR/tmp")" = "$RAM_ROOT/tmp" ]; then
    info "tmp/ 已指向内存盘（符号链接已存在）"
  else
    if [ -e "$TOPDIR/tmp" ] && [ ! -L "$TOPDIR/tmp" ]; then
      info "现有磁盘 tmp/（可再生缓存）将被替换为内存盘符号链接"
      run rm -rf "$TOPDIR/tmp"
    fi
    run ln -sfn "$RAM_ROOT/tmp" "$TOPDIR/tmp"
    info "tmp/ -> $RAM_ROOT/tmp"
  fi

  # 可选：build_dir 也放内存
  if [ "$RAM_BUILD_DIR" = 1 ]; then
    if [ -L "$TOPDIR/build_dir" ] && [ "$(readlink "$TOPDIR/build_dir")" = "$RAM_ROOT/build_dir" ]; then
      info "build_dir/ 已在内存盘"
    else
      echo "注意: build_dir 上内存盘 = 丢弃磁盘增量，本次将全量重编（且重启后需重编）"
      if [ -e "$TOPDIR/build_dir" ] && [ ! -L "$TOPDIR/build_dir" ]; then
        run rm -rf "$TOPDIR/build_dir"
      fi
      run mkdir -p "$RAM_ROOT/build_dir"
      run ln -sfn "$RAM_ROOT/build_dir" "$TOPDIR/build_dir"
      info "build_dir/ -> $RAM_ROOT/build_dir"
    fi
  fi
fi

# ---------------- 4. 配置固化 ----------------
info "make defconfig（固化 .config，不编译）"
run make defconfig || { echo "错误: defconfig 失败"; exit 1; }

# ---------------- 5. 编译 ----------------
LOG_DIR="$TOPDIR/logs"; mkdir -p "$LOG_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/build-$STAMP.log"
ERR_FILE="$LOG_DIR/errors-$STAMP.txt"
if [ "$DRY_RUN" = 1 ]; then
  echo "  [dry-run] 将执行: make -j$JOBS V=s 2>&1 | tee ${LOG_FILE##*/}"
  BUILD_RC=0
  ERR_COUNT=0
else
  info "开始编译: make -j$JOBS V=s  (日志: ${LOG_FILE##*/})"
  set -o pipefail
  make -j"$JOBS" V=s 2>&1 | tee "$LOG_FILE"
  BUILD_RC=${PIPESTATUS[0]}
  set +o pipefail
  info "make 退出码: $BUILD_RC"

  # ---------------- 6. 收集报错 ----------------
  # 只抓真错误（make 失败/编译器报错），并排除 V=s 配方回显与已知可选提示噪音
  grep -inE "make\[[0-9]+\]: \*\*\*|error:|fatal error|undefined reference|No rule to make target|\
No space left on device|cannot (find|open|create) " "$LOG_FILE" \
    | grep -vE "for mod in|NOTICE:|patchelf: cannot find section|win32ole|Data not found|File exists" \
    > "$ERR_FILE" || true
  ERR_COUNT=$(wc -l < "$ERR_FILE")
fi
SUMMARY="$LOG_DIR/summary-$STAMP.txt"
{
  echo "构建时间: $(date '+%F %T')"
  echo "make 退出码: $BUILD_RC"
  [ "$DRY_RUN" = 1 ] && echo "（dry-run，未实际编译）"
  echo "错误行数: $ERR_COUNT"
  [ "$ERR_COUNT" -gt 0 ] && { echo "---- 错误摘录 ----"; head -40 "$ERR_FILE"; }
  echo "---- 产物 ----"
  ls -1 bin/targets/*/*/*.bin bin/targets/*/*/*.ubi bin/targets/*/*/*.itb 2>/dev/null
} > "$SUMMARY"
info "报错收集: $ERR_COUNT 行 -> ${ERR_FILE##*/}（摘要 ${SUMMARY##*/}）"

# ---------------- 7. 推送产物到 eDisk（新建文件夹） ----------------
if [ "$NO_PUSH" = 1 ]; then
  info "跳过 eDisk 推送（--no-push）"
else
  if [ -d "$EDISK_BASE" ]; then
    DEST="$EDISK_BASE/immortalwrt-redmi_ax6-$STAMP"
    info "推送产物 -> $DEST"
    run mkdir -p "$DEST"
    # 只推本次构建设备（.config 中 DEVICE_* 的镜像，排除 *-stock 变体）+ 校验/清单/配置 + 日志
    DEVICE=$(grep -oE "CONFIG_TARGET_[a-z0-9_]+_DEVICE_[a-z0-9_]+=y" .config | head -1 | sed 's/.*DEVICE_//; s/=y//')
    [ -n "$DEVICE" ] || DEVICE=redmi_ax6
    run bash -c "find bin/targets -maxdepth 3 -type f \( -name \"*-\$DEVICE-*\" -o -name \"*-\$DEVICE.*\" \) \
                 ! -name \"*stock*\" -exec cp -a {} \"$DEST\"/ \; 2>/dev/null || true"
    run bash -c "cp -a bin/targets/*/*/*.manifest bin/targets/*/*/*.buildinfo \
                 bin/targets/*/*/sha256sums bin/targets/*/*/profiles.json \"$DEST\"/ 2>/dev/null || true"
    run cp "$LOG_FILE" "$ERR_FILE" "$SUMMARY" "$DEST"/
    info "eDisk 推送完成: $DEST（设备 $DEVICE）"
  else
    echo "警告: eDisk 目录不存在 ($EDISK_BASE)，跳过推送"
  fi
fi

# ---------------- 8. 清理（--clean-ram：恢复磁盘 tmp/build_dir） ----------------
if [ "$CLEAN_RAM" = 1 ] && [ -n "$RAM_ROOT" ]; then
  info "恢复磁盘 tmp/ 与 build_dir/（--clean-ram）"
  [ -L "$TOPDIR/tmp" ] && { run rm -f "$TOPDIR/tmp"; run mkdir -p "$TOPDIR/tmp"; }
  [ -L "$TOPDIR/build_dir" ] && { run rm -f "$TOPDIR/build_dir"; run mkdir -p "$TOPDIR/build_dir"; }
  run rm -rf "$RAM_ROOT"
fi

echo
info "完成。退出码=$BUILD_RC，摘要: ${SUMMARY##*/}"
exit "$BUILD_RC"
