#!/usr/bin/env bash
# =============================================================================
#  ontap-sim-2node-proxmox.sh
#  NetApp ONTAP Simulator — automatic 2-node cluster deployment on Proxmox
# After downloading, make the script executable: `chmod +x ontap-sim-2node-proxmox.sh`
# =============================================================================
#
# VERSION HISTORY
# ---------------
# Format: v{MAJOR}.{MINOR}  {DD-MM-YYYY}  {Description}
#
# MAJOR increments on major functional changes (new approach, different behavior)
# MINOR increments on bugfixes, minor improvements or adjustments
# Date is the actual date the change was made
#
# v1.0  17-04-2026  Initial version: basic 2-node OVA import on Proxmox
# v1.1  17-04-2026  Fixed disk import order (sort -V); replaced global NODE_DISKS
#                   with local nameref arrays per VM
# v1.2  17-04-2026  Added VLOADER serial console automation via expect;
#                   fixed serial socket race condition
# v1.3  17-04-2026  Normalized hostname comparison (case-insensitive)
#                   so local node is recognized correctly without SSH
# v1.4  17-04-2026  Added cluster-wide VM-name check; changed naming
#                   to {prefix}-cluster{NN}-01 / -02 schema
# v1.5  17-04-2026  VMID allocation cluster-wide via pvesh; prevents conflict
#                   with VMs on nodes other than where script runs
# v1.6  17-04-2026  Extended API-precheck with retry-loop (5 attempts);
#                   storage-type check for VG-validation (skip for dir/nfs)
# v1.7  17-04-2026  Updated defaults: OVA_STORAGE_ID=software,
#                   TARGET_NODE1=pve01, TARGET_NODE2=pve02
# v2.0  17-04-2026  Replaced VLOADER-automation via serial console with
#                   direct guestfish-inject into /env/env on disk1 before import;
#                   both nodes get unique serial number based on VMID
# v2.1  17-04-2026  Fixed /env/env write syntax to VLOADER format:
#                   "setenv NAME \"VALUE\"" instead of KEY=VALUE
# v2.2  17-04-2026  Inject script sent via SSH stdin with env-variables;
#                   prevents path issues on remote nodes (VMDK not local)
# v2.3  17-04-2026  Fixed verification after inject: check tmpfile content
#                   instead of re-reading VMDK (NFS kernel cache issue)
# v2.4  17-04-2026  Fixed inject path passing: disk1 path is now always
#                   re-looked up on target node if empty;
#                   added explicit debug-logging for inject path
#
# v2.5  17-04-2026  Moved inject from VMDK to imported RAW disk;
#                   guestfish upload to RAW disk works reliably
# v2.6  17-04-2026  Set fixed ONTAP Simulator license serials:
#                   node1=4082368-50-7/4082368507, node2=4034389-06-2/4034389062
# v2.7  28-04-2026  Configurable NUM_NET_PORTS; dynamische poort-toewijzing:
#                   net0+net1=cluster, rest gelijk verdeeld over
#                   cifs (ifgroup a0a) / nfs (ifgroup a0b) / iscsi (individueel)
# v2.8  29-04-2026  SSH_OPTS uitgebreid met StrictHostKeyChecking=accept-new;
#                   oplossing voor "Host key verification failed" bij eerste
#                   verbinding naar nodes die nog niet in known_hosts staan
# v2.9  29-04-2026  CIFS_BRIDGE/CIFS_VLAN_TAG toegevoegd; CIFS-poorten krijgen
#                   eigen bridge (vmbr0), cluster/nfs/iscsi blijven op DATA_BRIDGE
# =============================================================================
#
# DESCRIPTION
# -----------
# This script automatically deploys a NetApp ONTAP Simulator 2-node cluster
# on a Proxmox VE cluster. It handles the following steps:
#
#   1. Prechecks  — API access, storage availability, OVA readability
#   2. VMID       — Cluster-wide allocation of two unique VMIDs
#   3. Naming     — Automatic cluster number (sim-cluster01-01 / -02)
#   4. VM create  — Both VMs are created on the specified nodes
#   5. OVA import — The 4 VMDKs are unpacked and imported per node
#   6. Identity   — Unique SYS_SERIAL_NUM and SYSID are written via guestfish
#                   directly to loader.conf on disk1 before import
#   7. Config     — Disks attached to IDE0-3, boot order set
#
# REQUIREMENTS
# ------------
#   - Proxmox VE 7.x or 8.x cluster with at least 2 nodes
#   - pvesh, qm, pvesm available (standard on Proxmox)
#   - SSH BatchMode access from executing node to all target nodes
#   - python3 available on executing node
#   - libguestfs-tools (guestfish) — installed automatically if needed
#   - ONTAP Simulator OVA (vsim-netapp-DOT9.16.1-cm_nodar.ova) present
#     on the storage accessible via OVA_STORAGE_ID
#
# USAGE
# -----
#   Basic (using default config file):
#     ./ontap-sim-2node-proxmox.sh
#
#   With custom config file:
#     ./ontap-sim-2node-proxmox.sh --config /path/to/custom.conf
#
#   Using CONFIG_FILE environment variable:
#     CONFIG_FILE=/path/to/custom.conf ./ontap-sim-2node-proxmox.sh
#
#   Override config settings with environment variables:
#     TARGET_NODE1=pve03 TARGET_NODE2=pve04 ./ontap-sim-2node-proxmox.sh
#
#   Force a specific cluster number:
#     CLUSTER_NUM=3 ./ontap-sim-2node-proxmox.sh
#
#   Start VMs directly after creation:
#     START_AFTER_CREATE=1 ./ontap-sim-2node-proxmox.sh
#
# CONFIGURATION FILE
# ------------------
# All settings are stored in ontap-sim-2node-proxmox.conf.
# To use custom settings:
#   1. Copy the default config: cp ontap-sim-2node-proxmox.conf my-config.conf
#   2. Edit my-config.conf with your desired values
#   3. Pass it to the script: ./ontap-sim-2node-proxmox.sh --config my-config.conf
#
# Available settings in the config file:
#   - Storage: VM_STORAGE, OVA_STORAGE_ID, OVA_DIR, OVA_NAME
#   - Nodes: TARGET_NODE1, TARGET_NODE2, VMID1, VMID2
#   - Network: DATA_BRIDGE, DATA_VLAN_TAG, NUM_NET_PORTS
#   - Hardware: CORES, SOCKETS, MEMORY_MB, CPU_TYPE, NET_MODEL
#   - ONTAP: NODE1_SYS_SERIAL_NUM, NODE1_SYSID, NODE2_SYS_SERIAL_NUM, NODE2_SYSID
#   - Runtime: WORKDIR, EXPECT_TIMEOUT, DISK_FORMAT
#
# Environment variables override config file values.
#
# NAMING AND DEFAULTS
# --------------------
# All configurable settings are in ontap-sim-2node-proxmox.conf.
# See that file for all available options and their defaults.
#
# VMs are automatically named according to the schema:
#   {CLUSTER_PREFIX}-cluster{NN}-01  (node1)
#   {CLUSTER_PREFIX}-cluster{NN}-02  (node2)
#
# The cluster number NN is automatically incremented if a cluster already exists.
# Example: if sim-cluster01-01 and sim-cluster01-02 already exist, the
# new VMs will be sim-cluster02-01 and sim-cluster02-02.
#
# SERIAL NUMBERS
# ---------------
# The ONTAP Simulator uses fixed license serials that are identical for every
# 2-node cluster:
#   Node1: SYS_SERIAL_NUM=4082368-50-7   SYSID=4082368507
#   Node2: SYS_SERIAL_NUM=4034389-06-2   SYSID=4034389062
#
# These are written via guestfish to /env/env on the imported RAW disk
# after import, so ONTAP has the correct identity and licenses on first boot.
# Values can be overridden via:
#   NODE1_SYS_SERIAL_NUM / NODE1_SYSID
#   NODE2_SYS_SERIAL_NUM / NODE2_SYSID
#
# NEXT STEPS AFTER EXECUTION
# ----------------------------
# 1. Start node1:   ssh {TARGET_NODE1} qm start {VMID1}
# 2. Connect console: Proxmox webinterface > VM > Console
#    or serial:    ssh {TARGET_NODE1} qm terminal {VMID1}
# 3. Go through ONTAP cluster setup wizard on node1
# 4. Join node2 via cluster-interconnect network
#
# =============================================================================

set -euo pipefail

# Default config file location
CONFIG_FILE="${CONFIG_FILE:-./ontap-sim-2node-proxmox.conf}"

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_FILE="$2"
      shift 2
      ;;
    --help|-h)
      cat <<HELP
Usage: $(basename "$0") [OPTIONS]

Options:
  --config FILE    Path to configuration file
                   Default: ./ontap-sim-2node-proxmox.conf
  --help           Show this help message

Configuration:
  Settings are read from the config file. Copy ontap-sim-2node-proxmox.conf
  and customize as needed, then pass it:
    $(basename "$0") --config my-custom-config.conf

  Or set CONFIG_FILE environment variable:
    CONFIG_FILE=my-config.conf $(basename "$0")

Environment variables override config file values:
  TARGET_NODE1=pve01 TARGET_NODE2=pve02 $(basename "$0")
HELP
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Use --help for usage information" >&2
      exit 1
      ;;
  esac
done

# Verify config file exists
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Config file not found: $CONFIG_FILE" >&2
  exit 1
fi

# Source configuration file
# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Allow environment variables to override config file values
VM_STORAGE="${VM_STORAGE:-datastore_ds02}"
OVA_STORAGE_ID="${OVA_STORAGE_ID:-software}"
OVA_DIR="${OVA_DIR:-/mnt/pve/${OVA_STORAGE_ID}/template/iso}"
OVA_NAME="${OVA_NAME:-vsim-netapp-DOT9.16.1-cm_nodar.ova}"
CLUSTER_PREFIX="${CLUSTER_PREFIX:-sim}"
CLUSTER_NUM="${CLUSTER_NUM:-auto}"
VMID1="${VMID1:-auto}"
VMID2="${VMID2:-auto}"
TARGET_NODE1="${TARGET_NODE1:-pve01}"
TARGET_NODE2="${TARGET_NODE2:-pve02}"
DATA_BRIDGE="${DATA_BRIDGE:-vmbr1}"
DATA_VLAN_TAG="${DATA_VLAN_TAG:-20}"
CIFS_BRIDGE="${CIFS_BRIDGE:-vmbr0}"
CIFS_VLAN_TAG="${CIFS_VLAN_TAG:-0}"
NUM_NET_PORTS="${NUM_NET_PORTS:-8}"
CORES="${CORES:-2}"
SOCKETS="${SOCKETS:-1}"
MEMORY_MB="${MEMORY_MB:-6144}"
CPU_TYPE="${CPU_TYPE:-SandyBridge}"
NET_MODEL="${NET_MODEL:-e1000}"
START_AFTER_CREATE="${START_AFTER_CREATE:-0}"
AUTOMATE_NODE2_SYSID="${AUTOMATE_NODE2_SYSID:-1}"
NODE1_SYS_SERIAL_NUM="${NODE1_SYS_SERIAL_NUM:-4082368-50-7}"
NODE1_SYSID="${NODE1_SYSID:-4082368507}"
NODE2_SYS_SERIAL_NUM="${NODE2_SYS_SERIAL_NUM:-4034389-06-2}"
NODE2_SYSID="${NODE2_SYSID:-4034389062}"
WORKDIR="${WORKDIR:-/var/tmp/ontap-sim-9.16.1}"
EXPECT_TIMEOUT="${EXPECT_TIMEOUT:-360}"
SSH_OPTS="${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new}"
DISK_FORMAT="${DISK_FORMAT:-raw}"

# Initialize VM names (will be set in alloc_vmids())
VMNAME1=""
VMNAME2=""

# ---------- Helpers ----------

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: required command missing: $1" >&2; exit 1; }
}

for cmd in qm tar awk sed grep find timeout pvesh pvesm hostname ssh python3; do
  require_cmd "$cmd"
done

mkdir -p "$WORKDIR"
cd "$WORKDIR"

run_on_node() {
  local node="$1"
  shift
  # Compare both short and long hostname, normalize case
  local short_host long_host node_lower
  short_host="$(hostname -s 2>/dev/null || true)"
  long_host="$(hostname 2>/dev/null || true)"
  node_lower="${node,,}"
  if [[ "${node_lower}" == "${short_host,,}" || "${node_lower}" == "${long_host,,}" ]]; then
    "$@"
  else
    ssh $SSH_OPTS "$node" "$(printf '%q ' "$@")"
  fi
}

install_expect_if_missing() {
  if ! command -v expect >/dev/null 2>&1; then
    echo "expect missing; installing via apt" >&2
    apt-get update -qq -o APT::Update::Error-Mode=any 2>/dev/null || true
    apt-get install -y expect >/dev/null
  fi
}

next_vmid() {
  pvesh get /cluster/nextid
}

# Check cluster-wide whether a VMID is already in use (on any node)
vmid_in_use_cluster() {
  local vmid="$1"
  pvesh get /cluster/resources --type vm --output-format json 2>/dev/null     | python3 -c "
import sys, json
try:
    vms = json.load(sys.stdin)
    ids = [str(vm.get('vmid','')) for vm in vms]
    print('yes' if '${vmid}' in ids else 'no')
except Exception:
    print('no')
" 2>/dev/null || echo "no"
}

# Returns the next cluster-wide free VMID starting from start_id
next_free_vmid_from() {
  local start_id="$1"
  local vmid="$start_id"
  # Get all used VMIDs at once
  local used_ids
  used_ids=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null     | python3 -c "
import sys, json
try:
    vms = json.load(sys.stdin)
    print(' '.join(str(vm.get('vmid','')) for vm in vms))
except Exception:
    pass
" 2>/dev/null || true)
  while echo " $used_ids " | grep -q " $vmid "; do
    vmid=$(( vmid + 1 ))
  done
  echo "$vmid"
}

# Get all existing VM names from the entire cluster (all nodes)
get_all_vm_names() {
  pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
    | python3 -c "
import sys, json
try:
    vms = json.load(sys.stdin)
    for vm in vms:
        name = vm.get('name', '')
        if name:
            print(name)
except Exception:
    pass
" 2>/dev/null || true
}

# Determine the next free cluster number for the given prefix.
# Looks for names like "{prefix}-cluster01-01" and returns the first free number.
next_free_cluster_num() {
  local prefix="$1"
  local all_names="$2"
  local n=1
  while true; do
    local cluster_id
    cluster_id="$(printf '%02d' "$n")"
    local name1="${prefix}-cluster${cluster_id}-01"
    local name2="${prefix}-cluster${cluster_id}-02"
    # Cluster number is free if BOTH names don't exist yet
    if ! grep -qx "$name1" <<< "$all_names" 2>/dev/null && \
       ! grep -qx "$name2" <<< "$all_names" 2>/dev/null; then
      echo "$cluster_id"
      return
    fi
    n=$(( n + 1 ))
    if [[ $n -gt 99 ]]; then
      echo "ERROR: no free cluster number found (1-99)" >&2
      exit 1
    fi
  done
}

alloc_vmids() {
  echo "[precheck] Allocate VMIDs cluster-wide..."
  if [[ "$VMID1" == "auto" ]]; then
    VMID1="$(next_vmid)"
  fi
  # Check VMID1 cluster-wide (pvesh nextid checks this already, but not for manual assignment)
  if [[ "$(vmid_in_use_cluster "$VMID1")" == "yes" ]]; then
    echo "ERROR: VMID1=$VMID1 is already in use in the cluster" >&2
    exit 1
  fi

  if [[ "$VMID2" == "auto" ]]; then
    # Look cluster-wide for the next free VMID after VMID1
    VMID2="$(next_free_vmid_from $(( VMID1 + 1 )))"
  fi
  # Check VMID2 cluster-wide
  if [[ "$(vmid_in_use_cluster "$VMID2")" == "yes" ]]; then
    echo "ERROR: VMID2=$VMID2 is already in use in the cluster" >&2
    exit 1
  fi

  if [[ "$VMID1" == "$VMID2" ]]; then
    echo "ERROR: VMID1 and VMID2 are the same" >&2
    exit 1
  fi
  echo "  VMID1=$VMID1  VMID2=$VMID2"

  # Determine free cluster number and set VM names
  echo "[precheck] Check existing cluster names in Proxmox..."
  local all_names
  all_names="$(get_all_vm_names)"

  local cluster_id
  if [[ "$CLUSTER_NUM" == "auto" ]]; then
    cluster_id="$(next_free_cluster_num "$CLUSTER_PREFIX" "$all_names")"
  else
    cluster_id="$(printf '%02d' "$CLUSTER_NUM")"
    # Validate that the specified number is actually free
    local n1="${CLUSTER_PREFIX}-cluster${cluster_id}-01"
    local n2="${CLUSTER_PREFIX}-cluster${cluster_id}-02"
    if grep -qx "$n1" <<< "$all_names" 2>/dev/null || \
       grep -qx "$n2" <<< "$all_names" 2>/dev/null; then
      echo "ERROR: CLUSTER_NUM=$CLUSTER_NUM is already in use ($n1 or $n2 already exists)" >&2
      exit 1
    fi
  fi

  VMNAME1="${CLUSTER_PREFIX}-cluster${cluster_id}-01"
  VMNAME2="${CLUSTER_PREFIX}-cluster${cluster_id}-02"

  echo "  Cluster number  : $cluster_id"
  echo "  VMNAME1         : $VMNAME1"
  echo "  VMNAME2         : $VMNAME2"
}

# FIX: node2 identity based on VMID2 (was already correct), but we now also
#      generate a unique NODE1 equivalent so both are always different.
#      Node1 uses the OVA-default NVRAM; node2 gets a different serial.
derive_node_identities() {
  # Fixed license serials for ONTAP Simulator — not calculated
  echo "[identity] Node1: SYS_SERIAL_NUM=$NODE1_SYS_SERIAL_NUM  SYSID=$NODE1_SYSID"
  echo "[identity] Node2: SYS_SERIAL_NUM=$NODE2_SYS_SERIAL_NUM  SYSID=$NODE2_SYSID"
}

check_api_create_path() {
  local node="$1"
  local max_retries=5
  local wait_sec=6
  local attempt=1
  local err

  while [[ $attempt -le $max_retries ]]; do
    if err=$(pvesh get "/nodes/${node}/qemu" 2>&1); then
      return 0
    fi
    echo "  [precheck] API not reachable for $node (attempt $attempt/$max_retries): $err" >&2
    if [[ $attempt -lt $max_retries ]]; then
      echo "  [precheck] Wait ${wait_sec}s for next attempt..." >&2
      sleep "$wait_sec"
    fi
    attempt=$(( attempt + 1 ))
  done

  echo "ERROR: API precheck failed for /nodes/${node}/qemu after $max_retries attempts" >&2
  echo "  Possible causes:" >&2
  echo "  - Node $node is offline or unreachable in the cluster" >&2
  echo "  - Corosync/pve-cluster service is not active" >&2
  echo "  - Check: pvesh get /nodes/${node}/status" >&2
  return 1
}

validate_api_access() {
  for node in "$TARGET_NODE1" "$TARGET_NODE2"; do
    echo "[precheck] Check API access for VM creation on node: $node"
    check_api_create_path "$node" || exit 1
  done
}

node_online() {
  local node="$1"
  pvesh get /nodes/"$node"/status >/dev/null 2>&1
}

check_storage_reachable_for_node() {
  local node="$1"
  local storage_id="$2"
  local out
  if ! out=$(pvesm status --storage "$storage_id" --target "$node" 2>/dev/null | awk 'NR>1 {print $3, $2}'); then
    echo "ERROR: could not query storage status for $storage_id on node $node" >&2
    return 1
  fi
  [[ -n "$out" ]] || { echo "ERROR: storage $storage_id is not visible/allowed for node $node" >&2; return 1; }
  local active type
  active=$(echo "$out" | awk '{print $1}')
  type=$(echo "$out" | awk '{print $2}')
  if [[ "$active" != "active" ]]; then
    echo "ERROR: storage $storage_id is not active on node $node (status: $active, type: $type)" >&2
    return 1
  fi
  return 0
}

check_ova_path_reachable_for_node() {
  local node="$1"
  local path="$2"
  local ova_file
  ova_file="$(basename "$path")"

  # Primaire methode: Proxmox storage-content API — werkt via cluster-proxy,
  # geen SSH-sleutels nodig tussen uitvoerende node en target.
  if pvesh get "/nodes/${node}/storage/${OVA_STORAGE_ID}/content" \
       --output-format json 2>/dev/null \
     | python3 -c "
import sys, json
try:
    items = json.load(sys.stdin)
    for item in items:
        if item.get('volid','').endswith('/${ova_file}'):
            sys.exit(0)
    sys.exit(1)
except Exception:
    sys.exit(1)
" 2>/dev/null; then
    return 0
  fi

  # Fallback: directe bestandscheck via run_on_node (zelfde SSH-pad als rest van script)
  local err
  if err=$(run_on_node "$node" test -r "$path" 2>&1); then
    return 0
  fi
  echo "  [OVA check] API check én SSH check mislukt op $node." >&2
  echo "  SSH-fout: ${err:-geen foutmelding}" >&2
  echo "  Controleer: ssh $node test -r '$path'" >&2
  return 1
}

validate_node_access() {
  for node in "$TARGET_NODE1" "$TARGET_NODE2"; do
    echo "[precheck] Check node status: $node"
    node_online "$node" || { echo "ERROR: node $node is not reachable via Proxmox API" >&2; exit 1; }

    echo "[precheck] Check storage $OVA_STORAGE_ID on node $node"
    check_storage_reachable_for_node "$node" "$OVA_STORAGE_ID" || exit 1

    echo "[precheck] Check storage $VM_STORAGE on node $node"
    check_storage_reachable_for_node "$node" "$VM_STORAGE" || exit 1

    echo "[precheck] Check OVA readability on node $node: $OVA_PATH"
    check_ova_path_reachable_for_node "$node" "$OVA_PATH" || {
      echo "ERROR: OVA path not readable on node $node: $OVA_PATH" >&2
      exit 1
    }
  done
}

check_vg_on_all_nodes() {
  local vg="$1"

  # First check if VM_STORAGE is LVM or LVMthin storage.
  # For dir/nfs/cifs/zfs storage, VG-check is not applicable.
  local storage_type
  storage_type=$(awk -v sid="$VM_STORAGE" '
    $1 ~ /^(lvm:|lvmthin:|dir:|nfs:|cifs:|zfspool:)/ {
      type=$1; sub(/:$/,"",type)
      if ($2 == sid) { print type; exit }
    }
  ' /etc/pve/storage.cfg 2>/dev/null || true)

  if [[ "$storage_type" != "lvm" && "$storage_type" != "lvmthin" ]]; then
    echo "[precheck] Storage '$VM_STORAGE' is type '${storage_type:-unknown}'; VG-check skipped"
    return 0
  fi

  echo "[precheck] Check presence of VG '$vg' on all nodes that use $VM_STORAGE"

  local nodes
  nodes=$(awk -v sid="$VM_STORAGE" '
    $1 ~ /^(lvm:|lvmthin:)/ && $2 == sid {inblock=1; next}
    inblock && $1 == "nodes" {print $2; exit}
    inblock && $1 ~ /^(dir:|nfs:|cifs:|lvm:|lvmthin:|zfspool:)/ {exit}
  ' /etc/pve/storage.cfg 2>/dev/null || true)

  if [[ -z "${nodes:-}" ]]; then
    nodes=$(pvesh get /cluster/resources --type node --output-format json 2>/dev/null       | python3 -c "import sys,json; [print(n['node']) for n in json.load(sys.stdin) if n.get('type') == 'node']"       2>/dev/null || true)
  fi

  if [[ -z "${nodes:-}" ]]; then
    echo "[precheck] WARNING: could not determine node list for $VM_STORAGE; VG-check skipped" >&2
    return 0
  fi

  local failed=0
  for node in $nodes; do
    echo "  - node $node: check VG $vg"
    local check_cmd="vgs --noheadings -o vg_name 2>/dev/null | grep -qw '$vg'"
    if [[ "${node,,}" == "$(hostname -s 2>/dev/null || true)" || "${node,,}" == "$(hostname 2>/dev/null || true)" ]]; then
      if ! eval "$check_cmd"; then
        echo "ERROR: VG '$vg' not found on node $node" >&2
        failed=1
      fi
    else
      if ! ssh $SSH_OPTS "$node" "$check_cmd" 2>/dev/null; then
        echo "ERROR: VG '$vg' not found on node $node" >&2
        failed=1
      fi
    fi
  done
  [[ $failed -eq 0 ]] || exit 1
}

format_nic() {
  local bridge="$1"
  local tag="$2"
  if [[ "$tag" == "0" ]]; then
    echo "$NET_MODEL,bridge=$bridge"
  else
    echo "$NET_MODEL,bridge=$bridge,tag=$tag"
  fi
}

validate_num_ports() {
  if ! [[ "$NUM_NET_PORTS" =~ ^[0-9]+$ ]] || (( NUM_NET_PORTS < 4 )); then
    echo "ERROR: NUM_NET_PORTS moet een geheel getal >= 4 zijn (waarde: '$NUM_NET_PORTS')" >&2
    exit 1
  fi
  local remaining=$(( NUM_NET_PORTS - 2 ))
  if (( remaining % 3 != 0 )); then
    echo "ERROR: NUM_NET_PORTS=$NUM_NET_PORTS is ongeldig." >&2
    echo "  Na 2 cluster-poorten moeten de resterende $remaining poort(en)" >&2
    echo "  deelbaar zijn door 3 (gelijke verdeling: cifs / nfs / iscsi)." >&2
    echo "  Geldige waarden: 5, 8, 11, 14, ..." >&2
    exit 1
  fi
}

# Print ONTAP port-mapping en ifgroup-commando's voor na de cluster-setup.
print_port_info() {
  local ports_per_proto=$(( (NUM_NET_PORTS - 2) / 3 ))
  local letters="abcdefghijklmnopqrstuvwxyz"
  local i netid

  echo ""
  echo "Netwerk poort-mapping (per ONTAP node, ${NUM_NET_PORTS} poorten):"
  printf "  %-7s  %-5s  %-22s  %s\n" "Proxmox" "ONTAP" "Doel" "Bridge"
  printf "  %-7s  %-5s  %-22s  %s\n" "-------" "-----" "----" "------"
  for (( i=0; i<2; i++ )); do
    printf "  net%-4d e0%-4s %-22s  %s vlan %s\n" \
      "$i" "${letters:$i:1}" "cluster interconnect" "$DATA_BRIDGE" "$DATA_VLAN_TAG"
  done
  for (( i=0; i<ports_per_proto; i++ )); do
    netid=$(( 2 + i ))
    printf "  net%-4d e0%-4s %-22s  %s vlan %s\n" \
      "$netid" "${letters:$netid:1}" "cifs  (ifgroup a0a)" "$CIFS_BRIDGE" "$CIFS_VLAN_TAG"
  done
  for (( i=0; i<ports_per_proto; i++ )); do
    netid=$(( 2 + ports_per_proto + i ))
    printf "  net%-4d e0%-4s %-22s  %s vlan %s\n" \
      "$netid" "${letters:$netid:1}" "nfs   (ifgroup a0b)" "$DATA_BRIDGE" "$DATA_VLAN_TAG"
  done
  for (( i=0; i<ports_per_proto; i++ )); do
    netid=$(( 2 + 2*ports_per_proto + i ))
    printf "  net%-4d e0%-4s %-22s  %s vlan %s\n" \
      "$netid" "${letters:$netid:1}" "iscsi (individueel)" "$DATA_BRIDGE" "$DATA_VLAN_TAG"
  done

  echo ""
  echo "ONTAP ifgroup-commando's (uitvoeren per node na cluster-init):"
  echo "  # CIFS ifgroup a0a:"
  echo "  network port ifgrp create -node <node> -ifgrp a0a -distr-func port -mode multimode_lacp"
  for (( i=0; i<ports_per_proto; i++ )); do
    netid=$(( 2 + i ))
    echo "  network port ifgrp add-port -node <node> -ifgrp a0a -port e0${letters:$netid:1}"
  done
  echo ""
  echo "  # NFS ifgroup a0b:"
  echo "  network port ifgrp create -node <node> -ifgrp a0b -distr-func port -mode multimode_lacp"
  for (( i=0; i<ports_per_proto; i++ )); do
    netid=$(( 2 + ports_per_proto + i ))
    echo "  network port ifgrp add-port -node <node> -ifgrp a0b -port e0${letters:$netid:1}"
  done
  echo ""
  echo "  # iSCSI poorten (individueel, geen ifgroup):"
  for (( i=0; i<ports_per_proto; i++ )); do
    netid=$(( 2 + 2*ports_per_proto + i ))
    echo "  #   e0${letters:$netid:1}"
  done
}

cleanup_vm_and_orphaned_disks() {
  local vmid="$1"
  local target_node="$2"

  echo "[VM $vmid] Cleanup existing VM-config + orphaned disks on $target_node"

  if run_on_node "$target_node" qm status "$vmid" >/dev/null 2>&1; then
    run_on_node "$target_node" qm stop "$vmid" --skiplock 1 >/dev/null 2>&1 || true
    run_on_node "$target_node" qm destroy "$vmid" --destroy-unreferenced-disks 1 --purge 1 >/dev/null 2>&1 || true
  fi

  local vgname
  vgname=$(awk -v sid="$VM_STORAGE" '
    $1 ~ /^(lvm:|lvmthin:)/ && $2 == sid {inblock=1; next}
    inblock && $1 == "vgname" {print $2; exit}
    inblock && $1 ~ /^(dir:|nfs:|cifs:|lvm:|lvmthin:|zfspool:)/ {exit}
  ' /etc/pve/storage.cfg || true)

  if [[ -n "${vgname:-}" ]]; then
    run_on_node "$target_node" bash -lc "
      set -euo pipefail
      mapfile -t LVS_TO_REMOVE < <(lvs --noheadings -o lv_name '$vgname' 2>/dev/null | sed 's/^ *//' | grep '^vm-${vmid}-disk-' || true)
      if [[ \${#LVS_TO_REMOVE[@]} -gt 0 ]]; then
        echo '  leftover LVs on $target_node:' \"\${LVS_TO_REMOVE[*]}\"
        for lv in \"\${LVS_TO_REMOVE[@]}\"; do
          lvremove -fy '/dev/$vgname/'\"\$lv\" >/dev/null
        done
      fi
    "
  fi
}

ensure_machine_type() {
  local vmid="$1"
  local target_node="$2"
  run_on_node "$target_node" qm set "$vmid" --machine pc-i440fx-8.0 >/dev/null 2>&1 || \
  run_on_node "$target_node" qm set "$vmid" --machine pc-i440fx-7.2 >/dev/null 2>&1 || true
}

# FIX: prepare_vmdks_on_node now writes to a local nameref so
#      node1 and node2 don't overwrite each other (was global NODE_DISKS).
prepare_vmdks_on_node() {
  local target_node="$1"
  local -n _out_disks="$2"   # nameref: caller provides name of their own array
  local extract_dir="$WORKDIR/extracted-$target_node"

  echo "[node $target_node] Extract OVA locally on node in $extract_dir"
  run_on_node "$target_node" mkdir -p "$extract_dir"
  run_on_node "$target_node" bash -lc "rm -rf '$extract_dir'/* && tar -xf '$OVA_PATH' -C '$extract_dir'"

  # FIX: sort numerically (-V) so disk1 < disk2 < disk3 < disk4 is guaranteed
  mapfile -t _out_disks < <(run_on_node "$target_node" find "$extract_dir" -maxdepth 1 -type f -iname '*.vmdk' | sort -V)

  if [[ ${#_out_disks[@]} -lt 4 ]]; then
    echo "ERROR: fewer than 4 VMDK files found on node $target_node in $extract_dir" >&2
    run_on_node "$target_node" find "$extract_dir" -maxdepth 1 -type f >&2 || true
    exit 1
  fi

  _out_disks=("${_out_disks[0]}" "${_out_disks[1]}" "${_out_disks[2]}" "${_out_disks[3]}")
  echo "[node $target_node] VMDK order: ${_out_disks[*]}"
}

create_vm() {
  local vmid="$1"
  local name="$2"
  local target_node="$3"
  local do_inject="${4:-0}"   # optional: inject identity into VMDK before import
  # params 5 and 6: serial and sysid for inject (only used if do_inject=1)

  cleanup_vm_and_orphaned_disks "$vmid" "$target_node"

  echo "[VM $vmid] Create VM on host $target_node"
  pvesh create "/nodes/${target_node}/qemu" \
    --vmid "$vmid" \
    --name "$name" \
    --ostype l26 \
    --bios seabios \
    --scsihw virtio-scsi-single \
    --agent 0 \
    --cpu "$CPU_TYPE" \
    --cores "$CORES" \
    --sockets "$SOCKETS" \
    --memory "$MEMORY_MB" \
    --balloon 0 \
    --numa 0 \
    --tablet 0 \
    --onboot 0 \
    --serial0 socket \
    --vga std

  ensure_machine_type "$vmid" "$target_node"

  echo "[VM $vmid] Add $NUM_NET_PORTS network interfaces on $target_node"
  local _ports_per_proto=$(( (NUM_NET_PORTS - 2) / 3 ))
  local _cifs_end=$(( 2 + _ports_per_proto ))
  for (( _p=0; _p<NUM_NET_PORTS; _p++ )); do
    if (( _p >= 2 && _p < _cifs_end )); then
      # cifs-poorten → CIFS_BRIDGE
      run_on_node "$target_node" qm set "$vmid" "--net${_p}" "$(format_nic "$CIFS_BRIDGE" "$CIFS_VLAN_TAG")"
    else
      # cluster (0,1) + nfs + iscsi → DATA_BRIDGE
      run_on_node "$target_node" qm set "$vmid" "--net${_p}" "$(format_nic "$DATA_BRIDGE" "$DATA_VLAN_TAG")"
    fi
  done

  # FIX: use a per-VM local array (no global NODE_DISKS anymore)
  local -a node_disks=()
  prepare_vmdks_on_node "$target_node" node_disks

  echo "[VM $vmid] Import VMDKs in order 1..4 on $target_node"
  for vmdk in "${node_disks[@]}"; do
    run_on_node "$target_node" qm disk import "$vmid" "$vmdk" "$VM_STORAGE" --format "$DISK_FORMAT"
  done

  echo "[VM $vmid] Config after import on $target_node:"
  run_on_node "$target_node" qm config "$vmid" | grep -E '^(unused|ide|sata|scsi):' || true

  # FIX: wait until all 4 disks appear as unusedX in the config
  #      (LVM-import may take a few seconds to flush)
  echo "[VM $vmid] Waiting until 4 disks appear as unusedX in config..."
  local retries=0
  local -a imported_disks=()
  while [[ $retries -lt 30 ]]; do
    mapfile -t imported_disks < <(run_on_node "$target_node" qm config "$vmid" | awk -F': ' '/^unused[0-9]+: /{print $2}' | cut -d',' -f1)
    if [[ ${#imported_disks[@]} -ge 4 ]]; then
      break
    fi
    echo "  ...only ${#imported_disks[@]} found, waiting (attempt $((retries+1))/30)..."
    sleep 3
    retries=$((retries + 1))
  done

  if [[ ${#imported_disks[@]} -lt 4 ]]; then
    echo "ERROR: fewer than 4 imported disks (unusedX) found for VM $vmid on node $target_node after waiting" >&2
    run_on_node "$target_node" qm config "$vmid" >&2 || true
    exit 1
  fi

  # FIX: sort the unusedX entries by index (unused0, unused1, ...) so
  #      the attachment to ide0..ide3 is deterministic regardless of import order
  mapfile -t imported_disks < <(
    run_on_node "$target_node" qm config "$vmid" \
    | awk -F': ' '/^unused[0-9]+: /{print $1, $2}' \
    | sort -t'd' -k2 -n \
    | awk '{print $2}' \
    | cut -d',' -f1
  )

  # Wait until all LVs are actually active on target node before attaching.
  # qm disk import sometimes returns before lvchange -ay is fully complete.
  echo "[VM $vmid] Waiting until all LVs are active on $target_node..."
  local vgname
  vgname=$(awk -v sid="$VM_STORAGE" '
    $1 ~ /^(lvm:|lvmthin:)/ && $2 == sid {inblock=1; next}
    inblock && $1 == "vgname" {print $2; exit}
    inblock && $1 ~ /^(dir:|nfs:|cifs:|lvm:|lvmthin:|zfspool:)/ {exit}
  ' /etc/pve/storage.cfg 2>/dev/null || true)

  if [[ -n "${vgname:-}" ]]; then
    local lv_retries=0
    while [[ $lv_retries -lt 30 ]]; do
      local all_active=1
      for disk in "${imported_disks[@]}"; do
        # disk format: storage:vm-VMID-disk-N  -> LV name is vm-VMID-disk-N
        local lv_name="${disk#*:}"
        if ! run_on_node "$target_node" lvs --noheadings "/dev/${vgname}/${lv_name}"              >/dev/null 2>&1; then
          all_active=0
          break
        fi
      done
      if [[ $all_active -eq 1 ]]; then
        echo "  All LVs active on $target_node"
        break
      fi
      echo "  ...LVs not yet all active, waiting (attempt $((lv_retries+1))/30)..."
      sleep 2
      lv_retries=$(( lv_retries + 1 ))
    done
  fi

  # Wait until storage is online on target node before attaching disks.
  # After a series of disk imports, storage may be temporarily marked offline.
  echo "[VM $vmid] Waiting until storage '$VM_STORAGE' is online on $target_node..."
  local stor_retries=0
  while [[ $stor_retries -lt 60 ]]; do
    local stor_status
    stor_status=$(run_on_node "$target_node"       pvesm status --storage "$VM_STORAGE" 2>/dev/null | awk 'NR>1 {print $3}')
    if [[ "$stor_status" == "active" ]]; then
      echo "  Storage '$VM_STORAGE' is active on $target_node"
      break
    fi
    echo "  ...storage status='${stor_status:-unknown}', waiting (attempt $((stor_retries+1))/60)..."
    sleep 5
    stor_retries=$(( stor_retries + 1 ))
  done
  if [[ $stor_retries -ge 60 ]]; then
    echo "ERROR: storage '$VM_STORAGE' not online on $target_node after 5 minutes" >&2
    exit 1
  fi

  # Attach all 4 disks in a single qm set call to avoid race conditions
  echo "[VM $vmid] Attach imported disks to IDE0..IDE3 on $target_node"
  run_on_node "$target_node" qm set "$vmid"     --ide0 "${imported_disks[0]}"     --ide1 "${imported_disks[1]}"     --ide2 "${imported_disks[2]}"     --ide3 "${imported_disks[3]}"

  run_on_node "$target_node" bash -lc "
    set -euo pipefail
    for dev in sata0 sata1 sata2 sata3; do
      qm config '$vmid' | grep -q \"^\${dev}:\" && qm set '$vmid' --delete \"\${dev}\" || true
    done
  "

  # Inject identity into the imported RAW disk (disk-0) after import
  if [[ "$do_inject" == "1" ]]; then
    local inject_serial="${5:-}"
    local inject_sysid="${6:-}"
    # Determine the path of the imported disk-0 on the target node
    local raw_path
    raw_path=$(run_on_node "$target_node"       find "/mnt/pve/${VM_STORAGE}/images/${vmid}"       -maxdepth 1 -name "vm-${vmid}-disk-0.*" 2>/dev/null | head -1 || true)
    # Fallback: read path from qm config
    if [[ -z "$raw_path" ]]; then
      local disk0_cfg
      disk0_cfg=$(run_on_node "$target_node" qm config "$vmid"         | awk -F'[ ,]' '/^ide0:/{print $2}' | head -1)
      # disk0_cfg format: storage:vmid/vm-vmid-disk-0.raw
      raw_path="/mnt/pve/${disk0_cfg#*:}"
    fi
    echo "[VM $vmid] Inject identity into RAW disk: $raw_path"
    inject_identity_to_disk "$target_node" "$raw_path" "$inject_serial" "$inject_sysid"
  fi

  run_on_node "$target_node" qm set "$vmid" --boot order=ide0
  run_on_node "$target_node" qm set "$vmid" --description "NetApp ONTAP Simulator 9.16.1 two-node lab; ${NUM_NET_PORTS} ports op ${DATA_BRIDGE} (vlan ${DATA_VLAN_TAG}); host=${target_node}"

  echo "[VM $vmid] Final disk/boot config on $target_node:"
  run_on_node "$target_node" qm config "$vmid" | grep -E '^(boot|ide|sata|scsi|serial|vga):' || true

  if [[ "$START_AFTER_CREATE" == "1" ]]; then
    run_on_node "$target_node" qm start "$vmid"
  fi
}

# FIX: now waits for actual VLOADER-prompt via socat instead of just socket.
#      The socket exists as soon as QEMU starts; VLOADER comes later.
#      Increased retries (90x2s = 3 min) for slow LVM storage.
wait_for_serial_socket() {
  local vmid="$1"
  local node="$2"
  local sock="/var/run/qemu-server/${vmid}.serial0"
  echo "[VM $vmid] Waiting for serial socket $sock on $node..."
  local short_host long_host node_lower
  short_host="$(hostname -s 2>/dev/null || true)"
  long_host="$(hostname 2>/dev/null || true)"
  node_lower="${node,,}"
  for _ in $(seq 1 90); do
    if [[ "${node_lower}" == "${short_host,,}" || "${node_lower}" == "${long_host,,}" ]]; then
      [[ -S "$sock" ]] && { echo "$sock"; return 0; }
    else
      ssh $SSH_OPTS "$node" "test -S '$sock'" >/dev/null 2>&1 && { echo "$sock"; return 0; }
    fi
    sleep 2
  done
  echo "ERROR: serial socket $sock not found on $node after 3 minutes" >&2
  return 1
}

# Write NVRAM variables directly to loader.conf on disk1 of node2.
# This is more reliable than VLOADER interaction via serial console,
# because VLOADER is only available for a few seconds during boot.
inject_identity_to_disk() {
  local target_node="$1"
  local raw_disk="$2"    # full path to imported RAW disk on target_node
  local serial="$3"
  local sysid="$4"

  echo "[inject] SYS_SERIAL_NUM=$serial SYSID=$sysid -> $raw_disk on $target_node"

  local inject_script='
set -euo pipefail

echo "[inject] RAW disk: $INJ_DISK"
ls -lh "$INJ_DISK" || { echo "ERROR: RAW disk not found: $INJ_DISK" >&2; exit 1; }

# Install guestfish if needed
if ! command -v guestfish >/dev/null 2>&1; then
  echo "[inject] guestfish missing; installing..."
  apt-get update -qq -o APT::Update::Error-Mode=any 2>/dev/null || true
  apt-get install -y libguestfs-tools >/dev/null \
    || { echo "ERROR: could not install libguestfs-tools" >&2; exit 1; }
fi

PARTITION=/dev/sda2
ENV_PATH=/env/env

# Read existing content
EXISTING=$(guestfish --ro -a "$INJ_DISK" -m "$PARTITION" -- cat "$ENV_PATH" 2>/dev/null || true)

# Build new content
TMPFILE="${INJ_WORKDIR}/env_inject_$$.conf"
printf "%s\n" "$EXISTING" \
  | grep -v -E "^[[:space:]]*setenv[[:space:]]+(SYS_SERIAL_NUM|bootarg\.nvram\.sysid)[[:space:]]" \
  | sed "/^[[:space:]]*$/d" > "$TMPFILE"
printf "setenv SYS_SERIAL_NUM \"%s\"\n" "$INJ_SERIAL" >> "$TMPFILE"
printf "setenv bootarg.nvram.sysid \"%s\"\n" "$INJ_SYSID" >> "$TMPFILE"

echo "[inject] New /env/env:"
cat "$TMPFILE" | sed "s/^/  /"

# Upload to RAW disk
guestfish -a "$INJ_DISK" -m "$PARTITION" -- upload "$TMPFILE" "$ENV_PATH" \
  || { echo "ERROR: guestfish upload failed" >&2; rm -f "$TMPFILE"; exit 1; }
sync

# Verify
VERIFY=$(guestfish --ro -a "$INJ_DISK" -m "$PARTITION" -- cat "$ENV_PATH" 2>/dev/null || true)
if echo "$VERIFY" | grep -q "SYS_SERIAL_NUM.*$INJ_SERIAL"; then
  echo "[inject] Verification successful: SYS_SERIAL_NUM=$INJ_SERIAL"
else
  echo "ERROR: verification failed after writing" >&2
  echo "$VERIFY" | sed "s/^/  /" >&2
  rm -f "$TMPFILE"
  exit 1
fi

rm -f "$TMPFILE"
echo "[inject] Fully successful"
'

  local _sh _lh
  _sh="$(hostname -s 2>/dev/null || true)"
  _lh="$(hostname 2>/dev/null || true)"

  if [[ "${target_node,,}" == "${_sh,,}" || "${target_node,,}" == "${_lh,,}" ]]; then
    echo "[inject] Local execution on $(hostname -s)"
    INJ_DISK="$raw_disk" INJ_SERIAL="$serial" INJ_SYSID="$sysid" \
      INJ_WORKDIR="$WORKDIR" bash <<< "$inject_script"
  else
    echo "[inject] Remote execution on $target_node via SSH"
    ssh $SSH_OPTS "$target_node" bash -s << INJECT_EOF
export INJ_DISK='$raw_disk'
export INJ_SERIAL='$serial'
export INJ_SYSID='$sysid'
export INJ_WORKDIR='$WORKDIR'
$inject_script
INJECT_EOF
  fi
}

automate_node2_sysid() {
  local vmid="$1"
  local node="$2"
  local sock="$3"

  # Install expect locally and on remote node if needed
  install_expect_if_missing
  local _sh _lh
  _sh="$(hostname -s 2>/dev/null || true)"
  _lh="$(hostname 2>/dev/null || true)"
  if [[ "${node,,}" != "${_sh,,}" && "${node,,}" != "${_lh,,}" ]]; then
    if ! ssh $SSH_OPTS "$node" "command -v expect >/dev/null 2>&1"; then
      echo "[VM $vmid] expect missing on $node; installing..." >&2
      ssh $SSH_OPTS "$node" \
        "apt-get update -qq -o APT::Update::Error-Mode=any 2>/dev/null || true && apt-get install -y expect" \
        || { echo "ERROR: could not install expect on $node" >&2; exit 1; }
    fi
  fi

  # FIX: revised expect script:
  #   - Multiple \r sends to wake VLOADER if it has already passed
  #   - exp_continue after timeout so we keep polling
  #   - Explicit check that setenv commands are confirmed
  #   - After 'boot' wait for EOF or ONTAP banner instead of closing immediately
  #   - Identical script both locally and remote (was inconsistent)

  local expect_script
  expect_script=$(cat <<'EXPEOF'
set timeout $env(EXPECT_TIMEOUT)
set vmid $env(VMID)
set serial_num $env(NODE2_SYS_SERIAL_NUM)
set sysid $env(NODE2_SYSID)

spawn socat -,raw,echo=0 UNIX-CONNECT:/var/run/qemu-server/$vmid.serial0

# Send repeated enters until VLOADER> appears
proc wake_vloader {} {
    global timeout
    set old_timeout $timeout
    set timeout 5
    send "\r"
    expect {
        "VLOADER>" { set timeout $old_timeout; return 1 }
        timeout     { return 0 }
    }
    set timeout $old_timeout
    return 0
}

expect {
    "VLOADER>" { }
    timeout {
        # VLOADER not yet seen; keep sending enters
        set attempts 0
        while {$attempts < 20} {
            send "\r"
            expect {
                "VLOADER>" { break }
                timeout     { incr attempts; sleep 2 }
            }
        }
        if {$attempts >= 20} {
            puts stderr "ERROR: VLOADER> prompt not found after 20 attempts"
            exit 1
        }
    }
}

send "setenv SYS_SERIAL_NUM $serial_num\r"
expect {
    "VLOADER>" { }
    timeout { puts stderr "ERROR: no confirmation after setenv SYS_SERIAL_NUM"; exit 1 }
}

send "setenv bootarg.nvram.sysid $sysid\r"
expect {
    "VLOADER>" { }
    timeout { puts stderr "ERROR: no confirmation after setenv bootarg.nvram.sysid"; exit 1 }
}

send "printenv SYS_SERIAL_NUM\r"
expect {
    "$serial_num" { }
    timeout { puts stderr "WARNING: SYS_SERIAL_NUM not visible in printenv" }
}
expect "VLOADER>"

send "printenv bootarg.nvram.sysid\r"
expect {
    "$sysid" { }
    timeout { puts stderr "WARNING: sysid not visible in printenv" }
}
expect "VLOADER>"

puts "VLOADER vars set: SYS_SERIAL_NUM=$serial_num sysid=$sysid"
send "boot\r"

# Give VLOADER 2 seconds to process boot command,
# then close socat connection cleanly. ONTAP continues booting in background.
sleep 2
close
wait
EXPEOF
)

  local _sh _lh
  _sh="$(hostname -s 2>/dev/null || true)"
  _lh="$(hostname 2>/dev/null || true)"
  if [[ "${node,,}" != "${_sh,,}" && "${node,,}" != "${_lh,,}" ]]; then
    echo "[VM $vmid] Remote VLOADER automation on $node"
    ssh $SSH_OPTS "$node" \
      "VMID='$vmid' NODE2_SYS_SERIAL_NUM='$NODE2_SYS_SERIAL_NUM' NODE2_SYSID='$NODE2_SYSID' EXPECT_TIMEOUT='$EXPECT_TIMEOUT' expect -f -" \
      <<< "$expect_script"
  else
    echo "[VM $vmid] Local VLOADER automation"
    VMID="$vmid" \
      NODE2_SYS_SERIAL_NUM="$NODE2_SYS_SERIAL_NUM" \
      NODE2_SYSID="$NODE2_SYSID" \
      EXPECT_TIMEOUT="$EXPECT_TIMEOUT" \
      expect -f - <<< "$expect_script"
  fi
}

# ---------- Main ----------

# Show all effective settings at startup, so environment variables
# that are accidentally exported are immediately visible.
cat <<STARTINFO
[start] Effective configuration (including any environment variables):
  CLUSTER_PREFIX   = ${CLUSTER_PREFIX}
  CLUSTER_NUM      = ${CLUSTER_NUM}
  TARGET_NODE1     = ${TARGET_NODE1}
  TARGET_NODE2     = ${TARGET_NODE2}
  VM_STORAGE       = ${VM_STORAGE}
  VMID1            = ${VMID1}
  VMID2            = ${VMID2}
  DATA_BRIDGE      = ${DATA_BRIDGE}
  DATA_VLAN_TAG    = ${DATA_VLAN_TAG}
  CIFS_BRIDGE      = ${CIFS_BRIDGE}
  CIFS_VLAN_TAG    = ${CIFS_VLAN_TAG}
  NUM_NET_PORTS    = ${NUM_NET_PORTS}
STARTINFO

validate_num_ports
check_vg_on_all_nodes iscsi-data
validate_api_access

OVA_DIR_RESOLVED="$OVA_DIR"
OVA_PATH="$OVA_DIR_RESOLVED/$OVA_NAME"

validate_node_access
alloc_vmids
derive_node_identities

cat <<INFO
[1/10] Settings:
- OVA path:               $OVA_PATH
- VM storage:             $VM_STORAGE
- Node1:                  $TARGET_NODE1, VMID $VMID1, name $VMNAME1
- Node2:                  $TARGET_NODE2, VMID $VMID2, name $VMNAME2
- Node1 SYS_SERIAL_NUM:   $NODE1_SYS_SERIAL_NUM
- Node1 SYSID:            $NODE1_SYSID
- Node2 SYS_SERIAL_NUM:   $NODE2_SYS_SERIAL_NUM
- Node2 SYSID:            $NODE2_SYSID
- EXPECT_TIMEOUT:         $EXPECT_TIMEOUT s
INFO

create_vm "$VMID1" "$VMNAME1" "$TARGET_NODE1" "${AUTOMATE_NODE2_SYSID}" "$NODE1_SYS_SERIAL_NUM" "$NODE1_SYSID"
create_vm "$VMID2" "$VMNAME2" "$TARGET_NODE2" "${AUTOMATE_NODE2_SYSID}" "$NODE2_SYS_SERIAL_NUM" "$NODE2_SYSID"

cat <<POST

[10/10] Done. Next steps:
1. Start node1 (if not already started):
   ssh $TARGET_NODE1 qm start $VMID1

2. Node2 has unique SYS_SERIAL_NUM ($NODE2_SYS_SERIAL_NUM) and SYSID ($NODE2_SYSID).
   Verify this via: ssh $TARGET_NODE2 qm terminal $VMID2
   Then in VLOADER: printenv SYS_SERIAL_NUM

3. Check per node:
   ssh $TARGET_NODE1 "qm config $VMID1 | grep -E '^(boot|ide|sata|scsi):'"
   ssh $TARGET_NODE2 "qm config $VMID2 | grep -E '^(boot|ide|sata|scsi):'"

4. Console:
   - Web console (VGA) via Proxmox
   - Serial:
     ssh $TARGET_NODE1 qm terminal $VMID1
     ssh $TARGET_NODE2 qm terminal $VMID2

5. Go through ONTAP cluster setup:
   - Initialize cluster on node1
   - Join node2 via cluster-interconnect network

POST

print_port_info
