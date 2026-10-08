#!/bin/bash
# 重建 WERSS菜单栏.app（改 src/menubar_app.swift / src/review_ui.swift 后运行；新机无需，仓库带已编译二进制）
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/WERSS菜单栏.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/main" "$ROOT/src/menubar_app.swift" "$ROOT/src/review_ui.swift" "$ROOT/src/logs_ui.swift"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
codesign --verify --deep --strict "$APP" >/dev/null 2>&1 && echo "构建+签名 ✓ ($APP)"

# 应用在运行则经 launchctl 原子重启(杀旧+拉新;KeepAlive 只在崩溃时拉起,正常退出不会再自动起来)。
# 切勿用 open -a 手动重启:会与 launchd 拉起撞出双实例(2026-10-04 事故;应用内另有 pid 守卫兜底)。
# 注:二进制刚替换后首次拉起可能被签名校验拦掉,launchd 会自动重试,故下方轮询等待进程就绪。
LABEL="com.werss.menubar"
# 必须按**进程**判定，不能只看 launchctl print：任务常驻加载着，用户主动退出后
# launchctl print 照样成功，但进程已经不在——此时 kickstart 会把用户刚退掉的图标
# 硬拉回来，并连带恢复 runner/容器，与「退出=服务全停」规则相悖(2026-10-08 实测)。
if ! pgrep -f "WERSS菜单栏.app/Contents/MacOS/main" >/dev/null 2>&1; then
  echo "菜单栏未在运行（用户已退出）→ 仅重建二进制，不拉起（要恢复: launchctl kickstart gui/$(id -u)/${LABEL}）"
  exit 0
fi
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$(id -u)/$LABEL"
  for i in $(seq 1 15); do
    sleep 2
    pgrep -f "WERSS菜单栏.app/Contents/MacOS/main" >/dev/null 2>&1 && { echo "已重启菜单栏 ✓"; exit 0; }
  done
  echo "警告:菜单栏进程 30s 内未就绪,请查看 launchctl print gui/\$(id -u)/$LABEL"
fi
