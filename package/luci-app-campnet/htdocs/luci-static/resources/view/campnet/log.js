'use strict';
'require view';
'require rpc';
'require ui';

var getLog = rpc.declare({
	object: 'luci.campnet',
	method: 'getLog',
	params: [ 'lines' ]
});

var LINES = [ 100, 300, 800 ];

return view.extend({
	load: function () {
		return L.resolveDefault(getLog({ lines: 200 }), {});
	},

	render: function (data) {
		var that = this;
		var pre = E('pre', {
			'id': 'campnet-log-body',
			'style': 'white-space:pre-wrap;word-break:break-all;background:#f6f6f6;padding:10px;min-height:300px;font-size:12px'
		}, [ (data.log || _('（暂无日志）')) ]);

		var lineSel = E('select', { 'class': 'cbi-input-select', 'style': 'width:auto' }, LINES.map(function (n) {
			return E('option', { 'value': String(n), 'selected': (n === 200) ? 'selected' : null }, [ n + ' 行' ]);
		}));

		var load = function () {
			getLog({ lines: parseInt(lineSel.value, 10) || 200 }).then(function (r) {
				pre.textContent = (r && r.log) ? r.log : _('（暂无日志）');
			}).catch(function () {
				pre.textContent = _('读取日志失败');
			});
		};

		var refreshBtn = E('button', {
			'class': 'cbi-button cbi-button-apply',
			'click': function (ev) { ev.preventDefault(); load(); }
		}, [ _('刷新') ]);

		lineSel.addEventListener('change', load);

		return E('div', {}, [
			E('div', { 'class': 'cbi-section' }, [
				E('h3', _('运行日志')),
				E('div', { 'class': 'cbi-section-descr' }, [
					_('日志路径 /var/log/campnet/campnet.log（行数自动轮转，保留最近 ~800 行）。敏感字段（密码/queryString/mac 等）写入前已脱敏。')
				]),
				E('div', { 'style': 'margin:8px 0' }, [ lineSel, E('span', ' '), refreshBtn ]),
				pre
			])
		]);
	}
});
