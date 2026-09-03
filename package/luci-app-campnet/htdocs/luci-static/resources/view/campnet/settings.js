'use strict';
'require form';
'require rpc';
'require view';
'require ui';

var getStatus = rpc.declare({
	object: 'luci.campnet',
	method: 'getStatus'
});

var setSecret = rpc.declare({
	object: 'luci.campnet',
	method: 'setSecret',
	params: [ 'account', 'username', 'password' ],
	expect: { ok: false }
});

return view.extend({
	load: function () {
		return L.resolveDefault(getStatus(), {});
	},

	render: function (data) {
		var st = data || {};
		var m, s, o;

		m = new form.Map('campnet', _('校园网认证 CampNet 设置'),
			_('后端 shell + 前端 LuCI2。帐密不存 uci —— 见页面底部「帐密」区（/etc/campnet/.config, 0600）。'));

		/* ---------------- 基本 ---------------- */
		s = m.section(form.NamedSection, 'settings', _('基本'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('启用插件'), _('关闭后停止保活与多播编排（可用 CLI 手动登录）。'));
		o.default = '1';

		o = s.option(form.ListValue, 'auth_mode', _('认证模式'), _('ruijie=axe_bras(webauth.do) 默认；eportal=纯网关 eportal 门户；auto=按页面特征自动探测。'));
		o.value('ruijie', _('ruijie — axe_bras (webauth.do)'));
		o.value('eportal', _('eportal — Ruijie eportal (InterFace.do)'));
		o.value('auto', _('auto — 自动探测'));
		o.default = 'ruijie';

		o = s.option(form.Value, 'gateway', _('认证网关'), _('BRAS/Portal 网关 IP，用于登录与在线验证。默认 10.0.1.51。'));
		o.default = '10.0.1.51';
		o.placeholder = '10.0.1.51';

		o = s.option(form.Value, 'probe_url', _('在线探针 URL'), _('返回 HTTP 204 视为已认证。'));
		o.default = 'http://connect.rom.miui.com/generate_204';

		o = s.option(form.Value, 'check_interval', _('保活周期（秒）'), _('keeper 探测间隔；掉线即重连，无需等满周期才探测（探测失败立触）。'));
		o.datatype = 'uinteger';
		o.default = '120';

		o = s.option(form.Value, 'max_retry', _('登录重试次数'));
		o.datatype = 'uinteger';
		o.default = '3';

		o = s.option(form.Value, 'retry_delay', _('重试间隔（秒）'));
		o.datatype = 'uinteger';
		o.default = '5';

		/* ---------------- 多播均衡 ---------------- */
		s = m.section(form.NamedSection, 'settings', _('多播均衡（带宽倍增）'));
		s.anonymous = true;

		o = s.option(form.Flag, 'dial_on_start', _('开机自动编排'), _('服务启动时自动为 create_vlan=1 的账号建立 macvlan 通道并注入 mwan3（幂等）。'));
		o.default = '1';

		o = s.option(form.Value, 'uplink', _('上行基础设备'), _('macvlan 挂在哪个物理/逻辑设备上。auto=自动取主 wan 的内核设备（如 eth1.2）。'));
		o.default = 'auto';

		o = s.option(form.Value, 'poll_max', _('外网拨号轮询上限'), _('axe_bras「正在进行外网拨号」时轮询 getAuthResult.do 的次数。'));
		o.datatype = 'uinteger';
		o.default = '20';

		o = s.option(form.Value, 'poll_interval', _('拨号轮询间隔（秒）'));
		o.datatype = 'uinteger';
		o.default = '2';

		/* ---------------- ruijie 参数 ---------------- */
		s = m.section(form.NamedSection, 'settings', _('ruijie(axe_bras) 表单参数'),
			_('一般保持默认即可适配锐捷 axe 系；换学校时按抓包调整。'));
		s.anonymous = true;

		o = s.option(form.Value, 'wlanacname', _('wlanacname'));
		o.default = 'BRAS';

		o = s.option(form.Value, 'pageid', _('pageid'));
		o.datatype = 'uinteger';
		o.default = '5';

		o = s.option(form.Value, 'templatetype', _('templatetype'));
		o.datatype = 'uinteger';
		o.default = '1';

		o = s.option(form.Value, 'vlan', _('vlan'));
		o.datatype = 'uinteger';
		o.default = '0';

		o = s.option(form.Value, 'auth_type', _('auth_type'));
		o.datatype = 'uinteger';
		o.default = '0';

		o = s.option(form.Value, 'auth_host', _('认证域名（可选）'), _('独立认证域名；留空则直接用 gateway IP 认证（自托管门户）。'));
		o.placeholder = 'auth.example.edu.cn';

		o = s.option(form.Value, 'server_ip', _('认证服务器 IP（可选）'), _('配合 auth_host 使用 --resolve 绕过 DNS；留空则直连 gateway。'));

		o = s.option(form.Value, 'curl_connect_timeout', _('连接超时（秒）'));
		o.datatype = 'uinteger';
		o.default = '5';

		o = s.option(form.Value, 'curl_timeout', _('请求超时（秒）'));
		o.datatype = 'uinteger';
		o.default = '12';

		/* ---------------- 账号（多播） ---------------- */
		s = m.section(form.TypedSection, 'account', _('账号（多账号多播）'),
			_('每个账号一段。create_vlan=1 会为该账号建立独立 macvlan WAN + DHCP（独立 MAC）并加入 mwan3 均衡；多账号并网后多线程带宽倍增。默认已内置 main（直接走 wan，无需额外通道）。'));
		s.addremove = true;
		s.anonymous = false;

		o = s.option(form.Flag, 'enabled', _('启用该账号'));
		o.default = '1';

		o = s.option(form.Value, 'iface', _('UCI 网络接口'), _('该账号绑定到哪个 network 接口（内核设备由其 device 解析）。主通道常用 wan。'));
		o.default = 'wan';

		o = s.option(form.Flag, 'create_vlan', _('建立独立 macvlan 通道'), _('开 = 为该账号生成 campnet_<id> 设备/接口（独立 MAC + DHCP）；关 = 直接使用上面接口。'));
		o.default = '0';

		o = s.option(form.Value, 'macaddr', _('macvlan MAC（可留空）'), _('留空则首次 setup 自动生成并写回此处（重启不漂移）。'));

		o = s.option(form.Value, 'metric', _('mwan3 metric'), _('越小优先级越高。'));
		o.datatype = 'uinteger';
		o.default = '10';

		o = s.option(form.Value, 'weight', _('mwan3 weight'), _('均衡权重，带宽倍数参考。'));
		o.datatype = 'uinteger';
		o.default = '10';

		/* ---------------- 帐密（.config 文件） ---------------- */
		var that = this;
		var accSel = E('select', { 'class': 'cbi-input-select', 'id': 'campnet-secret-acc' }, []);
		var userIn = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'id': 'campnet-secret-user', 'autocomplete': 'off', 'placeholder': _('学号 / 用户名') });
		var passIn = E('input', { 'class': 'cbi-input-text', 'type': 'password', 'id': 'campnet-secret-pass', 'autocomplete': 'new-password', 'placeholder': _('密码') });

		(st.accounts || []).forEach(function (a) {
			accSel.appendChild(E('option', { 'value': a.id }, [ a.id + ' (' + (a.status || 'unknown') + ')' ]));
		});
		if (!(st.accounts || []).length)
			accSel.appendChild(E('option', { 'value': 'main' }, [ 'main' ]));

		var saveSecret = E('button', {
			'class': 'cbi-button cbi-button-apply',
			'click': function (ev) {
				ev.preventDefault();
				var acc = accSel.value || 'main';
				var user = userIn.value.trim();
				var pass = passIn.value;
				if (!user || !pass) {
					ui.addNotification(null, E('p', {}, [ _('用户名与密码都不能为空') ]), 'warning');
					return;
				}
				this.disabled = true;
				setSecret({ account: acc, username: user, password: pass }).then(function (r) {
					if (r && r.ok)
						ui.addNotification(null, E('p', {}, [ _('帐密已保存到 /etc/campnet/.config') ]));
					else
						ui.addNotification(null, E('p', {}, [ _('保存失败，请查看系统日志') ]), 'error');
					this.disabled = false;
				}.bind(this));
			}
		}, [ _('保存帐密') ]);

		var secretCard = E('div', { 'class': 'cbi-section' }, [
			E('h3', _('帐密（写入 /etc/campnet/.config，不经过 uci）')),
			E('div', { 'class': 'cbi-section-descr' }, [
				_('选择账号 → 填写学号与密码 → 保存。文件权限 0600，默认值见 .config.default；修改后保活下次周期即生效，也可回总览点「立即登录」。')
			]),
			E('table', { 'class': 'table', 'style': 'width:auto' }, [
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left' }, [ _('账号') ]),
					E('td', { 'class': 'td left' }, [ accSel ])
				]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left' }, [ _('用户名') ]),
					E('td', { 'class': 'td left' }, [ userIn ])
				]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left' }, [ _('密码') ]),
					E('td', { 'class': 'td left' }, [ passIn ])
				]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left' }, [ '' ]),
					E('td', { 'class': 'td left' }, [ saveSecret ])
				])
			])
		]);

		var formEl = m.render();
		return E('div', {}, [ formEl, secretCard ]);
	}
});
