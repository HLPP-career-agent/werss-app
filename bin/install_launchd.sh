#!/bin/bash
# 安装/刷新 launchd：① 30分钟保活+登录自启 ② 菜单栏应用常驻（崩溃自动重启）。幂等。
#
# 注意（2026-09-29 修复）：旧版用 `launchctl load -w` / `unload`，这两个子命令在
# macOS 14+ 已是废弃路径，在 gui/$UID 域下会「返回 0 但实际没加载」。结果是 plist
# 文件在磁盘上、任务却不在 launchctl list 里，保活静默停摆（招聘帖扫描随之停 5 天）。
# 现在改用 bootout + bootstrap，并在最后做真实校验。
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

mkdir -p "$HOME/Library/LaunchAgents" "$LOGS"
UID_NUM=$(id -u)
FAILED=0

install_agent() {
  local label="$1" tmpl="$2" plist="$HOME/Library/LaunchAgents/$1.plist"
  sed "s|__ROOT__|$WERSS_ROOT|g" "$WERSS_ROOT/launchd/$tmpl" > "$plist"

  # bootout 对「未加载」和「不存在」都返回非 0，属正常，忽略
  launchctl bootout "gui/$UID_NUM/$label" >/dev/null 2>&1
  launchctl unload "$plist" >/dev/null 2>&1

  if ! launchctl bootstrap "gui/$UID_NUM" "$plist" 2>/dev/null; then
    # 已加载时 bootstrap 会报 37，属幂等成功
    if ! launchctl print "gui/$UID_NUM/$label" >/dev/null 2>&1; then
      echo "launchd $label 安装失败 ✗"
      FAILED=1
      return
    fi
  fi

  # 真校验：光看 bootstrap 退出码不够，必须确认任务确实在域里
  if launchctl print "gui/$UID_NUM/$label" >/dev/null 2>&1; then
    echo "launchd $label 已安装 ✓"
  else
    echo "launchd $label 安装失败 ✗（bootstrap 无报错但任务不在 launchctl 中）"
    FAILED=1
  fi
}

install_agent com.werss.keepalive com.werss.keepalive.plist.template
install_agent com.werss.menubar  com.werss.menubar.plist.template

# launchd 是招聘帖扫描的唯一触发源，装不上必须让人知道，不能静默带病运行
if [ "$FAILED" = "1" ]; then
  echo "警告：launchd 安装存在失败项，保活/扫描可能未运行；请执行 bin/keepalive.sh 手工验证。"
  exit 1
fi
exit 0
