#!/usr/bin/env bash
# Apply GL-MT5000 DSA network config and first-boot defaults.
# The GLiNet mt5000 branch (used as the build base) already contains the
# full device support (DTS, image recipe, native RTL8366UB DSA driver).
set -eu

BOARDD=target/linux/mediatek/filogic/base-files/etc/board.d/02_network

echo ">> Ensuring GL-MT5000 DSA network config (lan1 lan2 / WAN eth1)"
if ! grep -q 'glinet,gl-mt5000' "$BOARDD"; then
  echo ">> ERROR: gl-mt5000 case missing from board.d"
  exit 1
fi
# Ensure the DSA interface line is correct (lan1 lan2 on switch, WAN on eth1)
if ! grep -qF 'ucidef_set_interfaces_lan_wan "lan1 lan2" eth1' "$BOARDD"; then
  echo ">> WARNING: board.d gl-mt5000 line differs from expected DSA layout"
fi
sh -n "$BOARDD" || { echo ">> ERROR: board.d has syntax error"; exit 1; }

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

echo ">> GL-MT5000 config applied"
