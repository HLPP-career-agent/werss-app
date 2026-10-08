#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
jobs.py —— 招聘帖审查与发布（werss-app）

流水线：
  1. 规则粗筛（保召回）：订阅号名含「招聘」的号全部文章 + 标题命中关键词的文章
  2. MiniMax 模型精判（消噪）：区分真招聘帖与团建/节日/企业宣传等，并抽取届别/类型/主体
  3. 状态库 data/jobs_review.json：待审 / 已发布 / 已忽略，防重复发布
  4. 发布：POST 到 JOBS_PUBLISH_URL（未配置则仅本地标记）

子命令：
  scan [--limit N] [--quiet]   扫描新候选并模型精判（keepalive 每 30 分钟跑一次）
  list [--status S] --json      供菜单栏审核窗口读取
  stats                        key=value 计数（供菜单栏角标）
  seen                         把当前待审数记为「已看过」（清菜单角标）
  publish <id>                 发布一帖（调接口 + 标记状态）
  skip <id>                    忽略一帖
  undo <id>                    恢复为待审

状态文件在 data/ 内，随备份包交接，发布记录不丢。
"""
import argparse
import concurrent.futures
import datetime as dt
import fcntl
import html as html_mod
import json
import os
import re
import sqlite3
import sys
import urllib.error
import urllib.request
from urllib.parse import urlparse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG_FILE = os.path.join(ROOT, "config.env")
DB_FILE = os.path.join(ROOT, "data", "db.db")
STATE_FILE = os.path.join(ROOT, "data", "jobs_review.json")
LOCK_FILE = os.path.join(ROOT, "data", "jobs_review.lock")

# 规则②关键词（规则①=订阅号名含「招聘」）
KEYWORDS = ["招聘", "秋招", "校招", "社招", "内推", "实习", "招贤", "纳士", "网申", "双选会", "宣讲会"]

SYS_PROMPT = """你是一个微信公众号文章分类器，任务是把文章判定为"招聘相关"或"非招聘"，并抽取关键信息。

判定标准：
- 招聘相关（is_recruitment=true）：校园招聘（秋招/春招/补录）、社会招聘、实习生/管培生招募、内推、人才引进、宣讲会/双选会/空中宣讲通知、招聘流程公告（笔试通知/面试名单/录用公示）。
- 非招聘（is_recruitment=false）：团建活动、节日祝福、企业新闻/产品发布、领导来访/参观交流、员工培训纪实/内部活动、企业文化宣传、行业资讯、声明等一切与招聘求职无关的内容。

拿不准时判 true 并在 reason 里说明存疑（后续有人工复核，漏报代价大于误报）。
只输出一个 JSON 对象，不要输出任何其他文字，字段如下：
{"is_recruitment": true或false, "type": "校招|社招|实习|内推|宣讲会|流程公告|其他招聘|非招聘", "session_year": 届别年份整数或null, "company": "招聘主体公司名", "positions": "岗位方向简述或null", "reason": "一句话依据"}"""


# ---------------- 配置 ----------------

def load_cfg():
    """解析 config.env（支持 ${VAR:-默认} 展开）"""
    cfg = {}
    if not os.path.exists(CONFIG_FILE):
        return cfg
    with open(CONFIG_FILE, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
            if not m:
                continue
            k, v = m.group(1), m.group(2).strip()

            def repl(mm):
                var, default = mm.group(1), mm.group(2)
                return os.environ.get(var) or default or ""

            v = re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}", repl, v)
            v = v.strip().strip('"').strip("'")
            cfg[k] = v
    return cfg


# ---------------- 状态库（带文件锁，防菜单栏操作与保活扫描并发写） ----------------

class StateLock:
    def __init__(self):
        self.fh = None

    def __enter__(self):
        os.makedirs(os.path.dirname(LOCK_FILE), exist_ok=True)
        self.fh = open(LOCK_FILE, "w")
        fcntl.flock(self.fh, fcntl.LOCK_EX)
        return self

    def __exit__(self, *a):
        fcntl.flock(self.fh, fcntl.LOCK_UN)
        self.fh.close()


def load_state():
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, encoding="utf-8") as f:
                s = json.load(f)
            if isinstance(s.get("items"), dict):
                return s
        except Exception:
            pass
    return {"version": 1, "seen_pending": 0, "last_scan": "", "items": {}}


def save_state(state):
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=1)
    os.replace(tmp, STATE_FILE)


# ---------------- 候选查询 ----------------

def fetch_candidates():
    """规则粗筛：招聘号全收 + 标题关键词。返回按发现时间倒序的行。"""
    if not os.path.exists(DB_FILE):
        print("数据库不存在: %s" % DB_FILE, file=sys.stderr)
        return []
    kw_like = " OR ".join(["a.title LIKE ?"] * len(KEYWORDS))
    sql = """
        SELECT a.id, a.mp_id, IFNULL(f.mp_name,''), a.title, IFNULL(a.url,''),
               IFNULL(a.publish_time,0), IFNULL(a.description,''),
               IFNULL(a.content,'')
        FROM articles a LEFT JOIN feeds f ON f.id = a.mp_id
        WHERE f.mp_name LIKE '%%招聘%%' OR (%s)
        ORDER BY a.publish_time DESC
    """ % kw_like
    args = tuple("%" + k + "%" for k in KEYWORDS)
    db = sqlite3.connect("file:%s?mode=ro" % DB_FILE, uri=True)
    try:
        return db.execute(sql, args).fetchall()
    finally:
        db.close()


def strip_html(s, limit):
    s = re.sub(r"<[^>]+>", " ", s or "")
    s = html_mod.unescape(s)
    s = re.sub(r"\s+", " ", s).strip()
    return s[:limit]


# ---------------- MiniMax 精判 ----------------

def minimax_chat(cfg, user_prompt):
    body = {
        "model": cfg.get("MINIMAX_MODEL") or "MiniMax-M3",
        "messages": [
            {"role": "system", "content": SYS_PROMPT},
            {"role": "user", "content": user_prompt},
        ],
        "max_tokens": 3000,
        "temperature": 0.2,
    }
    req = urllib.request.Request(
        cfg.get("MINIMAX_BASE_URL") or "https://api.minimaxi.com/v1/text/chatcompletion_v2",
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Authorization": "Bearer " + cfg.get("MINIMAX_API_KEY", ""),
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=90) as r:
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


def classify_one(cfg, row):
    """row → verdict dict；失败抛异常（scan 统一按失败处理，保持待审不丢）"""
    _id, _mp_id, mp_name, title, url, pub_ts, desc, content = row
    desc_t = strip_html(desc, 300)
    content_t = strip_html(content, 700)
    user = "公众号: %s\n标题: %s\n摘要: %s\n正文片段: %s" % (
        mp_name or "未知", title, desc_t or "无", content_t or "无")
    verdict = extract_json(minimax_chat(cfg, user))
    if not isinstance(verdict, dict) or "is_recruitment" not in verdict:
        raise ValueError("模型输出缺少字段: %r" % (verdict,))
    verdict["is_recruitment"] = bool(verdict.get("is_recruitment"))
    sy = verdict.get("session_year")
    verdict["session_year"] = int(sy) if isinstance(sy, (int, float)) else (
        int(str(sy)[:4]) if re.match(r"^\d{4}", str(sy or "")) else None)
    verdict.setdefault("type", "")
    verdict.setdefault("company", "")
    verdict.setdefault("positions", "")
    verdict.setdefault("reason", "")
    return verdict


# ---------------- 子命令 ----------------

def cmd_scan(args):
    cfg = load_cfg()
    quiet = args.quiet
    with StateLock():
        state = load_state()
        rows = fetch_candidates()
        todo = [r for r in rows
                if r[0] not in state["items"] or not state["items"][r[0]].get("verdict")]
        if args.limit:
            todo = todo[:args.limit]
        if not todo:
            if not quiet:
                print("无新候选（总候选 %d，待审 %d）" % (
                    len(rows), sum(1 for v in state["items"].values() if v.get("status") == "pending")))
            state["last_scan"] = dt.datetime.now().isoformat(timespec="seconds")
            save_state(state)
            return 0

        api_key = cfg.get("MINIMAX_API_KEY", "")
        n_rec = n_non = n_fail = 0

        def work(r):
            return r, classify_one(cfg, r)

        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            fut_row = {pool.submit(work, r): r for r in todo}
            for i, fu in enumerate(concurrent.futures.as_completed(fut_row), 1):
                row = fut_row[fu]
                verdict, err = None, None
                try:
                    _, verdict = fu.result()
                except Exception as e:
                    err = "%s: %s" % (type(e).__name__, e)
                _id, _mp_id, mp_name, title, url, pub_ts, desc, content = row
                item = state["items"].get(_id, {})
                item.update({
                    "id": _id, "mp_id": _mp_id, "mp_name": mp_name, "title": title,
                    "url": url, "found_ts": pub_ts, "desc": strip_html(desc, 300),
                    "added_at": dt.datetime.now().timestamp(),
                })
                if err is None:
                    item["verdict"] = True
                    item["is_recruitment"] = verdict["is_recruitment"]
                    item["type"] = verdict["type"]
                    item["session_year"] = verdict["session_year"]
                    item["company"] = str(verdict.get("company") or "")[:80]
                    item["positions"] = str(verdict.get("positions") or "")[:80]
                    item["reason"] = str(verdict.get("reason") or "")[:120]
                    item.pop("model_error", None)
                    # 首次判定才定状态；复判不覆盖「人工决定」，但必须覆盖失败占位
                    # （否则模型重判为非招聘也会卡在 pending —— 见下方 status_from_error）
                    if item.pop("status_from_error", False) or "status" not in item:
                        item["status"] = "pending" if verdict["is_recruitment"] else "skipped"
                        if not verdict["is_recruitment"]:
                            item["auto"] = True
                            item["skipped_at"] = dt.datetime.now().timestamp()
                    n_rec += 1 if verdict["is_recruitment"] else 0
                    n_non += 0 if verdict["is_recruitment"] else 1
                else:
                    item["verdict"] = None
                    item["model_error"] = err[:200]
                    # 失败保持待审（让人看得见），并打标记：重判时要允许覆盖这个占位状态
                    item.setdefault("status", "pending")
                    item["status_from_error"] = True
                    n_fail += 1
                state["items"][_id] = item
                if not quiet:
                    print("[%d/%d] %s %s | %s" % (
                        i, len(todo), "✓" if err is None else "✗", title[:40], err or ""))
                elif err is not None and (api_key or "").strip() == "":
                    pass  # 未配 key 的提示在汇总里统一说
        state["last_scan"] = dt.datetime.now().isoformat(timespec="seconds")
        save_state(state)
        pending = sum(1 for v in state["items"].values() if v.get("status") == "pending")
        if not quiet:
            print("本轮: 新判定 %d（招聘 %d / 非招聘 %d / 失败 %d）；当前待审 %d" % (
                len(todo), n_rec, n_non, n_fail, pending))
            if n_fail and not api_key.strip():
                print("提示: config.env 未配置 MINIMAX_API_KEY，候选仅按规则入库（全部待审）")
        else:
            if n_fail:
                print("jobs scan: %d 失败（下轮自动重试）" % n_fail, file=sys.stderr)
    return 0


def decorate(item, now=None):
    """给单条 item 补展示字段（不落盘）"""
    now = now or dt.datetime.now()
    ts = item.get("found_ts") or 0
    d = dt.datetime.fromtimestamp(ts) if ts else None
    out = dict(item)
    out["date"] = d.strftime("%Y-%m-%d") if d else ""
    out["time"] = d.strftime("%H:%M") if d else ""
    out["is_today"] = d is not None and d.date() == now.date()
    sy = item.get("session_year")
    cycle = now.year + (1 if now.month >= 6 else 0)  # 9月看2027届；6月前看同年届
    out["stale"] = bool(sy and sy < cycle)
    return out


def cmd_list(args):
    cfg = load_cfg()
    state = load_state()
    items = [decorate(v) for v in state["items"].values()]
    items.sort(key=lambda x: -(x.get("found_ts") or 0))
    counts = {
        "pending": sum(1 for i in items if i["status"] == "pending"),
        "published": sum(1 for i in items if i["status"] == "published"),
        "skipped": sum(1 for i in items if i["status"] == "skipped"),
        "total": len(items),
    }
    pub_url = (cfg.get("JOBS_PUBLISH_URL") or "").strip()
    meta = {
        "last_scan": state.get("last_scan") or "",
        "publish_configured": bool(pub_url),
        "publish_host": urlparse(pub_url).netloc if pub_url else "",
    }
    if args.status and args.status != "all":
        items = [i for i in items if i["status"] == args.status]
    if args.json:
        print(json.dumps({"counts": counts, "meta": meta, "items": items}, ensure_ascii=False))
    else:
        for i in items:
            print("%s %-4s %-6s %s | %s" % (
                i["date"], i["time"], i["status"], i["mp_name"][:14], i["title"][:48]))
        print("-- 待审%(pending)d 已发布%(published)d 已忽略%(skipped)d" % counts)
    return 0


def cmd_stats(_args):
    state = load_state()
    pending = sum(1 for v in state["items"].values() if v.get("status") == "pending")
    published = sum(1 for v in state["items"].values() if v.get("status") == "published")
    skipped = sum(1 for v in state["items"].values() if v.get("status") == "skipped")
    print("pending=%d" % pending)
    print("published=%d" % published)
    print("skipped=%d" % skipped)
    print("total=%d" % len(state["items"]))
    print("unseen=%d" % max(0, pending - int(state.get("seen_pending") or 0)))
    print("last_scan=%s" % (state.get("last_scan") or "never"))
    return 0


def cmd_seen(_args):
    with StateLock():
        state = load_state()
        state["seen_pending"] = sum(
            1 for v in state["items"].values() if v.get("status") == "pending")
        save_state(state)
    return 0


def build_payload(item):
    ts = item.get("found_ts") or 0
    return {
        "source": "werss-app",
        "article_id": item["id"],
        "title": item["title"],
        "url": item.get("url", ""),
        "mp_name": item.get("mp_name", ""),
        "company": item.get("company", ""),
        "type": item.get("type", ""),
        "session_year": item.get("session_year"),
        "positions": item.get("positions", ""),
        "found_at": dt.datetime.fromtimestamp(ts).isoformat(timespec="seconds") if ts else "",
        "published_at": dt.datetime.now().isoformat(timespec="seconds"),
    }


def cmd_publish(args):
    cfg = load_cfg()
    with StateLock():
        state = load_state()
        item = state["items"].get(args.id)
        if not item:
            print("不存在: %s" % args.id, file=sys.stderr)
            return 1
        if item.get("status") == "published":
            print("已是已发布状态（%s），跳过" % dt.datetime.fromtimestamp(
                item.get("published_at") or 0).strftime("%m-%d %H:%M"))
            return 0
        payload = build_payload(item)
        # 环境变量可临时覆盖 config.env（便于联调测试）
        url = (os.environ.get("JOBS_PUBLISH_URL") or cfg.get("JOBS_PUBLISH_URL") or "").strip()
        note = "本地标记（未配置 JOBS_PUBLISH_URL）"
        if url:
            headers = {"Content-Type": "application/json"}
            tok = (cfg.get("JOBS_PUBLISH_TOKEN") or "").strip()
            if tok:
                headers["Authorization"] = "Bearer " + tok
            req = urllib.request.Request(url, data=json.dumps(
                payload, ensure_ascii=False).encode("utf-8"), headers=headers, method="POST")
            try:
                with urllib.request.urlopen(req, timeout=20) as r:
                    note = "HTTP %d → %s" % (r.status, url)
            except urllib.error.HTTPError as e:
                print("发布失败 HTTP %d: %s" % (e.code, e.read()[:200]), file=sys.stderr)
                return 1
            except Exception as e:
                print("发布失败: %s" % e, file=sys.stderr)
                return 1
        item["status"] = "published"
        item["published_at"] = dt.datetime.now().timestamp()
        item["publish_note"] = note
        save_state(state)
        print("已发布: %s（%s）" % (item["title"][:40], note))
    return 0


def cmd_skip(args):
    with StateLock():
        state = load_state()
        item = state["items"].get(args.id)
        if not item:
            print("不存在: %s" % args.id, file=sys.stderr)
            return 1
        item["status"] = "skipped"
        item["skipped_at"] = dt.datetime.now().timestamp()
        save_state(state)
        print("已忽略: %s" % item["title"][:40])
    return 0


def cmd_undo(args):
    with StateLock():
        state = load_state()
        item = state["items"].get(args.id)
        if not item:
            print("不存在: %s" % args.id, file=sys.stderr)
            return 1
        item["status"] = "pending"
        for k in ("published_at", "skipped_at", "auto", "publish_note"):
            item.pop(k, None)
        save_state(state)
        print("已恢复待审: %s" % item["title"][:40])
    return 0


def main():
    p = argparse.ArgumentParser(description="招聘帖审查与发布")
    sub = p.add_subparsers(dest="cmd", required=True)
    sp = sub.add_parser("scan"); sp.add_argument("--limit", type=int, default=0); sp.add_argument("--quiet", action="store_true")
    sp = sub.add_parser("list"); sp.add_argument("--status", default="all",
                                                 choices=["pending", "published", "skipped", "all"])
    sp.add_argument("--json", action="store_true")
    sub.add_parser("stats")
    sub.add_parser("seen")
    sp = sub.add_parser("publish"); sp.add_argument("id")
    sp = sub.add_parser("skip"); sp.add_argument("id")
    sp = sub.add_parser("undo"); sp.add_argument("id")
    args = p.parse_args()
    fn = {"scan": cmd_scan, "list": cmd_list, "stats": cmd_stats, "seen": cmd_seen,
          "publish": cmd_publish, "skip": cmd_skip, "undo": cmd_undo}[args.cmd]
    sys.exit(fn(args))


if __name__ == "__main__":
    main()
