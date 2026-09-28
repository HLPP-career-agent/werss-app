#!/bin/bash
# 文章同步频率快速设置：通过 we-mp-rss 官方 REST API 修改「定时采集任务」的 cron 表达式。
# 与网页端「任务管理」页完全同一组接口（登录 → PUT 任务 → PUT job/fresh 重载调度器），
# 不改容器内程序、不直接写数据库，符合"只按原程序设计的能力调整"的原则。
# 用法:
#   article_sync_cron.sh get                 查看现状（task_id/cron/name/status）
#   article_sync_cron.sh set <cron> <任务名>  修改第一个定时任务的 cron 并重载生效
# 示例:
#   article_sync_cron.sh set "0 */6 * * *" "每6小时全量更新"
set -e
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

API="$WERSS_APP_URL/api/v1/wx"

# 登录拿 token（与 status.sh 的 weread 探测同一账号体系）
TOK=$(curl -s -m 15 -X POST "$API/auth/login" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "username=$WERSS_ADMIN_USER" \
    --data-urlencode "password=$WERSS_ADMIN_PASS" 2>/dev/null \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('data',{}).get('access_token',''))" 2>/dev/null)
[ -n "$TOK" ] || { echo "ERR 登录失败（$WERSS_APP_URL）"; exit 1; }

case "${1:-}" in
  get)
    curl -s -m 15 "$API/message_tasks" -H "Authorization: Bearer $TOK" | python3 -c "
import sys, json
tasks = json.load(sys.stdin).get('data', {}).get('list', [])
t = tasks[0] if tasks else {}
print('task_id=' + str(t.get('id', '')))
print('cron=' + str(t.get('cron_exp', '')))
print('name=' + str(t.get('name', '')))
print('status=' + str(t.get('status', '')))
"
    ;;
  set)
    CRON="${2:-}"; NAME="${3:-}"
    [ -n "$CRON" ] && [ -n "$NAME" ] || { echo "ERR 用法: $0 set <cron> <任务名>"; exit 1; }
    LIST=$(curl -s -m 15 "$API/message_tasks" -H "Authorization: Bearer $TOK")
    TASK_ID=$(printf '%s' "$LIST" | python3 -c "import sys,json;d=json.load(sys.stdin).get('data',{}).get('list',[]);print(d[0]['id'] if d else '')")
    [ -n "$TASK_ID" ] || { echo "ERR 未找到定时任务"; exit 1; }
    # PUT 需要完整任务对象（网页端同款）：取现有任务整体回填，仅替换 cron_exp 与 name
    PAYLOAD=$(printf '%s' "$LIST" | CRON="$CRON" NAME="$NAME" python3 -c "
import sys, json, os
t = json.load(sys.stdin)['data']['list'][0]
t['cron_exp'] = os.environ['CRON']
t['name'] = os.environ['NAME']
print(json.dumps(t, ensure_ascii=False))
")
    RESP=$(curl -s -m 15 -X PUT "$API/message_tasks/$TASK_ID" -H "Authorization: Bearer $TOK" \
        -H 'Content-Type: application/json' -d "$PAYLOAD")
    echo "$RESP" | grep -q '"code":0' || { echo "ERR 更新失败: $RESP"; exit 1; }
    # 官方重载：让运行中的调度器立即按新 cron 生效（不用重启容器）
    RESP=$(curl -s -m 15 -X PUT "$API/message_tasks/job/fresh" -H "Authorization: Bearer $TOK")
    echo "$RESP" | grep -q '"code":0' || { echo "ERR 重载失败: $RESP"; exit 1; }
    echo "OK cron=$CRON name=$NAME"
    ;;
  *)
    echo "用法: $0 get | set <cron> <任务名>"; exit 1;;
esac
