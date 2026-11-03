(function () {
  'use strict';

  var TAU = Math.PI * 2;

  var SEV_STOPS = [[33, 193, 119], [245, 166, 35], [240, 69, 62]];
  function sevColor(v) {
    v = v < 0 ? 0 : (v > 2 ? 2 : v);
    var i = Math.min(1, Math.floor(v));
    var f = v - i;
    var a = SEV_STOPS[i], b = SEV_STOPS[i + 1];
    return 'rgb(' + Math.round(a[0] + (b[0] - a[0]) * f) + ',' +
                    Math.round(a[1] + (b[1] - a[1]) * f) + ',' +
                    Math.round(a[2] + (b[2] - a[2]) * f) + ')';
  }
  function sevCss(v) { return v === null || v === undefined ? '#3d5a7a' : sevColor(v); }

  var COLOR_NONE = '#48688f';
  var COLOR_PIPE = '#2a5180';
  var COLOR_ACCENT = '#29d3ff';

  var INFLUENCE_M = 1000;
  var TRANSITION_MS = 800;
  var RIPPLE_MS = 1100;
  var RIPPLE_R_M = 700;
  var PULSE_PERIOD_MS = 1600;

  var SEV_TEXT = ['无腐蚀', '轻度', '重度'];

  function easeOutCubic(t) { return 1 - Math.pow(1 - t, 3); }
  function clamp(v, lo, hi) { return v < lo ? lo : (v > hi ? hi : v); }

  function Heatmap(canvas, camera) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d');
    this.camera = camera;
    this.net = null;
    this.lines = [];
    this.pointsById = new Map();
    this.state = new Map();
    this.ripples = [];
    this.mouse = { x: -1, y: -1, inside: false };
    this.hoverId = null;
    this.cssW = 0; this.cssH = 0; this._k = 0;
    this._lastCamVersion = -1;

    this.sat = { img: new Image(), ok: false };

    this.onlineSet = new Set();

    this.ledgerMap = new Map();
    this.viewKind = 'corrosion';

    this.historyMap = null;
    this.historyUntil = 0;
    var self = this;
    this.sat.img.onload = function () { self.sat.ok = true; };
    this.sat.img.src = 'assets/satellite.jpg';

    var tip = document.createElement('div');
    tip.id = 'map-tip';
    canvas.parentElement.appendChild(tip);
    this.tip = tip;

    var self = this;
    canvas.addEventListener('mousemove', function (e) {
      var rect = canvas.getBoundingClientRect();
      self.mouse.x = (e.clientX - rect.left) / rect.width * self.cssW;
      self.mouse.y = (e.clientY - rect.top) / rect.height * self.cssH;
      self.mouse.inside = true;
    });
    canvas.addEventListener('mouseleave', function () {
      self.mouse.inside = false;
      self.hoverId = null;
      tip.style.display = 'none';
    });

    canvas.addEventListener('click', function (e) {
      if (self.camera.dragPx > 6) return;
      var rect = canvas.getBoundingClientRect();
      var mx = (e.clientX - rect.left) / rect.width * self.cssW;
      var my = (e.clientY - rect.top) / rect.height * self.cssH;
      var p = self._nearestPoint(mx, my, 14);
      if (p && self.onclick) {
        var z = (self.camera.mode === '25d') ? R_PIPE_M * 2 : 0;
        var s = self.camera.worldToScreen(p.x, p.y, z);
        self.onclick(p.id, s.x, s.y);
      } else if (!p && self.onclick) {
        self.onclick(null, mx, my);
      }
    });
  }

  Heatmap.prototype._nearestPoint = function (mx, my, radiusPx) {
    var best = null, bestD = radiusPx * radiusPx;
    for (var li = 0; li < this.lines.length; li++) {
      var pts = this.lines[li].pts;
      for (var i = 0; i < pts.length; i++) {
        var s = this.camera.worldToScreen(pts[i].x, pts[i].y);
        var dx = s.x - mx, dy = s.y - my;
        var d2 = dx * dx + dy * dy;
        if (d2 < bestD) { bestD = d2; best = pts[i]; }
      }
    }
    return best;
  };

  Heatmap.prototype.loadNetwork = function (net) {
    this.net = net;
    var byId = this.pointsById;
    net.points.forEach(function (p) { byId.set(p.id, p); });
    this.lines = net.lines.map(function (l) {
      var pts = net.points.filter(function (p) { return p.line === l.id; })
                          .sort(function (a, b) { return a.mileage - b.mileage; });
      return Object.assign({}, l, { pts: pts, _eff: null });
    });
    this.linesById = new Map(this.lines.map(function (l) { return [l.id, l]; }));
  };

  Heatmap.prototype.setOnline = function (ids) {
    for (var i = 0; i < ids.length; i++) this.onlineSet.add(ids[i]);
  };

  Heatmap.prototype._curOf = function (pid) {
    if (this.historyMap) {
      var v = this.historyMap.get(pid);
      return { cur: (v === undefined || v === null) ? null : v };
    }
    return this.state.get(pid);
  };

  Heatmap.prototype.flyTo = function (pid) {
    var p = this.pointsById.get(pid);
    if (!p) return null;
    this.camera.cx = p.x;
    this.camera.cy = p.y;
    if (this.camera.mPerPx > 15) this.camera.mPerPx = 15;
    this.camera._emit();
    return this.camera.worldToScreen(p.x, p.y, 30);
  };

  Heatmap.prototype.setPaused = function (v) { this.paused = !!v; };

  Heatmap.prototype.setLedger = function (points) {
    var m = new Map();
    Object.keys(points || {}).forEach(function (k) { m.set(k, points[k]); });
    this.ledgerMap = m;
  };
  Heatmap.prototype.setViewKind = function (kind) {
    this.viewKind = (kind === 'aged') ? 'aged' : 'corrosion';
    this._emit();
    return this.viewKind;
  };

  var AGE_STOPS = [[214, 232, 250], [170, 190, 235], [120, 128, 215], [75, 60, 165], [58, 48, 138]];
  function ageColor(years) {
    var t = Math.max(0, Math.min(1, years / 30));
    var seg = t * (AGE_STOPS.length - 1);
    var i = Math.min(AGE_STOPS.length - 2, Math.floor(seg));
    var f = seg - i;
    var a = AGE_STOPS[i], b = AGE_STOPS[i + 1];
    return 'rgb(' + Math.round(a[0] + (b[0] - a[0]) * f) + ',' +
           Math.round(a[1] + (b[1] - a[1]) * f) + ',' +
           Math.round(a[2] + (b[2] - a[2]) * f) + ')';
  }
  Heatmap.prototype.ageColor = ageColor;

  Heatmap.prototype._agedColorOf = function (pid) {
    var e = this.ledgerMap.get(pid);
    return ageColor(e ? e.age_years : 0);
  };

  Heatmap.prototype._drawAgedSegments = function (ctx, cam, lines, width) {
    ctx.lineWidth = width;
    for (var li = 0; li < lines.length; li++) {
      var pts = lines[li].pts;
      for (var i = 0; i < pts.length - 1; i++) {
        var a = cam.worldToScreen(pts[i].x, pts[i].y);
        var b = cam.worldToScreen(pts[i + 1].x, pts[i + 1].y);
        var ca = this._agedColorOf(pts[i].id), cb = this._agedColorOf(pts[i + 1].id);
        if (ca === cb) {
          ctx.strokeStyle = ca;
        } else {
          var pa = ca.match(/\d+/g), pb = cb.match(/\d+/g);
          ctx.strokeStyle = 'rgb(' + Math.round((+pa[0] + +pb[0]) / 2) + ',' +
            Math.round((+pa[1] + +pb[1]) / 2) + ',' + Math.round((+pa[2] + +pb[2]) / 2) + ')';
        }
        ctx.beginPath(); ctx.moveTo(a.x, a.y); ctx.lineTo(b.x, b.y); ctx.stroke();
      }
    }
  };

  Heatmap.prototype._drawAgeLegend = function () {
    var ctx = this.ctx;
    var x = 16, y = this.cssH - 96, w2 = 170, h = 10;
    ctx.save();
    ctx.globalAlpha = 0.92;
    for (var i = 0; i < w2; i++) {
      ctx.fillStyle = ageColor(i / w2 * 30);
      ctx.fillRect(x + i, y, 1.5, h);
    }
    ctx.strokeStyle = 'rgba(207,227,255,.5)';
    ctx.strokeRect(x, y, w2, h);
    ctx.fillStyle = 'rgba(207,227,255,.9)';
    ctx.font = '10px "Microsoft YaHei"';
    ctx.fillText('0 年（新管）', x, y - 4);
    ctx.fillText('30 年（设计寿命）', x + w2 - 92, y - 4);
    ctx.fillText('管道使用年限', x, y + h + 13);
    ctx.restore();
  };

  Heatmap.prototype.setHistoryState = function (map, until) {
    this.historyMap = map;
    this.historyUntil = until || 0;
    this.ripples.length = 0;
    if (this.onhistory) this.onhistory(!!map, this.historyUntil);

    if (this.onchange) this.onchange([], { silent: true });
  };
  Heatmap.prototype.clearHistoryState = function () {
    this.setHistoryState(null, 0);
  };

  Heatmap.prototype.isOnlinePending = function (pid) {
    if (this.historyMap) return false;
    return this.onlineSet.has(pid) && !this.state.has(pid);
  };

  Heatmap.prototype.applyDetections = function (items, opts) {
    opts = opts || {};
    var now = opts.now || performance.now();
    var changed = [];
    for (var i = 0; i < items.length; i++) {
      var it = items[i];
      var p = this.pointsById.get(it.point_id);
      if (!p || it.severity === null || it.severity === undefined) continue;
      var st = this.state.get(it.point_id) || { prev: null, cur: null, t0: 0, ts: 0 };
      st.prev = this.effValue(st, now);
      st.cur = it.severity;
      st.t0 = now;
      st.ts = it.timestamp || 0;
      this.state.set(it.point_id, st);
      if (!opts.silent) {
        this.ripples.push({ x: p.x, y: p.y, t0: now, color: sevColor(it.severity) });
      }
      changed.push(it.point_id);
    }
    if (changed.length && this.onchange) this.onchange(changed, opts);
    return changed;
  };

  Heatmap.prototype.effValue = function (st, now) {
    if (!st || st.cur === null || st.cur === undefined) return null;
    if (st.prev === null || st.prev === undefined) return st.cur;
    var t = clamp((now - st.t0) / TRANSITION_MS, 0, 1);
    return st.prev + (st.cur - st.prev) * easeOutCubic(t);
  };

  Heatmap.prototype.getStateCounts = function () {
    var counts = { total: this.pointsById.size, none: 0, online: 0, 0: 0, 1: 0, 2: 0 };
    var self = this;
    this.pointsById.forEach(function (_p, pid) {
      var st = self._curOf(pid);
      if (self.historyMap) {
        if (st && st.cur !== null && st.cur !== undefined) counts[st.cur]++;
        else counts.none++;
        return;
      }
      if (self.onlineSet.has(pid)) counts.online++;
      if (st && st.cur !== null && st.cur !== undefined) counts[st.cur]++;
      else if (!self.onlineSet.has(pid)) counts.none++;
    });
    return counts;
  };

  Heatmap.prototype._syncSize = function () {
    var w = this.canvas.clientWidth, h = this.canvas.clientHeight;
    var k = (window.devicePixelRatio || 1) * (window.MFL.stageScale || 1);
    var bw = Math.round(w * k), bh = Math.round(h * k);
    if (bw !== this.canvas.width || bh !== this.canvas.height || k !== this._k) {
      this.canvas.width = bw; this.canvas.height = bh;
      this.ctx.setTransform(k, 0, 0, k, 0, 0);
      this._k = k;
    }

    this.ctx.setTransform(this._k, 0, 0, this._k, 0, 0);
    this.ctx.clearRect(0, 0, w, h);
    if (w !== this.cssW || h !== this.cssH) {
      this.cssW = w; this.cssH = h;
      this.camera.setSize(w, h);
    }
  };

  Heatmap.prototype.render = function (now) {
    if (this.paused) return;
    this._syncSize();
    var ctx = this.ctx, cam = this.camera;
    var w = this.cssW, h = this.cssH;
    if (w < 2 || h < 2 || !this.net) return;

    ctx.fillStyle = '#07101f';
    ctx.fillRect(0, 0, w, h);
    this._drawSatellite(ctx, cam);
    this._drawGrid(ctx, cam, w, h);

    for (var li = 0; li < this.lines.length; li++) {
      var l = this.lines[li];
      if (!l._eff || l._eff.length !== l.pts.length) l._eff = new Array(l.pts.length);
      for (var i = 0; i < l.pts.length; i++) {

        var hs = this._curOf(l.pts[i].id);
        l._eff[i] = this.historyMap ? (hs && hs.cur !== null ? hs.cur : null)
                                    : this.effValue(this.state.get(l.pts[i].id), now);
      }
    }

    var spacing = 200 / cam.mPerPx;

    var pipeW = clamp(spacing * 0.24, 6, 10);
    var dotR = clamp(spacing * 1.24, 3, 11);

    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';

    if (cam.mode === '25d') {
      this._drawPipes25d(ctx, cam, now);

      if (this.viewKind === 'aged') this._drawAgeLegend();

      if (spacing > 8 && this.viewKind !== 'aged') this._drawFlow25d(ctx, cam, now);
      this._drawStations(ctx, cam);
      this._updateHover(ctx, cam, clamp(spacing * 0.62, 1.5, 5.5));
    } else {

      ctx.strokeStyle = COLOR_PIPE;
      ctx.lineWidth = pipeW;
      for (li = 0; li < this.lines.length; li++) this._strokeLine(ctx, cam, this.lines[li], null, 0, 0);

      if (this.viewKind === 'aged') {
        this._drawAgedSegments(ctx, cam, this.lines, pipeW + 0.6);
        this._drawAgeLegend();
        this._drawStations(ctx, cam);
        this._drawPoints(ctx, cam, now, dotR, true);
        this._updateHover(ctx, cam, dotR);
      } else {

        for (li = 0; li < this.lines.length; li++) this._drawColoredSegments(ctx, cam, this.lines[li], pipeW + 0.6);

        this._drawStations(ctx, cam);
        this._drawPoints(ctx, cam, now, dotR);

        if (spacing > 8) this._drawFlow2d(ctx, cam, now, pipeW);
        this._drawRipples(ctx, cam, now);
        this._updateHover(ctx, cam, dotR);
      }
    }

    if (cam.version !== this._lastCamVersion) {
      this._lastCamVersion = cam.version;
      this._updateScalebar();
    }
  };

  Heatmap.prototype._strokeLine = function (ctx, cam, line, color, extraW, alpha) {
    var pts = line.pts;
    if (pts.length < 2) return;
    if (color) ctx.strokeStyle = color;
    if (alpha !== undefined) ctx.globalAlpha = alpha;
    ctx.beginPath();
    var s = cam.worldToScreen(pts[0].x, pts[0].y);
    ctx.moveTo(s.x, s.y);
    for (var i = 1; i < pts.length; i++) {
      s = cam.worldToScreen(pts[i].x, pts[i].y);
      ctx.lineTo(s.x, s.y);
    }
    ctx.stroke();
    ctx.globalAlpha = 1;
  };

  Heatmap.prototype._pointStateColor = function (pid, v) {
    if (v !== null && v !== undefined) return sevColor(v);
    if (this.onlineSet.has(pid)) return COLOR_ONLINE;
    return COLOR_NONE;
  };

  Heatmap.prototype._drawColoredSegments = function (ctx, cam, line, width) {
    var pts = line.pts, eff = line._eff;
    var n = pts.length;
    if (n < 2) return;
    var span = pts[n - 1].mileage - pts[0].mileage || 200;
    var spacingM = span / (n - 1);
    var K = Math.max(1, Math.ceil(INFLUENCE_M / spacingM));
    ctx.lineWidth = width;
    for (var i = 0; i < n - 1; i++) {
      var mid = (pts[i].mileage + pts[i + 1].mileage) / 2;
      var sumW = 0, sumV = 0;
      for (var j = Math.max(0, i - K); j <= Math.min(n - 1, i + K); j++) {
        if (eff[j] === null) continue;
        var d = Math.abs(pts[j].mileage - mid);
        if (d > INFLUENCE_M) continue;
        var wgt = 1 - d / INFLUENCE_M;
        sumW += wgt; sumV += wgt * eff[j];
      }
      var colStr;
      if (sumW >= 1e-4) {
        colStr = sevColor(sumV / sumW);
      } else {

        var ca = this._pointStateColor(pts[i].id, eff[i]);
        var cb = this._pointStateColor(pts[i + 1].id, eff[i + 1]);
        if (ca === cb) { colStr = ca; }
        else {
          var pa = ca.match(/\d+/g), pb = cb.match(/\d+/g);
          colStr = 'rgb(' + Math.round((+pa[0] + +pb[0]) / 2) + ',' +
                   Math.round((+pa[1] + +pb[1]) / 2) + ',' +
                   Math.round((+pa[2] + +pb[2]) / 2) + ')';
        }
      }
      var a = cam.worldToScreen(pts[i].x, pts[i].y);
      var b = cam.worldToScreen(pts[i + 1].x, pts[i + 1].y);
      ctx.strokeStyle = colStr;
      ctx.beginPath();
      ctx.moveTo(a.x, a.y);
      ctx.lineTo(b.x, b.y);
      ctx.stroke();
    }
  };

  Heatmap.prototype._drawSatellite = function (ctx, cam) {
    if (!this.sat.ok || !this.net) return;
    var b = this.net.meta.bounds;
    var img = this.sat.img;
    var O = cam.worldToScreen(b.min_x, b.max_y);
    var P = cam.worldToScreen(b.max_x, b.max_y);
    var Q = cam.worldToScreen(b.min_x, b.min_y);
    var ax = (P.x - O.x) / img.naturalWidth, ay = (P.y - O.y) / img.naturalWidth;
    var bx = (Q.x - O.x) / img.naturalHeight, by = (Q.y - O.y) / img.naturalHeight;
    ctx.save();
    ctx.transform(ax, ay, bx, by, O.x, O.y);
    ctx.drawImage(img, 0, 0);
    ctx.restore();

    ctx.save();
    ctx.transform(ax, ay, bx, by, O.x, O.y);
    ctx.fillStyle = 'rgba(5, 10, 20, 0.45)';
    ctx.fillRect(0, 0, img.naturalWidth, img.naturalHeight);
    ctx.restore();
  };

  var R_PIPE_M = 30;
  var _pipeColorCache = new Map();
  var PIPE_NONE = { body: '#3a5878', hi: '#5a7898', flange: '#2a4158', glow: '#3a5878' };

  var COLOR_ONLINE = '#3aa0e8';
  var PIPE_ONLINE = { body: '#2f86c8', hi: '#5aa8dd', flange: '#1e5f92', glow: '#3aa0e8' };

  function sevRGB25(v) {
    v = clamp(v, 0, 2);
    var i = Math.min(1, Math.floor(v)), f = v - i;
    var a = SEV_STOPS[i], b = SEV_STOPS[i + 1];
    return [a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f];
  }
  function pipeColor(v) {
    var q = Math.round(clamp(v, 0, 2) * 25);
    var hit = _pipeColorCache.get(q);
    if (hit) return hit;
    var rgb = sevRGB25(q / 25);
    function s(c) { return 'rgb(' + Math.round(c[0]) + ',' + Math.round(c[1]) + ',' + Math.round(c[2]) + ')'; }
    hit = {
      body: s(rgb.map(function (c) { return c * 0.88; })),
      hi: s(rgb.map(function (c) { return Math.min(255, c * 0.5 + 128); })),
      flange: s(rgb.map(function (c) { return c * 0.72; })),
      glow: s(rgb)
    };
    if (_pipeColorCache.size > 200) _pipeColorCache.clear();
    _pipeColorCache.set(q, hit);
    return hit;
  }

  Heatmap.prototype._buildSegs25d = function (cam, line, R_s) {
    var pts = line.pts, eff = line._eff, n = pts.length;
    var segs = [];
    for (var i = 0; i < n; i++) {
      var p = pts[i];
      var prev = pts[i - 1], next = pts[i + 1];
      var ax_w = prev ? (p.x + prev.x) / 2 : p.x - (next ? next.x - p.x : R_PIPE_M) / 2;
      var ay_w = prev ? (p.y + prev.y) / 2 : p.y - (next ? next.y - p.y : R_PIPE_M) / 2;
      var bx_w = next ? (p.x + next.x) / 2 : p.x + (prev ? p.x - prev.x : R_PIPE_M) / 2;
      var by_w = next ? (p.y + next.y) / 2 : p.y + (prev ? p.y - prev.y : R_PIPE_M) / 2;
      var a = cam.worldToScreen(ax_w, ay_w, R_PIPE_M);
      var b = cam.worldToScreen(bx_w, by_w, R_PIPE_M);
      var a0 = cam.worldToScreen(ax_w, ay_w, 0);
      var b0 = cam.worldToScreen(bx_w, by_w, 0);

      var pad = R_s * 3 + 20;
      var minX = Math.min(a.x, b.x, a0.x, b0.x), maxX = Math.max(a.x, b.x, a0.x, b0.x);
      var minY = Math.min(a.y, b.y, a0.y, b0.y), maxY = Math.max(a.y, b.y, a0.y, b0.y);
      if (maxX < -pad || minX > this.cssW + pad || maxY < -pad || minY > this.cssH + pad) continue;

      var vs = [], sum = 0;
      if (eff[i] !== null) { vs.push(eff[i]); sum += eff[i]; }
      if (i > 0 && eff[i - 1] !== null) { vs.push(eff[i - 1]); sum += eff[i - 1]; }
      if (i < n - 1 && eff[i + 1] !== null) { vs.push(eff[i + 1]); sum += eff[i + 1]; }

      var col = vs.length ? pipeColor(sum / vs.length)
                : (this.onlineSet.has(p.id) ? PIPE_ONLINE : PIPE_NONE);
      segs.push({ sy: (a.y + b.y) / 2, a: a, b: b, a0: a0, b0: b0, col: col,
                  p: p, v: eff[i], R_s: R_s });
    }
    return segs;
  };

  Heatmap.prototype._drawPipes25d = function (ctx, cam, now) {

    var R_s = clamp((200 / cam.mPerPx) * 0.38, 2.4, 16);
    var cosP = Math.cos(cam.pitch), sinP = Math.sin(cam.pitch);
    var k = 1 / cam.mPerPx;
    var all = [];
    for (var li = 0; li < this.lines.length; li++) {
      all = all.concat(this._buildSegs25d(cam, this.lines[li], R_s));
    }
    all.sort(function (u, v) { return u.sy - v.sy; });
    var short = R_s < 2.8;
    ctx.lineCap = 'butt';

    for (var i = 0; i < all.length; i++) {
      var g = all[i];

      if (!short) {
        ctx.strokeStyle = 'rgba(0, 0, 0, 0.4)';
        ctx.lineWidth = R_s * 1.15;
        ctx.beginPath(); ctx.moveTo(g.a0.x, g.a0.y); ctx.lineTo(g.b0.x, g.b0.y); ctx.stroke();
      }

      ctx.strokeStyle = g.col.body;
      ctx.lineWidth = R_s * 2;
      ctx.beginPath(); ctx.moveTo(g.a.x, g.a.y); ctx.lineTo(g.b.x, g.b.y); ctx.stroke();

      if (!short) {
        ctx.strokeStyle = g.col.hi;
        ctx.globalAlpha = 0.85;
        ctx.lineWidth = R_s * 0.7;
        ctx.beginPath();
        ctx.moveTo(g.a.x, g.a.y - R_s * 0.42);
        ctx.lineTo(g.b.x, g.b.y - R_s * 0.42);
        ctx.stroke();
        ctx.globalAlpha = 1;
      }

      if (R_s > 6) {
        var far = (g.a0.y <= g.b0.y) ? g.a : g.b;
        var ang = Math.atan2(g.b.y - g.a.y, g.b.x - g.a.x);
        ctx.fillStyle = g.col.flange;
        ctx.globalAlpha = 0.55;
        ctx.beginPath();
        ctx.ellipse(far.x, far.y, R_s * 0.98, Math.max(1, R_s * 0.3), ang + Math.PI / 2, 0, TAU);
        ctx.fill();
        ctx.globalAlpha = 1;
      }

      var st25 = this._curOf(g.p.id);
      if (st25 && st25.cur === 2 && !short) {
        ctx.strokeStyle = 'rgba(240,69,62,1)';
        ctx.globalAlpha = 0.25 + 0.25 * Math.sin(now / 300);
        ctx.lineWidth = R_s * 2;
        ctx.beginPath(); ctx.moveTo(g.a.x, g.a.y); ctx.lineTo(g.b.x, g.b.y); ctx.stroke();
        ctx.globalAlpha = 1;
      }

      var st = this._curOf(g.p.id);
      if (st && st.cur === 2) {
        var gp = cam.worldToScreen(g.p.x, g.p.y, 0);
        var phase = (now % PULSE_PERIOD_MS) / PULSE_PERIOD_MS;
        var rg = R_s * (4.5 + 1.8 * Math.sin(TAU * phase));
        var grd = ctx.createRadialGradient(gp.x, gp.y, 0, gp.x, gp.y, rg);
        grd.addColorStop(0, 'rgba(240,69,62,0.35)');
        grd.addColorStop(1, 'rgba(240,69,62,0)');
        ctx.fillStyle = grd;
        ctx.save();
        ctx.translate(gp.x, gp.y);
        ctx.scale(1, cosP);
        ctx.beginPath(); ctx.arc(0, 0, rg, 0, TAU); ctx.fill();
        ctx.restore();
      }
    }

    for (var r = 0; r < this.ripples.length; r++) {
      var rp = this.ripples[r];
      var t = (now - rp.t0) / RIPPLE_MS;
      if (t >= 1) continue;
      var rr = RIPPLE_R_M * easeOutCubic(t) * k;
      var gp2 = cam.worldToScreen(rp.x, rp.y, 0);
      ctx.strokeStyle = rp.color;
      ctx.globalAlpha = 0.55 * (1 - t);
      ctx.lineWidth = 2;
      ctx.save();
      ctx.translate(gp2.x, gp2.y);
      ctx.scale(1, cosP);
      ctx.beginPath(); ctx.arc(0, 0, rr, 0, TAU); ctx.stroke();
      ctx.restore();
      ctx.globalAlpha = 1;
    }
  };

  function flowAlpha(now) {
    return 0.38 + 0.27 * Math.sin(now / 480);
  }

  Heatmap.prototype._drawFlow2d = function (ctx, cam, now, pipeW) {
    ctx.save();
    ctx.setLineDash([pipeW * 1.6, pipeW * 1.5]);
    ctx.lineDashOffset = -(now / 28) % (pipeW * 3.1);
    ctx.strokeStyle = 'rgba(255,255,255,1)';
    ctx.globalAlpha = flowAlpha(now);
    ctx.lineWidth = Math.max(1.5, pipeW * 0.45);
    ctx.lineCap = 'butt';
    for (var li = 0; li < this.lines.length; li++) {
      this._strokeLine(ctx, cam, this.lines[li]);
    }
    ctx.restore();
  };

  Heatmap.prototype._drawFlow25d = function (ctx, cam, now) {
    var R_s = clamp((200 / cam.mPerPx) * 1.14, 2.4, 40);
    if (R_s < 5) return;
    var breath = flowAlpha(now);
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    for (var li = 0; li < this.lines.length; li++) {
      var pts = this.lines[li].pts;
      for (var i = 0; i < pts.length - 1; i++) {
        var pA = pts[i], pB = pts[i + 1];
        var a = cam.worldToScreen(pA.x, pA.y, R_PIPE_M);
        var b = cam.worldToScreen(pB.x, pB.y, R_PIPE_M);
        var dx = b.x - a.x, dy = b.y - a.y;
        var len = Math.hypot(dx, dy);
        if (len < 26 || a.x < -40 || a.x > this.cssW + 40 || a.y < -40 || a.y > this.cssH + 40) continue;
        var ux = dx / len, uy = dy / len;
        var px = -uy, py = ux;
        var chev = Math.min(R_s * 1.1, len * 0.3);

        var phase = ((now * 0.00022) + (i * 0.37 + li * 0.61)) % 1;
        var t = phase;
        var cxp = a.x + dx * t, cyp = a.y + dy * t;
        var back = chev * 0.9;
        ctx.strokeStyle = 'rgba(255,255,255,1)';
        ctx.globalAlpha = breath;
        ctx.lineWidth = Math.max(1.5, R_s * 0.28);
        ctx.beginPath();
        ctx.moveTo(cxp - ux * back + px * chev, cyp - uy * back + py * chev);
        ctx.lineTo(cxp, cyp);
        ctx.lineTo(cxp - ux * back - px * chev, cyp - uy * back - py * chev);
        ctx.stroke();
        ctx.globalAlpha = 1;
      }
    }
  };

  Heatmap.prototype._drawGrid = function (ctx, cam, w, h) {
    if (!this.net) return;
    var b = this.net.meta.bounds;
    var step = cam.mPerPx > 30 ? 20000 : (cam.mPerPx > 8 ? 5000 : 1000);
    var tl = cam.screenToWorld(0, 0), br = cam.screenToWorld(w, h);
    ctx.strokeStyle = 'rgba(70,130,210,0.07)';
    ctx.lineWidth = 1;
    ctx.beginPath();
    for (var gx = Math.floor(tl.x / step) * step; gx <= br.x; gx += step) {
      var sx = cam.worldToScreen(gx, 0).x;
      ctx.moveTo(sx, 0); ctx.lineTo(sx, h);
    }
    for (var gy = Math.floor(br.y / step) * step; gy <= tl.y; gy += step) {
      var sy = cam.worldToScreen(0, gy).y;
      ctx.moveTo(0, sy); ctx.lineTo(w, sy);
    }
    ctx.stroke();

    var nw = cam.worldToScreen(b.min_x, b.max_y), ne = cam.worldToScreen(b.max_x, b.max_y);
    var sw = cam.worldToScreen(b.min_x, b.min_y), se = cam.worldToScreen(b.max_x, b.min_y);
    ctx.strokeStyle = 'rgba(41,211,255,0.22)';
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(nw.x, nw.y); ctx.lineTo(ne.x, ne.y);
    ctx.lineTo(se.x, se.y); ctx.lineTo(sw.x, sw.y);
    ctx.closePath();
    ctx.stroke();
    if (cam.mode === '2d') {
      var x0 = Math.min(nw.x, se.x), y0 = Math.min(nw.y, se.y);
      var x1 = Math.max(nw.x, se.x), y1 = Math.max(nw.y, se.y);
      ctx.strokeStyle = 'rgba(41,211,255,0.6)';
      ctx.lineWidth = 2;
      var L = 14, cs = [[x0, y0, 1, 1], [x1, y0, -1, 1], [x0, y1, 1, -1], [x1, y1, -1, -1]];
      ctx.beginPath();
      for (var i = 0; i < 4; i++) {
        var cx2 = cs[i][0], cy2 = cs[i][1];
        ctx.moveTo(cx2 + cs[i][2] * L, cy2); ctx.lineTo(cx2, cy2); ctx.lineTo(cx2, cy2 + cs[i][3] * L);
      }
      ctx.stroke();
    } else {
      ctx.fillStyle = 'rgba(41,211,255,0.7)';
      [nw, ne, sw, se].forEach(function (c) {
        ctx.beginPath();
        ctx.moveTo(c.x, c.y - 5); ctx.lineTo(c.x + 5, c.y);
        ctx.lineTo(c.x, c.y + 5); ctx.lineTo(c.x - 5, c.y);
        ctx.closePath(); ctx.fill();
      });
    }
  };

  Heatmap.prototype._drawStations = function (ctx, cam) {
    var stations = this.net.stations, mPerPx = cam.mPerPx;
    ctx.textAlign = 'center';
    for (var i = 0; i < stations.length; i++) {
      var st = stations[i];
      var s = cam.worldToScreen(st.x, st.y);
      if (s.x < -60 || s.x > this.cssW + 60 || s.y < -30 || s.y > this.cssH + 30) continue;
      var valve = st.type === '阀室';
      var r = valve ? 3 : 4.5;
      ctx.save();
      ctx.translate(s.x, s.y);
      ctx.rotate(Math.PI / 4);
      ctx.fillStyle = '#0a1a30';
      ctx.strokeStyle = COLOR_ACCENT;
      ctx.lineWidth = 1.4;
      ctx.fillRect(-r, -r, r * 2, r * 2);
      ctx.strokeRect(-r, -r, r * 2, r * 2);
      ctx.restore();
      var showLabel = valve ? mPerPx < 10 : mPerPx < 40;
      if (showLabel) {
        ctx.fillStyle = valve ? 'rgba(159,195,255,0.75)' : '#9fc3ff';
        ctx.font = (valve ? '10px' : '12px') + ' "Microsoft YaHei", sans-serif';
        ctx.fillText(st.name, s.x, s.y - r - 5);
      }
    }
    ctx.textAlign = 'left';
  };

  Heatmap.prototype._drawPoints = function (ctx, cam, now, dotR, agedMode) {
    var mPerPx = cam.mPerPx;
    var showId = 200 / mPerPx > 30;
    ctx.font = '10px Consolas, monospace';
    for (var li = 0; li < this.lines.length; li++) {
      var line = this.lines[li], pts = line.pts, eff = line._eff;
      for (var i = 0; i < pts.length; i++) {
        var p = pts[i], v = eff[i];
        var s = cam.worldToScreen(p.x, p.y);
        if (s.x < -10 || s.x > this.cssW + 10 || s.y < -10 || s.y > this.cssH + 10) continue;
        var st = this._curOf(p.id);
        var isSevere = st && st.cur === 2;
        if (isSevere && !agedMode) this._drawPulse(ctx, s.x, s.y, dotR, now);

        ctx.fillStyle = agedMode ? this._agedColorOf(p.id)
          : ((v === null && this.isOnlinePending(p.id)) ? COLOR_ONLINE : sevCss(v));
        ctx.beginPath();
        ctx.arc(s.x, s.y, dotR, 0, TAU);
        ctx.fill();
        if (showId) {
          ctx.fillStyle = 'rgba(159,195,255,0.7)';
          ctx.fillText(p.id, s.x + dotR + 2, s.y - dotR - 2);
        }
      }
    }
  };

  Heatmap.prototype._drawPulse = function (ctx, x, y, r, now) {
    var phase = (now % PULSE_PERIOD_MS) / PULSE_PERIOD_MS;
    var glowR = r * (2.2 + 0.9 * Math.sin(TAU * phase));
    var g = ctx.createRadialGradient(x, y, r * 0.4, x, y, glowR);
    g.addColorStop(0, 'rgba(240,69,62,0.4)');
    g.addColorStop(1, 'rgba(240,69,62,0)');
    ctx.fillStyle = g;
    ctx.beginPath();
    ctx.arc(x, y, glowR, 0, TAU);
    ctx.fill();
  };

  Heatmap.prototype._drawRipples = function (ctx, cam, now) {
    for (var i = this.ripples.length - 1; i >= 0; i--) {
      var rp = this.ripples[i];
      var t = (now - rp.t0) / RIPPLE_MS;
      if (t >= 1) { this.ripples.splice(i, 1); continue; }
      var r = RIPPLE_R_M * easeOutCubic(t) / cam.mPerPx;
      ctx.strokeStyle = rp.color;
      ctx.globalAlpha = 0.55 * (1 - t);
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.arc(cam.worldToScreen(rp.x, rp.y).x, cam.worldToScreen(rp.x, rp.y).y, r, 0, TAU);
      ctx.stroke();
      ctx.globalAlpha = 1;
    }
  };

  Heatmap.prototype._updateHover = function (ctx, cam, dotR) {
    if (!this.mouse.inside) return;
    var best = this._nearestPoint(this.mouse.x, this.mouse.y, 14);
    if (!best) { if (this.hoverId) { this.hoverId = null; this.tip.style.display = 'none'; } return; }

    if (best.id !== this.hoverId) {
      this.hoverId = best.id;
      var st = this._curOf(best.id);
      var line = this.linesById.get(best.line);
      var html = '<b>' + best.id + '</b>　' + (line ? line.name : '') + '　K' + (best.mileage / 1000).toFixed(1);

      var lg = this.ledgerMap.get(best.id);
      if (lg) {
        html += '<br>管龄 <b style="color:' + ageColor(lg.age_years) + '">' +
                lg.age_years.toFixed(1) + ' 年</b> · 壁厚 ' + lg.wall_mm +
                'mm · ' + lg.material + '<br>安装 ' +
                new Date(lg.installed_ms).toLocaleDateString() + ' · 清管 ' +
                new Date(lg.last_pig_ms).toLocaleDateString();
      }
      if (this.viewKind !== 'aged') {
        if (st && st.cur !== null && st.cur !== undefined) {
          var t = st.ts ? new Date(st.ts).toTimeString().slice(0, 8) : '--';
          html += '<br>状态：<b style="color:' + sevColor(st.cur) + '">' + SEV_TEXT[st.cur] + '</b>　' + t + ' 更新';
        } else if (this.onlineSet.has(best.id)) {
          html += '<br>状态：<span style="color:#3aa0e8">在线待检</span>';
        } else {
          html += '<br>状态：暂无检测数据';
        }
      }
      this.tip.innerHTML = html;
      this.tip.style.display = 'block';
    }
    var sp = cam.worldToScreen(best.x, best.y);
    this.tip.style.left = Math.min(sp.x + 14, this.cssW - this.tip.offsetWidth - 8) + 'px';
    this.tip.style.top = Math.min(sp.y + 14, this.cssH - this.tip.offsetHeight - 8) + 'px';

    ctx.strokeStyle = COLOR_ACCENT;
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.arc(sp.x, sp.y, dotR + 3.5, 0, TAU);
    ctx.stroke();
  };

  Heatmap.prototype._updateScalebar = function () {
    var bar = this.camera.scaleBar(140);
    var line = document.getElementById('scale-line');
    var text = document.getElementById('scale-text');
    var ratio = document.getElementById('scale-ratio');
    if (!line) return;
    line.style.width = Math.max(30, bar.px) + 'px';
    text.textContent = bar.label;
    ratio.textContent = bar.ratio >= 100000
      ? '比例 1:' + (bar.ratio / 10000).toFixed(1) + '万'
      : '比例 1:' + bar.ratio;
  };

  window.MFL = window.MFL || {};
  window.MFL.Heatmap = Heatmap;
  window.MFL.sevColor = sevColor;
})();
