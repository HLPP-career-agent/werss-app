#!/usr/bin/env python3
"""批量添加公众号的驱动脚本（重构版：路径/凭据/节奏全部来自 config.env）。

用法: python3 process_chunk.py <slice.jsonl> <worker编号>
单次调用最多运行 WERSS_CHUNK_BUDGET 秒(默认300),处理完或超时即退出,输出进度行。
"""
import csv, datetime, json, os, random, subprocess, sys, time, urllib.request

WORK = os.environ.get("WERSS_ROOT", os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
BATCH = os.path.join(WORK, "batch")
CSV_PATH = os.environ.get("WERSS_CSV", os.path.join(WORK, "companies.csv"))
APP_URL = os.environ.get("WERSS_APP_URL", "http://localhost:8001/")
ADMIN_USER = os.environ.get("WERSS_ADMIN_USER", "admin")
ADMIN_PASS = os.environ.get("WERSS_ADMIN_PASS", "admin@123")
JS_PATH = os.path.join(BATCH, "add_company.js")
slice_path = sys.argv[1]
worker = sys.argv[2] if len(sys.argv) > 2 else "1"
SPACE_NAME = f"werss-batch-{worker}"
SPACE_FILE = os.path.join(BATCH, f"space_{worker}.id")
LOCK_FILE = os.path.join(BATCH, "browser.lock")
LOG = open(os.path.join(BATCH, f"log_{worker}.txt"), "a")
BUDGET = int(os.environ.get("WERSS_CHUNK_BUDGET", "300"))
GAP_MIN = float(os.environ.get("WERSS_GAP_MIN", "45"))
GAP_MAX = float(os.environ.get("WERSS_GAP_MAX", "90"))
REST_EVERY_MIN = int(os.environ.get("WERSS_REST_EVERY_MIN", "3"))
REST_EVERY_MAX = int(os.environ.get("WERSS_REST_EVERY_MAX", "5"))
REST_MIN = float(os.environ.get("WERSS_REST_MIN", "120"))
REST_MAX = float(os.environ.get("WERSS_REST_MAX", "300"))
CANARY_THRESHOLD = int(os.environ.get("WERSS_CANARY_THRESHOLD", "5"))
JS = open(JS_PATH).read()

def say(msg):
    print(msg)
    LOG.write(f"{datetime.datetime.now():%H:%M:%S} {msg}\n")
    LOG.flush()

def app_alive():
    try:
        with urllib.request.urlopen(APP_URL, timeout=5) as r:
            return r.status == 200
    except Exception:
        return False

def run_js(company, mode="add"):
    js = (JS
          .replace("__COMPANY__", json.dumps(company, ensure_ascii=False))
          .replace("__MODE__", mode)
          .replace("__SPACE_FILE__", SPACE_FILE)
          .replace("__SPACE_NAME__", SPACE_NAME)
          .replace("__APP_URL__", APP_URL)
          .replace("__ADMIN_USER__", ADMIN_USER)
          .replace("__ADMIN_PASS__", ADMIN_PASS)
          .replace("__T2S_FILE__", os.path.join(BATCH, "t2s_map.json")))
    try:
        r = subprocess.run(["ego-browser", "nodejs"], input=js, capture_output=True,
                           text=True, timeout=200)
        out = (r.stdout or "") + (r.stderr or "")
        for line in out.splitlines():
            if line.startswith("RESULT:"):
                return json.loads(line[7:])
        return {"status": "CLI_ERROR", "detail": out[-200:]}
    except Exception as e:
        return {"status": "CLI_ERROR", "detail": str(e)[:200]}

def update_csv(company_id, status, mp_name="", tried=None):
    with open(CSV_PATH, newline="", encoding="utf-8-sig") as f:
        rows = list(csv.reader(f))
    header = rows[0]
    i_id = header.index("company_id")
    i_n, i_t = header.index("wx_mp_name"), header.index("wx_mp_added_at")
    i_s, i_tr = header.index("wx_mp_status"), header.index("wx_mp_tried_names")
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    for r in rows[1:]:
        if r and r[i_id].strip() == company_id:
            while len(r) < len(header):
                r.append("")
            r[i_s] = status
            if status == "已添加":
                r[i_n], r[i_t], r[i_tr] = mp_name, now, ""
            elif status == "未找到":
                r[i_n], r[i_t], r[i_tr] = "", "", "尝试:" + ";".join(tried or [])
    with open(CSV_PATH, "w", newline="", encoding="utf-8-sig") as f:
        csv.writer(f).writerows(rows)

def read_slice():
    with open(slice_path, encoding="utf-8") as f:
        return [json.loads(l) for l in f if l.strip()]

def write_slice(items):
    with open(slice_path, "w", encoding="utf-8") as f:
        for it in items:
            f.write(json.dumps(it, ensure_ascii=False) + "\n")

LOCK_DIR = LOCK_FILE + ".d"

def browser_lock():
    return open(LOCK_FILE, "w")

def acquire_browser_lock(timeout=180):
    import os as _os
    t0 = time.time()
    while True:
        try:
            _os.mkdir(LOCK_DIR)
            return True
        except FileExistsError:
            # 超过10分钟的锁视为死锁残留
            try:
                if time.time() - _os.stat(LOCK_DIR).st_mtime > 600:
                    _os.rmdir(LOCK_DIR)
                    continue
            except Exception:
                pass
            if time.time() - t0 > timeout:
                return False
            time.sleep(2)

def release_browser_lock():
    try:
        import os as _os
        _os.rmdir(LOCK_DIR)
    except Exception:
        pass

def next_canary_kw():
    """从关键词池轮换取金丝雀词,每次都用没搜过的新词,避免缓存假阳性"""
    pool = json.load(open(os.path.join(BATCH, "canary_pool.json"), encoding="utf-8"))
    idx_f = os.path.join(BATCH, "canary_idx")
    idx = int(open(idx_f).read().strip() or 0) % len(pool)
    open(idx_f, "w").write(str(idx + 1))
    return pool[idx]

# ---- 主循环 ----
start = time.time()
consec_notfound = 0
processed = 0
items = read_slice()

if not items:
    print("SLICE_DONE")
    sys.exit(0)
if not app_alive():
    print("ABORT:app_down")
    sys.exit(1)

# 开 chunk 先金丝雀探测搜索可用性（教训：微信主授权 session 静默失效时，搜索全部返回
# "未找到"，而 chunk 只处理 3-4 家就被 runner 重启、循环内"连续 N 次未找到"阈值永远
# 够不着，导致 598 家被误标未找到。探测必须在写任何台账之前做）。
# 注：add_company.js 的 canary 模式固定搜"平安银行"，注入的关键词仅作日志展示。
canary_kw = next_canary_kw()
acquire_browser_lock()
try:
    canary = run_js({"company_id": "canary", "short": canary_kw,
                     "name": canary_kw + "股份有限公司"}, mode="canary")
finally:
    release_browser_lock()
if canary.get("found", 0) == 0:
    say(f"ABORT:search_throttled(开chunk金丝雀搜索失败,微信授权/搜索不可用,本轮未写任何台账)")
    sys.exit(1)
say(f"  [开chunk金丝雀通过({canary.get('found')}条)]")

lock = browser_lock()
while time.time() - start < BUDGET and items:
    comp = items[0]
    # 拿锁后操作浏览器(与其他 worker 串行,降低风控风险)
    while not acquire_browser_lock():
        say("ABORT:lock_timeout")
        sys.exit(1)
    try:
        res = run_js(comp, mode="add")
    finally:
        release_browser_lock()

    st = res.get("status", "CLI_ERROR")
    if st == "CLI_ERROR":
        say(f"ABORT:cli_error {res.get('detail','')[:120]}")
        sys.exit(1)
    if st == "JS_ERROR":
        say(f"ABORT:js_error {res.get('detail','')[:120]}")
        sys.exit(1)

    items.pop(0)
    processed += 1
    tried = res.get("tried", [])

    if st == "added":
        consec_notfound = 0
        update_csv(comp["company_id"], "已添加", res.get("name", ""))
        say(f"{comp['company_id']}|已添加|{res.get('name','')}")
    elif st == "not_found":
        consec_notfound += 1
        now = datetime.datetime.now().strftime("%H:%M")
        update_csv(comp["company_id"], "未找到", tried=[f"{now}尝试:{t}" for t in tried])
        say(f"{comp['company_id']}|未找到|尝试:{';'.join(tried)}")
    else:  # submit_failed 等
        update_csv(comp["company_id"], "待复核", tried=tried)
        say(f"{comp['company_id']}|待复核|{st}")
        consec_notfound = 0

    write_slice(items)

    # 风控探测:连续 N 个未找到立即做金丝雀测试;失败即中止(宁停勿错)
    if consec_notfound >= CANARY_THRESHOLD:
        canary_kw = next_canary_kw()
        acquire_browser_lock()
        try:
            canary = run_js({"company_id": "canary", "short": canary_kw,
                             "name": canary_kw + "股份有限公司"}, mode="canary")
        finally:
            release_browser_lock()
        if canary.get("found", 0) == 0:
            say(f"ABORT:search_throttled(金丝雀[{canary_kw}]搜索失败,本次未写入任何误判)")
            sys.exit(1)
        say(f"  [金丝雀 {canary_kw} 通过({canary.get('found')}条),继续]")
        consec_notfound = 0
        continue

    # 随机节奏:公司间隔 GAP_MIN-GAP_MAX 秒;每 REST_EVERY 家随机休息 REST_MIN-MAX 秒
    time.sleep(random.uniform(GAP_MIN, GAP_MAX))
    if processed % random.randint(REST_EVERY_MIN, REST_EVERY_MAX) == 0:
        pause = random.uniform(REST_MIN, REST_MAX)
        say(f"  [worker{worker} 随机休息 {int(pause)}s]")
        time.sleep(pause)

write_slice(items)
if items:
    print(f"CHUNK_DONE processed={processed} remaining={len(items)}")
else:
    print(f"SLICE_DONE processed={processed}")
