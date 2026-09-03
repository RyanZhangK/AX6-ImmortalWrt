#!/bin/sh
# ============================================================
# dial.sh —— 多账号多播均衡编排（带宽倍增）
# setup   : 每个启用账号建立独立 WAN 通道并注入 mwan3 均衡
#           - create_vlan=1 的账号 → netifd 托管 macvlan(campnet_<id>) + DHCP
#           - 全部启用账号 → mwan3 interface/member + policy(campnet_balanced)
#           - 兜底 rule(campnet_rule)，自动置于 default_rule* 之前
# teardown: 仅撤销 .created 登记过的本插件资源，绝不碰用户既有配置
# status  : 打印登记与存活情况
# 幂等     : 可反复执行；仅当确有变更才 commit / 重启 mwan3
# ============================================================

CAMP_LIB=/usr/libexec/campnet/lib.sh
[ -f "$CAMP_LIB" ] || CAMP_LIB="$(dirname "$0")/lib.sh"
. "$CAMP_LIB" || { echo "dial: 无法加载 $CAMP_LIB" >&2; exit 1; }

MWAN3_BIN=$(command -v mwan3 2>/dev/null || echo /usr/sbin/mwan3)
DIAL_MAX_ACCOUNTS=8
DIRTY=0

uci_chk() { # <cfg.section.option> <value> —— 值不同才 set 并置 DIRTY
	local cur
	cur=$(uci -q get "$1")
	[ "$cur" = "$2" ] || { uci -q set "$1=$2"; DIRTY=1; }
}

mark() { # kind arg
	mkdir -p "$CAMP_DIR" 2>/dev/null
	grep -qF -- "$1 $2" "$CAMP_CREATED" 2>/dev/null || echo "$1 $2" >> "$CAMP_CREATED"
}

# 命名助手（base_of/dev_name_for/devsec_for）与
# acct_iface_effective/acct_iface 等由 lib.sh 统一提供。

_gen_mac() {
	local hex
	hex=$(od -An -N5 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
	[ "${#hex}" -eq 10 ] || hex=$(printf '%08x' $(( ($$ * 7919 + ${RANDOM:-1}) % 0xFFFFFF )))
	printf '%s' "$hex" | sed -E 's/^(..)(..)(..)(..)(..)$/02:\1:\2:\3:\4:\5/'
}

# 取（或生成并固化）某账号 macvlan MAC —— 固化到 uci 防重启漂移
_acct_mac() {
	local acc="$1" mac
	mac=$(acct_opt "$acc" macaddr)
	if [ -z "$mac" ]; then
		mac=$(_gen_mac)
		uci -q set "campnet.$acc.macaddr=$mac"
		DIRTY=1
	fi
	echo "$mac"
}

_resolve_uplink() {
	if [ -n "$S_UPLINK" ] && [ "$S_UPLINK" != "auto" ]; then
		echo "$S_UPLINK"
	else
		iface_to_dev "$(acct_iface main 2>/dev/null || echo wan)"
	fi
}

fw_zone_index() { # zone name → 序号（找不到返回 1 退出码）
	local i=0 n
	while :; do
		n=$(uci -q get "firewall.@zone[$i].name")
		[ -n "$n" ] || return 1
		[ "$n" = "$1" ] && { echo "$i"; return 0; }
		i=$((i + 1))
	done
	return 1
}

mwan3_available() {
	[ -x "$MWAN3_BIN" ] && [ -f /etc/config/mwan3 ]
}

# 参与均衡通道："iface|metric|weight" 列表（确定性顺序、去重）
_balance_targets() {
	local ids acc iface devname seen out t
	ids=$(camp_account_ids)
	seen=""; out=""
	for acc in $ids; do
		[ "$(acct_enabled "$acc")" = "1" ] || continue
		devname=$(acct_iface_effective "$acc")
		case " $seen " in
			*" $devname "*) continue ;;
		esac
		seen="$seen $devname"
		out="$out $devname|$(uciqn "campnet.$acc.metric" 10)|$(uciqn "campnet.$acc.weight" 10)"
	done
	echo "$out"
}

# ------------------------------------------------------------
# pass1：macvlan + DHCP + 防火墙
# ------------------------------------------------------------
dial_net_setup() {
	local uplink ids acc z
	uplink=$(_resolve_uplink)
	if [ -z "$uplink" ] || [ ! -d "/sys/class/net/$uplink" ]; then
		log WARN "dial: 上行链路 '$uplink' 不存在，跳过"
		return 0
	fi
	log INFO "dial: 上行链路 = $uplink"

	ids=$(camp_account_ids)
	for acc in $ids; do
		[ "$(acct_enabled "$acc")" = "1" ] || continue
		[ "$(uciqn "campnet.$acc.create_vlan" 0)" = "1" ] || continue

		local devname devsec mac
		devname=$(dev_name_for "$acc")
		devsec=$(devsec_for "$acc")
		mac=$(_acct_mac "$acc")
		log INFO "dial: 账号[$acc] → macvlan $devname (link=$uplink mac=$mac)"

		# 1) netifd 托管 device 段（type macvlan，重启自动重建）
		[ "$(uci -q get network.$devsec 2>/dev/null)" = "device" ] || {
			uci -q set "network.$devsec=device"; DIRTY=1
		}
		uci_chk "network.$devsec.name" "$devname"
		uci_chk "network.$devsec.type" "macvlan"
		uci_chk "network.$devsec.ifname" "$uplink"
		uci_chk "network.$devsec.mode" "bridge"
		uci_chk "network.$devsec.macaddr" "$mac"
		mark netdev "$devsec"

		# 2) DHCP 接口（id 与内核设备同名，netifd 自动关联 device 段）
		[ "$(uci -q get network.$devname 2>/dev/null)" = "interface" ] || {
			uci -q set "network.$devname=interface"; DIRTY=1
		}
		uci_chk "network.$devname.proto" "dhcp"
		uci_chk "network.$devname.device" "$devname"
		mark netiface "$devname"

		# 3) 防火墙 wan 区域成员
		z=$(fw_zone_index wan)
		if [ -n "$z" ]; then
			case " $(uci -q get firewall.@zone[$z].network 2>/dev/null) " in
				*" $devname "*) ;;
				*) uci -q add_list "firewall.@zone[$z].network=$devname"; mark fwlist "$z" "$devname"; DIRTY=1 ;;
			esac
		else
			log WARN "dial: 找不到 firewall zone 'wan'，请手动把 $devname 加入 wan 区域"
		fi
	done

	[ "$DIRTY" -eq 1 ] || return 0
	# 固化新生成的 MAC 等 campnet 选项（commit 会触发服务 reload，幂等安全）
	[ -n "$(uci -q changes campnet 2>/dev/null)" ] && uci -q commit campnet 2>/dev/null
	uci -q commit network
	uci -q commit firewall
	# 立即建立并拉起 DHCP
	for acc in $ids; do
		[ "$(acct_enabled "$acc")" = "1" ] || continue
		[ "$(uciqn "campnet.$acc.create_vlan" 0)" = "1" ] || continue
		ifup "$(dev_name_for "$acc")" >/dev/null 2>&1 || true
	done
	[ -x /etc/init.d/firewall ] && /etc/init.d/firewall reload >/dev/null 2>&1 || true
	return 0
}

# ------------------------------------------------------------
# pass2：mwan3 均衡（≥2 条通道才注入）
# ------------------------------------------------------------
dial_mwan3_setup() {
	local targets n t iface metric weight member desired cur
	targets=$(_balance_targets)
	n=$(echo $targets | wc -w)
	[ "$n" -ge 2 ] || { log INFO "dial: 可用通道 $n 条（<2），无需 mwan3 均衡"; return 0; }
	mwan3_available || { log WARN "dial: mwan3 不可用，跳过均衡注入（opkg install mwan3）"; return 0; }

	# interface/member
	for t in $targets; do
		iface=${t%%|*}; rest=${t#*|}; metric=${rest%%|*}; weight=${rest##*|}
		member="${iface}_camp_m${metric}_w${weight}"
		if ! uci -q get "mwan3.$iface" >/dev/null 2>&1; then
			uci -q set "mwan3.$iface=interface"
			uci -q set "mwan3.$iface.enabled=1"
			uci -q set "mwan3.$iface.family=ipv4"
			uci -q set "mwan3.$iface.reliability=2"
			uci -q add_list "mwan3.$iface.track_ip=223.5.5.5"
			uci -q add_list "mwan3.$iface.track_ip=119.29.29.29"
			mark mwan3iface "$iface"
			DIRTY=1
		fi
		if ! uci -q get "mwan3.$member" >/dev/null 2>&1; then
			uci -q set "mwan3.$member=member"
			uci -q set "mwan3.$member.interface=$iface"
			uci -q set "mwan3.$member.metric=$metric"
			uci -q set "mwan3.$member.weight=$weight"
			mark mwan3member "$member"
			DIRTY=1
		fi
	done

	# policy
	if ! uci -q get "mwan3.campnet_balanced" >/dev/null 2>&1; then
		uci -q set "mwan3.campnet_balanced=policy"
		mark mwan3policy campnet_balanced
		DIRTY=1
	fi
	# 重建 use_member（仅当实际不同）
	desired=""
	for t in $targets; do
		iface=${t%%|*}; rest=${t#*|}; metric=${rest%%|*}; weight=${rest##*|}
		desired="$desired ${iface}_camp_m${metric}_w${weight}"
	done
	desired=${desired# }
	cur=$(uci -q get "mwan3.campnet_balanced.use_member")
	if [ "$cur" != "$desired" ]; then
		uci -q delete "mwan3.campnet_balanced.use_member" 2>/dev/null
		for t in $targets; do
			iface=${t%%|*}; rest=${t#*|}; metric=${rest%%|*}; weight=${rest##*|}
			uci -q add_list "mwan3.campnet_balanced.use_member=${iface}_camp_m${metric}_w${weight}"
		done
		DIRTY=1
	fi

	# rule（兜底 0.0.0.0/0 → campnet_balanced；用 uci 创建，保证 commit 一致）
	if ! uci -q get "mwan3.campnet_rule" >/dev/null 2>&1; then
		uci -q set "mwan3.campnet_rule=rule"
		uci -q set "mwan3.campnet_rule.dest_ip=0.0.0.0/0"
		uci -q set "mwan3.campnet_rule.family=ipv4"
		uci -q set "mwan3.campnet_rule.use_policy=campnet_balanced"
		mark mwan3rule campnet_rule
		DIRTY=1
	fi

	# 提交配置（若有变更）
	[ "$DIRTY" -eq 1 ] && uci -q commit mwan3

	# 规则位置校正：无论本次是否有其它变更，保证 campnet_rule 在 default_rule 之前
	MOVED=0
	[ -f /etc/config/mwan3 ] && grep -q "^config rule .campnet_rule" /etc/config/mwan3 \
		&& _relocate_rule

	if [ "$DIRTY" -eq 1 ] || [ "$MOVED" -eq 1 ]; then
		if "$MWAN3_BIN" restart >/dev/null 2>&1; then
			log INFO "dial: mwan3 已重载，均衡生效"
		else
			log WARN "dial: mwan3 restart 失败，请手动检查"
		fi
	fi
	return 0
}

# 把 campnet_rule 段移动到第一个 default_rule* 之前（保证兜底规则先命中；
# mwan3 规则按配置顺序判定，落于 default 之后会被其吞掉）
_relocate_rule() {
	local cfg=/etc/config/mwan3
	[ -f "$cfg" ] || return 0
	grep -q "^config rule .campnet_rule" "$cfg" || return 0
	grep -q "^config rule .default_rule" "$cfg" || return 0
	awk '
		{ lines[NR] = $0 }
		END {
			start = 0; def = 0
			for (i = 1; i <= NR; i++) {
				if (!start && lines[i] ~ /^config rule .campnet_rule./) start = i
				if (!def    && lines[i] ~ /^config rule .default_rule/) def = i
			}
			if (!start || !def || start < def) exit 0   # 已在 default 之前或找不到 → 不动
			bend = NR
			for (i = start + 1; i <= NR; i++)
				if (lines[i] ~ /^config /) { bend = i - 1; break }
			for (i = 1; i <= NR; i++) {
				if (i >= start && i <= bend) continue
				if (i == def) { for (j = start; j <= bend; j++) print lines[j] }
				print lines[i]
			}
		}
	' "$cfg" > "$cfg.tmp" 2>/dev/null || return 1
	mv "$cfg.tmp" "$cfg" 2>/dev/null || return 1
	MOVED=1
	log INFO "dial: campnet_rule 已置于 default_rule 之前"
	return 0
}

# ------------------------------------------------------------
dial_setup() {
	load_settings
	[ "$S_ENABLED" = "1" ] || { log WARN "dial: 插件停用(enabled=0)，跳过"; return 0; }
	command -v ip >/dev/null 2>&1 || { log ERROR "dial: 缺少 ip 命令"; return 1; }
	dial_net_setup
	DIRTY=0   # pass1 变更已提交；pass2 只反映 mwan3 变更
	dial_mwan3_setup
	return 0
}

dial_teardown() {
	[ -f "$CAMP_CREATED" ] || { echo "dial: 无登记记录，无需清理"; return 0; }
	local s z net
	# mwan3（先规则/策略后成员/接口）
	for s in $(awk '$1=="mwan3rule"{print $2}' "$CAMP_CREATED"); do
		uci -q get "mwan3.$s" >/dev/null 2>&1 && uci -q delete "mwan3.$s"
	done
	for s in $(awk '$1=="mwan3policy"{print $2}' "$CAMP_CREATED"); do
		uci -q get "mwan3.$s" >/dev/null 2>&1 && uci -q delete "mwan3.$s"
	done
	for s in $(awk '$1=="mwan3member"{print $2}' "$CAMP_CREATED"); do
		uci -q get "mwan3.$s" >/dev/null 2>&1 && uci -q delete "mwan3.$s"
	done
	for s in $(awk '$1=="mwan3iface"{print $2}' "$CAMP_CREATED"); do
		uci -q get "mwan3.$s" >/dev/null 2>&1 && uci -q delete "mwan3.$s"
	done
	# 防火墙
	awk '$1=="fwlist"{print $2, $3}' "$CAMP_CREATED" | while read -r z net; do
		[ -n "$z" ] && [ -n "$net" ] && uci -q del_list "firewall.@zone[$z].network=$net" 2>/dev/null
	done
	# network 接口（devname）
	for s in $(awk '$1=="netiface"{print $2}' "$CAMP_CREATED"); do
		ifdown "$s" >/dev/null 2>&1 || true
		uci -q get "network.$s" >/dev/null 2>&1 && uci -q delete "network.$s"
	done
	# netifd device 段（devsec，内核设备名在 option name）
	for s in $(awk '$1=="netdev"{print $2}' "$CAMP_CREATED"); do
		kname=$(uci -q get "network.$s.name")
		uci -q get "network.$s" >/dev/null 2>&1 && uci -q delete "network.$s"
		if [ -n "$kname" ] && [ -d "/sys/class/net/$kname" ]; then
			ip link del dev "$kname" 2>/dev/null || true
		fi
	done
	uci -q commit network 2>/dev/null
	uci -q commit firewall 2>/dev/null
	uci -q commit mwan3 2>/dev/null
	rm -f "$CAMP_CREATED"
	mwan3_available && "$MWAN3_BIN" restart >/dev/null 2>&1 || true
	log INFO "dial: 已撤销本插件创建的全部多播资源"
	return 0
}

dial_status() {
	echo "== campnet 多播资源登记 =="
	[ -f "$CAMP_CREATED" ] && cat "$CAMP_CREATED" || echo "（无登记记录）"
	echo
	echo "== 账号与通道 =="
	local ids acc iface dev ip
	ids=$(camp_account_ids)
	for acc in $ids; do
		iface=$(acct_iface "$acc")
		dev=$(iface_to_dev "$iface")
		ip=$(dev_ip "$dev")
		printf '账号[%s] enabled=%s create_vlan=%s iface=%s dev=%s ip=%s\n' \
			"$acc" "$(acct_enabled "$acc")" "$(uciqn "campnet.$acc.create_vlan" 0)" \
			"$iface" "$dev" "${ip:--}"
	done
	return 0
}

case "${1:-status}" in
	setup) dial_setup ;;
	teardown) dial_teardown ;;
	status) dial_status ;;
	*) echo "用法: $0 {setup|teardown|status}" >&2; exit 1 ;;
esac
