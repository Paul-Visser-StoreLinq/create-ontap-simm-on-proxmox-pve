#!/usr/bin/env bash
# =============================================================================
#  ontap-sim-2node-proxmox.sh
#  NetApp ONTAP Simulator — automatische 2-node cluster deployement op Proxmox
# After downloading, make the script executable: `chmod +x ontap-sim-2node-proxmox.sh`
# =============================================================================
#
# VERSIE BEHEER
# -------------
# Formaat: v{MAJOR}.{MINOR}  {DD-MM-YYYY}  {Omschrijving}
#
# MAJOR verhoogt bij grote functionele wijzigingen (nieuwe aanpak, andere werking)
# MINOR verhoogt bij bugfixes, kleine verbeteringen of aanpassingen
# Datum is de werkelijke datum waarop de wijziging is doorgevoerd
#
# v1.0  17-04-2026  Initiële versie: basis 2-node OVA import op Proxmox
# v1.1  17-04-2026  Disk import volgorde gefixed (sort -V); globale NODE_DISKS
#                   vervangen door lokale nameref arrays per VM
# v1.2  17-04-2026  VLOADER serial console automation via expect toegevoegd;
#                   serial socket race condition opgelost
# v1.3  17-04-2026  Hostnaam-vergelijking genormaliseerd (case-insensitive)
#                   zodat lokale node correct herkend wordt zonder SSH
# v1.4  17-04-2026  Cluster-brede VM-naam check toegevoegd; naamgeving
#                   gewijzigd naar {prefix}-cluster{NN}-01 / -02 schema
# v1.5  17-04-2026  VMID-allocatie cluster-breed via pvesh; voorkomt conflict
#                   met VMs op andere nodes dan waar script draait
# v1.6  17-04-2026  API-precheck uitgebreid met retry-loop (5 pogingen);
#                   storage-type check voor VG-validatie (skip bij dir/nfs)
# v1.7  17-04-2026  Defaults bijgewerkt: OVA_STORAGE_ID=software,
#                   TARGET_NODE1=pve01, TARGET_NODE2=pve02
# v2.0  17-04-2026  VLOADER-automation via serial console vervangen door
#                   directe guestfish-inject in /env/env op disk1 vóór import;
#                   beide nodes krijgen uniek serienummer gebaseerd op VMID
# v2.1  17-04-2026  /env/env schrijfsyntax gecorrigeerd naar VLOADER-formaat:
#                   "setenv NAAM \"WAARDE\"" in plaats van KEY=VALUE
# v2.2  17-04-2026  Inject script via SSH stdin gestuurd met env-variabelen;
#                   voorkomt pad-problemen bij remote nodes (VMDK niet lokaal)
# v2.3  17-04-2026  Verificatie na inject gefixed: controleer tmpfile inhoud
#                   in plaats van herlezen VMDK (NFS kernel cache probleem)
# v2.4  17-04-2026  Inject pad-doorgave gefixed: disk1 pad wordt nu altijd
#                   opnieuw opgezocht op de target node als het leeg is;
#                   expliciete debug-logging toegevoegd voor inject pad
#
# v2.5  17-04-2026  Inject verplaatst van VMDK naar geimporteerde RAW disk;
#                   guestfish upload op RAW disk werkt betrouwbaar
# v2.6  17-04-2026  Vaste ONTAP Simulator licentie-serials ingesteld:
#                   node1=4082368-50-7/4082368507, node2=4034389-06-2/4034389062
# =============================================================================
#
# BESCHRIJVING
# ------------
# Dit script deployt automatisch een NetApp ONTAP Simulator 2-node cluster
# op een Proxmox VE cluster. Het verwerkt de volgende stappen:
#
#   1. Prechecks  — API toegang, storage beschikbaarheid, OVA leesbaarheid
#   2. VMID       — Cluster-brede toewijzing van twee unieke VMIDs
#   3. Naamgeving — Automatisch clusternummer (sim-cluster01-01 / -02)
#   4. VM aanmaak — Beide VMs worden aangemaakt op de opgegeven nodes
#   5. OVA import — De 4 VMDKs worden uitgepakt en geïmporteerd per node
#   6. Identiteit — Unieke SYS_SERIAL_NUM en SYSID worden via guestfish
#                   direct in loader.conf op disk1 geschreven vóór import
#   7. Configuratie— Disks gekoppeld aan IDE0-3, boot volgorde ingesteld
#
# VEREISTEN
# ---------
#   - Proxmox VE 7.x of 8.x cluster met minimaal 2 nodes
#   - pvesh, qm, pvesm beschikbaar (standaard op Proxmox)
#   - SSH BatchMode toegang van de uitvoerende node naar alle target nodes
#   - python3 beschikbaar op de uitvoerende node
#   - libguestfs-tools (guestfish) — wordt automatisch geïnstalleerd indien nodig
#   - De ONTAP Simulator OVA (vsim-netapp-DOT9.16.1-cm_nodar.ova) aanwezig
#     op de storage die via OVA_STORAGE_ID bereikbaar is
#
# GEBRUIK
# -------
#   Basis (alle defaults):
#     ./ontap-sim-2node-proxmox.sh
#
#   Met aangepaste nodes en prefix:
#     TARGET_NODE1=pve01 TARGET_NODE2=pve02 CLUSTER_PREFIX=lab \
#       ./ontap-sim-2node-proxmox.sh
#
#   Forceer een specifiek clusternummer:
#     CLUSTER_NUM=3 ./ontap-sim-2node-proxmox.sh
#
#   Specifieke VMIDs opgeven:
#     VMID1=200 VMID2=201 ./ontap-sim-2node-proxmox.sh
#
#   VMs direct starten na aanmaak:
#     START_AFTER_CREATE=1 ./ontap-sim-2node-proxmox.sh
#
#   Zonder automatische identity inject (handmatige VLOADER):
#     AUTOMATE_NODE2_SYSID=0 ./ontap-sim-2node-proxmox.sh
#
# OMGEVINGSVARIABELEN
# -------------------
# Alle instellingen kunnen als omgevingsvariabele worden meegegeven.
# De waarde in het script is de default als de variabele niet is ingesteld.
#
#   VM_STORAGE         Proxmox storage-id voor VM disks
#                      Default: datastore_ds02
#
#   OVA_STORAGE_ID     Proxmox storage-id waar de OVA staat
#                      Default: software
#
#   OVA_DIR            Volledig pad naar de map met de OVA
#                      Default: /mnt/pve/{OVA_STORAGE_ID}/template/iso
#
#   OVA_NAME           Bestandsnaam van de OVA
#                      Default: vsim-netapp-DOT9.16.1-cm_nodar.ova
#
#   CLUSTER_PREFIX     Prefix voor VM-namen (schema: {prefix}-cluster{NN}-{01|02})
#                      Default: sim
#
#   CLUSTER_NUM        Forceer een specifiek clusternummer (bijv. 3 voor cluster03)
#                      Default: auto (eerste vrije nummer)
#
#   TARGET_NODE1       Proxmox node voor node1 van het cluster
#                      Default: pve01
#
#   TARGET_NODE2       Proxmox node voor node2 van het cluster
#                      Default: pve02
#
#   VMID1              VMID voor node1 (auto = cluster-breed vrij ID)
#                      Default: auto
#
#   VMID2              VMID voor node2 (auto = eerste vrije ID na VMID1)
#                      Default: auto
#
#   MGMT_BRIDGE        Bridge voor management netwerk (net2)
#                      Default: vmbr0
#
#   DATA_BRIDGE        Bridge voor data/cluster netwerk (net0, net1, net3)
#                      Default: vmbr1
#
#   MGMT_VLAN_TAG      VLAN tag voor management (0 = geen tag)
#                      Default: 0
#
#   DATA_VLAN_TAG      VLAN tag voor data netwerk
#                      Default: 20
#
#   CORES              Aantal CPU cores per VM
#                      Default: 2
#
#   MEMORY_MB          RAM per VM in MB
#                      Default: 6144 (6 GB)
#
#   CPU_TYPE           QEMU CPU type
#                      Default: SandyBridge
#
#   DISK_FORMAT        Disk formaat voor import (raw of qcow2)
#                      Default: raw
#
#   START_AFTER_CREATE Start VMs direct na aanmaak (1=ja, 0=nee)
#                      Default: 0
#
#   AUTOMATE_NODE2_SYSID
#                      Injecteer unieke SYS_SERIAL_NUM en SYSID in beide nodes
#                      via guestfish (1=ja, 0=nee)
#                      Default: 1
#
#   EXPECT_TIMEOUT     Timeout in seconden voor serial console operaties
#                      Default: 360
#
# NAAMGEVING
# ----------
# VMs worden automatisch benoemd volgens het schema:
#   {CLUSTER_PREFIX}-cluster{NN}-01  (node1)
#   {CLUSTER_PREFIX}-cluster{NN}-02  (node2)
#
# Het clusternummer NN wordt automatisch opgehoogd als een cluster al bestaat.
# Voorbeeld: als sim-cluster01-01 en sim-cluster01-02 al bestaan, worden
# de nieuwe VMs sim-cluster02-01 en sim-cluster02-02.
#
# SERIENUMMERS
# ------------
# De ONTAP Simulator gebruikt vaste licentie-serials die voor elke
# 2-node cluster identiek zijn:
#   Node1: SYS_SERIAL_NUM=4082368-50-7   SYSID=4082368507
#   Node2: SYS_SERIAL_NUM=4034389-06-2   SYSID=4034389062
#
# Deze worden via guestfish in /env/env op de geïmporteerde RAW disk
# geschreven na import, zodat ONTAP bij eerste boot de juiste identiteit
# en licenties heeft. De waarden kunnen overschreven worden via:
#   NODE1_SYS_SERIAL_NUM / NODE1_SYSID
#   NODE2_SYS_SERIAL_NUM / NODE2_SYSID
#
# VOLGENDE STAPPEN NA UITVOERING
# --------------------------------
# 1. Start node1:   ssh {TARGET_NODE1} qm start {VMID1}
# 2. Verbind console: Proxmox webinterface > VM > Console
#    of serieel:    ssh {TARGET_NODE1} qm terminal {VMID1}
# 3. Doorloop de ONTAP cluster setup wizard op node1
# 4. Join node2 via het cluster-interconnect netwerk
#
# =============================================================================

set -euo pipefail

# ---------- Basisconfig ----------
VM_STORAGE="${VM_STORAGE:-datastore_ds02}"
OVA_STORAGE_ID="${OVA_STORAGE_ID:-software}"
OVA_DIR="${OVA_DIR:-/mnt/pve/${OVA_STORAGE_ID}/template/iso}"
OVA_NAME="${OVA_NAME:-vsim-netapp-DOT9.16.1-cm_nodar.ova}"

# Naamgeving: {CLUSTER_PREFIX}-cluster{NN}-01 / -02
# NN wordt automatisch bepaald op basis van bestaande clusters in Proxmox.
# Forceer een specifiek clusternummer met CLUSTER_NUM=03 (anders: auto)
CLUSTER_PREFIX="${CLUSTER_PREFIX:-sim}"
CLUSTER_NUM="${CLUSTER_NUM:-auto}"
VMID1="${VMID1:-auto}"
VMID2="${VMID2:-auto}"
# VMNAME1/VMNAME2 worden automatisch bepaald in alloc_vmids(); niet handmatig instellen.
VMNAME1=""
VMNAME2=""
TARGET_NODE1="${TARGET_NODE1:-pve01}"
TARGET_NODE2="${TARGET_NODE2:-pve02}"

MGMT_BRIDGE="${MGMT_BRIDGE:-vmbr0}"
DATA_BRIDGE="${DATA_BRIDGE:-vmbr1}"
MGMT_VLAN_TAG="${MGMT_VLAN_TAG:-0}"
DATA_VLAN_TAG="${DATA_VLAN_TAG:-20}"

CORES="${CORES:-2}"
SOCKETS="${SOCKETS:-1}"
MEMORY_MB="${MEMORY_MB:-6144}"
CPU_TYPE="${CPU_TYPE:-SandyBridge}"
NET_MODEL="${NET_MODEL:-e1000}"

START_AFTER_CREATE="${START_AFTER_CREATE:-0}"

AUTOMATE_NODE2_SYSID="${AUTOMATE_NODE2_SYSID:-1}"
# Vaste ONTAP Simulator licentie-serials — altijd hetzelfde voor elke 2-node cluster
NODE1_SYS_SERIAL_NUM="${NODE1_SYS_SERIAL_NUM:-4082368-50-7}"
NODE1_SYSID="${NODE1_SYSID:-4082368507}"
NODE2_SYS_SERIAL_NUM="${NODE2_SYS_SERIAL_NUM:-4034389-06-2}"
NODE2_SYSID="${NODE2_SYSID:-4034389062}"

WORKDIR="${WORKDIR:-/var/tmp/ontap-sim-9.16.1}"

# FIX: timeout verhoogd van 240 naar 360 seconden; LVM-import kan traag zijn
EXPECT_TIMEOUT="${EXPECT_TIMEOUT:-360}"

SSH_OPTS="${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=5}"
DISK_FORMAT="${DISK_FORMAT:-raw}"

# ---------- Helpers ----------

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "FOUT: vereist commando ontbreekt: $1" >&2; exit 1; }
}

for cmd in qm tar awk sed grep find socat timeout pvesh pvesm hostname ssh; do
  require_cmd "$cmd"
done

mkdir -p "$WORKDIR"
cd "$WORKDIR"

run_on_node() {
  local node="$1"
  shift
  # Vergelijk zowel kort als lang hostname, en normaliseer hoofdletters
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
    echo "expect ontbreekt; installeren via apt" >&2
    apt-get update -qq -o APT::Update::Error-Mode=any 2>/dev/null || true
    apt-get install -y expect >/dev/null
  fi
}

next_vmid() {
  pvesh get /cluster/nextid
}

# Controleer cluster-breed of een VMID al in gebruik is (op welke node dan ook)
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

# Geeft het volgende cluster-brede vrije VMID terug, startend vanaf start_id
next_free_vmid_from() {
  local start_id="$1"
  local vmid="$start_id"
  # Haal alle gebruikte VMIDs in één keer op
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

# Haal alle bestaande VM-namen op uit de hele cluster (alle nodes)
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

# Bepaal het volgende vrije clusternummer voor het gegeven prefix.
# Zoekt naar namen als "{prefix}-cluster01-01" en geeft het eerste vrije nummer terug.
next_free_cluster_num() {
  local prefix="$1"
  local all_names="$2"
  local n=1
  while true; do
    local cluster_id
    cluster_id="$(printf '%02d' "$n")"
    local name1="${prefix}-cluster${cluster_id}-01"
    local name2="${prefix}-cluster${cluster_id}-02"
    # Clusternummer is vrij als BEIDE namen nog niet bestaan
    if ! grep -qx "$name1" <<< "$all_names" 2>/dev/null && \
       ! grep -qx "$name2" <<< "$all_names" 2>/dev/null; then
      echo "$cluster_id"
      return
    fi
    n=$(( n + 1 ))
    if [[ $n -gt 99 ]]; then
      echo "FOUT: geen vrij clusternummer gevonden (1-99)" >&2
      exit 1
    fi
  done
}

alloc_vmids() {
  echo "[precheck] Alloceer VMIDs cluster-breed..."
  if [[ "$VMID1" == "auto" ]]; then
    VMID1="$(next_vmid)"
  fi
  # Controleer VMID1 cluster-breed (pvesh nextid checkt dit al, maar bij handmatig opgeven niet)
  if [[ "$(vmid_in_use_cluster "$VMID1")" == "yes" ]]; then
    echo "FOUT: VMID1=$VMID1 is al in gebruik in de cluster" >&2
    exit 1
  fi

  if [[ "$VMID2" == "auto" ]]; then
    # Zoek cluster-breed het volgende vrije VMID na VMID1
    VMID2="$(next_free_vmid_from $(( VMID1 + 1 )))"
  fi
  # Controleer VMID2 cluster-breed
  if [[ "$(vmid_in_use_cluster "$VMID2")" == "yes" ]]; then
    echo "FOUT: VMID2=$VMID2 is al in gebruik in de cluster" >&2
    exit 1
  fi

  if [[ "$VMID1" == "$VMID2" ]]; then
    echo "FOUT: VMID1 en VMID2 zijn gelijk" >&2
    exit 1
  fi
  echo "  VMID1=$VMID1  VMID2=$VMID2"

  # Bepaal vrij clusternummer en stel VM-namen in
  echo "[precheck] Controleer bestaande clusternamen in Proxmox..."
  local all_names
  all_names="$(get_all_vm_names)"

  local cluster_id
  if [[ "$CLUSTER_NUM" == "auto" ]]; then
    cluster_id="$(next_free_cluster_num "$CLUSTER_PREFIX" "$all_names")"
  else
    cluster_id="$(printf '%02d' "$CLUSTER_NUM")"
    # Valideer dat het opgegeven nummer ook echt vrij is
    local n1="${CLUSTER_PREFIX}-cluster${cluster_id}-01"
    local n2="${CLUSTER_PREFIX}-cluster${cluster_id}-02"
    if grep -qx "$n1" <<< "$all_names" 2>/dev/null || \
       grep -qx "$n2" <<< "$all_names" 2>/dev/null; then
      echo "FOUT: CLUSTER_NUM=$CLUSTER_NUM is al in gebruik ($n1 of $n2 bestaat al)" >&2
      exit 1
    fi
  fi

  VMNAME1="${CLUSTER_PREFIX}-cluster${cluster_id}-01"
  VMNAME2="${CLUSTER_PREFIX}-cluster${cluster_id}-02"

  echo "  Clusternummer : $cluster_id"
  echo "  VMNAME1       : $VMNAME1"
  echo "  VMNAME2       : $VMNAME2"
}

# FIX: node2 identity gebaseerd op VMID2 (was al goed), maar we genereren
#      nu ook een uniek NODE1-equivalent zodat beide altijd verschillend zijn.
#      Node1 gebruikt de OVA-default NVRAM; node2 krijgt een afwijkende serie.
derive_node_identities() {
  # Vaste licentie-serials voor ONTAP Simulator — worden niet berekend
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
    echo "  [precheck] API niet bereikbaar voor $node (poging $attempt/$max_retries): $err" >&2
    if [[ $attempt -lt $max_retries ]]; then
      echo "  [precheck] Wacht ${wait_sec}s voor volgende poging..." >&2
      sleep "$wait_sec"
    fi
    attempt=$(( attempt + 1 ))
  done

  echo "FOUT: API precheck mislukt voor /nodes/${node}/qemu na $max_retries pogingen" >&2
  echo "  Mogelijke oorzaken:" >&2
  echo "  - Node $node is offline of niet bereikbaar in de cluster" >&2
  echo "  - Corosync/pve-cluster service is niet actief" >&2
  echo "  - Controleer: pvesh get /nodes/${node}/status" >&2
  return 1
}

validate_api_access() {
  for node in "$TARGET_NODE1" "$TARGET_NODE2"; do
    echo "[precheck] Controleer API toegang voor VM creatie op node: $node"
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
    echo "FOUT: kon storage status voor $storage_id op node $node niet opvragen" >&2
    return 1
  fi
  [[ -n "$out" ]] || { echo "FOUT: storage $storage_id is niet zichtbaar/toegestaan voor node $node" >&2; return 1; }
  local active type
  active=$(echo "$out" | awk '{print $1}')
  type=$(echo "$out" | awk '{print $2}')
  if [[ "$active" != "active" ]]; then
    echo "FOUT: storage $storage_id is niet active op node $node (status: $active, type: $type)" >&2
    return 1
  fi
  return 0
}

check_ova_path_reachable_for_node() {
  local node="$1"
  local path="$2"
  local short_host long_host node_lower
  short_host="$(hostname -s 2>/dev/null || true)"
  long_host="$(hostname 2>/dev/null || true)"
  node_lower="${node,,}"
  if [[ "${node_lower}" == "${short_host,,}" || "${node_lower}" == "${long_host,,}" ]]; then
    test -r "$path"
  else
    ssh $SSH_OPTS "$node" "test -r '$path'" >/dev/null 2>&1
  fi
}

validate_node_access() {
  for node in "$TARGET_NODE1" "$TARGET_NODE2"; do
    echo "[precheck] Controleer node status: $node"
    node_online "$node" || { echo "FOUT: node $node is niet bereikbaar via Proxmox API" >&2; exit 1; }

    echo "[precheck] Controleer storage $OVA_STORAGE_ID op node $node"
    check_storage_reachable_for_node "$node" "$OVA_STORAGE_ID" || exit 1

    echo "[precheck] Controleer storage $VM_STORAGE op node $node"
    check_storage_reachable_for_node "$node" "$VM_STORAGE" || exit 1

    echo "[precheck] Controleer leesbaarheid OVA op node $node: $OVA_PATH"
    check_ova_path_reachable_for_node "$node" "$OVA_PATH" || {
      echo "FOUT: OVA path niet leesbaar op node $node: $OVA_PATH" >&2
      exit 1
    }
  done
}

check_vg_on_all_nodes() {
  local vg="$1"

  # Controleer eerst of VM_STORAGE een LVM of LVMthin storage is.
  # Voor dir/nfs/cifs/zfs storage is een VG-check niet van toepassing.
  local storage_type
  storage_type=$(awk -v sid="$VM_STORAGE" '
    $1 ~ /^(lvm:|lvmthin:|dir:|nfs:|cifs:|zfspool:)/ {
      type=$1; sub(/:$/,"",type)
      if ($2 == sid) { print type; exit }
    }
  ' /etc/pve/storage.cfg 2>/dev/null || true)

  if [[ "$storage_type" != "lvm" && "$storage_type" != "lvmthin" ]]; then
    echo "[precheck] Storage '$VM_STORAGE' is type '${storage_type:-onbekend}'; VG-check overgeslagen"
    return 0
  fi

  echo "[precheck] Controleer aanwezigheid van VG '$vg' op alle nodes die $VM_STORAGE gebruiken"

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
    echo "[precheck] WAARSCHUWING: kon nodelijst voor $VM_STORAGE niet bepalen; VG-check overgeslagen" >&2
    return 0
  fi

  local failed=0
  for node in $nodes; do
    echo "  - node $node: check VG $vg"
    local check_cmd="vgs --noheadings -o vg_name 2>/dev/null | grep -qw '$vg'"
    if [[ "${node,,}" == "$(hostname -s 2>/dev/null || true)" || "${node,,}" == "$(hostname 2>/dev/null || true)" ]]; then
      if ! eval "$check_cmd"; then
        echo "FOUT: VG '$vg' niet gevonden op node $node" >&2
        failed=1
      fi
    else
      if ! ssh $SSH_OPTS "$node" "$check_cmd" 2>/dev/null; then
        echo "FOUT: VG '$vg' niet gevonden op node $node" >&2
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

cleanup_vm_and_orphaned_disks() {
  local vmid="$1"
  local target_node="$2"

  echo "[VM $vmid] Cleanup bestaande VM-config + orphaned disks op $target_node"

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
        echo '  leftover LVs op $target_node:' \"\${LVS_TO_REMOVE[*]}\"
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

# FIX: prepare_vmdks_on_node schrijft nu naar een lokale nameref zodat
#      node1 en node2 elkaar niet overschrijven (was globale NODE_DISKS).
prepare_vmdks_on_node() {
  local target_node="$1"
  local -n _out_disks="$2"   # nameref: aanroeper geeft naam van zijn eigen array mee
  local extract_dir="$WORKDIR/extracted-$target_node"

  echo "[node $target_node] Pak OVA lokaal uit op node in $extract_dir"
  run_on_node "$target_node" mkdir -p "$extract_dir"
  run_on_node "$target_node" bash -lc "rm -rf '$extract_dir'/* && tar -xf '$OVA_PATH' -C '$extract_dir'"

  # FIX: sort numeriek (-V) zodat disk1 < disk2 < disk3 < disk4 gegarandeerd is
  mapfile -t _out_disks < <(run_on_node "$target_node" find "$extract_dir" -maxdepth 1 -type f -iname '*.vmdk' | sort -V)

  if [[ ${#_out_disks[@]} -lt 4 ]]; then
    echo "FOUT: minder dan 4 VMDK bestanden gevonden op node $target_node in $extract_dir" >&2
    run_on_node "$target_node" find "$extract_dir" -maxdepth 1 -type f >&2 || true
    exit 1
  fi

  _out_disks=("${_out_disks[0]}" "${_out_disks[1]}" "${_out_disks[2]}" "${_out_disks[3]}")
  echo "[node $target_node] VMDK volgorde: ${_out_disks[*]}"
}

create_vm() {
  local vmid="$1"
  local name="$2"
  local target_node="$3"
  local do_inject="${4:-0}"   # optioneel: inject identity in VMDK voor import
  # params 5 en 6: serial en sysid voor inject (alleen gebruikt als do_inject=1)

  cleanup_vm_and_orphaned_disks "$vmid" "$target_node"

  echo "[VM $vmid] VM aanmaken op host $target_node"
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

  echo "[VM $vmid] Netwerkinterfaces toevoegen op $target_node"
  run_on_node "$target_node" qm set "$vmid" --net2 "$(format_nic "$MGMT_BRIDGE" "$MGMT_VLAN_TAG")"
  run_on_node "$target_node" qm set "$vmid" --net1 "$(format_nic "$DATA_BRIDGE" "$DATA_VLAN_TAG")"
  run_on_node "$target_node" qm set "$vmid" --net0 "$(format_nic "$DATA_BRIDGE" "$DATA_VLAN_TAG")"
  run_on_node "$target_node" qm set "$vmid" --net3 "$(format_nic "$DATA_BRIDGE" "$DATA_VLAN_TAG")"

  # FIX: gebruik een per-VM lokale array (geen globale NODE_DISKS meer)
  local -a node_disks=()
  prepare_vmdks_on_node "$target_node" node_disks

  echo "[VM $vmid] Importeer VMDKs in volgorde 1..4 op $target_node"
  for vmdk in "${node_disks[@]}"; do
    run_on_node "$target_node" qm disk import "$vmid" "$vmdk" "$VM_STORAGE" --format "$DISK_FORMAT"
  done

  echo "[VM $vmid] Config na import op $target_node:"
  run_on_node "$target_node" qm config "$vmid" | grep -E '^(unused|ide|sata|scsi):' || true

  # FIX: wacht tot alle 4 disks als unusedX zichtbaar zijn in de config
  #      (LVM-import kan enige seconden nodig hebben om te flushen)
  echo "[VM $vmid] Wachten tot 4 disks als unusedX verschijnen in config..."
  local retries=0
  local -a imported_disks=()
  while [[ $retries -lt 30 ]]; do
    mapfile -t imported_disks < <(run_on_node "$target_node" qm config "$vmid" | awk -F': ' '/^unused[0-9]+: /{print $2}' | cut -d',' -f1)
    if [[ ${#imported_disks[@]} -ge 4 ]]; then
      break
    fi
    echo "  ...nog maar ${#imported_disks[@]} gevonden, wachten (poging $((retries+1))/30)..."
    sleep 3
    retries=$((retries + 1))
  done

  if [[ ${#imported_disks[@]} -lt 4 ]]; then
    echo "FOUT: minder dan 4 geimporteerde disks (unusedX) gevonden voor VM $vmid op node $target_node na wachten" >&2
    run_on_node "$target_node" qm config "$vmid" >&2 || true
    exit 1
  fi

  # FIX: sorteer de unusedX-entries op index (unused0, unused1, ...) zodat
  #      de koppeling aan ide0..ide3 deterministisch is ongeacht import-volgorde
  mapfile -t imported_disks < <(
    run_on_node "$target_node" qm config "$vmid" \
    | awk -F': ' '/^unused[0-9]+: /{print $1, $2}' \
    | sort -t'd' -k2 -n \
    | awk '{print $2}' \
    | cut -d',' -f1
  )

  # Wacht tot alle LVs ook echt actief zijn op de target node voordat we koppelen.
  # qm disk import retourneert soms voordat lvchange -ay volledig klaar is.
  echo "[VM $vmid] Wachten tot alle LVs actief zijn op $target_node..."
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
        # disk formaat: storage:vm-VMID-disk-N  -> LV naam is vm-VMID-disk-N
        local lv_name="${disk#*:}"
        if ! run_on_node "$target_node" lvs --noheadings "/dev/${vgname}/${lv_name}"              >/dev/null 2>&1; then
          all_active=0
          break
        fi
      done
      if [[ $all_active -eq 1 ]]; then
        echo "  Alle LVs actief op $target_node"
        break
      fi
      echo "  ...LVs nog niet allemaal actief, wachten (poging $((lv_retries+1))/30)..."
      sleep 2
      lv_retries=$(( lv_retries + 1 ))
    done
  fi

  # Wacht tot de storage online is op de target node voordat we disks koppelen.
  # Na een reeks disk imports kan de storage tijdelijk als offline gemarkeerd zijn.
  echo "[VM $vmid] Wachten tot storage '$VM_STORAGE' online is op $target_node..."
  local stor_retries=0
  while [[ $stor_retries -lt 60 ]]; do
    local stor_status
    stor_status=$(run_on_node "$target_node"       pvesm status --storage "$VM_STORAGE" 2>/dev/null | awk 'NR>1 {print $3}')
    if [[ "$stor_status" == "active" ]]; then
      echo "  Storage '$VM_STORAGE' is active op $target_node"
      break
    fi
    echo "  ...storage status='${stor_status:-onbekend}', wachten (poging $((stor_retries+1))/60)..."
    sleep 5
    stor_retries=$(( stor_retries + 1 ))
  done
  if [[ $stor_retries -ge 60 ]]; then
    echo "FOUT: storage '$VM_STORAGE' niet online op $target_node na 5 minuten" >&2
    exit 1
  fi

  # Koppel alle 4 disks in één enkele qm set aanroep om race conditions te vermijden
  echo "[VM $vmid] Koppel imported disks aan IDE0..IDE3 op $target_node"
  run_on_node "$target_node" qm set "$vmid"     --ide0 "${imported_disks[0]}"     --ide1 "${imported_disks[1]}"     --ide2 "${imported_disks[2]}"     --ide3 "${imported_disks[3]}"

  run_on_node "$target_node" bash -lc "
    set -euo pipefail
    for dev in sata0 sata1 sata2 sata3; do
      qm config '$vmid' | grep -q \"^\${dev}:\" && qm set '$vmid' --delete \"\${dev}\" || true
    done
  "

  # Injecteer identity in de geimporteerde RAW disk (disk-0) na import
  if [[ "$do_inject" == "1" ]]; then
    local inject_serial="${5:-}"
    local inject_sysid="${6:-}"
    # Bepaal het pad van de geimporteerde disk-0 op de target node
    local raw_path
    raw_path=$(run_on_node "$target_node"       find "/mnt/pve/${VM_STORAGE}/images/${vmid}"       -maxdepth 1 -name "vm-${vmid}-disk-0.*" 2>/dev/null | head -1 || true)
    # Fallback: lees pad uit qm config
    if [[ -z "$raw_path" ]]; then
      local disk0_cfg
      disk0_cfg=$(run_on_node "$target_node" qm config "$vmid"         | awk -F'[ ,]' '/^ide0:/{print $2}' | head -1)
      # disk0_cfg formaat: storage:vmid/vm-vmid-disk-0.raw
      raw_path="/mnt/pve/${disk0_cfg#*:}"
    fi
    echo "[VM $vmid] Injecteer identity in RAW disk: $raw_path"
    inject_identity_to_disk "$target_node" "$raw_path" "$inject_serial" "$inject_sysid"
  fi

  run_on_node "$target_node" qm set "$vmid" --boot order=ide0
  run_on_node "$target_node" qm set "$vmid" --description "NetApp ONTAP Simulator 9.16.1 two-node lab; net0=$MGMT_BRIDGE net1-3=$DATA_BRIDGE; host=$target_node"

  echo "[VM $vmid] Definitieve disk/boot config op $target_node:"
  run_on_node "$target_node" qm config "$vmid" | grep -E '^(boot|ide|sata|scsi|serial|vga):' || true

  if [[ "$START_AFTER_CREATE" == "1" ]]; then
    run_on_node "$target_node" qm start "$vmid"
  fi
}

# FIX: wacht nu op de echte VLOADER-prompt via socat ipv alleen op de socket.
#      De socket bestaat al zodra QEMU gestart is; VLOADER komt later.
#      Verhoogde retries (90x2s = 3 min) voor trage LVM-storage.
wait_for_serial_socket() {
  local vmid="$1"
  local node="$2"
  local sock="/var/run/qemu-server/${vmid}.serial0"
  echo "[VM $vmid] Wachten op serial socket $sock op $node..."
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
  echo "FOUT: serial socket $sock niet gevonden op $node na 3 minuten" >&2
  return 1
}

# Schrijf NVRAM-variabelen direct naar loader.conf op disk1 van node2.
# Dit is betrouwbaarder dan VLOADER-interactie via serial console,
# omdat VLOADER slechts enkele seconden beschikbaar is bij boot.
inject_identity_to_disk() {
  local target_node="$1"
  local raw_disk="$2"    # volledig pad naar de geimporteerde RAW disk op target_node
  local serial="$3"
  local sysid="$4"

  echo "[inject] SYS_SERIAL_NUM=$serial SYSID=$sysid -> $raw_disk op $target_node"

  local inject_script='
set -euo pipefail

echo "[inject] RAW disk: $INJ_DISK"
ls -lh "$INJ_DISK" || { echo "FOUT: RAW disk niet gevonden: $INJ_DISK" >&2; exit 1; }

# Installeer guestfish indien nodig
if ! command -v guestfish >/dev/null 2>&1; then
  echo "[inject] guestfish ontbreekt; installeren..."
  apt-get update -qq -o APT::Update::Error-Mode=any 2>/dev/null || true
  apt-get install -y libguestfs-tools >/dev/null \
    || { echo "FOUT: kon libguestfs-tools niet installeren" >&2; exit 1; }
fi

PARTITION=/dev/sda2
ENV_PATH=/env/env

# Lees bestaande inhoud
EXISTING=$(guestfish --ro -a "$INJ_DISK" -m "$PARTITION" -- cat "$ENV_PATH" 2>/dev/null || true)

# Bouw nieuwe inhoud
TMPFILE="${INJ_WORKDIR}/env_inject_$$.conf"
printf "%s\n" "$EXISTING" \
  | grep -v -E "^[[:space:]]*setenv[[:space:]]+(SYS_SERIAL_NUM|bootarg\.nvram\.sysid)[[:space:]]" \
  | sed "/^[[:space:]]*$/d" > "$TMPFILE"
printf "setenv SYS_SERIAL_NUM \"%s\"\n" "$INJ_SERIAL" >> "$TMPFILE"
printf "setenv bootarg.nvram.sysid \"%s\"\n" "$INJ_SYSID" >> "$TMPFILE"

echo "[inject] Nieuwe /env/env:"
cat "$TMPFILE" | sed "s/^/  /"

# Upload naar RAW disk
guestfish -a "$INJ_DISK" -m "$PARTITION" -- upload "$TMPFILE" "$ENV_PATH" \
  || { echo "FOUT: guestfish upload mislukt" >&2; rm -f "$TMPFILE"; exit 1; }
sync

# Verificeer
VERIFY=$(guestfish --ro -a "$INJ_DISK" -m "$PARTITION" -- cat "$ENV_PATH" 2>/dev/null || true)
if echo "$VERIFY" | grep -q "SYS_SERIAL_NUM.*$INJ_SERIAL"; then
  echo "[inject] Verificatie geslaagd: SYS_SERIAL_NUM=$INJ_SERIAL"
else
  echo "FOUT: verificatie mislukt na schrijven" >&2
  echo "$VERIFY" | sed "s/^/  /" >&2
  rm -f "$TMPFILE"
  exit 1
fi

rm -f "$TMPFILE"
echo "[inject] Volledig geslaagd"
'

  local _sh _lh
  _sh="$(hostname -s 2>/dev/null || true)"
  _lh="$(hostname 2>/dev/null || true)"

  if [[ "${target_node,,}" == "${_sh,,}" || "${target_node,,}" == "${_lh,,}" ]]; then
    echo "[inject] Lokale uitvoering op $(hostname -s)"
    INJ_DISK="$raw_disk" INJ_SERIAL="$serial" INJ_SYSID="$sysid" \
      INJ_WORKDIR="$WORKDIR" bash <<< "$inject_script"
  else
    echo "[inject] Remote uitvoering op $target_node via SSH"
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

  # Installeer expect lokaal én op de remote node indien nodig
  install_expect_if_missing
  local _sh _lh
  _sh="$(hostname -s 2>/dev/null || true)"
  _lh="$(hostname 2>/dev/null || true)"
  if [[ "${node,,}" != "${_sh,,}" && "${node,,}" != "${_lh,,}" ]]; then
    if ! ssh $SSH_OPTS "$node" "command -v expect >/dev/null 2>&1"; then
      echo "[VM $vmid] expect ontbreekt op $node; installeren..." >&2
      ssh $SSH_OPTS "$node" \
        "apt-get update -qq -o APT::Update::Error-Mode=any 2>/dev/null || true && apt-get install -y expect" \
        || { echo "FOUT: kon expect niet installeren op $node" >&2; exit 1; }
    fi
  fi

  # FIX: expect-script herzien:
  #   - Meerdere \r stuurt om VLOADER te wekken als hij al voorbij is
  #   - exp_continue na timeout zodat we blijven pollen
  #   - Expliciete check dat de setenv-commando's bevestigd worden
  #   - Na 'boot' wachten op EOF of ONTAP banner ipv direct afsluiten
  #   - Zowel lokaal als remote identiek script (was inconsistent)

  local expect_script
  expect_script=$(cat <<'EXPEOF'
set timeout $env(EXPECT_TIMEOUT)
set vmid $env(VMID)
set serial_num $env(NODE2_SYS_SERIAL_NUM)
set sysid $env(NODE2_SYSID)

spawn socat -,raw,echo=0 UNIX-CONNECT:/var/run/qemu-server/$vmid.serial0

# Stuur herhaaldelijk enters totdat VLOADER> verschijnt
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
        # VLOADER nog niet gezien; blijf enters sturen
        set attempts 0
        while {$attempts < 20} {
            send "\r"
            expect {
                "VLOADER>" { break }
                timeout     { incr attempts; sleep 2 }
            }
        }
        if {$attempts >= 20} {
            puts stderr "FOUT: VLOADER> prompt niet gevonden na 20 pogingen"
            exit 1
        }
    }
}

send "setenv SYS_SERIAL_NUM $serial_num\r"
expect {
    "VLOADER>" { }
    timeout { puts stderr "FOUT: geen bevestiging na setenv SYS_SERIAL_NUM"; exit 1 }
}

send "setenv bootarg.nvram.sysid $sysid\r"
expect {
    "VLOADER>" { }
    timeout { puts stderr "FOUT: geen bevestiging na setenv bootarg.nvram.sysid"; exit 1 }
}

send "printenv SYS_SERIAL_NUM\r"
expect {
    "$serial_num" { }
    timeout { puts stderr "WAARSCHUWING: SYS_SERIAL_NUM niet zichtbaar in printenv" }
}
expect "VLOADER>"

send "printenv bootarg.nvram.sysid\r"
expect {
    "$sysid" { }
    timeout { puts stderr "WAARSCHUWING: sysid niet zichtbaar in printenv" }
}
expect "VLOADER>"

puts "VLOADER vars ingesteld: SYS_SERIAL_NUM=$serial_num sysid=$sysid"
send "boot\r"

# Geef VLOADER 2 seconden om het boot-commando te verwerken,
# sluit dan de socat-verbinding netjes. ONTAP boot verder op de achtergrond.
sleep 2
close
wait
EXPEOF
)

  local _sh _lh
  _sh="$(hostname -s 2>/dev/null || true)"
  _lh="$(hostname 2>/dev/null || true)"
  if [[ "${node,,}" != "${_sh,,}" && "${node,,}" != "${_lh,,}" ]]; then
    echo "[VM $vmid] Remote VLOADER automation op $node"
    ssh $SSH_OPTS "$node" \
      "VMID='$vmid' NODE2_SYS_SERIAL_NUM='$NODE2_SYS_SERIAL_NUM' NODE2_SYSID='$NODE2_SYSID' EXPECT_TIMEOUT='$EXPECT_TIMEOUT' expect -f -" \
      <<< "$expect_script"
  else
    echo "[VM $vmid] Lokale VLOADER automation"
    VMID="$vmid" \
      NODE2_SYS_SERIAL_NUM="$NODE2_SYS_SERIAL_NUM" \
      NODE2_SYSID="$NODE2_SYSID" \
      EXPECT_TIMEOUT="$EXPECT_TIMEOUT" \
      expect -f - <<< "$expect_script"
  fi
}

# ---------- Main ----------

# Toon alle effectieve instellingen direct bij opstarten, zodat omgevingsvariabelen
# die per ongeluk geexporteerd zijn direct zichtbaar zijn.
cat <<STARTINFO
[start] Effectieve configuratie (inclusief eventuele omgevingsvariabelen):
  CLUSTER_PREFIX   = ${CLUSTER_PREFIX}
  CLUSTER_NUM      = ${CLUSTER_NUM}
  TARGET_NODE1     = ${TARGET_NODE1}
  TARGET_NODE2     = ${TARGET_NODE2}
  VM_STORAGE       = ${VM_STORAGE}
  VMID1            = ${VMID1}
  VMID2            = ${VMID2}
STARTINFO

check_vg_on_all_nodes iscsi-data
validate_api_access

OVA_DIR_RESOLVED="$OVA_DIR"
OVA_PATH="$OVA_DIR_RESOLVED/$OVA_NAME"

if [[ ! -r "$OVA_PATH" ]]; then
  echo "FOUT: OVA niet leesbaar op $OVA_PATH" >&2
  exit 1
fi

validate_node_access
alloc_vmids
derive_node_identities

cat <<INFO
[1/10] Instellingen:
- OVA path:               $OVA_PATH
- VM storage:             $VM_STORAGE
- Node1:                  $TARGET_NODE1, VMID $VMID1, naam $VMNAME1
- Node2:                  $TARGET_NODE2, VMID $VMID2, naam $VMNAME2
- Node1 SYS_SERIAL_NUM:   $NODE1_SYS_SERIAL_NUM
- Node1 SYSID:            $NODE1_SYSID
- Node2 SYS_SERIAL_NUM:   $NODE2_SYS_SERIAL_NUM
- Node2 SYSID:            $NODE2_SYSID
- EXPECT_TIMEOUT:         $EXPECT_TIMEOUT s
INFO

create_vm "$VMID1" "$VMNAME1" "$TARGET_NODE1" "${AUTOMATE_NODE2_SYSID}" "$NODE1_SYS_SERIAL_NUM" "$NODE1_SYSID"
create_vm "$VMID2" "$VMNAME2" "$TARGET_NODE2" "${AUTOMATE_NODE2_SYSID}" "$NODE2_SYS_SERIAL_NUM" "$NODE2_SYSID"

cat <<POST

[10/10] Klaar. Volgende stappen:
1. Start node1 (als nog niet gestart):
   ssh $TARGET_NODE1 qm start $VMID1

2. Node2 heeft unieke SYS_SERIAL_NUM ($NODE2_SYS_SERIAL_NUM) en SYSID ($NODE2_SYSID).
   Controleer dit via: ssh $TARGET_NODE2 qm terminal $VMID2
   Dan in VLOADER: printenv SYS_SERIAL_NUM

3. Controleer per node:
   ssh $TARGET_NODE1 "qm config $VMID1 | grep -E '^(boot|ide|sata|scsi):'"
   ssh $TARGET_NODE2 "qm config $VMID2 | grep -E '^(boot|ide|sata|scsi):'"

4. Console:
   - Web-console (VGA) via Proxmox
   - Serieel:
     ssh $TARGET_NODE1 qm terminal $VMID1
     ssh $TARGET_NODE2 qm terminal $VMID2

5. Doorloop de ONTAP cluster setup:
   - Cluster initialiseren op node1
   - Node2 joinen via cluster-interconnect netwerk

POST
