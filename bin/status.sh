#!/bin/bash
# 状态报告。默认人类可读多行；--parse 输出机器可读 key=value（菜单栏应用用）。
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

MODE="${1:-}"   # 先存：后面 set -- 会覆盖位置参数

docker_ok && D=OK || D=DOWN
container_up && C=UP || C=DOWN
app_alive && A=OK || A=DOWN
runner_alive && R="UP" || R="DOWN"

# CSV 进度
CSV_ADDED=0; CSV_NOTFOUND=0; CSV_PENDING=0
if [ -f "$CSV_PATH" ]; then
  while IFS='=' read -r k v; do
    case "$k" in
      CSV_ADDED) CSV_ADDED="$v" ;;
      CSV_NOTFOUND) CSV_NOTFOUND="$v" ;;
      CSV_PENDING) CSV_PENDING="$v" ;;
    esac
  done < <(python3 - "$CSV_PATH" <<'PY'
import csv, sys, collections
rows = list(csv.reader(open(sys.argv[1], newline="", encoding="utf-8-sig")))
h = rows[0]; i = h.index("wx_mp_status")
c = collections.Counter(r[i] for r in rows[1:] if r and len(r) > i)
print("CSV_ADDED=%d" % c.get('已添加', 0))
print("CSV_NOTFOUND=%d" % c.get('未找到', 0))
print("CSV_PENDING=%d" % c.get('待处理', 0))
PY
)
fi
SLICE=$(slice_remaining)

# 文章/订阅数（容器内 SQLite 只读查询，带超时防引擎卡死拖住菜单栏）
# 第 2 行顺带只读返回文章同步定时任务现状（任务名/cron/启用状态），供菜单栏显示与子菜单勾选
FEEDS=-1; ARTICLES=-1; HAS_CONTENT=-1
SYNC_TASK_NAME=""; SYNC_TASK_CRON=""; SYNC_TASK_STATUS=""
if container_up; then
  OUT=$(with_timeout 15 docker exec "$WERSS_CONTAINER" python3 -c "
import sqlite3, json
db = sqlite3.connect('file:/app/data/db.db?mode=ro', uri=True)
print(db.execute('select count(*) from feeds').fetchone()[0],
      db.execute('select count(*) from articles').fetchone()[0],
      db.execute('select count(*) from articles where has_content=1').fetchone()[0])
row = db.execute('select name,cron_exp,status from message_tasks order by rowid limit 1').fetchone()
print(json.dumps(list(row), ensure_ascii=False) if row else '-')
" 2>/dev/null) && {
    FEEDS=$(echo "$OUT" | awk 'NR==1{print $1}')
    ARTICLES=$(echo "$OUT" | awk 'NR==1{print $2}')
    HAS_CONTENT=$(echo "$OUT" | awk 'NR==1{print $3}')
    TASK_JSON=$(echo "$OUT" | awk 'NR==2')
    eval "$(TASK_JSON="$TASK_JSON" python3 -c "
import json, os, shlex
try:
    r = json.loads(os.environ['TASK_JSON'])
    print('SYNC_TASK_NAME=' + shlex.quote(str(r[0])))
    print('SYNC_TASK_CRON=' + shlex.quote(str(r[1])))
    print('SYNC_TASK_STATUS=' + shlex.quote(str(r[2])))
except Exception:
    pass
")"
  }
fi

# ego 浏览器（CLI 存在 + 应用进程存活）
if [ -x "$HOME/.local/bin/ego-browser" ] && pgrep -f "ego lite.app/Contents" >/dev/null 2>&1; then E=OK; else E=DOWN; fi

# 磁盘可用（根卷 GB）与最近备份天数
DISK_GB=$(df -g / 2>/dev/null | awk 'NR==2{print $4}')
BK_DAYS=-1
NEWEST=$(ls -t "$WERSS_ROOT"/backups/werss-backup-*.tar.gz 2>/dev/null | head -1)
[ -n "$NEWEST" ] && BK_DAYS=$(( ( $(date +%s) - $(stat -f %m "$NEWEST") ) / 86400 ))

# 限流冷却（最近 1 小时 runner.log 有 search_throttled）
TH=no
if [ -f "$BATCH/runner.log" ]; then
  TH=$(python3 - "$BATCH/runner.log" <<'ENDPY'
import sys, re, datetime
now = datetime.datetime.now()
last = None
for line in open(sys.argv[1], encoding='utf-8', errors='ignore'):
    if 'search_throttled' in line:
        m = re.match(r'(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)', line)
        if m:
            try:
                t = datetime.datetime(now.year, int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4)), int(m.group(5)))
                if t > now: t = t.replace(year=now.year - 1)
                last = max(last, t) if last else t
            except Exception:
                pass
print('yes' if last and (now - last).total_seconds() < 3600 else 'no')
ENDPY
)
fi

# weread 授权
WR=UNKNOWN
if app_alive; then
  TOK=$(curl -s -m 10 -X POST "$WERSS_APP_URL/api/v1/wx/auth/login" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode "username=$WERSS_ADMIN_USER" \
      --data-urlencode "password=$WERSS_ADMIN_PASS" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('data',{}).get('access_token',''))" 2>/dev/null)
  if [ -n "$TOK" ]; then
    RESP=$(curl -s -m 10 -X POST "$WERSS_APP_URL/api/v1/wx/weread/test" -H "Authorization: Bearer $TOK" 2>/dev/null)
    echo "$RESP" | grep -qiE 'true|有效|success|"code":200' && WR=OK || WR=FAIL
  else
    WR=LOGINERR
  fi
fi

# 微信主授权探针（公众号搜索/添加通道，与微信读书是两个独立凭证）。
# 教训：2026-09-27 主授权 session 静默失效(invalid session 200003)，容器把错误吞成
# 空搜索结果，598 家公司被批量误标"未找到"而无任何告警——weread 有专门测试端点，
# 这条通道只能用小搜索探测：session 失效时容器返回 HTTP 201 + code 50001(请重新扫码授权)，
# 正常时 200 且带 list 字段（空 list 也是 OK，只判 session 不判结果）。
# 菜单栏每 30 秒拉一次 status.sh，这里按 10 分钟节流真探，其余时候读缓存值。
WX=UNKNOWN
if app_alive; then
  if [ -z "$TOK" ]; then
    WX=UNKNOWN
  elif [ $(( $(date +%s) - $(cat "$LOGS/.wx_probe_at" 2>/dev/null || echo 0) )) -lt 600 ]; then
    WX=$(cat "$LOGS/.wx_probe_cache" 2>/dev/null || echo UNKNOWN)
  else
    KW=$(python3 - "$BATCH/canary_pool.json" "$LOGS/.wx_probe_idx" <<'PY'
import json, os, sys
pool = json.load(open(sys.argv[1], encoding="utf-8"))
idx = int(open(sys.argv[2]).read().strip() or 0) if os.path.exists(sys.argv[2]) else 0
open(sys.argv[2], "w").write(str((idx + 1) % len(pool)))
print(pool[idx % len(pool)])
PY
)
    ENC=$(python3 -c "import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))" "$KW")
    WX_RESP=$(curl -s -m 15 "$WERSS_APP_URL/api/v1/wx/mps/search/$ENC?offset=0&limit=1" \
        -H "Authorization: Bearer $TOK" 2>/dev/null)
    if echo "$WX_RESP" | grep -q '"list"'; then
      WX=OK
    elif echo "$WX_RESP" | grep -qE '50001|重新扫码'; then
      WX=EXPIRED
    else
      WX=UNKNOWN
    fi
    date +%s > "$LOGS/.wx_probe_at"
    echo "$WX" > "$LOGS/.wx_probe_cache"
  fi
fi

# 跟踪主授权扫码时刻：仅 EXPIRED→恢复(OK) 时写入（UNKNOWN→OK 不算扫码），与 weread 同款
WX_STATE_FILE="$LOGS/.wx_state"
WX_OK_AT_FILE="$LOGS/.wx_ok_at"
PREV_WX=$(cat "$WX_STATE_FILE" 2>/dev/null || echo "UNKNOWN")
if [ "$WX" = "OK" ] && [ "$PREV_WX" = "EXPIRED" ]; then
  date +%s > "$WX_OK_AT_FILE"
fi
echo "$WX" > "$WX_STATE_FILE"
WX_OK_AT=$(cat "$WX_OK_AT_FILE" 2>/dev/null || echo "-1")

# 跟踪扫码时刻：仅在授权真正失效(FAIL/LOGINERR)后恢复(OK)时写入，即"刚扫码"；
# UNKNOWN→OK（应用/容器重启但授权本来就有效）不算扫码，不刷新时间
WR_STATE_FILE="$LOGS/.weread_state"
WR_OK_AT_FILE="$LOGS/.weread_ok_at"
PREV_WR=$(cat "$WR_STATE_FILE" 2>/dev/null || echo "UNKNOWN")
if [ "$WR" = "OK" ] && { [ "$PREV_WR" = "FAIL" ] || [ "$PREV_WR" = "LOGINERR" ]; }; then
  date +%s > "$WR_OK_AT_FILE"   # 仅失效→恢复（=扫码）时记录
fi
echo "$WR" > "$WR_STATE_FILE"
WR_OK_AT=$(cat "$WR_OK_AT_FILE" 2>/dev/null || echo "-1")

if [ "$MODE" = "--parse" ]; then
  cat <<EOF
docker=$D
container=$C
app=$A
runner=$R
slice=$SLICE
csv_added=$CSV_ADDED
csv_notfound=$CSV_NOTFOUND
csv_pending=$CSV_PENDING
feeds=$FEEDS
articles=$ARTICLES
has_content=$HAS_CONTENT
sync_task_name=$SYNC_TASK_NAME
sync_task_cron=$SYNC_TASK_CRON
sync_task_status=$SYNC_TASK_STATUS
weread=$WR
weread_ok_at=$WR_OK_AT
wx_auth=$WX
wx_ok_at=$WX_OK_AT
ego=$E
disk_gb=$DISK_GB
backup_days=$BK_DAYS
throttled=$TH
EOF
  exit 0
fi

echo "$D $C $A $R | slice剩余$SLICE | CSV 已添加$CSV_ADDED/未找到$CSV_NOTFOUND/待处理$CSV_PENDING | 订阅$FEEDS 文章$ARTICLES 有正文$HAS_CONTENT"
[ "$WR" = "OK" ] && echo "weread授权:OK" || echo "weread授权:$WR(需扫码)"
[ "$WX" = "OK" ] && echo "微信主授权:OK" || echo "微信主授权:$WX(公众号搜索/添加不可用,需扫码)"
echo "ego:$E 磁盘可用:${DISK_GB}G 最近备份:${BK_DAYS}天前 限流:$TH"
echo "文章同步任务:${SYNC_TASK_NAME:-未配置} cron:${SYNC_TASK_CRON:-?} ${SYNC_TASK_STATUS:+状态:$SYNC_TASK_STATUS}"
