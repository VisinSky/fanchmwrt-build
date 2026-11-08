#!/bin/bash
MODE=prepare
CLEAN_BEFORE=1
# FanchmWrt Builder 编译入口；在 Ubuntu 22 / Linux 环境内执行。
set -o pipefail
export LC_ALL=C
export TZ=Asia/Shanghai

SRC="${SRC:-/build/src}"
DL="${DL:-/build/dl}"
CCACHE_DIR="${CCACHE_DIR:-/build/ccache}"
SHARE="${SHARE:-/build/share}"
JOB="${JOB:-manual}"
OUT="$SHARE/$JOB/out"
REPO_URL="${REPO_URL:-https://github.com/fanchmwrt/fanchmwrt.git}"
BRANCH="${BRANCH:-fanchmwrt-25.12.6}"
MODE="${MODE:-build}"
[ -z "$JOBS" ] || [ "$JOBS" = "0" ] || [ "$JOBS" = "auto" ] && JOBS="$(nproc 2>/dev/null || echo 4)"

mkdir -p "$OUT" "$DL" "$CCACHE_DIR" "$SHARE/$JOB"
export CCACHE_DIR
export OUT SRC DL

stage() { echo ""; echo "===== [$1] $(date '+%H:%M:%S') ====="; }
fail()  { echo ""; echo "!!!!! 失败：$1 !!!!!"; exit 1; }

stage "环境信息"
echo "模式      : $MODE"
echo "源码目录  : $SRC"
echo "并行任务  : $JOBS"
echo "分支      : $BRANCH"
echo "用户      : $(id -un) (uid=$(id -u))"
[ "$(id -u)" != "0" ] || fail "OpenWrt 禁止 root 编译，请在容器中切换到普通用户"
command -v gcc >/dev/null || fail "缺少 gcc，请先安装编译依赖（见 README）"

if [ ! -d "$SRC/.git" ]; then
  stage "拉取源码（首次约 300MB-1GB，请耐心等待）"
  mkdir -p "$(dirname "$SRC")"
  git clone --depth 1 -b "$BRANCH" "$REPO_URL" "$SRC" || fail "源码 clone 失败"
else
  stage "更新源码"
  cd "$SRC" || fail "无法进入源码目录"
  git fetch --depth 1 origin "$BRANCH" 2>/dev/null || true
  git checkout -q "$BRANCH" 2>/dev/null || true
  git pull --ff-only -q 2>/dev/null || echo "[提示] 源码已是最新或存在本地改动，跳过 pull"
fi

cd "$SRC" || fail "无法进入源码目录"
[ -L dl ] || { rm -rf dl; ln -s "$DL" dl; }

stage "更新 feeds（package / luci / routing / fanchmwrt 等）"
./scripts/feeds update -a 2>&1 || fail "feeds update 失败（检查网络）"
./scripts/feeds install -a 2>&1 || fail "feeds install 失败"

if [ "$MODE" = "prepare" ]; then
  stage "扫描设备型号与软件包"
  python3 "$SHARE/$JOB/scan.py" || fail "源码扫描失败"
  cp "$OUT/targets.json" "$SHARE/$JOB/targets.json" 2>/dev/null || true
  echo ""
  echo "准备完成：设备列表与软件包索引已生成。"
  exit 0
fi

stage "写入 .config"
cp "$SHARE/$JOB/.config" "$SRC/.config" || fail "缺少 .config"
mkdir -p "$SRC/files/etc/uci-defaults"
cp "$SHARE/$JOB/99-fanchmwrt-custom" "$SRC/files/etc/uci-defaults/99-fanchmwrt-custom"
chmod 755 "$SRC/files/etc/uci-defaults/99-fanchmwrt-custom"
grep -E '^CONFIG_TARGET_(BOARD|SUBTARGET|PROFILE)=' "$SRC/.config" || true

stage "make defconfig（解析依赖，补全配置）"
make defconfig 2>&1 || fail "make defconfig 失败"
grep -E '^CONFIG_TARGET_(BOARD|SUBTARGET|PROFILE)=' "$SRC/.config" || true

if [ "$CLEAN_BEFORE" = "1" ]; then
  stage "清理旧构建"
  make clean 2>&1 || true
fi

stage "下载源码包（首次可能 1-3GB）"
make DL_DIR="$DL" download -j"$JOBS" 2>&1 || make DL_DIR="$DL" download -j1 2>&1 || fail "源码下载失败"

stage "开始编译（首次全量编译通常 1-3 小时）"
if [ "$VERBOSE" = "1" ]; then
  make DL_DIR="$DL" -j"$JOBS" V=s 2>&1 || fail "编译失败"
else
  make DL_DIR="$DL" -j"$JOBS" 2>&1 || fail "编译失败"
fi

stage "收集固件产物"
BOARD="$(sed -n 's/^CONFIG_TARGET_BOARD="\(.*\)"/\1/p' "$SRC/.config" | head -1)"
SUB="$(sed -n 's/^CONFIG_TARGET_SUBTARGET="\(.*\)"/\1/p' "$SRC/.config" | head -1)"
TDIR="$SRC/bin/targets/$BOARD/$SUB"
COUNT=0
if [ -d "$TDIR" ]; then
  while IFS= read -r f; do
    cp -f "$f" "$OUT/" && COUNT=$((COUNT+1))
  done < <(find "$TDIR" -maxdepth 1 -type f \
      \( -name '*.img' -o -name '*.img.gz' -o -name '*.bin' -o -name '*.bin.gz' \
         -o -name '*sysupgrade*' -o -name '*factory*' -o -name '*rootfs*' \
         -o -name '*kernel*' -o -name '*.qcow2' -o -name '*.vmdk' -o -name '*.vhd' \
         -o -name 'sha256sums' -o -name '*.manifest' \) 2>/dev/null)
fi
cp "$SRC/.config" "$OUT/build.config" 2>/dev/null || true

python3 - "$OUT" "$SRC" "$BOARD" "$SUB" "$COUNT" <<'PYEOF'
import json, os, re, sys, datetime
out, src, board, sub, count = sys.argv[1:6]
def read(p):
    try:
        return open(p, encoding="utf-8", errors="replace").read()
    except OSError:
        return ""
cfg = read(os.path.join(src, ".config"))
m = re.search(r'^CONFIG_TARGET_PROFILE="(.+)"', cfg, re.M)
info = {
    "model": m.group(1).replace("DEVICE_", "") if m else "default",
    "board": board, "subtarget": sub,
    "version": read(os.path.join(src, "version")).strip(),
    "kernel": "",
    "branch": "", "commit": "",
    "built_at": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    "artifact_count": int(count),
}
k = re.search(r'^CONFIG_LINUX_(\d+)_(\d+)=y', cfg, re.M)
if k:
    info["kernel"] = k.group(1) + "." + k.group(2)
for line in read(os.path.join(src, "feeds.conf.default")).splitlines():
    info.setdefault("feeds", []).append(line)
with open(os.path.join(out, "build-info.json"), "w", encoding="utf-8") as f:
    json.dump(info, f, ensure_ascii=False, indent=2)
PYEOF

echo ""
echo "==================== 编译完成 ===================="
echo "输出目录 : $OUT"
echo "产物数量 : $COUNT"
ls -lh "$OUT" | tail -n +2 || true
echo "=================================================="
