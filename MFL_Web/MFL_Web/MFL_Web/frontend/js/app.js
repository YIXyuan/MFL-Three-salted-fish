(function () {
  'use strict';

  var qs = new URLSearchParams(location.search);

  function fitStage() {
    var s = Math.min(window.innerWidth / 1920, window.innerHeight / 1080);
    window.MFL.stageScale = s;
    var stage = document.getElementById('stage');
    stage.style.transform = 'translate(-50%, -50%) scale(' + s + ')';
  }
  window.addEventListener('resize', fitStage);
  fitStage();

  var WEEK = ['日', '一', '二', '三', '四', '五', '六'];
  function tickClock() {
    var d = new Date();
    function p(n) { return n < 10 ? '0' + n : '' + n; }
    document.getElementById('clock').textContent =
      d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) +
      ' 周' + WEEK[d.getDay()] + ' ' + p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
  }
  setInterval(tickClock, 1000);
  tickClock();

  function setConn(state) {
    var dot = document.getElementById('conn-dot');
    var text = document.getElementById('conn-text');
    if (state === 'on') { dot.className = 'dot on'; text.textContent = '已连接'; }
    else { dot.className = 'dot off'; text.textContent = '连接中断，重连中…'; }
  }

  var heatmap;
  function updateStats() {
    var c = heatmap.getStateCounts();
    document.getElementById('stat-total').textContent = c.total;

    document.getElementById('stat-online').textContent = c.online;
    document.getElementById('stat-none').textContent = c.none;
    document.getElementById('stat-0').textContent = c['0'];
    document.getElementById('stat-1').textContent = c['1'];
    document.getElementById('stat-2').textContent = c['2'];
  }

  async function boot() {
    var canvas = document.getElementById('map-canvas');
    var camera = new MFL.Camera(canvas);
    heatmap = new MFL.Heatmap(canvas, camera);
    window.MFL.heatmap = heatmap;
    window.MFL.view = camera;
    heatmap.onchange = updateStats;

    heatmap.onclick = function (pid, sx, sy) {
      if (pid) MFL.preview.open(pid, sx, sy);
      else MFL.preview.close();
    };

    var net = await (await fetch('/api/network')).json();
    heatmap.loadNetwork(net);
    heatmap._syncSize();
    camera.setBounds(net.meta.bounds);

    if (qs.get('zoom') === 'max') {
      camera.mPerPx = MFL.MAX_ZOOM_M_PER_PX;
      camera._emit();
    }

    requestAnimationFrame(function frame(t) {
      try { heatmap.render(t); } catch (err) { console.error('[MFL] render', err); }
      requestAnimationFrame(frame);
    });

    var lastTick = 0;
    requestAnimationFrame(function (t) { lastTick = performance.now(); });
    setInterval(function () {
      if (performance.now() - lastTick > 400) {
        lastTick = performance.now();
        try { heatmap.render(performance.now()); } catch (err) {          }
      }
    }, 250);

    document.getElementById('zoom-in').addEventListener('click', function () { camera.zoomBy(1.6); });
    document.getElementById('zoom-out').addEventListener('click', function () { camera.zoomBy(1 / 1.6); });
    document.getElementById('zoom-reset').addEventListener('click', function () { camera.reset(); });

    document.getElementById('view-mode').addEventListener('click', function () {
      this.textContent = camera.toggleMode().replace('25d', '2.5D').replace('2d', '2D');
    });

    connectSSE();
    await refreshState();
    MFL.panels.init(heatmap);

    MFL.timeMachine.init(heatmap);

    MFL.search.init();

    MFL.selfcheck.init(heatmap);

    fetch('/api/ledger').then(function (r) { return r.json(); })
      .then(function (j) {
        heatmap.setLedger(j.points);
        var btn = document.createElement('button');
        btn.id = 'view-aged';
        btn.title = '切换 管道年限状态图 / 热力图';
        btn.textContent = '年限图';
        btn.addEventListener('click', function () {

          var on = heatmap.setViewKind(
            heatmap.viewKind !== 'aged' ? 'aged' : 'corrosion') === 'aged';
          btn.classList.toggle('active', on);
          btn.textContent = on ? '热力图' : '年限图';
        });
        document.getElementById('view-mode').parentNode.insertBefore(btn, document.getElementById('view-mode'));
      }).catch(function () {});
  }

  var es = null, needResync = false;

  async function refreshState() {
    try {
      var j = await (await fetch('/api/state')).json();
      var online = [], items = [];
      Object.keys(j.points || {}).forEach(function (id) {
        var r = j.points[id];
        if (r.online) online.push(id);
        if (r.detected && r.severity != null) {
          items.push({ point_id: id, severity: r.severity, timestamp: r.timestamp });
        }
      });
      heatmap.setOnline(online);
      if (items.length) heatmap.applyDetections(items, { silent: true });
      updateStats();
    } catch (e) { console.warn('[MFL] 状态恢复失败', e); }
  }

  function connectSSE() {
    es = new EventSource('/api/events');
    es.onopen = function () {
      setConn('on');
      if (needResync) { needResync = false; refreshState(); }
    };
    es.onerror = function () { setConn('off'); needResync = true; };
    es.onmessage = function (e) {
      var msg;
      try { msg = JSON.parse(e.data); } catch (err) { return; }
      if (msg.type === 'detection' && msg.items) {
        heatmap.applyDetections(msg.items);
        MFL.timeMachine.feed(msg.items);
      } else if (msg.type === 'alert') {
        MFL.panels.refreshAlerts();
      } else if (msg.type === 'online') {
        refreshState();
      }
    };
  }

  boot().catch(function (err) {
    console.error('[MFL] 启动失败', err);
    document.getElementById('conn-text').textContent = '加载失败：' + err.message;
  });
})();
