#!/usr/bin/env bash
# Graft GL-MT5000 device support onto official openwrt-25.12 (kernel 6.12).
# The GLiNet mt5000 branch is based on openwrt main (kernel 6.18), so we
# extract files individually and adapt 6.18 -> 6.12 instead of cherry-picking
# (which fails on directory-rename conflicts).
set -eu

WORKSPACE="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")/.." && pwd)}"
GL_REPO="${GL_DEVICE_COMMIT:-https://github.com/GLiNet-Tech/openwrt.git}"
KCFG=target/linux/mediatek/filogic/config-6.12
FILOGIC_MK=target/linux/mediatek/image/filogic.mk
BOARDD=target/linux/mediatek/filogic/base-files/etc/board.d/02_network
PLATFORMSH=target/linux/mediatek/filogic/base-files/lib/upgrade/platform.sh
DTS=target/linux/mediatek/dts/mt7987a-gl-mt5000.dts

echo ">> Fetching GL-MT5000 device support from GLiNet mt5000 branch"
git config user.email build@local
git config user.name mt5000-build
git remote add glinet "$GL_REPO" 2>/dev/null || true
git fetch --depth 2 glinet mt5000

GL_COMMIT=FETCH_HEAD

echo ">> Extracting MT5000 files from GLiNet branch"

# 1. DTS — copy directly
git --work-tree=/tmp/gl-extract checkout "$GL_COMMIT" -- \
  target/linux/mediatek/dts/mt7987a-gl-mt5000.dts 2>/dev/null || \
git show "$GL_COMMIT:target/linux/mediatek/dts/mt7987a-gl-mt5000.dts" > "$DTS"

# 2. Kernel patches: pending-6.18 -> pending-6.12
# NOTE: 795-11 (8021Q PPE offload) and 795-12 (mtk dummy NAPI) are skipped
# because they depend on kernel 6.18 APIs not present in 6.12. The core DSA
# driver (795-10) is sufficient for basic switch functionality.
mkdir -p target/linux/generic/pending-6.12
for p in \
  795-10-net-dsa-realtek-add-rtl8366ub.patch
do
  echo ">> Copying kernel patch: $p"
  git show "$GL_COMMIT:target/linux/generic/pending-6.18/$p" \
    > "target/linux/generic/pending-6.12/$p"
done

# 2b. Fix 795-10 Makefile hunk for kernel 6.12 (6.18 Makefile has multi-line
#     rtl8365mb-objs; 6.12 is single-line). Replace the hunk to append at EOF.
echo ">> Adapting 795-10 Makefile hunk for kernel 6.12"
python3 - target/linux/generic/pending-6.12/795-10-net-dsa-realtek-add-rtl8366ub.patch <<'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    content = f.read()

# Match the entire Makefile hunk (from @@ ... Makefile to the next diff --git)
pattern = re.compile(
    r'(diff --git a/drivers/net/dsa/realtek/Makefile b/drivers/net/dsa/realtek/Makefile\n'
    r'index [^\n]+\n'
    r'--- a/drivers/net/dsa/realtek/Makefile\n'
    r'\+\+\+ b/drivers/net/dsa/realtek/Makefile\n)'
    r'(@@.*?\n)'
    r'(.*?)(?=diff --git|\Z)',
    re.DOTALL
)

m = pattern.search(content)
if m:
    header = m.group(1)
    # New hunk: match the last line of 6.12 Makefile and append rtl8366ub block
    new_hunk = "@@ -11,1 +11,14 @@ obj-$(CONFIG_NET_DSA_REALTEK_RTL8365MB) += rtl8365mb.o\n"
    new_hunk += "+\n"
    new_hunk += "+obj-$(CONFIG_NET_DSA_REALTEK_RTL8366UB) += rtl8366ub.o\n"
    new_hunk += "+rtl8366ub-objs := rtl8366ub_reg.o \\\n"
    new_hunk += "+\t\trtl8366ub_init.o \\\n"
    new_hunk += "+\t\trtl8366ub_core.o \\\n"
    new_hunk += "+\t\trtl8366ub_port.o \\\n"
    new_hunk += "+\t\trtl8366ub_cpu.o \\\n"
    new_hunk += "+\t\trtl8366ub_switch.o \\\n"
    new_hunk += "+\t\trtl8366ub_table.o \\\n"
    new_hunk += "+\t\trtl8366ub_l2.o \\\n"
    new_hunk += "+\t\trtl8366ub_mib.o \\\n"
    new_hunk += "+\t\trtl8366ub_dsa.o \\\n"
    new_hunk += "+\t\trtl8366ub_phy.o\n\n"
    replacement = header + new_hunk
    content = content[:m.start()] + replacement + content[m.end():]
    with open(path, 'w') as f:
        f.write(content)
    print("  Makefile hunk adapted for 6.12")
else:
    print("  WARNING: Makefile hunk not found")
PYEOF

# 3. Kernel config: apply 6.18 additions to 6.12
echo ">> Adding RTL8366UB DSA config to config-6.12"
for cfg in CONFIG_NET_DSA_REALTEK=y CONFIG_NET_DSA_REALTEK_MDIO=y CONFIG_NET_DSA_REALTEK_RTL8366UB=y; do
  grep -q "^$cfg" "$KCFG" || echo "$cfg" >> "$KCFG"
done

# 4. filogic.mk: extract the gl-mt5000 device block and insert after gl-mt3600be
echo ">> Adding gl-mt5000 device definition to filogic.mk"
git show "$GL_COMMIT:target/linux/mediatek/image/filogic.mk" > /tmp/gl-filogic.mk
# Extract the gl-mt5000 define block
awk '/^define Device\/glinet_gl-mt5000$/{f=1} f{print} /^endef$/{if(f){f=0}}' /tmp/gl-filogic.mk > /tmp/mt5000-define.txt
# Also extract the TARGET_DEVICES line
grep "TARGET_DEVICES += glinet_gl-mt5000" /tmp/gl-filogic.mk >> /tmp/mt5000-define.txt

# Insert the gl-mt5000 block before the gl-mt6000 definition
if ! grep -q "glinet_gl-mt5000" "$FILOGIC_MK"; then
  awk '
    /^define Device\/glinet_gl-mt6000$/ && !done {
      while ((getline line < "/tmp/mt5000-define.txt") > 0) print line
      close("/tmp/mt5000-define.txt")
      done=1
    }
    {print}
  ' "$FILOGIC_MK" > /tmp/filogic.mk.new && mv /tmp/filogic.mk.new "$FILOGIC_MK"
fi

# 5. board.d/02_network: add gl-mt5000 case
echo ">> Adding gl-mt5000 network config to board.d"
if ! grep -q "glinet,gl-mt5000" "$BOARDD"; then
  python3 - "$BOARDD" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()
out = []
inserted = False
for i, line in enumerate(lines):
    out.append(line)
    if not inserted and 'wavlink,wl-wnt100x3-ubootmod)' in line:
        # skip ahead to the ;; that ends this case
        j = i + 1
        while j < len(lines) and ';;' not in lines[j]:
            out.append(lines[j])
            j += 1
        if j < len(lines):
            out.append(lines[j])
            out.append('\tglinet,gl-mt5000)\n')
            out.append('\t\tucidef_set_interfaces_lan_wan "lan1 lan2" eth1\n')
            out.append('\t\t;;\n')
            inserted = True
            # consume the lines we already added so the main loop skips them
            # by replacing them: mark indices i+1..j as consumed
            for k in range(i + 1, j + 1):
                lines[k] = None
# filter out None (consumed lines)
out = [l for l in out if l is not None]
with open(path, 'w') as f:
    f.writelines(out)
PYEOF
fi

# 6. platform.sh: add gl-mt5000 to upgrade list
echo ">> Adding gl-mt5000 to platform.sh upgrade list"
if ! grep -q "glinet,gl-mt5000" "$PLATFORMSH"; then
  python3 - "$PLATFORMSH" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
content = content.replace(
    'glinet,gl-mt2500-airoha|\\',
    'glinet,gl-mt2500-airoha|\\\n\tglinet,gl-mt5000|\\'
)
with open(path, 'w') as f:
    f.write(content)
PYEOF
fi

# Cleanup temp files
rm -rf /tmp/gl-extract /tmp/gl-filogic.mk /tmp/mt5000-define.txt

# --- Sanity checks ---
echo ">> Running sanity checks"
test -f "$DTS" || { echo ">> ERROR: DTS missing"; exit 1; }
grep -q "glinet_gl-mt5000" "$FILOGIC_MK" || { echo ">> ERROR: device recipe missing"; exit 1; }
grep -q "CONFIG_NET_DSA_REALTEK_RTL8366UB=y" "$KCFG" || { echo ">> ERROR: RTL8366UB config missing"; exit 1; }
grep -q 'glinet,gl-mt5000)' "$BOARDD" || { echo ">> ERROR: gl-mt5000 case missing from board.d"; exit 1; }
grep -q 'glinet,gl-mt5000' "$PLATFORMSH" || { echo ">> ERROR: gl-mt5000 missing from platform.sh"; exit 1; }
sh -n "$BOARDD" || { echo ">> ERROR: board.d has syntax error"; exit 1; }
test -f target/linux/generic/pending-6.12/795-10-net-dsa-realtek-add-rtl8366ub.patch || { echo ">> ERROR: DSA patch missing"; exit 1; }

# --- First-boot defaults ---
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

echo ">> MT5000 device support applied successfully"
