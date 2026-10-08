#!/usr/bin/env python3
"""批量添加公众号的驱动脚本（重构版：路径/凭据/节奏全部来自 config.env）。

第二轮重试起改为三段式:search(浏览器逐词搜索,不做匹配判断) → AI 选号(MiniMax,
复用 jobs 管线的配置,case-by-case 判断) → pick(浏览器按 AI 选定账号提交)。
固定 isMatch 词表匹配只保留在 add_company.js 的旧 add 模式里,本轮不再使用。
每家公司终态后追加一条独立轮次记录到 mp_match_ledger.json(去重/经验积累的唯一依据)。

用法: python3 process_chunk.py <slice.jsonl> <worker编号>
单次调用最多运行 WERSS_CHUNK_BUDGET 秒(默认300),处理完或超时即退出,输出进度行。
"""
import csv, datetime, json, os, random, re, subprocess, sys, time, urllib.parse, urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mp_retry_lib import merge_tried_cell, ledger_append_result, ledger_load, log_event

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

def abort(msg):
    """中止 chunk 并记事件;文本保持 ABORT:<msg> 格式,run_forever 靠它识别冷却类型"""
    log_event("abort", detail=msg[:300], worker=worker)
    say(f"ABORT:{msg}")

def wechat_auth_ok(timeout=12):
    """探测微信授权是否还有效(探测方式与 bin/keepalive.sh 的 weread 探针一致)。
    返回 True=有效 / False=已失效 / None=探测本身失败(网络/服务不可达)。

    为什么必须有这个探测(2026-10-04 事故):公众号搜索与微信读书共用同一套微信授权。
    授权失效后微信侧一律回 "invalid session 代码 200003",金丝雀在页面上只看到"空列表",
    与"真限流"完全同形。若不区分,授权失效就会被报成限流 → 冷却 40 分钟 → 人工不介入
    就永远自愈不了,实测连续 9 轮白转 7 小时、1124 家零进展。
    注意:keepalive 的提醒文案写的是"账号添加不受影响",该假设是错的,搜索同样依赖此授权。
    """
    base = APP_URL.rstrip("/")
    try:
        form = urllib.parse.urlencode({"username": ADMIN_USER, "password": ADMIN_PASS}).encode()
        req = urllib.request.Request(base + "/api/v1/wx/auth/login", data=form,
                                     headers={"Content-Type": "application/x-www-form-urlencoded"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            tok = json.loads(r.read().decode()).get("data", {}).get("access_token", "")
        if not tok:
            return False          # 管理端登不进去 = 后端/凭据故障,同样不是限流
        req2 = urllib.request.Request(base + "/api/v1/wx/weread/test", method="POST",
                                      headers={"Authorization": "Bearer " + tok})
        with urllib.request.urlopen(req2, timeout=timeout) as r:
            body = r.read().decode()
        return bool(re.search(r'true|有效|success|"code":\s*200', body, re.I))
    except Exception:
        return None

def canary_failure(canary, tag):
    """把金丝雀结果分类:返回 None=通过,否则返回中止原因。

    教训(2026-10-04 事故):旧代码一律按 canary.get("found",0)==0 报 search_throttled,
    但 JS_ERROR/CLI_ERROR 根本没有 found 字段,取默认值 0 也等于"限流"。一次 we-mp-rss
    数据库 disk I/O 故障(login 取用户失败)被伪装成限流,连续 9 轮各冷却 40 分钟,
    白转 7 小时、1124 家零进展。

    三类成因,处置完全不同,不能混:
      search_throttled —— 微信侧真限流,该长冷却退避;
      env_auth_expired  —— 微信授权失效,退避没有意义,必须人工扫码,长冷却只会掩盖;
      env_*             —— 本机环境故障(登录失败/数据库挂/页面结构变/ego 崩了),
                          5 分钟重试即可,关键是别再谎报成限流、别让日志指向错误方向。
    """
    st = canary.get("status", "CLI_ERROR")
    if st == "canary":
        if canary.get("found", 0) > 0:
            return None
        # found=0 有两种成因:微信授权失效(要人工扫码)与真限流(退避即可)。
        # 金丝雀在页面上只看到空列表,必须靠后端探测区分。
        auth = wechat_auth_ok()
        if auth is False:
            return ("env_auth_expired(%s金丝雀搜索0条,根因=微信授权失效(invalid session),"
                    "需人工扫码才能恢复,退避无效): 控制台.app 一键直达扫码页" % tag)
        if auth is None:
            # 探测不通时不能默认"就是限流"——那正是本次事故的成因,宁可承认不知道。
            return (f"env_broken({tag}金丝雀搜索0条,但微信授权状态探测失败,无法判定是否限流,"
                    "本轮未写任何台账)")
        return f"search_throttled({tag}金丝雀搜索0条,微信授权有效,判定真限流,本轮未写任何台账)"
    detail = str(canary.get("detail", ""))[:160]
    if "LOGIN_FAILED" in detail:
        return f"env_login_failed({tag}:we-mp-rss管理端登录失败,本轮未写任何台账): {detail}"
    return f"env_broken({tag}金丝雀执行异常,本轮未写任何台账): status={st} {detail}"

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
                r[i_n], r[i_t] = "", ""
                r[i_tr] = merge_tried_cell(r[i_tr], tried or [])
            elif status == "待复核":
                r[i_tr] = merge_tried_cell(r[i_tr], tried or [])
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

# ---- AI 选号(MiniMax,配置复用 jobs 管线) ----
PICK_SYS_PROMPT = (
    "你是公众号匹配审核员。给定一家公司的名称信息,以及在招聘RSS工具『添加公众号』"
    "搜索框中用若干关键词搜索得到的候选账号名列表。请判断哪个候选账号是该公司"
    "(或其母公司/所属集团)的招聘类公众号。招聘类包括:官方招聘号、人才招聘、人力资源、"
    "校园招聘等;单纯的企业官方号不算。若没有合适候选,pick 返回 null。"
    "只输出 JSON: {\"pick\": \"账号名或null\", \"reason\": \"一句话理由\"}"
)

def minimax_chat(system, user, timeout=60):
    body = {
        "model": os.environ.get("MINIMAX_MODEL") or "MiniMax-M3",
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "max_tokens": 3000,
        "temperature": 0.2,
    }
    req = urllib.request.Request(
        os.environ.get("MINIMAX_BASE_URL") or "https://api.minimaxi.com/v1/text/chatcompletion_v2",
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Authorization": "Bearer " + os.environ.get("MINIMAX_API_KEY", ""),
            "Content-Type": "application/json",
        },
        method="POST",
    )
    # runner 环境的 /usr/local/bin/python3 默认证书链会撞自签 CA,优先用 certifi 的 CA 包
    ctx = None
    try:
        import ssl, certifi
        ctx = ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        pass
    with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
        data = json.loads(r.read().decode("utf-8"))
    return data["choices"][0]["message"]["content"]

def extract_json(text):
    text = (text or "").strip()
    text = re.sub(r"^```(json)?|```$", "", text, flags=re.M).strip()
    try:
        return json.loads(text)
    except Exception:
        i, j = text.find("{"), text.rfind("}")
        if i >= 0 and j > i:
            return json.loads(text[i:j + 1])
        raise

def ai_pick(comp, opts_all):
    """AI 逐案选号。返回 {"pick": str|None, "reason": str};不可用返回 None(调用方整体中止)。"""
    lines = [f"公司全称: {comp.get('name', '')}", f"公司简称: {comp.get('short', '')}"]
    # 前几轮经验:历史轮次的 AI 理由一并给模型,避免重复误判
    rounds = ledger_load().get(comp["company_id"], {}).get("rounds", [])
    for rd in rounds:
        if rd.get("ai_reason"):
            lines.append(f"第{rd.get('round')}轮经验: {rd['ai_reason']}")
    for kw, opts in opts_all:
        lines.append(f"[{kw}] 候选: {' / '.join(opts) if opts else '(无结果)'}")
    prompt = "\n".join(lines)
    last_err = None
    for attempt in (1, 2):   # M3 是推理模型,偶发截断/网络抖动,重试一次再放弃
        try:
            verdict = extract_json(minimax_chat(PICK_SYS_PROMPT, prompt))
            if isinstance(verdict, dict) and "pick" in verdict:
                return verdict
            last_err = ValueError("模型输出缺少字段: %r" % (verdict,))
        except Exception as e:
            last_err = e
        time.sleep(5)
    say(f"  [AI判断异常x2: {str(last_err)[:120]}]")
    return None

# ---- 主循环 ----
start = time.time()
consec_notfound = 0
processed = 0
items = read_slice()

if not items:
    print("SLICE_DONE")
    sys.exit(0)
if not app_alive():
    abort("app_down")
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
_open_chunk_fail = canary_failure(canary, "开chunk")
if _open_chunk_fail:
    abort(_open_chunk_fail)
    sys.exit(1)
say(f"  [开chunk金丝雀通过({canary.get('found')}条)]")
log_event("canary", detail=f"开chunk金丝雀通过({canary.get('found')}条)", worker=worker)

lock = browser_lock()
while time.time() - start < BUDGET and items:
    comp = items[0]
    # 拿锁后操作浏览器(与其他 worker 串行,降低风控风险)
    while not acquire_browser_lock():
        abort("lock_timeout")
        sys.exit(1)

    # ---- 阶段1:search,浏览器逐词搜索,原样收集候选,不做匹配判断 ----
    try:
        res = run_js(comp, mode="search")
    finally:
        release_browser_lock()

    st = res.get("status", "CLI_ERROR")
    if st in ("CLI_ERROR", "JS_ERROR"):
        abort(f"{st.lower()} {res.get('detail','')[:120]}")
        sys.exit(1)
    if st != "searched":
        abort(f"unexpected_status {st}")
        sys.exit(1)

    per_kw = res.get("per_kw", [])
    tried = [p.get("kw", "") for p in per_kw]
    opts_all = [(p["kw"], p.get("opts") or []) for p in per_kw if p.get("opts")]
    ledger_per_kw = [{"kw": p.get("kw"), "opts": len(p.get("opts") or [])} for p in per_kw]

    # ---- 阶段2:AI 逐案选号 ----
    name, ai_pick_v, ai_reason, kw_hit = "", None, "", None
    if not opts_all:
        st = "not_found"
        ai_reason = "所有关键词均无搜索结果"
    else:
        ai = ai_pick(comp, opts_all)
        if ai is None:
            # AI 不可用属临时故障:不写任何台账,整体中止,稍后重试本家
            abort("ai_unavailable MiniMax 判断失败,本轮未写台账")
            sys.exit(1)
        ai_pick_v = ai.get("pick") or None
        ai_reason = (ai.get("reason") or "").strip()
        if ai_pick_v:
            kw_hit = next((kw for kw, opts in opts_all if ai_pick_v in opts), None)
            if kw_hit is None:
                ai_reason = (ai_reason + " [pick不在候选列表,按未找到处理]").strip()
                ai_pick_v = None
        if not ai_pick_v:
            st = "not_found"   # AI 明确无合适候选,按未找到终态处理(勿送待复核)

    # ---- 阶段3:pick,按 AI 选定账号重搜并提交 ----
    if ai_pick_v:
        while not acquire_browser_lock():
            abort("lock_timeout")
            sys.exit(1)
        try:
            res2 = run_js(dict(comp, pick_kw=kw_hit, pick_target=ai_pick_v), mode="pick")
        finally:
            release_browser_lock()
        st2 = res2.get("status", "CLI_ERROR")
        if st2 in ("CLI_ERROR", "JS_ERROR"):
            abort(f"{st2.lower()}(pick阶段) {res2.get('detail','')[:120]}")
            sys.exit(1)
        st = st2
        name = res2.get("name", "") if st2 == "added" else ""

    items.pop(0)
    processed += 1

    if st == "added":
        consec_notfound = 0
        update_csv(comp["company_id"], "已添加", name)
        say(f"{comp['company_id']}|已添加|{name}|AI:{ai_reason[:80]}")
    elif st == "not_found":
        consec_notfound += 1
        update_csv(comp["company_id"], "未找到", tried=tried)
        say(f"{comp['company_id']}|未找到|AI:{ai_reason[:100]}")
    else:  # submit_failed → 待复核
        update_csv(comp["company_id"], "待复核", tried=tried)
        say(f"{comp['company_id']}|待复核|{st}|AI:{ai_reason[:80]}")
        consec_notfound = 0

    # 每轮独立台账:终态即追加(含每词候选数与 AI 理由,供后续轮次去重与借鉴)
    ledger_append_result(comp["company_id"], {
        "round": comp.get("round", 2),
        "time": datetime.datetime.now().isoformat(timespec="seconds"),
        "kws": tried, "per_kw": ledger_per_kw,
        "ai_pick": ai_pick_v, "ai_reason": ai_reason,
        "result": st, "name": name,
    })

    # 结构化事件:供菜单栏「全量日志」窗口筛选展示
    ev_type = {"added": "added", "not_found": "not_found"}.get(st, "pending_review")
    log_event(ev_type, detail=(ai_reason or st)[:300], company_id=comp["company_id"],
              company_name=comp.get("name"), mp_name=name or None,
              round=comp.get("round"), worker=worker, kws=";".join(tried) or None)

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
        _retry_fail = canary_failure(canary, f"金丝雀[{canary_kw}]")
        if _retry_fail:
            abort(_retry_fail)
            sys.exit(1)
        say(f"  [金丝雀 {canary_kw} 通过({canary.get('found')}条),继续]")
        log_event("canary", detail=f"连击金丝雀[{canary_kw}]通过({canary.get('found')}条)", worker=worker)
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
    log_event("chunk", detail=f"chunk完成 processed={processed} 剩余={len(items)}", worker=worker)
    print(f"CHUNK_DONE processed={processed} remaining={len(items)}")
else:
    log_event("chunk", detail=f"slice全部完成 processed={processed}", worker=worker)
    print(f"SLICE_DONE processed={processed}")
