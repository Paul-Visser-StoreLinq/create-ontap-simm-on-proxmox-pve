#!/usr/bin/env bash
# =============================================================================
# tests/test_network.sh — network mapping and bridge/VLAN precheck (v3.3; ranges in bridge-vids)
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
  /cluster/resources) if [[ -f "$FX/resources.json" ]]; then cat "$FX/resources.json"; else echo '[]'; fi ;;
  /nodes/*/qemu/*/config)
    v="${path%/config}"; v="${v##*/}"
    f="$FX/qemu-$v.json"; [[ -f "$f" ]] && { cat "$f"; exit 0; }
    echo "Configuration file 'qemu-server/$v.conf' does not exist" >&2; exit 2 ;;
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
  local nd
  rm -f "$FX"/net-*.json
  for nd in pve02 pve04; do
    fx "$nd" vmbr0 1 "30 50 99"
    fx "$nd" vmbr1 1 "10 20 30 40 51 52 53 100-102"
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

echo "== ifgroup advice (v3.4)"
out="$(run --config "$(mkconf 1)" --show-ports)"
! grep -q "multimode_lacp" <<< "$(grep -v '^  #' <<< "$out")" && grep -q "ifgrp create -node <node> -ifgrp a0a -distr-func port -mode singlemode" <<< "$out" \
  && ok "advice uses singlemode, no multimode_lacp command" || bad "advice mode" "$out"
adv="$(sed -n '/ifgroup a0a (e0c e0d)/,/ifgroup a0b/p' <<< "$out")"
ln() { grep -nF -- "$1" <<< "$adv" | head -1 | cut -d: -f1; }
l_park=$(ln "-lif cluster_mgmt -home-node <node2> -home-port e0c"); l_add_d=$(ln "-ifgrp a0a -port e0d")
l_back=$(ln "-lif cluster_mgmt -home-node <node1> -home-port a0a"); l_nm=$(ln "-lif <node-mgmt-LIF van node> -home-port a0a")
l_add_c=$(ln "-ifgrp a0a -port e0c"); l_bd_d=$(ln "-ports <node>:e0d")
if [[ -n "$l_park" && -n "$l_add_d" && -n "$l_back" && -n "$l_nm" && -n "$l_add_c" && -n "$l_bd_d" ]] \
   && (( l_park < l_bd_d && l_bd_d < l_add_d && l_add_d < l_back && l_back < l_nm && l_nm < l_add_c )); then
  ok "a0a: LIFs leave e0d/e0c before add-port; cluster_mgmt back to node 1 before node-mgmt moves"
else bad "a0a order park=$l_park bd=$l_bd_d add_d=$l_add_d back=$l_back nm=$l_nm add_c=$l_add_c" "$adv"; fi
out2="$(CLUSTER_MGMT_PORT=e0g run --config "$(mkconf 1)" --show-ports)"
grep -q "cluster_mgmt -home-node <node2>" <<< "$out2" && bad "no parking when cluster_mgmt is not in a0a" "$out2" || ok "no cluster_mgmt parking when CLUSTER_MGMT_PORT is outside the ifgroups"
grep -q "Stap 1 (per node): a0a maken met e0d" <<< "$out2" && ok "step numbering starts at 1 without parking" || bad "numbering" "$out2"

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

echo "== bridge-vids with ranges and combinations"
vids_ok() { # name vmbr0-vids vmbr1-vids
  local name="$1" n
  rm -f "$FX"/net-*.json
  for nd in pve02 pve04; do fx "$nd" vmbr0 1 "$2"; fx "$nd" vmbr1 1 "$3"; done
  for n in 1 2 3; do
    out="$(run --config "$(mkconf $n)" --dry-run)"; rc=$?
    if [[ $rc -ne 0 ]] || ! grep -q "All prechecks passed" <<< "$out"; then bad "$name (cluster$n rc=$rc)" "$out"; return; fi
  done
  ok "$name"
}
vids_ok "vmbr1 live pve02/pve04 02-11-2026 (with duplicate 53)" "30 50 99" "10 20 30 40 51 52 53 100 101 102 53"
vids_ok "vmbr0 and vmbr1 2-4094" "2-4094" "2-4094"
vids_ok "vmbr1 '10 20 50-53 100-102'" "30 50 99" "10 20 50-53 100-102"
vids_ok "range boundaries exact: vmbr0 50-50, vmbr1 51-53 100-102" "50-50" "51-53 100-102"
vids_ok "comma-separated: vmbr0 '30,50,99', vmbr1 '51,52,53,100-102'" "30,50,99" "51,52,53,100-102"
vids_ok "range around the VLAN: vmbr0 2-99, vmbr1 10-200" "2-99" "10-200"
good_fixtures; fx pve02 vmbr1 1 "10 20 50-52 100-102"
expect_fail "range 50-52 lacks 53 (cluster3)" "bridge 'vmbr1' on node pve02 does not carry VLAN\(s\) 53 \(bridge-vids: 10 20 50-52 100-102\)" --config "$(mkconf 3)" --dry-run
good_fixtures; fx pve04 vmbr1 1 "51-53 100-101"
expect_fail "range 100-101 lacks trunk VLAN 102" "does not carry VLAN\(s\) 102" --config "$(mkconf 1)" --dry-run
good_fixtures; fx pve02 vmbr0 1 "2-49 51-4094"
expect_fail "VLAN 50 in the gap between two ranges" "bridge 'vmbr0' on node pve02 does not carry VLAN\(s\) 50" --config "$(mkconf 1)" --dry-run
good_fixtures; fx pve02 vmbr1 1 "102-100"
expect_fail "reversed range refused" "bridge-vids of 'vmbr1' on node pve02 cannot be read: '102-100'" --config "$(mkconf 1)" --dry-run
good_fixtures; fx pve02 vmbr1 1 "2-5000"
expect_fail "range beyond 4094 refused" "cannot be read: '2-5000'" --config "$(mkconf 1)" --dry-run
good_fixtures; fx pve04 vmbr0 1 "50 abc"
expect_fail "garbage in bridge-vids refused" "bridge-vids of 'vmbr0' on node pve04 cannot be read" --config "$(mkconf 1)" --dry-run

echo "== --dry-run with existing VMs (the sim VMs exist again since 02-11-2026)"
# qemu fixture: vmid, then 8 net specs (as qm config shows them, with MAC)
qfx() { local v="$1"; shift; local i=0 js="{\"name\":\"lab-cluster-x\"" n
  for n in "$@"; do js+=",\"net$i\":\"$n\""; i=$((i+1)); done
  echo "$js}" > "$FX/qemu-$v.json"; }
good_vm() { # vmid N
  local v="$1" n="$2" m
  m="BC:24:11:00:0$n:"
  qfx "$v" "e1000=${m}00,bridge=vmbr1,tag=5$n" "e1000=${m}01,bridge=vmbr1,tag=5$n,firewall=0" \
    "e1000=${m}02,bridge=vmbr0,tag=50" "e1000=${m}03,bridge=vmbr0,tag=50" "e1000=${m}04,bridge=vmbr0,tag=50" \
    "e1000=${m}05,bridge=vmbr1,trunks=100;101;102" "e1000=${m}06,bridge=vmbr0,tag=50" "e1000=${m}07,bridge=vmbr0,tag=50"; }
existing() { # N: both VMs of cluster N exist on pve02/pve04 with correct NICs
  local n="$1" v1 v2
  v1=$((90+2*n)); v2=$((91+2*n))
  printf '[{"vmid":%d,"node":"pve02","name":"lab-cluster0%d-01"},{"vmid":%d,"node":"pve04","name":"lab-cluster0%d-02"}]\n' "$v1" "$n" "$v2" "$n" > "$FX/resources.json"
  good_vm "$v1" "$n"; good_vm "$v2" "$n"; }
for n in 1 2 3; do
  good_fixtures; existing "$n"
  out="$(run --config "$(mkconf $n)" --dry-run)"; rc=$?
  if [[ $rc -eq 0 ]] && grep -q "already exists: a real deploy stops here" <<< "$out" \
     && grep -q "All NICs of the existing VMs match the plan" <<< "$out" && ! grep -q "DIFF" <<< "$out"; then
    ok "existing cluster$n with correct NICs: dry-run passes (MAC and firewall= ignored)"
  else bad "existing cluster$n rc=$rc" "$out"; fi
done
good_fixtures; existing 1
qfx 92 "e1000=BC:24:11:00:01:00,bridge=vmbr0,tag=51" "e1000=BC:24:11:00:01:01,bridge=vmbr0,tag=51" \
  "e1000=BC:24:11:00:01:02,bridge=vmbr1,tag=50" "e1000=BC:24:11:00:01:03,bridge=vmbr1,tag=50" "e1000=BC:24:11:00:01:04,bridge=vmbr1,tag=50" \
  "e1000=BC:24:11:00:01:05,bridge=vmbr1,tag=50" "e1000=BC:24:11:00:01:06,bridge=vmbr1,tag=50" "e1000=BC:24:11:00:01:07,bridge=vmbr1,tag=50"
out="$(run --config "$(mkconf 1)" --dry-run)"; rc=$?
if [[ $rc -ne 0 ]] && grep -q "net0: DIFF  now e1000,bridge=vmbr0,tag=51   plan e1000,bridge=vmbr1,tag=51" <<< "$out" \
   && grep -q "net5: DIFF  now e1000,bridge=vmbr1,tag=50   plan e1000,bridge=vmbr1,trunks=100;101;102" <<< "$out" \
   && grep -q "existing VM(s) differ from the plan" <<< "$out"; then ok "existing VM with swapped bridges (old VM 100): DIFF and exit 1"
else bad "existing swapped (rc=$rc)" "$out"; fi
good_fixtures; existing 2
printf '[{"vmid":94,"node":"pve04","name":"x"},{"vmid":95,"node":"pve04","name":"y"}]\n' > "$FX/resources.json"
out="$(run --config "$(mkconf 2)" --dry-run)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "VM 94 is on node pve04, the plan puts it on pve02" <<< "$out" && ok "existing VM on the wrong node: exit 1" || bad "wrong node (rc=$rc)" "$out"
good_fixtures; existing 3; good_vm 97 3
python3 -c 'import json,sys;f=sys.argv[1];d=json.load(open(f));d["net8"]="e1000=BC:24:11:00:03:08,bridge=vmbr0";json.dump(d,open(f,"w"))' "$FX/qemu-97.json"
out="$(run --config "$(mkconf 3)" --dry-run)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "net8: DIFF  extra NIC e1000" <<< "$out" && ok "extra NIC on an existing VM: DIFF" || bad "extra NIC (rc=$rc)" "$out"
good_fixtures; existing 1
out="$(run --config "$(mkconf 1)" </dev/null)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "ERROR: VMID1=92 is already in use in the cluster" <<< "$out" && ! grep -q "stub qm must not be called" <<< "$out" \
  && ok "real deploy with an existing VMID still stops before qm" || bad "deploy existing VMID (rc=$rc)" "$out"
rm -f "$FX/resources.json" "$FX"/qemu-*.json

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
