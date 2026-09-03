# luci-app-campnet — 校园网自动认证 + 多账号多播均衡

[![License: WTFPL](https://img.shields.io/badge/License-WTFPL-brightgreen.svg)](LICENSE)
[![OpenWrt](https://img.shields.io/badge/OpenWrt-Supported-brightgreen.svg)](https://openwrt.org/)

面向 ImmortalWrt / OpenWrt（23.05 系，LuCI2 JS）的校园网 Portal 认证插件：
**断线自动重连 + 每账号独立 macvlan WAN + mwan3 均衡（多账号带宽倍增）**，
带原生 LuCI 交互配置界面（非旧式“卡片风”自绘 UI）。

- 调研记录：`docs/research-notes.md`　设计方案：`docs/design.md`
- 后端：POSIX shell（认证 / 保活 / 编排），前端：LuCI2 原生 JS view + form

## 功能

| 模块 | 说明 |
|---|---|
| 自动登录 | 默认认证网关 `10.0.1.51`，支持两种认证系统（可切换/自动探测） |
| 断线自动重连 | `/etc/init.d/campnet` procd 服务，每账号一个 keeper 实例周期探测，掉线立即重试登录 |
| 多播均衡（带宽倍增） | 每账号一条独立 `macvlan + DHCP` WAN（独立 MAC 防风控），`mwan3` 负载均衡 |
| LuCI 交互界面 | 状态总览 / 设置 / 日志 三页，原生组件观感 |
| 帐密安全 | 帐密存 `/etc/campnet/.config`（0600），**不入 uci、不入 Git**（`.config` 已 `.gitignore`） |
| 日志 | `/var/log/campnet/campnet.log` 行数轮转 + 敏感字段写入前脱敏 |
| 增强项 | auto 模式自动探测门户类型、多播一键 setup/teardown（幂等、只动自建资源）、MAC 固化、开机自启、状态缓存 |

> 带宽倍增边界（与调研一致）：mwan3 为 per-flow 均衡，**多线程/多连接**场景才能叠加带宽；
> 单线程单连接不会叠加。

## 目录结构（仓库即 LuCI 应用包）

```
Makefile                      # OpenWrt 包 Makefile（PKG_NAME=luci-app-campnet）
LICENSE                       # WTFPL 2.0
.config.example               # 本地运行时配置样例（含默认 学号/密码 与网关）
.config                       # 本地运行时配置（已被 .gitignore 忽略，勿提交）
scripts/gen-config.sh         # .config 生成 / 同步为打包默认模板
docs/{research-notes.md,design.md}
tests/static-checks.sh        # 交付前静态自检（sh -n / JSON / JS / lib 冒烟）
root/                         # → 安装到设备根 /
  etc/config/campnet          #   uci 默认配置（非敏感）
  etc/campnet/.config.default #   帐密首启模板（默认 202524104131/240414）
  etc/init.d/campnet          #   procd 服务（每账号一实例）
  etc/uci-defaults/40_luci-campnet  # 首启：种子 .config + 自启
  usr/libexec/campnet/        #   后端：campnet(CLI) lib.sh ruijie.sh eportal.sh
  usr/libexec/rpcd/luci.campnet     #   keeper.sh dial.sh status.sh
  usr/share/luci/menu.d/、rpcd/acl.d/  # 菜单 / 权限
htdocs/luci-static/resources/view/campnet/  # LuCI2 JS：overview / settings / log
```

## 安装

把仓库目录放入 LuCI feed 或直接放入源码树：

```bash
# 方式一（推荐，LuCI feed 布局）
ln -s "$PWD" <immortalwrt>/feeds/luci/applications/luci-app-campnet
./scripts/feeds update -i && ./scripts/feeds install -a
make menuconfig   # LuCI → Applications → luci-app-campnet（*）
make package/luci-app-campnet/compile

# 方式二：放入 <immortalwrt>/package/custom/luci-app-campnet，
# 并把 Makefile 里 "include ../../luci.mk" 改为
#   include $(TOPDIR)/feeds/luci/luci.mk
```

依赖：`luci-base curl ip-full jsonfilter mwan3`（opkg 自动安装）。

装好后访问 **LuCI → 服务 → 校园网认证 CampNet**。

## 快速上手

1. `服务 → 校园网认证 CampNet → 设置`：核对「认证网关」默认 `10.0.1.51`；
   若你的校园网不是 axe_bras/webauth.do 系统，把「认证模式」切到 `eportal` 或 `auto`。
2. 页底「帐密」区：选 `main` 账号，填学号密码，点保存（写入 `/etc/campnet/.config`，0600）。
3. 回「状态总览」点 **立即登录全部**；keeper 每 `check_interval` 秒自动保活。
4. 加号带宽倍增：设置页新增账号段（`create_vlan=1`），补帐密 → 总览点
   **重建多播线路**，或重启服务自动编排。

### CLI（SSH 下）

```sh
campnet status [-j]                     # 状态（JSON）
campnet auth all --force                # 立即登录全部账号
campnet auth main                       # 只登录 main
campnet dial setup|teardown|status      # 多播线路编排/撤销/查看
campnet secret set <学号> <密码> [账号]  # 写帐密
campnet secret show [账号]              # 查看是否已配置（脱敏）
campnet log [行数]                      # 日志
campnet test [账号]                     # 连通性自检
/etc/init.d/campnet {start|stop|restart|enable|disable}
```

## 配置参考（uci `campnet`）

- `settings`：`enabled`、`auth_mode`(ruijie|eportal|auto)、`gateway`(默认 10.0.1.51)、
  `probe_url`、`check_interval`(120s)、`max_retry`/`retry_delay`、`poll_max`/`poll_interval`、
  `uplink`(auto)、`dial_on_start`、`wlanacname`、`pageid`、`templatetype`、`vlan`、`auth_type`、
  `auth_host`/`server_ip`（可选域名+IP，--resolve 绕 DNS）、curl 超时。
- `account`：每账号一段（named），`enabled`、`iface`(uci 接口，默认 wan)、
  `create_vlan`(1=建独立 macvlan 通道)、`macaddr`(留空自动生成固化)、`metric`、`weight`。
- 帐密：`/etc/campnet/.config`，`[default]`=main，`[account:<id>]`=附加账号。

## 认证算法（默认 ruijie / axe_bras）

移植自本地项目 campus-auth-openwrt（GXSTNU axe_bras/webauth.do 一键登录流程，见 docs/）：

1. Cookie 播种：`GET http://<gateway>/`（若配了 `auth_host` 再播种其 https 根）。
2. 表单 `POST https://<host>/webauth.do`：`wlanacip/wlanacname/wlanuserip/mac/vlan/scheme/
   serverIp/hostIp/pageid/templatetype/...`，账号密码 `--data-urlencode`。
3. 若响应含「正在进行外网拨号/请稍候」→ 轮询 `POST /getAuthResult.do`
   （`userId + pageId`，poll_max×poll_interval）。
4. 在线判定：探针 URL 返回 204，或 `ping -I <dev> 223.5.5.5`。

`eportal` 模式（kanoverse 调研结论）：从网关被劫持响应提取 `eportal/index.jsp?<queryString>`，
双 URL 编码后 `POST /eportal/InterFace.do?method=login`（`result:"success"` 判成功）。

## 多播均衡原理

```
物理WAN(ethX) ─┬─ wan(main 账号，直连)
               ├─ campnet_acc2 (macvlan, 独立MAC) ─ DHCP → 账号2
               ├─ campnet_acc3 (macvlan, 独立MAC) ─ DHCP → 账号3
               └─ …
全部接口 → mwan3 member/metric/weight → policy campnet_balanced
        → rule campnet_rule(0.0.0.0/0)（自动置于 default_rule 之前）
```

- `dial setup` 幂等：只增不改用户已有配置；自建资源登记在 `/etc/campnet/.created`，
  `dial teardown` 只删登记过的资源。
- macvlan 由 netifd 托管（`config device` type macvlan + mode bridge），重启自动重建；
  MAC 生成后写回 uci `macaddr`，重启不漂移。
- 主账号 `main` 默认 `create_vlan=0`（直连 wan）；要叠加带宽，再加 `create_vlan=1` 的账号段即可。

## 安全

- 帐密绝不进 uci / Git：`.config` 已在 `.gitignore`；仓库只含脱敏样例与首启默认模板
  （`.config.default`，随固件/ipk 携带默认 学号/密码，请按需修改）。
- 日志对所有请求体做脱敏（passwd/password/userId/queryString/mac/wlanuserip/distoken → `***`）。
- cookie/锁文件放 `/tmp`；认证所需静态路由只加不改，失败静默。

## 测试与验证（本仓库内可执行）

```sh
./tests/static-checks.sh     # sh -n / JSON / node --check / lib 纯函数冒烟
```

真机验证项（固件编译与校园网实网不可在此环境进行，已在 docs/design.md 风险节说明）：
认证成功率、mwan3 均衡命中顺序、macvlan DHCP、服务 reload 触发链。

## License

[WTFPL 2.0](LICENSE) —— DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE.
