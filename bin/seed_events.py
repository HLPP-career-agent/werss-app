#!/usr/bin/env python3
"""一次性:把 companies.csv 里"已添加"的行播种为 added 事件。

第一批批量匹配(2026-09-17 起)的成功记录只存在于 CSV 台账(wx_mp_added_at/wx_mp_name),
播种后菜单栏「全量日志」窗口的"已添加"筛选即可跨第一、二批查看。
幂等:events.jsonl 里已存在 csv_seed 播种行时跳过(--force 可重播)。
"""
import os, sys, json

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "batch"))
from mp_retry_lib import log_event, read_csv, EVENTS_PATH, ledger_load

def seeded_already():
    try:
        with open(EVENTS_PATH, encoding="utf-8") as f:
            return any('"source": "csv_seed"' in ln for ln in f)
    except FileNotFoundError:
        return False

def main():
    force = "--force" in sys.argv
    if seeded_already() and not force:
        print("已播种过,跳过(--force 重播)")
        return
    if force:
        # 重播:先剔除旧的播种行,避免重复
        kept = []
        try:
            with open(EVENTS_PATH, encoding="utf-8") as f:
                for ln in f:
                    try:
                        if json.loads(ln).get("source") == "csv_seed":
                            continue
                    except Exception:
                        pass
                    kept.append(ln)
            with open(EVENTS_PATH, "w", encoding="utf-8") as f:
                f.writelines(kept)
        except FileNotFoundError:
            pass
    csv_path = os.environ.get("WERSS_CSV",
                              os.path.join(os.path.dirname(os.path.dirname(
                                  os.path.abspath(__file__))), "companies.csv"))
    rows = read_csv(csv_path)
    # ledger 里有 round-2 记录的公司属于第二批,轮次标记要修正
    r2 = {cid for cid, v in ledger_load().items() if cid != "_meta"
          for x in v.get("rounds", []) if x.get("round") == 2}
    n = 0
    for r in rows:
        if (r.get("wx_mp_status") or "").strip() != "已添加":
            continue
        name = (r.get("wx_mp_name") or "").strip()
        added_at = (r.get("wx_mp_added_at") or "").strip()
        if not name or not added_at:
            continue
        # "2026-09-17 17:45" → ISO "2026-09-17T17:45:00"(与在线事件同为 T 分隔,排序一致)
        ts = added_at.replace(" ", "T") + (":00" if len(added_at) == 16 else "")
        cid = r["company_id"].strip()
        log_event("added", detail="批量匹配第二轮(CSV播种)" if cid in r2 else "批量匹配第一轮(CSV播种)",
                  ts=ts, company_id=cid,
                  company_name=(r.get("company_name") or "").strip(),
                  mp_name=name, round=2 if cid in r2 else 1,
                  worker=None, source="csv_seed")
        n += 1
    print(f"播种 {n} 条已添加事件(其中第二轮 {sum(1 for r in rows if r['company_id'].strip() in r2 and (r.get('wx_mp_status') or '').strip()=='已添加')}) → {EVENTS_PATH}")

if __name__ == "__main__":
    main()
