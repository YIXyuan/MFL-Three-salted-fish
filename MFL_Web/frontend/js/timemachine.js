(function () {
  'use strict';

  var WINDOW_MS = 24 * 3600 * 1000;
  var bar, fill, handle, startEl, endEl, statusEl, liveBtn;
  var inited = false;
  var byPoint = new Map();
  var winStart = 0, winEnd = 0;
  var windowMode = 'all';
  var startedAt = 0;
  var seekT = null;
  var dragging = false;
  var heatmap = null;

  function $(id) { return document.getElementById(id); }

  function init(hm) {
    if (inited) return;
    inited = true;
    heatmap = hm;

    bar = document.createElement('div');
    bar.id = 'tm-bar';
    bar.innerHTML =
      '<span class="tm-label">时间回看</span>' +
      '<span class="tm-start" id="tm-start">--</span>' +
      '<div class="tm-track" id="tm-track">' +
      '  <div class="tm-ticks" id="tm-ticks"></div>' +
      '  <div class="tm-handle" id="tm-handle"></div>' +
      '</div>' +
      '<span class="tm-end" id="tm-end">--</span>' +
      '<span class="tm-status" id="tm-status"></span>' +
      '<button class="tm-live hidden" id="tm-live">回到实时</button>';
    document.getElementById('map-wrap').appendChild(bar);

    fill = $('tm-track');
    handle = $('tm-handle');
    startEl = $('tm-start');
    endEl = $('tm-end');
    statusEl = $('tm-status');
    liveBtn = $('tm-live');

    liveBtn.addEventListener('click', function () { goLive(); });

    var track = $('tm-track');
    var dragging = false;
    function seekFromEvent(e) {
      var rect = track.getBoundingClientRect();

      var x = Math.max(rect.left, Math.min(e.clientX, rect.right));
      var t = (x - rect.left) / rect.width;
      t = Math.max(0, Math.min(1, t));
      seek(winStart + t * (winEnd - winStart));
    }
    function endDrag() { dragging = false; }
    track.addEventListener('pointerdown', function (e) {
      dragging = true;
      try { track.setPointerCapture(e.pointerId); } catch (err) {                       }
      seekFromEvent(e);
    });
    track.addEventListener('pointermove', function (e) {
      if (dragging) seekFromEvent(e);
    });

    track.addEventListener('pointerup', endDrag);
    track.addEventListener('pointercancel', endDrag);
    track.addEventListener('lostpointercapture', endDrag);
    window.addEventListener('pointerup', endDrag);
    track.addEventListener('wheel', function (e) {
      if (winEnd <= winStart) return;
      var d = (e.deltaY > 0 ? -1 : 1) * (winEnd - winStart) * 0.02;

      var base = (seekT == null ? winEnd : seekT);
      seek(Math.max(winStart, Math.min(winEnd, base + d)));
      e.preventDefault();
    }, { passive: false });

    heatmap.onhistory = function (on, until) {
      statusEl.textContent = on
        ? '回看 ' + fmtTime(until) + '（数据截至该时刻）'
        : '';
      bar.classList.toggle('reviewing', on);

      if (!on) { rebuildWindow(); }
    };

    var sysBd = document.querySelector('[data-slot="system"] .panel-bd');
    if (sysBd) {
      var bar2 = document.createElement('div');
      bar2.className = 'tm-windows';
      bar2.innerHTML = '<span class="tmw-lbl">回看窗口</span>';
      [['all', '全程'], ['3600000', '1h'], ['21600000', '6h'], ['43200000', '12h'],
       ['86400000', '1d'], ['259200000', '3d'], ['604800000', '7d'],
       ['2592000000', '30d']].forEach(function (pair) {
        var b = document.createElement('button');
        b.className = 'tmw-btn' + (pair[0] === 'all' ? ' active' : '');
        b.textContent = pair[1];
        b.dataset.mode = pair[0];
        b.addEventListener('click', function () {
          windowMode = pair[0] === 'all' ? 'all' : parseInt(pair[0], 10);
          bar2.querySelectorAll('.tmw-btn').forEach(function (x) {
            x.classList.toggle('active', x === b);
          });
          rebuildWindow();
          if (seekT != null) seek(Math.max(winStart, Math.min(seekT, winEnd)));
        });
        bar2.appendChild(b);
      });
      sysBd.appendChild(bar2);
    }

    setInterval(function () {
      if (seekT == null && inited) rebuildWindow();
    }, 1000);
  }

  function fmtTime(ms) {
    var d = new Date(ms);
    function p(n) { return n < 10 ? '0' + n : n; }
    return p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' +
           p(d.getHours()) + ':' + p(d.getMinutes());
  }
  function fmtTick(ms) {
    var d = new Date(ms);
    function p(n) { return n < 10 ? '0' + n : n; }
    return p(d.getHours()) + ':' + p(d.getMinutes());
  }

  function pull() {

    fetch('/api/system').then(function (r) { return r.json(); })
      .then(function (j) { startedAt = j.started_at_ms || (Date.now() - (j.uptime_s || 0) * 1000); })
      .catch(function () {});
    return fetch('/api/events/history')
      .then(function (r) { return r.json(); })
      .then(function (j) {
        (j.events || []).forEach(function (e) { feed([e]); });
        rebuildWindow();
      })
      .catch(function () {});
  }

  function feed(events) {
    var changed = false;
    (events || []).forEach(function (e) {
      if (!byPoint.has(e.point_id)) byPoint.set(e.point_id, []);
      var arr = byPoint.get(e.point_id);
      arr.push({ t: e.timestamp, sev: e.severity });
      changed = true;
    });
    if (changed) rebuildWindow();
  }

  function rebuildWindow() {
    var now = Date.now();
    var latest = 0;
    byPoint.forEach(function (arr) {
      if (arr.length && arr[arr.length - 1].t > latest) latest = arr[arr.length - 1].t;
    });
    winEnd = Math.max(latest, Math.min(now, startedAt ? now : now), seekT || 0);
    if (windowMode === 'all') {
      winStart = startedAt || (winEnd - WINDOW_MS);
    } else {
      winStart = winEnd - windowMode;
    }
    if (winEnd <= winStart) winEnd = winStart + 60000;
    startEl.textContent = fmtTime(winStart);
    endEl.textContent = fmtTime(winEnd);

    var span = winEnd - winStart;
    var steps = [60e3, 5 * 60e3, 10 * 60e3, 30 * 60e3, 3600e3,
                 3 * 3600e3, 6 * 3600e3, 12 * 3600e3, 86400e3, 3 * 86400e3];
    var stp = steps[steps.length - 1];
    for (var si = 0; si < steps.length; si++) {
      if (span / steps[si] <= 10) { stp = steps[si]; break; }
    }
    var ticks = $('tm-ticks');
    ticks.innerHTML = '';
    var one = Math.ceil(winStart / stp) * stp;
    for (; one <= winEnd; one += stp) {
      var x = (one - winStart) / span * 100;
      var tk = document.createElement('span');
      tk.className = 'tm-tick';
      tk.style.left = x + '%';
      tk.title = fmtTick(one);
      ticks.appendChild(tk);
    }
    bar.classList.toggle('empty', byPoint.size === 0);

    if (seekT == null) {
      handle.style.left = '100%';
    } else {
      seek(Math.max(winStart, Math.min(seekT, winEnd)));
    }
  }

  function seek(t) {
    t = Math.max(winStart, Math.min(winEnd, t));
    seekT = t;
    handle.style.left = Math.max(0, Math.min(100,
      (t - winStart) / Math.max(1, winEnd - winStart) * 100)) + '%';
    var snap = new Map();
    byPoint.forEach(function (arr, pid) {
      var v = null;
      for (var i = arr.length - 1; i >= 0; i--) {
        if (arr[i].t <= t) { v = arr[i].sev; break; }
      }
      if (v !== null) snap.set(pid, v);
    });
    heatmap.setHistoryState(snap, t);
    liveBtn.classList.remove('hidden');
  }

  function goLive() {
    seekT = null;
    liveBtn.classList.add('hidden');
    statusEl.textContent = '';
    bar.classList.remove('reviewing');
    heatmap.clearHistoryState();

    rebuildWindow();
  }

  window.MFL = window.MFL || {};
  window.MFL.timeMachine = {
    init: function (hm) { init(hm); pull(); },
    feed: function (events) { feed(events); },
    goLive: goLive
  };
})();
