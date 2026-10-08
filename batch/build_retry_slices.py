#!/usr/bin/env python3
"""第二轮公众号重试:为"未找到"公司生成没试过的新关键字队列 + 播种每轮独立台账。

用法:
  python3 build_retry_slices.py            # dry-run,只打印报告,不写任何文件
  python3 build_retry_slices.py --write    # 写 slice1/2/3.jsonl + 播种 mp_match_ledger.json

规则:
  - 只取 wx_mp_status ∈ {未找到, 待复核} 且 ledger 里尚无 round-2 结果的公司;
  - 新词 = 结构变体(去括号/去括号内文字/全角Ａ→半角去尾/去城市前缀,各配±招聘,外加"+人才招聘"兜底),
    与 ledger 全部历史词归一化去重,家内去重,每家截断 ≤6 个;
  - 旧格式台账(无时间戳,含当年主授权失效误标嫌疑批次)排队列最前;
  - 写入 slice 后 keepalive 会在 30 分钟内自动拉起 runner。
"""
import datetime, json, os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mp_retry_lib import (BATCH, norm, parse_tried, read_csv,
                          ledger_load, ledger_save, ledger_history_kws)

CSV_PATH = os.environ.get("WERSS_CSV", os.path.join(BATCH, "..", "companies.csv"))
MAX_KWS = 6
CITIES = ("深圳|上海|北京|广州|天津|重庆|苏州|杭州|南京|武汉|成都|西安|长沙|郑州"
          "|青岛|厦门|宁波|无锡|合肥|福州")

def js_clean(s):
    """镜像 add_company.js clean():去空白/＊、去 ST/SST 前缀、去 ASCII 尾 A。"""
    s = re.sub(r"[\s*＊]", "", s or "")
    s = re.sub(r"^(SST|ST|ＳＴ)", "", s, flags=re.I)
    return re.sub(r"A$", "", s)

def js_base(name):
    """镜像 add_company.js base:去 法务后缀(含集团/控股)。"""
    b = re.sub(r"(控股集团|集团|控股)?股份有限公司$", "", name or "")
    return re.sub(r"(集团|控股)?有限公司$", "", b)

def round2_cands(short, name):
    s = js_clean(short)
    base = js_base(name)
    base_noparen = re.sub(r"[()（）\[\]【】]", "", base)
    base_in = re.sub(r"[()（）\[\]【】][^()（）\[\]【】]*[()（）\[\]【】]", "", base)
    bare = s.replace("Ａ", "A").replace("Ｂ", "B").replace("Ｃ", "C")
    bare = re.sub(r"[ABC]$", "", bare)
    out = []
    for x in [base_noparen + "招聘", base_noparen, base_in + "招聘", base_in,
              bare + "招聘", bare, base + "人才招聘"]:
        x = (x or "").strip()
        if x and len(x) >= 2 and x not in out:
            out.append(x)
    m = re.match("^(%s)市?" % CITIES, base_in)
    if m and len(base_in) > len(m.group(0)) + 1:
        stripped = base_in[len(m.group(0)):]
        for x in [stripped + "招聘", stripped]:
            if len(x) >= 2 and x not in out:
                out.append(x)
    return out

def is_old_format(cell):
    """旧格式台账 = 有内容但无时间戳(第一版代码所写,误标嫌疑最大)。"""
    c = (cell or "").strip()
    return bool(c) and not re.search(r"\d{2}:\d{2}尝试:", c)

def main(write=False):
    rows = read_csv(CSV_PATH)
    ledger = ledger_load()
    seeded = "_meta" in ledger

    if write and not seeded:
        ledger["_meta"] = {
            "seeded_at": datetime.datetime.now().isoformat(timespec="seconds"),
            "note": "round1 由 companies.csv wx_mp_tried_names 播种;round2 起由 process_chunk.py 追加",
        }

    queued, skipped_no_round2, skipped_no_kws = [], [], []
    dist = {"1": 0, "2-3": 0, "4-5": 0, "6": 0}
    total_kws = 0
    old_cnt = 0

    for r in rows:
        cid = r["company_id"].strip()
        status = (r["wx_mp_status"] or "").strip()
        if status not in ("未找到", "待复核"):
            continue
        comp_ledger = ledger.setdefault(cid, {"company_name": r["company_name"],
                                              "short": r["short"], "rounds": []})
        if any(x.get("round") == 2 for x in comp_ledger.get("rounds", [])):
            skipped_no_round2.append(cid)   # 已有第二轮结果,不重复入队
            continue
        # 播种 round1(仅首次 --write;dry-run 用临时副本不影响真实 ledger)
        if not any(x.get("round") == 1 for x in comp_ledger["rounds"]):
            cell = r["wx_mp_tried_names"]
            if (cell or "").strip():
                comp_ledger["rounds"].append({
                    "round": 1, "time": None, "kws": parse_tried(cell),
                    "result": "not_found" if status == "未找到" else "pending_review",
                    "source": "csv_seed"})

        hist = ledger_history_kws(ledger, cid)
        seen, novel = set(), []
        for k in round2_cands(r["short"], r["company_name"]):
            n = norm(k)
            if n in hist or n in seen:
                continue
            seen.add(n)
            novel.append(k)
            if len(novel) >= MAX_KWS:
                break
        total_kws += len(novel)
        if not novel:
            skipped_no_kws.append((cid, r["company_name"]))
            continue
        dist["1" if len(novel) == 1 else "2-3" if len(novel) <= 3
             else "4-5" if len(novel) <= 5 else "6"] += 1
        old = is_old_format(r["wx_mp_tried_names"])
        old_cnt += 1 if old else 0
        queued.append({
            "company_id": cid, "name": r["company_name"], "short": r["short"],
            "round": 2, "retry_kws": novel, "_old": old})

    # 旧格式(误标嫌疑)排最前,其余按 company_id 稳定排序
    queued.sort(key=lambda x: (not x["_old"], x["company_id"]))
    for it in queued:
        it.pop("_old")

    slices = {1: [], 2: [], 3: []}
    for i, it in enumerate(queued):
        slices[i % 3 + 1].append(it)

    print("=== 第二轮重试队列报告 (%s) ===" % ("WRITE" if write else "dry-run"))
    print("入队公司数: %d  (其中旧格式台账优先: %d)" % (len(queued), old_cnt))
    print("每家新词数分布: %s" % dist)
    print("预计总搜索次数: %d  (每家 ≤%d 词)" % (total_kws, MAX_KWS))
    print("slice1/2/3: %d/%d/%d" % (len(slices[1]), len(slices[2]), len(slices[3])))
    print("无新词跳过: %d   已有round2结果跳过: %d" % (len(skipped_no_kws), len(skipped_no_round2)))
    print("--- 队首 5 项(旧格式优先) ---")
    for it in queued[:5]:
        print(" %s | %s | %s" % (it["company_id"], it["name"], ";".join(it["retry_kws"])))
    print("--- 队尾 3 项 ---")
    for it in queued[-3:]:
        print(" %s | %s | %s" % (it["company_id"], it["name"], ";".join(it["retry_kws"])))
    if skipped_no_kws:
        print("--- 无新词样例(最多5) ---")
        for cid, nm in skipped_no_kws[:5]:
            print(" %s %s" % (cid, nm))

    if not write:
        print("(dry-run 未写任何文件;确认后加 --write)")
        return

    if os.system("pgrep -f 'bash .*run_forever.sh' >/dev/null 2>&1") == 0:
        print("ABORT: runner 正在运行,先停止再写入(避免队列被覆盖)")
        sys.exit(1)
    for n in (1, 2, 3):
        with open(os.path.join(BATCH, "slice%d.jsonl" % n), "w", encoding="utf-8") as f:
            for it in slices[n]:
                f.write(json.dumps(it, ensure_ascii=False) + "\n")
    ledger_save(ledger)
    print("已写入 slice1/2/3.jsonl 与 mp_match_ledger.json;keepalive 将在 30 分钟内自动拉起 runner")

if __name__ == "__main__":
    main(write="--write" in sys.argv)
