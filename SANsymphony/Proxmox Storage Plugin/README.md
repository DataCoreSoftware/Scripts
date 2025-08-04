# DataCore Storage Plugin for Proxmox VE

A Proxmox VE storage plugin to integrate [DataCore SANsymphony™](https://www.datacore.com/products/sansymphony/) storage using iSCSI, with native multipath support and custom CLI management.

---

## 📚 Table of Contents

1. [Overview](#-overview)
3. [Prerequisites](#%EF%B8%8F-prerequisites)
4. [Installation](#-installation)
   - [Using APT Repository (Recommended)](#-recommended-using-apt-repository)
   - [Using Debian Package (.deb)](#-alternative-debian-package-deb)
5. [Configuration](#%EF%B8%8F-configuration)
   - [Using ssy-plugin (Recommended)](#-recommended-using-ssy-plugin-command)
   - [Using pvesm add command](#-using-pvesm-add-command)
   - [Manual storage.cfg editing](#-manually-editing-storage-configuration-file-etcpvestoragecfg)
7. [Troubleshooting](#-troubleshooting)

---

<br/>

# ✨ Overview

The plugin enables shared iSCSI storage managed by DataCore SANsymphony to be used directly from Proxmox VE. You can manage storage via the Proxmox UI/CLI or using the built-in `ssy-plugin` command-line interface.

Key capabilities include:
- Management of multiple iSCSI sessions with multipath support
- Seamless provisioning of shared Virtual Disks (VDs)
- LVM support on top of SANsymphony VDs
- Compatibility with both Proxmox UI and CLI
- An interactive wrapper CLI tool (`ssy-plugin`) for simplified management

<br/>

# ⚠️ Prerequisites

- Ensure the `VD Template` is already created in SANsymphony.

If installing via `.deb`:
- Install `jq` and `multipath-tools` manually.
- Enable `multipath` and configure `udev rules` manually (see [Host Configuration Guide](https://dcsw.atlassian.net/wiki/spaces/ProxmoxDoc/pages/8528330757/Host+Configuration+Guide+PVE)).

<br/>

# 📦 Installation

## ✅ Recommended: Using APT Repository

Run these commands **on each Proxmox node**:

### 1. Import GPG Key
```bash
wget -P /usr/share/keyrings https://cjsstorage.blob.core.windows.net/datacore/ssy-pgp-key.public
```

### 2. Add Apt Source
```bash
echo "deb [signed-by=/usr/share/keyrings/ssy-pgp-key.public] \
https://cjsstorage.blob.core.windows.net/datacore/ssy-apt-repo stable main" \
| tee /etc/apt/sources.list.d/ssy.list
```

### 3. Update & Install Plugin
```bash
apt update
apt install ssy-plugin
```

## 🗂 Alternative: Debian Package (.deb)

Use this method if you cannot access the apt repo from the PVE node.

### 1. Download the package
```bash
wget https://cjsstorage.blob.core.windows.net/datacore/SANsymphony-plugin_1.0.0_amd64.deb
```

### 2. Install it
```bash
dpkg -i SANsymphony-plugin_1.0.0_amd64.deb
```

<br/>

# ⚙️ Configuration

> [!TIP]
> In a cluster setup, configuration only needs to be performed on one node.

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
| portals        | One or more iSCSI FrontEnd portal IP addresses for SANsymphony, comma-separated. Use `all` to auto-discover FE iSCSI connections.                                                  |
| nodes          | A comma-separated list of Proxmox node names. Use `all` to include all PVE nodes in the cluster.                                                                                   |
| shared         | (`optional`) Set to `1` if the storage class should be shared across all nodes. If omitted, the storage class is treated as local.                                                 |
| disable        | (`optional`) Set to `1` to temporarily disable the storage class without removing it.                                                                                              |
| default        | (`optional`) Set to `1` to use default parameters where applicable.                                                                                                                |

**Examples:**
```bash
ssy-plugin ssy \
  --SSYname SSY-example \
  --SSYipAddress 10.15.0.1,10.15.0.2 \
  --SSYusername administrator \
  --SSYpassword Password \
  --vdTemplateName Mirrored-VD \
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
    --portals <SSY FrontEnd iSCSI portals list> \
    --targets <SSY FrontEnd iSCSI Target IQN list> \
    --vdTemplateName <SSY Virtual Disk Template Name> \
    --nodes <Proxmox Node Names list> \
    --shared 1 \
    --disable 0
```

## 🧭 Manually editing storage configuration file `/etc/pve/storage.cfg`

```bash
ssy: <SSY Storage Class Name>
   DCipAddress <SSY Management IP Address list>
   DCusername <SSY Username>
   DCpassword <SSY Password>
   portals <SSY FrontEnd iSCSI portals list>
   targets <SSY FrontEnd iSCSI Target IQN list>
   vdTemplateName <SSY Virtual Disk Template Name>
   nodes <Proxmox Node Names list>
   shared 1
   disable 0
```

| Parameter      | Description                                                                                                                                                                |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| storage_id     | The storage identifier (name under which it will appear in the Proxmox Storage list).                                                                                      |
| SSYipAddress   | One or more comma-separated SANsymphony management IP addresses. Ensure Proxmox nodes can reach these IPs.                                                                 |
| SSYusername    | The username used to authenticate with the SANsymphony REST API.                                                                                                           |
| SSYpassword    | The password used to authenticate with the SANsymphony REST API.                                                                                                           |
| portals        | One or more iSCSI FE portal IP addresses, comma-separated. These are used for initiator connections.                                                                       |
| targets        | One or more iSCSI target IQNs (Initiator Qualified Names), comma-separated.                                                                                                |
| vdTemplateName | The name of the Virtual Disk Template to use for provisioning disks from DataCore. This template must already exist in SANsymphony.                                        |
| nodes          | (`optional`) A comma-separated list of Proxmox node names. Use this parameter to restrict the plugin to specific nodes. If omitted, the storage is available on all nodes. |
| shared         | (`optional`) Set to `1` to mark the storage as shared across all nodes. If omitted, the storage is treated as local.                                                       |
| disable        | (`optional`) Set to `1` to temporarily disable the storage without deleting it.                                                                                            |

**Example:**
```
ssy: Storage-Name
   DCipAddress 10.15.1.19,10.15.1.18
   DCusername administrator
   DCpassword Password
   portals 10.15.1.17,10.151.1.16
   targets iqn.2000-08.com.datacore:ssy1-1,iqn.2000-08.com.datacore:ssy2-1
   vdTemplateName SSY-VDT
   nodes pve1,pve2
   shared 1
   disable 0
```

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
  multipath -ll -v3     # diagnose issues with the multipath service
  iscsiadm -m node      # list what iSCSI nodes are mounted
  ```
- **Multipath Configuration:** Verify that your `multipath.conf` is correctly configured and that multipath devices are recognized. Use `multipath -ll` to list the current multipath devices.
- **SANsymphony User Permissions:** Ensure that the SANsymphony user has the necessary permissions to create and manage storage.
- **Plugin Updates:** Ensure you are using the latest version of the plugin.
