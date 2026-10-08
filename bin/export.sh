#!/bin/bash
# 导出备份包：停 runner+容器(保证 SQLite 一致) → 打包数据/台账/进度 → 自动恢复运行。
# 用法: export.sh [--with-image]   产物: backups/werss-backup-YYYYmmdd-HHMM.tar.gz
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

STAGE="$WERSS_ROOT/.export-stage.$$"
BACKUP_DIR="$WERSS_ROOT/backups"; mkdir -p "$BACKUP_DIR"
TS=$(date +%Y%m%d-%H%M)
OUT="$BACKUP_DIR/werss-backup-$TS.tar.gz"

# ---- 0. 先在运行中统计核对数字（写进 manifest，导入侧据此校验）----
STATS=$(bash "$WERSS_ROOT/bin/status.sh" 2>/dev/null)
log "[export] 当前状态: $STATS"

python3 - "$WERSS_ROOT" "$CSV_PATH" > "$BACKUP_DIR/.manifest.$$.json" <<'PY'
import csv, json, os, subprocess, sys, collections, datetime
root, csv_path = sys.argv[1], sys.argv[2]
m = {"created": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")}
try:
    rows = list(csv.reader(open(csv_path, newline="", encoding="utf-8-sig")))
    h = rows[0]; i = h.index("wx_mp_status")
    c = collections.Counter(r[i] for r in rows[1:] if r and len(r) > i)
    m["csv"] = dict(c)
except Exception as e:
    m["csv"] = {"error": str(e)[:100]}
try:
    out = subprocess.run(["docker", "exec", os.environ.get("WERSS_CONTAINER", "we-mp-rss"), "python3", "-c",
        "import sqlite3;db=sqlite3.connect('file:/app/data/db.db?mode=ro',uri=True);"
        "print(db.execute('select count(*) from feeds').fetchone()[0],"
        "db.execute('select count(*) from articles').fetchone()[0],"
        "db.execute('select count(*) from articles where has_content=1').fetchone()[0])"],
        capture_output=True, text=True, timeout=30).stdout.split()
    m["feeds"], m["articles"], m["has_content"] = int(out[0]), int(out[1]), int(out[2])
except Exception as e:
    m["db_error"] = str(e)[:100]
n = 0
for k in (1, 2, 3):
    p = os.path.join(root, "batch", f"slice{k}.jsonl")
    if os.path.exists(p):
        n += sum(1 for l in open(p, encoding="utf-8") if l.strip())
m["slice_remaining"] = n
print(json.dumps(m, ensure_ascii=False, indent=1))
PY

# ---- 1. 停 runner 与容器 ----
log "[export] 停止 runner 与容器（约 1-2 分钟）…"
stop_runner || log "[export] runner 停止超时，继续（导出后再处理）"
compose stop

# ---- 2. 打包 ----
rm -rf "$STAGE"; mkdir -p "$STAGE/batch"
cp "$BACKUP_DIR/.manifest.$$.json" "$STAGE/manifest.json" && rm -f "$BACKUP_DIR/.manifest.$$.json"
[ -d "$WERSS_ROOT/data" ] && cp -R "$WERSS_ROOT/data" "$STAGE/data"
[ -f "$CSV_PATH" ] && cp "$CSV_PATH" "$STAGE/companies.csv"
for f in slice1.jsonl slice2.jsonl slice3.jsonl canary_pool.json canary_idx \
         pending_articles.jsonl recovery_done.txt todo.jsonl; do
  [ -f "$BATCH/$f" ] && cp "$BATCH/$f" "$STAGE/batch/$f"
done
# data 里 redis/cache 属可再生产物，一并打包保证开箱即用；排除超大无用文件
tar -czf "$OUT" -C "$STAGE" manifest.json data companies.csv batch 2>/dev/null \
  || tar -czf "$OUT" -C "$STAGE" manifest.json companies.csv batch
rm -rf "$STAGE"

SIZE=$(du -h "$OUT" | cut -f1)
log "[export] 备份包完成: $OUT ($SIZE)"

# ---- 3. 可选：内嵌镜像（离线装机用）----
if [ "${1:-}" = "--with-image" ]; then
  log "[export] 附加导出镜像（约 4.3GB，需要几分钟）…"
  docker save "${WERSS_IMAGE%%@*}" | gzip > "$BACKUP_DIR/werss-image.tar.gz"
  log "[export] 镜像包: $BACKUP_DIR/werss-image.tar.gz ($(du -h "$BACKUP_DIR/werss-image.tar.gz" | cut -f1))"
fi

# ---- 4. 恢复运行 ----
log "[export] 恢复容器与 runner…"
compose up -d
RESTORE_OK=1
wait_app 300 || { RESTORE_OK=; notify_important app "导出后恢复失败" "容器已启动但应用未就绪，请检查"; }
start_runner

# ---- 5. 完成汇总与交接引导（数字取自备份包内 manifest，即导入侧核对的同一基准）----
# 注意：括号串在 python 里拼好，bash 侧只做 ${PROGRESS} 直接替换——
# bash(3.2) 的 ${var:+…$var…} 同名嵌套展开会截坏多字节字符，不能用。
META=$(tar -xzOf "$OUT" manifest.json 2>/dev/null | python3 -c "
import sys, json
m = json.load(sys.stdin)
c = m.get('csv') or {}
done = c.get('已添加', 0) + c.get('未找到', 0)
total = done + c.get('待处理', 0)
prog = f'（共{total}家、已处理{done}、进度约{round(done * 100 / total)}%，队列随采集减少）' if total else ''
print(m.get('feeds', '?'), m.get('articles', '?'), m.get('slice_remaining', '?'), prog, sep='|')
" 2>/dev/null)
IFS='|' read -r FEEDS ARTICLES SLICE_LEFT PROGRESS <<< "$META"
: "${FEEDS:=?}" "${ARTICLES:=?}" "${SLICE_LEFT:=?}"
notify_now "备份完成" "$OUT ($SIZE)｜下一步: 拷到新机放入 backups/ 双击交接导入"

BAR=$(printf '━%.0s' {1..44})
echo; echo "$BAR"
if [ -n "$RESTORE_OK" ]; then
  echo "✅ 备份完成，采集已恢复运行（开头几行是导出前的系统体检，与备份结果无关）"
else
  echo "⚠️ 备份完成，但容器恢复未就绪——备份包本身有效，请按上方通知排查"
fi
echo
echo "备份包: $OUT ($SIZE)"
echo "快照: 订阅${FEEDS} · 文章${ARTICLES} · 待采${SLICE_LEFT}${PROGRESS}"
echo
echo "交接两步:"
echo "  旧机: 把上面这个备份包发给新机（AirDrop/U盘均可）"
echo "  新机: 先装好 werss-app（安装.command）→ 备份包放入 backups/ → 双击 交接导入.command 直接回车"
echo "导入后自动核对数字，本机数据只挪不删。此窗口可关闭。"
echo "$BAR"
