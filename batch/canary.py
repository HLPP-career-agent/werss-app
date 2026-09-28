#!/usr/bin/env python3
"""独立金丝雀测试:从轮换池取一个新词搜索,输出 found 数量。只搜索,不添加,不写 CSV。"""
import json, os, subprocess, sys

WORK = os.environ.get("WERSS_ROOT", os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
BATCH = os.path.join(WORK, "batch")
ADMIN_USER = os.environ.get("WERSS_ADMIN_USER", "admin")
ADMIN_PASS = os.environ.get("WERSS_ADMIN_PASS", "admin@123")
APP_URL = os.environ.get("WERSS_APP_URL", "http://localhost:8001/")
JS = open(os.path.join(BATCH, "add_company.js")).read()

pool = json.load(open(os.path.join(BATCH, "canary_pool.json"), encoding="utf-8"))
idx_f = os.path.join(BATCH, "canary_idx")
idx = int(open(idx_f).read().strip() or 0) % len(pool)
open(idx_f, "w").write(str(idx + 1))
kw = pool[idx]

js = (JS.replace("__COMPANY__", json.dumps({"company_id": "canary", "short": kw,
                                            "name": kw + "股份有限公司"}, ensure_ascii=False))
        .replace("__MODE__", "canary")
        .replace("__SPACE_FILE__", os.path.join(BATCH, "space_canary.id"))
        .replace("__SPACE_NAME__", "werss-canary")
        .replace("__APP_URL__", APP_URL)
        .replace("__ADMIN_USER__", ADMIN_USER)
        .replace("__ADMIN_PASS__", ADMIN_PASS)
        .replace("__T2S_FILE__", os.path.join(BATCH, "t2s_map.json")))
r = subprocess.run(["ego-browser", "nodejs"], input=js, capture_output=True, text=True, timeout=120)
out = (r.stdout or "") + (r.stderr or "")
found = -1
for line in out.splitlines():
    if line.startswith("RESULT:"):
        found = json.loads(line[7:]).get("found", -1)
        break
print(f"CANARY kw={kw} found={found}")
sys.exit(0 if found > 0 else 1)
