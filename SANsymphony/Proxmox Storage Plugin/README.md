# DataCore Storage Plugin for Proxmox VE

A Proxmox VE storage plugin to integrate [DataCore SANsymphony™](https://www.datacore.com/products/sansymphony/) storage using **iSCSI** or **NVMe/TCP**, with multipath support and custom CLI management.

## 📚 Table of Contents

1. [Overview](#-overview)
2. [What's New in v1.1.0](#-whats-new-in-v110)
3. [Prerequisites](#%EF%B8%8F-prerequisites)
4. [Installation](#-installation)
   - [Using APT Repository (Recommended)](#-recommended-using-apt-repository)
   - [Using Debian Package (.deb)](#-alternative-debian-package-deb)
   - [Proxmox Configuration Updates Performed After Plugin Installation](#%EF%B8%8F-proxmox-configuration-updates-performed-after-plugin-installation)
   - [Uninstalling the Plugin](#-uninstalling-the-plugin)
5. [Plugin Configuration](#%EF%B8%8F-plugin-configuration)
   - [Using ssy-plugin (Recommended)](#-recommended-using-ssy-plugin-command)
   - [Using pvesm add command](#-using-pvesm-add-command)
   - [Manual storage.cfg editing](#-manually-editing-storage-configuration-file-etcpvestoragecfg)
6. [Troubleshooting](#-troubleshooting)

<br/>

References
- [SANsymphony Storage Plugin for Proxmox](https://docs.datacore.com/SANsymphony-Storage-Plugin-for-Proxmox-WebHelp/Proxmox-Plugin/WebHelp/Overview.htm) – Complete Proxmox plugin configuration details.
- [Proxmox Host Configuration Guide](https://docs.datacore.com/SSV-WebHelp/SSV-WebHelp/FAQ/Host-Configuration-Guide/Proxmox_Configuration_Guide.htm) – Host setup, network configuration instructions and more.

<br/>

# ✨ Overview

The plugin enables shared **iSCSI** or **NVMe/TCP** storage managed by DataCore SANsymphony to be used directly from Proxmox VE. You can manage storage via the Proxmox UI/CLI or using the built-in `ssy-plugin` command-line interface.

### Key capabilities include:
- **Advanced Storage Configuration**: Automates the setup of [Udev Rules](https://docs.datacore.com/SSV-WebHelp/SSV-WebHelp/FAQ/Host-Configuration-Guide/Proxmox_Configuration_Guide.htm#SCSI), [iSCSI Settings](https://docs.datacore.com/SSV-WebHelp/SSV-WebHelp/FAQ/Host-Configuration-Guide/Proxmox_Configuration_Guide.htm?Highlight=Proxmox#iSCSI) and [SCSI Multipath](https://docs.datacore.com/SSV-WebHelp/SSV-WebHelp/FAQ/Host-Configuration-Guide/Proxmox_Configuration_Guide.htm?Highlight=Proxmox#iSCSI2) for optimal performance.
- **Multi-Path Storage Management**: Handles multiple iSCSI sessions or NVMe/TCP connections simultaneously for path redundancy.
- **Seamless Shared Storage**: Enables unified provisioning across the entire Proxmox cluster.
- **Dynamic Raw Device Mapping (RDM)**: Facilitates dynamic provisioning of Virtual Disks via RDM.
- **LVM Integration**: Full support for LVM volumes layered on top of DataCore SANsymphony Virtual Disks.
- `ssy-plugin` **CLI**: Includes an interactive wrapper for simplified management and troubleshooting.
- **Cluster High Availability (HA) & Migration**: As the plugin provides true Shared Storage, it fully supports Proxmox HA environments:
  - **Live Migration**: Seamlessly move running VMs between nodes with zero downtime.
  - **Automatic HA Failover**: Integrated with the PVE HA stack to restart VMs on healthy nodes if a host fails.
  - **Consistent State**: Shared LVM/storage targets ensure all nodes have simultaneous, coordinated access to VM data.

>[!IMPORTANT]
> The SANsymphony Custom Storage Plugin **1.1.0** has been validated and tested with Proxmox VE versions **8** and **9.2**. If you upgrade or install Proxmox VE to a version higher than **9.2**, you may see the following warning message: "**PVE::Storage::Custom::SANsymphonyPlugin is implementing an older storage API; an upgrade is recommended**". This warning is informational and does not typically impact the functionality of the plugin.

<br/>

# 🆕 What's New in v1.1.0

### New features
- **NVMe/TCP support**: A new `protocol` parameter (`iscsi` | `nvme-tcp`) lets a storage class use NVMe/TCP as the transport. `iscsi` remains the default, so existing configurations are unchanged. See [Plugin Configuration](#%EF%B8%8F-plugin-configuration).
- **NVMe/TCP multipath view**: `ssy-plugin multipath` (via `ssy-multipath`) now renders NVMe/TCP topology and path status in addition to iSCSI.
- **LVM snapshot-as-volume-chain**: The `ssy-plugin` LVM action accepts a new `snapshotAsVolumeChain` (`0` | `1`) parameter to enable Proxmox snapshot-as-volume-chain on LVM storage layered over SANsymphony.

### Enhancements
- **Leaner dependencies**: `open-iscsi` and `multipath-tools` are no longer forced dependencies. Install only what your protocol needs — `open-iscsi` + `multipath-tools` for iSCSI, or `nvme-cli` for NVMe/TCP. See [Prerequisites](#%EF%B8%8F-prerequisites).
- **Per-target iSCSI tuning**: The recommended iSCSI settings are now applied per target at login time (via `iscsiadm`) instead of editing the global `/etc/iscsi/iscsid.conf`. The `ssy-configure-iscsid` helper has been removed.
- **Smarter udev reload**: The `99-datacore.rules` udev rule is reloaded on install only when its contents actually change (tracked via a SHA-256 hash), avoiding unnecessary reloads.
- **Faster storage operations**: Adding a storage class no longer restarts the Proxmox services (`pvedaemon`, `pveproxy`, `pvestatd`, `pvescheduler`) across every node — it now only reloads multipath, significantly reducing execution time.
- **Safer uninstall**: Package removal is now blocked while `ssy:` storage classes are still configured, and purging the package restores the original `/etc/multipath.conf` that was backed up at install time. See [Uninstalling the Plugin](#-uninstalling-the-plugin).

<br/>

# ⚠️ Prerequisites

Before using the plugin, ensure the following:
- Ensure that a **Virtual Disk Template** is available or create one to use with the plugin.
- Install the packages required for the storage protocol you intend to use. These are no longer installed automatically by the plugin package, so install them for whichever protocol(s) the node uses:
  - **iSCSI**: `open-iscsi` and `multipath-tools`
    ```bash
    apt install open-iscsi multipath-tools
    ```
  - **NVMe/TCP**: `nvme-cli`
    ```bash
    apt install nvme-cli
    modprobe nvme-tcp
    ```
- If installing the plugin via the **.deb** package, also install `jq` (it is resolved automatically when using the APT repository):
  ```bash
  apt install jq
  ```

<br/>

# 📦 Installation

>[!IMPORTANT]
> In a cluster setup, plugin installation needs to be performed on all the nodes.

## ✅ Recommended: Using APT Repository

>This method ensures automatic updates and integrates the plugin into the Proxmox package management system, making future updates and management much easier.

### 1. Import GPG Key
```bash
wget -P /usr/share/keyrings https://github.com/DataCoreSoftware/Scripts/releases/download/SSY_PVE_Plugin/ssy-pgp-key.public
```

### 2. Add Apt Source
```bash
echo "deb [signed-by=/usr/share/keyrings/ssy-pgp-key.public] https://datacoresoftware.github.io/Scripts/ssy-apt-repo stable main" | tee /etc/apt/sources.list.d/ssy.list
```

### 3. Update & Install Plugin
```bash
apt update
apt install ssy-plugin
```

## 🗂 Alternative: Debian Package (.deb)

> Use this method if you cannot access the apt repo from the PVE node.

### 1. Download the package
```bash
wget https://github.com/DataCoreSoftware/Scripts/releases/download/SSY_PVE_Plugin/SANsymphony-plugin_1.1.0_amd64.deb
```

### 2. Install it
```bash
dpkg -i SANsymphony-plugin_1.1.0_amd64.deb
```

## 🛠️ Proxmox Configuration Updates Performed After Plugin Installation

When the SANsymphony Custom Storage plugin is installed using any of the supported methods (APT repository or DPKG package), the installer updates several host-level configurations immediately after the installation completes.

These updates are required for proper operation of SANsymphony storage with Proxmox VE and are applied as soon as the plugin is installed, without requiring manual configuration. The following sections describe the configuration changes that are applied during installation.

### iSCSI Settings

To ensure reliable connectivity to SANsymphony storage, the plugin applies the recommended iSCSI settings **per target when it logs in** (using `iscsiadm --mode node --targetname <target> --op update`), instead of editing the global `/etc/iscsi/iscsid.conf` file. The following settings are applied for each target:

```
node.startup = manual
node.leading_login = No
node.session.timeo.replacement_timeout = 15
node.session.initial_login_retry_max = 0
```

These settings are applied automatically each time a target is activated and do not require any manual configuration.

For more information, refer to the [iSCSI Settings](https://docs.datacore.com/SSV-WebHelp/SSV-WebHelp/FAQ/Host-Configuration-Guide/Proxmox_Configuration_Guide.htm#iSCSI) section in the Proxmox Configuration Guide. 

### iSCSI Multipath Configuration

To ensure high availability and proper path management for SANsymphony virtual disks, the plugin installation updates the multipath configuration on the Proxmox VE node immediately after installation. Refer to [iSCSI Multipath](https://docs.datacore.com/SSV-WebHelp/SSV-WebHelp/FAQ/Host-Configuration-Guide/Proxmox_Configuration_Guide.htm#iSCSI2) for more information.

As part of the installation, the plugin creates or updates the multipath configuration file at the following location:
```
/etc/multipath.conf
```

If the `multipath.conf` file exists, a backup is created at the following location:
  ```
  /var/backups/SANsymphony-Plugin-Backup/multipath.conf.<YYYYMMDD>
  ```

The configuration applied includes DataCore-recommended defaults and device-specific settings equivalent to the following:
```
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

### Multipath Service Restart

After applying the multipath configuration, the installer reloads the multipath service, so the changes take effect immediately:
```
multipath -r
```

### Custom udev Rule for DataCore Disks

During installation, the plugin adds a custom udev rule to ensure appropriate SCSI timeout handling for SANsymphony virtual disks.

The following file is created or updated as part of the installation:
```
/etc/udev/rules.d/99-datacore.rules
```
With the following rule:
```
SUBSYSTEM=="block", ACTION=="add", ATTRS{vendor}=="DataCore", ATTRS{model}=="Virtual Disk    ", RUN+="/bin/sh -c 'echo 80 > /sys/block/%k/device/timeout' "
```
The udev rules are reloaded automatically **only if the rule file has changed** since the last installation (the installer tracks the rule's SHA-256 hash at `/var/lib/ssy-plugin/99-datacore.rules.sha256`). If the rule is unchanged, the reload is skipped to avoid unnecessary delays. When a reload is triggered, the following commands are run:
```
udevadm control --reload-rules
udevadm trigger --subsystem-match=block
```

### Post-Installation Proxmox Service Management

To ensure that the plugin configurations are correctly loaded and integrated into the Proxmox Virtual Environment (PVE), the following core services are signaled to reload or restart during the postinst phase. This process ensures zero or minimal downtime by attempting a reload before resorting to a restart.

- `pvedaemon.service` – Proxmox VE API daemon
- `pveproxy.service` – Proxmox VE web interface proxy
- `pvestatd.service` – Proxmox VE status update daemon
- `pvescheduler.service` – Proxmox VE task scheduler
- `pve-ha-lrm.service` – Proxmox VE HA local resource manager

>[!NOTE]
>The restart commands are safe and include fallbacks to avoid blocking the installation if a service is not running.

## 🧹 Uninstalling the Plugin

>[!IMPORTANT]
> Package removal is **blocked while any `ssy:` storage class is still configured** in `/etc/pve/storage.cfg`, since those entries would fail to load once the plugin is gone. Remove the storage classes first, then remove the package:
> ```bash
> pvesm remove <SSY Storage Class Name>
> apt remove ssy-plugin        # or: dpkg -r ssy-plugin
> ```
> Upgrades are not affected — existing storage classes may remain in place during an upgrade.

Purging the package (`apt purge ssy-plugin`) additionally restores the original `/etc/multipath.conf` that was backed up during installation (from `/var/backups/SANsymphony-Plugin-Backup/`) and removes the plugin's tracking files.

<br/>

# ⚙️ Plugin Configuration

>[!NOTE]
> In a cluster setup, configuration only needs to be performed on one node.

>[!NOTE]
> **Storage protocol:** The `protocol` parameter selects the transport, either `iscsi` or `nvme-tcp`. It is **optional** and defaults to `iscsi`. The `portals` and `targets` parameters apply to the chosen protocol — IQNs for iSCSI, NQN for NVMe/TCP.
> - **iSCSI:** the number of `portals` must equal the number of `targets` (each portal is paired with one target).
> - **NVMe/TCP:** multiple `portals` are allowed, but only a **single** NQN `target` per Server Group is supported. Target discovery uses port **8009**.
> - The **Virtual Disk Template must match the protocol**: use an NVMe-enabled template for `nvme-tcp` and a non-NVMe template for `iscsi`. Disk allocation fails if the template's transport does not match the storage class.

After installing the plugin, configure Proxmox VE to use it. Since Proxmox VE does not currently support adding custom storage plugins via the GUI, use the `pvesm` command or the built-in `ssy-plugin` command:

## 🧭 Recommended: Using `ssy-plugin` command

The `ssy-plugin` tool can be used in two modes:

### 1. Interactive Mode

Launches a prompt-based interface for guided use.

```bash
ssy-plugin
```

Sample menu:
```
Please select the Operation type:
1. Add SANsymphony Storage class (SSY)
2. Add LVM Storage class (LVM)
3. Remove existing Storage class
4. Display SSY multipath status
```

### 2. Non-Interactive Mode (Direct Command Execution)

You can also run individual commands directly from the shell, passing all parameters via flags.

View help:
```bash
ssy-plugin -h
```

**Syntax:**
```bash
ssy-plugin [ACTION] [OPTIONS]
```

| ACTION      | Description                                                                    |
| ----------- | ------------------------------------------------------------------------------ |
| `ssy`       | Add a new SANsymphony storage class.                                           |
| `lvm`       | Add a new LVM (Logical Volume Manager) storage class.                          |
| `remove`    | Remove an existing storage class.                                              |
| `multipath` | Display the current SANsymphony multipath connection status for iSCSI targets. |

| OPTION         | Description                                                                                                                                                                        |
| -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| LVMname        | The name of the LVM storage class.                                                                                                                                                 |
| LVMsize        | Size of the LVM storage class in GiB.                                                                                                                                              |
| SSYname        | The name of the SANsymphony (SSY) storage class.                                                                                                                                   |
| SSYipAddress   | One or more comma-separated SANsymphony management IP addresses. Ensure Proxmox nodes can reach these IPs.                                                                         |
| SSYusername    | The username used to authenticate with the SANsymphony REST API.                                                                                                                   |
| SSYpassword    | The password used to authenticate with the SANsymphony REST API.                                                                                                                   |
| vdTemplateName | The name of the Virtual Disk Template to use for provisioning disks from SANsymphony. This template must already exist in SANsymphony.                                             |
| portals        | One or more FrontEnd portal IP addresses for SANsymphony (iSCSI or NVMe/TCP), comma-separated. Use `all` to auto-discover connections.                                              |
| nodes          | A comma-separated list of Proxmox node names. Use `all` to include all PVE nodes in the cluster.                                                                                   |
| shared         | (`optional`) Set to `1` if the storage class should be shared across all nodes. If omitted, the storage class is treated as local. Defaults to `1`.                                |
| disable        | (`optional`) Set to `1` to temporarily disable the storage class without removing it.                                                                                              |
| protocol       | (`optional`) Storage protocol: `iscsi` or `nvme-tcp`. Defaults to `iscsi`.                                                                                                          |
| snapshotAsVolumeChain | (`optional`, **LVM only**) Set to `1` to enable PVE snapshot-as-volume-chain on the LVM storage class. Defaults to `1`.                                                   |
| default        | (`optional`) Set to `1` to use default parameters where applicable.                                                                                                                |

**Examples:**
```bash
ssy-plugin ssy \
  --SSYname SSY-example \
  --SSYipAddress 10.15.0.1,10.15.0.2 \
  --SSYusername administrator \
  --SSYpassword Password \
  --vdTemplateName Mirrored-VD \
  --protocol nvme-tcp \
  --portals all \
  --nodes all \
  --shared 1 \
  --disable 0
```
```bash
ssy-plugin ssy \
  --SSYname SSY-example \
  --SSYipAddress 10.15.0.1,10.15.0.2 \
  --SSYusername administrator \
  --SSYpassword Password  \
  --vdTemplateName Mirror-VD \
  --default 1
```  
```bash
ssy-plugin lvm \
  --LVMname SSY-LVM-example \
  --LVMsize 1024 \
  --SSYname SSY-example \
  --default 1
```
```bash
ssy-plugin multipath
```
```bash
ssy-plugin remove
```

## 🧭 Using `pvesm add` command

You can also directly use the `pvesm add` command:

```bash
pvesm add ssy <SSY Storage Class Name> \
    --SSYipAddress <SSY Management IP Address list> \
    --SSYusername <SSY Username> \
    --SSYpassword <SSY Password> \
    --portals <SSY FrontEnd portal IP list> \
    --targets <SSY FrontEnd target IQN/NQN list> \
    --vdTemplateName <SSY Virtual Disk Template Name> \
    --nodes <Proxmox Node Names list> \
    --protocol iscsi \
    --shared 1 \
    --disable 0
```
> `--protocol` is optional and defaults to `iscsi`; use `--protocol nvme-tcp` for NVMe/TCP.

## 🧭 Manually editing storage configuration file `/etc/pve/storage.cfg`

```bash
ssy: <SSY Storage Class Name>
   SSYipAddress <SSY Management IP Address list>
   SSYusername <SSY Username>
   portals <SSY FrontEnd portal IP list>
   targets <SSY FrontEnd target IQN/NQN list>
   vdTemplateName <SSY Virtual Disk Template Name>
   nodes <Proxmox Node Names list>
   protocol iscsi
   shared 1
   disable 0
```

| Parameter      | Description                                                                                                                                                                |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| storage_id     | The storage identifier (name under which it will appear in the Proxmox Storage list).                                                                                      |
| SSYipAddress   | One or more comma-separated SANsymphony management IP addresses. Ensure Proxmox nodes can reach these IPs.                                                                 |
| SSYusername    | The username used to authenticate with the SANsymphony REST API.                                                                                                           |
| SSYpassword    | The password used to authenticate with the SANsymphony REST API. It is saved in a file readable only by the root user(`/etc/pve/priv/storage/<Storage-Name>.pw`).          |
| portals        | One or more FE portal IP addresses (iSCSI or NVMe/TCP), comma-separated. These are used for initiator connections.                                                         |
| targets        | One or more target identifiers, comma-separated: IQNs for iSCSI, one NQN for NVMe/TCP.                                                                                       |
| vdTemplateName | The name of the Virtual Disk Template to use for provisioning disks from DataCore. This template must already exist in SANsymphony.                                        |
| nodes          | (`optional`) A comma-separated list of Proxmox node names. Use this parameter to restrict the plugin to specific nodes. If omitted, the storage is available on all nodes. |
| protocol       | (`optional`) Storage protocol: `iscsi` or `nvme-tcp`. Defaults to `iscsi`.                                                                                                |
| shared         | (`optional`) Set to `1` to mark the storage as shared across all nodes. If omitted, the storage is treated as local.                                                       |
| disable        | (`optional`) Set to `1` to temporarily disable the storage without deleting it.                                                                                            |

**Example:**
```
ssy: Storage-Name
   SSYipAddress 10.15.1.19,10.15.1.18
   SSYusername administrator
   portals 10.15.1.17,10.151.1.16
   targets iqn.2000-08.com.datacore:ssy1-1,iqn.2000-08.com.datacore:ssy2-1
   vdTemplateName SSY-VDT
   nodes pve1,pve2
   protocol iscsi
   shared 1
   disable 0
```

**Example (NVMe/TCP):**
```
ssy: Storage-Name-NVMe
   SSYipAddress 10.15.1.19,10.15.1.18
   SSYusername administrator
   portals 10.15.1.17
   targets nqn.2000-08.com.datacore:ssy1
   vdTemplateName SSY-VDT-NVMe
   protocol nvme-tcp
   nodes pve1,pve2
   shared 1
```

>[!NOTE]
>The SSYpassword is stored **Base64-encoded** in `/etc/pve/priv/storage/<Storage-Name>.pw`, readable only by root. During upgrades, if a plaintext SSY password is found in `storage.cfg`, the installer automatically migrates it to the appropriate file and removes the plaintext entry from `storage.cfg`.

<br/>

# 🛠 Troubleshooting

If you encounter issues while using the plugin, consider the following steps:

- **Check Service Status:** Ensure that the Proxmox VE services are running correctly. You can restart the services if necessary:
  ```bash
  systemctl restart pvedaemon pveproxy pvestatd pvescheduler
  ```
- **Verify Network Connectivity:** Ensure that the Proxmox VE nodes can reach SANsymphony over the network. Check for firewall rules or network issues that might be blocking communication.
- **Review Logs:** Check the Proxmox VE logs for any error messages related to storage or the plugin. Logs are typically found in `/var/log/pve`.
  Useful commands:
  ```bash
  journalctl -xe        # displays Proxmox logs
  multipath -ll -v3     # diagnose issues with the multipath service (iSCSI)
  iscsiadm -m node      # list what iSCSI nodes are mounted (iSCSI)
  nvme list             # list connected NVMe devices (NVMe/TCP)
  nvme list-subsys      # show NVMe subsystem and session info (NVMe/TCP)
  ```
- **Multipath Configuration:** Verify that your `multipath.conf` is correctly configured and that multipath devices are recognized. Use `multipath -ll` to list the current multipath devices.
- **SANsymphony User Permissions:** Ensure that the SANsymphony user has the necessary permissions to create and manage storage.
- **Plugin Updates:** Ensure you are using the latest version of the plugin.
