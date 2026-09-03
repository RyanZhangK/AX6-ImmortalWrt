# 调研记录：OpenWrt 校园网认证与多账号带宽叠加

> 本文件记录设计前对两个指定来源（外加其引用的第三方资料）的调研要点，
> 作为 `design.md` 与代码实现的依据。全部要点均来自公开资料/代码，不含真实密码。

## 1. kanoverse 文章《OpenWrt 校园网共享》

来源：https://www.kanoverse.com/article/openwrt-campus-network-sharing（2025-09-15，華乃のスペース）

### 目标与结论
- 校园网「单账号仅限两台设备」→ 通过路由器把整网变成「一台设备」接入；Wi-Fi 客户端随意接入。
- 多账号带宽叠加：100M 账号 + 50M 账号经 mwan3 均衡后，多线程测速/下载可突破单账号上限；
  单线程无法叠加（mwan 是 per-flow/包均衡，非单连接聚合）。
- 硬件：二手 H3C NX30 Pro（MT7981B / 128M Flash / 256M RAM），自编译精简 ImmortalWrt 23.05.6
  （仅保留 mwan、turboacc、fileassistant、upnp 等，固件约 15.4MB）。

### 关键做法（架构层面可复用）
1. **认证算法逆向**：任意网址被 DNS 劫持/302 重定向到认证页 → 判定为锐捷（Ruijie）系 Web
   Portal 认证 → 直接移植社区已验证的登录算法，无需自研逆向。
   引用文章：Mars-Luke《校园网认证流程分析及自动认证脚本》
   https://www.cnblogs.com/0x000001/p/18766279（详见第 3 节）。
2. **保活方式**：OpenWrt `init.d` + `procd` 守护登录状态 —— 周期性探测，离线自动登录；
   **每个账号一份独立 init 服务**（脚本内用接口名区分：`campus_portal_eth1` 等），
   保证各账号登录控制互不干扰。
3. **多账号承载**：`Macvlan` 虚拟接口 —— 每个账号一个 macvlan 设备 + 对应 DHCP 客户端接口，
   放入 `wan` 防火墙区域；多 WAN 交给 `mwan3` 负载均衡（iptables + fwmark 路由规则）。

### 参考要点
- macvlan：LuCI「网络 → 接口 → 设备」添加 macvlan（选择基础物理设备），再建 DHCP 接口 + wan 区域。
- mwan3 单线程不叠加带宽 → 需在文档中明示「带宽倍增 = 多线程/多连接场景」。

## 2. 本地项目 campus-auth-openwrt（/home/ryanz/Projects/campus-auth-openwrt）

> 只读调研；该项目为 GXSTNU（锐捷 axe_bras）校园网 Portal 认证 + mwan3 多线路故障切换。
> 主要文件：README.md、docs/CONFIGURATION.md、docs/PORTAL_AUTH_PAGE_NOTES.md、install.sh(≈1282 行)、
> docs/CONTRIBUTING.md、tests/check_install_templates.py。许可证 MIT。

### 2.1 认证算法（axe_bras / webauth.do，核心可复用点）
- 认证服务器形态：`axe_bras/1.0` BRAS。访问 AC 地址 `http://<AC_IP>/` 返回 302 → 门户
  `https://<auth_domain>/webauth.do?...`（query 含 wlanacip/wlanacname/wlanuserip/mac/vlan/distoken/url…）。
- 一键登录的简洁 POST（项目默认不依赖 urlParameter/distoken，理由见
  docs/PORTAL_AUTH_PAGE_NOTES.md —— 减少会话字段过期/日志泄露/BRAS 跳转异常风险）：
  1. Cookie 播种：`curl -skL http://<AC_IP>/`（拿到门户会话 cookie），再 `curl -sk https://<auth_domain>/`。
  2. 构造表单（application/x-www-form-urlencoded）：
     `wlanacip=<AC_IP>&wlanacname=<AC_NAME>&wlanuserip=<本机IP>&mac=<小写MAC>&vlan=0`
     `&scheme=https&serverIp=tomcat_server1:443&hostIp=http://127.0.0.1:8446/&auth_type=0`
     `&isBindMac1=0&pageid=5&templatetype=1&portalVer=0&tservertypeid=axe&realTerminalType=a`
     `&operatorastrict=0,1,2,3&url=http://<AC_IP>&remInfo=on`
     `&userId=<账号>&passwd=<密码>`（账号密码用 `--data-urlencode`，避免特殊字符破坏表单）。
  3. `POST https://<auth_domain>/webauth.do`（`-k` 忽略自签证书，可用 `--resolve
     <domain>:443:<server_ip>` 绕过 DNS）。
- 延迟拨号处理：若响应含「正在进行外网拨号请稍候」，则轮询 `POST https://<auth_domain>/getAuthResult.do`
  （`userId=<账号>&pageId=5`，最多 20 次 × 2s），直到返回成功或外网连通。
- 在线判定：`curl --interface <wan> http://connect.rom.miui.com/generate_204`；
  `204`=已认证，`301/302/200`=需认证（被劫持/重定向），其它=离线；辅助 `ping -I <wan> 223.5.5.5`。
- 安全点（保留到新实现）：认证前添加静态路由 `ip route add <server_ip> via <gw> dev <wan>`；
  日志脱敏（passwd/userId/mac/distoken/wlanuserip 打码）；`/tmp` cookie 文件；
  密码 `ENC:` base64+字母轮换混淆（新实现按 DoD 改为 `.config` 文件 + 0600 权限存储）。

### 2.2 多线路/mwan3（本项目为故障切换，非均衡）
- mwan3 配置含接口跟踪（ping 223.5.5.5/119.29.29.29）、member（metric/weight）、
  policy（failover 故障切换）、rule（0.0.0.0/0 → failover）。
- `/etc/mwan3.user` 钩子：WAN ifup 事件触发认证检查。
- 0 点/6 点定时断网/恢复 + 每 30 分钟保活检查（crontab）。

### 2.4 管理框架（UI 丑，只参考框架不参考样式 —— 用户指示）
- LuCI（Lua 旧式）：controller `admin/services/campus_auth` + CBI model + 自定义 HTML 视图；
  页面为整页自定义 CSS 的「卡片风」控制台（状态/按钮/日志），风格与 LuCI 原生不一致 —— 新实现改为
  LuCI2 JS（`view` + `form` 原生组件），保持系统观感统一。
- 后端 CLI：`/root/campus_auth.sh {login|check|status|hook|midnight|morning|encrypt|test}`，
  配置读 uci `campus_auth.@auth[0]`；日志 `/var/log/campus_auth.log`（500 行轮转）。

### 2.5 可复用清单 / 不足
可复用：axe webauth.do 完整算法、拨号延迟轮询、generate_204 判定、日志脱敏思路。
不足：单账号单线路（无 macvlan 多拨）；mwan3 只做 failover 不做均衡；
依赖 uci 明文/混淆密码（DoD 要求 .config 文件）；旧式 Lua CBI UI。

## 3. kanoverse 引用文章（Mars-Luke，博客园 0x000001）

来源：https://www.cnblogs.com/0x000001/p/18766279《校园网认证流程分析及自动认证脚本》

- 场景：`http://<gateway>/eportal/index.jsp?<queryString>` 型 Web 门户（另一类校园网认证系统），
  被劫持页面里 `top.self.location.href='http://<gw>/eportal/index.jsp?...'` 取出 queryString。
- 登录接口：`POST http://<gw>/eportal/InterFace.do?method=login`，参数：
  `userId=<账号>&password=<密码>&service=&queryString=<两次URL编码的queryString>
   &operatorPwd=&operatorUserId=&validcode=&passwordEncrypt=false`
- 成功判定：响应 JSON 含 `"result":"success"`；否则取 `"message"` 提示。
- 价值：展示了「纯 IP 网关门户」的通用登录形态 —— 与仅给 IP（10.0.1.51）的部署匹配，
  无需域名。新实现将其作为 `eportal` 模式内置，与 `ruijie` 模式可切换。

## 4. 需求侧事实（来自任务）
- 默认账号 `202524104131` / 密码 `240414`，网关 `10.0.1.51`。
- 帐密必须存 `.config` 文件且加入 `.gitignore`（不进 Git）。
- 多播均衡 = 多账号（或同号多次）分别登录独立 WAN → mwan3 均衡 → 带宽倍增（多线程场景）。
- 目标固件：ImmortalWrt（23.05/24.10 系，LuCI2 JS + ucode rpcd 可用）。

## 5. 结论（设计输入）
1. 后端复用 axe_bras 算法为主、eportal 算法为辅，均做成「配置可切换、网关默认 10.0.1.51」。
2. 每账号 = macvlan(独立 MAC) + DHCP 接口 + wan 防火墙区域 + 独立保活认证；procd 每账号实例。
3. 均衡层用 mwan3（member + balanced policy），幂等注入、不覆盖用户既有配置。
4. 帐密 `.config`(0600) 管理；UI 为 LuCI2 JS 原生组件；CLI 供手动/脚本使用。
