(function () {
  'use strict';

  var inited = false;
  var active = false;
  var pollTimer = null;
  var gaugeAnim = null;
  var rateHist = [];
  var heatmap = null;

  function $(id) { return document.getElementById(id); }

  function init(hm) {
    if (inited) return;
    inited = true;
    heatmap = hm;
    $('btn-selfcheck').addEventListener('click', enter);
    $('sc-back').addEventListener('click', exit);
  }

  function enter() {
    if (active) return;
    active = true;
    heatmap.setPaused(true);
    $('map-canvas').style.display = 'none';
    $('selfcheck-view').classList.remove('hidden');
    $('btn-selfcheck').classList.add('active');
    poll();
    pollTimer = setInterval(poll, 1000);
  }

  function exit() {
    if (!active) return;
    active = false;
    clearInterval(pollTimer);
    gaugeAnim = null;
    heatmap.setPaused(false);
    $('map-canvas').style.display = '';
    $('selfcheck-view').classList.add('hidden');
    $('btn-selfcheck').classList.remove('active');
  }

  function poll() {
    fetch('/api/selfcheck').then(function (r) { return r.json(); })
      .then(function (j) { render(j); })
      .catch(function () {});
  }

  function fmtUptime(s) {
    var d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600),
        m = Math.floor(s % 3600 / 60);
    return (d ? d + '天' : '') + (h || d ? h + '时' : '') + m + '分';
  }

  function render(j) {
    var warn = (j.items || []).some(function (it) { return it.status === 'warn'; });
    $('sc-health-txt').textContent = warn ? '系统运行中（存在警告项）' : '系统运行正常';
    $('sc-health-txt').className = 'sc-health-txt' + (warn ? ' warn' : '');
    document.querySelector('.sc-pulse').className =
      'sc-pulse' + (warn ? ' warn' : '');
    $('sc-sub').textContent = j.platform + ' · 自检于 ' +
      new Date(j.server_time).toTimeString().slice(0, 8) +
      ' · 已运行 ' + fmtUptime(j.uptime_s);

    $('sc-runtime').innerHTML =
      row('运行平台', j.platform) + row('Go 运行时', j.go_version || '—') +
      row('并发协程', j.goroutines) + row('服务启动', fmtFull(j.started_at_ms));
    function row(k, v) {
      return '<div class="sc-row"><span>' + k + '</span><b>' + v + '</b></div>';
    }
    function fmtFull(ms) {
      var d = new Date(ms);
      function p(n) { return n < 10 ? '0' + n : n; }
      return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) +
             ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
    }

    rateHist.push(j.events_5s);
    if (rateHist.length > 60) rateHist.shift();
    $('sc-rate-60').textContent = '60s: ' + j.events_60s + ' 条';
    $('sc-rate-5').textContent = '5s: ' + j.events_5s + ' 条';
    drawSpark();

    drawGauge('gauge-cpu', j.cpu_load == null ? null : parseFloat(j.cpu_load), '%');
    drawGauge('gauge-mem', j.mem_used_pct == null ? null : parseFloat(j.mem_used_pct), '%');

    $('sc-items').innerHTML = (j.items || []).map(function (it) {
      return '<div class="sc-item ' + it.status + '">' +
        '<span class="sc-light"></span><span class="sc-name">' + it.name + '</span>' +
        '<span class="sc-val">' + it.value + '</span></div>';
    }).join('');

    $('sc-storage').innerHTML =
      '<span>事件日志 ' + (j.log_bytes / 1048576).toFixed(2) + ' MB</span>' +
      '<span>历史图像 ' + j.captures_files + ' 个 / ' +
      (j.captures_bytes / 1048576).toFixed(1) + ' MB</span>' +
      '<span>SSE 推送 ' + j.sse_clients + ' 端</span>' +
      '<span>未处理告警 ' + j.alerts_unresolved + '</span>';
  }

  function drawGauge(id, pct, unit) {
    var cv = document.getElementById(id);
    if (!cv) return;
    var ctx = cv.getContext('2d');
    var W = cv.width, H = cv.height;
    ctx.clearRect(0, 0, W, H);
    var cx = W / 2, cy = H * 0.82, R = 52;

    ctx.lineWidth = 12; ctx.lineCap = 'round';
    ctx.strokeStyle = 'rgba(29,58,99,.9)';
    ctx.beginPath(); ctx.arc(cx, cy, R, Math.PI, 0); ctx.stroke();
    var now = performance.now();
    if (pct == null) {
      ctx.fillStyle = 'rgba(126,156,196,.6)';
      ctx.font = '12px "Microsoft YaHei"';
      ctx.textAlign = 'center';
      ctx.fillText('PC 开发机无 /proc', cx, cy - 14);
      return;
    }
    var t = Math.max(0, Math.min(1, pct / 100));

    t = Math.min(1, t + 0.02 * Math.sin(now / 500));
    var grad = ctx.createLinearGradient(cx - R, 0, cx + R, 0);
    grad.addColorStop(0, '#21c177'); grad.addColorStop(0.6, '#f5a623');
    grad.addColorStop(1, '#f0453e');
    ctx.strokeStyle = grad;
    ctx.beginPath(); ctx.arc(cx, cy, R, Math.PI, Math.PI + t * Math.PI); ctx.stroke();

    ctx.fillStyle = '#cfe3ff';
    ctx.font = '700 20px Consolas, monospace';
    ctx.textAlign = 'center';
    ctx.fillText(pct.toFixed(1) + unit, cx, cy - 10);
  }

  function drawSpark() {
    var cv = document.getElementById('sc-spark');
    if (!cv) return;
    var ctx = cv.getContext('2d');
    var W = cv.width, H = cv.height;
    ctx.clearRect(0, 0, W, H);

    ctx.strokeStyle = 'rgba(29,58,99,.5)';
    for (var gy = 0; gy <= 3; gy++) {
      ctx.beginPath(); ctx.moveTo(0, gy * H / 3); ctx.lineTo(W, gy * H / 3); ctx.stroke();
    }
    if (rateHist.length < 2) return;
    var max = Math.max(4, Math.max.apply(null, rateHist));
    var bw = W / 60;

    for (var i = 0; i < rateHist.length; i++) {
      var v = rateHist[i];
      var h = v / max * (H - 18);
      ctx.fillStyle = 'rgba(41,211,255,' + (0.35 + 0.5 * v / max) + ')';
      ctx.fillRect(i * bw, H - 6 - h, bw - 1.5, h);
    }

    ctx.strokeStyle = 'rgba(41,211,255,.9)';
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    for (i = 0; i < rateHist.length; i++) {
      var x = i * bw + bw / 2, y = H - 6 - rateHist[i] / max * (H - 18);
      i ? ctx.lineTo(x, y) : ctx.moveTo(x, y);
    }
    ctx.stroke();
  }

  window.MFL = window.MFL || {};
  window.MFL.selfcheck = { init: init, exit: exit, isActive: function () { return active; } };
})();
