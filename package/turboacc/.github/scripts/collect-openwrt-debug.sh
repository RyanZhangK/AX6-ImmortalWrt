#!/usr/bin/env bash

set +e

OUT="${DEBUG_OUTPUT_PATH:-${GITHUB_WORKSPACE:-$(pwd)}/openwrt-debug}"
OPENWRT_ROOT="${OPENWRT_ROOT_PATH:-}"
JOB_STATUS="${JOB_STATUS:-unknown}"
MATRIX_TAG_BRANCHE="${MATRIX_TAG_BRANCHE:-unknown}"
MATRIX_COMPILE="${MATRIX_COMPILE:-unknown}"
TURBOACC_ROOT="${TURBOACC_PATH:-}"

mkdir -p \
  "$OUT/meta" \
  "$OUT/config" \
  "$OUT/patches" \
  "$OUT/rejects" \
  "$OUT/kernel-source" \
  "$OUT/logs"

COPY_ERRORS="$OUT/logs/copy-errors.log"
: > "$COPY_ERRORS"

log() {
  printf '%s\n' "$*" | tee -a "$OUT/logs/collector.log"
}

capture_cmd() {
  local dest="$1"
  shift
  {
    printf '$'
    printf ' %q' "$@"
    printf '\n\n'
    "$@"
  } > "$dest" 2>&1 || true
}

copy_file_to() {
  local src="$1"
  local dest="$2"
  if [ -f "$src" ]; then
    mkdir -p "$(dirname "$dest")"
    cp -a "$src" "$dest" 2>> "$COPY_ERRORS" || true
  fi
}

copy_dir_to() {
  local src="$1"
  local dest="$2"
  if [ -d "$src" ]; then
    mkdir -p "$(dirname "$dest")"
    cp -a "$src" "$dest" 2>> "$COPY_ERRORS" || true
  fi
}

copy_preserve_path() {
  local src="$1"
  local bucket="$2"
  local base="${3:-$OPENWRT_ROOT}"
  local rel="$src"

  if [ -n "$base" ] && [[ "$src" == "$base/"* ]]; then
    rel="${src#$base/}"
  else
    rel="${src#/}"
  fi

  if [ -f "$src" ]; then
    copy_file_to "$src" "$OUT/$bucket/$rel"
  elif [ -d "$src" ]; then
    copy_dir_to "$src" "$OUT/$bucket/$rel"
  fi
}

write_meta() {
  {
    echo "job_status=$JOB_STATUS"
    echo "matrix_tag_branche=$MATRIX_TAG_BRANCHE"
    echo "matrix_compile=$MATRIX_COMPILE"
    echo "github_workflow=${GITHUB_WORKFLOW:-}"
    echo "github_run_id=${GITHUB_RUN_ID:-}"
    echo "github_run_number=${GITHUB_RUN_NUMBER:-}"
    echo "github_job=${GITHUB_JOB:-}"
    echo "github_ref=${GITHUB_REF:-}"
    echo "github_sha=${GITHUB_SHA:-}"
    echo "github_workspace=${GITHUB_WORKSPACE:-}"
    echo "openwrt_root=$OPENWRT_ROOT"
    echo "turboacc_path=$TURBOACC_ROOT"
    date -u '+utc_time=%Y-%m-%dT%H:%M:%SZ'
  } > "$OUT/meta/github.txt"

  if [ -n "$OPENWRT_ROOT" ] && [ -d "$OPENWRT_ROOT" ]; then
    capture_cmd "$OUT/meta/openwrt-branch.txt" git -C "$OPENWRT_ROOT" branch --show-current
    capture_cmd "$OUT/meta/openwrt-commit.txt" git -C "$OPENWRT_ROOT" log -1 --decorate --oneline
    capture_cmd "$OUT/meta/openwrt-status.txt" git -C "$OPENWRT_ROOT" status --short
    capture_cmd "$OUT/meta/df.txt" df -h
    capture_cmd "$OUT/meta/openwrt-du.txt" du -h --max-depth=1 "$OPENWRT_ROOT"
    capture_cmd "$OUT/meta/build-dir-du.txt" du -h --max-depth=2 "$OPENWRT_ROOT/build_dir"

    if [ -f "$OPENWRT_ROOT/.config" ]; then
      grep '^CONFIG_LINUX_' "$OPENWRT_ROOT/.config" > "$OUT/meta/kernel-version.txt" 2>/dev/null || true
      grep '^CONFIG_TARGET_' "$OPENWRT_ROOT/.config" > "$OUT/meta/target-config.txt" 2>/dev/null || true
    fi
  else
    echo "OPENWRT_ROOT_PATH is not set or does not exist." > "$OUT/meta/openwrt-missing.txt"
  fi
}

collect_lightweight() {
  if [ -z "$OPENWRT_ROOT" ] || [ ! -d "$OPENWRT_ROOT" ]; then
    return
  fi

  copy_file_to "$OPENWRT_ROOT/.config" "$OUT/config/openwrt.config"
  copy_file_to "$OPENWRT_ROOT/include/version.mk" "$OUT/config/version.mk"
  copy_file_to "$OPENWRT_ROOT/add_turboacc.sh" "$OUT/patches/add_turboacc.sh"

  if [ -f "$OPENWRT_ROOT/scripts/diffconfig.sh" ]; then
    capture_cmd "$OUT/config/diffconfig.txt" bash -c "cd \"\$1\" && ./scripts/diffconfig.sh" _ "$OPENWRT_ROOT"
  fi

  if [ -d "$OPENWRT_ROOT/target/linux/generic" ]; then
    find "$OPENWRT_ROOT/target/linux/generic" -maxdepth 1 -type f -name 'config-*' -print0 |
      while IFS= read -r -d '' file; do
        copy_preserve_path "$file" "config"
      done

    find "$OPENWRT_ROOT/target/linux/generic" -maxdepth 1 -type d \( -name 'hack-*' -o -name 'pending-*' \) -print0 |
      while IFS= read -r -d '' dir; do
        copy_preserve_path "$dir" "patches"
      done

    capture_cmd "$OUT/logs/generic-patch-files.list" find "$OPENWRT_ROOT/target/linux/generic" -maxdepth 2 -type f
  fi

  copy_dir_to "$OPENWRT_ROOT/package/network/config/firewall4/patches" "$OUT/patches/package/network/config/firewall4/patches"
  copy_dir_to "$OPENWRT_ROOT/package/network/utils/nftables/patches" "$OUT/patches/package/network/utils/nftables/patches"
  copy_dir_to "$OPENWRT_ROOT/package/libs/libnftnl/patches" "$OUT/patches/package/libs/libnftnl/patches"

  if [ -n "$TURBOACC_ROOT" ] && [ -d "$TURBOACC_ROOT" ]; then
    copy_file_to "$TURBOACC_ROOT/version" "$OUT/patches/turboacc-version"
  fi
  copy_file_to "$OPENWRT_ROOT/package/turboacc/version" "$OUT/patches/openwrt-package-turboacc-version"

  copy_dir_to "$OPENWRT_ROOT/logs" "$OUT/logs/openwrt-logs"
  capture_cmd "$OUT/logs/package-dirs.list" find "$OPENWRT_ROOT/package" -maxdepth 4 -type d
  capture_cmd "$OUT/logs/target-linux-dirs.list" find "$OPENWRT_ROOT/target/linux/generic" -maxdepth 2 -type d
}

collect_rejects() {
  if [ -z "$OPENWRT_ROOT" ] || [ ! -d "$OPENWRT_ROOT" ]; then
    return
  fi

  find "$OPENWRT_ROOT" \
    -path "$OPENWRT_ROOT/dl" -prune -o \
    -path "$OPENWRT_ROOT/staging_dir" -prune -o \
    -type f \( -name '*.rej' -o -name '*.orig' \) -print0 |
    while IFS= read -r -d '' file; do
      copy_preserve_path "$file" "rejects"
    done
}

collect_kernel_source() {
  if [ -z "$OPENWRT_ROOT" ] || [ ! -d "$OPENWRT_ROOT/build_dir" ]; then
    log "No build_dir found; skip kernel source snapshot."
    return
  fi

  find "$OPENWRT_ROOT/build_dir" -mindepth 2 -maxdepth 4 -type d -name 'linux-[0-9]*' -print0 |
    while IFS= read -r -d '' src; do
      local_rel="${src#$OPENWRT_ROOT/}"
      safe_name="$(printf '%s' "$local_rel" | tr '/\\' '__')"
      archive="$OUT/kernel-source/${safe_name}.tar.gz"
      log "Collect kernel source: $local_rel"
      tar \
        --exclude-vcs \
        --exclude='*.o' \
        --exclude='*.ko' \
        --exclude='*.a' \
        --exclude='*.cmd' \
        --exclude='.*.cmd' \
        --exclude='.tmp_versions' \
        --exclude='modules.order' \
        --exclude='Module.symvers' \
        --exclude='vmlinux' \
        --exclude='vmlinux.*' \
        -czf "$archive" \
        -C "$(dirname "$src")" "$(basename "$src")" 2>> "$COPY_ERRORS" || true
    done
}

write_summary() {
  local reject_count kernel_archive_count openwrt_commit kernel_version

  reject_count="$(find "$OUT/rejects" -type f 2>/dev/null | wc -l | tr -d ' ')"
  kernel_archive_count="$(find "$OUT/kernel-source" -type f -name '*.tar.gz' 2>/dev/null | wc -l | tr -d ' ')"
  openwrt_commit="$(sed -n '3p' "$OUT/meta/openwrt-commit.txt" 2>/dev/null || true)"
  kernel_version="$(cat "$OUT/meta/kernel-version.txt" 2>/dev/null | tr '\n' ' ' || true)"

  {
    echo "## OpenWrt debug summary"
    echo
    echo "- Job status: $JOB_STATUS"
    echo "- Matrix: $MATRIX_TAG_BRANCHE / $MATRIX_COMPILE"
    echo "- OpenWrt commit: ${openwrt_commit:-unknown}"
    echo "- Kernel config: ${kernel_version:-unknown}"
    echo "- Reject/orig files: $reject_count"
    echo "- Kernel source archives: $kernel_archive_count"
    echo
    if [ "$reject_count" != "0" ]; then
      echo "### Reject files"
      find "$OUT/rejects" -type f | sed "s#^$OUT/rejects/#- #"
      echo
    fi
  } > "$OUT/debug-summary.md"

  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    cat "$OUT/debug-summary.md" >> "$GITHUB_STEP_SUMMARY" || true
  fi
}

log "Collect OpenWrt debug info into $OUT"
write_meta
collect_lightweight

case "$JOB_STATUS" in
  failure|cancelled)
    log "Job status is $JOB_STATUS; collect heavy failure artifacts."
    collect_rejects
    collect_kernel_source
    ;;
  *)
    log "Job status is $JOB_STATUS; skip rejects and kernel source snapshot."
    ;;
esac

write_summary
log "Debug collection finished."

exit 0
