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

echo "$(date '+%m-%d %H:%M:%S') [runner] 启动无限循环"
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
    echo "$(date '+%m-%d %H:%M:%S') [runner] slice$n → $(echo "$OUT" | grep -E "ABORT|CHUNK_DONE|SLICE_DONE|已添加|未找到" | tail -1)"
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
    if echo "$OUT" | grep -q "search_throttled"; then
      echo "$(date '+%m-%d %H:%M:%S') [runner] 检测到限流,冷却40分钟"
      sleep 2400
    fi
    # 正常轮转间隔 90-180 秒
    SLEEP=$((90 + RANDOM % 90))
    sleep $SLEEP
  done
  if [ $all_done -eq 1 ]; then
    echo "$(date '+%m-%d %H:%M:%S') [runner] 全部切片完成,退出"
    break
  fi
done
echo "$(date '+%m-%d %H:%M:%S') [runner] 结束"
