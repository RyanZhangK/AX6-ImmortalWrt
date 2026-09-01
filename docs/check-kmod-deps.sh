#!/bin/bash
# 检查 10 插件相关的内核依赖(kmod-*/iptables-mod-*)在 .config 中是否勾选
cd "$(dirname "$0")/.." || exit 1

pkgs="ua3f luci-app-openclash minieap luci-proto-minieap luci-theme-argon \
luci-app-argon-config luci-app-upnp miniupnpd-nftables luci-app-turboacc \
luci-app-ddns ddns-scripts luci-app-adguardhome adguardhome \
luci-app-watchcat watchcat luci-app-docker dockerd \
luci-i18n-docker-zh-cn luci-compat luci-base"

declare -A required
for p in $pkgs; do
  # Depends 字段可能跨行折行：取 Depends 行 + 后续续行（直到下一个字段/空行），拼接后解析
  dep=$(awk -v pkg="$p" '
    $0=="Package: "pkg{f=1}
    f&&/^Depends:/{d=1; sub(/^Depends: */,""); printf "%s ",$0; next}
    f&&d&&/^[A-Za-z0-9_-]+:/{exit}
    f&&d{printf "%s ",$0}
    f&&d&&/^$/{exit}
  ' tmp/.packageinfo 2>/dev/null)
  [ -z "$dep" ] && continue
  for tok in $(echo "$dep" | grep -oE "(PACKAGE_[A-Za-z0-9_-]+:)?(kmod-[a-z0-9_-]+|iptables-mod-[a-z0-9_-]+)" | sort -u); do
    if [[ "$tok" == *:* ]]; then
      cond="${tok%%:*}"; kmod="${tok##*:}"
      # 条件依赖：仅当条件符号在 .config 中启用时才算必需
      if grep -qE "^CONFIG_${cond}=[ym]" .config 2>/dev/null; then
        required["$kmod"]="(条件 $cond 已启用)"
      fi
    else
      required["$tok"]="(直接依赖)"
    fi
  done
done

echo "共发现 ${#required[@]} 个内核相关依赖包："
echo "----------------------------------------"
missing=0
for k in $(echo "${!required[@]}" | tr ' ' '\n' | sort); do
  if grep -qE "^CONFIG_PACKAGE_${k}=[ym]" .config; then
    state=$(grep -oE "^CONFIG_PACKAGE_${k}=[ym]" .config | cut -d= -f2)
    printf "OK    %-30s =%s  %s\n" "$k" "$state" "${required[$k]}"
  else
    printf "MISS  %-30s (未勾选) %s\n" "$k" "${required[$k]}"
    missing=$((missing+1))
  fi
done
echo "----------------------------------------"
echo "缺失数: $missing"
