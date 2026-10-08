#!/bin/bash
# 自更新：检查 GitHub 最新 Release → 对比 VERSION → 下载 tarball 覆盖代码文件
#       → 重装 launchd → 容器配置有变则重建 → 用新代码重启 runner。
# 数据安全：data/、companies.csv、config.env、batch 运行态（队列/日志/进度）永不被覆盖；
#           更新前自动把当前代码备份到 backups/code-pre-update-*.tar.gz。
# 用法: update.sh [--check]   --check 只报告新版本，不更新
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# 仓库地址解析（零配置，无需在各机器上做任何设置）：
#   ① config/env 显式指定的 WERSS_GITHUB_REPO → ② 本目录 git remote origin 自动探测
#   （git@github.com:u/r.git / https://github.com/u/r.git 均可）→ ③ 都没有则跳过。
# 用 zip 安装的新机（无 .git）靠发布时写入 config.example.env 的地址兜底（见 bin/publish.sh）。
resolve_repo() {
  if [ -n "${WERSS_GITHUB_REPO:-}" ]; then echo "$WERSS_GITHUB_REPO"; return 0; fi
  local url
  url=$(git -C "$WERSS_ROOT" remote get-url origin 2>/dev/null) || return 1
  url=$(printf '%s' "$url" | sed -E 's#\.git$##; s#^git@github\.com:##; s#^https?://github\.com/##')
  case "$url" in
    */*) echo "$url"; return 0 ;;
    *) return 1 ;;
  esac
}

REPO=$(resolve_repo)
if [ -z "${REPO:-}" ]; then
  echo "[update] 未解析到 GitHub 仓库地址（发布时运行 bin/publish.sh 即全程自动），跳过"
  exit 0
fi

LOCAL_V="$(cat "$WERSS_ROOT/VERSION" 2>/dev/null || echo v0)"
REL=$(with_timeout 30 curl -sf -m 20 "https://api.github.com/repos/$REPO/releases/latest") || {
  echo "[update] 无法访问 github.com/$REPO（未发布 release 或网络问题），跳过"; exit 0
}
TAG=$(printf '%s' "$REL" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null)
TARBALL=$(printf '%s' "$REL" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("tarball_url",""))' 2>/dev/null)
[ -n "$TAG" ] || { echo "[update] 仓库无 release，跳过"; exit 0; }

# 归一化比较（v 前缀可有可无）——只在远程版本更新时才升级，本地超前（开发中/未发布）绝不降级
if [ "${TAG#v}" = "${LOCAL_V#v}" ]; then
  echo "[update] 已是最新 ($LOCAL_V)"
  exit 0
fi
HIGHER=$(printf '%s\n%s\n' "${TAG#v}" "${LOCAL_V#v}" | sort -V | tail -1)
if [ "$HIGHER" = "${LOCAL_V#v}" ]; then
  log "[update] 本地 ($LOCAL_V) 新于最新 Release ($TAG)，跳过（不降级）"
  exit 0
fi
if [ "${1:-}" = "--check" ]; then
  echo "[update] 有新版本: $LOCAL_V → $TAG（去掉 --check 执行更新）"
  exit 0
fi

log "[update] 开始更新 $LOCAL_V → $TAG"

# 1. 备份当前代码
BK="$WERSS_ROOT/backups/code-pre-update-$(date +%Y%m%d-%H%M%S).tar.gz"
tar -czf "$BK" -C "$WERSS_ROOT" \
    bin batch/*.sh batch/*.py batch/*.js batch/*.template batch/canary_pool.json \
    launchd docker-compose.yml VERSION README.md *.command 2>/dev/null \
  || tar -czf "$BK" -C "$WERSS_ROOT" bin launchd docker-compose.yml VERSION README.md
log "[update] 代码已备份: $BK"

# 2. 下载并解包（GitHub tarball 只含 git 跟踪文件，天然不会碰 data/config.env/运行态）
STAGE=$(mktemp -d /tmp/werss-update.XXXX)
with_timeout 300 curl -sfL -m 280 "$TARBALL" -o "$STAGE/src.tar.gz" || {
  log "[update] 下载失败，放弃（系统保持原样）"; rm -rf "$STAGE"; exit 1; }
mkdir -p "$STAGE/src" && tar -xzf "$STAGE/src.tar.gz" -C "$STAGE/src" --strip-components=1

# 3. 覆盖代码（tar 解包覆盖，不删除本地多出的文件——队列/日志/数据安全）
( cd "$STAGE/src" && tar cf - . ) | ( cd "$WERSS_ROOT" && tar xf - )
rm -rf "$STAGE"

# 4. 生效：launchd 模板可能有变 → 重装；compose 定义可能有变 → up -d 幂等重建；
#    runner 换新代码 → 重启
chmod +x "$WERSS_ROOT"/bin/*.sh "$WERSS_ROOT"/batch/*.sh "$WERSS_ROOT"/batch/*.py "$WERSS_ROOT"/*.command 2>/dev/null
# 装不上 launchd 会让保活/招聘扫描静默停摆，这里不再吞错误（记录+通知后续由 install 自身输出）
bash "$WERSS_ROOT/bin/install_launchd.sh" || log "[update] 警告：launchd 安装有失败项"
compose up -d || true
pkill -f "bash run_forever.sh" 2>/dev/null; pkill -f "python3 .*process_chunk.py" 2>/dev/null; sleep 2
start_runner

notify "已自动更新" "$LOCAL_V → $TAG（代码备份于 backups/，数据未动）"
log "[update] 完成 $LOCAL_V → $TAG"
