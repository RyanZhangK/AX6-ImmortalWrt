#!/bin/sh
# ============================================================
# keeper.sh —— 每账号保活循环（procd 实例）
# 用法: keeper.sh --account <uci账号名> [--interval <秒>]
# 逻辑：周期性探测 → 需要认证时自动登录 → 更新状态 → 睡眠。
# ============================================================

CAMP_LIB=/usr/libexec/campnet/lib.sh
[ -f "$CAMP_LIB" ] || CAMP_LIB="$(dirname "$0")/lib.sh"
. "$CAMP_LIB" || { echo "keeper: 无法加载 $CAMP_LIB" >&2; exit 1; }
. "$(dirname "$0")/ruijie.sh"
. "$(dirname "$0")/eportal.sh"

ACCOUNT=""
INTERVAL=""

while [ "$#" -gt 0 ]; do
	case "$1" in
		--account) ACCOUNT="$2"; shift 2 ;;
		--interval) INTERVAL="$2"; shift 2 ;;
		*) shift ;;
	esac
done

[ -n "$ACCOUNT" ] || { echo "keeper: 缺少 --account" >&2; exit 1; }

# 干净退出（procd stop / TERM）
trap 'exit 0' TERM INT HUP

log INFO "keeper[账号=$ACCOUNT] 启动"

while :; do
	load_settings
	[ "$S_ENABLED" = "1" ] || { sleep "${INTERVAL:-60}"; continue; }
	[ "$(acct_enabled "$ACCOUNT")" = "1" ] || { sleep "${INTERVAL:-60}"; continue; }

	iface=$(acct_iface_effective "$ACCOUNT")
	dev=$(iface_to_dev "$iface")
	DEV="$dev"

	st=$(probe_status "$dev")
	ip=$(dev_ip "$dev"); mac=$(dev_mac "$dev")

	case "$st" in
		authenticated)
			state_write "$ACCOUNT" status authenticated ip "$ip" mac "$mac" dev "$dev" msg "在线"
			;;
		no_ip)
			state_write "$ACCOUNT" status no_ip ip "" mac "$mac" dev "$dev" msg "接口无 IP（等待 DHCP）"
			log INFO "keeper[$ACCOUNT] 接口 $dev 暂无 IP"
			;;
		need_auth|offline)
			state_write "$ACCOUNT" status "${st}" ip "$ip" mac "$mac" dev "$dev" msg "离线，尝试认证"
			log INFO "keeper[$ACCOUNT] 检测到 $st，尝试自动登录..."
			run_login "$ACCOUNT"
			;;
	esac

	sleep "${INTERVAL:-$S_CHECK_INTERVAL}"
done
