#!/bin/bash
# 30 分钟保活：Docker → 容器 → runner → 快检 → 需要人时发 macOS 系统通知。
# 由 launchd（com.werss.keepalive）每 30 分钟调用，也可手动执行。带并发锁。
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

LOCK="$WERSS_ROOT/.keepalive.lock.d"
if ! mkdir "$LOCK" 2>/dev/null; then
  # 已有实例在跑；超过 40 分钟视为残留
  if [ $(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || date +%s) )) -gt 2400 ]; then
    rmdir "$LOCK" 2>/dev/null
  else
    echo "$(date '+%m-%d %H:%M:%S') [keepalive] 上一轮仍在进行，跳过"
    exit 0
  fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

STATE="$LOGS/keepalive_fails"
FAILS=$(cat "$STATE" 2>/dev/null || echo 0)
ok=1

# ---- 1. Docker 守护进程（软→硬恢复，见 lib.sh:ensure_docker）----
if ! docker_ok; then
  log "[keepalive] Docker 守护进程未就绪，尝试恢复…"
  if ensure_docker; then
    log "[keepalive] Docker 已恢复"
  else
    notify_important docker "Docker 未恢复" "Docker Desktop 软/硬恢复均失败，需人工检查"
    echo $(( FAILS + 1 )) > "$STATE"; exit 1
  fi
fi

# ---- 2. 容器 ----
if ! container_up; then
  log "[keepalive] 容器未运行，拉起…"
  compose up -d
  log "[keepalive] 等待应用 HTTP 就绪（初始化约 2 分钟）…"
  if wait_app 300; then
    log "[keepalive] 容器已恢复"
  else
    notify_important app "应用未就绪" "容器已启动但 5 分钟未就绪，请看 docker logs $WERSS_CONTAINER"
    docker logs --tail 30 "$WERSS_CONTAINER" >> "$LOGS/keepalive.log" 2>&1
    echo $(( FAILS + 1 )) > "$STATE"; exit 1
  fi
fi

# ---- 3. 采集 runner ----
if runner_alive; then
  :
elif [ "$(slice_remaining)" -gt 0 ]; then
  log "[keepalive] runner 未运行且还有 $(slice_remaining) 条任务，拉起…"
  start_runner
  sleep 60
  if ! runner_alive; then
    notify "werss 保活" "runner 拉起失败，请查看 $BATCH/runner.log"
    ok=0
  fi
else
  log "[keepalive] 无剩余任务，runner 保持停止"
fi

# ---- 4. 快检：weread 授权（状态刚失效时自动打开一次扫码页，之后只提醒）----
if app_alive; then
  TOK=$(curl -s -m 10 -X POST "$WERSS_APP_URL/api/v1/wx/auth/login" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode "username=$WERSS_ADMIN_USER" \
      --data-urlencode "password=$WERSS_ADMIN_PASS" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('data',{}).get('access_token',''))" 2>/dev/null)
  if [ -n "$TOK" ]; then
    WR=$(curl -s -m 10 -X POST "$WERSS_APP_URL/api/v1/wx/weread/test" -H "Authorization: Bearer $TOK" 2>/dev/null)
    if ! echo "$WR" | grep -qiE 'true|有效|success|"code":200'; then
      log "[keepalive] weread 授权疑似失效，发提醒"
      notify_important weread "微信读书授权失效，请扫码" \
        "文章正文采集暂停（账号添加不受影响）。处理：双击 WERSS控制台.app 一键直达扫码页（自动登录）。登录账密：$WERSS_ADMIN_USER / $WERSS_ADMIN_PASS"
    else
      alert_clear weread
    fi
    # 微信主授权（公众号搜索/添加通道）——与 weread 是两个独立 session；
    # 失效时搜索接口把错误吞成空结果，批量添加会静默误标"未找到"（2026-09-27 事故）
    WXRESP=$(curl -s -m 15 "$WERSS_APP_URL/api/v1/wx/mps/search/%E8%B4%B5%E5%B7%9E%E8%8C%85%E5%8F%B0?offset=0&limit=1" \
        -H "Authorization: Bearer $TOK" 2>/dev/null)
    if echo "$WXRESP" | grep -q '"list"'; then
      alert_clear wxauth
    elif echo "$WXRESP" | grep -qE '50001|重新扫码'; then
      log "[keepalive] 微信主授权失效，发提醒"
      notify_important wxauth "微信授权失效，公众号搜索/添加已停" \
        "批量添加已暂停（金丝雀自动拦截，台账零污染）。处理：菜单栏「微信授权待扫码」直达授权页，或运行 bin/open_scan_page.sh --wx"
    fi
  else
    log "[keepalive] 管理端登录失败（检查 config.env 凭据）"
    notify_important login "管理端登录失败" "请检查 config.env 的 WERSS_ADMIN_USER / WERSS_ADMIN_PASS"
  fi
else
  log "[keepalive] 应用未响应（容器标记 Up 但 HTTP 不通）"
  ok=0
fi

# ---- 4.5 招聘帖扫描（规则粗筛 + MiniMax 精判，见 bin/jobs.py；新帖 → 菜单栏 ● 提醒）----
if [ -f "$WERSS_ROOT/data/db.db" ]; then
  python3 "$WERSS_ROOT/bin/jobs.py" scan --quiet >> "$LOGS/jobs_scan.log" 2>&1 || true
fi

# ---- 5. 每日一次自动更新检查（GitHub Release，见 bin/update.sh）----
if [ "$(date +%F)" != "$(cat "$LOGS/.last-update-check" 2>/dev/null)" ]; then
  date +%F > "$LOGS/.last-update-check"
  bash "$WERSS_ROOT/bin/update.sh" >> "$LOGS/update.log" 2>&1 || true
fi

# ---- 6. 汇总 ----
if [ $ok -eq 1 ]; then
  echo 0 > "$STATE"
  echo "$(date '+%m-%d %H:%M:%S') [keepalive] 正常 docker:OK 容器:UP app:OK runner:$(runner_alive && echo UP || echo 停) slice剩余:$(slice_remaining)"
else
  FAILS=$(( FAILS + 1 )); echo "$FAILS" > "$STATE"
  if [ "$FAILS" -ge 3 ]; then
    notify_important fails3 "连续 ${FAILS} 次异常" "自动恢复失败，需要人工介入（详见 logs/ 与 batch/runner.log）"
  fi
  exit 1
fi
