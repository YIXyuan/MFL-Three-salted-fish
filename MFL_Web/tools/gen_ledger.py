"""

"""

import argparse
import json
import random
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NET = json.loads((ROOT / "data" / "network.json").read_text(encoding="utf-8"))

MATERIALS = ["L245", "L360", "L415", "X52", "X60", "X65"]

def main():
    ap = argparse.ArgumentParser(description="生成管道台账虚拟数据")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--out", default=str(ROOT / "data" / "ledger.json"))
    args = ap.parse_args()
    rng = random.Random(args.seed)

    now = time.time()
    points = {}
    for p in NET["points"]:

        is_trunk = p["line"].startswith("T")
        age_years = rng.uniform(5, 12) if is_trunk else rng.uniform(2, 10)
        installed = now - age_years * 365.25 * 86400
        points[p["id"]] = {
            "installed_ms": int(installed * 1000),
            "age_years": round(age_years, 2),
            "wall_mm": round(rng.uniform(6.4, 12.7), 1),
            "material": rng.choice(MATERIALS),
            "last_pig_ms": int((now - rng.uniform(30, 400) * 86400) * 1000),
        }

    meta = {
        "note": "虚拟台账数据（演示用），生产日期不超过 12 年；年限图以 30 年为满刻度",
        "design_life_years": 30,
        "generated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "seed": args.seed,
        "count": len(points),
    }
    out = Path(args.out)
    out.write_text(json.dumps({"meta": meta, "points": points},
                              ensure_ascii=False, indent=1), encoding="utf-8")
    print("已生成 %s（%d 条台账记录）" % (out, len(points)))

if __name__ == "__main__":
    main()
