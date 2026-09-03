# SPDX-License-Identifier: WTFPL
#
# luci-app-campnet — 校园网自动认证 + 多账号多播均衡（ImmortalWrt/OpenWrt）
#
# 布局说明：本包既可直接放入 feeds/luci/applications/luci-app-campnet，
# 也可镜像到仓库 package/luci-app-campnet（OpenWrt 顶层自动扫描 package/*，
# 本仓库即采用后者，与 package/turboacc、package/UA3F 的镜像方式一致）。
# 下方自动探测 luci.mk 的实际位置，两种布局都无需改动本文件。

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-campnet
PKG_VERSION:=0.2.0
PKG_RELEASE:=1

PKG_LICENSE:=WTFPL
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=ryanz <ryanz@users.noreply.github.com>

LUCI_TITLE:=Campus network auto-auth & multi-WAN bond (CampNet)
LUCI_DESCRIPTION:=Campus portal auto login (default gateway 10.0.1.51), per-account macvlan dial-up and mwan3 load balancing for bandwidth aggregation. Shell backend + native LuCI2 JS UI.
LUCI_DEPENDS:=+luci-base +curl +ip-full +jsonfilter +mwan3
LUCI_PKGARCH:=all

# 安装后初始化（opkg install 时执行；首刷镜像由 uci-defaults 兜底）
define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/campnet enable 2>/dev/null
	/etc/init.d/campnet start 2>/dev/null
	rm -f /tmp/luci-indexcache.* /tmp/luci-modulecache.* /tmp/luci-indexcache/
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
	exit 0
}
exit 0
endef

# 自动定位 luci.mk：feeds/luci 布局下为 ../../luci.mk；
# 镜像到 package/ 布局下为 $(TOPDIR)/feeds/luci/luci.mk
LUCI_MK:=$(if $(wildcard ../../luci.mk),../../luci.mk,$(TOPDIR)/feeds/luci/luci.mk)
include $(LUCI_MK)

# call BuildPackage - OpenWrt buildroot signature
