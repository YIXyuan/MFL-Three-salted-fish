"""

"""

import argparse
import datetime
import json
import math
from pathlib import Path

POINT_SPACING = 200.0
SCALE = 1.0
VALVE_EVERY_M = 10000.0
VALVE_MIN_GAP_M = 3000.0

LINES = [
    {"id": "T1", "name": "北干线", "type": "trunk",
     "waypoints": [[-75000, 28000], [-55000, 30000], [-35000, 27000], [-15000, 29000]]},
    {"id": "T2", "name": "中干线", "type": "trunk",
     "waypoints": [[-15000, 2000], [5000, 4000], [25000, 1000], [45000, 3000]]},
    {"id": "T3", "name": "南干线", "type": "trunk",
     "waypoints": [[-40000, -30000], [-20000, -28000], [0, -31000], [20000, -29000]]},
    {"id": "C1", "name": "红中联络线", "type": "link",
     "waypoints": [[-35000, 27000], [-28000, 14000], [-15000, 2000]]},
    {"id": "C2", "name": "青东联络线", "type": "link",
     "waypoints": [[25000, 1000], [26000, -14000], [20000, -29000]]},
    {"id": "B1", "name": "红崖支线", "type": "branch",
     "waypoints": [[-15000, 29000], [8000, 34000]]},
    {"id": "B2", "name": "青河支线", "type": "branch",
     "waypoints": [[25000, 1000], [44000, -11000]]},
    {"id": "B3", "name": "东湖支线", "type": "branch",
     "waypoints": [[20000, -29000], [41000, -23000]]},
    {"id": "B4", "name": "城西支线", "type": "branch",
     "waypoints": [[-55000, 30000], [-60000, 37000], [-68000, 43000]]},
    {"id": "B5", "name": "南园支线", "type": "branch",
     "waypoints": [[-20000, -28000], [-28000, -36000], [-34000, -42000]]},
    {"id": "B6", "name": "东林支线", "type": "branch",
     "waypoints": [[-28000, 14000], [-9000, 12500]]},
]

STATIONS = [
    {"id": "S01", "name": "西梁首站",   "type": "首站",   "line": "T1", "at": "start"},
    {"id": "S02", "name": "柳沟泵站",   "type": "泵站",   "line": "T1", "mileage": 20000},
    {"id": "S03", "name": "白家窑泵站", "type": "泵站",   "line": "T1", "mileage": 40000},
    {"id": "S04", "name": "红崖分输站", "type": "分输站", "line": "T1", "at": "end"},
    {"id": "S05", "name": "沙坨储备库", "type": "储备库", "line": "B1", "at": "end"},
    {"id": "S06", "name": "中堡泵站",   "type": "泵站",   "line": "T2", "mileage": 20000},
    {"id": "S07", "name": "青河分输站", "type": "分输站", "line": "T2", "wp": 2},
    {"id": "S08", "name": "东滩末站",   "type": "末站",   "line": "T2", "at": "end"},
    {"id": "S09", "name": "青河炼厂",   "type": "炼厂",   "line": "B2", "at": "end"},
    {"id": "S10", "name": "南川首站",   "type": "首站",   "line": "T3", "at": "start"},
    {"id": "S11", "name": "南川泵站",   "type": "泵站",   "line": "T3", "mileage": 20000},
    {"id": "S12", "name": "东湖末站",   "type": "末站",   "line": "B3", "at": "end"},
    {"id": "S13", "name": "红崖口联络阀室", "type": "联络阀室", "line": "T1", "wp": 2},
    {"id": "S14", "name": "中堡西联络阀室", "type": "联络阀室", "line": "T2", "wp": 0},
    {"id": "S15", "name": "东湖口联络阀室", "type": "联络阀室", "line": "T3", "wp": 3},
    {"id": "S16", "name": "柳沟东联络阀室", "type": "联络阀室", "line": "T1", "wp": 1},
    {"id": "S17", "name": "南川西联络阀室", "type": "联络阀室", "line": "T3", "wp": 1},
    {"id": "S18", "name": "中湖联络阀室",   "type": "联络阀室", "line": "C1", "wp": 1},
    {"id": "S19", "name": "城西门站",   "type": "门站",   "line": "B4", "at": "end"},
    {"id": "S20", "name": "化工园末站", "type": "末站",   "line": "B5", "at": "end"},
    {"id": "S21", "name": "东林储配库", "type": "储配库", "line": "B6", "at": "end"},
]

def polyline_length(wps):
    total = 0.0
    for (x1, y1), (x2, y2) in zip(wps, wps[1:]):
        total += math.hypot(x2 - x1, y2 - y1)
    return total

def point_at(wps, mileage):

    remain = mileage
    for i, ((x1, y1), (x2, y2)) in enumerate(zip(wps, wps[1:])):
        seg = math.hypot(x2 - x1, y2 - y1)
        if remain <= seg or i == len(wps) - 2:
            t = 0.0 if seg == 0 else min(1.0, remain / seg)
            return [x1 + (x2 - x1) * t, y1 + (y2 - y1) * t], i
        remain -= seg
    return wps[-1], len(wps) - 2

def build(scale):
    lines_out, points_out, stations_out = [], [], []
    pid = 0
    bounds = {"min_x": 1e18, "max_x": -1e18, "min_y": 1e18, "max_y": -1e18}

    def expand(x, y):
        bounds["min_x"] = min(bounds["min_x"], x)
        bounds["max_x"] = max(bounds["max_x"], x)
        bounds["min_y"] = min(bounds["min_y"], y)
        bounds["max_y"] = max(bounds["max_y"], y)

    wps_by_line = {}
    for line in LINES:
        wps = [[x * scale, y * scale] for x, y in line["waypoints"]]
        wps_by_line[line["id"]] = wps
        length = polyline_length(wps)
        n = int(round(length / POINT_SPACING)) + 1
        for k in range(n):
            m = min(k * POINT_SPACING, length)
            [x, y], _ = point_at(wps, m)
            pid += 1
            points_out.append({"id": "P%04d" % pid, "line": line["id"],
                               "mileage": round(m, 1),
                               "x": round(x, 1), "y": round(y, 1)})
            expand(x, y)
        lines_out.append({"id": line["id"], "name": line["name"], "type": line["type"],
                          "waypoints": wps, "length_m": round(length, 1),
                          "point_count": n})

    for st in STATIONS:
        wps = wps_by_line[st["line"]]
        length = polyline_length(wps)
        if "wp" in st:
            mileage = sum(math.hypot(x2 - x1, y2 - y1)
                          for (x1, y1), (x2, y2) in zip(wps[:st["wp"] + 1], wps[1:st["wp"] + 2]))
            x, y = wps[st["wp"]]
        else:
            mileage = st.get("mileage", 0.0)
            if st.get("at") == "end":
                mileage = length
            [x, y], _ = point_at(wps, mileage)
        stations_out.append({"id": st["id"], "name": st["name"], "type": st["type"],
                             "line": st["line"], "mileage": round(mileage, 1),
                             "x": round(x, 1), "y": round(y, 1)})
        expand(x, y)

    for line in LINES:
        wps = wps_by_line[line["id"]]
        length = polyline_length(wps)
        same_line = [s for s in stations_out if s["line"] == line["id"]]
        m, vi = VALVE_EVERY_M, 1
        while m < length - VALVE_EVERY_M * 0.5:
            if all(abs(m - s["mileage"]) >= VALVE_MIN_GAP_M for s in same_line):
                [x, y], _ = point_at(wps, m)
                stations_out.append({"id": "%s-V%02d" % (line["id"], vi),
                                     "name": "%s%d号阀室" % (line["name"], vi),
                                     "type": "阀室", "line": line["id"],
                                     "mileage": round(m, 1),
                                     "x": round(x, 1), "y": round(y, 1)})
                vi += 1
            m += VALVE_EVERY_M

    stations_out.sort(key=lambda s: s["id"])
    meta = {
        "name": "某省级输油管网监测辖区（虚构演示数据）",
        "point_spacing_m": POINT_SPACING,
        "scale": scale,
        "total_length_m": round(sum(l["length_m"] for l in lines_out), 1),
        "point_count": len(points_out),
        "station_count": len(stations_out),
        "bounds": {k: round(v, 1) for k, v in bounds.items()},
        "generated_at": datetime.datetime.now().isoformat(timespec="seconds"),
    }
    return {"meta": meta, "lines": lines_out, "stations": stations_out, "points": points_out}

def main():
    global SCALE
    ap = argparse.ArgumentParser(description="生成虚构输油管网拓扑")
    ap.add_argument("--scale", type=float, default=SCALE, help="整体缩放系数")
    ap.add_argument("-o", "--output", default=str(Path(__file__).resolve().parent.parent / "data" / "network.json"))
    args = ap.parse_args()

    net = build(args.scale)
    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(net, ensure_ascii=False, indent=1), encoding="utf-8")

    m = net["meta"]
    span_x = (m["bounds"]["max_x"] - m["bounds"]["min_x"]) / 1000
    span_y = (m["bounds"]["max_y"] - m["bounds"]["min_y"]) / 1000
    print("已生成 %s" % out)
    print("  管线 %d 条，总长 %.1f km；监测点 %d 个（间距 %.0f m）；站场 %d 座"
          % (len(net["lines"]), m["total_length_m"] / 1000, m["point_count"], POINT_SPACING, m["station_count"]))
    print("  辖区范围约 %.0f km x %.0f km" % (span_x, span_y))

if __name__ == "__main__":
    main()
