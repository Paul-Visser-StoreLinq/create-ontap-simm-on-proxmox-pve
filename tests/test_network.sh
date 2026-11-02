#!/usr/bin/env bash
# =============================================================================
# tests/test_network.sh — network mapping and bridge/VLAN precheck (v3.3)
#
# Runs on any machine with bash >= 4 and python3 (no Proxmox needed): qm, pvesh
# and pvesm are replaced by stubs that read fixtures from a temp directory.
# Usage: bash tests/test_network.sh
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../ontap-sim-2node-proxmox.sh"
CONF="$HERE/../ontap-sim-2node-proxmox.conf"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); echo "  OK   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FOUT $1"; [[ -n "${2:-}" ]] && sed 's/^/       | /' <<< "$2" | tail -15; }

# ---- stubs ------------------------------------------------------------------
mkdir -p "$TMP/bin" "$TMP/fx"
cat > "$TMP/bin/pvesh" <<'STUB'
#!/usr/bin/env bash
# pvesh get <path> [...]; fixtures in $FX
[[ "$1" == "get" ]] || { echo "stub pvesh: only get" >&2; exit 2; }
path="$2"
case "$path" in
  /nodes/*/network/*)
    n="${path#/nodes/}"; node="${n%%/*}"; br="${path##*/}"
    f="$FX/net-$node-$br.json"
    [[ -f "$f" ]] && { cat "$f"; exit 0; }
    echo "no such interface '$br'" >&2; exit 2 ;;
  /cluster/resources) echo '[]' ;;
  /nodes/*/storage/*/content) echo '[{"volid":"software:iso/vsim-netapp-DOT9.16.1-cm_nodar.ova"}]' ;;
  /nodes/*) echo '{}' ;;
  *) echo '{}' ;;
esac
STUB
cat > "$TMP/bin/pvesm" <<'STUB'
#!/usr/bin/env bash
echo "Name Type Status Total Used Available %"
echo "x nfs active 1 1 1 1%"
STUB
printf '#!/usr/bin/env bash\necho "stub qm must not be called: $*" >&2; exit 99\n' > "$TMP/bin/qm"
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH" FX="$TMP/fx"

# net fixture: node bridge vlan_aware vids
fx() { printf '{"type":"bridge","iface":"%s","bridge_vlan_aware":%s,"bridge_vids":"%s"}\n' "$2" "$3" "$4" > "$FX/net-$1-$2.json"; }
good_fixtures() {
  rm -f "$FX"/net-*.json
  for n in pve02 pve04; do
    fx "$n" vmbr0 1 "30 50 99"
    fx "$n" vmbr1 1 "10 20 30 40 51 52 53 100-102"
  done
}

# conf for cluster N (from the repo example; only the cluster-specific values change)
mkconf() {
  local n="$1" f="$TMP/c$1.conf"
  sed -e "s/^CLUSTER_NUM=.*/CLUSTER_NUM=\"0$n\"/" \
      -e "s/^CLUSTER_VLAN_TAG=.*/CLUSTER_VLAN_TAG=\"5$n\"/" \
      -e "s/^VMID1=.*/VMID1=\"$((90+2*n))\"/" -e "s/^VMID2=.*/VMID2=\"$((91+2*n))\"/" \
      -e "s|^WORKDIR=.*|WORKDIR=\"$TMP/work\"|" \
      -e 's/^TARGET_NODE1=.*/TARGET_NODE1="pve02"/' -e 's/^TARGET_NODE2=.*/TARGET_NODE2="pve04"/' \
      "$CONF" > "$f"
  echo "$f"
}

# expected 8 lines per node for cluster N
expect_lines() {
  local n="$1" vmid="$2"
  for p in 0 1; do echo "qm set $vmid --net$p e1000,bridge=vmbr1,tag=5$n"; done
  for p in 2 3 4; do echo "qm set $vmid --net$p e1000,bridge=vmbr0,tag=50"; done
  echo "qm set $vmid --net5 e1000,bridge=vmbr1,trunks=100;101;102"
  for p in 6 7; do echo "qm set $vmid --net$p e1000,bridge=vmbr0,tag=50"; done
}

check_commands() { # name output n
  local name="$1" out="$2" n="$3"
  local v1=$((90+2*n)) v2=$((91+2*n)) got want
  got="$(grep -E '^  qm set ' <<< "$out" | sed 's/^  //')"
  want="$(expect_lines "$n" "$v1"; expect_lines "$n" "$v2")"
  if [[ "$got" == "$want" ]]; then ok "$name"; else bad "$name" "$(diff <(echo "$want") <(echo "$got"))"; fi
}

run() { CONFIG_FILE='' bash "$SCRIPT" "$@" 2>&1; }

echo "== --show-ports (any machine)"
for n in 1 2 3; do
  out="$(run --config "$(mkconf $n)" --show-ports)"; rc=$?
  [[ $rc -eq 0 ]] || bad "show-ports cluster$n exit $rc" "$out"
  check_commands "show-ports lab-cluster$n: net0/1 vmbr1 tag 5$n, net2-4/6/7 vmbr0 tag 50, net5 vmbr1 trunks" "$out" "$n"
done
grep -q "e0f.*trunk (VLAN-poorten).*vmbr1 trunks 100;101;102" <<< "$out" && ok "port table shows e0f as trunk" || bad "port table e0f" "$out"
grep -q "ifgrp a0b -port e0f" <<< "$out" && bad "e0f must not be in ifgroup a0b" "$out" || ok "e0f not in ifgroup a0b"

echo "== --dry-run (stubbed Proxmox)"
good_fixtures
for n in 1 2 3; do
  out="$(run --config "$(mkconf $n)" --dry-run)"; rc=$?
  if [[ $rc -eq 0 ]] && grep -q "All prechecks passed" <<< "$out"; then ok "dry-run cluster$n prechecks pass"; else bad "dry-run cluster$n rc=$rc" "$out"; fi
  check_commands "dry-run lab-cluster$n commands for pve02 and pve04" "$out" "$n"
done
[[ ! -e "$TMP/work" ]] && ok "dry-run created no WORKDIR" || bad "dry-run created WORKDIR"

expect_fail() { # name grep-pattern args...
  local name="$1" pat="$2"; shift 2
  local out rc
  out="$(run "$@")"; rc=$?
  if [[ $rc -ne 0 ]] && grep -qE "$pat" <<< "$out" && ! grep -q "^  qm set" <<< "$out"; then ok "$name"
  else bad "$name (rc=$rc)" "$out"; fi
}

echo "== precheck stops"
good_fixtures; fx pve04 vmbr0 1 "30 99"
expect_fail "vmbr0 without VLAN 50 on pve04" "bridge 'vmbr0' on node pve04 does not carry VLAN\(s\) 50" --config "$(mkconf 1)" --dry-run
good_fixtures; fx pve02 vmbr1 1 "10 20 30 40 51 53 100-102"
expect_fail "vmbr1 without VLAN 52 on pve02 (cluster2)" "bridge 'vmbr1' on node pve02 does not carry VLAN\(s\) 52" --config "$(mkconf 2)" --dry-run
good_fixtures; fx pve04 vmbr1 1 "51 52 53"
expect_fail "vmbr1 without trunk VLANs" "does not carry VLAN\(s\) 100,101,102" --config "$(mkconf 3)" --dry-run
good_fixtures; fx pve02 vmbr0 0 ""
expect_fail "vmbr0 not VLAN-aware" "is not VLAN-aware" --config "$(mkconf 1)" --dry-run
good_fixtures; fx pve02 vmbr0 1 ""
expect_fail "vmbr0 without bridge-vids" "has no bridge-vids set" --config "$(mkconf 1)" --dry-run
good_fixtures; rm -f "$FX/net-pve04-vmbr1.json"
expect_fail "vmbr1 missing on pve04" "bridge 'vmbr1' not found on node pve04" --config "$(mkconf 1)" --dry-run

echo "== regression VM 100 (02-11-2026): interconnect on vmbr0, data on vmbr1"
good_fixtures
out="$(CLUSTER_BRIDGE=vmbr0 DATA_BRIDGE=vmbr1 run --config "$(mkconf 1)" --dry-run)"; rc=$?
if [[ $rc -ne 0 ]] && grep -q "bridge 'vmbr0' on node pve02 does not carry VLAN(s) 51" <<< "$out" \
   && grep -q "bridge 'vmbr1' on node pve02 does not carry VLAN(s) 50" <<< "$out"; then ok "swapped bridges are refused before anything is created"
else bad "swapped bridges (rc=$rc)" "$out"; fi

echo "== config validation"
out="$(TRUNK_VLANS='51;100' run --config "$(mkconf 1)" --show-ports)"; [[ $? -ne 0 ]] && grep -q "also in TRUNK_VLANS" <<< "$out" && ok "TRUNK_VLANS with VLAN 51 refused" || bad "TRUNK_VLANS 51" "$out"
out="$(TRUNK_PORT=9 run --config "$(mkconf 1)" --show-ports)"; [[ $? -ne 0 ]] && grep -q "TRUNK_PORT=9 does not exist" <<< "$out" && ok "TRUNK_PORT outside the ports refused" || bad "TRUNK_PORT=9" "$out"
out="$(TRUNK_PORT=1 run --config "$(mkconf 1)" --show-ports)"; [[ $? -ne 0 ]] && grep -q "cluster interconnect port" <<< "$out" && ok "TRUNK_PORT on interconnect refused" || bad "TRUNK_PORT=1" "$out"
out="$(TRUNK_VLANS='100;x' run --config "$(mkconf 1)" --show-ports)"; [[ $? -ne 0 ]] && ok "TRUNK_VLANS syntax checked" || bad "TRUNK_VLANS syntax" "$out"
out="$(TRUNK_PORT=none run --config "$(mkconf 1)" --show-ports)"
grep -q "^  qm set 92 --net5 e1000,bridge=vmbr0,tag=50$" <<< "$out" && ok "TRUNK_PORT=none puts net5 back on the data network" || bad "TRUNK_PORT=none" "$out"
out="$(TRUNK_VLANS='100-102' run --config "$(mkconf 1)" --show-ports)"
grep -q "^  qm set 92 --net5 e1000,bridge=vmbr1,trunks=100-102$" <<< "$out" && ok "TRUNK_VLANS range accepted" || bad "range" "$out"

echo ""
echo "== $PASS OK, $FAIL FOUT"
(( FAIL == 0 ))
