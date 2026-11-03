(function () {
  'use strict';

  var CSS_PX_PER_CM = 96 / 2.54;

  var MAX_ZOOM_M_PER_PX = 50 / CSS_PX_PER_CM;
  var FIT_PADDING = 46;

  var VIEW_YAW = -30 * Math.PI / 180;
  var VIEW_PITCH = 55 * Math.PI / 180;

  function clamp(v, lo, hi) { return v < lo ? lo : (v > hi ? hi : v); }

  function Camera(canvas) {
    this.canvas = canvas;
    this.cx = 0;
    this.cy = 0;
    this.mPerPx = 100;
    this.minMPerPx = MAX_ZOOM_M_PER_PX;
    this.maxMPerPx = MAX_ZOOM_M_PER_PX;
    this.onChange = null;
    this.version = 0;
    this._size = { w: 0, h: 0 };
    this.dragPx = 0;

    this.mode = '2d';
    this.yaw = VIEW_YAW;
    this.pitch = VIEW_PITCH;
    this._attachInput();
  }

  Camera.prototype._emit = function () {
    this.version++;
    if (this.onChange) this.onChange(this);
  };

  Camera.prototype.setBounds = function (bounds) {
    var w = this._width(), h = this._height();
    var spanX = Math.max(1, bounds.max_x - bounds.min_x);
    var spanY = Math.max(1, bounds.max_y - bounds.min_y);
    this.maxMPerPx = Math.max(
      spanX / Math.max(1, w - FIT_PADDING * 2),
      spanY / Math.max(1, h - FIT_PADDING * 2)
    );
    this.bounds = bounds;
    this.reset();
  };

  Camera.prototype.reset = function () {
    this.mPerPx = this.maxMPerPx;
    if (this.bounds) {
      this.cx = (this.bounds.min_x + this.bounds.max_x) / 2;
      this.cy = (this.bounds.min_y + this.bounds.max_y) / 2;
    }
    this._emit();
  };

  Camera.prototype.zoomAt = function (sx, sy, factor) {

    var before = this.screenToWorld(sx, sy, 0);
    this.mPerPx = clamp(this.mPerPx / factor, this.minMPerPx, this.maxMPerPx);

    var lin = this._unproject(sx, sy, 0, 0, 0);
    this.cx = before.x - lin.x;
    this.cy = before.y - lin.y;
    this._emit();
  };

  Camera.prototype.zoomBy = function (factor) {
    this.zoomAt(this._width() / 2, this._height() / 2, factor);
  };

  Camera.prototype.screenToWorld = function (sx, sy, z) {
    return this._unproject(sx, sy, z || 0, this.cx, this.cy);
  };

  Camera.prototype._unproject = function (sx, sy, z, cx, cy) {
    var k = this.mPerPx;
    if (this.mode === '25d') {
      var rx = (sx - this._width() / 2) * k;
      var ry = -(sy - this._height() / 2) * k / Math.cos(this.pitch) - (z || 0) * Math.tan(this.pitch);
      var cosY = Math.cos(this.yaw), sinY = Math.sin(this.yaw);
      return {
        x: cx + rx * cosY + ry * sinY,
        y: cy - rx * sinY + ry * cosY
      };
    }
    return { x: cx + (sx - this._width() / 2) * k,
             y: cy - (sy - this._height() / 2) * k + (z || 0) };
  };

  Camera.prototype.worldToScreen = function (wx, wy, z) {
    var k = 1 / this.mPerPx;
    if (this.mode === '25d') {
      var dx = wx - this.cx, dy = wy - this.cy;
      var cosY = Math.cos(this.yaw), sinY = Math.sin(this.yaw);
      var rx = dx * cosY - dy * sinY;
      var ry = dx * sinY + dy * cosY;
      return {
        x: this._width() / 2 + rx * k,
        y: this._height() / 2 - (ry * Math.cos(this.pitch) + (z || 0) * Math.sin(this.pitch)) * k
      };
    }
    return { x: (wx - this.cx) * k + this._width() / 2,
             y: (this.cy - wy + (z || 0)) * k + this._height() / 2 };
  };

  Camera.prototype.toggleMode = function () {
    this.mode = this.mode === '2d' ? '25d' : '2d';
    this._emit();
    return this.mode;
  };

  Camera.prototype._width = function () { return this._size.w || 1; };
  Camera.prototype._height = function () { return this._size.h || 1; };

  Camera.prototype.setSize = function (w, h) { this._size = { w: w, h: h }; };

  Camera.prototype._attachInput = function () {
    var self = this;
    var canvas = this.canvas;
    var dragging = false, lastX = 0, lastY = 0, moved = 0;

    canvas.addEventListener('wheel', function (e) {
      e.preventDefault();
      var rect = canvas.getBoundingClientRect();
      var sx = (e.clientX - rect.left) / rect.width * self._width();
      var sy = (e.clientY - rect.top) / rect.height * self._height();
      self.zoomAt(sx, sy, Math.exp(-e.deltaY * 0.0016));
    }, { passive: false });

    canvas.addEventListener('pointerdown', function (e) {
      dragging = true; moved = 0; self.dragPx = 0;
      lastX = e.clientX; lastY = e.clientY;
      canvas.classList.add('dragging');
      canvas.setPointerCapture(e.pointerId);
    });
    canvas.addEventListener('pointermove', function (e) {
      if (!dragging) return;
      var rect = canvas.getBoundingClientRect();
      var k = self._width() / rect.width;
      var dx = (e.clientX - lastX) * k, dy = (e.clientY - lastY) * k;
      lastX = e.clientX; lastY = e.clientY;
      moved += Math.abs(dx) + Math.abs(dy);
      self.dragPx += Math.abs(dx) + Math.abs(dy);

      var sy = (e.clientY - rect.top) / rect.height * self._height();
      var sx = (e.clientX - rect.left) / rect.width * self._width();
      var w0 = self._unproject(sx - dx, sy - dy, 0, 0, 0);
      var w1 = self._unproject(sx, sy, 0, 0, 0);
      self.cx -= w1.x - w0.x;
      self.cy -= w1.y - w0.y;
      self._emit();
    });
    canvas.addEventListener('pointerup', function () { dragging = false; canvas.classList.remove('dragging'); });
    canvas.addEventListener('pointercancel', function () { dragging = false; canvas.classList.remove('dragging'); });
    canvas.addEventListener('dblclick', function () { self.reset(); });
  };

  Camera.prototype.scaleBar = function (maxPx) {
    maxPx = maxPx || 140;
    var candidates = [50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000, 50000];
    var m = candidates[0];
    for (var i = 0; i < candidates.length; i++) {
      if (candidates[i] / this.mPerPx <= maxPx) { m = candidates[i]; }
    }
    var label = m >= 1000 ? (m / 1000) + ' km' : m + ' m';

    var ratio = Math.round(this.mPerPx * 100 / (2.54 / 96));
    return { m: m, px: m / this.mPerPx, label: label, ratio: ratio };
  };

  window.MFL = window.MFL || {};
  window.MFL.Camera = Camera;
  window.MFL.MAX_ZOOM_M_PER_PX = MAX_ZOOM_M_PER_PX;
})();
