# Changelog

All notable changes to this project are documented in this file.  
Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

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
- Script version number included in filename going forward (`ontap-sim-2node-proxmox-vX.Y.sh`).

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

1. Replace the script with `ontap-sim-2node-proxmox-v2.9.sh`.
2. Update `ontap-sim-2node-proxmox.conf` — add the new variables or use the updated default config:
   ```ini
   CIFS_BRIDGE="vmbr0"
   CIFS_VLAN_TAG="0"
   NUM_NET_PORTS="8"
   SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"
   ```
3. Remove `NETWORK_PORTS`, `MGMT_BRIDGE`, and `MGMT_VLAN_TAG` if present in your config (no longer used).
