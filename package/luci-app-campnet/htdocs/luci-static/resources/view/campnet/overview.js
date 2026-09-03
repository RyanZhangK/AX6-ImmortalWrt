'use strict';
'require view';
'require rpc';
'require ui';

var getStatus = rpc.declare({
	object: 'luci.campnet',
	method: 'getStatus'
});

var authAccount = rpc.declare({
	object: 'luci.campnet',
	method: 'auth',
	params: [ 'account' ],
	expect: { ok: false }
});

var dialSetup = rpc.declare({
	object: 'luci.campnet',
	method: 'dialSetup',
	expect: { ok: false }
});

var dialTeardown = rpc.declare({
	object: 'luci.campnet',
	method: 'dialTeardown',
	expect: { ok: false }
});

var STATUS = {
	authenticated: { text: _('已认证'), color: '#16a34a' },
	need_auth:     { text: _('需认证'), color: '#ea580c' },
	authing:       { text: _('认证中'), color: '#0284c7' },
	no_ip:         { text: _('无 IP'),  color: '#64748b' },
	offline:       { text: _('离线'),   color: '#64748b' },
	error:         { text: _('错误'),   color: '#dc2626' },
	unknown:       { text: _('未知'),   color: '#94a3b8' }
};

var MODES = {
	ruijie:  _('ruijie — axe_bras (webauth.do)'),
	eportal: _('eportal — Ruijie eportal (InterFace.do)'),
	auto:    _('auto — 自动探测')
};

function statusBadge(st) {
	var s = STATUS[st] || STATUS.unknown;
	return E('span', { 'style': 'color:' + s.color + ';font-weight:600' }, [ s.text ]);
}

function actionButton(text, cls, promiseFn) {
	return E('button', {
		'class': 'cbi-button ' + cls,
		'click': function (ev) {
			ev.preventDefault();
			this.disabled = true;
			promiseFn().then(function (r) {
				if (r && r.ok)
					ui.addNotification(null, E('p', {}, [ _('操作已执行') ]));
				else
					ui.addNotification(null, E('p', {}, [ _('操作失败，详见 /var/log/campnet/campnet.log') ]));
				window.setTimeout(function () { location.reload(); }, 700);
			}).catch(function () {
				this.disabled = false;
				ui.addNotification(null, E('p', {}, [ _('调用失败') ]));
			}.bind(this));
		}
	}, [ text ]);
}

return view.extend({
	load: function () {
		return L.resolveDefault(getStatus(), {});
	},

	render: function (st) {
		var s = st.settings || {};
		var accounts = st.accounts || [];

		var kv = function (k, v) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '200px' }, [ k ]),
				E('td', { 'class': 'td left' }, [ v ])
			]);
		};

		var control = E('div', { 'class': 'cbi-section' }, [
			E('h3', _('控制')),
			E('div', { 'class': 'cbi-section-descr' }, [
				_('立即登录全部账号 / 重建或撤销多播均衡线路（macvlan + mwan3）。')
			]),
			E('div', { 'style': 'margin:10px 0 0 0' }, [
				actionButton(_('立即登录全部'), 'cbi-button-action',
					function () { return authAccount({ account: 'all' }); }),
				E('span', ' '),
				actionButton(_('重建多播线路'), 'cbi-button-action',
					function () { return dialSetup(); }),
				E('span', ' '),
				actionButton(_('撤销多播线路'), 'cbi-button-reset',
					function () { return dialTeardown(); }),
				E('span', ' '),
				E('button', {
					'class': 'cbi-button cbi-button-apply',
					'click': function (ev) { ev.preventDefault(); location.reload(); }
				}, [ _('刷新') ])
			])
		]);

		var cfg = E('div', { 'class': 'cbi-section' }, [
			E('h3', _('当前配置')),
			E('table', { 'class': 'table', 'style': 'width:auto' }, [
				kv(_('总开关'), s.enabled ? _('启用') : _('停用')),
				kv(_('认证模式'), MODES[s.auth_mode] || s.auth_mode),
				kv(_('认证网关'), s.gateway || '-'),
				kv(_('保活周期'), (s.check_interval || '-') + ' s'),
				kv(_('重试策略'), (s.max_retry || '-') + ' 次 / ' + (s.retry_delay || '-') + ' s'),
				kv(_('保活进程数'), String(st.keepers || 0))
			])
		]);

		var th = [ _('账号'), _('接口 / 设备'), _('状态'), _('IP'), _('说明'), _('操作') ];
		var head = E('tr', { 'class': 'tr cbi-section-table-titles' }, th.map(function (t) {
			return E('th', { 'class': 'th' }, [ t ]);
		}));

		var rows = [ head ];
		if (!accounts.length) {
			rows.push(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'colspan': '6' }, [
					_('尚未配置任何账号 —— 请到「设置」页添加；帐密写入 /etc/campnet/.config（不入 uci）。')
				])
			]));
		}
		accounts.forEach(function (a) {
			rows.push(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left' }, [ a.id || '-' ]),
				E('td', { 'class': 'td left' }, [ (a.iface || '-') + ' / ' + (a.dev || '-') ]),
				E('td', { 'class': 'td left' }, [ statusBadge(a.status) ]),
				E('td', { 'class': 'td left' }, [ a.ip || '-' ]),
				E('td', { 'class': 'td left' }, [ a.msg || '-' ]),
				E('td', { 'class': 'td left' }, [
					actionButton(_('登录'), 'cbi-button-action',
						function () { return authAccount({ account: a.id }); })
				])
			]));
		});

		var acctCard = E('div', { 'class': 'cbi-section' }, [
			E('h3', _('账号状态')),
			E('div', { 'class': 'cbi-section-descr' }, [
				_('状态来自保活缓存，约每 check_interval 秒更新；点「登录」立即重试。')
			]),
			E('table', { 'class': 'table' }, rows)
		]);

		var note = E('div', { 'class': 'cbi-section alert-message warning' }, [
			E('h3', _('说明')),
			E('p', {}, [
				_('多播均衡 = 每账号一条独立 macvlan WAN，经 mwan3 负载均衡。多线程下载 / 测速可叠加带宽；单线程连接不叠加（同 mwan3 限制）。')
			]),
			E('p', {}, [
				_('帐密存于 /etc/campnet/.config（0600）；默认认证网关 10.0.1.51，认证模式与参数在「设置」页调整。')
			])
		]);

		return E('div', {}, [ control, cfg, acctCard, note ]);
	},

	handleSave: null,
	handleReset: null
});
