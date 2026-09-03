#!/bin/sh
# ============================================================
# eportal.sh —— Ruijie eportal（InterFace.do?method=login）登录
# 算法移植自调研：kanoverse《OpenWrt 校园网共享》引用的社区实现
# （eportal/index.jsp?<queryString> → 双 URL 编码 → POST 登录）。
# 适用于“纯网关 IP 门户”型校园网（如 10.0.1.51 自托管门户）。
# 被 run_login 以 auth_eportal 调用；调用方需已准备 S_*/USERNAME/PASSWORD/ACCOUNT/DEV。
# ============================================================

# 从被劫持响应中提取 eportal queryString
_eportal_query_string() {
	local dev="$1" resp qs
	# 先看 HTTP 头 Location（302 型）
	resp=$(curl -s -o /dev/null -D - -m 8 --interface "$dev" --noproxy '*' \
		"http://$S_GATEWAY/" 2>/dev/null)
	qs=$(printf '%s' "$resp" | tr -d '\r' \
		| sed -n 's#.*[Ll]ocation: [^?]*eportal/index\.jsp?##p' | head -1)
	[ -n "$qs" ] || {
		# 再看页面 JS（top.self.location.href='...index.jsp?<qs>'）
		resp=$(curl -s -m 8 --interface "$dev" --noproxy '*' \
			"http://$S_GATEWAY/" 2>/dev/null)
		qs=$(printf '%s' "$resp" \
			| grep -o "eportal/index\.jsp?[^'\"]*" | head -1 | sed 's#.*index\.jsp?##')
	}
	printf '%s' "$qs"
}

# ------------------------------------------------------------
# auth_eportal —— eportal 一键登录；成功返回 0
# ------------------------------------------------------------
auth_eportal() {
	local dev="$DEV" qs enc1 enc2 post resp result msg _ip
	_ip=$(dev_ip "$dev")
	[ -n "$_ip" ] || { log ERROR "账号[$ACCOUNT] 接口 $dev 无 IPv4，无法认证"; return 1; }

	log INFO "账号[$ACCOUNT] eportal 模式登录 (gateway=$S_GATEWAY dev=$dev)"
	qs=$(_eportal_query_string "$dev")
	if [ -z "$qs" ]; then
		log WARN "账号[$ACCOUNT] 未能从网关抓取 eportal queryString（可能不在认证环境）"
		return 1
	fi
	log INFO "账号[$ACCOUNT] 已取得 queryString(len=${#qs})"

	# queryString 两次 URL 编码（服务端要求）
	enc1=$(urlencode "$qs")
	enc2=$(urlencode "$enc1")

	post="userId=$(urlencode "$USERNAME")&password=$(urlencode "$PASSWORD")&service="
	post="${post}&queryString=${enc2}&operatorPwd=&operatorUserId=&validcode=&passwordEncrypt=false"

	resp=$(curl -sS -m 15 --interface "$dev" --noproxy '*' \
		-X POST "http://$S_GATEWAY/eportal/InterFace.do?method=login" \
		-H "User-Agent: Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/68.0.3440.84 Safari/537.36" \
		-H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
		-H "Referer: http://$S_GATEWAY/eportal/index.jsp?${qs}" \
		--data "$post" 2>&1 || true)

	result=$(printf '%s' "$resp" | jsonfilter -e '@.result' 2>/dev/null)
	[ -n "$result" ] || result=$(printf '%s' "$resp" | sed -n 's/.*"result"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
	if [ "$result" = "success" ]; then
		log INFO "账号[$ACCOUNT] eportal 登录成功"
		return 0
	fi
	msg=$(printf '%s' "$resp" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
	log WARN "账号[$ACCOUNT] eportal 登录失败(${result:-unknown}): ${msg:-$(redact "$resp")}"
	return 1
}
