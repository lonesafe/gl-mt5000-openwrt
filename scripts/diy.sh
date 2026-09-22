#!/usr/bin/env bash
# Graft GL-MT5000 (Brume 3) device support onto official OpenWrt main.
#
# The patch file (patches/gl-mt5000-support.patch) was extracted from
# GLiNet-Tech/openwrt commit 996b7d38 — the same commit as the (closed)
# PR #21728.  It targets openwrt main (kernel 6.18) and adds:
#   - DTS:  mt7987a-gl-mt5000.dts
#   - DSA:  795-10/11/12 kernel patches (RTL8366UB driver + PPE + NAPI)
#   - Config / image recipe / board.d / platform.sh entries
#
# Because both the patch and the build base use kernel 6.18, the patch
# should apply cleanly.  If main has drifted, fall back to --3way / fuzz.
set -eu

# Locate patch relative to this script (scripts/ is one level below repo root)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCH_SRC="${1:-$SCRIPT_DIR/../patches/gl-mt5000-support.patch}"
PATCH_FILE="/tmp/gl-mt5000-support.patch"

echo ">> Copying patch into build tree"
cp "$PATCH_SRC" "$PATCH_FILE"

echo ">> Applying GL-MT5000 device support patch"
# Try clean apply first, then with fuzz, then --3way
if git apply --check "$PATCH_FILE" 2>/dev/null; then
    git apply "$PATCH_FILE"
    echo ">> Patch applied cleanly"
elif patch -p1 --fuzz=3 --forward < "$PATCH_FILE"; then
    echo ">> Patch applied with fuzz"
else
    echo ">> Clean apply failed, trying git apply --3way …"
    if git apply --3way "$PATCH_FILE"; then
        echo ">> Patch applied with 3-way merge"
    else
        echo ">> ERROR: Could not apply patch. Trying file-by-file fallback…"
        # Last resort: apply each diff hunk individually
        python3 - "$PATCH_FILE" <<'PY'
import sys, re, subprocess, os

patch_file = sys.argv[1]
with open(patch_file) as f:
    content = f.read()

# Split into per-file diffs
diffs = re.split(r'(?=^diff --git)', content, flags=re.MULTILINE)
diffs = [d for d in diffs if d.strip()]

ok = 0
fail = 0
for d in diffs:
    # Extract filename
    m = re.match(r'diff --git a/(\S+) b/(\S+)', d)
    if not m:
        continue
    fname = m.group(2)
    tmp = f"/tmp/hunk_{ok}_{fname.replace('/', '_')}.patch"
    with open(tmp, 'w') as f:
        f.write(d)
    ret = subprocess.run(['git', 'apply', '--fuzz=3', '--reject', tmp],
                         capture_output=True, text=True)
    if ret.returncode == 0:
        print(f"  OK: {fname}")
        ok += 1
    else:
        print(f"  FAIL: {fname}: {ret.stderr.strip()[:120]}")
        fail += 1
    os.unlink(tmp)

print(f"\nApplied {ok} files, {fail} failures")
if fail > 0:
    sys.exit(1)
PY
    fi
fi

echo ">> Verifying key files exist"
for f in \
    target/linux/mediatek/dts/mt7987a-gl-mt5000.dts \
    target/linux/generic/pending-6.18/795-10-net-dsa-realtek-add-rtl8366ub.patch \
    target/linux/mediatek/filogic/config-6.18; do
    [ -f "$f" ] || { echo ">> ERROR: $f missing after patch"; exit 1; }
done

echo ">> Verifying DSA driver in kernel config"
grep -q '^CONFIG_NET_DSA_REALTEK_RTL8366UB=y' \
    target/linux/mediatek/filogic/config-6.18 \
    || { echo ">> ERROR: RTL8366UB DSA config missing"; exit 1; }

echo ">> Verifying board.d network config"
BOARDD=target/linux/mediatek/filogic/base-files/etc/board.d/02_network
grep -q 'glinet,gl-mt5000' "$BOARDD" \
    || { echo ">> ERROR: gl-mt5000 case missing from board.d"; exit 1; }
sh -n "$BOARDD" || { echo ">> ERROR: board.d syntax error"; exit 1; }

echo ">> Setting first-boot defaults"
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-gl-mt5000 <<'UCI'
#!/bin/sh
uci -q batch <<-EOF
	set system.@system[0].hostname='GL-MT5000'
	set system.@system[0].timezone='WET0WEST,M3.5.0/1,M10.5.0'
	set system.@system[0].zonename='Europe/Lisbon'
	commit system
EOF
exit 0
UCI

echo ">> GL-MT5000 device support applied successfully"
