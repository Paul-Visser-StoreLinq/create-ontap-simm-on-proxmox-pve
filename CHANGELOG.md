# Changelog

All notable changes to this project are documented in this file.  
Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [v3.1.2] – 2026-10-08

### Added
- **Free-space check on `WORKDIR`** before the OVA is extracted, once per host that extracts (`check_workdir_space()`). Needed = extracted OVA size + 10%. The size is taken from the tar listing (`determine_ova_extracted_size()`); when that is unavailable it falls back to the OVA file size × 1.0 (an OVA is an uncompressed tar, so this is accurate; the margin covers tar padding). An old `extracted-<node>` directory from a previous run counts as available since it is replaced. When there is not enough space the script stops with host, path, needed and free, before any VM exists.
- **`KEEP_EXTRACTED`** (default `0`) in the config and the script: remove (`0`) or keep (`1`) the extracted OVA directories after a successful run. Validated as 0 or 1.
- `cleanup_extracted()`: removes `WORKDIR/extracted-<node>` after both nodes were imported successfully. There is no `trap`, so after any error nothing is removed and the files stay for debugging.
- `assert_under_workdir()`: every `rm -rf` of an extract directory goes through it. It refuses an empty, relative or `/` `WORKDIR`, an empty path, a path containing `..` and any path that is not strictly below `WORKDIR`.

### Changed
- **Both nodes on the same host** (same `TARGET_NODE1`/`TARGET_NODE2` name, case-insensitive): the OVA is extracted once and node 2 reuses the directory (before: extracted twice into the same directory). On different hosts the behaviour is as before: one extraction per host.
- The extract directory is now derived by `extract_dir_for()` and guarded before the existing `rm -rf` inside `prepare_vmdks_on_node()`.

### Notes
- Existing local configs keep working without edits (`KEEP_EXTRACTED` defaults to `0`). **Behaviour change:** the extracted directories used to stay behind after a run; they are now removed on success. Set `KEEP_EXTRACTED=1` for the old behaviour.
- "Same host" means the same node name. Two different names that resolve to one machine (e.g. short name vs FQDN) are treated as two hosts: two extractions, still correct.

---

## [v3.1.1] – 2026-10-08

### Fixed
- **Environment variables did not override the config file.** The header, `--help` and the README promise this (`VMID1=200 ./ontap-sim-2node-proxmox.sh`, `CLUSTER_NUM=3`, `START_AFTER_CREATE=1`), but the config assigns every variable unconditionally after the environment was read, so the environment value was silently thrown away. This affected every variable in the config (all 31 of them), and existed before v3.1.
- The script now remembers which config variables are already set in the environment before sourcing the config, and restores those values afterwards. No change to the config format, so existing local configs keep working without edits.

### Notes
- A variable set in the environment but empty also wins (an empty `CLUSTER_VLAN_TAG` in the environment still triggers the "not set" error).
- Derived defaults follow the config, not the environment: setting only `OVA_STORAGE_ID` does not move `OVA_DIR`, because the config computes `OVA_DIR` from its own `OVA_STORAGE_ID`. Set both, or `OVA_DIR` directly.

---

## [v3.1] – 2026-10-08

Backwards compatible: without the new variables the behaviour is unchanged (OVA default disks, `/env/env` only gets the serial/sysid).

### Added
- Optional larger simulated disks, configured at deploy time (before the first boot): `SIM_DISK_TYPE`, `SIM_DISKS_PER_SHELF` (1–14, default 14), `SIM_SHELVES` (1–4, default 2), plus `SIM_DISK_SIZE_GB` (for types outside the built-in table) and `SIM_DISK_MARGIN_PCT` (default 10).
- `setenv bootarg.vm.sim.vdevinit` and `setenv bootarg.sim.vdevinit` (`<type>:<disks>:<shelf>,...`) are written to `/env/env` of both nodes by the existing guestfish inject. Earlier vdevinit lines are replaced (no duplicates on a re-run) and both lines are verified after writing, like the serial.
- `validate_sim_disk_config()`: startup validation (type, ranges, size table, requires `AUTOMATE_NODE2_SYSID=1`).
- `check_sim_disk_capacity()`: reads the size of the sim disk (4th OVA disk, `ide3`) with `qemu-img info`. It runs **once**, right after the OVA has been extracted and before the first VM is created (the OVA is the same for both nodes). If disks × size + margin does not fit, it stops with the maximum number of disks for that type, and no VM exists yet.
- The disk setting is shown in the startup summary, in `--show-ports` (`print_sim_disk_info()`), at the end of the run and in the VM description.

### Changed
- The OVA is now extracted for both nodes up front (new in `main`), before `create_vm` runs; `create_vm` receives the extracted VMDK list as its 7th argument. Without `SIM_DISK_TYPE` this only changes the order of the steps, not the result.

### Notes
- The sim disk is deliberately **not** resized with `qm resize`: that only grows the block device, not the filesystem inside it, and it could not be confirmed that the simulator grows it on first boot. See README, "Simulated disks".
- The disk type table (23 = ~1 GB, 31 = ~4 GB, 36 = ~9 GB) and the `vdevinit` format are based on NetApp Community posts, not on official documentation. Verify with `vsim_makedisks -h`.

---

## [v3.0] – 2026-10-08

> **Breaking:** configs written for v2.x are not compatible. `CLUSTER_VLAN_TAG` is now required; the script stops with an error if it is empty.

### Added
- `CLUSTER_BRIDGE` (default `vmbr1`) and `CLUSTER_VLAN_TAG` (**required**, no default) for the cluster interconnect (`net0`, `net1`).
- Startup validation (before anything happens on Proxmox): aborts if `CLUSTER_VLAN_TAG` is empty, if a VLAN tag is not an integer 0–4094, or if cluster and data use the same bridge and the same VLAN tag (including `0`/`0`).
- `SCRIPT_VERSION` variable at the top of the script as the single source of truth for the version; shown in `--help`, the startup summary and the VM description.
- `--version` option.
- `require_proxmox_host()`: stops with a clear message when the script is not run on a Proxmox VE host (`qm`/`pvesh`/`pvesm` missing).
- `--show-ports` option: validates the network config and prints the bridge/VLAN per port, without touching Proxmox (also works off-Proxmox).
- Startup summary and VM description now include `CLUSTER_BRIDGE` / `CLUSTER_VLAN_TAG`.

### Changed
- **Version number is no longer part of the filename.** The script is now `ontap-sim-2node-proxmox.sh` (was `ontap-sim-2node-proxmox-vX.Y.sh`). This supersedes the v2.7 note "Script version number included in filename going forward".
- `DATA_BRIDGE` / `DATA_VLAN_TAG` now apply only to the data ports (NFS, iSCSI).
- **Behaviour change:** `CIFS_BRIDGE` / `CIFS_VLAN_TAG` now default to `DATA_BRIDGE` / `DATA_VLAN_TAG` (previously `vmbr0`, untagged). They remain available as an optional override. If you relied on CIFS ending up on `vmbr0`, set `CIFS_BRIDGE="vmbr0"` and `CIFS_VLAN_TAG="0"` explicitly.
- Port mapping and `print_port_info()` show the correct bridge/VLAN per port group: `net0`/`net1` cluster, then CIFS, NFS, iSCSI.
- All `.conf` files: Network Configuration section extended with `CLUSTER_*` and commented-out `CIFS_*` overrides; header no longer refers to a versioned script name. `CLUSTER_VLAN_TAG` is left empty and must be filled in per the StoreLinq network VLAN plan.

### Upgrading from v2.x
1. Use `ontap-sim-2node-proxmox.sh` (the old versioned file is gone).
2. Set `CLUSTER_VLAN_TAG` (and optionally `CLUSTER_BRIDGE`) in your config, different from the data network.
3. Set `CIFS_BRIDGE` / `CIFS_VLAN_TAG` explicitly if CIFS should stay on a different network than NFS/iSCSI.

---

## [v2.9] – 2026-04-29

### Added
- `CIFS_BRIDGE` and `CIFS_VLAN_TAG` configuration variables — CIFS ports get their own bridge (default `vmbr0`), separate from the cluster/NFS/iSCSI bridge.
- Port-mapping table printed at end of run now includes the bridge and VLAN per port group.

### Changed
- Network port assignment is now protocol-aware:
  - `net0`, `net1` → cluster interconnect → `DATA_BRIDGE`
  - next N ports → CIFS (ifgroup `a0a`) → `CIFS_BRIDGE`
  - next N ports → NFS (ifgroup `a0b`) → `DATA_BRIDGE`
  - last N ports → iSCSI (individual) → `DATA_BRIDGE`
- `ontap-sim-2node-proxmox.conf` Network Configuration section updated with bridge-per-protocol documentation.

---

## [v2.8] – 2026-04-29

### Fixed
- **"Host key verification failed"** when running the script from a node where target nodes are not yet in `/root/.ssh/known_hosts`.  
  Root cause: `BatchMode=yes` causes SSH to reject unknown host keys silently.  
  Fix: added `-o StrictHostKeyChecking=accept-new` to `SSH_OPTS` — new host keys are accepted and stored automatically; changed keys are still rejected.

### Changed
- `SSH_OPTS` default updated in both script and `.conf` to include `StrictHostKeyChecking=accept-new`.
- Script can now be started from **any Proxmox node** in the cluster without pre-populating `known_hosts`.

---

## [v2.7] – 2026-04-28

### Added
- `NUM_NET_PORTS` configuration variable — number of network ports to create per VM (default: `8`).  
  Formula: `2 (cluster) + 3×N`, valid values: `5, 8, 11, 14, …`
- `validate_num_ports()` — validates `NUM_NET_PORTS` at startup; exits with a clear message if the value is invalid.
- `print_port_info()` — prints the full ONTAP port mapping and ready-to-use `network port ifgrp` commands after deployment.
- Script can now be started from any Proxmox node (removed local OVA readability check; per-node check via API/SSH was already in place).

### Changed
- Hardcoded 8-port network setup replaced with a dynamic loop driven by `NUM_NET_PORTS`.
- `socat` removed from `require_cmd` (only used in dead-code path replaced by guestfish in v2.5).
- `python3` added to `require_cmd` (was already used but not verified at startup).
- `MGMT_BRIDGE` / `MGMT_VLAN_TAG` / `NETWORK_PORTS` removed — superseded by `NUM_NET_PORTS` and protocol-specific bridge variables.
- `DATA_BRIDGE` and `DATA_VLAN_TAG` are now the primary (only) bridge variables in this version.
- OVA readability precheck now uses the Proxmox storage content API as primary method; SSH `test -r` as fallback. Provides actionable error output if both fail.
- Startup summary now includes `DATA_BRIDGE`, `DATA_VLAN_TAG`, and `NUM_NET_PORTS`.

---

## [v2.6] – 2026-04-17 *(baseline for this changelog)*

### Added
- Fixed ONTAP Simulator license serial numbers written via guestfish:
  - Node 1: `SYS_SERIAL_NUM=4082368-50-7` / `SYSID=4082368507`
  - Node 2: `SYS_SERIAL_NUM=4034389-06-2` / `SYSID=4034389062`
- Serials configurable via `NODE1_SYS_SERIAL_NUM`, `NODE1_SYSID`, `NODE2_SYS_SERIAL_NUM`, `NODE2_SYSID`.

---

## Release notes — v2.9

**ONTAP Simulator 2-node Proxmox deployment — release v2.9**

This release completes the flexible network configuration introduced in v2.7 and resolves two operational issues that prevented the script from running on arbitrary cluster nodes.

### What's new since v2.6

| Version | Highlight |
|---------|-----------|
| v2.7 | Configurable `NUM_NET_PORTS`; dynamic port assignment with protocol mapping and ONTAP ifgroup commands printed at completion |
| v2.8 | SSH host-key fix — script now works from any Proxmox node without manual `known_hosts` setup |
| v2.9 | CIFS ports on separate bridge (`CIFS_BRIDGE`); cluster/NFS/iSCSI stay on `DATA_BRIDGE` |

### Network layout (default: 8 ports)

```
Proxmox  ONTAP  Protocol               Bridge
-------  -----  --------               ------
net0     e0a    cluster interconnect   vmbr1 vlan 20
net1     e0b    cluster interconnect   vmbr1 vlan 20
net2     e0c    cifs  (ifgroup a0a)    vmbr0
net3     e0d    cifs  (ifgroup a0a)    vmbr0
net4     e0e    nfs   (ifgroup a0b)    vmbr1 vlan 20
net5     e0f    nfs   (ifgroup a0b)    vmbr1 vlan 20
net6     e0g    iscsi (individual)     vmbr1 vlan 20
net7     e0h    iscsi (individual)     vmbr1 vlan 20
```

Change `NUM_NET_PORTS` in the config for a different port count (valid: 5, 8, 11, …). CIFS always goes to `CIFS_BRIDGE`, everything else to `DATA_BRIDGE`.

### Upgrading from v2.6

1. Replace the script with the v2.9 release (filename at that time: `ontap-sim-2node-proxmox-v2.9.sh`; from v3.0 the name is unversioned).
2. Update `ontap-sim-2node-proxmox.conf` — add the new variables or use the updated default config:
   ```ini
   CIFS_BRIDGE="vmbr0"
   CIFS_VLAN_TAG="0"
   NUM_NET_PORTS="8"
   SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"
   ```
3. Remove `NETWORK_PORTS`, `MGMT_BRIDGE`, and `MGMT_VLAN_TAG` if present in your config (no longer used).
