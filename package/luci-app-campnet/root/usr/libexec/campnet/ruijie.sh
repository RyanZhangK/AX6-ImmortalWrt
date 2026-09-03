#!/bin/sh
# ============================================================
# ruijie.sh —— axe_bras / webauth.do 一键登录（默认模式）
# 算法移植自调研：campus-auth-openwrt（GXSTNU axe_bras 认证流程）。
# 被 lib.sh 的 run_login 以 auth_ruijie 调用；环境由调用方准备：
#   load_settings 已执行（S_* 全局）、secret_read 已执行（USERNAME/PASSWORD）、
#   ACCOUNT / DEV 全局已设置。
# ============================================================

# 认证主机：独立 auth_host 优先，否则网关 IP（默认 10.0.1.51）
_auth_host() {
	if [ -n "$S_AUTH_HOST" ]; then echo "$S_AUTH_HOST"; else echo "$S_GATEWAY"; fi
}

# --resolve 参数串（auth_host 是域名且给定了 server_ip 时）
_resolve_args() {
	if [ -n "$S_AUTH_HOST" ] && [ -n "$S_SERVER_IP" ]; then
		echo "--resolve $S_AUTH_HOST:443:$S_SERVER_IP"
	fi
}

# 网关/认证服务器 静态路由（保证能直连认证主机）
_ensure_auth_route() {
	local dev="$1" host gw hostip
	gw=$(dev_default_gw "$dev")
	[ -n "$gw" ] || return 0
	host=$(_auth_host)
	hostip=$(printf '%s\n' "$host" | sed -n '/^[0-9][0-9.]*$/p')
	# 域名 → 用 server_ip 落地；纯 IP → 直接落地
	[ -n "$hostip" ] || hostip="$S_SERVER_IP"
	[ -z "$hostip" ] && return 0
	[ "$hostip" = "$gw" ] || {
		ip route add "$hostip" via "$gw" dev "$dev" 2>/dev/null || true
		[ -n "$S_SERVER_IP" ] && ip route add "$S_SERVER_IP" via "$gw" dev "$dev" 2>/dev/null || true
	}
}

# 外网拨号轮询（axe_bras 延迟拨号场景）
_poll_auth_result() {
	local dev="$1" acct_id="$2" page_id="$3" attempt=0 body host base rargs
	host=$(_auth_host); base="https://$host"; rargs=$(_resolve_args)
	while [ "$attempt" -lt "$S_POLL_MAX" ]; do
		attempt=$((attempt + 1))
		sleep "$S_POLL_INTERVAL"
		verify_internet "$dev" && return 0
		body=$(curl -skS -m 10 --interface "$dev" --noproxy '*' $rargs \
			-b "$CJ" -c "$CJ" \
			-H "Host: $host" \
			-H "Origin: $base" \
			-H "Referer: $base/webauth.do" \
			-H "X-Requested-With: XMLHttpRequest" \
			-H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
			--data-urlencode "userId=${acct_id}" \
			--data "pageId=${page_id}" \
			"$base/getAuthResult.do" 2>&1 || true)
		verify_internet "$dev" && return 0
		case "$body" in
			*"成功"*|*"已在线"*|*success*|*online*|*LOGINSUCC*|*true*)
				sleep 2; verify_internet "$dev" && return 0 ;;
		esac
		case "$body" in
			*"认证失败"*|*"登录失败"*|*"密码错误"*|*"余额不足"*|*fail*|*error*)
				log WARN "轮询返回失败: $(redact "$body")"
				return 1 ;;
		esac
		[ $((attempt % 5)) -eq 0 ] && log INFO "外网拨号处理中(${attempt}/${S_POLL_MAX})"
	done
	log WARN "外网拨号轮询超时"
	return 1
}

# ------------------------------------------------------------
# auth_ruijie —— axe_bras 一键登录；成功返回 0
# 依赖全局：ACCOUNT DEV USERNAME PASSWORD S_* CJ(COOKIE_PATH)
# ------------------------------------------------------------
auth_ruijie() {
	local dev="$DEV" host base rargs ip macl mac data resp attempt gw
	host=$(_auth_host); base="https://$host"; rargs=$(_resolve_args)
	CJ="$COOKIE_PREFIX.${ACCOUNT}.jar"
	ip=$(dev_ip "$dev")
	mac=$(dev_mac "$dev")
	[ -n "$ip" ] || { log ERROR "账号[$ACCOUNT] 接口 $dev 无 IPv4，无法认证"; return 1; }
	macl=$(printf '%s' "$mac" | tr 'A-Z' 'a-f')

	_ensure_auth_route "$dev"

	# 1) Cookie 播种：先访问 BRAS/AC 首页（拿到会话 cookie 与门户下发字段）
	rm -f "$CJ"
	curl -skL -m "$S_TMO" --interface "$dev" --noproxy '*' \
		-c "$CJ" "http://${S_GATEWAY}/" >/dev/null 2>&1
	# 认证域与网关不同（域名门户）时，再播种一次 HTTPS 根
	if [ -n "$S_AUTH_HOST" ]; then
		curl -sk -m "$S_TMO" --interface "$dev" --noproxy '*' $rargs \
			-b "$CJ" -c "$CJ" "${base}/" >/dev/null 2>&1
	fi

	# 2) 构造表单（键值均按调研记录，账号密码走 --data-urlencode）
	data="wlanacip=${S_GATEWAY}&wlanacname=$(urlencode "$S_WLANACNAME")&wlanuserip=${ip}&mac=${macl}&vlan=${S_VLAN}"
	data="${data}&scheme=https&serverIp=tomcat_server1:443&hostIp=http://127.0.0.1:8446/&loginType=&auth_type=${S_AUTH_TYPE}"
	data="${data}&isBindMac1=0&pageid=${S_PAGEID}&templatetype=${S_TEMPLATETYPE}&listbindmac=0&recordmac=0&isRemind=1"
	data="${data}&portalVer=0&tservertypeid=axe&realTerminalType=a&operatorastrict=0,1,2,3"
	data="${data}&echostr=&loginTimes=&groupId=&url=http://${S_GATEWAY}/&remInfo=on"

	log INFO "账号[$ACCOUNT] POST ${base}/webauth.do (dev=$dev ip=$ip mac=$macl)"
	resp=$(curl -sSki -m 30 --interface "$dev" --noproxy '*' $rargs \
		-b "$CJ" -c "$CJ" \
		-H "Host: ${host}" \
		-H "Origin: ${base}" \
		-H "Referer: ${base}/webauth.do" \
		-H "Content-Type: application/x-www-form-urlencoded" \
		-d "$data" \
		--data-urlencode "userId=${USERNAME}" \
		--data-urlencode "passwd=${PASSWORD}" \
		"${base}/webauth.do" 2>&1 || true)

	sleep 2

	# 3) 结果判定
	if verify_internet "$dev"; then
		log INFO "账号[$ACCOUNT] 登录成功（直连校验通过）"
		return 0
	fi
	case "$resp" in
		*"正在进行外网"*|*"外网拨号"*|*"请稍候"*|*getAuthResult*)
			log INFO "账号[$ACCOUNT] 提交成功，等待外网拨号完成"
			_poll_auth_result "$dev" "$USERNAME" "$S_PAGEID" && return 0
			return 1
			;;
	esac
	case "$resp" in
		*"认证失败"*|*"登录失败"*|*"密码错误"*|*"余额不足"*|*"账号异常"*|*"不在上网时段"*|*"时段限制"*)
			log WARN "账号[$ACCOUNT] 服务器拒绝: $(redact "$resp")"
			return 1
			;;
	esac
	log WARN "账号[$ACCOUNT] 登录未确认: $(redact "$resp")"
	return 1
}
