# create-ontap-simm-on-proxmox-pve
Automated NetApp ONTAP Simulator 2-node cluster deployment on Proxmox VE

This script handles the complete deployment process: unpacking the OVA, importing disks, configuring VMs, and injecting the correct ONTAP license serials — all fully automated.

> After downloading, make the script executable: `chmod +x ontap-sim-2node-proxmox.sh`
---

## What it does

The script performs the following steps automatically:

1. **Prechecks** — verifies API access, storage availability and OVA readability on all target nodes
2. **VMID allocation** — assigns two unique VMIDs cluster-wide via the Proxmox API
3. **Naming** — automatically determines the next free cluster number (`sim-cluster01-01` / `-02`)
4. **VM creation** — creates both VMs on the specified Proxmox nodes
5. **OVA import** — extracts and imports all 4 VMDKs per node
6. **Identity injection** — writes the correct `SYS_SERIAL_NUM` and `SYSID` into `/env/env` on the imported RAW disk via `guestfish`
7. **Configuration** — attaches disks to IDE0–3 and sets the boot order

---

## Requirements

| Requirement | Notes |
|---|---|
| Proxmox VE 7.x or 8.x | Cluster with at least 2 nodes |
| `pvesh`, `qm`, `pvesm` | Available by default on Proxmox |
| SSH BatchMode access | From the executing node to all target nodes |
| `python3` | Available on the executing node |
| `libguestfs-tools` | Installed automatically if missing |
| ONTAP Simulator OVA | `vsim-netapp-DOT9.16.1-cm_nodar.ova` on the OVA storage |

> **Note:** The script must be run from a Proxmox node that has cluster API access (`pvesh`).

---

## Quick start

```bash
# Basic usage with all defaults
./ontap-sim-2node-proxmox.sh

# Environment variables always win over the config file
# (set variable in the environment > config file > built-in default)

# Custom nodes and prefix
TARGET_NODE1=pve01 TARGET_NODE2=pve02 CLUSTER_PREFIX=lab \
  ./ontap-sim-2node-proxmox.sh

# Force a specific cluster number
CLUSTER_NUM=3 ./ontap-sim-2node-proxmox.sh

# Start VMs immediately after creation
START_AFTER_CREATE=1 ./ontap-sim-2node-proxmox.sh

# Show how many simulated disks fit in the OVA's sim disk (no VM is created)
./ontap-sim-2node-proxmox.sh --show-sim-disk

# Let the script choose the number of disks per shelf
SIM_DISK_TYPE=36 SIM_DISKS_PER_SHELF=auto ./ontap-sim-2node-proxmox.sh

# Specify exact VMIDs
VMID1=200 VMID2=201 ./ontap-sim-2node-proxmox.sh
```

---

## Configuration

All settings can be passed as environment variables. The values below are the defaults.

### Storage & OVA

| Variable | Default | Description |
|---|---|---|
| `VM_STORAGE` | `datastore_ds02` | Proxmox storage ID for VM disks |
| `OVA_STORAGE_ID` | `software` | Proxmox storage ID where the OVA is located |
| `OVA_DIR` | `/mnt/pve/{OVA_STORAGE_ID}/template/iso` | Full path to the directory containing the OVA |
| `OVA_NAME` | `vsim-netapp-DOT9.16.1-cm_nodar.ova` | OVA filename |

### Cluster & VM naming

| Variable | Default | Description |
|---|---|---|
| `CLUSTER_PREFIX` | `sim` | Prefix for VM names |
| `CLUSTER_NUM` | `auto` | Force a specific cluster number (e.g. `3` for `cluster03`) |
| `VMID1` | `auto` | VMID for node1 (cluster-wide free ID) |
| `VMID2` | `auto` | VMID for node2 (first free ID after VMID1) |

### Target nodes

| Variable | Default | Description |
|---|---|---|
| `TARGET_NODE1` | `pve01` | Proxmox node for cluster node1 |
| `TARGET_NODE2` | `pve02` | Proxmox node for cluster node2 |

### Networking

| Variable | Default | Description |
|---|---|---|
| `CLUSTER_BRIDGE` | `vmbr1` | Bridge for the cluster interconnect (net0, net1) |
| `CLUSTER_VLAN_TAG` | *(none, required)* | VLAN tag for the cluster interconnect (`0` = untagged). Script aborts if empty |
| `DATA_BRIDGE` | `vmbr1` | Bridge for data ports (NFS, iSCSI) |
| `DATA_VLAN_TAG` | `20` | VLAN tag for data ports |
| `CIFS_BRIDGE` | `DATA_BRIDGE` | Optional override: bridge for CIFS ports |
| `CIFS_VLAN_TAG` | `DATA_VLAN_TAG` | Optional override: VLAN tag for CIFS ports |

The script aborts at startup if cluster and data use the same bridge **and** the same VLAN tag (including `0`/`0`), since everything would then share one L2 domain.

Use `./ontap-sim-2node-proxmox.sh --show-ports` to print the resulting bridge/VLAN per port without changing anything (works on any machine). `--version` shows the script version.

### Local configs

`ontap-sim-2node-proxmox.conf` is the only example config in the repo. Copy it to your own local config and pass it with `--config`:

```bash
cp ontap-sim-2node-proxmox.conf ontap-sim-2node-lab-cluster1.conf
./ontap-sim-2node-proxmox.sh --config ontap-sim-2node-lab-cluster1.conf
```

Files matching `ontap-sim-2node-*-cluster*.conf` are git-ignored so site-specific values and license data are never committed.

### VM hardware

| Variable | Default | Description |
|---|---|---|
| `CORES` | `2` | Number of CPU cores per VM |
| `MEMORY_MB` | `6144` | RAM per VM in MB (6 GB) |
| `CPU_TYPE` | `SandyBridge` | QEMU CPU type |
| `DISK_FORMAT` | `raw` | Disk format for import (`raw` or `qcow2`) |

### Simulated disks (optional)

| Variable | Default | Description |
|---|---|---|
| `SIM_DISK_TYPE` | *(empty)* | ONTAP simulator disk type ID (e.g. `36` = ~9 GB). Empty = OVA default (28 × 1 GB), nothing is changed |
| `SIM_DISKS_PER_SHELF` | `14` | Disks per shelf, 1–14, or `auto` (only used when `SIM_DISK_TYPE` is set). `auto` picks the highest number per shelf (max 14) that fits the sim disk with `SIM_SHELVES` and `SIM_DISK_TYPE` |
| `SIM_SHELVES` | `2` | Number of shelves, 1–4 |
| `SIM_DISK_SIZE_GB` | *(from table)* | Nominal GB per disk. Only needed for types outside the built-in table (23, 31, 36) |
| `SIM_DISK_MARGIN_PCT` | `10` | Extra room required on the sim disk on top of disks × size |

See [Simulated disks](#simulated-disks) below for what this does and what it cannot do.

### Behaviour

| Variable | Default | Description |
|---|---|---|
| `START_AFTER_CREATE` | `0` | Start VMs immediately after creation (`1` = yes) |
| `AUTOMATE_NODE2_SYSID` | `1` | Inject serial numbers via guestfish (`1` = yes) |
| `WORKDIR` | `/var/tmp/ontap-sim-9.16.1` | Working directory on every host that runs a node; the OVA is extracted below it |
| `KEEP_EXTRACTED` | `0` | `0` = remove the extracted OVA directories after both nodes were imported successfully, `1` = keep them |

### Disk space and cleanup

- **Free-space check.** Before anything is extracted or created, the script checks `WORKDIR` on every host that extracts: needed = extracted size of the OVA + 10%. The extracted size comes from the tar listing (exactly what extraction writes); if the listing is not available it falls back to the OVA file size × 1.0, which is valid because an OVA is an uncompressed tar archive (the 10% margin covers tar padding). An old `extracted-<node>` directory from an earlier run counts as available, because it is replaced. Too little space: the script stops with host, path, needed and free, and nothing has been created.
- **One extraction per host.** If both nodes run on the same host (`TARGET_NODE1` and `TARGET_NODE2` have the same name), the OVA is extracted once and node 2 reuses the directory. On different hosts each host extracts its own copy.
- **Cleanup.** After both nodes were imported successfully, the `extracted-<node>` directories are removed. After an error nothing is removed, so the files can be inspected. `KEEP_EXTRACTED=1` keeps them always. Removal only touches paths strictly below an absolute `WORKDIR`; an empty or relative `WORKDIR`, `/`, or a path containing `..` is refused.

---

## Simulated disks

By default the simulator has 28 disks of 1 GB. With `SIM_DISK_TYPE` set, the script writes the disk layout to `/env/env` of both nodes, in the same guestfish inject as the serial/sysid, so it is in place before the first boot:

```
setenv bootarg.vm.sim.vdevinit "36:14:0,36:14:1"
setenv bootarg.sim.vdevinit "36:14:0,36:14:1"
```

Format: `<type>:<disks>:<shelf>` per shelf, comma-separated. The result is checked after writing, just like the serial. `--show-ports` prints the planned layout without changing anything.

| Type | Nominal size | Note |
|---|---|---|
| 23 | ~1 GB | OVA default |
| 31 | ~4 GB | |
| 36 | ~9 GB | largest type the sources agree on |

> **Source quality:** no official NetApp documentation for these values was found. The type table and the `vdevinit` format come from NetApp Community threads and blog posts on `vsim_makedisks` (`-t` type, `-n` disks, `-a` shelf). Confirm the sizes with `vsim_makedisks -h` on your simulator. Other types (e.g. 35, 37) only work with `SIM_DISK_SIZE_GB`.

### Finding out what fits: `--show-sim-disk`

The capacity of the sim disk is read from the OVA itself, so nothing has to be looked up by hand:

```bash
./ontap-sim-2node-proxmox.sh --show-sim-disk      # on a Proxmox host
```

It extracts the OVA on `TARGET_NODE1` (with the same free-space check as a deploy) or reuses an existing `extracted-<node>` directory, reads the virtual size of the sim disk (4th VMDK) with `qemu-img info`, and prints for every known disk type the size per disk and the maximum number of disks that fit (including `SIM_DISK_MARGIN_PCT`), spread over shelves (max 14 per shelf, max 4 shelves). Example (a 250 GB sim disk; the real size comes from your OVA):

```
Sim disk (4th OVA disk, ide3): 250 GB virtual; usable with 10% margin: 227 GB
  Type   GB/disk  Max disks  Layout (max 14 per shelf, max 4 shelves)
  23     1        56         4 x 14
  31     4        56         4 x 14
  36     9        25         1 x 14 + 1 x 11  <- SIM_DISK_TYPE

Current config: type 36 (~9 GB) x 14 per shelf x 2 shelves = 28 disks, vdevinit=36:14:0,36:14:1
  DOES NOT FIT: needs 277 GB incl. 10% margin, sim disk is 250 GB (maximum: 25 disks of type 36)
```

It also says whether the current `SIM_DISK_TYPE` / `SIM_DISKS_PER_SHELF` / `SIM_SHELVES` fit. No VM is created and nothing on Proxmox is changed. The extracted directory is removed afterwards unless `KEEP_EXTRACTED=1`; an already existing directory is reused and left in place. `--show-ports` stays a quick plan without extracting and points to this option.

### `SIM_DISKS_PER_SHELF="auto"`

With `auto` the script picks the highest number of disks per shelf (max 14) so that `SIM_SHELVES` shelves of `SIM_DISK_TYPE` disks fit the sim disk. The size is only known once the OVA is extracted, so the choice is made then and shown in the log and in the settings summary (e.g. `auto -> 12 per shelf`). If not even 1 disk per shelf fits, the script stops with the normal "does not fit" message and the maximum number of disks, before any VM is created.

**What does and does not work**

- `vdevinit` is, according to the community sources, only effective on a fresh simulator (before the first boot). Changing it on a node that has already booted is not supported by this script; redeploy the VM instead.
- The simulated disks are files on the 4th OVA disk (`ide3`). Right after the OVA has been extracted, and before the first VM is created, the script reads that disk's size once (the OVA is the same for both nodes) and stops with an error and the maximum number of disks if the layout (disks × size + `SIM_DISK_MARGIN_PCT`) does not fit. At that point nothing has been created on Proxmox.
- The sim disk is **not** resized. `qm resize` only grows the block device; it does not grow the partition or the filesystem inside it, and it could not be established that the simulator does that on first boot. Treat the size in the OVA as the limit.
- Limits: 14 disks per shelf, 4 shelves, 56 disks.
- Still to verify on a real deploy: the actual size of the sim disk in `vsim-netapp-DOT9.16.1-cm_nodar.ova`, whether the simulated disks are sparse files, and that ONTAP shows the new disks after the first boot (`storage disk show`).

---

## VM naming scheme

VMs are automatically named according to the following scheme:

```
{CLUSTER_PREFIX}-cluster{NN}-01   (node1)
{CLUSTER_PREFIX}-cluster{NN}-02   (node2)
```

The cluster number `NN` is automatically incremented if a cluster already exists. For example, if `sim-cluster01-01` and `sim-cluster01-02` already exist, the new VMs will be named `sim-cluster02-01` and `sim-cluster02-02`.

Both names of a cluster pair must be free — if only one exists, the number is also considered in use.

---

## Serial numbers

The ONTAP Simulator uses fixed license serials that are the same for every 2-node cluster:

| Node | SYS_SERIAL_NUM | SYSID |
|---|---|---|
| Node 1 | `4082368-50-7` | `4082368507` |
| Node 2 | `4034389-06-2` | `4034389062` |

These are injected via `guestfish` directly into `/env/env` on the imported RAW disk after import. This is the file that the VSIM VLOADER reads at boot.

---

## After deployment

Once the script completes:

```bash
# Start node1
ssh pve01 qm start <VMID1>

# Connect via serial console
ssh pve01 qm terminal <VMID1>

# Or use the Proxmox web interface: VM > Console
```

Then follow the standard ONTAP cluster setup wizard on node1 and join node2 via the cluster interconnect network.

---

## Changelog

| Version | Date | Description |
|---|---|---|
| v1.0 | 17-04-2026 | Initial version: basic 2-node OVA import on Proxmox |
| v1.1 | 17-04-2026 | Fixed disk import order (sort -V); replaced global NODE_DISKS with local nameref arrays |
| v1.2 | 17-04-2026 | Added VLOADER serial console automation via expect; fixed serial socket race condition |
| v1.3 | 17-04-2026 | Normalized hostname comparison (case-insensitive) for correct local node detection |
| v1.4 | 17-04-2026 | Added cluster-wide VM name check; changed naming to `{prefix}-cluster{NN}-01/02` |
| v1.5 | 17-04-2026 | Cluster-wide VMID allocation via pvesh; prevents conflicts with VMs on other nodes |
| v1.6 | 17-04-2026 | API precheck extended with retry loop (5 attempts); storage type check for VG validation |
| v1.7 | 17-04-2026 | Updated defaults: `OVA_STORAGE_ID=software`, `TARGET_NODE1=pve01`, `TARGET_NODE2=pve02` |
| v2.0 | 17-04-2026 | Replaced VLOADER serial console automation with direct guestfish inject into `/env/env` |
| v2.1 | 17-04-2026 | Fixed `/env/env` write syntax to VLOADER format: `setenv NAME "VALUE"` |
| v2.2 | 17-04-2026 | Inject script sent via SSH stdin with env variables; fixes path issues on remote nodes |
| v2.3 | 17-04-2026 | Fixed verification after inject: check tmpfile instead of re-reading VMDK (NFS cache issue) |
| v2.4 | 17-04-2026 | Fixed inject path passing; added explicit debug logging for inject path |
| v2.5 | 17-04-2026 | Moved inject from VMDK to imported RAW disk; guestfish upload on RAW works reliably |
| v2.6 | 17-04-2026 | Set fixed ONTAP Simulator license serials: node1=`4082368-50-7`, node2=`4034389-06-2` |
| v3.0 | 08-10-2026 | Cluster interconnect on separate `CLUSTER_BRIDGE`/`CLUSTER_VLAN_TAG` (required); CIFS defaults to data network; version no longer in filename; `--version`, `--show-ports` |
| v3.1 | 08-10-2026 | Optional bigger simulated disks (`SIM_DISK_TYPE`, `SIM_DISKS_PER_SHELF`, `SIM_SHELVES`) via `bootarg.(vm.)sim.vdevinit` in `/env/env`; one capacity check against the sim disk before the first VM is created |
| v3.1.1 | 08-10-2026 | Fix: environment variables now really override the config file (they were ignored for every variable the config assigns) |
| v3.1.2 | 08-10-2026 | Free-space check on `WORKDIR` per host before extracting; OVA extracted once when both nodes share a host; extracted directories removed after a successful run (`KEEP_EXTRACTED`) |
| v3.2 | 08-10-2026 | `--show-sim-disk` (capacity of the sim disk per disk type, no VM created); `SIM_DISKS_PER_SHELF="auto"` |

---

## License

MIT License — see [LICENSE](LICENSE) for details.

---

## Contributing

Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.
