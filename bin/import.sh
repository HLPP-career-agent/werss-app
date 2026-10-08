#!/bin/bash
# 从备份包恢复：停全套 → 本机旧数据安全挪走(绝不删除) → 换入备份数据 → 起容器 → 三核对 → 起 runner。
# 用法: import.sh <werss-backup-*.tar.gz>
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

BK="${1:-}"
if [ -z "$BK" ] || [ ! -f "$BK" ]; then
  # 自动找最近的备份包
  BK=$(ls -t "$WERSS_ROOT"/backups/werss-backup-*.tar.gz 2>/dev/null | head -1)
fi
if [ -z "$BK" ] || [ ! -f "$BK" ]; then
  echo "用法: $0 <werss-backup-*.tar.gz>（也可先放入 backups/ 目录自动识别）"
  notify_now "导入失败" "未找到备份包"
  exit 1
fi
BK="$(cd "$(dirname "$BK")" && pwd)/$(basename "$BK")"
log "[import] 使用备份包: $BK"

STAGE="$WERSS_ROOT/.import-stage.$$"
PRE="$WERSS_ROOT/backups/pre-import-$(date +%Y%m%d-%H%M%S)"

# ---- 1. 解包校验 ----
rm -rf "$STAGE"; mkdir -p "$STAGE"
tar -xzf "$BK" -C "$STAGE"
if [ ! -f "$STAGE/manifest.json" ]; then
  log "[import] 备份包缺少 manifest.json，不是 werss-app 备份包"; rm -rf "$STAGE"; exit 1
fi
cp "$STAGE/manifest.json" "$WERSS_ROOT/.last-import-manifest"
python3 -c "import json;m=json.load(open('$WERSS_ROOT/.last-import-manifest'));print('[import] 备份包基准: 订阅%s 文章%s 有正文%s 待采%s CSV=%s'%(m.get('feeds','?'),m.get('articles','?'),m.get('has_content','?'),m.get('slice_remaining','?'),m.get('csv')))"

# ---- 2. 停全套 ----
log "[import] 停止本机 runner 与容器…"
stop_runner || true
compose down 2>/dev/null || docker rm -f "$WERSS_CONTAINER" 2>/dev/null

# ---- 3. 本机旧数据安全挪走（绝不删除）----
mkdir -p "$PRE"
[ -d "$WERSS_ROOT/data" ] && mv "$WERSS_ROOT/data" "$PRE/data"
[ -f "$WERSS_ROOT/companies.csv" ] && mv "$WERSS_ROOT/companies.csv" "$PRE/companies.csv"
for f in slice1.jsonl slice2.jsonl slice3.jsonl canary_pool.json canary_idx \
         pending_articles.jsonl recovery_done.txt todo.jsonl; do
  [ -f "$BATCH/$f" ] && mv "$BATCH/$f" "$PRE/batch-$f" 2>/dev/null
done
mkdir -p "$PRE"; true
log "[import] 本机旧数据已挪至 $PRE"

# ---- 4. 换入备份数据 ----
[ -d "$STAGE/data" ] && mv "$STAGE/data" "$WERSS_ROOT/data"
[ -f "$STAGE/companies.csv" ] && mv "$STAGE/companies.csv" "$WERSS_ROOT/companies.csv"
for f in slice1.jsonl slice2.jsonl slice3.jsonl canary_pool.json canary_idx \
         pending_articles.jsonl recovery_done.txt todo.jsonl; do
  [ -f "$STAGE/batch/$f" ] && mv "$STAGE/batch/$f" "$BATCH/$f"
done
rm -rf "$STAGE"

# 不迁 taskSpace id 与锁文件（新机自愈重建，旧锁反而碍事）
rm -f "$BATCH"/space_*.id 2>/dev/null
rm -rf "$BATCH"/browser.lock.d 2>/dev/null

# ---- 5. 起容器（镜像缺失时自动拉取）----
log "[import] 启动容器（初始化约 2 分钟）…"
compose up -d
if ! wait_app 600; then
  notify_important app "导入后启动失败" "容器已启动但应用 10 分钟未就绪，请看 docker logs $WERSS_CONTAINER"
  log "[import] 应用未就绪，请人工检查"; exit 1
fi

# ---- 6. 三核对：订阅数 / 文章数 / 待处理余量（实际 vs 备份包基准）----
NOW=$(bash "$WERSS_ROOT/bin/status.sh" 2>/dev/null | head -1)
log "[import] 导入后实际: $NOW"
VERIFY=$(python3 - "$WERSS_ROOT" "$WERSS_CONTAINER" "$CSV_PATH" <<'PY'
import csv, json, os, subprocess, sys
root, container, csv_path = sys.argv[1], sys.argv[2], sys.argv[3]
m = json.load(open(os.path.join(root, ".last-import-manifest"), encoding="utf-8"))
cur = {}
try:
    out = subprocess.run(["docker", "exec", container, "python3", "-c",
        "import sqlite3;db=sqlite3.connect('file:/app/data/db.db?mode=ro',uri=True);"
        "print(db.execute('select count(*) from feeds').fetchone()[0],db.execute('select count(*) from articles').fetchone()[0])"],
        capture_output=True, text=True, timeout=30).stdout.split()
    cur["feeds"], cur["articles"] = int(out[0]), int(out[1])
except Exception:
    pass
n = 0
for k in (1, 2, 3):
    p = os.path.join(root, "batch", f"slice{k}.jsonl")
    if os.path.exists(p):
        n += sum(1 for l in open(p, encoding="utf-8") if l.strip())
cur["slice_remaining"] = n
def cmp(key):
    if key not in cur or key not in m: return "?"
    return "一致" if cur[key] == m[key] else f"不一致(实际{cur[key]}/备份{m[key]})"
print(f"订阅{cmp('feeds')} 文章{cmp('articles')} 待采{cmp('slice_remaining')}")
PY
)
log "[import] 核对: $VERIFY"

# ---- 7. 起 runner ----
start_runner

notify_now "导入完成" "$VERIFY｜$NOW"
log "[import] 完成。旧数据保留在 $PRE（确认无误后可手动清理）"
