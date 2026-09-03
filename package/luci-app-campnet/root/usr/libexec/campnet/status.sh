#!/bin/sh
# ============================================================
# status.sh —— 状态输出（被 campnet status 调用；JSON 依赖 jshn）
# ============================================================

# 服务存活：keeper 进程数
_service_keepers() {
	pgrep -f '/usr/libexec/campnet/keeper.sh' 2>/dev/null | wc -l
}

# 读取账号状态（state 文件缓存；避免状态页触发实时探测造成延迟）
_account_state() {
	local acc="$1" key="$2"
	state_read "$acc" "$key" | grep -q . && state_read "$acc" "$key" || echo unknown
}

text_status() {
	local ids acc iface dev ip st
	load_settings
	echo "=================================================="
	echo " luci-app-campnet 校园网认证状态"
	echo "=================================================="
	echo " 启用      : $([ "$S_ENABLED" = "1" ] && echo 是 || echo 否)"
	echo " 认证模式  : $S_AUTH_MODE   (网关 $S_GATEWAY)"
	echo " 保活周期  : ${S_CHECK_INTERVAL}s  重试: ${S_MAX_RETRY}×${S_RETRY_DELAY}s"
	echo " 服务keeper: $(_service_keepers) 个进程"
	echo "--------------------------------------------------"
	ids=$(camp_account_ids)
	if [ -z "$ids" ]; then
		echo "（未配置任何账号）"
	fi
	for acc in $ids; do
		iface=$(acct_iface_effective "$acc"); dev=$(iface_to_dev "$iface")
		ip=$(dev_ip "$dev")
		st=$(_account_state "$acc" status)
		printf ' 账号[%s] %-13s %-15s %s\n' "$acc" "$st" "${ip:--}" "iface=$iface dev=$dev"
	done
	echo "--------------------------------------------------"
	echo " 最近日志 5 行:"
	tail -n 5 "$CAMP_LOG" 2>/dev/null | sed 's/^/  /' || true
}

json_status() {
	local HAVE_JSHN=0
	if [ -f /usr/share/libubox/jshn.sh ]; then
		. /usr/share/libubox/jshn.sh
		HAVE_JSHN=1
	fi
	load_settings
	local ids acc iface dev ip st mac msg ts
	if [ "$HAVE_JSHN" = "1" ]; then
		json_init
		json_add_object "settings"
		json_add_boolean "enabled" "$S_ENABLED"
		json_add_string "auth_mode" "$S_AUTH_MODE"
		json_add_string "gateway" "$S_GATEWAY"
		json_add_int "check_interval" "$S_CHECK_INTERVAL"
		json_add_int "max_retry" "$S_MAX_RETRY"
		json_add_string "uplink" "$S_UPLINK"
		json_add_boolean "dial_on_start" "$S_DIAL_ON_START"
		json_close_object

		json_add_int "keepers" "$(_service_keepers)"

		json_add_array "accounts"
		ids=$(camp_account_ids)
		for acc in $ids; do
			iface=$(acct_iface_effective "$acc"); dev=$(iface_to_dev "$iface")
			ip=$(dev_ip "$dev"); mac=$(dev_mac "$dev")
			st=$(_account_state "$acc" status)
			msg=$(state_read "$acc" msg)
			json_add_object ""
			json_add_string "id" "$acc"
			json_add_boolean "enabled" "$(acct_enabled "$acc")"
			json_add_string "iface" "$iface"
			json_add_string "dev" "$dev"
			json_add_string "ip" "${ip:-}"
			json_add_string "mac" "${mac:-}"
			json_add_string "status" "$st"
			json_add_string "msg" "$(sanitize_msg "${msg:-}")"
			json_close_object
		done
		json_close_array
		json_dump
		return 0
	fi
	# 无 jshn 兜底：极简
	printf '{"enabled":%s,"gateway":"%s","accounts":[' "$S_ENABLED" "$S_GATEWAY"
	ids=$(camp_account_ids)
	local first=1
	for acc in $ids; do
		[ "$first" -eq 1 ] || printf ','
		first=0
		iface=$(acct_iface_effective "$acc"); dev=$(iface_to_dev "$iface")
		printf '{"id":"%s","dev":"%s","ip":"%s","status":"%s"}' \
			"$acc" "$dev" "$(dev_ip "$dev")" "$(_account_state "$acc" status)"
	done
	printf ']}'
}
