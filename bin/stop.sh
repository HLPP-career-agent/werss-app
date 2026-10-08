#!/bin/bash
# 停止本项目全部服务：采集 runner + we-mp-rss 容器。
#
# 语义（2026-10-08 用户定规则）：菜单栏「退出菜单栏」= 这件事相关的服务都不再需要，
# 故 quit() 会派发本脚本。数据全部保留：compose stop 只停不删，数据在 bind mount。
# **不碰 Docker Desktop**——同机还有 hlpp-analytics / neststack 等容器在跑，与本项目无关。
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

log "[stop] 停止 runner…"
if stop_runner; then
  log "[stop] runner 已停"
else
  log "[stop] runner 停止超时（可能仍在收尾，稍后自行退出）"
  # 停不掉是用户回来后看得见的待办：留 alert-state，菜单栏启动即会显示并可点修复。
  echo fail > "$LOGS/.alert-state-stoprunner"
fi

log "[stop] 停止容器（优雅退出，最多等 30s；compose.yml 已设 stop_grace_period）…"
if compose stop; then
  log "[stop] 容器已停"
else
  log "[stop] 容器停止失败"
  echo fail > "$LOGS/.alert-state-stopcontainer"
fi

# ---- 收尾：把"主动停机"留下的运行时状态清干净，别让下次启动误读 ----
# 1) keepalive 失败计数：主动停机不是故障。不清的话会一路累加，
#    下次启动三次就触发"连续 N 次异常"假告警。
echo 0 > "$LOGS/keepalive_fails"
# 2) 停服告警自清：本次成功就把上次写的停服告警抹掉，否则它会永久残留
#    （notify_important 只有 fail 路径，清除只能靠显式 alert_clear）。
[ -f "$LOGS/.alert-state-stoprunner" ]    && ! runner_alive && alert_clear stoprunner
[ -f "$LOGS/.alert-state-stopcontainer" ] && ! container_up && alert_clear stopcontainer
# 2) 无主的 flock 文件：内核在进程退出时自动释放锁，文件本身残留无害但会误导排查。
#    只在没有进程持有时才删（正在跑就绝不碰）。
if ! runner_alive; then
  rm -f "$BATCH/browser.lock" "$BATCH/mp_match_ledger.json.lock" 2>/dev/null
  rm -f "$WERSS_ROOT/data/jobs_review.lock" 2>/dev/null
fi
# 3) 停机事件进事件日志（菜单栏「全量日志」可见）：用户回来能对上时间线。
python3 "$WERSS_ROOT/bin/ev.py" log runner "菜单栏退出 → 已停止 runner 与 $WERSS_CONTAINER" >/dev/null 2>&1 || true

log "[stop] 完成（Docker Desktop 保持运行；如需彻底停 Docker 请手动退出）"
