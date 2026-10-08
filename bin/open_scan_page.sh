#!/bin/bash
# 直达扫码页：用 ego 浏览器自动登录并翻到扫码页，然后把 ego 窗口带到前台。
# 由 WERSS控制台.app / 菜单栏调用；也可手动运行。
#   无参数    → 微信读书授权页 /weread（文章正文通道）
#   --wx      → 授权管理页 /wechat-status（微信主授权，公众号搜索/添加通道）
# 设计：绝不让用户面对登录页——默认浏览器没有登录态（登录后也不会跳回扫码页，
# 且不动原仓库），所以一律走 ego 自动登录；ego 彻底失败才退默认浏览器并给菜单指引。
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

if [ "${1:-}" = "--wx" ]; then
  TEMPLATE="$BATCH/open_scan_wx.js.template"
  PAGE_PATH="/wechat-status"
else
  TEMPLATE="$BATCH/open_scan.js.template"
  PAGE_PATH="/weread"
fi

GEN="$BATCH/open_scan.js"
sed -e "s|__W__|$BATCH|g" -e "s|__APP_URL__|$WERSS_APP_URL|g" \
    -e "s|__ADMIN_USER__|$WERSS_ADMIN_USER|g" -e "s|__ADMIN_PASS__|$WERSS_ADMIN_PASS|g" \
    "$TEMPLATE" > "$GEN"

# 与采集 worker 共用同一把目录锁（ego 并发竞争会返回空结果）
LOCKD="$BATCH/browser.lock.d"
T0=$(date +%s)
until mkdir "$LOCKD" 2>/dev/null; do
  # 超10分钟的锁视为死锁残留
  [ $(( $(date +%s) - $(stat -f %m "$LOCKD" 2>/dev/null || date +%s) )) -gt 600 ] && rmdir "$LOCKD" 2>/dev/null
  [ $(( $(date +%s) - T0 )) -gt 90 ] && break
  sleep 2
done

OUT_FULL=$(with_timeout 90 ego-browser nodejs < "$GEN" 2>&1); RC=$?
[ -z "$OUT_FULL" ] && { sleep 5; OUT_FULL=$(with_timeout 90 ego-browser nodejs < "$GEN" 2>&1); RC=$?; }
OUT=$(printf '%s' "$OUT_FULL" | tail -1)
rmdir "$LOCKD" 2>/dev/null
rm -f "$GEN"
echo "$(date '+%m-%d %H:%M:%S') rc=$RC out=${OUT_FULL:0:120}" >> "$LOGS/open_scan.log"

TARGET=$([ "$PAGE_PATH" = "/wechat-status" ] && echo "公众号主授权" || echo "微信读书")

if echo "$OUT_FULL" | grep -q "SCAN_PAGE_READY"; then
  open -a "ego lite" 2>/dev/null   # 把扫码窗口带到前台
  log "[open_scan] 扫码页已在前台 ($PAGE_PATH)"
  python3 "$WERSS_ROOT/bin/ev.py" log scan state=open "${TARGET}扫码页已打开,等待扫码" >/dev/null 2>&1 || true
else
  # 兜底：默认浏览器直达目标页（未登录会自动跳登录页并带 redirect=参数，
  # 登录成功后自动跳回本页——原仓库自带能力，无需改动）。ego 故障时才走此路。
  open "$WERSS_APP_URL$PAGE_PATH" 2>/dev/null
  notify_now "请两步完成扫码" "第1步 登录（账密 $WERSS_ADMIN_USER / $WERSS_ADMIN_PASS），登录后自动跳回本页；第2步 点页面「扫码授权」出二维码"
  log "[open_scan] ego 失败，已用默认浏览器兜底（两步指引已推送）"
  python3 "$WERSS_ROOT/bin/ev.py" log scan state=open "${TARGET}扫码页已打开(默认浏览器兜底),等待扫码" >/dev/null 2>&1 || true
fi
