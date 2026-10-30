# DataCore Storage Plugin for Proxmox VE

A Proxmox VE storage plugin to integrate [DataCore SANsymphony™](https://www.datacore.com/products/sansymphony/) storage using **iSCSI** or **NVMe/TCP**, with multipath support and the `ssy-plugin` terminal console for management, Continuous Data Protection and recovery.

## 📚 Table of Contents

1. [Overview](#-overview)
2. [What's New in v2.0.0 (preview)](#-whats-new-in-v200-preview)
3. [Quick start](#-quick-start)
4. [Prerequisites](#-prerequisites)
5. [Installation](#-installation)
   - [Installing the preview build (.deb)](#installing-the-preview-build-deb)
   - [What the installer changes on each node](#what-the-installer-changes-on-each-node)
6. [Add a SANsymphony storage class](#-add-a-sansymphony-storage-class)
   - [Using the console wizard (recommended)](#using-the-console-wizard-recommended)
   - [Using pvesm add](#using-pvesm-add)
   - [Editing /etc/pve/storage.cfg](#editing-etcpvestoragecfg)
7. [The ssy-plugin console](#-the-ssy-plugin-console)
   - [Keyboard shortcuts](#keyboard-shortcuts)
8. [Everyday disk operations](#-everyday-disk-operations)
9. [Data protection and recovery](#-data-protection-and-recovery)
   - [Continuous Data Protection (CDP)](#continuous-data-protection-cdp)
   - [Snapshots](#snapshots)
   - [Recovery workflows](#recovery-workflows)
10. [Performance and multipath](#-performance-and-multipath)
11. [Logging and diagnostics](#-logging-and-diagnostics)
12. [Troubleshooting](#-troubleshooting)
13. [Removing storage and uninstalling](#-removing-storage-and-uninstalling)
    - [Remove a storage class](#remove-a-storage-class)
    - [Uninstall the plugin](#uninstall-the-plugin)
14. [Reference](#-reference)
    - [Storage class options](#storage-class-options)
    - [Version history](#version-history)
15. [FAQ](#-faq)

<br/>

References
- [Proxmox Host Configuration Guide](https://docs.datacore.com/SSV-WebHelp/SSV-WebHelp/FAQ/Host-Configuration-Guide/Proxmox_Configuration_Guide.htm) – Host setup, network configuration instructions and more.
- [DataCore SANsymphony Help](https://docs.datacore.com/SSV-WebHelp/SSV-WebHelp/Welcome_to_DataCore_SANsymphony_Help.htm) – SANsymphony product documentation.

<br/>

---

## ✨ Overview

This plugin adds a new storage type, **`ssy`**, to Proxmox VE. Each VM disk you create on it becomes its own **DataCore SANsymphony virtual disk (vDisk)**. The vDisk is served to every node in the cluster and mapped to the VM as a raw device. Because the storage is truly shared, **live migration and Proxmox HA work as they do on any shared storage.**

You do everyday disk work (create, attach, resize, delete) in the **Proxmox web UI or CLI**, as usual. You do SAN-side work that Proxmox has no model for (CDP, SAN snapshots, recovery, re-tiering, performance history) in the **`ssy-plugin` console**, a full-screen terminal UI you run over SSH. Nothing inside Proxmox is patched.

> [!WARNING]
> **`2.0.0~preview` is a pre-release for evaluation, not a supported production release.**
> It supports Proxmox VE 8.x and 9.2, up to the latest release, **9.2.24**, which DataCore has tested in a multi-node cluster. Try it on a test cluster first.
> This preview build is available **only as a `.deb` package**. Installing the final 2.0.0 later upgrades it in place.

### How it works

```text
  You:  "Add Hard Disk, 32 GiB, on my SSY storage"
          │
          ▼
  ①  The plugin asks SANsymphony (REST API) to create a vDisk from your template
  ②  SANsymphony serves the new vDisk to every node in the storage class
  ③  Each node sees it over iSCSI or NVMe/TCP, across several paths (multipath)
  ④  Proxmox attaches it to the VM as a raw device: live migration and HA just work
```

If any step fails, for example because no session to the SAN is up, the half-created vDisk is unserved and deleted. **Nothing is left behind on the SAN.**

### Key capabilities

| | Capability | What you get |
|:-:|---|---|
| ⚙ | **Automated host setup** | udev rule, per-target iSCSI settings, SCSI timeouts and `multipath.conf`, applied at install. No manual host tuning. |
| ⇉ | **Multipath** | Several iSCSI sessions or NVMe/TCP connections per disk, ALUA/ANA-aware, so a single link or port failure doesn't take a disk offline. |
| ▦ | **Shared storage with dynamic RDM** | Define a storage class once and use it on every node. Each VM disk is provisioned on demand. |
| ▤ | **LVM and Directory on SANsymphony** | Put a shared LVM volume group or a formatted directory storage on a SANsymphony vDisk. |
| ⇄ | **High availability and live migration** | Move running VMs between nodes with no downtime. Proxmox HA restarts VMs on a healthy node. |
| ◈ | **The `ssy-plugin` console** | A fleet view of every SANsymphony-backed VM, vDisk and pool, plus CDP, snapshots, recovery, resize, re-tiering, performance history and diagnostics. |

### What ships in the package

One `.deb` holds everything, so all the pieces are installed and upgraded together:

| Component | What it is | Use it for |
|---|---|---|
| **Storage plugin** (`SANsymphonyPlugin.pm`) | The Proxmox storage type `ssy` | VM disk create, attach, resize and delete from the web UI, `qm` and `pvesm` |
| **`ssy-plugin`** | Full-screen terminal console | Adding storage, browsing the fleet, CDP, snapshots, recovery, performance, logs |
| **`ssy-multipath`** | Shell helper | Path topology annotated with DataCore port and vDisk names |
| **`ssy-plugin-collect`** | Background service | Recording performance history for every vDisk, all the time |
| **`ssy-plugin-old`** | The earlier prompt-and-answer CLI | Older scripts and runbooks |

### Proxmox alone vs. with the console

| Capability | Through Proxmox | With the `ssy-plugin` console |
|---|---|---|
| Content and format | VM disk images, raw block devices | — |
| Shared across nodes | ✅ Yes | Cluster-wide view |
| Transports | iSCSI and NVMe/TCP, per storage class | Both resolved per disk |
| Path redundancy | ✅ Multipath | Live path topology |
| Thin provisioning | From the vDisk template | Pool commitment gauges |
| Live migration and HA | ✅ Yes | — |
| Resize | Grow only | Guided, propagated to every node |
| Full clone / Move Disk | ✅ Yes | — |
| Proxmox snapshots, linked clones, templates | ❌ Not on `ssy:` volumes | SAN snapshots; clone from a snapshot or recovery point |
| Continuous Data Protection | ❌ | ✅ Yes |

---

## 🆕 What's New in v2.0.0 (preview)

| Capability | Before | Now |
|---|---|---|
| **Proxmox VE support** | Validated up to 9.2.3 | Supports the latest release, **9.2.24** |
| **Fleet visibility** | Per-VM disk view in Proxmox's storage tab | One tree of every SSY-backed VM, vDisk, LVM and Directory storage, orphan disk and pool |
| **Continuous Data Protection** | Not available in Proxmox | One switch per VM or disk, sized from the real write rate, with a downtime guardrail on unmirrored disks |
| **Instant recovery** | Manual work in the DataCore console | Create a recovery point, boot it network-isolated, compare, promote to production |
| **Multi-VM recovery** | One VM at a time, by hand | Recover every VM on a shared LVM volume from one point in a single pass |
| **Snapshots** | Not available | Per-disk and whole-VM consistent snapshot sets; clone or promote from any point |
| **Resize and re-tier** | Proxmox resize only | Guided extend propagated to every node; change a live vDisk's storage profile |
| **Storage provisioning** | Command-line wizard | Guided wizards for SSY, LVM and Directory storage, and a blocker-checked remove |
| **Monitoring** | DataCore console only | Performance history (5 min to 1 year), pool capacity gauges, DataCore alerts |
| **Troubleshooting** | Scattered logs | Log viewer, per-operation logs and a one-command support bundle |

---

## 🚀 Quick start

Already know Proxmox and SANsymphony? This is the whole journey for an iSCSI setup:

```bash
# 1. On EVERY node: install prerequisites (NVMe/TCP users: see Prerequisites)
apt install open-iscsi multipath-tools jq

# 2. On EVERY node: download and install the preview package (.deb only)
wget https://github.com/DataCoreSoftware/Scripts/releases/download/SSY_PVE_Plugin/SANsymphony-plugin_2.0.0~preview_amd64.deb
dpkg -i SANsymphony-plugin_2.0.0~preview_amd64.deb

# 3. On ONE node: open the console and choose "Add SSY storage"
ssy-plugin

# 4. Confirm the storage is active
pvesm status
```

Now create a VM in the Proxmox web UI and pick your SSY storage for its disk. 🎉

```text
Prepare ──► Install ──► Add storage ──► Run VMs ──► Protect
template,   on every    once per        disks,      CDP, snapshots,
packages    node        cluster         resize      recovery
```

---

## ✅ Prerequisites

Have these in place **before** you install. The plugin does not install the transport packages for you.

| Requirement | Details |
|---|---|
| **Proxmox VE** | 8.x or 9.2, up to the latest release, **9.2.24**. Install the plugin on **every node** in the cluster. |
| **vDisk template** | A SANsymphony virtual disk template for new disks. **It must match the protocol:** NVMe-enabled for NVMe/TCP, non-NVMe for iSCSI. |
| **iSCSI packages** | `open-iscsi` and `multipath-tools` |
| **NVMe/TCP packages** | `nvme-cli`, with the `nvme-tcp` kernel module loaded |
| **jq** | Required. `dpkg` doesn't install dependencies, so install it before the plugin. |
| **Network** | Every node can reach the SANsymphony **management addresses** and **front-end portals**. |
| **SANsymphony account** | A user allowed to **create, modify, serve and delete** virtual disks. |
| **Console access** | A terminal on a node. Python 3.11+ is already present on supported Proxmox VE versions. |

**For iSCSI:**

```bash
apt install open-iscsi multipath-tools jq
```

**For NVMe/TCP:**

```bash
apt install nvme-cli jq
modprobe nvme-tcp
echo nvme-tcp > /etc/modules-load.d/nvme-tcp.conf   # load at every boot
```

📘 More detail: [Proxmox Host Configuration Guide](https://docs.datacore.com/SSV-WebHelp/SSV-WebHelp/FAQ/Host-Configuration-Guide/Proxmox_Configuration_Guide.htm)

---

## 📦 Installation

> [!IMPORTANT]
> **This preview build is available only as a `.deb` package.** Download it and install it with `dpkg`, as shown below.
> Install the plugin on **every node** in the cluster.

### Installing the preview build (.deb)

The package is **self-contained**: the console's Python libraries are bundled inside it, so it also installs on an **air-gapped** node. `dpkg` does not resolve dependencies, so install the [prerequisites](#-prerequisites) first.

```bash
# 1. Download the package
wget https://github.com/DataCoreSoftware/Scripts/releases/download/SSY_PVE_Plugin/SANsymphony-plugin_2.0.0~preview_amd64.deb

# 2. Install it
dpkg -i SANsymphony-plugin_2.0.0~preview_amd64.deb
```

No internet access on the node? Download the file on another machine and copy it over, for example with `scp SANsymphony-plugin_2.0.0~preview_amd64.deb root@<node>:`.

### Verify the installation

```bash
dpkg -l | grep ssy-plugin
ssy-plugin --version          # 2.0.0~preview
```

`dpkg -s ssy-plugin` also shows a **PREVIEW PRE-RELEASE** notice in the package description.

### What the installer changes on each node

Before changing anything, the installer backs up existing configuration to `/var/backups/SANsymphony-Plugin-Backup/`. It then applies:

| Area | What changes |
|---|---|
| **iSCSI** | Recommended settings applied **per target** at login (`iscsiadm … --op update`), not in the global `iscsid.conf`. Re-applied each time a target is activated. |
| **iSCSI multipath** | `/etc/multipath.conf` created or updated with DataCore device settings. A dated backup is kept, then `multipath -r` reloads it. |
| **udev rule** | `/etc/udev/rules.d/99-datacore.rules` sets an **80-second SCSI timeout** on DataCore disks. Rules are reloaded only when the file changed. |
| **NVMe/TCP** | Uses native Linux NVMe multipathing. No extra configuration. |
| **Proxmox services** | `pvedaemon`, `pveproxy`, `pvestatd`, `pvescheduler` and `pve-ha-lrm` are reloaded, and restarted only when needed. |
| **Console** | The `ssy-plugin` console, the `ssy-plugin-collect` performance service, a root-only log directory and its `logrotate` policy. |

<details>
<summary><b>Show the exact iSCSI, multipath and udev settings</b></summary>

**iSCSI, applied per target:**

```ini
node.startup = manual
node.leading_login = No
node.session.timeo.replacement_timeout = 15
node.session.initial_login_retry_max = 0
```

**`/etc/multipath.conf`:**

```text
defaults {
    user_friendly_names    yes
    polling_interval       60
    find_multipaths        "smart"
}
blacklist {
    devnode "^(ram|raw|loop|fd|md|dm-|sr|scd|st)[0-9]*"
    devnode "^hd[a-z]"
}
devices {
    device {
        vendor               "DataCore"
        product              "Virtual Disk"
        path_checker          tur
        prio                  alua
        failback              10
        no_path_retry         fail
        dev_loss_tmo          60
        fast_io_fail_tmo      5
        rr_min_io_rq          100
        path_grouping_policy  group_by_prio
    }
}
```

**`/etc/udev/rules.d/99-datacore.rules`:**

```text
SUBSYSTEM=="block", ACTION=="add", ATTRS{vendor}=="DataCore", ATTRS{model}=="Virtual Disk    ", RUN+="/bin/sh -c 'echo 80 > /sys/block/%k/device/timeout' "
```

**Check NVMe native multipath:**

```bash
cat /sys/module/nvme_core/parameters/multipath   # expect: Y
nvme list-subsys /dev/nvme0                      # ANA state and paths
```

</details>

---

## 🔌 Add a SANsymphony storage class

Do this **once, on any one node**. `/etc/pve/storage.cfg` is shared by the whole cluster.

> [!NOTE]
> The Proxmox web UI can't add custom storage plugins. Use the console (recommended), `pvesm add`, or edit `storage.cfg` directly.

### Using the console wizard (recommended)

Run `ssy-plugin` and choose **Add SSY storage** on the Home screen. The wizard has seven steps:

| Step | What you do |
|:-:|---|
| 1 | **Protocol**: pick iSCSI or NVMe/TCP. |
| 2 | **Server IPs**: enter one or more SANsymphony management addresses. Each one is ping-checked. |
| 3 | **Credentials**: enter the SANsymphony user and password. |
| 4 | **VD template**: pick a template. Only templates that match the protocol are offered. |
| 5 | **Front-end portals**: these are discovered for you. Offline ports are skipped with a warning; the wizard stops only if no portal is online. |
| 6 | **Name and nodes**: name the storage class and choose the Proxmox nodes that use it. |
| 7 | **Review and add**: confirm, and the storage is added for the whole cluster. |

The same Home screen also adds **LVM on SSY** and **Directory storage** (`ext4`, `xfs` or `btrfs`) on top of an SSY storage class.

### Using `pvesm add`

```bash
pvesm add ssy <storage-name> \
    --SSYipAddress <ip1>,<ip2> \
    --SSYusername <user> \
    --SSYpassword <password> \
    --portals <portal1>,<portal2> \
    --targets <iqn1>,<iqn2> \
    --vdTemplateName <template> \
    --nodes <node1>,<node2> \
    --protocol iscsi \
    --shared 1 \
    --disable 0
```

Every option is described under [Storage class options](#storage-class-options).

### Editing `/etc/pve/storage.cfg`

<table>
<tr><th>iSCSI</th><th>NVMe/TCP</th></tr>
<tr>
<td>

```text
ssy: Storage-Name
    SSYipAddress 10.15.1.19,10.15.1.18
    SSYusername administrator
    portals 10.15.1.17,10.15.1.16
    targets iqn.2000-08.com.datacore:ssy1-1,iqn.2000-08.com.datacore:ssy2-1
    vdTemplateName SSY-VDT
    nodes pve1,pve2
    protocol iscsi
    shared 1
    disable 0
```

</td>
<td>

```text
ssy: Storage-Name-NVMe
    SSYipAddress 10.15.1.19,10.15.1.18
    SSYusername administrator
    portals 10.15.1.17,10.15.1.18,10.15.2.17,10.15.2.18
    targets nqn.2000-08.com.datacore:ssy1
    vdTemplateName SSY-VDT-NVMe
    protocol nvme-tcp
    nodes pve1,pve2
    shared 1
```

</td>
</tr>
</table>

Then store the password **Base64-encoded** in `/etc/pve/priv/storage/<storage-name>.pw`, readable by root only.

> [!IMPORTANT]
> Never put the password in `storage.cfg`. If the installer finds a plaintext password there on upgrade, it moves it into the `.pw` file for you.

### Protocol rules

| | iSCSI | NVMe/TCP |
|---|---|---|
| **Portals vs. targets** | Number of portals **must equal** number of targets; each portal pairs with one IQN | Several portals allowed, but only **one target NQN** per server group |
| **Discovery** | Standard iSCSI | Port **8009** |
| **Storage class** | Its own | Needs **its own** storage class, separate from iSCSI |
| **Template** | Non-NVMe template | NVMe-enabled template |

> [!CAUTION]
> If the template's protocol doesn't match the storage class, disk creation fails.
> The template's alias becomes the suffix of every disk name: a disk for VM 101 from template alias `MR` is named `101-MR`, so choose aliases that read clearly.

### Verify

```bash
pvesm status
```

The storage should show type `ssy` and status `active`, and appear under **Datacenter → Storage** in the web UI. If it doesn't appear after a `pvesm add` or a manual edit, restart the Proxmox services on the affected nodes:

```bash
systemctl restart pvedaemon pveproxy pvestatd pvescheduler
```

---

## 💻 The ssy-plugin console

Run it on **any node**. It reads the storage configuration and credentials the plugin already wrote, so there is nothing extra to set up.

```bash
ssy-plugin                     # opens the console
tmux new -s ssy 'ssy-plugin'   # for long operations: survives a dropped SSH session
```

> [!TIP]
> If your terminal looks odd after a dropped session, run `reset`.

### Home screen

| Card | What it does |
|---|---|
| **Manage storage** | Browse VMs, vDisks, snapshots, pools and paths |
| **Add SSY storage** | Connect a SANsymphony server group over iSCSI or NVMe/TCP |
| **Add LVM on SSY** | A shared LUN and volume group for many VMs |
| **Add Directory storage** | A formatted, mounted vDisk for ISOs, backups or templates |
| **Remove storage** | Tear down storage. Blocked while anything still depends on it |
| **Readiness line** | Whether storage is configured, the SAN is reachable, and `multipath`/`nvme` are present |

Manage storage, Add LVM and Add Directory become available once an SSY storage class exists.

### Manage storage

A Proxmox-style layout: a tree on the left, details in the centre, live statistics along the bottom. Mouse and keyboard both work, the layout adapts to the terminal size, and the colours follow your terminal's light or dark theme.

| Tree group | Shows |
|---|---|
| **Virtual Machines** | Every VM with an SSY-backed disk (block or LVM), with per-disk CDP status |
| **SSY Storage** | Each `ssy:` storage and its vDisks, mapped to the VMs using them |
| **LVM on SSY** | Volume groups on a DataCore LUN, the backing vDisk, and each logical volume's VM |
| **Directory on SSY** | Directory storages on a DataCore LUN. Resize grows the vDisk only, not the filesystem |
| **Orphan vDisks** | vDisks served to a node but attached to no VM: **Attach to VM**, **Create new VM** or **Unserve & delete** |
| **Pools** | Capacity and allocation per pool, and the vDisks drawing from it |
| **Alerts** | Unacknowledged and recent DataCore alerts |

### vDisk actions

| Action | What happens |
|---|---|
| ⤢ **Resize** (extend only) | Pre-checked against DataCore, then propagated to every node: SCSI rescan → multipath map resize → LVM `pvresize` → per-node rescan |
| ⛉ **Storage profile** | Re-tier a live vDisk from its Settings tab. DataCore moves the data in the background |
| ◈ **CDP and snapshots** | See [Data protection and recovery](#-data-protection-and-recovery) |
| ⌫ **Remove** | A blocker report first (rollbacks, a non-empty volume group, VM or container users), then unserve and delete, cleaning stale SCSI and multipath state on every node |

Every consequential action asks **"Are you sure?"** first, and the **Yes** button turns red when the action can't be undone. Long operations run in the background and show DataCore's own messages word for word.

### Keyboard shortcuts

| Key | Action | Key | Action |
|:-:|---|:-:|---|
| <kbd>Enter</kbd> | Select / open | <kbd>5</kbd> | Performance history |
| <kbd>Tab</kbd> | Move focus | <kbd>x</kbd> | Remove vDisk |
| <kbd>r</kbd> | Refresh (keeps your place) | <kbd>Ctrl</kbd>+<kbd>L</kbd> | Log viewer |
| <kbd>b</kbd> | Toggle sidebar | <kbd>Ctrl</kbd>+<kbd>T</kbd> | Toggle theme |
| <kbd>1</kbd> | Resize | <kbd>?</kbd> | Help |
| <kbd>3</kbd> | CDP | <kbd>Esc</kbd> | Back |
| <kbd>4</kbd> | Snapshots | <kbd>q</kbd> | Quit |

---

## 💽 Everyday disk operations

Day-to-day disk work happens in Proxmox as usual, and the plugin handles the SANsymphony side.

### In the web UI

- **Create a VM:** in **Create VM → Disks**, choose the SSY storage and a size. A SANsymphony vDisk of that size is created and presented to the node.
- **Add a disk:** **Hardware → Add → Hard Disk**, then pick the SSY storage. Each disk is its own vDisk.
- **Extend a disk:** **Hardware → Disk Action → Resize**, then enter the increase in GiB.
- **List volumes:** **\<SSY storage\> → VM Disks** lists used and unused vDisks. Disks that back LVM storage aren't listed.
- **Delete a VM:** **More → Remove** deletes the VM **and every SANsymphony vDisk it owns**.

### Operations at a glance

| Operation | Web UI | CLI | What happens on SANsymphony |
|---|---|---|---|
| **List** | Storage → VM Disks | `pvesm list <storage>` | Read from this node's paths; the same list on every node |
| **Allocate** | Hardware → Add → Hard Disk | `pvesm alloc <storage> <vmid> '' 32G` | Creates a vDisk from the template and serves it to the nodes |
| **Attach** | Edit an `unused` disk | `qm set <vmid> --scsi1 <volid>` | Nothing; Proxmox configuration only |
| **Detach** | Disk Action → Detach | `qm unlink <vmid> --idlist scsi1` | Nothing; the disk stays as `unused` |
| **Delete** | Remove an `unused` disk | `pvesm free <volid>` | Unserves the vDisk from every node and deletes it |
| **Resize** | Disk Action → Resize | `qm resize <vmid> scsi1 +16G` | Grows the vDisk (grow only) |
| **Status** | Storage → Summary | `pvesm status` | Active while a session to the SAN is up |

### Volume naming

A volume ID embeds the device's permanent identity and ends with the owning VM's ID:

```text
# iSCSI     <storage>:<channel>.<target>.<lun>.scsi-3<NAA>:<vmid>
ssy1:0.0.1.scsi-360030d90737df90149c3a6d1e2f4b8a7:101

# NVMe/TCP  <storage>:0.<ctrl>.<ns>.nvme-uuid.<uuid>:<vmid>
ssy2-nvme:0.0.1.nvme-uuid.60030d90-737d-4901-89c3-a6d1e2f4b8a7:101
```

In SANsymphony the vDisk is named `<vmid>-<template alias>` and described as `[Proxmox VM <vmid>]`. The format is always `raw`, and the minimum size is 1 GiB. A VM with two or more disks gets one SANsymphony **virtual disk group** named after its VM ID.

### Good to know

> [!WARNING]
> **Don't attach one volume to two running VMs.** This is shared storage, not a shared filesystem.
> Detach a disk before deleting it, or the VM keeps a stale reference.

- 📏 **Resize grows the device only.** Extend the partition and filesystem inside the guest yourself. For LVM and Directory storage, resize from the console so the new size reaches multipath and LVM on every node.
- 📸 **Proxmox snapshots, linked clones and templates aren't supported** on `ssy:` volumes. Full clone and Move Disk work. Use the console for SAN [snapshots](#snapshots) and [CDP](#continuous-data-protection-cdp).

---

## 🔒 Data protection and recovery

All of this lives in the `ssy-plugin` console.

### Continuous Data Protection (CDP)

CDP records every write in a DataCore journal, so you can recover a VM to any moment inside its retention window.

| Concept | Set on | Meaning |
|---|---|---|
| **Retention target** | VM | Hours of recovery you want, applied to every protected disk of the VM together |
| **History log size** | vDisk | Sized per disk from its own write rate |
| **Recovery point** | VM | A named moment across all the VM's disks, kept until you discard it |

**Turning it on:** open the VM's **Settings** tab, flip the CDP switch, enter a retention target in hours, and press **Apply**. The result is reported per disk. The same switch-and-Apply pattern also works per disk from the vDisk or LVM Settings tab.

**Sizing:** the first enable sizes the history log for you. After that, the log size is a field on the Settings tab, with a suggested size beside it when the achieved window falls short of your target. Growing the log keeps the existing journal. **⟳ Measure** takes a fresh reading; results based on less than 24 hours of history are marked provisional.

> [!CAUTION]
> Turning CDP on or off for a disk **with no mirror leg** briefly interrupts access to it. The console shows the disk's redundancy first and asks you to confirm.

### Recovery points

| Step | What it does |
|---|---|
| **Create** | A consistent rollback across every protected disk at one moment |
| **Inspect** | Boots as its own VM with every network interface disconnected |
| **Promote** | Splits it into a standalone VM in the background; the VM stays usable |
| **Discard** | Removes it in one action (the usual outcome after comparing) |

Recovery sets always cover **every** SANsymphony disk of the VM, so a recovered VM is internally consistent.

### Snapshots

- **Per disk:** list, create and delete from a vDisk's Snapshots tab. Deletion is refused while a snapshot is immutable or still served.
- **Whole VM:** the VM's Snapshots tab lists only **complete sets**, so every set restores a consistent machine.
- **Clone or promote** from any snapshot, the same way as from a recovery point.

### Recovery workflows

- **⇧ Promote:** makes a clone's disks standalone vDisks, releases the source's log, and can add a mirror leg in the same step.
- **↺ Reuse an existing set:** clone again from a recovery point or snapshot set that already exists.
- **⌦ Delete a clone:** keep or remove the SAN objects it came from.
- **Several VMs from one shared LUN:** on LVM storage, mark source VMs and clone them in one pass (**Clone VM(s)**), make them all independent together (**Promote LUN**), or remove one clone (**Remove VM**).

---

## 📈 Performance and multipath

**Performance history:** the stats strip shows live IOPS, throughput and latency for the selected vDisk or pool. Press <kbd>5</kbd> for graphs from **5 minutes to 1 year**. The `ssy-plugin-collect` service records every vDisk continuously, whether or not the console is open.

**Multipath:** every **Paths** tab shows live topology: which paths are active, the server and port each one leads to, and which mirror leg it serves. iSCSI and NVMe/TCP read the same way. Outside the console, use `ssy-multipath`:

```bash
ssy-multipath              # both transports
ssy-multipath iscsi        # iSCSI only
ssy-multipath nvme-tcp     # NVMe/TCP only
```

---

## 🩺 Logging and diagnostics

Everything the console does to the node and the SAN is recorded.

| Where | What it holds | How to read it |
|---|---|---|
| `/var/log/ssy-plugin/ssy-plugin.log` | Everything: commands, output, SAN calls, full errors. Root-only, rotated weekly. | <kbd>Ctrl</kbd>+<kbd>L</kbd> in the console, or `less` |
| Journal, tag `ssy-plugin` | Outcomes and failures, next to kernel and multipath messages | `journalctl -t ssy-plugin` |
| Proxmox Task History | Plugin output for disk create, resize and delete, prefixed `SANsymphonyPlugin[LEVEL]:` | **Node → Task History** or **System Log** |

**Handy commands:**

```bash
# Collect everything for support (passwords scrubbed, file is 0600)
python3 -m ssy_plugin.support          # → /var/tmp/ssy-plugin-support-<node>-<time>.tar.gz

# Turn on verbose plugin tracing (set to 0 to turn off)
pvesm set <storage> --ssy_debug 1

# Read the plugin's recent messages
journalctl -u pvedaemon -u pvestatd -u pvescheduler --since "10 min ago" | grep SANsymphonyPlugin
```

In the log viewer: <kbd>f</kbd> follows live, <kbd>w</kbd> shows warnings only, <kbd>m</kbd> loads more history and <kbd>z</kbd> exports. Each operation has an ID, so `grep 'op=resize-…'` returns its whole story. Read `manifest.txt` inside the support bundle before sending it on.

> [!NOTE]
> **Logs are per node,** so collect the bundle on the node where the console ran.
> **`ssy_debug` is cluster-wide** because `storage.cfg` is replicated, so remember to turn it off when you're done.

---

## 🔧 Troubleshooting

If the cause isn't obvious, start with a [support bundle](#-logging-and-diagnostics).

| Symptom | Likely cause | Fix |
|---|---|---|
| Disk or LVM creation fails because of stale iSCSI devices | Stale SCSI devices left on the node | `echo 1 > /sys/block/sdX/device/delete` (replace `sdX`) |
| Disk creation fails: *"check portal connectivity"* | An iSCSI or NVMe/TCP session to SANsymphony is down | Check `iscsiadm -m session` (iSCSI) or `nvme list-subsys` (NVMe/TCP), then retry |
| Proxmox is slow or the storage doesn't respond | A Proxmox service stopped or hung | `systemctl restart pvedaemon pveproxy pvestatd pvescheduler` |
| Nodes can't reach SANsymphony | Firewall or routing | Check connectivity from every node. The console's Home screen shows SAN reachability |
| iSCSI multipath devices missing or unbalanced | Bad `multipath.conf`, or `multipathd` not running | `multipath -ll`, then `systemctl restart multipathd` |
| Not all iSCSI paths are used | Sessions not refreshed after a network change | `iscsiadm -m session --rescan` |
| Not all NVMe/TCP paths are used | Connections not refreshed after a network change | `nvme list` and `nvme list-subsys /dev/nvme0` |
| Create, delete or resize fails with a permission error | The SANsymphony user lacks rights | Allow the user to create, modify, serve and delete virtual disks |
| Adding SSY storage reports offline ports | A front-end port or its server is offline | Usually nothing to do: the wizard skips and names them, and stops only if **no** portal is online |
| A disk vanished from a VM but is still on the SAN | The plugin couldn't match the volume to a vDisk on delete | Find it under **Orphan vDisks** in the console: attach, adopt into a new VM, or delete |
| A long operation stopped part-way | The SSH session dropped | The log records the last step attempted. Run long operations in `tmux` or `screen` |
| The plugin fails after a Proxmox VE upgrade | The plugin doesn't support the new release yet | Uninstall, then install the latest compatible version. *"Implementing an older storage API"* warnings are informational |
| Still stuck? | — | Check `/var/log/pve` and `journalctl -xe`, turn on `ssy_debug`, and collect a support bundle |

---

## 🧹 Removing storage and uninstalling

### Remove a storage class

1. **Remove the disks from VMs.** Detach and delete SANsymphony disks, or delete VMs you no longer need (that removes their disks too).
2. **Remove LVM and Directory storage built on it.** In the console, **Remove storage** runs a blocker report and asks whether to delete the backing vDisk too.
3. **Remove the SSY storage class**, from the console's **Remove storage** or with:
   ```bash
   pvesm remove <storage-name>
   ```
4. **Verify:**
   ```bash
   pvesm status | grep -i <storage-name>
   ```

> [!CAUTION]
> Don't unserve disks by hand in the DataCore Management Console. That bypasses the plugin and can leave stale configuration on the nodes.

### Uninstall the plugin

Package removal is **blocked while any `ssy:` storage class exists**, because those entries would fail to load without the plugin. Upgrades aren't affected.

```bash
dpkg -r ssy-plugin    # remove: keep configuration and logs
dpkg -P ssy-plugin    # purge: remove everything
```

**Purge** restores the original `/etc/multipath.conf` from the install-time backup and removes the plugin's configuration, performance history and logs.

---

## 📖 Reference

### Storage class options

| Option | Type | Required | Description |
|---|---|:-:|---|
| `SSYipAddress` | string | ✅ | SANsymphony management address(es), comma-separated |
| `SSYusername` | string | ✅ | SANsymphony REST API user |
| `SSYpassword` | string | on create | Stored Base64-encoded in `/etc/pve/priv/storage/<name>.pw`, root only |
| `portals` | string | ✅ | Front-end portal addresses, comma-separated |
| `targets` | string | ✅ | iSCSI IQNs (one per portal), or one NVMe/TCP NQN |
| `vdTemplateName` | string | ✅ | vDisk template; must match the protocol |
| `protocol` | string | | `iscsi` (default) or `nvme-tcp` |
| `nodes` | string | | Restrict to these nodes; omit for all nodes |
| `shared` | boolean | | `1` to share across nodes |
| `disable` | boolean | | `1` to switch the storage off without removing it |
| `ssy_debug` | boolean | | `1` traces every REST call to the journal, cluster-wide (default `0`) |

### Compatibility

| | |
|---|---|
| **Proxmox VE** | 8.x and 9.2, up to the latest release, **9.2.24** (tested in a multi-node cluster) |
| **Distribution** | `.deb` package only for this preview |
| **Transports** | iSCSI, NVMe/TCP |
| **Package depends on** | `python3 (>= 3.11)`, `jq`, `libpve-storage-perl`; `python3-systemd` recommended |

### Version history

| Version | Highlights |
|---|---|
| **2.0.0~preview** 🧪 | Logging and support bundle; log viewer; Directory storage in Manage; one-switch CDP; Promote and multi-VM recovery; offline-port and pre-registered-host handling; protocol-matched templates; smarter default pools |
| **1.2.0.5** | `ssy-plugin` opens the terminal console; the previous command line stays available as `ssy-plugin-old` |
| **1.2.0** | Terminal console included in the package; air-gapped install; performance collector |
| **1.1.0** | NVMe/TCP; LVM snapshot-as-volume-chain; per-target iSCSI tuning; leaner dependencies; faster storage changes; uninstall blocked while storage exists |
| **1.0.x** | Initial releases (archived in [`Previous Versions/`](Previous%20Versions)) |

---

## ❓ FAQ

<details>
<summary><b>Does the console replace the Proxmox storage plugin?</b></summary>

No. The storage plugin is the Proxmox integration that makes SANsymphony disks usable as VM storage. The console is the tool you use to set up and operate that storage. Both ship in the same package.
</details>

<details>
<summary><b>Do I need to configure anything for the console?</b></summary>

No. It reads the same `storage.cfg` entry and credentials the plugin uses.
</details>

<details>
<summary><b>Can I run the console from more than one node?</b></summary>

Yes, on any node with the package installed.
</details>

<details>
<summary><b>What happened to the interactive <code>ssy-plugin</code> command line?</b></summary>

Typing `ssy-plugin` now opens the terminal console. Scripts that still pass arguments to `ssy-plugin` are refused with a pointer to `ssy-plugin-old`, where the previous command line remains available.
</details>

<details>
<summary><b>Can I still create storage from a script?</b></summary>

Yes. Use `pvesm add ssy …` ([Using `pvesm add`](#using-pvesm-add)) or the non-interactive `ssy-plugin-old` CLI (`ssy-plugin-old -h` for its options).
</details>
