(function () {
  'use strict';

  var overlay, titleEl, bodyEl;
  var inited = false;
  var currentId = null;
  var frames = [];
  var selIdx = 0;
  var rulerEl = null;

  var SEV_TEXT = ['无腐蚀', '轻度', '重度'];

  function init() {
    if (inited) return;
    inited = true;
    overlay = document.getElementById('history-overlay');
    titleEl = document.getElementById('history-title');
    bodyEl = document.getElementById('history-body');
    document.getElementById('history-close').addEventListener('click', close);
    overlay.addEventListener('click', function (e) {
      if (e.target === overlay) close();
    });
    document.addEventListener('keydown', function (e) {
      if (overlay.classList.contains('hidden')) return;
      if (e.key === 'Escape') close();
      if (e.key === 'ArrowLeft') select(selIdx - 1);
      if (e.key === 'ArrowRight') select(selIdx + 1);
    });
  }

  function close() {
    overlay.classList.add('hidden');
    currentId = null;
    frames = [];
  }

  function fmtTime(ms) {
    if (!ms) return '--';
    var d = new Date(ms);
    function p(n) { return n < 10 ? '0' + n : n; }
    return (d.getMonth() + 1) + '月' + d.getDate() + '日 ' +
           p(d.getHours()) + ':' + p(d.getMinutes());
  }

  function renderTitle(pointId) {
    var hm = window.MFL.heatmap;
    var p = hm.pointsById.get(pointId);
    var line = p && hm.linesById.get(p.line);
    var st = hm.state.get(pointId);
    var seg = '<b>' + pointId + '</b>　' + (line ? line.name : '') +
              '　K' + (p ? (p.mileage / 1000).toFixed(1) : '--');
    if (st && st.cur !== null && st.cur !== undefined) {
      seg += '　·　<span style="color:' + MFL.sevColor(st.cur) + '">' +
             SEV_TEXT[st.cur] + '</span>';
    } else {
      seg += '　·　<span style="color:#7e9cc4">无检测数据</span>';
    }
    titleEl.innerHTML = seg;
  }

  function renderRuler(pointId, captures) {
    bodyEl.innerHTML = '';
    if (!captures.length) {
      bodyEl.innerHTML =
        '<div class="history-empty"><div class="big">暂无历史图像</div>' +
        '<div class="small">该节点尚未有磁漏检测图像记录</div>' +
        '<div class="small">数据放置于 data/captures/，命名 ' + pointId + '_序号.png</div></div>';
      return;
    }

    frames = captures.slice().reverse();
    selIdx = frames.length - 1;

    var wrap = document.createElement('div');
    wrap.className = 'timeline2';
    wrap.innerHTML =
      '<div class="t2-view">' +
      '  <img id="t2-img" src="' + frames[selIdx].url + '" alt="MFL">' +
      '  <div class="t2-meta" id="t2-meta"></div>' +
      '  <span class="tl-badge" id="t2-badge" style="display:none">最新</span>' +
      '</div>' +
      '<div class="t2-ruler-wrap">' +
      '  <div class="t2-ruler" id="t2-ruler">' +
      '    <div class="t2-band" id="t2-band"></div>' +
      '    <div class="t2-handle" id="t2-handle"></div>' +
      '  </div>' +
      '  <div class="t2-times"><span>' + fmtTime(frames[0].time) + '</span>' +
      '  <span>← 方向键 / 滚轮 / 拖动 →</span>' +
      '  <span>' + fmtTime(frames[frames.length - 1].time) + '</span></div>' +
      '</div>';
    bodyEl.appendChild(wrap);
    rulerEl = wrap.querySelector('#t2-ruler');

    var band = wrap.querySelector('#t2-band');
    var colors = [];
    frames.forEach(function (c) {
      var col = (c.severity === null || c.severity === undefined)
        ? '#3d5a7a' : MFL.sevColor(c.severity);
      colors.push(col);
      var seg = document.createElement('div');
      seg.className = 't2-seg';
      seg.style.background = col;
      band.appendChild(seg);
    });

    function pickFromEvent(e) {
      var rect = rulerEl.getBoundingClientRect();
      var t = (e.clientX - rect.left) / rect.width;
      t = Math.max(0, Math.min(1, t));
      select(Math.round(t * (frames.length - 1)));
    }
    var dragging = false;
    rulerEl.addEventListener('pointerdown', function (e) {
      dragging = true;
      rulerEl.setPointerCapture(e.pointerId);
      pickFromEvent(e);
    });
    rulerEl.addEventListener('pointermove', function (e) {
      if (dragging) pickFromEvent(e);
    });
    rulerEl.addEventListener('pointerup', function () { dragging = false; });
    rulerEl.addEventListener('wheel', function (e) {
      select(selIdx + (e.deltaY > 0 ? -1 : 1));
      e.preventDefault();
    }, { passive: false });

    select(selIdx);
  }

  function select(idx) {
    if (!frames.length) return;
    selIdx = Math.max(0, Math.min(frames.length - 1, idx));
    var c = frames[selIdx];
    var img = document.getElementById('t2-img');
    var meta = document.getElementById('t2-meta');
    var badge = document.getElementById('t2-badge');
    var handle = document.getElementById('t2-handle');
    img.src = c.url;
    var sevTxt = (c.severity === null || c.severity === undefined)
      ? '<span style="color:#7e9cc4">未检测</span>'
      : '<span style="color:' + MFL.sevColor(c.severity) + '">' + SEV_TEXT[c.severity] + '</span>';
    meta.innerHTML = '#' + c.seq + '　' + fmtTime(c.time) + '　·　' + sevTxt +
      '　·　' + (selIdx + 1) + ' / ' + frames.length;
    badge.style.display = (selIdx === frames.length - 1) ? 'inline-block' : 'none';
    if (rulerEl && frames.length > 1) {
      handle.style.left = (selIdx / (frames.length - 1) * 100) + '%';
    } else if (handle) {
      handle.style.left = '50%';
    }
  }

  function open(pointId) {
    init();
    currentId = pointId;
    overlay.classList.remove('hidden');
    renderTitle(pointId);
    bodyEl.innerHTML = '<div class="history-empty"><div class="big">加载中…</div></div>';
    fetch('/api/points/' + pointId + '/captures')
      .then(function (r) { return r.json(); })
      .then(function (j) {
        if (currentId !== pointId) return;
        renderRuler(pointId, j.captures || []);
      })
      .catch(function () {
        if (currentId === pointId) {
          bodyEl.innerHTML = '<div class="history-empty"><div class="big">加载失败</div></div>';
        }
      });
  }

  window.MFL = window.MFL || {};
  window.MFL.history = { open: open, close: close };
})();
