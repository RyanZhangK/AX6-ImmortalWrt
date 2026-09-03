#!/bin/sh
# ============================================================
# lib.sh —— campnet 公共函数库（POSIX sh / busybox-ash 兼容）
# 被 campnet CLI、keeper、init.d、dial.sh、status.sh、rpcd 等 source。
# 约定：所有脚本先调用 load_settings()，再使用 S_* 全局。
# ============================================================

CAMP_CONF=campnet                       # uci 配置名
CAMP_DIR=/etc/campnet                   # 运行时目录（帐密等）
CAMP_SECRET="$CAMP_DIR/.config"         # 帐密文件（0600，绝不入 Git）
CAMP_SECRET_DEFAULT="$CAMP_DIR/.config.default"  # 打包默认模板
CAMP_CREATED="$CAMP_DIR/.created"       # dial.sh 登记已创建资源
CAMP_STATE_DIR=/var/run/campnet         # 每账号状态
CAMP_LOG_DIR=/var/log/campnet
CAMP_LOG="$CAMP_LOG_DIR/campnet.log"
CAMP_LOCK_DIR=/tmp/campnet-lock
CAMP_PREFIX=campnet
MAX_LOG_LINES=800
TRIM_LOG_LINES=500
COOKIE_PREFIX=/tmp/campnet-cookie

# ------------------------------------------------------------
# 基础工具
# ------------------------------------------------------------
uciq() { uci -q get "$1" 2>/dev/null; }

# 取整数值并带默认（非法/空 → 默认）
uciqn() {
	local v
	v=$(uciq "$1")
	case "$v" in
		''|*[!0-9]*) echo "${2:-0}" ;;
		*) echo "$v" ;;
	esac
}

# 日志：写文件（行数轮转）+ 标准错误
log() {
	local lvl="$1" msg="$2" ts
	mkdir -p "$CAMP_LOG_DIR" 2>/dev/null
	if [ -f "$CAMP_LOG" ] && [ "$(wc -l < "$CAMP_LOG" 2>/dev/null || echo 0)" -gt "$MAX_LOG_LINES" ]; then
		tail -n "$TRIM_LOG_LINES" "$CAMP_LOG" > "$CAMP_LOG.tmp" 2>/dev/null \
			&& mv "$CAMP_LOG.tmp" "$CAMP_LOG" 2>/dev/null
	fi
	ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
	printf '[%s] [%s] %s\n' "$ts" "$lvl" "$msg" >> "$CAMP_LOG" 2>/dev/null
	printf '[%s] %s\n' "$lvl" "$msg"
}

# 日志脱敏：避免把 帐号/密码/queryString/mac/distoken/wlanuserip 打进日志
redact() {
	printf '%s' "$1" | sed \
		-e 's/passwd=[^& ]*/passwd=***/g' \
		-e 's/password=[^& ]*/password=***/g' \
		-e 's/userId=[^& ]*/userId=***/g' \
		-e 's/username=[^& ]*/username=***/g' \
		-e 's/queryString=[^& ]*/queryString=***/g' \
		-e 's/mac=[^& ]*/mac=***/g' \
		-e 's/wlanuserip=[^& ]*/wlanuserip=***/g' \
		-e 's/distoken=[^& ]*/distoken=***/g' \
		| cut -c1-400
}

# URL 编码（POST 参数用）
urlencode() {
	local s="$1" out="" c i n
	i=1; n=${#s}
	while [ "$i" -le "$n" ]; do
		c=$(printf '%s' "$s" | cut -c "$i")
		case "$c" in
			[a-zA-Z0-9._~-]) out="${out}${c}" ;;
			*) out="${out}$(printf '%%%02X' "'$c")" ;;
		esac
		i=$((i + 1))
	done
	printf '%s' "$out"
}

# ------------------------------------------------------------
# 配置加载（uci campnet.settings）
# ------------------------------------------------------------
load_settings() {
	S_ENABLED=$(uciqn campnet.settings.enabled 1)
	S_AUTH_MODE=$(uciq campnet.settings.auth_mode);          S_AUTH_MODE=${S_AUTH_MODE:-ruijie}
	S_GATEWAY=$(uciq campnet.settings.gateway);              S_GATEWAY=${S_GATEWAY:-10.0.1.51}
	S_PROBE_URL=$(uciq campnet.settings.probe_url);          S_PROBE_URL=${S_PROBE_URL:-http://connect.rom.miui.com/generate_204}
	S_CHECK_INTERVAL=$(uciqn campnet.settings.check_interval 120)
	S_MAX_RETRY=$(uciqn campnet.settings.max_retry 3)
	S_RETRY_DELAY=$(uciqn campnet.settings.retry_delay 5)
	S_POLL_MAX=$(uciqn campnet.settings.poll_max 20)
	S_POLL_INTERVAL=$(uciqn campnet.settings.poll_interval 2)
	S_UPLINK=$(uciq campnet.settings.uplink);                S_UPLINK=${S_UPLINK:-auto}
	S_DIAL_ON_START=$(uciqn campnet.settings.dial_on_start 1)
	S_WLANACNAME=$(uciq campnet.settings.wlanacname);        S_WLANACNAME=${S_WLANACNAME:-BRAS}
	S_PAGEID=$(uciqn campnet.settings.pageid 5)
	S_TEMPLATETYPE=$(uciqn campnet.settings.templatetype 1)
	S_VLAN=$(uciqn campnet.settings.vlan 0)
	S_AUTH_TYPE=$(uciqn campnet.settings.auth_type 0)
	# 可选：独立认证域名 / 服务器 IP（用于 --resolve 绕过 DNS）
	S_AUTH_HOST=$(uciq campnet.settings.auth_host)
	S_SERVER_IP=$(uciq campnet.settings.server_ip)
	S_CTMO=$(uciqn campnet.settings.curl_connect_timeout 5)
	S_TMO=$(uciqn campnet.settings.curl_timeout 12)
	# 多播均衡兜底：若 settings 中没启用但存在 ≥2 个启用账号，也按 1 处理（见 dial.sh）
	[ "$S_ENABLED" = "1" ] || S_ENABLED=0
}

# ------------------------------------------------------------
# 账号（uci campnet.account.*，named 优先，兼容匿名 @account[N]）
# ------------------------------------------------------------
camp_account_ids() {
	uci show campnet 2>/dev/null | grep -E '^campnet\.[^=]+=account$' \
		| sed -E 's/^campnet\.//; s/=account$//'
}

acct_opt() { uciq "campnet.$1.$2"; }
acct_enabled() { uciqn "campnet.$1.enabled" 1; }

# 该账号实际绑定的 uci network 接口名（默认 wan）
acct_iface() {
	local v
	v=$(acct_opt "$1" iface)
	echo "${v:-wan}"
}

# 多播命名助手（与 dial.sh 共用；确定性）
# 账号 id → 短基名（<=7 字节，仅字母数字）
base_of() {
	local base
	base=$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]//g' | cut -c1-7)
	[ -n "$base" ] || base=acc
	echo "$base"
}
# 内核设备名 / uci network 接口 id（<=15 字节）
dev_name_for() { echo "campnet_$(base_of "$1")"; }
# netifd device 段 id（与接口段区分）
devsec_for() { echo "campd_$(base_of "$1")"; }

# 该账号实际生效的 uci network 接口：
# create_vlan=1 → 专属 macvlan 通道 campnet_<base>；否则账号 iface（默认 wan）
acct_iface_effective() {
	local acc="$1"
	if [ "$(uciqn "campnet.$acc.create_vlan" 0)" = "1" ]; then
		dev_name_for "$acc"
	else
		acct_iface "$acc"
	fi
}

# uci network 接口 → 内核设备名（23.05 device / 旧 ifname 兼容）
iface_to_dev() {
	local d
	d=$(uciq "network.$1.device")
	[ -z "$d" ] && d=$(uciq "network.$1.ifname")
	[ -z "$d" ] && d="$1"
	echo "$d"
}

# ------------------------------------------------------------
# 帐密：/etc/campnet/.config（0600）
# 分节：main 账号 → [default]；其余账号 → [account:<id>]
# ------------------------------------------------------------
_secret_section() {  # account → 对应分节名
	case "${1:-main}" in
		''|main) echo "default" ;;
		*) echo "account:$1" ;;
	esac
}

# secret_read <account> → 设置全局 USERNAME / PASSWORD；成功返回 0
secret_read() {
	USERNAME=""; PASSWORD=""
	local acc="${1:-main}" want sec out u p
	want=$(_secret_section "$acc")
	[ -f "$CAMP_SECRET" ] || return 1
	out=$(awk -v want="$want" '
		function unq(s) {
			if (length(s) >= 2 && ((substr(s,1,1)=="\"" && substr(s,length(s),1)=="\"") || \
			    (substr(s,1,1)=="\x27" && substr(s,length(s),1)=="\x27")))
				return substr(s,2,length(s)-2)
			return s
		}
		/^[[:space:]]*\[/ {
			sec=$0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", sec)
			if (sec==want) cur=1; else cur=0
			next
		}
		cur==1 && /^[[:space:]]*[A-Za-z0-9_]+[[:space:]]*=/ {
			k=$0; sub(/^[[:space:]]*/,"",k); sub(/=[^=]*$/,"",k); gsub(/[[:space:]]/,"",k)
			v=$0; sub(/^[^=]*=[[:space:]]*/,"",v); gsub(/[[:space:]]*$/,"",v)
			if (k=="username") u=unq(v)
			else if (k=="password") p=unq(v)
		}
		END { if (u!="" || p!="") printf "U=%s\nP=%s\n", u, p }
	' "$CAMP_SECRET")
	USERNAME=$(printf '%s\n' "$out" | sed -n 's/^U=//p' | head -1)
	PASSWORD=$(printf '%s\n' "$out" | sed -n 's/^P=//p' | head -1)
	[ -n "$USERNAME" ] && [ -n "$PASSWORD" ]
}

# secret_write <account> <username> <password> —— 原子重写（0600）
# 规则：[default] 存 main；其它存 [account:<id>]。只覆盖目标分节，保留其它分节。
secret_write() {
	local acc="${1:-main}" user="$2" pass="$3" want
	want=$(_secret_section "$acc")
	mkdir -p "$CAMP_DIR" 2>/dev/null || return 1
	{
		printf '# campnet 帐密 —— 请通过 LuCI/CLI 修改，勿直接编辑\n'
		printf '# [default] = 主账号(main)；[account:<id>] = 附加账号\n'
		if [ "$want" = "default" ]; then
			printf '\n[default]\nusername=%s\npassword=%s\n' "$user" "$pass"
			# 保留其它 [account:*] 分节
			[ -f "$CAMP_SECRET" ] && awk '
				BEGIN { skip=0; started=0 }
				/^[[:space:]]*\[/ {
					sec=$0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", sec)
					if (sec=="default") { skip=1; next }
					skip=0
					if (started) print ""; started=1
				}
				skip==0 && !/^[[:space:]]*#/ && !/^[[:space:]]*$/ { print }
			' "$CAMP_SECRET"
		else
			# 保留旧文件（跳过目标分节与注释；[default] 一并保留）
			if [ -f "$CAMP_SECRET" ]; then
				awk -v want="$want" '
					BEGIN { skip=0; started=0 }
					/^[[:space:]]*\[/ {
						sec=$0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", sec)
						if (sec==want) { skip=1; next }
						skip=0
						if (started) print ""; started=1
					}
					skip==0 && !/^[[:space:]]*#/ && !/^[[:space:]]*$/ { print }
				' "$CAMP_SECRET"
			else
				printf '\n[default]\nusername=\npassword=\n'
			fi
			printf '\n[%s]\nusername=%s\npassword=%s\n' "$want" "$user" "$pass"
		fi
	} > "$CAMP_SECRET.tmp" 2>/dev/null || return 1
	chmod 600 "$CAMP_SECRET.tmp"
	mv "$CAMP_SECRET.tmp" "$CAMP_SECRET" || return 1
	chmod 600 "$CAMP_SECRET"
	return 0
}

# 种子化：无则用打包模板/内置默认生成
secret_seed() {
	mkdir -p "$CAMP_DIR" 2>/dev/null
	[ -f "$CAMP_SECRET" ] && { chmod 600 "$CAMP_SECRET" 2>/dev/null; return 0; }
	if [ -f "$CAMP_SECRET_DEFAULT" ]; then
		cp "$CAMP_SECRET_DEFAULT" "$CAMP_SECRET" 2>/dev/null || return 1
	else
		cat > "$CAMP_SECRET" <<-EOF
			[default]
			username=202524104131
			password=240414
		EOF
	fi
	chmod 600 "$CAMP_SECRET" 2>/dev/null
	return 0
}

# ------------------------------------------------------------
# 网络探测（dev = 内核设备名）
# ------------------------------------------------------------
dev_has_ip() { ip -4 addr show dev "$1" 2>/dev/null | grep -q ' inet '; }

dev_ip() {
	ip -4 addr show dev "$1" 2>/dev/null | awk '/ inet /{ sub(/\/.*/, "", $2); print $2; exit }'
}

dev_mac() {
	cat "/sys/class/net/$1/address" 2>/dev/null | tr 'a-f' 'A-F'
}

dev_default_gw() {
	ip -4 route show dev "$1" 2>/dev/null | awk '$1=="default" { print $3; exit }'
}

# probe_online <dev>：0=在线(204)；1=需要认证(被劫持/门户)；2=离线/网关不可达
probe_online() {
	local dev="$1" code gcode
	code=$(curl -s -o /dev/null -w '%{http_code}' --interface "$dev" \
		--connect-timeout "${S_CTMO:-3}" --max-time "${S_TMO:-5}" --noproxy '*' \
		"$S_PROBE_URL" 2>/dev/null)
	case "$code" in
		204) return 0 ;;
		200|301|302|303|307|308) return 1 ;;
	esac
	# 探针未果 → 看门户网关是否可达（区分 需认证 / 真离线）
	gcode=$(curl -s -o /dev/null -w '%{http_code}' --interface "$dev" \
		--connect-timeout 3 --max-time 5 --noproxy '*' "http://$S_GATEWAY/" 2>/dev/null)
	case "$gcode" in
		200|301|302|303|307|308) return 1 ;;
	esac
	return 2
}

# probe_status <dev> → stdout: no_ip|authenticated|need_auth|offline
probe_status() {
	local dev="$1" rc
	dev_has_ip "$dev" || { echo no_ip; return; }
	if probe_online "$dev"; then echo authenticated; return; fi
	rc=$?
	[ "$rc" -eq 1 ] && { echo need_auth; return; }
	echo offline
}

# 在线硬校验（认证后使用）：204 或 ping 通 223.5.5.5
verify_internet() {
	local dev="$1"
	if probe_online "$dev"; then return 0; fi
	ping -c 1 -W 2 -I "$dev" 223.5.5.5 >/dev/null 2>&1 && return 0
	return 1
}

# ------------------------------------------------------------
# 锁（mkdir 原子 + 过期回收）
# ------------------------------------------------------------
lock_get() {
	local name="$1" lk i ts
	mkdir -p "$CAMP_LOCK_DIR" 2>/dev/null || return 1
	lk="$CAMP_LOCK_DIR/$name"
	i=0
	while ! mkdir "$lk" 2>/dev/null; do
		if [ -d "$lk" ]; then
			ts=$(stat -c %Y "$lk" 2>/dev/null || echo 0)
			[ "$(( $(date +%s) - ts ))" -gt 300 ] && rmdir "$lk" 2>/dev/null
		fi
		i=$((i + 1))
		[ "$i" -gt 100 ] && return 1
		sleep 0.2
	done
	return 0
}

lock_release() {
	rmdir "$CAMP_LOCK_DIR/$1" 2>/dev/null
	return 0
}

# ------------------------------------------------------------
# 状态缓存（每账号 /var/run/campnet/<account>.state，供 UI/status）
# ------------------------------------------------------------
state_write() {
	local acc="$1" f t
	shift
	mkdir -p "$CAMP_STATE_DIR" 2>/dev/null || return 1
	f="$CAMP_STATE_DIR/$acc.state"
	t=$(mktemp "$f.XXXXXX" 2>/dev/null) || return 1
	printf 'ts=%s\n' "$(date +%s)" > "$t"
	while [ "$#" -ge 2 ]; do
		printf '%s=%s\n' "$1" "$2"
		shift 2
	done >> "$t"
	mv "$t" "$f"
	return 0
}

state_read() {
	[ -f "$CAMP_STATE_DIR/$1.state" ] \
		&& sed -n "s/^$2=//p" "$CAMP_STATE_DIR/$1.state" 2>/dev/null | head -1
}

sanitize_msg() { printf '%s' "$1" | tr '\n\r' '  ' | cut -c1-200; }

# ------------------------------------------------------------
# 认证入口 run_login（由 keeper/CLI 调用；需已 source ruijie.sh/eportal.sh）
# 返回：0=成功在线 1=失败 2=接口未就绪 3=锁占用
# ------------------------------------------------------------
run_login() {
	local acc="$1" force="$2" iface dev rc mode tried ok
	load_settings
	[ "$S_ENABLED" = "1" ] || { log WARN "插件已停用(enabled=0)，跳过 $acc"; return 0; }
	[ "$(acct_enabled "$acc")" = "1" ] || { log INFO "账号 $acc 未启用，跳过"; return 0; }

	iface=$(acct_iface_effective "$acc")
	dev=$(iface_to_dev "$iface")
	ACCOUNT="$acc"; DEV="$dev"

	# 已在线且非强制 → 直接成功
	[ "$force" = "--force" ] || {
		if probe_status "$dev" | grep -q authenticated; then
			state_write "$acc" status authenticated ip "$(dev_ip "$dev")" mac "$(dev_mac "$dev")" dev "$dev" msg "已在线"
			return 0
		fi
	}

	secret_read "$acc" || {
		state_write "$acc" status error ip "$(dev_ip "$dev")" dev "$dev" msg "缺少帐密配置(/etc/campnet/.config)"
		log ERROR "账号[$acc] 缺少帐密，请先配置"
		return 1
	}

	if ! dev_has_ip "$dev"; then
		state_write "$acc" status no_ip dev "$dev" msg "接口 $iface($dev) 暂无 IPv4"
		log WARN "账号[$acc] 接口 $dev 无 IP，等待 DHCP"
		return 2
	fi

	lock_get "login-$acc" || {
		log WARN "账号[$acc] 已有认证在进行，跳过"
		return 3
	}

	state_write "$acc" status authing ip "$(dev_ip "$dev")" mac "$(dev_mac "$dev")" dev "$dev" msg "认证中..."
	tried=0; ok=0
	while [ "$tried" -lt "$S_MAX_RETRY" ]; do
		tried=$((tried + 1))
		[ "$tried" -gt 1 ] && log INFO "账号[$acc] 第 $tried 次尝试"
		case "$S_AUTH_MODE" in
			eportal) auth_eportal && ok=1 ;;
			auto)
				# auto：先按页面特征探测门户类型，再回退尝试
				if detect_portal_type "$dev" | grep -q eportal; then
					{ auth_eportal || auth_ruijie; } && ok=1
				else
					{ auth_ruijie || auth_eportal; } && ok=1
				fi
				;;
			*) auth_ruijie && ok=1 ;;
		esac
		[ "$ok" -eq 1 ] && break
		[ "$tried" -lt "$S_MAX_RETRY" ] && sleep "$S_RETRY_DELAY"
	done

	lock_release "login-$acc"

	if [ "$ok" -eq 1 ]; then
		state_write "$acc" status authenticated ip "$(dev_ip "$dev")" mac "$(dev_mac "$dev")" dev "$dev" \
			msg "登录成功(第${tried}次)"
		log INFO "账号[$acc] 校园网认证成功 (接口 $iface/$dev)"
		return 0
	fi
	state_write "$acc" status error ip "$(dev_ip "$dev")" mac "$(dev_mac "$dev")" dev "$dev" \
		msg "认证失败(重试${S_MAX_RETRY}次)"
	log ERROR "账号[$acc] 认证失败（接口 $dev）"
	return 1
}

# 页面特征探测（auto 模式）：输出 eportal|ruijie
detect_portal_type() {
	local dev="$1" body hdr
	body=$(curl -s -m 8 --interface "$dev" --noproxy '*' "http://$S_GATEWAY/" 2>/dev/null)
	hdr=$(curl -s -o /dev/null -D - -m 8 --interface "$dev" --noproxy '*' "http://$S_GATEWAY/" 2>/dev/null)
	{
		printf '%s\n%s\n' "$body" "$hdr"
	} | grep -qi 'eportal\|InterFace\.do' && { echo eportal; return; }
	printf '%s\n%s\n' "$body" "$hdr" | grep -qi 'webauth\.do\|axe_bras\|/eportal/' && { echo ruijie; return; }
	echo ruijie
}
