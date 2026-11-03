(function () {
  'use strict';

  var hm = null;
  var activeTab = 'severe';
  var trendPoint = null;
  var lastTopAlertId = null;
  var STATUS_ORDER = ['待处理', '处理中', '已修复'];

  var expandedLines = new Set();
  var tipEl = null;

  function $(id) { return document.getElementById(id); }
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>\"]/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
    });
  }
  function fmtClock(ms) {
    if (!ms) return '--:--:--';
    var d = new Date(ms);
    function p(n) { return n < 10 ? '0' + n : n; }
    return p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
  }
  function fmtAgo(sec) {
    if (sec == null) return '--';
    if (sec < 60) return sec + ' 秒前';
    if (sec < 3600) return Math.floor(sec / 60) + ' 分钟前';
    return Math.floor(sec / 3600) + ' 小时前';
  }
  function fmtDur(sec) {
    var h = Math.floor(sec / 3600), m = Math.floor(sec % 3600 / 60);
    return (h ? h + '小时' : '') + m + '分';
  }

  function onlineCount(maxAgeMs) {
    var now = Date.now(), n = 0;
    hm.state.forEach(function (st) {
      if (st.ts && now - st.ts <= maxAgeMs) n++;
    });
    return n;
  }

  function animateNum(el, to, dur) {
    if (el == null) return;
    to = Math.max(0, Math.round(to));
    var from = (el._shown == null ? 0 : el._shown);
    if (from === to) { el.textContent = to; return; }
    if (el._animT0 == null) el._animT0 = 0;
    var t0 = performance.now(), d0 = from;
    el._shown = to;
    var durMs = dur || 550;
    function step(t) {
      var k = Math.min(1, (t - t0) / durMs);
      k = 1 - Math.pow(1 - k, 3);
      el.textContent = Math.round(d0 + (to - d0) * k);
      if (k < 1) requestAnimationFrame(step);
    }
    requestAnimationFrame(step);

    var tile = el.parentElement;
    if (tile) {
      tile.classList.remove('bump');
      void tile.offsetWidth;
      tile.classList.add('bump');
    }
  }

  function renderTiles(alertsUnresolved) {
    var c = hm.getStateCounts();
    var online = onlineCount(10 * 60 * 1000);
    var box = $('sys-tiles');
    if (!box.dataset.built) {
      box.dataset.built = '1';
      box.innerHTML =
        '<div class="tile acc"><div class="num" id="tn-total">0</div><div class="lbl">监测点</div></div>' +
        '<div class="tile ok"><div class="num" id="tn-online">0</div><div class="lbl">在线节点(10min)</div></div>' +
        '<div class="tile"><div class="num" id="tn-severe">0</div><div class="lbl">当前重度</div></div>' +
        '<div class="tile"><div class="num" id="tn-alerts">0</div><div class="lbl">未处理告警</div></div>';
    }
    animateNum($('tn-total'), c.total);
    animateNum($('tn-online'), online);
    animateNum($('tn-severe'), c['2']);
    animateNum($('tn-alerts'), alertsUnresolved || 0);
    $('tn-severe').parentElement.classList.toggle('warn', !!c['2']);
    $('tn-alerts').parentElement.classList.toggle('warn', !!alertsUnresolved);
  }

  function drawDonut(c) {
    var cv = $('donut'), ctx = cv.getContext('2d');
    var dpr = window.devicePixelRatio || 1;

    if (cv.width !== 96 * dpr) { cv.width = cv.height = 96 * dpr; }
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, 96, 96);

    var parts = [
      { v: c.none, color: '#3d5a7a' },
      { v: c['0'], color: '#21c177' },
      { v: c['1'], color: '#f5a623' },
      { v: c['2'], color: '#f0453e' }
    ];
    var total = c.total || 1, start = -Math.PI / 2;
    ctx.lineWidth = 12;
    parts.forEach(function (p) {
      if (!p.v) return;
      var ang = p.v / total * Math.PI * 2;
      ctx.strokeStyle = p.color;
      ctx.beginPath();
      ctx.arc(48, 48, 34, start, start + ang - 0.02);
      ctx.stroke();
      start += ang;
    });

    var donut = { _shown: window._donutShown || 0 };
    var target = c.total;
    window._donutShown = target;

    ctx.fillStyle = '#cfe3ff';
    ctx.font = '700 15px Consolas, monospace';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText(target, 48, 46);
    ctx.font = '9px "Microsoft YaHei"';
    ctx.fillStyle = '#7e9cc4';
    ctx.fillText('监测点', 48, 60);

    $('donut-legend').innerHTML =
      lg('none', '离线 ' + c.none) +
      lg('s0', '无腐蚀 ' + c['0']) + lg('s1', '轻度 ' + c['1']) +
      lg('s2', '重度 ' + c['2']);
    function lg(cls, txt) { return '<div><i class="sw ' + cls + '"></i>' + txt + '</div>'; }
  }

  function renderSysRows(sys) {
    var rows = [
      ['数据链路', '<b class="' + (sys.link === '活跃' ? 'ok' : 'idle') + '">' +
        esc(sys.link) + '</b>'],
      ['最近事件', '<b>' + (sys.last_event_age_s == null ? '--' : fmtAgo(sys.last_event_age_s)) + '</b>'],
      ['累计检测事件', '<b>' + sys.events_total + '</b>'],
      ['SSE 在线客户端', '<b>' + sys.sse_clients + '</b>'],
      ['服务运行时长', '<b>' + fmtDur(sys.uptime_s) + '</b>'],
      ['ARM CPU 负载', '<b>' + (sys.cpu_pct == null ? '--' : sys.cpu_pct + '%') + '</b>'],
      ['内存使用', '<b>' + (sys.mem_used_pct == null ? '--' :
        sys.mem_used_pct + '% (' + sys.mem_total_mb + 'MB)</b>')],
      ['运行平台', '<b>' + esc(sys.platform) + '</b>']
    ];
    $('sys-rows').innerHTML = rows.map(function (r) {
      return '<div class="sys-row"><span>' + r[0] + '</span>' + r[1] + '</div>';
    }).join('');
  }

  function refreshSystem() {
    renderTiles(null);
    drawDonut(hm.getStateCounts());
    fetch('/api/system').then(function (r) { return r.json(); }).then(function (sys) {
      renderSysRows(sys);
      renderTiles(sys.alerts_unresolved);
    }).catch(function () {});
  }

  function showCellTip(pid, text, x, y) {
    if (!tipEl) {
      tipEl = document.createElement('div');
      tipEl.className = 'nd-tip';
      document.body.appendChild(tipEl);
    }
    tipEl.innerHTML = '<b>' + esc(pid) + '</b>' + text;
    tipEl.style.display = 'block';
    tipEl.style.left = (x + 12) + 'px';
    tipEl.style.top = (y - 10) + 'px';
  }
  function hideCellTip() {
    if (tipEl) tipEl.style.display = 'none';
  }

  function renderAlerts(data) {
    var board = $('alert-board');
    var badge = $('alert-badge');
    badge.textContent = data.unresolved;
    badge.classList.toggle('hidden', !data.unresolved);

    if (!data.alerts.length) {
      board.innerHTML = '<div class="alert-empty">暂 无 告 警</div>';
      lastTopAlertId = null;
      return;
    }
    var html = '';
    data.alerts.forEach(function (a) {
      var st = a.status, next = STATUS_ORDER[Math.min(STATUS_ORDER.indexOf(st) + 1, 2)];

      var typeTxt = a.type_text || (a.type === 'severe' ? '严重腐蚀' : '节点离线');
      var range = a.range_text
        ? '<span class="a-range">' + esc(a.range_text) + '</span>' : '';
      html += '<div class="alert-row" data-id="' + a.id + '" data-pid="' + esc(a.point_id) + '">' +
        '<span class="a-time">' + fmtClock(a.time) + '</span>' +
        '<span class="a-type ' + a.type + '">' + esc(typeTxt) + '</span>' + range +
        '<span class="a-text">' + esc(a.text) + '</span>' +
        '<span class="chip st-' + st + '" title="点击推进到「' + next + '」">' + st + '</span>' +
        '</div>';
    });
    board.innerHTML = html;

    var topId = data.alerts[0].id;
    if (lastTopAlertId !== null && topId !== lastTopAlertId) {
      var first = board.querySelector('.alert-row');
      if (first) first.classList.add('fresh');
    }
    lastTopAlertId = topId;
  }

  function refreshAlerts() {
    fetch('/api/alerts').then(function (r) { return r.json(); })
      .then(renderAlerts).catch(function () {});
  }

  function switchTab(name) {
    activeTab = name;
    document.querySelectorAll('#stats-tabs .tab').forEach(function (b) {
      b.classList.toggle('active', b.dataset.tab === name);
    });
    ['severe', 'coverage', 'volatility'].forEach(function (t) {
      $('tab-' + t).classList.toggle('hidden', t !== name);
    });
    refreshStatsTab();
  }

  function refreshStatsTab() {
    if (activeTab === 'severe') refreshSevere();
    else if (activeTab === 'coverage') refreshCoverage();
    else refreshVolatility();
  }

  function refreshSevere() {
    fetch('/api/stats/top_severe').then(function (r) { return r.json(); })
      .then(function (j) {
        var items = j.items || [];
        if (!items.length) {
          $('tab-severe').innerHTML = '<div class="trend-empty">暂无重度腐蚀记录</div>';
          return;
        }
        var max = items[0].count || 1;
        $('tab-severe').innerHTML = items.map(function (it, i) {
          var w = Math.round(it.count / max * 100);
          var cur = it.current === 2 ? ' <span style="color:#f0453e">[当前重度]</span>' : '';
          return '<div class="rank-row" data-pid="' + esc(it.point_id) + '">' +
            '<span class="no ' + (i < 3 ? 'top' : '') + '">' + (i + 1) + '</span>' +
            '<span class="pid">' + esc(it.point_id) + '</span>' +
            '<span class="meta">' + esc(it.line_name) + ' K' +
            (it.mileage_m / 1000).toFixed(1) + cur + '</span>' +
            '<span class="bar-wrap"><span class="bar" style="width:' + w + '%"></span></span>' +
            '<span class="val">' + it.count + ' 次</span></div>';
        }).join('') +
        '<div class="rank-row sub" style="border:none"><span class="meta">点击行查看该节点历史图像</span></div>';

        Array.prototype.forEach.call($('tab-severe').querySelectorAll('.rank-row[data-pid]'), function (el) {
          el.addEventListener('click', function () {
            var s = window.MFL.heatmap.flyTo(el.dataset.pid);
            if (s) window.MFL.preview.open(el.dataset.pid, s.x, s.y);
          });
        });
      }).catch(function () {});
  }

  function cellClass(pid) {
    var st = hm.state.get(pid);
    if (st && st.cur !== null && st.cur !== undefined) return 'nd-' + st.cur;
    return hm.isOnlinePending(pid) ? 'nd-on' : 'nd-off';
  }

  function refreshCoverage() {
    fetch('/api/stats/coverage').then(function (r) { return r.json(); })
      .then(function (j) {
        var o = j.overall;
        var html = '<div class="cov-row cov-overall">' +
          '<div class="cov-hd"><span>总体覆盖率</span>' +
          '<span class="pct-big">' + o.pct + '%</span></div>' +
          '<div class="cov-track"><div class="cov-fill' + (o.pct >= 100 ? ' full' : '') +
          '" style="width:' + o.pct + '%"></div></div>' +
          '<div class="cov-hd" style="margin-top:4px"><span>已检 ' + o.covered +
          '</span><span>共 ' + o.total + ' 点</span></div></div>';
        html += j.lines.map(function (l) {
          var open = expandedLines.has(l.id);
          return '<div class="cov-row" data-line="' + esc(l.id) + '">' +
            '<div class="cov-hd cov-toggle" data-line="' + esc(l.id) + '">' +
            '<span><i class="cov-arrow">' + (open ? '▾' : '▸') + '</i><b>' + esc(l.name) +
            '</b>（' + l.id + '）</span><span>' + l.covered + '/' + l.total +
            ' · ' + l.pct + '%</span></div>' +
            '<div class="cov-track"><div class="cov-fill' + (l.pct >= 100 ? ' full' : '') +
            '" style="width:' + l.pct + '%"></div></div>' +
            '<div class="nd-grid' + (open ? '' : ' hidden') + '" data-grid="' + esc(l.id) + '"></div>' +
            '</div>';
        }).join('');
        $('tab-coverage').innerHTML = html;

        $('tab-coverage').querySelectorAll('.nd-grid').forEach(function (grid) {
          var lid = grid.dataset.grid;
          if (!expandedLines.has(lid)) return;
          var hm = window.MFL.heatmap;
          var pmap = hm.pointsById;
          var cells = [];

          var pts = [];
          hm.net.points.forEach(function (p) { if (p.line === lid) pts.push(p); });
          pts.sort(function (a, b) { return a.mileage - b.mileage; });
          pts.forEach(function (p) {
            var cls = cellClass(p.id);
            var st = hm.state.get(p.id);
            var sevTxt = (st && st.cur !== null && st.cur !== undefined)
              ? ['无腐蚀', '轻度', '重度'][st.cur] : (hm.isOnlinePending(p.id) ? '在线待检' : '离线');
            cells.push('<span class="nd-cell ' + cls + '" data-pid="' + esc(p.id) + '"' +
              ' data-info="' + esc((hm.linesById.get(lid) || {}).name || '') + ' K' +
              (p.mileage / 1000).toFixed(1) + ' · ' + sevTxt + '"></span>');
          });
          grid.innerHTML = cells.join('');

          grid.querySelectorAll('.nd-cell').forEach(function (cell) {
            cell.addEventListener('mousemove', function (e) {
              showCellTip(cell.dataset.pid, cell.dataset.info, e.clientX, e.clientY);
            });
            cell.addEventListener('mouseleave', hideCellTip);
            cell.addEventListener('click', function (e) {
              e.stopPropagation();
              hideCellTip();
              var s = window.MFL.heatmap.flyTo(cell.dataset.pid);
              if (s) window.MFL.preview.open(cell.dataset.pid, s.x, s.y);
            });
          });
        });

        $('tab-coverage').querySelectorAll('.cov-toggle').forEach(function (hd) {
          hd.addEventListener('click', function () {
            var lid = hd.dataset.line;
            if (expandedLines.has(lid)) expandedLines.delete(lid);
            else expandedLines.add(lid);
            refreshCoverage();
          });
        });
      }).catch(function () {});
  }

  function refreshVolatility() {
    fetch('/api/stats/volatility').then(function (r) { return r.json(); })
      .then(function (j) {
        var items = j.items || [];
        if (!items.length) {
          $('tab-volatility').innerHTML =
            '<div class="trend-empty">暂无腐蚀波动记录<br>（节点严重度发生变动后出现）</div>';
          return;
        }
        if (!trendPoint || !items.some(function (it) { return it.point_id === trendPoint; })) {
          trendPoint = items[0].point_id;
        }
        var rows = items.map(function (it, i) {
          var sel = it.point_id === trendPoint;
          return '<div class="rank-row" data-pid="' + esc(it.point_id) + '" style="' +
            (sel ? 'background:rgba(41,211,255,.1)' : '') + '">' +
            '<span class="no ' + (i < 3 ? 'top' : '') + '">' + (i + 1) + '</span>' +
            '<span class="pid">' + esc(it.point_id) + '</span>' +
            '<span class="meta">' + esc(it.line_name) + '</span>' +
            '<span class="meta">' + it.transitions + ' 次变动</span>' +
            '<span class="val">波动 ' + it.volatility.toFixed(1) + '</span>' +
            '<span class="chip ' + (it.current != null ? 'st-处理中' : '') +
            '" style="' + (it.current != null ? '' : 'visibility:hidden') + '">' +
            (it.current != null ? ['无腐蚀', '轻度', '重度'][it.current] : '-') + '</span>' +
            '</div>';
        }).join('');
        $('tab-volatility').innerHTML =
          '<div class="trend-title">腐蚀波动 No.1：<b>' + esc(trendPoint) +
          '</b> 严重度趋势（点击下方行切换）</div>' +
          '<div class="trend-chart-wrap"><canvas id="trend-canvas"></canvas></div>' +
          rows;
        Array.prototype.forEach.call($('tab-volatility').querySelectorAll('.rank-row[data-pid]'), function (el) {
          el.addEventListener('click', function () {

            if (trendPoint !== el.dataset.pid) {
              trendPoint = el.dataset.pid;
              refreshVolatility();
            }
            if (window.MFL.view && window.MFL.preview) {
              var s = window.MFL.heatmap.flyTo(el.dataset.pid);
              if (s) window.MFL.preview.open(el.dataset.pid, s.x, s.y);
            }
          });
        });
        loadTrend(trendPoint);
      }).catch(function () {});
  }

  function loadTrend(pid) {
    fetch('/api/stats/point_trend/' + pid).then(function (r) { return r.json(); })
      .then(function (j) { drawTrend($('trend-canvas'), j.series || []); })
      .catch(function () {});
  }

  function drawTrend(cv, series) {
    if (!cv) return;
    var wrap = cv.parentElement;
    var W = wrap.clientWidth, H = wrap.clientHeight;
    var dpr = window.devicePixelRatio || 1;
    cv.width = W * dpr; cv.height = H * dpr;
    var ctx = cv.getContext('2d');
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, W, H);
    if (!series.length) {
      ctx.fillStyle = 'rgba(126,156,196,.5)';
      ctx.font = '12px "Microsoft YaHei"';
      ctx.textAlign = 'center';
      ctx.fillText('该节点暂无严重度历史', W / 2, H / 2);
      return;
    }
    var L = 34, R = 10, T = 10, B = 20;
    var t0 = series[0][0], t1 = series[series.length - 1][0] || (t0 + 1);
    var x = function (t) { return L + (t - t0) / (t1 - t0) * (W - L - R); };
    var y = function (v) { return H - B - v / 2 * (H - T - B); };

    ctx.font = '10px Consolas, monospace';
    ctx.textAlign = 'right'; ctx.textBaseline = 'middle';
    [[0, '#3d5a7a'], [1, '#f5a623'], [2, '#f0453e']].forEach(function (g) {
      ctx.strokeStyle = 'rgba(70,130,210,.18)';
      ctx.beginPath(); ctx.moveTo(L, y(g[0])); ctx.lineTo(W - R, y(g[0])); ctx.stroke();
      ctx.fillStyle = g[1];
      ctx.fillText(['无腐蚀', '轻度', '重度'][g[0]], L - 4, y(g[0]));
    });

    function sevColor(v) {
      var stops = [[33, 193, 119], [245, 166, 35], [240, 69, 62]];
      v = Math.max(0, Math.min(2, v));
      var i = Math.min(1, Math.floor(v)), f = v - i, a = stops[i], b = stops[i + 1];
      return 'rgb(' + Math.round(a[0] + (b[0] - a[0]) * f) + ',' +
             Math.round(a[1] + (b[1] - a[1]) * f) + ',' +
             Math.round(a[2] + (b[2] - a[2]) * f) + ')';
    }
    ctx.lineWidth = 2;
    for (var i = 1; i < series.length; i++) {
      var px0 = x(series[i - 1][0]), px1 = x(series[i][0]);
      var py = y(series[i - 1][1]);
      ctx.strokeStyle = sevColor(series[i - 1][1]);
      ctx.beginPath(); ctx.moveTo(px0, py); ctx.lineTo(px1, py); ctx.stroke();
      ctx.strokeStyle = 'rgba(207,227,255,.25)';
      ctx.beginPath(); ctx.moveTo(px1, py); ctx.lineTo(px1, y(series[i][1])); ctx.stroke();
    }
    var last = series[series.length - 1];
    ctx.fillStyle = sevColor(last[1]);
    ctx.beginPath(); ctx.arc(x(last[0]), y(last[1]), 3, 0, Math.PI * 2); ctx.fill();

    ctx.fillStyle = '#7e9cc4'; ctx.textAlign = 'left';
    ctx.fillText(fmtClock(t0), L, H - 8);
    ctx.textAlign = 'right';
    ctx.fillText(fmtClock(t1), W - R, H - 8);
  }

  function bindAlertBoard() {
    $('alert-board').addEventListener('click', function (e) {
      var row = e.target.closest('.alert-row');
      if (!row) return;
      if (e.target.classList.contains('chip')) {
        var st = STATUS_ORDER.indexOf(e.target.textContent);
        if (st < STATUS_ORDER.length - 1) {
          fetch('/api/alerts/' + row.dataset.id + '/status', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ status: STATUS_ORDER[st + 1] })
          }).then(function () { refreshAlerts(); }).catch(function () {});
        }
        e.stopPropagation();
        return;
      }
      if (row.dataset.pid) {

        var s = window.MFL.heatmap.flyTo(row.dataset.pid);
        if (s) window.MFL.preview.open(row.dataset.pid, s.x, s.y);
        MFL.history.open(row.dataset.pid);
      }
    });
  }

  function init(heatmap) {
    hm = heatmap;
    $('stats-tabs').addEventListener('click', function (e) {
      if (e.target.classList.contains('tab')) switchTab(e.target.dataset.tab);
    });
    bindAlertBoard();
    refreshSystem(); refreshAlerts(); refreshSevere();
    setInterval(refreshSystem, 3000);
    setInterval(refreshAlerts, 3000);
    setInterval(refreshStatsTab, 5000);
  }

  window.MFL = window.MFL || {};
  window.MFL.panels = {
    init: init,
    refreshAlerts: refreshAlerts,
    refreshStats: refreshStatsTab
  };
})();
