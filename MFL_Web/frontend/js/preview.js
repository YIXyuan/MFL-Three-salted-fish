(function () {
  'use strict';

  var el = null;
  var curId = null;
  var reqSeq = 0;

  var SEV_TEXT = ['无腐蚀', '轻度', '重度'];

  function ensure() {
    if (el) return el;
    el = document.createElement('div');
    el.id = 'map-preview';
    document.getElementById('map-wrap').appendChild(el);
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && curId) close();
    });
    return el;
  }

  function fmtTime(ms) {
    if (!ms) return '--';
    var d = new Date(ms);
    function p(n) { return n < 10 ? '0' + n : n; }
    return (d.getMonth() + 1) + '月' + d.getDate() + '日 ' +
           p(d.getHours()) + ':' + p(d.getMinutes());
  }

  function position(sx, sy, w, h) {
    var wrap = document.getElementById('map-wrap');
    var W = wrap.clientWidth, H = wrap.clientHeight;
    var x = sx - w / 2;
    x = Math.max(8, Math.min(x, W - w - 8));
    var y = sy - h - 14;
    if (y < 8) y = sy + 18;
    y = Math.max(8, Math.min(y, H - h - 8));
    el.style.left = x + 'px';
    el.style.top = y + 'px';
  }

  function open(pointId, sx, sy) {
    var box = ensure();
    curId = pointId;
    var seq = ++reqSeq;
    box.style.display = 'block';

    var hm = window.MFL.heatmap;
    var p = hm.pointsById.get(pointId);
    var line = p && hm.linesById.get(p.line);
    var st = hm.state.get(pointId);
    var sevHtml = (st && st.cur != null)
      ? '<span style="color:' + MFL.sevColor(st.cur) + '">' + SEV_TEXT[st.cur] + '</span>'
      : '<span style="color:#7e9cc4">未检测</span>';

    box.innerHTML =
      '<div class="pv-hd"><b>' + pointId + '</b>' +
      '<span class="pv-sub">' + (line ? line.name : '') + '　K' +
      (p ? (p.mileage / 1000).toFixed(1) : '--') + '　·　' + sevHtml + '</span>' +
      '<span class="pv-close" title="关闭">✕</span></div>' +
      '<div class="pv-img">加载中…</div>' +
      '<div class="pv-ft"><span class="pv-hist">查看全部历史</span></div>';

    box.querySelector('.pv-close').addEventListener('click', close);
    box.querySelector('.pv-hist').addEventListener('click', function () {
      close();
      window.MFL.history.open(pointId);
    });

    var lg = window.MFL.heatmap.ledgerMap.get(pointId);
    var ageHtml = lg
      ? '<div class="pv-ledger">管龄 ' + lg.age_years.toFixed(1) + ' 年 · 壁厚 ' +
        lg.wall_mm + 'mm · ' + lg.material + '</div>'
      : '';
    box.querySelector('.pv-hd').insertAdjacentHTML('afterend', ageHtml);

    position(sx, sy, 260, 210);
    fetch('/api/points/' + pointId + '/captures')
      .then(function (r) { return r.json(); })
      .then(function (j) {
        if (curId !== pointId || seq !== reqSeq) return;
        var caps = j.captures || [];
        var imgBox = box.querySelector('.pv-img');
        if (!caps.length) {
          imgBox.innerHTML = '<div class="pv-empty">暂无历史图像</div>';
        } else {
          var latest = caps[0];
          imgBox.innerHTML = '<img src="' + latest.url + '" alt="latest">' +
            '<span class="pv-time">' + fmtTime(latest.time) + '</span>';
          box.querySelector('.pv-hist').textContent = '查看全部 ' + caps.length + ' 张历史';
        }
        position(sx, sy, 260, box.offsetHeight);
      })
      .catch(function () {
        if (curId === pointId && seq === reqSeq) {
          box.querySelector('.pv-img').innerHTML = '<div class="pv-empty">加载失败</div>';
        }
      });
  }

  function close() {
    if (el) el.style.display = 'none';
    curId = null;
  }

  window.MFL = window.MFL || {};
  window.MFL.preview = { open: open, close: close };
})();
