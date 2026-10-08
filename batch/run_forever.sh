#!/bin/bash
# 账号批量添加的无值守循环:不依赖任何 agent,直接跑驱动脚本
# 路径与配置来自 ../config.env（由 lib.sh 推导）
. "$(cd "$(dirname "$0")/.." && pwd)/bin/lib.sh"
cd "$BATCH"

# 单实例守卫:keepalive 自动拉起与手动重启可能撞出双循环，双 runner 会并发处理
# 同一 slice（重复处理 + write_slice 互相覆盖队列）。目录锁 + 10 分钟陈旧残留清理。
LOCKD="$BATCH/runner.lock.d"
if ! mkdir "$LOCKD" 2>/dev/null; then
  if [ $(( $(date +%s) - $(stat -f %m "$LOCKD" 2>/dev/null || date +%s) )) -gt 600 ]; then
    rmdir "$LOCKD"   # 超过 10 分钟视为死循环残留
    mkdir "$LOCKD" || { echo "[runner] 守卫锁仍被占用,退出"; exit 1; }
  else
    echo "$(date '+%m-%d %H:%M:%S') [runner] 已有实例在运行,退出"
    exit 0
  fi
fi
trap 'rmdir "$LOCKD" 2>/dev/null' EXIT

# 长冷却期间必须保活实例锁:否则锁 mtime 超过 600s 会被下方守卫当作残留清掉,
# 菜单栏/keepalive 就能在本实例还活着时再拉起第二个 runner(实测发生过)。
# 锁消失 = 已被其他实例接管,本实例立即退出。
cool_down() {
  local secs=$1 i=0
  while [ "$i" -lt "$secs" ]; do
    sleep 30; i=$((i+30))
    [ -d "$LOCKD" ] || exit 0
    touch "$LOCKD" 2>/dev/null || exit 0
  done
}

echo "$(date '+%m-%d %H:%M:%S') [runner] 启动无限循环"
python3 "$WERSS_ROOT/bin/ev.py" log runner "runner 启动" >/dev/null 2>&1 || true
while true; do
  all_done=1
  for n in 1 2 3; do
    if [ ! -s slice$n.jsonl ]; then
      echo "$(date '+%m-%d %H:%M:%S') [runner] slice$n 已完成,跳过"
      continue
    fi
    all_done=0
    # 清理页面预算(防 ego taskSpace 页面数上限)
    if [ -f space$n.id ]; then
      python3 cleanup_space.py space$n.id >/dev/null 2>&1
    fi
    OUT=$(python3 process_chunk.py slice$n.jsonl $n 2>&1)
    echo "$(date '+%m-%d %H:%M:%S') [runner] slice$n → $(echo "$OUT" | grep -E "ABORT|CHUNK_DONE|SLICE_DONE|已添加|未找到|待复核" | tail -1)"
    if echo "$OUT" | grep -q "PageBudgetError"; then
      echo "$(date '+%m-%d %H:%M:%S') [runner] 页面预算满,清理后重试"
      python3 cleanup_space.py space$n.id 2>&1 | grep CLEANED
      sleep 10
      OUT=$(python3 process_chunk.py slice$n.jsonl $n 2>&1 | tail -3)
      echo "$(date '+%m-%d %H:%M:%S') [runner] slice$n 重试 → $(echo "$OUT" | head -1)"
    fi
    if echo "$OUT" | grep -q "SLICE_DONE"; then
      continue
    fi
    # 冷却分类:只有微信侧真限流才长冷却。
    # env_* 是本机环境故障(we-mp-rss 登录失败/数据库挂/页面结构变),退避无意义,
    # 5 分钟后重试即可 —— 关键是别把它们当限流,否则日志会指向错误方向,还会白等几小时。
    if echo "$OUT" | grep -q "search_throttled"; then
      echo "$(date '+%m-%d %H:%M:%S') [runner] 检测到限流,冷却40分钟"
      cool_down 2400
    fi
    if echo "$OUT" | grep -qE "env_login_failed|env_broken|env_auth_expired"; then
      echo "$(date '+%m-%d %H:%M:%S') [runner] ⚠ 环境异常(非限流),见下方 reason 字段,5分钟后重试"
      cool_down 300
    fi
    if echo "$OUT" | grep -q "ai_unavailable"; then
      echo "$(date '+%m-%d %H:%M:%S') [runner] AI判断不可用,冷却10分钟"
      cool_down 600
    fi
    # 正常轮转间隔 90-180 秒
    SLEEP=$((90 + RANDOM % 90))
    sleep $SLEEP
  done
  if [ $all_done -eq 1 ]; then
    echo "$(date '+%m-%d %H:%M:%S') [runner] 全部切片完成,退出"
    python3 "$WERSS_ROOT/bin/ev.py" log runner "全部切片完成,退出" >/dev/null 2>&1 || true
    break
  fi
done
echo "$(date '+%m-%d %H:%M:%S') [runner] 结束"
