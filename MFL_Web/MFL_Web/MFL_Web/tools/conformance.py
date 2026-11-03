"""

"""

import argparse
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GO_EXE = ROOT / "backend" / "go" / "bin" / ("mflweb.exe" if os.name == "nt" else "mflweb")
APP_PY = ROOT / "backend" / "app.py"
PYLIBS = ROOT / "backend" / "pylibs"

VOLATILE_KEYS = {"server_time", "time", "timestamp", "uptime_s",
                 "last_event_age_s", "started_at_ms"}

def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]

def request(base, method, path, body=None, raw_body=None):
    data = raw_body if raw_body is not None else (
        json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            payload = resp.read().decode("utf-8", "replace")
            try:
                return resp.status, json.loads(payload)
            except ValueError:
                return resp.status, payload
    except urllib.error.HTTPError as e:
        payload = e.read().decode("utf-8", "replace")
        try:
            return e.code, json.loads(payload)
        except ValueError:
            return e.code, payload

def normalize(x):
    if isinstance(x, dict):
        return {k: ("<ts>" if k in VOLATILE_KEYS else normalize(v)) for k, v in x.items()}
    if isinstance(x, list):
        return [normalize(v) for v in x]
    return x

def wait_health(base, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(base + "/api/health", timeout=2) as r:
                if r.status == 200:
                    return True
        except Exception:
            time.sleep(0.3)
    return False

def _popen_logged(cmd, env=None):
    return subprocess.Popen(cmd, cwd=str(ROOT), env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, encoding="utf-8", errors="replace")

def start_flask(port, eventlog):
    env = dict(os.environ)
    if PYLIBS.is_dir():
        env["PYTHONPATH"] = str(PYLIBS) + os.pathsep + env.get("PYTHONPATH", "")
    return _popen_logged(
        [sys.executable, str(APP_PY), "--port", str(port), "--no-auto-online",
         "--eventlog", str(eventlog)], env=env)

def start_go(port, eventlog):

    return _popen_logged(
        [str(GO_EXE), "--port", str(port), "--auto-online=false",
         "--eventlog", str(eventlog)])

def run_sequence(base):

    out = {}

    def case(name, method, path, body=None, raw_body=None):
        st, j = request(base, method, path, body, raw_body)
        out[name] = (st, normalize(j) if not isinstance(j, str) else j)

    case("health0", "GET", "/api/health")

    case("nodes_online", "POST", "/api/nodes/online",
         {"items": ["P0010", "P0011", "P9999"]})
    case("nodes_online_bad", "POST", "/api/nodes/online", {"items": []})

    case("progress_set", "POST", "/api/progress", {"sweep": 2, "total": 6})
    case("progress_get", "GET", "/api/progress")
    case("progress_bad", "POST", "/api/progress", {"sweep": 0})
    case("batch", "POST", "/api/detections",
         {"items": [{"point_id": "P0001", "severity": 0},
                    {"point_id": "P0002", "severity": 2},
                    {"point_id": "P0003", "severity": 2},
                    {"point_id": "P0003", "severity": 1},
                    {"point_id": "P0003", "severity": 2},
                    {"point_id": "P0001", "severity": 1}]})
    case("invalid", "POST", "/api/detections",
         {"items": [{"point_id": "P9999", "severity": 0},
                    {"point_id": "P0002", "severity": 5},
                    {},
                    {"point_id": "P0004", "severity": True},
                    {"point_id": "P0004", "severity": 1.5}]})
    case("single", "POST", "/api/detections", {"point_id": "P0005", "severity": 2})
    case("bare_array", "POST", "/api/detections", [{"point_id": "P0006", "severity": 1}])
    case("garbage", "POST", "/api/detections", raw_body=b"not json")
    case("state", "GET", "/api/state")
    case("alerts1", "GET", "/api/alerts")
    case("status_ok", "POST", "/api/alerts/1/status", {"status": "处理中"})
    case("status_bad", "POST", "/api/alerts/1/status", {"status": "bad"})
    case("status_404", "POST", "/api/alerts/999/status", {"status": "处理中"})
    case("alerts2", "GET", "/api/alerts")
    case("coverage", "GET", "/api/stats/coverage")
    case("top_severe", "GET", "/api/stats/top_severe")
    case("volatility", "GET", "/api/stats/volatility")
    case("trend", "GET", "/api/stats/point_trend/P0003")
    if isinstance(out.get("trend", (0, 0))[1], dict):
        tj = out["trend"][1]
        tj["series"] = [["<ts>", v] for _, v in tj.get("series", [])]
    case("trend_404", "GET", "/api/stats/point_trend/P9999")
    case("system", "GET", "/api/system")
    case("captures0", "GET", "/api/points/P0001/captures")
    case("captures_bad", "GET", "/captures/..%2Fetc%2Fpasswd")
    case("static_404", "GET", "/nope.js")

    try:
        with urllib.request.urlopen(base + "/", timeout=5) as r:
            html = r.read().decode("utf-8", "replace")
            out["index"] = (r.status, "管道漏磁腐蚀监测中心" in html)
    except Exception as e:
        out["index"] = (None, str(e))

    try:
        with urllib.request.urlopen(base + "/api/events", timeout=4) as r:
            chunk = ""
            for _ in range(6):
                chunk += r.readline().decode("utf-8", "replace")
                if "hello" in chunk:
                    break
            out["sse_hello"] = (r.status, "retry: 3000" in chunk and "hello" in chunk)
    except Exception as e:
        out["sse_hello"] = (None, str(e))

    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip-flask", action="store_true", help="只测 Go")
    args = ap.parse_args()

    if not GO_EXE.exists():
        sys.exit("Go 产物不存在：%s（先运行 backend/go/build.sh）" % GO_EXE)

    tmp = Path(tempfile.mkdtemp(prefix="mfl_conf_"))
    go_port, flask_port = free_port(), free_port()
    go_url = "http://127.0.0.1:%d" % go_port
    procs = [start_go(go_port, tmp / "go.jsonl")]

    flask_url = None
    if not args.skip_flask:
        flask_url = "http://127.0.0.1:%d" % flask_port
        procs.append(start_flask(flask_port, tmp / "flask.jsonl"))

    try:
        if not wait_health(go_url):
            print("---- 失败进程输出 ----")
            print(procs[0].communicate(timeout=5)[0][-1500:] or "<无输出>")
            sys.exit("Go 后端未就绪")
        if flask_url and not wait_health(flask_url):
            print("---- 失败进程输出 ----")
            print(procs[1].communicate(timeout=5)[0][-1500:] or "<无输出>")
            sys.exit("Flask 后端未就绪")

        go_res = run_sequence(go_url)
        flask_res = run_sequence(flask_url) if flask_url else None

        print("%-14s %-10s %-10s 判定" % ("用例", "Go", "Flask" if flask_res else "-"))
        fails = 0
        for name, (gst, gj) in go_res.items():
            if flask_res is None:
                print("%-14s %-10s -          (仅测 Go)" % (name, gst))
                continue
            fst, fj = flask_res.get(name, (None, None))
            ok = (gst == fst)
            if not isinstance(gj, str) and not isinstance(fj, str):
                ok = ok and (gj == fj)
            fails += 0 if ok else 1
            mark = "PASS" if ok else "FAIL"
            print("%-14s %-10s %-10s %s" % (name, gst, fst, mark))
            if not ok:
                print("   Go   :", json.dumps(gj, ensure_ascii=False)[:260])
                print("   Flask:", json.dumps(fj, ensure_ascii=False)[:260])
        print()
        if flask_res is None:
            print("结论：Go 后端 %d 个用例执行完毕（未比对 Flask）" % len(go_res))
        else:
            print("结论：%s（%d 个用例，%d 个不一致）"
                  % ("全部一致 ✓" if fails == 0 else "存在不一致 ✗", len(go_res), fails))
        sys.exit(0 if fails == 0 else 1)
    finally:
        for p in procs:
            try:
                p.terminate()
            except Exception:
                pass

if __name__ == "__main__":
    main()
