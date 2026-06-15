# DataCore Storage Plugin for Proxmox VE

A Proxmox VE storage plugin to integrate [DataCore SANsymphony™](https://www.datacore.com/products/sansymphony/) storage using **iSCSI** and **NVMe/TCP**, with multipath support and custom CLI management.

## 📚 Table of Contents

1. [Overview](#-overview)
2. [Prerequisites](#%EF%B8%8F-prerequisites)
3. [Installation](#-installation)
   - [Using Debian Package (.deb)](#-debian-package-deb)
   - [Proxmox Configuration Updates Performed After Plugin Installation](#%EF%B8%8F-proxmox-configuration-updates-performed-after-plugin-installation)
4. [Plugin Configuration](#%EF%B8%8F-plugin-configuration)
   - [Using ssy-plugin (Recommended)](#-recommended-using-ssy-plugin-command)
   - [Using pvesm add command](#-using-pvesm-add-command)
   - [Manual storage.cfg editing](#-manually-editing-storage-configuration-file-etcpvestoragecfg)
   - [Verify and Restart Proxmox VE Services](#-verify-and-restart-the-proxmox-ve-services)
   - [Removing a SANsymphony Storage Class](#-removing-a-sansymphony-storage-class)
5. [Uninstalling the Plugin](#-uninstalling-the-plugin)
6. [Troubleshooting](#-troubleshooting)

<br/>

References
- [SANsymphony Storage Plugin for Proxmox](https://docs.datacore.com/SANsymphony-Storage-Plugin-for-Proxmox-WebHelp/Proxmox-Plugin/WebHelp/Overview.htm) – Complete Proxmox plugin configuration details.
- [Proxmox Host Configuration Guide](https://docs.datacore.com/SSV-WebHelp/SSV-WebHelp/FAQ/Host-Configuration-Guide/Proxmox_Configuration_Guide.htm) – Host setup, network configuration instructions and more.

<br/>

# ✨ Overview

The plugin enables shared iSCSI and NVMe/TCP storage managed by DataCore SANsymphony to be used directly from Proxmox VE. You can manage storage via the Proxmox UI/CLI or using the built-in `ssy-plugin` command-line interface.

### Key capabilities include:
- **Advanced Storage Configuration**: Automates the setup of [Udev Rules](https://docs.datacore.com/SSV-WebHelp/SSV-WebHelp/FAQ/Host-Configuration-Guide/Proxmox_Configuration_Guide.htm#SCSI), [iSCSI Settings](https://docs.datacore.com/SSV-WebHelp/SSV-WebHelp/FAQ/Host-Configuration-Guide/Proxmox_Configuration_Guide.htm?Highlight=Proxmox#iSCSI) and [SCSI Multipath](https://docs.datacore.com/SSV-WebHelp/SSV-WebHelp/FAQ/Host-Configuration-Guide/Proxmox_Configuration_Guide.htm?Highlight=Proxmox#iSCSI2) for optimal performance.
- **Multi-Session iSCSI Management**: Handles multiple iSCSI sessions simultaneously for path redundancy.
- **NVMe/TCP Support**: Native NVMe/TCP multipath support via the Linux NVMe kernel subsystem.
- **Seamless Shared Storage**: Enables unified provisioning across the entire Proxmox cluster.
- **Dynamic Raw Device Mapping (RDM)**: Facilitates dynamic provisioning of Virtual Disks via RDM.
- **LVM Integration**: Full support for LVM volumes layered on top of DataCore SANsymphony Virtual Disks.
- `ssy-plugin` **CLI**: Includes an interactive wrapper for simplified management and troubleshooting.
- **Cluster High Availability (HA) & Migration**: As the plugin provides true Shared Storage, it fully supports Proxmox HA environments:
  - **Live Migration**: Seamlessly move running VMs between nodes with zero downtime.
  - **Automatic HA Failover**: Integrated with the PVE HA stack to restart VMs on healthy nodes if a host fails.
  - **Consistent State**: Shared LVM/iSCSI targets ensure all nodes have simultaneous, coordinated access to VM data.

>[!IMPORTANT]
> The SANsymphony Custom Storage Plugin 1.1.0 has been validated and tested with Proxmox VE versions **8** and **9.2.2**. If you upgrade or install Proxmox VE to a version higher than **9.2.2**, you may see the following warning message: "**PVE::Storage::Custom::SANsymphonyPlugin is implementing an older storage API; an upgrade is recommended**". This warning is informational and does not typically impact the functionality of the plugin.

<br/>

# ⚠️ Prerequisites

Before using the plugin, ensure the following:
- Ensure that a **Virtual Disk Template** is available or create one to use with the plugin.
- If installing the plugin via the **.deb** package, you must install the below packages.
  ```bash
  apt update
  apt install jq
  ```
  
<br/>

# 📦 Installation

>[!IMPORTANT]
> In a cluster setup, plugin installation needs to be performed on all the nodes.

## 🗂 Debian Package (.deb)

> Use this method if you cannot access the apt repo from the PVE node.

### 1. Download the package
```bash
wget https://github.com/DataCoreSoftware/Scripts/releases/download/SSY_PVE_Plugin/SANsymphony-plugin_1.1.0~preview_amd64.deb
```

### 2. Install it
```bash
dpkg -i SANsymphony-plugin_1.1.0~preview_amd64.deb
```

When installing using DPKG, existing iSCSI and Multipath configuration files are automatically backed up to `/var/backups/SANsymphony-Plugin-Backup`, allowing you to restore the previous configuration if needed.

After installation, you can verify the plugin is installed by running:
```bash
dpkg -l | grep ssy-plugin
```

## 🛠️ Proxmox Configuration Updates Performed After Plugin Installation

When the SANsymphony Custom Storage plugin is installed using any of the supported methods (APT repository or DPKG package), the installer updates several host-level configurations immediately after the installation completes.

These updates are required for proper operation of SANsymphony storage with Proxmox VE and are applied as soon as the plugin is installed, without requiring manual configuration. The following sections describe the configuration changes that are applied during installation.

### iSCSI Settings

On Proxmox VE nodes, the iSCSI service does not start automatically by default after a system reboot. During installation of the SANsymphony Custom Storage plugin, the installer updates the iSCSI configuration to ensure reliable connectivity to SANsymphony storage.

- These iSCSI settings are also configured per session:
  ```
  node.session.initial_login_retry_max = 0
  node.startup = manual
  node.leading_login = No
  node.session.timeo.replacement_timeout = 15
  ```
For more information, refer to the [iSCSI Settings](https://docs.datacore.com/SSV-WebHelp/SSV-WebHelp/FAQ/Host-Configuration-Guide/Proxmox_Configuration_Guide.htm#iSCSI) section in the Proxmox Configuration Guide.

### iSCSI Multipath Configuration

To ensure high availability and proper path management for SANsymphony virtual disks, the plugin installation updates the multipath configuration on the Proxmox VE node immediately after installation. Refer to [iSCSI Multipath](https://docs.datacore.com/SSV-WebHelp/SSV-WebHelp/FAQ/Host-Configuration-Guide/Proxmox_Configuration_Guide.htm#iSCSI2) for more information.

As part of the installation, the plugin creates or updates the multipath configuration file at the following location:
```
/etc/multipath.conf
```

If the `multipath.conf` file exists, a backup is created at the following location:
  ```
  /var/backups/SANsymphony-Plugin-Backup/multipath.conf
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

After applying the multipath configuration, the installer restarts the multipath service, so the changes take effect immediately:
```
multipath -r
```

### NVMe/TCP Multipath Configuration

The Linux NVMe kernel subsystem implements multipathing natively, allowing multiple paths to NVMeoF targets for redundancy and performance.

Check if multipathing is enabled:
```bash
cat /sys/module/nvme_core/parameters/multipath
```
Expected output: `y` (indicates multipath is enabled).

Check the ANA (Asymmetric Namespace Access) state of a namespace:
```bash
nvme list-subsys <nvme device path>
```
Replace `<nvme device path>` with the actual device path (e.g., `/dev/nvme0`). This will show ANA state and path information for multipathed namespaces.

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
The udev rules are reloaded automatically by the SANsymphony Custom Storage Plugin so the changes take effect immediately.
```
udevadm control --reload-rules
udevadm trigger --subsystem-match=block
```

### Post-Installation Proxmox Service Management

To ensure that the plugin configurations are correctly loaded and integrated into the Proxmox Virtual Environment (PVE), the following core services are signaled to reload or restart during the postinst phase. This process ensures zero or minimal downtime by attempting a reload before resorting to a restart.

- `pvedaemon.service` – Proxmox VE API daemon
- `pvestatd.service` – Proxmox VE status update daemon
- `pvescheduler.service` – Proxmox VE task scheduler
- `pve-ha-lrm.service` – Proxmox VE HA local resource manager

>[!NOTE]
>The restart commands are safe and include fallbacks to avoid blocking the installation if a service is not running.

<br/>

# ⚙️ Plugin Configuration

>[!NOTE]
> In a cluster setup, configuration only needs to be performed on one node.

After installing the plugin, configure Proxmox VE to use it. Since Proxmox VE does not currently support adding custom storage plugins via the GUI, use the `pvesm` command or the built-in `ssy-plugin` command.

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

| OPTION                   | Description                                                                                                                                                                        |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--LVMname`              | The name of the LVM storage class.                                                                                                                                                 |
| `--LVMsize`              | Size of the LVM storage class in GiB.                                                                                                                                              |
| `--SSYname`              | The name of the SANsymphony (SSY) storage class.                                                                                                                                   |
| `--SSYipAddress`         | One or more comma-separated SANsymphony management IP addresses. Ensure Proxmox nodes can reach these IPs.                                                                         |
| `--SSYusername`          | The username used to authenticate with the SANsymphony REST API.                                                                                                                   |
| `--SSYpassword`          | The password used to authenticate with the SANsymphony REST API. (Stored encoded in `/etc/pve/priv/storage/<Storage-Name>.pw`, accessible only to the root user.)                 |
| `--vdTemplateName`       | The name of the Virtual Disk Template to use for provisioning disks from SANsymphony. This template must already exist in SANsymphony.                                             |
| `--portals`              | One or more iSCSI FrontEnd portal IP addresses for SANsymphony, comma-separated. Use `all` to auto-discover FE iSCSI connections.                                                  |
| `--targets`              | One or more iSCSI FrontEnd Target IQNs, comma-separated.                                                                                                                           |
| `--nodes`                | A comma-separated list of Proxmox node names. Use `all` to include all PVE nodes in the cluster.                                                                                   |
| `--protocol`             | Transport protocol: `iscsi` or `nvme-tcp`.                                                                                                                                         |
| `--snapshotAsVolumeChain`| Enables snapshots as a volume chain for LVM storage (`1` = yes, `0` = no).                                                                                                        |
| `--shared`               | (`optional`) Set to `1` if the storage class should be shared across all nodes. If omitted, the storage class is treated as local.                                                 |
| `--disable`              | (`optional`) Set to `1` to temporarily disable the storage class without removing it.                                                                                              |
| `--default`              | (`optional`) Set to `1` to use default parameters where applicable.                                                                                                                |

**Examples:**
```bash
# Add SANsymphony storage with all portals, all nodes, shared
ssy-plugin ssy \
  --SSYname SSY-example \
  --SSYipAddress 10.121.0.129,10.121.0.137 \
  --SSYusername administrator \
  --SSYpassword YourPassword \
  --vdTemplateName MirrorVd2 \
  --portals all \
  --nodes all \
  --protocol nvme-tcp \
  --shared 1 \
  --disable 0
```
```bash
# Add SANsymphony storage with default parameters
ssy-plugin ssy \
  --SSYname SSY-example \
  --SSYipAddress 10.121.0.129,10.121.0.137 \
  --SSYusername administrator \
  --SSYpassword YourPassword \
  --vdTemplateName MirrorVd \
  --protocol iscsi \
  --default 1
```
```bash
# Add LVM storage class
ssy-plugin lvm \
  --SSYname SSY-example \
  --LVMsize 50 \
  --LVMname SSY-LVM-example \
  --snapshotAsVolumeChain 1 \
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
pvesm add ssy <SSY-Name> \
    --SSYipAddress <IP1>,<IP2> \
    --SSYusername <Username> \
    --SSYpassword YourPassword \
    --portals <Portal1>,<Portal2> \
    --targets <TargetIQN1>,<TargetIQN2> \
    --vdTemplateName <TemplateName> \
    --nodes <Node1>,<Node2> \
    --protocol <iscsi/nvme-tcp> \
    --shared 1 \
    --disable 0
```

| Parameter        | Type    | Description                                                                                                                                                                |
| ---------------- | ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `SSYipAddress`   | string  | SANsymphony server management IP address (single or comma-separated list).                                                                                                 |
| `SSYusername`    | string  | The username used to authenticate with the SANsymphony REST API.                                                                                                           |
| `SSYpassword`    | string  | The password used to authenticate with the SANsymphony REST API. (Stored encoded in `/etc/pve/priv/storage/<Storage-Name>.pw`, accessible only to the root user.)         |
| `portals`        | string  | One or more iSCSI FE portal IP addresses, comma-separated.                                                                                                                 |
| `targets`        | string  | One or more iSCSI target IQNs, comma-separated.                                                                                                                            |
| `vdTemplateName` | string  | The name of the Virtual Disk Template to use for provisioning disks from DataCore. This template must already exist in SANsymphony.                                        |
| `nodes`          | string  | (`optional`) A comma-separated list of Proxmox node names. If omitted, the storage is available on all nodes.                                                              |
| `protocol`       | string  | Transport protocol: `iscsi` or `nvme-tcp`.                                                                                                                                 |
| `shared`         | boolean | (`optional`) Set to `1` to mark the storage as shared across all nodes. If omitted, the storage is treated as local.                                                       |
| `disable`        | boolean | (`optional`) Set to `1` to temporarily disable the storage without deleting it.                                                                                            |

If the plugin is configured using the `pvesm add ssy` command, you must verify and restart the Proxmox VE services. See [Verify and Restart the Proxmox VE Services](#-verify-and-restart-the-proxmox-ve-services) for details.

## 🧭 Manually editing storage configuration file `/etc/pve/storage.cfg`

```bash
nano /etc/pve/storage.cfg
```

Add the SANsymphony storage configuration following the Proxmox configuration file structure:

```
ssy: <SSY Storage Class Name>
   SSYipAddress <SSY Management IP Address list>
   SSYusername <SSY Username>
   portals <SSY FrontEnd iSCSI portals list>
   targets <SSY FrontEnd iSCSI Target IQN list>
   vdTemplateName <SSY Virtual Disk Template Name>
   nodes <Proxmox Node Names list>
   protocol <iscsi/nvme-tcp>
   shared 1
   disable 0
```

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

>[!NOTE]
>The SSYpassword is stored in the location `/etc/pve/priv/storage/<Storage-Name>.pw`.

If the plugin is configured by manually editing the storage configuration file, you must verify and restart the Proxmox VE services. See [Verify and Restart the Proxmox VE Services](#-verify-and-restart-the-proxmox-ve-services) for details.

## 🔄 Verify and Restart the Proxmox VE Services

After adding and configuring the SANsymphony Storage Plugin using the `pvesm add ssy` command or by editing the storage configuration file manually, restart the Proxmox VE services to ensure changes are applied:

```bash
systemctl restart pvedaemon pvestatd pvescheduler
```

Once the services have restarted, verify that the plugin has been integrated successfully:

```bash
pvesm status
```

This command displays the status of all storage resources in your Proxmox environment. If configured correctly, the SANsymphony storage class will appear with its storage ID, type, and status.

## 🗑 Removing a SANsymphony Storage Class

Follow this process to safely remove a SANsymphony Storage Class from Proxmox VE while ensuring all associated virtual disks and LVM volumes are properly cleaned up.

1. **Detach/remove SANsymphony disks from Virtual Machines** — Detach and delete any SANsymphony-provisioned disks from virtual machines, or delete the virtual machines if they are no longer needed (this also removes referenced/unreferenced SANsymphony disks).

2. **Remove any LVM storage** created on SANsymphony disks before proceeding.

3. **Run the interactive removal command** to select and remove virtual disks along with their underlying SANsymphony storage:
   ```bash
   ssy-plugin remove
   ```

4. **Remove the SANsymphony storage class from Proxmox VE** once all disks are removed:
   ```bash
   # Using pvesm:
   pvesm remove <storage_class_name>

   # Or using the plugin (interactive):
   ssy-plugin remove
   ```

5. **Verify removal:**
   ```bash
   pvesm status | grep -i <storage_class_name>
   ```

<br/>

# 🗑 Uninstalling the Plugin

If you no longer need the SANsymphony Storage Plugin for Proxmox, you can uninstall it. Before uninstalling, make sure to remove all SANsymphony virtual disks attached to the respective Proxmox nodes.

If installed via APT repository:
```bash
apt remove ssy-plugin
```

If installed via .deb package:
```bash
dpkg -r ssy-plugin
```

To verify removal (if the command returns "command not found," the plugin has been removed successfully):
```bash
ssy-plugin --version
```

<br/>

# 🛠 Troubleshooting

If you encounter issues while using the plugin, consider the following steps:

- **Check Service Status:** Ensure that the Proxmox VE services are running correctly. You can restart the services if necessary:
  ```bash
  systemctl restart pvedaemon pvestatd pvescheduler
  ```
- **Verify Network Connectivity:** Ensure that the Proxmox VE nodes can reach SANsymphony over the network. Check for firewall rules or network issues that might be blocking communication.
- **Review Logs:** Check the Proxmox VE logs for any error messages related to storage or the plugin. Logs are typically found in `/var/log/pve`.
  Useful commands:
  ```bash
  journalctl -xe        # displays Proxmox logs
  multipath -ll -v3     # diagnose issues with the multipath service
  iscsiadm -m node      # list what iSCSI nodes are mounted
  ```
- **Multipath Configuration:** Verify that your `multipath.conf` is correctly configured and that multipath devices are recognized. Use `multipath -ll` to list the current multipath devices.
- **SANsymphony User Permissions:** Ensure that the SANsymphony user has the necessary permissions to create and manage storage.
- **Plugin Updates:** Ensure you are using the latest version of the plugin.
