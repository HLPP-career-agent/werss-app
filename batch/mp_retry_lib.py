#!/usr/bin/env python3
"""公众号重试轮共享库:关键字归一化 / 已试关键字台账解析 / 每轮独立 ledger 读写。

ledger (mp_match_ledger.json) 结构:
  {
    "_meta": {"seeded_at": "...", "note": "..."},
    "C00002": {
      "company_name": "...", "short": "...",
      "rounds": [
        {"round": 1, "time": null, "kws": [...], "result": "not_found", "source": "csv_seed"},
        {"round": 2, "time": "...", "kws": [...], "per_kw": [{"kw":..., "opts": 3}],
         "ai_pick": null, "ai_reason": "...", "result": "not_found", "name": ""}
      ]
    }
  }
去重的唯一依据是 ledger 全部 rounds 的 kws(归一化后);CSV wx_mp_tried_names 只是给人看的摘要。
"""
import csv, datetime, fcntl, json, os

BATCH = os.path.dirname(os.path.abspath(__file__))
LEDGER_PATH = os.path.join(BATCH, "mp_match_ledger.json")
LEDGER_LOCK = LEDGER_PATH + ".lock"
T2S_PATH = os.path.join(BATCH, "t2s_map.json")
LOGS_DIR = os.path.join(os.path.dirname(BATCH), "logs")
EVENTS_PATH = os.path.join(LOGS_DIR, "events.jsonl")

def load_t2s():
    try:
        with open(T2S_PATH, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}

_T2S = load_t2s()

def norm(s):
    """与 add_company.js 的 norm() 一致:全角→半角 + 繁→简 + 小写。"""
    out = []
    for ch in s or "":
        c = ord(ch)
        if 0xFF01 <= c <= 0xFF5E:
            out.append(chr(c - 0xFEE0))
        else:
            out.append(_T2S.get(ch, ch))
    return "".join(out).lower()

def parse_tried(cell):
    """解析 wx_mp_tried_names 台账格,兼容两种历史格式:
    旧: 尝试:K1;K2;K3      (仅首段带"尝试:"前缀,后续为裸关键字)
    新: 尝试:HH:MM尝试:K1;HH:MM尝试:K2
    """
    if not (cell or "").strip():
        return []
    kws = []
    for seg in cell.split(";"):
        seg = seg.strip()
        if not seg:
            continue
        if "尝试:" in seg:
            kws.append(seg[seg.rindex("尝试:") + 3:].strip())
        else:
            kws.append(seg)
    return [k for k in kws if k]

def merge_tried_cell(old_cell, new_kws, now=None):
    """未找到/待复核写回:在旧台账后追加本轮关键字,历史不丢(旧代码是整格覆盖)。
    输出保持既有形态:非空格首段仍带"尝试:"前缀,新段带 HH:MM 时间戳。
    """
    now = now or datetime.datetime.now().strftime("%H:%M")
    new_segs = [f"{now}尝试:{k}" for k in new_kws]
    old = (old_cell or "").strip()
    if not old:
        return "尝试:" + ";".join(new_segs) if new_segs else ""
    if not new_segs:
        return old
    return old + ";" + ";".join(new_segs)

def ledger_load():
    try:
        with open(LEDGER_PATH, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}

def ledger_save(data):
    tmp = LEDGER_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    os.replace(tmp, LEDGER_PATH)

def ledger_append_result(company_id, entry):
    """多 worker 并发安全的一轮结果追加(flock 串行化读改写)。"""
    with open(LEDGER_LOCK, "a+") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        data = ledger_load()
        data.setdefault(company_id, {"rounds": []}).setdefault("rounds", []).append(entry)
        ledger_save(data)
        fcntl.flock(lk, fcntl.LOCK_UN)

def ledger_history_kws(data, company_id):
    """某公司全部轮次已试关键字的归一化集合。"""
    out = set()
    for r in data.get(company_id, {}).get("rounds", []):
        for k in r.get("kws", []):
            if k:
                out.add(norm(k))
    return out

def read_csv(path):
    with open(path, newline="", encoding="utf-8-sig") as f:
        return list(csv.DictReader(f))

# ---- 结构化事件日志(logs/events.jsonl):菜单栏「全量日志」窗口的数据源 ----
# 每行一个 JSON: {ts, type, detail, company_id?, company_name?, mp_name?, round?, worker?, ...}
# type ∈ added | not_found | pending_review | abort | canary | chunk | runner | keepalive

def log_event(type_, detail=None, ts=None, **fields):
    """追加一条事件。ts 供播种历史数据用;日志写入失败绝不打断主流程。"""
    rec = {"ts": ts or datetime.datetime.now().isoformat(timespec="seconds"),
           "type": type_, "detail": detail}
    rec.update({k: v for k, v in fields.items() if v is not None})
    try:
        os.makedirs(LOGS_DIR, exist_ok=True)
        with open(EVENTS_PATH, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except Exception:
        pass

def prune_events(days=7):
    """普通事件保留 N 天;added(已添加,CSV台账镜像,覆盖第一/二批)豁免清理。"""
    try:
        with open(EVENTS_PATH, encoding="utf-8") as f:
            lines = f.readlines()
    except FileNotFoundError:
        return 0, 0
    cutoff = (datetime.datetime.now() - datetime.timedelta(days=days)).isoformat(timespec="seconds")
    kept, dropped = [], 0
    for ln in lines:
        try:
            rec = json.loads(ln)
        except Exception:
            continue
        if rec.get("type") == "added" or (rec.get("ts") or "") >= cutoff:
            kept.append(ln if ln.endswith("\n") else ln + "\n")
        else:
            dropped += 1
    if dropped:
        tmp = EVENTS_PATH + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.writelines(kept)
        os.replace(tmp, EVENTS_PATH)
    return len(kept), dropped
