#!/bin/bash
# 新机一键安装器（幂等，可重复运行）：Docker → ego lite → 镜像 → 自启+保活 → 数据(可选导入)
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# 生成本机配置（不入库；模板为 config.example.env，之后改配置只改 config.env）
if [ ! -f "$WERSS_ROOT/config.env" ] && [ -f "$WERSS_ROOT/config.example.env" ]; then
  cp "$WERSS_ROOT/config.example.env" "$WERSS_ROOT/config.env"
  echo "已生成本机配置 config.env"
fi

step() { echo; echo "==> $*"; }

echo "=============================================="
echo " werss-app 安装器  ($WERSS_ROOT)"
echo " 微信公众号采集系统 · 新机一键部署"
echo "=============================================="

# ---- 0. 平台检查 ----
step "0/6 平台检查"
if [ "$(uname -s)" != "Darwin" ]; then echo "仅支持 macOS"; exit 1; fi
if [ "$(uname -m)" != "arm64" ]; then
  echo "警告：当前为 $(uname -m) 芯片。本系统镜像为 arm64，Intel Mac 不在支持范围。"
  read -p "仍要继续吗? [y/N] " A; [ "$A" = "y" ] || exit 1
fi
echo "macOS arm64 ✓"

# ---- 1. Docker Desktop ----
step "1/6 Docker Desktop"
if [ -d /Applications/Docker.app ] || [ -d "$HOME/Applications/Docker.app" ]; then
  echo "已安装 ✓"
else
  echo "未安装，开始自动安装（约 500MB 下载）…"
  if command -v brew >/dev/null 2>&1; then
    brew install --cask docker
  else
    DMG="/tmp/Docker.dmg"
    if curl -fL --retry 3 -o "$DMG" "https://desktop.docker.com/mac/main/arm64/Docker.dmg"; then
      hdiutil attach "$DMG" -nobrowse -readonly -mountpoint /tmp/DockerMnt >/dev/null
      cp -R /tmp/DockerMnt/Docker.app /Applications/ 2>/dev/null || cp -R /tmp/DockerMnt/Docker.app "$HOME/Applications/"
      xattr -dr com.apple.quarantine /Applications/Docker.app "$HOME/Applications/Docker.app" 2>/dev/null
      hdiutil detach /tmp/DockerMnt >/dev/null 2>&1; rm -f "$DMG"
    else
      echo "自动下载失败，请手动安装后重跑本安装器："
      open "https://www.docker.com/products/docker-desktop/"
      exit 1
    fi
  fi
fi
if ! docker_ok; then
  echo "启动 Docker Desktop（首次启动若弹出协议/密码窗口请完成它）…"
  open -a Docker
  i=0; until docker_ok || [ $i -ge 40 ]; do sleep 15; i=$((i+1)); echo "  等待 Docker 引擎… ($((i*15))s)"; done
  docker_ok && echo "Docker 就绪 ✓" || { notify_important install "安装受阻" "Docker 引擎 10 分钟未就绪，请完成 Docker 首次启动设置后重新双击 安装.command"; exit 1; }
else
  echo "Docker 运行中 ✓"
fi

# ---- 2. ego lite 浏览器 ----
step "2/6 ego lite 浏览器"
EGO_OK=0
if [ -d "/Applications/ego lite.app" ] || [ -d "$HOME/Applications/ego lite.app" ]; then EGO_OK=1; fi
if [ $EGO_OK -eq 0 ]; then
  echo "未安装，自动下载安装（来源 cdn.ego.app）…"
  bash "$WERSS_ROOT/bin/install_ego.sh" || { echo "ego lite 安装失败，请手动安装后重跑"; exit 1; }
fi
export PATH="$HOME/.local/bin:$PATH"
if ! command -v ego-browser >/dev/null 2>&1; then
  echo
  echo "ego lite 已安装，但命令行还没注册——需要你完成一次首次设置："
  echo "  1) 稍等 ego lite 窗口打开（若没打开：open -a 'ego lite'）"
  echo "  2) 按引导完成 onboarding（会自动注册 ego-browser 命令）"
  echo
  open -a "ego lite" 2>/dev/null
  i=0; until command -v ego-browser >/dev/null 2>&1 || [ $i -ge 40 ]; do sleep 15; i=$((i+1)); echo "  等待 onboarding 完成… ($((i*15))s)"; done
  command -v ego-browser >/dev/null 2>&1 && echo "ego-browser 命令就绪 ✓" || { notify_important install "安装受阻" "ego lite onboarding 未完成，完成后重新双击 安装.command"; exit 1; }
else
  echo "ego-browser 命令就绪 ✓"
fi

# ---- 3. 拉取镜像 ----
step "3/6 Docker 镜像（约 4.3GB，视网速 10-30 分钟）"
if [ -f "$WERSS_ROOT/backups/werss-image.tar.gz" ]; then
  echo "检测到离线镜像包，直接本地导入…"
  docker load < "$WERSS_ROOT/backups/werss-image.tar.gz" && echo "镜像导入 ✓"
else
  docker pull "$WERSS_IMAGE" && echo "镜像就绪 ✓" || { notify_important install "安装受阻：镜像拉取失败" "请检查网络后重跑 安装.command"; exit 1; }
fi

# ---- 4. 开机自启 + 30 分钟保活 ----
step "4/6 开机自启与保活 (launchd)"
bash "$WERSS_ROOT/bin/install_launchd.sh"

# ---- 5. 数据（可选导入，走到这步停下说明价值）----
step "5/6 数据"
BK=""
for f in "$WERSS_ROOT"/backups/werss-backup-*.tar.gz "$WERSS_ROOT"/werss-backup-*.tar.gz; do
  [ -f "$f" ] && BK="$f"
done
echo
if [ -d "$WERSS_ROOT/data" ] && [ -f "$WERSS_ROOT/data/db.db" ]; then
  echo "本机已有数据（data/db.db 存在），跳过导入。如需更换数据请双击 交接导入.command。"
elif [ -n "$BK" ]; then
  echo "检测到备份包: $BK"
  echo "──────────────────────────────────────────────"
  echo " 导入 = 恢复之前机器上的全部工作成果："
  echo "   · 已订阅的公众号清单与文章库"
  echo "   · 剩余待采集的公司队列（从断点继续，不重采）"
  echo "   · 微信授权文件（可能仍需重新扫一次码）"
  echo " 跳过 = 从空白系统开始（原机器的成果不会跟过来）"
  echo "──────────────────────────────────────────────"
  read -p "现在导入这份备份吗? [Y/n] " A
  if [ "${A:-y}" = "y" ]; then
    bash "$WERSS_ROOT/bin/import.sh" "$BK"
  else
    echo "已跳过。以后随时双击 交接导入.command 补导。"
  fi
else
  echo "未检测到备份包。"
  echo "──────────────────────────────────────────────"
  echo " 备份包是旧机器工作成果的载体（已订阅公众号、文章库、"
  echo " 剩余采集队列、微信授权）。没有它，本机将从空白开始。"
  echo " 现在可以把备份包拖到 $WERSS_ROOT/backups/ 后重跑安装，"
  echo " 或以后随时双击 交接导入.command 补导。"
  echo "──────────────────────────────────────────────"
  read -p "也可以现在把备份包拖入本窗口再回车（直接回车=空白开始）: " DRAG
  DRAG="${DRAG//\'/}"
  if [ -n "$DRAG" ] && [ -f "$DRAG" ]; then
    bash "$WERSS_ROOT/bin/import.sh" "$DRAG"
  else
    echo "空白开始：初始化全新数据目录…"
    compose up -d && wait_app 600 && echo "应用已就绪 ✓（默认账号见 config.env）"
  fi
fi

# ---- 6. 完成 ----
step "6/6 完成"
bash "$WERSS_ROOT/bin/status.sh" || true
# 打开菜单栏应用（常驻状态图标；launchd 已保活）
open "$WERSS_ROOT/WERSS菜单栏.app" 2>/dev/null && echo "菜单栏应用已打开（右上角 werss 图标）"
# 新装机立即对齐最新 Release（zip 可能落后于 GitHub 上的版本；零配置）
bash "$WERSS_ROOT/bin/update.sh" 2>&1 | tail -2 || true
echo
echo "后续无需任何操作："
echo "  · 开机登录后自动恢复全套（Docker→容器→采集）"
echo "  · 每 30 分钟自动保活；需要你时会弹可点击的通知（点击直达处理页）"
echo "  · 每天自动检查 GitHub Release 并自我更新"
echo "  · 日常看状态/打开管理页：双击 WERSS控制台.app"
echo "  · 换机交接：双击 交接导出.command / 交接导入.command"
notify_now "werss-app 安装完成" "系统已就绪并进入自动保活"
