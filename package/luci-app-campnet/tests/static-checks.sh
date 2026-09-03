#!/bin/sh
# ============================================================
# tests/static-checks.sh —— 交付前静态自检（无需真机/编译环境）
#   * 全部 shell 语法检查 (sh -n)
#   * menu.d/acl.d JSON 合法性
#   * LuCI JS 语法检查（若本机有 node）
#   * lib.sh 纯函数冒烟：urlencode / redact / secret 读写
# 用法: ./tests/static-checks.sh
# ============================================================
set -e
cd "$(dirname "$0")/.."

ROOT="$PWD"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
ko() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }

SHELL_FILES="
scripts/gen-config.sh
root/etc/init.d/campnet
root/etc/uci-defaults/40_luci-campnet
root/usr/libexec/campnet/campnet
root/usr/libexec/campnet/dial.sh
root/usr/libexec/campnet/eportal.sh
root/usr/libexec/campnet/keeper.sh
root/usr/libexec/campnet/lib.sh
root/usr/libexec/campnet/ruijie.sh
root/usr/libexec/campnet/status.sh
root/usr/libexec/rpcd/luci.campnet
tests/static-checks.sh
"

echo "[1/4] shell 语法"
for f in $SHELL_FILES; do
	[ -f "$ROOT/$f" ] || { ko "缺少 $f"; continue; }
	if sh -n "$ROOT/$f" 2>/dev/null; then ok "sh -n $f"; else ko "sh -n $f"; fi
done

echo "[2/4] JSON 合法性"
for f in "$ROOT"/root/usr/share/luci/menu.d/*.json "$ROOT"/root/usr/share/rpcd/acl.d/*.json; do
	if python3 -c "import json;json.load(open('$f'))" 2>/dev/null; then ok "json ${f#$ROOT/}"; else ko "json ${f#$ROOT/}"; fi
done

echo "[3/4] LuCI JS 语法（node --check）"
if command -v node >/dev/null 2>&1; then
	for f in "$ROOT"/htdocs/luci-static/resources/view/campnet/*.js; do
		if node --check "$f" 2>/dev/null; then ok "node --check ${f#$ROOT/}"; else ko "node --check ${f#$ROOT/}"; fi
	done
else
	echo "  SKIP  node 不存在，跳过 JS 检查"
fi

echo "[4/4] lib.sh 纯函数冒烟"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
. "$ROOT/root/usr/libexec/campnet/lib.sh"
CAMP_DIR="$TMP"
CAMP_SECRET="$TMP/.config"

# urlencode
[ "$(urlencode 'a b&c=')" = "a%20b%26c%3D" ] && ok "urlencode" || ko "urlencode"

# redact
r=$(redact 'userId=alice&passwd=secret123&mac=aa:bb')
case "$r" in
	*'passwd=***'*) ok "redact passwd" ;;
	*) ko "redact passwd ($r)" ;;
esac

# secret 读写
printf '[default]\nusername=202524104131\npassword=240414\n' > "$CAMP_SECRET"
chmod 600 "$CAMP_SECRET"
if secret_read main && [ "$USERNAME" = "202524104131" ] && [ "$PASSWORD" = "240414" ]; then
	ok "secret_read main"
else
	ko "secret_read main"
fi
secret_write acc2 'u2' 'p2'
if secret_read acc2 && [ "$USERNAME" = "u2" ] && [ "$PASSWORD" = "p2" ]; then
	ok "secret_write/read acc2"
else
	ko "secret_write/read acc2"
fi
if secret_read main && [ "$USERNAME" = "202524104131" ]; then
	ok "main 未被覆盖"
else
	ko "main 被覆盖"
fi
perm=$(stat -c %a "$CAMP_SECRET" 2>/dev/null || echo "?")
[ "$perm" = "600" ] && ok "secret 0600" || ko "secret 0600 ($perm)"

# _secret_section 映射
if [ "$(_secret_section main)" = "default" ] && [ "$(_secret_section acc2)" = "account:acc2" ]; then
	ok "_secret_section"
else
	ko "_secret_section"
fi

echo
echo "结果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
