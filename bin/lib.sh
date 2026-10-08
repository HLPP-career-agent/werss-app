#!/bin/bash
# 公共函数库：所有 bin/ 与 batch/ 脚本 source 本文件。
# 约定：source 前 cd 到任意位置均可，路径全部由本文件推导。

# 应用根目录 = lib.sh 所在目录的上一级
WERSS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WERSS_ROOT

# 读取配置：先加载模板默认值，再用本机 config.env 覆盖（两处均用 ${VAR:-默认}，
# 因此环境变量临时覆盖依然生效；config.env 缺失时仅用模板也能跑）
set -a
. "$WERSS_ROOT/config.example.env"
[ -f "$WERSS_ROOT/config.env" ] && . "$WERSS_ROOT/config.env"
set +a

# PATH 补全：launchd 代理环境只有 /usr/bin:/bin:/usr/sbin:/sbin，
# 需补 docker(/usr/local/bin) 与 ego-browser(~/.local/bin)；Homebrew 路径一并补上
export PATH="/usr/local/bin:/opt/homebrew/bin:$HOME/.local/bin:$PATH"
# locale 补全：launchd/无头环境 LANG 为空时，osascript/中文参数会乱码，必须显式 UTF-8
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

BATCH="$WERSS_ROOT/batch"
LOGS="$WERSS_ROOT/logs"
CSV_PATH="${WERSS_CSV:-$WERSS_ROOT/companies.csv}"
mkdir -p "$LOGS"

log() { echo "$(date '+%m-%d %H:%M:%S') $*"; }

# 便携 timeout（macOS 无 GNU timeout，用 perl alarm 实现）：with_timeout <秒> <命令…>
with_timeout() {
  local secs="$1"; shift
  perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
}

# 底层通知发送：统一 osascript（macOS 通知归属「脚本编辑器」，稳定必达、任何环境可用）。
# 注意：此类通知点击会打开脚本编辑器——**通知只做信息提示**，动作入口是 WERSS控制台.app
# （双击/Dock 一键直达扫码页等）。历史教训：terminal-notifier 权限会被系统静默关死、
# 未签名自研组件拿不到权限弹窗，均不可靠，已弃用。
#   werss_notify "标题" "副标题" "正文" "声音(default/Glass/Sosumi)" "分组ID(仅记日志)"
werss_notify() {
  osascript -e "display notification \"${3:-}\" with title \"${1:-werss}\" subtitle \"${2:-}\" sound name \"${4:-Glass}\"" >/dev/null 2>&1 || true
  echo "$(date '+%m-%d %H:%M:%S') osascript ${5:-}" >> "$LOGS/notify.log"
}

# ---- 在场闸：菜单栏图标是整套系统唯一的"在场"信号 ----
# 菜单栏不在 = 用户主动退出（launchd KeepAlive SuccessfulExit=false，不会自己回来）。
# 此时任何后台通知/自动恢复都是"用户感知不到"的：状态在面板里看不见，
# 用户只会收到一条无入口的横幅 → 感知为缺陷而不是功能。所以一律静默。
menubar_present() { pgrep -f "WERSS菜单栏.app/Contents/MacOS/main" >/dev/null 2>&1; }

# macOS 通知（右上角横幅+声音；信息提示，操作请用 WERSS控制台.app）
# **后台/自治**通知：受在场闸约束，菜单栏不在则静默落日志。
#   notify "标题" "正文"
notify() {
  if menubar_present; then
    werss_notify "werss" "${1:-}" "${2:-}" "Glass" "info"
  else
    echo "$(date '+%m-%d %H:%M:%S') [info-suppressed] ${1:-}" >> "$LOGS/notify.log"
  fi
}

# **用户亲手触发**的流程（双击控制台.app / 导入导出 / 安装 / 扫码页）：
# 用户就站在终端前等结果，属"感知得到"的反馈，不受在场闸约束。
#   notify_now "标题" "正文"
notify_now() {
  werss_notify "werss" "${1:-}" "${2:-}" "Glass" "info"
}

# 需要人介入的提醒：**永不自行发系统通知**，只落状态与日志。
# - 菜单栏在场：它每 30 秒自检 status.sh 并发可点击通知（自带 1800s 冷却，见
#   menubar_app.swift:594 notifyOnTransitions），这里只写 .alert-state-* 供
#   WERSS控制台.app 判断该开扫码页，避免重复轰炸。
# - 菜单栏不在场：整套静默，由 keepalive.sh 顶部的在场闸兜住。
# 历史教训：2026-10-08 用户反馈"菜单已退出，却每 31 分钟被 osascript 通知轰炸"，
#   根因就是本函数曾在菜单栏缺席时用 osascript 兜底推送——与"服务依附可见 UI"相反。
#   notify_important "状态键" "标题" "正文"
notify_important() {
  local key="$1" title="$2" where
  if menubar_present; then where="menubar-present(owned-by-menubar)"; else where="menubar-absent(silent)"; fi
  echo "$(date '+%m-%d %H:%M:%S') [alert:$key] $where $title" >> "$LOGS/notify.log"
  echo fail > "$LOGS/.alert-state-$key"
}

# 兼容旧调用
notify_action() {
  notify_important "$1" "$2" "$3"
}

# 异常恢复后清除状态（下次再出问题会重新触发控制台分发）
alert_clear() { rm -f "$LOGS/.alert-state-$1" 2>/dev/null; }

# 所有 docker 调用加超时：引擎半卡死时 CLI 可能无限挂起，不能拖死保活
docker_ok() { with_timeout 30 docker info >/dev/null 2>&1; }

app_alive() {
  curl -s -o /dev/null -m 5 -w '%{http_code}' "$WERSS_APP_URL/" 2>/dev/null | grep -q '^200$'
}

# 等应用 HTTP 200，最多 $1 秒（默认 300）
wait_app() {
  local deadline=$(( $(date +%s) + ${1:-300} ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    app_alive && return 0
    sleep 10
  done
  return 1
}

container_up() {
  [ "$(with_timeout 30 docker ps --filter "name=^$WERSS_CONTAINER$" --format '{{.Names}}' 2>/dev/null)" = "$WERSS_CONTAINER" ]
}

runner_pid() { pgrep -f "bash .*run_forever.sh" | head -1; }
runner_alive() { pgrep -f "bash .*run_forever.sh" >/dev/null 2>&1; }

# 剩余待采集条数（slice1/2/3 总行数）
slice_remaining() {
  local n=0 f
  for f in "$BATCH"/slice[123].jsonl; do
    [ -f "$f" ] && n=$(( n + $(wc -l < "$f" | tr -d ' ') ))
  done
  echo "$n"
}

# 停 runner（含正在跑的 worker），用于导出/导入/停机
stop_runner() {
  pkill -f "bash .*run_forever.sh" 2>/dev/null
  pkill -f "python3 .*process_chunk.py" 2>/dev/null
  local i=0
  while (runner_alive || pgrep -f "python3 .*process_chunk.py" >/dev/null 2>&1) && [ $i -lt 30 ]; do
    sleep 2; i=$((i+1))
  done
  runner_alive && return 1 || return 0
}

# 拉起 runner（仅当还有剩余任务）
start_runner() {
  if runner_alive; then log "[runner] 已在运行 (pid $(runner_pid))"; return 0; fi
  if [ "$(slice_remaining)" -eq 0 ]; then log "[runner] 无剩余任务，不启动"; return 0; fi
  ( cd "$BATCH" && nohup bash run_forever.sh > runner.log 2>&1 < /dev/null & )
  sleep 3
  runner_alive && log "[runner] 已启动 (pid $(runner_pid))" || { log "[runner] 启动失败"; return 1; }
}

compose() {
  with_timeout 300 docker compose --env-file "$WERSS_ROOT/config.env" -f "$WERSS_ROOT/docker-compose.yml" "$@"
}

# Docker 守护进程保活：软恢复(open)无效说明引擎卡死，升级硬恢复(退出重开 Docker Desktop)。
# 今天实测引擎会半卡死（进程在、socket 无响应、docker info 挂起），只能退出重开救回。
ensure_docker() {
  docker_ok && return 0
  log "[docker] 守护进程未就绪，软恢复: open -a Docker…"
  open -a Docker 2>/dev/null
  local i=0
  until docker_ok || [ $i -ge 12 ]; do sleep 10; i=$((i+1)); done
  docker_ok && { log "[docker] 软恢复成功"; return 0; }
  log "[docker] 软恢复无效（引擎卡死），硬恢复: 退出并重开 Docker Desktop…"
  osascript -e 'quit app "Docker"' 2>/dev/null
  sleep 8
  i=0
  while pgrep -f com.docker.backend >/dev/null 2>&1 && [ $i -lt 24 ]; do sleep 5; i=$((i+1)); done
  pkill -f com.docker.backend 2>/dev/null; sleep 3
  open -a Docker 2>/dev/null
  i=0
  until docker_ok || [ $i -ge 30 ]; do sleep 10; i=$((i+1)); done
  docker_ok && { log "[docker] 硬恢复成功"; return 0; }
  return 1
}

# 统一启动：Docker → 容器 → 等健康 → runner
ensure_stack() {
  # 1. Docker 守护进程（软→硬恢复）
  if ! ensure_docker; then
    notify_important docker "Docker 未恢复" "Docker Desktop 软/硬恢复均失败，需人工检查"
    return 1
  fi
  # 2. 容器
  if ! container_up; then
    log "[容器] 未运行，compose up…"
    compose up -d || return 1
    log "[容器] 等待应用就绪（首次初始化约 2 分钟）…"
    wait_app 300 || { notify_important app "应用未就绪" "容器已启动但 5 分钟内 HTTP 未恢复，查看 docker logs $WERSS_CONTAINER"; return 1; }
  fi
  # 3. runner
  start_runner
}
