# 设计方案：luci-app-campnet —— 校园网自动认证 + 多账号多播均衡（ImmortalWrt）

> 调研依据见 [research-notes.md](research-notes.md)。
> 一句话：把「每账号一个 Macvlan WAN + 自动 Portal 登录 + mwan3 均衡」做成一个标准 OpenWrt/LuCI 插件，
> 前端用 LuCI2 原生 JS 组件，后端用 shell（procd 保活），打包为单 ipk（`luci-app-campnet`）。

## 1. 总体架构

```
┌────────────────────────────────────────────────────────────┐
│ LuCI2 Web（浏览器）                                        │
│   overview.js / config.js / log.js  (原生 JS view+form)    │
│        │  JSON-RPC (rpcd)                                  │
│        ▼                                                   │
│ /usr/share/rpcd/ucode/campnet.uc  (ubus: luci.campnet)     │
│    └ 调用后端 CLI：campnet {status|auth|dial|service|...}  │
├────────────────────────────────────────────────────────────┤
│ 后端                                                        │
│   /etc/init.d/campnet        procd 服务（每账号一个实例）    │
│   /usr/libexec/campnet/      lib.sh(公共) ruijie.sh eportal.sh│
│                              keeper.sh(保活循环) dial.sh(线路)│
│                              campnet(CLI入口) status.sh     │
│   配置:  /etc/config/campnet (uci，非敏感)                   │
│          /etc/campnet/.config (帐密，0600，DoD)             │
├────────────────────────────────────────────────────────────┤
│ 系统层                                                      │
│   macvlan 设备 campnetN ── DHCP 接口(wan 区域) ── 独立认证会话│
│   mwan3: member campnetN_m1 + policy campnet(balanced)      │
│   /etc/mwan3.user 钩子：接口 up 后自动触发认证               │
└────────────────────────────────────────────────────────────┘
```

- **前端**：LuCI2 客户端 JS（`htdocs/luci-static/resources/view/campnet/*`），
  菜单注册在 `/usr/share/luci/menu.d`，权限在 `/usr/share/luci/acl.d`，
  RPC 由 rpcd ucode 插件 `campnet.uc` 暴露 `luci.campnet` 对象。观感与系统 LuCI 一致
  （不使用旧项目「整页自定义 CSS 卡片」风格）。
- **后端**：POSIX shell，全部经 `lib.sh` 加载配置与日志；认证核心 `ruijie.sh`（axe_bras，
  默认，复用调研到的成熟算法）与 `eportal.sh`（纯网关 IP 门户）二选一由 uci `auth_mode` 决定。
- **保活**：procd 实例每账号一个（`keeper.sh --account <名>`），周期检查在线状态，离线即认证；
  procd `respawn` 兜底崩溃重启。
- **多播均衡**：`dial.sh` 为每个启用账号生成 macvlan + DHCP 接口（独立随机 MAC，MAC 固化在 uci
  防漂移）+ 加入 wan 区域；随后幂等注入 mwan3 member/policy（balanced），N 个账号 = N 条带宽，
  多线程场景带宽倍增。
- **配置**：非敏感（开关、网关、模式、间隔、接口）走 uci `campnet`；帐密（学号/密码）落盘
  `/etc/campnet/.config`（`chmod 600`），仓库内 `.config` 同样被 `.gitignore` 排除。

## 2. 认证流程

### 2.1 通用探测（每账号、每保活周期）
```
1. ip 存在？(ip -4 addr show <iface>)            否则 → OFFLINE（等待 DHCP）
2. curl --interface <iface> -m5 -o/dev/null -w%{http_code} http://connect.rom.miui.com/generate_204
   └ 204          → AUTHENTICATED（跳过登录，保活）
   └ 301/302/200  → NEED_AUTH（被劫持/重定向到门户）
   └ 其它/空      → 网关可达但探测异常 → 重试几次后按 NEED_AUTH 处理
3. 网关校验：ping/HTTP 探测 CAMP_GATEWAY(10.0.1.51) —— 确认处于该校园网段
```

### 2.2 ruijie 模式（默认，axe_bras / webauth.do —— 来自调研 §2.1）
```
1. Cookie 播种: GET http://<AC_IP或网关>/  → cookie.jar；GET https://<auth_host>/（如有域名）
2. 构造表单 wlanacip/wlanacname/wlanuserip(本接口IP)/mac(本接口小写)/
   vlan/scheme/https 字段组 + userId + passwd(--data-urlencode)
3. POST https://<auth_host>/webauth.do  (-k；--resolve host:443:<server_ip> 可选)
4. 响应含「正在进行外网拨号」→ 轮询 POST /getAuthResult.do(userId,pageId) 直到成功/超时
5. 校验：generate_204 == 204 或 ping 通外网 → 成功；否则重试(max_retry×retry_delay)
```
默认参数：`auth_host` 留空则使用 `CAMP_GATEWAY`(10.0.1.51) 作为 BRAS 与登录主机；
`wlanacip = CAMP_GATEWAY`、`wlanacname`、`pageid/templatetype` 等全部可从 LuCI 覆盖，
便于适配任意锐捷 axe 校园网。

### 2.3 eportal 模式（可选，纯 IP 门户 —— 来自调研 §3）
```
1. 探测被劫持响应中 Location/JS:  http://<gw>/eportal/index.jsp?<queryString>
2. queryString 两次 URL 编码
3. POST http://<gw>/eportal/InterFace.do?method=login
   userId/password/service=/queryString(双编码)/passwordEncrypt=false
4. JSON "result":"success" → 成功；否则取 "message" 上报日志
```

### 2.4 日志与安全
- 统一日志 `/var/log/campnet/campnet.log`（行数轮转，保留最后 ~800 行）；
- 所有输出脱敏：`passwd/userId/queryString/mac/wlanuserip/distoken` 打码；
- cookie/锁文件在 `/tmp`；`.config` 权限 0600，仅 root 可读。

## 3. 多账号 / 多播均衡（带宽倍增）

1. `dial.sh setup`（可由 LuCI 一键触发，或首次 `service campnet start` 自动执行）：
   - 对每个 `enabled=1` 的 account 段（上限默认 8）：
     - macvlan 设备 `campnetN`：`ip link add campnetN link <uplink> type macvlan mode bridge`，
       MAC 取 `account.macaddr`（无则随机生成并写回 uci，保证重启/重装不漂移）；
     - 网络接口 `campnetN`（uci network）：proto dhcp、device campnetN；
     - 防火墙：接口划入 `wan` 区域（不新建 zone，避免改默认拓扑）；
   - mwan3 注入（幂等，不覆盖用户既有配置，全部使用 `campnet_` 前缀命名）：
     - interface 段（跟踪 ping 223.5.5.5、119.29.29.29）→ member `campnetN_m1`
       （metric=N、weight=10）→ policy `campnet`（balanced）→ rule `campnet_rule`
       （dest 0.0.0.0/0 → policy campnet）。
2. mwan3 按 flow 分发 → 多账号并发会话 → 多线程下载/测速叠加带宽；
   单线程不叠加（与调研结论一致，README/UI 均明示）。
3. 每个 WAN 由独立 procd 实例保活登录；某条断线只影响该条，mwan3 自动把流量分给健康线路。
4. `dial.sh teardown`：撤销本插件创建的全部 macvlan/接口/mwan3 段（仅删带 `campnet` 前缀项）。

## 4. 自启动 / 增强项

- **开机自启**：uci-defaults 写入默认 uci 配置 + `service campnet enable`；
  若 `settings.start_on_boot=1` 开机自动拨号（`hotplug/iface` 触发亦可）。
- **断线自动重连**：keeper 周期（`check_interval`，默认 120s）探测 + 掉线即时登录（重试 3 次），
  procd respawn 防僵死；`/etc/mwan3.user` 在接口 up 时通知认证。
- **状态展示**：overview 页轮询每账号 在线/离线/认证中、IP/MAC/上次结果/最近登录时间，
  及 mwan3 线路状态、整体外网连通性。
- **日志页**：按级别过滤 + 行数选择 + 手动刷新。
- **一键操作**：立即认证（全部/单账号）、重建多播线路、启停服务 —— 均走 LuCI 按钮。

## 5. 目录/文件规划（打包到固件的路径）

```
Makefile                       # OpenWrt 包 Makefile (PKG_NAME=luci-app-campnet)
LICENSE                        # WTFPL
README.md
docs/{design.md,research-notes.md}
.config / .config.example / .gitignore / scripts/gen-config.sh
root/etc/campnet/.config.default      # 帐密默认模板（uci-defaults 首次落地到 .config）
root/etc/uci-defaults/campnet         # 首装：生成 /etc/config/campnet + /etc/campnet/.config
root/etc/init.d/campnet               # procd 服务（多实例）
root/usr/libexec/campnet/lib.sh       # 公共函数：配置/日志/脱敏/探测
root/usr/libexec/campnet/ruijie.sh    # axe_bras 认证
root/usr/libexec/campnet/eportal.sh   # eportal 认证
root/usr/libexec/campnet/keeper.sh    # 每账号保活循环
root/usr/libexec/campnet/dial.sh      # macvlan/mwan3 多播线路编排
root/usr/libexec/campnet/status.sh    # JSON 状态输出
root/usr/libexec/campnet/campnet      # CLI 入口（status/auth/dial/service/log/secret）
root/usr/share/luci/menu.d/luci-app-campnet.json
root/usr/share/luci/acl.d/luci-app-campnet.json
root/usr/share/rpcd/ucode/campnet.uc
htdocs/luci-static/resources/view/campnet/{overview,config,log}.js
```

## 6. 关键默认值

| 项 | 默认 | 说明 |
|---|---|---|
| uci 配置 | `/etc/config/campnet` | 非敏感配置 |
| 帐密文件 | `/etc/campnet/.config` (0600) | 默认 `202524104131` / `240414` |
| 网关 | `10.0.1.51` | 认证/验证网关（BRAS） |
| auth_mode | `ruijie` | `ruijie` \| `eportal` |
| 探测 | `connect.rom.miui.com/generate_204` | HTTP 204 判定 |
| check_interval | 120s | 保活周期 |
| max_retry / retry_delay | 3 / 5s | 登录重试 |
| 多播上限 | 8 账号 | mwan3 均衡 |
| uplink | `eth1`（可改） | macvlan 基础设备 |

## 7. 风险与未决（如实记录）
1. **门户参数依赖部署**：10.0.1.51 具体校园网的认证域名/页面字段未知，axe 模式默认在
   「网关自托管门户」假设下工作；若该网需独立 `auth_host`/`server_ip`，在 LuCI 填入即可，
   算法与调研项目完全一致。
2. **mwan3 规则顺序**：插件新增 catch-all rule 若与既有 `default_rule` 冲突，需在 mwan3 页面
   调整顺序；UI 已提示。默认不动用户已有 policy/rule。
3. **同号多拨限制**：带宽倍增依赖学校允许同一/多个账号并发会话；若 ISP 限制同号重复登录，
   需填多个账号（本插件支持任意账号数）。
4. 未能在真机/固件编译环境验证（本机为只读调研环境 + 不允许改动 immortalwrt 源码树），
   交付物以静态校验（sh -n / JSON / JS syntax）+ 设计一致性为准。

---

## 附录 A：实现落地与偏差（2026-09，交付时）

- 本仓库即 LuCI 应用包根目录（Makefile 位于仓库根，含 `include ../../luci.mk`）；
  后端 shell 与前端一并打包为单 ipk `luci-app-campnet`。
- 落地路径与本设计一致：`/etc/config/campnet`(uci) + `/etc/campnet/.config`(帐密 0600)
  + `/etc/init.d/campnet`(procd 每账号 keeper) + `/usr/libexec/campnet/*`(lib/ruijie/eportal/
  keeper/dial/status/campnet CLI) + `htdocs/.../view/campnet/{overview,settings,log}.js`。
- **偏差 1（RPC 后端）**：设计稿计划 `root/usr/share/rpcd/ucode/campnet.uc`(ucode)，
  实现改为 **rpcd exec 型 shell 插件** `/usr/libexec/rpcd/luci.campnet`
  （参考 luci-app-pbr/https-dns-proxy，jshn 输出 JSON），避免对 ucode 版本 API 的依赖；
  ACL 方法：getStatus/getLog/test/auth/setSecret/dialSetup/dialTeardown/setService。
- **偏差 2（设备管理）**：macvlan 采用 **netifd 托管 device 段**
  （`config device` type macvlan/mode bridge + `config interface` proto dhcp），
  重启自动重建；device 段 id 用 `campd_<base>` 与接口段 `campnet_<base>` 区分。
- **偏差 3（mwan3 规则）**：兜底规则 `campnet_rule` 用 uci 创建并 commit，
  再经纯 awk 整段移动到首个 `default_rule*` 之前（已用夹具验证重排正确性）。
- **偏差 4（reload）**：init.d 在 start 时后台异步执行 `dial setup`
  （避免阻塞开机与自触发 reload 循环）。
- 实现补充：`acct_iface_effective()` 保证 create_vlan=1 的账号由 keeper/登录/状态
  统一监控其专属 macvlan 接口而非 `wan`；`auto` 模式按网关页面特征选择 ruijie/eportal。
- 状态输出：`campnet status -j`（jshn）写于进程内，LuCI 通过 rpcd getStatus 读取；
  每账号状态缓存 `/var/run/campnet/<账号>.state`，由 keeper/登录更新（页面不实时探测，
  避免 UI 触发网络探测造成延迟）。
- 自检：`tests/static-checks.sh`（sh -n / JSON / node --check / lib 冒烟 24 项）全绿。
