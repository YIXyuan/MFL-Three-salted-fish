"""

"""

import argparse
import json
import logging
import os
import queue
import re
import threading
import time
from collections import Counter, deque
from pathlib import Path

from flask import Flask, Response, jsonify, request, send_from_directory

BASE_DIR = Path(__file__).resolve().parent
START_TIME = time.time()
LOG = logging.getLogger("mflweb")

ALERT_TYPE_TEXT = {"severe": "突发严重腐蚀", "offline": "节点意外离线"}
ALERT_STATUSES = ("待处理", "处理中", "已修复")

class StateStore:

    def __init__(self):
        self._lock = threading.Lock()
        self._points = {}

    def mark_online(self, point_ids):

        with self._lock:
            n = 0
            for pid in point_ids:
                prev = self._points.get(pid)
                if prev is None:
                    self._points[pid] = {"online": True}
                    n += 1
                elif not prev.get("online"):
                    prev["online"] = True
                    n += 1
            return n

    def update(self, point_id, severity, timestamp):

        with self._lock:
            prev = self._points.get(point_id)
            self._points[point_id] = {"severity": severity, "timestamp": timestamp,
                                      "online": True, "detected": True}
            return dict(prev) if prev else None

    def snapshot(self):
        with self._lock:
            return {pid: dict(v) for pid, v in self._points.items()}

class EventLog:
    def __init__(self, path=None, maxlen=200000):
        self._lock = threading.Lock()
        self._items = deque(maxlen=maxlen)
        self.path = Path(path) if path else None
        self._fh = None
        if self.path:
            self._load()
            self._fh = open(self.path, "a", encoding="utf-8")

    def _load(self):
        try:
            lines = self.path.read_text(encoding="utf-8").splitlines()
        except OSError:
            return
        for ln in lines:
            try:
                rec = json.loads(ln)
            except ValueError:
                continue
            if isinstance(rec, dict) and "point_id" in rec and "severity" in rec:
                self._items.append(rec)

    def append(self, point_id, severity, timestamp):
        rec = {"point_id": point_id, "severity": severity, "timestamp": timestamp}
        with self._lock:
            self._items.append(rec)
            if self._fh:
                self._fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
                self._fh.flush()

    def all(self):
        with self._lock:
            return list(self._items)

    def __len__(self):
        with self._lock:
            return len(self._items)

class Alerts:
    def __init__(self):
        self._lock = threading.Lock()
        self._list = []
        self._next_id = 1

    def raise_cluster(self, line, line_name, pid, mileage, text):

        with self._lock:
            for a in self._list:
                if (a["type"] == "cluster" and a.get("line") == line
                        and a["status"] != "已修复"
                        and a["_start_m"] - 800 <= mileage <= a["_end_m"] + 800):
                    if mileage < a["_start_m"]:
                        a["_start_m"], a["start_pid"] = mileage, pid
                    if mileage > a["_end_m"]:
                        a["_end_m"], a["end_pid"] = mileage, pid
                    a["count"] = a.get("count", 1) + 1
                    a["text"] = text
                    a["time"] = int(time.time() * 1000)
                    a["range_text"] = a["start_pid"] + "~" + a["end_pid"]
                    return dict(a)
            a = {"id": self._next_id, "type": "cluster", "type_text": line_name + "区片腐蚀",
                 "line": line, "point_id": pid, "start_pid": pid, "end_pid": pid,
                 "range_text": pid + "~" + pid, "count": 1,
                 "_start_m": mileage, "_end_m": mileage,
                 "text": text, "time": int(time.time() * 1000), "status": "待处理"}
            self._next_id += 1
            self._list.append(a)
            return dict(a)

    def raise_(self, type_, point_id, text):

        with self._lock:
            for a in self._list:
                if (a["type"] == type_ and a["point_id"] == point_id
                        and a["status"] != "已修复"):
                    return None
            a = {"id": self._next_id, "type": type_, "point_id": point_id,
                 "text": text, "time": int(time.time() * 1000), "status": "待处理"}
            if type_ == "severe":
                a["type_text"] = "突发严重腐蚀"
            self._next_id += 1
            self._list.append(a)
            return dict(a)

    def resolve_offline(self, point_id):

        changed = []
        with self._lock:
            for a in self._list:
                if (a["type"] == "offline" and a["point_id"] == point_id
                        and a["status"] != "已修复"):
                    a["status"] = "已修复"
                    changed.append(dict(a))
        return changed

    def set_status(self, alert_id, status):
        with self._lock:
            for a in self._list:
                if a["id"] == alert_id:
                    a["status"] = status
                    return dict(a)
        return None

    def snapshot(self, limit=100):
        with self._lock:
            out = []
            for a in reversed(self._list[-limit:]):

                out.append({k: v for k, v in a.items() if not k.startswith("_")})
            return out

    def unresolved_count(self):
        with self._lock:
            return sum(1 for a in self._list if a["status"] != "已修复")

class SseBus:

    def __init__(self):
        self._lock = threading.Lock()
        self._clients = set()

    def subscribe(self):
        q = queue.Queue(maxsize=256)
        with self._lock:
            self._clients.add(q)
        return q

    def unsubscribe(self, q):
        with self._lock:
            self._clients.discard(q)

    def publish(self, event: dict):
        with self._lock:
            clients = list(self._clients)
        for q in clients:
            try:
                q.put_nowait(event)
            except queue.Full:
                pass

    def client_count(self):
        with self._lock:
            return len(self._clients)

CAPTURE_RE = re.compile(r"^(P\d{4})_(\d+)\.(png|jpe?g|bmp|gif)$", re.I)

def scan_captures(captures_dir: Path):
    out = {}
    try:
        entries = list(os.scandir(captures_dir))
    except OSError:
        return out
    for e in entries:
        m = CAPTURE_RE.match(e.name)
        if not m:
            continue
        try:
            mtime = int(e.stat().st_mtime * 1000)
        except OSError:
            mtime = 0
        out.setdefault(m.group(1).upper(), []).append(
            {"file": e.name, "seq": int(m.group(2)), "time": mtime})
    for lst in out.values():
        lst.sort(key=lambda c: -c["seq"])
    return out

def compute_coverage(network, store):
    line_pts = {}
    for p in network["points"]:
        line_pts.setdefault(p["line"], []).append(p["id"])

    covered = {pid for pid, r in store.snapshot().items() if r.get("detected")}
    lines = []
    tot_cov = tot_all = 0
    for l in network["lines"]:
        ids = line_pts.get(l["id"], [])
        cov = sum(1 for i in ids if i in covered)
        tot_cov += cov
        tot_all += len(ids)
        lines.append({"id": l["id"], "name": l["name"], "total": len(ids),
                      "covered": cov, "pct": round(cov * 100.0 / len(ids), 1) if ids else 0})
    return {"overall": {"total": tot_all, "covered": tot_cov,
                        "pct": round(tot_cov * 100.0 / tot_all, 1) if tot_all else 0},
            "lines": lines}

def compute_top_severe(network, eventlog, store, limit=10):
    counts = Counter(e["point_id"] for e in eventlog.all() if e["severity"] == 2)
    pinfo = {p["id"]: p for p in network["points"]}
    lname = {l["id"]: l["name"] for l in network["lines"]}
    cur = store.snapshot()
    items = []
    for pid, c in counts.most_common(limit):
        p = pinfo.get(pid, {})
        items.append({"point_id": pid, "count": c,
                      "line": p.get("line"), "line_name": lname.get(p.get("line"), ""),
                      "mileage_m": p.get("mileage", 0),
                      "current": cur.get(pid, {}).get("severity")})
    return {"items": items}

def compute_volatility(network, eventlog, store, limit=20):

    series = {}
    for e in eventlog.all():
        series.setdefault(e["point_id"], []).append((e["timestamp"], e["severity"]))
    pinfo = {p["id"]: p for p in network["points"]}
    lname = {l["id"]: l["name"] for l in network["lines"]}
    cur = store.snapshot()
    rows = []
    for pid, s in series.items():
        s.sort()
        tv = sum(abs(b[1] - a[1]) for a, b in zip(s, s[1:]))
        trans = len(s) - 1
        sevs = [v for _, v in s]
        rows.append({"point_id": pid, "volatility": round(tv + 0.5 * trans, 2),
                     "tv": round(tv, 2), "transitions": trans,
                     "max": max(sevs), "min": min(sevs),
                     "current": cur.get(pid, {}).get("severity"),
                     "line": pinfo.get(pid, {}).get("line"),
                     "line_name": lname.get(pinfo.get(pid, {}).get("line"), ""),
                     "mileage_m": pinfo.get(pid, {}).get("mileage", 0)})
    rows.sort(key=lambda r: -r["volatility"])
    return {"items": rows[:limit]}

def compute_point_trend(network, eventlog, point_id, max_points=600):
    s = sorted((e["timestamp"], e["severity"]) for e in eventlog.all()
               if e["point_id"] == point_id)
    if len(s) > max_points:
        step = len(s) / max_points
        s = [s[int(i * step)] for i in range(max_points)]
    p = next((p for p in network["points"] if p["id"] == point_id), {})
    lname = {l["id"]: l["name"] for l in network["lines"]}
    return {"point_id": point_id,
            "line": p.get("line"), "line_name": lname.get(p.get("line"), ""),
            "mileage_m": p.get("mileage", 0),
            "series": [[t, v] for t, v in s]}

def read_system():

    info = {"platform": "PC 开发机", "uptime_s": int(time.time() - START_TIME),
            "cpu_pct": None, "mem_used_pct": None, "mem_total_mb": None}
    try:
        l1 = float(open("/proc/loadavg").read().split()[0])
        cores = os.cpu_count() or 1
        info["platform"] = "板端 Linux"
        info["cpu_pct"] = round(min(200.0, l1 / cores * 100), 1)
        mem = {}
        for ln in open("/proc/meminfo"):
            k, v = ln.split(":", 1)
            mem[k.strip()] = int(v.strip().split()[0])
        total, avail = mem["MemTotal"], mem["MemAvailable"]
        info["mem_total_mb"] = round(total / 1024)
        info["mem_used_pct"] = round((total - avail) * 100.0 / total, 1)
    except (OSError, ValueError, KeyError):
        pass
    return info

def create_app(frontend_dir: Path, network_path: Path, captures_dir: Path,
               store: StateStore, eventlog: EventLog, alerts: Alerts, bus: SseBus,
               offline_min: float):
    app = Flask("mflweb")

    network = json.loads(network_path.read_text(encoding="utf-8"))
    point_ids = {p["id"] for p in network["points"]}
    LOG.info("管网拓扑载入：%d 条管线 / %d 个监测点 / %d 座站场",
             len(network["lines"]), len(network["points"]), len(network["stations"]))

    @app.after_request
    def no_cache(resp):
        if request.path.startswith(("/api/", "/captures/")):
            resp.headers["Cache-Control"] = "no-cache"
        else:
            resp.headers["Cache-Control"] = "no-store"
        return resp

    @app.route("/")
    def index():
        return send_from_directory(frontend_dir, "index.html")

    @app.route("/<path:filename>")
    def static_files(filename):
        return send_from_directory(frontend_dir, filename)

    @app.route("/api/network")
    def api_network():
        return jsonify(network)

    @app.route("/api/state")
    def api_state():
        return jsonify({"server_time": int(time.time() * 1000),
                        "points": store.snapshot()})

    _prog = {"sweep": 0, "total": 0}

    @app.route("/api/progress", methods=["POST"])
    def api_progress_post():
        body = request.get_json(silent=True, force=True) or {}
        try:
            sweep = int(body.get("sweep", 0))
            total = int(body.get("total", 0))
        except (TypeError, ValueError):
            sweep = total = 0
        if sweep <= 0:
            return jsonify({"error": 'body 需为 {"sweep":k,"total":T}'}), 400
        _prog["sweep"], _prog["total"] = sweep, total
        bus.publish({"type": "progress", "sweep": sweep, "total": total})
        return jsonify({"ok": True, "sweep": sweep, "total": total})

    @app.route("/api/progress")
    def api_progress_get():
        if _prog["total"] <= 0:
            return jsonify({"active": False})
        return jsonify({"active": True, "sweep": _prog["sweep"],
                        "total": _prog["total"],
                        "server_time": int(time.time() * 1000)})

    @app.route("/api/selfcheck")
    def api_selfcheck():
        now_ms = int(time.time() * 1000)
        ev60 = sum(1 for e in eventlog.all() if e["timestamp"] >= now_ms - 60_000)
        ev5 = sum(1 for e in eventlog.all() if e["timestamp"] >= now_ms - 5_000)
        cap_n = cap_bytes = 0
        try:
            for e in os.scandir(captures_dir):
                if e.is_file():
                    cap_n += 1
                    cap_bytes += e.stat().st_size
        except OSError:
            pass
        log_bytes = 0
        try:
            log_bytes = os.path.getsize(BASE_DIR / "event_log.jsonl")
        except OSError:
            pass
        unresolved = alerts.unresolved_count()
        off_n = sum(1 for a in alerts.snapshot(10000)
                    if a["type"] == "offline" and a["status"] != "已修复")
        sse = bus.client_count()

        def mb(b):
            return "%.2f MB" % (b / 1048576)

        items = [
            {"name": "管网拓扑", "status": "ok",
             "value": "%d 线 / %d 点" % (len(network["lines"]), len(network["points"]))},
            {"name": "事件日志",
             "status": "warn" if log_bytes > 5 * 1048576 else "ok",
             "value": "%d 条 / %s" % (len(eventlog.all()), mb(log_bytes))},
            {"name": "历史图像目录", "status": "ok",
             "value": "%d 个文件 / %s" % (cap_n, mb(cap_bytes))},
            {"name": "上报链路", "status": "ok",
             "value": ("活跃（60s 内 %d 条）" % ev60) if ev60 else "空闲"},
            {"name": "前端推送",
             "status": "warn" if sse == 0 else "ok",
             "value": "%d 个客户端%s" % (sse, "（无浏览器连接）" if sse == 0 else "")},
            {"name": "告警积压",
             "status": "warn" if unresolved > 50 else "ok",
             "value": "%d 条未处理" % unresolved},
            {"name": "离线节点",
             "status": "warn" if off_n > 0 else "ok",
             "value": "%d 个未恢复" % off_n},
        ]
        import threading
        return jsonify({
            "platform": "板端 Linux" if os.path.exists("/proc/meminfo") else "PC 开发机",
            "threads": threading.active_count(),
            "cpu_load": None, "mem_used_pct": None, "mem_total_mb": None,
            "started_at_ms": int(START_TIME * 1000),
            "uptime_s": int(time.time() - START_TIME),
            "events_total": len(eventlog.all()),
            "events_60s": ev60, "events_5s": ev5,
            "log_bytes": log_bytes,
            "captures_files": cap_n, "captures_bytes": cap_bytes,
            "sse_clients": sse, "alerts_unresolved": unresolved,
            "items": items, "server_time": now_ms,
        })

    @app.route("/api/nodes/online", methods=["POST"])
    def api_nodes_online():

        body = request.get_json(silent=True, force=True) or {}
        items = body.get("items")
        if not isinstance(items, list) or not items:
            return jsonify({"error": 'body 需为 {"items":[point_id...]}'}), 400
        valid = [pid for pid in items if pid in point_ids]
        unknown = len(items) - len(valid)
        n = store.mark_online(valid)
        if n:
            bus.publish({"type": "online"})
        return jsonify({"online": n, "unknown": unknown,
                        "server_time": int(time.time() * 1000)})

    @app.route("/api/detections", methods=["POST"])
    def api_detections():
        """
"""
        body = request.get_json(silent=True, force=True)
        if isinstance(body, dict) and "items" in body:
            items = body["items"]
        elif isinstance(body, dict):
            items = [body]
        elif isinstance(body, list):
            items = body
        else:
            return jsonify({"error": "body 需为 {\"items\":[...]} 或单个检测对象"}), 400

        now_ms = int(time.time() * 1000)
        accepted, rejected, events = 0, [], []
        alert_changed = False
        for i, it in enumerate(items):
            if not isinstance(it, dict):
                rejected.append({"index": i, "reason": "item 不是对象"}); continue
            pid = it.get("point_id")
            sev = it.get("severity")
            if not isinstance(pid, str) or pid not in point_ids:
                rejected.append({"point_id": pid, "reason": "point_id 未知"}); continue
            if isinstance(sev, bool) or not isinstance(sev, int) or sev not in (0, 1, 2):
                rejected.append({"point_id": pid, "reason": "severity 需为 0/1/2"}); continue
            ts = it.get("timestamp")
            if isinstance(ts, bool) or not isinstance(ts, int) or ts <= 0:
                ts = now_ms
            prev = store.update(pid, sev, ts)
            eventlog.append(pid, sev, ts)
            events.append({"point_id": pid, "severity": sev, "timestamp": ts})
            accepted += 1

            if sev == 2 and (prev is None or prev["severity"] < 2):
                pm = {p["id"]: p for p in network["points"]}
                pinfo = pm.get(pid, {})
                if alerts.raise_cluster(pinfo.get("line", ""),
                        next((l["name"] for l in network["lines"] if l["id"] == pinfo.get("line")), ""),
                        pid, pinfo.get("mileage", 0.0),
                        "突发严重腐蚀：%s 升级为重度" % pid):
                    alert_changed = True

            if alerts.resolve_offline(pid):
                alert_changed = True

        if events:
            bus.publish({"type": "detection", "items": events})
        if alert_changed:
            bus.publish({"type": "alert"})
        return jsonify({"accepted": accepted, "rejected": rejected,
                        "server_time": now_ms})

    @app.route("/api/events/history")
    def api_events_history():
        q = request.args
        since = int(q.get("since", 0) or 0)
        until = int(q.get("until", 0) or 0) or int(time.time() * 1000)
        limit = 50000
        evs = [e for e in eventlog.all()
               if since <= e["timestamp"] <= until]
        if len(evs) > limit:
            evs = evs[-limit:]
        return jsonify({"events": evs, "count": len(evs),
                        "server_time": int(time.time() * 1000)})

    @app.route("/api/events")
    def api_events():

        def stream():
            q = bus.subscribe()
            try:
                yield "retry: 3000\n\n"
                yield "data: %s\n\n" % json.dumps(
                    {"type": "hello", "server_time": int(time.time() * 1000)},
                    ensure_ascii=False)
                while True:
                    try:
                        ev = q.get(timeout=15)
                        yield "data: %s\n\n" % json.dumps(ev, ensure_ascii=False)
                    except queue.Empty:
                        yield ": keep-alive\n\n"
            finally:
                bus.unsubscribe(q)

        resp = Response(stream(), mimetype="text/event-stream")
        resp.headers["Cache-Control"] = "no-cache"
        resp.headers["X-Accel-Buffering"] = "no"
        return resp

    @app.route("/api/health")
    def api_health():
        return jsonify({"ok": True, "points": len(store.snapshot()),
                        "events": len(eventlog), "alerts_unresolved": alerts.unresolved_count(),
                        "sse_clients": bus.client_count(),
                        "server_time": int(time.time() * 1000)})

    @app.route("/api/alerts")
    def api_alerts():
        return jsonify({"alerts": alerts.snapshot(),
                        "unresolved": alerts.unresolved_count(),
                        "server_time": int(time.time() * 1000)})

    @app.route("/api/alerts/<int:alert_id>/status", methods=["POST"])
    def api_alert_status(alert_id):
        body = request.get_json(silent=True, force=True) or {}
        status = body.get("status")
        if status not in ALERT_STATUSES:
            return jsonify({"error": "status 需为 %s" % "/".join(ALERT_STATUSES)}), 400
        a = alerts.set_status(alert_id, status)
        if not a:
            return jsonify({"error": "告警不存在"}), 404
        bus.publish({"type": "alert"})

        return jsonify({k: v for k, v in a.items() if not k.startswith("_")})

    @app.route("/api/stats/coverage")
    def api_coverage():
        return jsonify(compute_coverage(network, store))

    @app.route("/api/stats/top_severe")
    def api_top_severe():
        return jsonify(compute_top_severe(network, eventlog, store))

    @app.route("/api/stats/volatility")
    def api_volatility():
        return jsonify(compute_volatility(network, eventlog, store))

    @app.route("/api/stats/point_trend/<point_id>")
    def api_point_trend(point_id):
        if point_id not in point_ids:
            return jsonify({"error": "point_id 未知"}), 404
        return jsonify(compute_point_trend(network, eventlog, point_id))

    def _severity_at(pid, ts):

        last = None
        for e in eventlog.all():
            if e["point_id"] == pid and e["timestamp"] <= ts:
                last = e["severity"]
        return last

    @app.route("/api/points/<point_id>/captures")
    def api_point_captures(point_id):
        caps = scan_captures(captures_dir).get(point_id.upper(), [])
        for c in caps:
            c["url"] = "/captures/" + c["file"]
            c["severity"] = _severity_at(point_id.upper(), c["time"])
        return jsonify({"point_id": point_id, "captures": caps})

    @app.route("/captures/<path:fname>")
    def captures_file(fname):
        if not CAPTURE_RE.match(fname):
            return jsonify({"error": "非法文件名"}), 404
        return send_from_directory(captures_dir, fname)

    @app.route("/api/system")
    def api_system():
        info = read_system()
        snap = store.snapshot()

        last_ts = max((r["timestamp"] for r in snap.values()
                       if r.get("detected") and r.get("timestamp")), default=0)
        age = max(0, int(time.time() * 1000) - last_ts) // 1000 if last_ts else None

        info["started_at_ms"] = int(START_TIME * 1000)
        info.update({"events_total": len(eventlog),

                     "points_with_data": sum(1 for r in snap.values() if r.get("detected")),
                     "last_event_age_s": age,
                     "link": "活跃" if age is not None and age <= 60 else "空闲",
                     "sse_clients": bus.client_count(),
                     "alerts_unresolved": alerts.unresolved_count(),
                     "server_time": int(time.time() * 1000)})
        return jsonify(info)

    return app

def offline_sweeper(store, alerts, bus, offline_min):
    threshold_ms = max(1000, int(offline_min * 60 * 1000))
    while True:
        time.sleep(15)
        now = int(time.time() * 1000)
        raised = False
        for pid, rec in store.snapshot().items():

            if not rec.get("detected"):
                continue
            if now - rec["timestamp"] > threshold_ms:
                if alerts.raise_("offline", pid,
                                 "节点意外离线：超过 %g 分钟无检测数据" % offline_min):
                    raised = True
        if raised:
            bus.publish({"type": "alert"})

def main():
    ap = argparse.ArgumentParser(description="MFL_Web 后端")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--frontend", default=str(BASE_DIR.parent / "frontend"),
                    help="前端静态目录")
    ap.add_argument("--data", default=str(BASE_DIR.parent / "data" / "network.json"),
                    help="管网拓扑 JSON 路径")
    ap.add_argument("--captures-dir", default=str(BASE_DIR.parent / "data" / "captures"),
                    help="历史磁漏图像目录（命名 <point_id>_<seq>.<ext>）")
    ap.add_argument("--eventlog", default=str(BASE_DIR / "event_log.jsonl"),
                    help="事件日志路径；--no-eventlog 关闭落盘")
    ap.add_argument("--no-eventlog", action="store_true")
    ap.add_argument("--offline-minutes", type=float, default=10.0,
                    help="节点离线判定阈值（分钟）")

    ap.add_argument("--auto-online", action=argparse.BooleanOptionalAction, default=True,
                    help="启动后自动全节点依次上线（无需等检测结果）")
    ap.add_argument("--log-file", default=None, help="日志文件（缺省仅控制台）")
    args = ap.parse_args()

    handlers = [logging.StreamHandler()]
    if args.log_file:
        handlers.append(logging.FileHandler(args.log_file, encoding="utf-8"))
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s",
                        handlers=handlers)

    store, alerts, bus = StateStore(), Alerts(), SseBus()
    eventlog = EventLog(None if args.no_eventlog else args.eventlog)
    if eventlog.path:
        LOG.info("事件日志：%s（%d 条历史）", eventlog.path, len(eventlog))

    threading.Thread(target=offline_sweeper,
                     args=(store, alerts, bus, args.offline_minutes),
                     daemon=True).start()

    def auto_online():
        time.sleep(2.5)
        all_ids = sorted(network["points"], key=lambda p: p["id"])
        ids = [p["id"] for p in all_ids]
        batch = 60
        for i in range(0, len(ids), batch):
            store.mark_online(ids[i:i + batch])
            bus.publish({"type": "online"})
            time.sleep(0.12)
        LOG.info("自动上线完成：%d 个节点", len(ids))

    if args.auto_online:
        threading.Thread(target=auto_online, daemon=True).start()

    app = create_app(Path(args.frontend), Path(args.data), Path(args.captures_dir),
                     store, eventlog, alerts, bus, args.offline_minutes)
    LOG.info("监听 http://%s:%d （浏览器访问 http://<本机IP>:%d）", args.host, args.port, args.port)

    app.run(host=args.host, port=args.port, threaded=True, use_reloader=False)

if __name__ == "__main__":
    main()
