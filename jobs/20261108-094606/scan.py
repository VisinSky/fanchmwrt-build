#!/usr/bin/env python3
"""扫描 OpenWrt 源码树，输出 targets.json / packages.json / source.json。"""
import json, os, re, subprocess, sys

SRC = os.environ.get("SRC", "/build/src")
OUT = os.environ.get("OUT", "")
if not OUT:
    print("SCAN: OUT not set", file=sys.stderr); sys.exit(1)
os.makedirs(OUT, exist_ok=True)


def read(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def write(name, obj):
    with open(os.path.join(OUT, name), "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, separators=(",", ":"))


def sh(args, cwd=None):
    try:
        return subprocess.run(args, cwd=cwd, capture_output=True, text=True,
                              timeout=20).stdout.strip()
    except Exception:
        return ""


# ---------- source info ----------
src_info = {"ready": os.path.isdir(os.path.join(SRC, ".git")), "path": SRC}
if src_info["ready"]:
    src_info["branch"] = sh(["git", "branch", "--show-current"], SRC)
    src_info["commit"] = sh(["git", "log", "-1", "--format=%h %s"], SRC)
    src_info["date"] = sh(["git", "log", "-1", "--format=%ci"], SRC)
    src_info["version"] = read(os.path.join(SRC, "version")).strip()
    src_info["kernel"] = ""
    m = re.search(r"^KERNEL_PATCHVER\s*:?=\s*(\S+)", read(os.path.join(SRC, "target/linux/x86/Makefile")), re.M)
    if m:
        src_info["kernel"] = m.group(1)
write("source.json", src_info)

# ---------- targets ----------
targets = []
troot = os.path.join(SRC, "target", "linux")
if os.path.isdir(troot):
    for board in sorted(os.listdir(troot)):
        bdir = os.path.join(troot, board)
        mk = os.path.join(bdir, "Makefile")
        if not os.path.isdir(bdir) or not os.path.isfile(mk):
            continue
        text = read(mk)
        m = re.search(r"^\s*BOARDNAME\s*:?=\s*(.+)$", text, re.M)
        board_name = m.group(1).strip() if m else board
        m = re.search(r"^\s*SUBTARGETS\s*:?=\s*(.+)$", text, re.M)
        subs = m.group(1).split() if m else []
        found = set(subs)
        for d in sorted(os.listdir(bdir)):
            if os.path.isfile(os.path.join(bdir, d, "target.mk")):
                found.add(d)
        sub_list = []
        for sub in sorted(found):
            sdir = os.path.join(bdir, sub)
            st = read(os.path.join(sdir, "target.mk"))
            m = re.search(r"^\s*BOARDNAME\s*:?=\s*(.+)$", st, re.M)
            sub_name = m.group(1).strip() if m else sub
            m = re.search(r"^\s*KERNEL_PATCHVER\s*:?=\s*(\S+)", st, re.M)
            kernel = m.group(1) if m else ""
            devices = []
            seen = set()

            def add_device(did, title):
                did = did.strip()
                if not did or did in seen:
                    return
                seen.add(did)
                devices.append({"id": did, "title": title.strip() or did})

            # 新式 Device/ 定义
            image_dir = os.path.join(sdir, "image")
            search_dirs = [image_dir, os.path.join(bdir, "image")] if os.path.isdir(image_dir) else [os.path.join(bdir, "image")]
            for idir in search_dirs:
                if not os.path.isdir(idir):
                    continue
                for fn in sorted(os.listdir(idir)):
                    if not fn.endswith(".mk") and fn != "Makefile":
                        continue
                    it = read(os.path.join(idir, fn))
                    for block in re.split(r"(?=^define Device/)", it, flags=re.M):
                        dm = re.match(r"^define Device/([^\s]+)", block)
                        if not dm:
                            continue
                        did = dm.group(1)
                        tm = re.search(r"^\s*DEVICE_TITLE\s*:?=\s*(.+)$", block, re.M)
                        title = tm.group(1).strip() if tm else ""
                        if not title:
                            vendor = re.search(r"^\s*DEVICE_VENDOR\s*:?=\s*(.+)$", block, re.M)
                            model = re.search(r"^\s*DEVICE_MODEL\s*:?=\s*(.+)$", block, re.M)
                            title = " ".join(x.group(1).strip() for x in (vendor, model) if x)
                        add_device(did, title)
            # 老式 Profile/ 定义
            pdir = os.path.join(sdir, "profiles")
            if os.path.isdir(pdir):
                for fn in sorted(os.listdir(pdir)):
                    if not fn.endswith(".mk"):
                        continue
                    pt = read(os.path.join(pdir, fn))
                    for block in re.split(r"(?=^define Profile/)", pt, flags=re.M):
                        pm = re.match(r"^define Profile/([^\s]+)", block)
                        if not pm:
                            continue
                        nm = re.search(r"^\s*NAME\s*:?=\s*(.+)$", block, re.M)
                        add_device(pm.group(1), nm.group(1) if nm else pm.group(1))
            if not devices:
                add_device("Default", "默认配置（无独立 Device Profile）")
            sub_list.append({"id": sub, "name": sub_name, "kernel": kernel,
                             "devices": devices})
        if sub_list:
            targets.append({"id": board, "name": board_name, "subtargets": sub_list})
write("targets.json", targets)

# ---------- packages ----------
names = {}
skip_dirs = {"bin", "build_dir", "staging_dir", "tmp", "dl", "logs", ".git", "feeds_patches"}
roots = [os.path.join(SRC, "package"), os.path.join(SRC, "feeds")]
define_re = re.compile(r"^define Package/([A-Za-z0-9_.+\-]+)", re.M)
pkg_re = re.compile(r"^\s*PKG_NAME\s*:?=\s*([A-Za-z0-9_.+\-]+)", re.M)
for root in roots:
    if not os.path.isdir(root):
        continue
    for dirpath, dirnames, filenames in os.walk(root, followlinks=True):
        dirnames[:] = [d for d in dirnames if d not in skip_dirs and not d.startswith(".")]
        depth = dirpath[len(root):].count(os.sep)
        if depth > 5:
            dirnames[:] = []
        if "Makefile" not in filenames:
            continue
        text = read(os.path.join(dirpath, "Makefile"))
        origin = "core" if root.endswith("/package") else "feed"
        for m in define_re.finditer(text):
            names.setdefault(m.group(1), origin)
        if not define_re.search(text):
            for m in pkg_re.finditer(text):
                names.setdefault(m.group(1), origin)
pkgs = sorted(names)
write("packages.json", pkgs)
print("SCAN: %d targets, %d packages -> %s" % (len(targets), len(pkgs), OUT))
