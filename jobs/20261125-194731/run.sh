#!/bin/bash
MODE=build
CLEAN_BEFORE=0
TARGET_BOARD=x86
VERSION_DIST=fanchmwrt
VERSION_FILENAMES=1
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
# 固件品牌：镜像文件名前缀 + GRUB 开机菜单标题 + /etc/openwrt_release 的 DISTRIB_ID
# （源码 include/version.mk 里 VERSION_DIST 默认是 OpenWrt，见下方 VERVARS 说明）
VERSION_DIST="${VERSION_DIST:-fanchmwrt}"
VERSION_FILENAMES="${VERSION_FILENAMES:-1}"
[ -z "$JOBS" ] || [ "$JOBS" = "0" ] || [ "$JOBS" = "auto" ] && JOBS="$(nproc 2>/dev/null || echo 4)"

mkdir -p "$OUT" "$DL" "$CCACHE_DIR" "$SHARE/$JOB"
export CCACHE_DIR
export OUT SRC DL

stage() { echo ""; echo "===== [$1] $(date '+%H:%M:%S') ====="; }
fail()  { echo ""; echo "!!!!! 失败：$1 !!!!!"; exit 1; }

# 镜像文件名前缀 = include/version.mk 里的 VERSION_DIST（IMG_PREFIX）。
# 源码默认 VERSION_DIST=OpenWrt，而且 CONFIG_VERSION_* 并不是 Kconfig 符号——
# 写进 .config 会被 `make defconfig` 当未知符号丢弃，所以只能在 make 命令行覆盖
# （命令行变量优先级高于 makefile 里的 := 赋值）。全程不改动源码文件。
# GRUB 开机菜单标题（CONFIG_GRUB_TITLE）是真 Kconfig 符号，已由 .config 同步设为
# 同一个值，这里只做一次兜底校验，确保两边不会出现「文件名 fanchmwrt、菜单 OpenWrt」。
case "$VERSION_DIST" in
  ""|*[!A-Za-z0-9._-]*) fail "固件品牌只能包含字母、数字、点、下划线、连字符：$VERSION_DIST" ;;
esac
VERVARS="CONFIG_VERSION_DIST=$VERSION_DIST"
if [ "$VERSION_FILENAMES" = "1" ]; then
  VERVARS="$VERVARS CONFIG_VERSION_FILENAMES=y"
  VERSION_FILENAMES_LABEL="含版本号"
else
  VERSION_FILENAMES_LABEL="不含版本号"
fi
# x86 的 GRUB 菜单标题同样跟随固件品牌。绝大多数情况 .config 里已经写对了；
# 但用户「额外 .config」可能手写了别的值，这里以页面上的「固件品牌」为准覆盖，
# 保证「改一处、文件名和开机菜单一起变」。非 x86 目标没有该符号，传了不起作用。
case "${TARGET_BOARD:-x86}" in
  x86) VERVARS="$VERVARS CONFIG_GRUB_TITLE=$VERSION_DIST" ;;
esac

stage "环境信息"
echo "模式      : $MODE"
echo "源码目录  : $SRC"
echo "并行任务  : $JOBS"
echo "分支      : $BRANCH"
echo "固件品牌  : $VERSION_DIST（镜像名${VERSION_FILENAMES_LABEL:-含版本号} / GRUB 开机菜单标题同名）"
echo "用户      : $(id -un) (uid=$(id -u))"
[ "$(id -u)" != "0" ] || fail "OpenWrt 禁止 root 编译，请在容器中切换到普通用户"
command -v gcc >/dev/null || fail "缺少 gcc，请先安装编译依赖（见 README）"

MIRROR="${SRC_MIRROR:-}"
MIRROR_OK=0
if [ "$MIRROR" ] && [ ! -d "$MIRROR" ]; then
  mkdir -p "$(dirname "$MIRROR")"
  echo "初始化本地源码镜像（首次需要联网，之后免网络）…"
  if git clone --bare --single-branch --branch "$BRANCH" "$REPO_URL" "$MIRROR" 2>/dev/null; then
    MIRROR_OK=1
  else
    echo "[提示] 镜像初始化失败，将直接从远程克隆"
  fi
elif [ "$MIRROR" ] && [ -d "$MIRROR" ]; then
  # 必须用显式强制 refspec 更新 refs/heads/$BRANCH。
  # bare 镜像的 remote.origin.fetch 为空，`git fetch origin <branch>` 只写 FETCH_HEAD，
  # 不会移动分支引用；随后 `git clone -b <branch> <mirror>` 拿到的仍是旧提交，
  # 上游（fanchmwrt）更新会被静默吞掉。实测 `+refs/heads/x:refs/heads/x` 才有效。
  # 前缀 + 允许上游 rebase / force-push 后也能跟上。
  if git -C "$MIRROR" fetch -q origin "+refs/heads/$BRANCH:refs/heads/$BRANCH" 2>/dev/null; then
    MIRROR_OK=1
  else
    echo "[提示] 镜像更新失败，改为直接从远程克隆"
  fi
fi

if [ ! -d "$SRC/.git" ]; then
  stage "拉取源码（首次约 300MB-1GB，请耐心等待）"
  mkdir -p "$(dirname "$SRC")"
  if [ "$MIRROR_OK" = "1" ]; then
    echo "从本地镜像克隆（免网络，秒级）"
    git clone --depth 1 -b "$BRANCH" "$MIRROR" "$SRC" 2>/dev/null \
      || git clone --depth 1 -b "$BRANCH" "$REPO_URL" "$SRC" || fail "源码 clone 失败"
  else
    git clone --depth 1 -b "$BRANCH" "$REPO_URL" "$SRC" || fail "源码 clone 失败"
  fi
else
  stage "更新源码"
  cd "$SRC" || fail "无法进入源码目录"
  # 显式把远端分支取到远程跟踪引用，再让工作树跟上。
  # 旧写法 git fetch origin <branch> 只写 FETCH_HEAD；配合 pull 在浅克隆 / 镜像
  # origin 的场景会静默跳过更新，导致本地虚拟机长期用旧源码。
  # 自定义文件（.config / feeds.conf / files/）都是未跟踪文件，不会被覆盖。
  git fetch --depth 1 origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" 2>/dev/null || true
  git checkout -q -B "$BRANCH" "refs/remotes/origin/$BRANCH" 2>/dev/null \
    || echo "[提示] 源码更新失败或离线，继续使用现有源码"
fi

cd "$SRC" || fail "无法进入源码目录"
stage "源码版本"
git -C "$SRC" log -1 --format='  提交 %h · %ci · %s' 2>/dev/null || true
echo "  分支 $BRANCH · 仓库 $REPO_URL"
[ -L dl ] || { rm -rf dl; ln -s "$DL" dl; }

if [ -f "$SHARE/$JOB/extra-feeds.conf" ]; then
  stage "追加自定义源码 feeds（依赖定制）"
  cp "$SRC/feeds.conf.default" "$SRC/feeds.conf" || fail "无法写入 feeds.conf"
  # 只「追加」，绝不删改源码默认 feeds。
  # fanchmwrt 的 luci-app-fwx-* 与主题 Makefile 都写死了
  #   include $(TOPDIR)/feeds/luci/luci.mk
  # 一旦删掉默认 src-git luci，feeds/luci/ 目录就不存在，整套 fanchmwrt 应用与
  # LuCI 主题会在 defconfig 阶段被静默丢弃，编出「只有原生 LuCI」的空壳固件。
  # feeds install -a 对多个 feed 提供同名包并不会失败：它按 feeds.conf 顺序
  # 静默保留第一个（默认 feed 在前），附加 feed 只补充默认没有的包（如 ddns-go）。
  cat "$SHARE/$JOB/extra-feeds.conf" >> "$SRC/feeds.conf"
  echo "[依赖定制] 已保留全部默认 feeds，并追加以下源码 feed："
  grep '^src-git' "$SRC/feeds.conf" || true
fi

stage "更新 feeds（package / luci / routing / fanchmwrt 等）"
./scripts/feeds update -a 2>&1 || fail "feeds update 失败（检查网络）"
# 防呆自检：fanchmwrt 的 luci-app-fwx-* 与 luci-theme-fanchmwrt 都 include
# $(TOPDIR)/feeds/luci/luci.mk。缺了它，这些包会在 defconfig 阶段被静默丢弃，
# 却依然能「编译成功」产出只有原生 LuCI 的空壳固件。这里提前失败，别再静默。
if [ ! -f "$SRC/feeds/luci/luci.mk" ]; then
  fail "feeds/luci/luci.mk 缺失：fanchmwrt 的 LuCI 应用与主题无法编译（检查 feeds.conf 是否误删了默认 luci feed）"
fi
# 仅编译模式需要 feeds install（它会解析并安装每个包的 Makefile，较重）；
# 扫描模式只需 feeds update 即可让 scan.py 遍历源码树与 feeds 目录。
if [ "$MODE" != "prepare" ]; then
  ./scripts/feeds install -a 2>&1 || fail "feeds install 失败"
fi

if [ "$MODE" = "prepare" ]; then
  stage "扫描设备型号与软件包"
  echo "提示：扫描只拉取源码与软件包索引，不会编译固件（比编译快很多）。"
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
if [ -f "$SHARE/$JOB/99-fanchmwrt-repos" ]; then
  cp "$SHARE/$JOB/99-fanchmwrt-repos" "$SRC/files/etc/uci-defaults/99-fanchmwrt-repos"
  chmod 755 "$SRC/files/etc/uci-defaults/99-fanchmwrt-repos"
  echo "[依赖定制] 已注入第三方系统软件源（首次开机写 distfeeds.list）"
fi
if [ -f "$SHARE/$JOB/99-fanchmwrt-apk-keys" ]; then
  cp "$SHARE/$JOB/99-fanchmwrt-apk-keys" "$SRC/files/etc/uci-defaults/99-fanchmwrt-apk-keys"
  chmod 755 "$SRC/files/etc/uci-defaults/99-fanchmwrt-apk-keys"
  echo "[密钥] 已注入额外 apk 信任公钥（首次开机写入 /etc/apk/keys/）"
fi
if [ -f "$SHARE/$JOB/99-fanchmwrt-expand" ]; then
  cp "$SHARE/$JOB/99-fanchmwrt-expand" "$SRC/files/etc/uci-defaults/99-fanchmwrt-expand"
  chmod 755 "$SRC/files/etc/uci-defaults/99-fanchmwrt-expand"
  echo "[扩容] 已注入首次开机自动扩展根分区脚本（仅 ext4）"
fi
grep -E '^CONFIG_TARGET_(BOARD|SUBTARGET|PROFILE)=' "$SRC/.config" || true

stage "make defconfig（解析依赖，补全配置）"
make defconfig 2>&1 || fail "make defconfig 失败"
grep -E '^CONFIG_TARGET_(BOARD|SUBTARGET|PROFILE)=' "$SRC/.config" || true

# defconfig 可能因依赖关系重新启用被排除的包，这里再压一次排除项
if [ -f "$SHARE/$JOB/exclude-packages.txt" ]; then
  python3 - "$SRC/.config" "$SHARE/$JOB/exclude-packages.txt" <<'EXCLUDE_PYEOF'
import re, sys
cfg, lst = sys.argv[1], sys.argv[2]
names = [l.strip() for l in open(lst, encoding="utf-8") if l.strip()]
names = [n for n in names if re.match(r"^[A-Za-z0-9_.+\-]+$", n)]
lines = open(cfg, encoding="utf-8").read().splitlines()
out = [ln for ln in lines if not any(ln == "CONFIG_PACKAGE_%s=y" % n for n in names)]
seen = set(out)
for n in names:
    mark = "# CONFIG_PACKAGE_%s is not set" % n
    if mark not in seen:
        out.append(mark); seen.add(mark)
open(cfg, "w", encoding="utf-8").write("\n".join(out) + "\n")
print("[依赖定制] defconfig 后重新应用排除包:", ", ".join(names) or "(无)")
EXCLUDE_PYEOF
fi

if [ "$CLEAN_BEFORE" = "1" ]; then
  stage "清理旧构建"
  make clean 2>&1 || true
fi

stage "下载源码包（首次可能 1-3GB）"
make DL_DIR="$DL" download -j"$JOBS" 2>&1 || make DL_DIR="$DL" download -j1 2>&1 || fail "源码下载失败"

stage "开始编译（首次全量编译通常 1-3 小时）"
if [ "$VERBOSE" = "1" ]; then
  make DL_DIR="$DL" $VERVARS -j"$JOBS" V=s 2>&1 || fail "编译失败"
else
  make DL_DIR="$DL" $VERVARS -j"$JOBS" 2>&1 || fail "编译失败"
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
if [ "$COUNT" -gt 0 ]; then
  echo "产物文件名（前缀应为 $VERSION_DIST）："
  ls -1 "$OUT" 2>/dev/null | sed 's/^/  /'
  case "$(ls -1 "$OUT" 2>/dev/null | head -1)" in
    "$VERSION_DIST"-*) : ;;
    *) echo "[警告] 产物前缀不是 $VERSION_DIST，请检查 VERSION_DIST 是否被源码覆盖" ;;
  esac
fi
# 开机菜单标题校验：编译后 .config 里应仍是同一个固件品牌，
# 若被源码 / 额外 .config 改回 OpenWrt，这里直接提示。
GT="$(sed -n 's/^CONFIG_GRUB_TITLE="\(.*\)"$/\1/p' "$SRC/.config" | head -1)"
if [ "$GT" ] && [ "$GT" != "$VERSION_DIST" ]; then
  echo "[警告] GRUB 开机菜单标题为 $GT，与固件品牌 $VERSION_DIST 不一致"
else
  [ "$GT" ] && echo "GRUB 开机菜单标题：$GT"
fi

python3 - "$OUT" "$SRC" "$BOARD" "$SUB" "$COUNT" <<'PYEOF'
import json, os, re, sys, datetime, subprocess
out, src, board, sub, count = sys.argv[1:6]
def read(p):
    try:
        return open(p, encoding="utf-8", errors="replace").read()
    except OSError:
        return ""
def git_commit():
    """源码树里的实际提交号。build 模式若源码树无 .git（镜像/浅克隆），返回空串。"""
    try:
        r = subprocess.run(["git", "-C", src, "log", "-1", "--format=%h %s"],
                           capture_output=True, text=True, timeout=10)
        return r.stdout.strip() if r.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""
cfg = read(os.path.join(src, ".config"))
m = re.search(r'^CONFIG_TARGET_PROFILE="(.+)"', cfg, re.M)
info = {
    "model": m.group(1).replace("DEVICE_", "") if m else "default",
    "board": board, "subtarget": sub,
    "version": read(os.path.join(src, "version")).strip(),
    "kernel": "",
    "branch": "", "commit": git_commit(),
    "built_at": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    "artifact_count": int(count),
}
k = re.search(r'^CONFIG_LINUX_(\d+)_(\d+)=y', cfg, re.M)
if k:
    info["kernel"] = k.group(1) + "." + k.group(2)
for line in read(os.path.join(src, "feeds.conf.default")).splitlines():
    info.setdefault("feeds", []).append(line)
# 分支名：从 .git 读当前分支（无 .git 时留空）
try:
    r = subprocess.run(["git", "-C", src, "rev-parse", "--abbrev-ref", "HEAD"],
                       capture_output=True, text=True, timeout=10)
    if r.returncode == 0:
        info["branch"] = r.stdout.strip()
except (OSError, subprocess.SubprocessError):
    pass
with open(os.path.join(out, "build-info.json"), "w", encoding="utf-8") as f:
    json.dump(info, f, ensure_ascii=False, indent=2)
PYEOF

echo ""
echo "==================== 编译完成 ===================="
echo "输出目录 : $OUT"
echo "产物数量 : $COUNT"
ls -lh "$OUT" | tail -n +2 || true
echo "=================================================="
