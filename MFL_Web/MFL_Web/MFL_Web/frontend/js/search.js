(function () {
  'use strict';

  var input, list, btn;
  var inited = false;
  var selIdx = -1;
  var results = [];

  function init() {
    if (inited) return;
    inited = true;
    input = document.getElementById('node-search');
    list = document.getElementById('search-list');
    btn = document.getElementById('node-search-btn');

    input.addEventListener('input', function () { renderList(input.value.trim()); });
    input.addEventListener('keydown', function (e) {
      if (e.key === 'ArrowDown') { move(1); e.preventDefault(); }
      else if (e.key === 'ArrowUp') { move(-1); e.preventDefault(); }
      else if (e.key === 'Enter') { pick(selIdx >= 0 ? results[selIdx] : (results[0] || null)); }
      else if (e.key === 'Escape') { hideList(); }
    });
    btn.addEventListener('click', function () {
      if (results.length) pick(selIdx >= 0 ? results[selIdx] : results[0]);
      else renderList(input.value.trim());
    });
    document.addEventListener('click', function (e) {
      if (!list.contains(e.target) && e.target !== input) hideList();
    });
  }

  function hideList() {
    list.style.display = 'none';
    selIdx = -1;
  }

  function move(d) {
    if (!results.length) return;
    selIdx = (selIdx + d + results.length) % results.length;
    [...list.children].forEach(function (li, i) {
      li.classList.toggle('sel', i === selIdx);
    });
  }

  function match(q) {
    var hm = window.MFL.heatmap;
    var out = [];
    var ql = q.toLowerCase();
    hm.pointsById.forEach(function (p, pid) {
      var pl = pid.toLowerCase();
      if (pl.indexOf(ql) === 0 || pl.indexOf(ql) > 0) {
        out.push({ type: 'point', id: pid, name: pid,
                   sub: (hm.linesById.get(p.line) || {}).name || '',
                   pid: pid });
      }
    });
    (hm.net.stations || []).forEach(function (st) {
      if (st.id.toLowerCase().indexOf(ql) === 0 ||
          st.name.toLowerCase().indexOf(ql) >= 0) {
        out.push({ type: 'station', id: st.id, name: st.name,
                   sub: st.type + ' · ' + st.name, pid: null,
                   x: st.x, y: st.y });
      }
    });
    return out.slice(0, 8);
  }

  function renderList(q) {
    if (!q) { hideList(); return; }
    results = match(q);
    if (!results.length) { hideList(); return; }
    list.innerHTML = results.map(function (r, i) {
      return '<li class="' + (i === selIdx ? 'sel' : '') + '" data-i="' + i + '">' +
             '<b>' + r.id + '</b> ' + r.name +
             '<span class="s-sub">' + r.sub + '</span></li>';
    }).join('');
    list.style.display = 'block';
    Array.prototype.forEach.call(list.children, function (li) {
      li.addEventListener('click', function () { pick(results[+li.dataset.i]); });
    });
    selIdx = -1;
  }

  function pick(r) {
    if (!r) return;
    hideList();
    input.value = r.type === 'point' ? r.id : r.name;
    if (r.type === 'point') {
      var s = window.MFL.heatmap.flyTo(r.pid);
      if (s) window.MFL.preview.open(r.pid, s.x, s.y);
    } else {

      var cam = window.MFL.view;
      cam.cx = r.x; cam.cy = r.y;
      if (cam.mPerPx > 15) cam.mPerPx = 15;
      cam._emit();
    }
  }

  window.MFL = window.MFL || {};
  window.MFL.search = {
    init: function () {
      init();
      hideList();
    }
  };
})();
