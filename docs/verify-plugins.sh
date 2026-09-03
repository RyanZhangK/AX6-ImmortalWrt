#!/bin/bash
# Verification helper: check each deployed plugin Makefile is scannable
# and that every include resolves. Parsing/metadata only — no compilation.
cd "$(dirname "$0")" || exit 1

plugins=(
  package/UA3F/openwrt/Makefile
  package/turboacc/luci-app-turboacc/Makefile
  package/luci-app-campnet/Makefile
  package/feeds/luci/applications/luci-app-openclash/Makefile
  package/feeds/luci/themes/luci-theme-argon/Makefile
  package/feeds/luci/applications/luci-app-argon-config/Makefile
  package/feeds/luci/applications/luci-app-upnp/Makefile
  package/feeds/packages/net/miniupnpd/Makefile
  package/feeds/luci/applications/luci-app-ddns/Makefile
  package/feeds/packages/net/ddns-scripts/Makefile
  package/feeds/luci/applications/luci-app-adguardhome/Makefile
  package/feeds/packages/net/adguardhome/Makefile
  package/feeds/luci/applications/luci-app-watchcat/Makefile
  package/feeds/packages/utils/watchcat/Makefile
  package/feeds/luci/applications/luci-app-docker/Makefile
)

fail=0
for p in "${plugins[@]}"; do
  if [ ! -f "$p" ]; then echo "MISSING FILE: $p"; fail=1; continue; fi
  bp=$(grep -cE "call (BuildPackage|Build/DefaultTargets)" "$p")
  bad=0
  while IFS= read -r inc; do
    inc=${inc#include }
    case "$inc" in
      '$(TOPDIR)/'*)
        rel=${inc#'$(TOPDIR)/'}
        [ -f "$rel" ] || bad=1 ;;
      '../../'*)
        base=$(dirname "$p")
        [ -f "$base/$inc" ] || bad=1 ;;
      '$(INCLUDE_DIR)/'*)
        rel=${inc#'$(INCLUDE_DIR)/'}
        [ -f "include/$rel" ] || bad=1 ;;
    esac
  done < <(grep -E '^include ' "$p")
  printf '%-70s BuildPackage:%s includes_broken:%s\n' "$p" "$bp" "$bad"
  [ "$bp" -ge 1 ] || fail=1
  [ "$bad" -eq 0 ] || fail=1
done

# Also verify the mirror feeds are findable by the scan's own filelist step
echo "--- scan filelist (find+grep, as include/scan.mk does) ---"
find -L package -mindepth 1 -maxdepth 5 -name Makefile \
  | xargs grep -aHE 'call (Build/DefaultTargets|BuildPackage|KernelPackage)' 2>/dev/null \
  | grep -cE 'package/(UA3F/openwrt|turboacc/luci-app-turboacc|feeds/luci/applications/luci-app-openclash|feeds/luci/applications/luci-app-upnp|feeds/luci/applications/luci-app-ddns|feeds/luci/applications/luci-app-watchcat|feeds/luci/applications/luci-app-docker|feeds/luci/applications/luci-app-adguardhome|feeds/luci/applications/luci-app-argon-config|feeds/luci/themes/luci-theme-argon|luci-app-campnet)'

echo "--- luci-i18n-docker-zh-cn: generated from po dir ---"
ls package/feeds/luci/applications/luci-app-docker/po/ 2>/dev/null
echo "verification done (fail=$fail)"
exit $fail
