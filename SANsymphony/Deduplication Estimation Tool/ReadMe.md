# Deduplication Estimation Tool

The **Deduplication Estimation Tool** helps you estimate potential storage savings before enabling **Inline Deduplication** in **DataCore SANsymphony**. It scans data from either file system paths or raw disks and calculates deduplication ratios without modifying any data.

---

## 🔧 Key Features

* Estimate deduplication benefits **before enabling ILDC**
* Support for scanning **raw disks** or **file paths**
* Automates snapshot creation and scanning for **virtual disks**
* Customize chunk size, hash function, and threading

---

## 📦 Tool Components

The tool package includes:

| File                        | Description                                                      |
| --------------------------- | ---------------------------------------------------------------- |
| `DcsEstimateDedupRatio.exe` | Standalone CLI tool for scanning paths or raw devices            |
| `DDestimate.ps1`            | PowerShell wrapper script for scanning SANsymphony virtual disks |

---

## 🧪 Usage Modes

### 1. **Scan Raw Disks**

Estimate deduplication ratio for entire physical disks.

**Steps:**

```sh
wmic diskdrive list brief   # Identify physical disk paths
DcsEstimateDedupRatio.exe -raw \\.\PHYSICALDRIVE1
```

**Optional Parameters:**

* `--nosampling` : Does not do sampling, scans complete data. Increase accuracy (uses more memory)
* `--skip-zeroes` : Ignore zero-byte blocks (for thin provisioning)
* `-s <bytes>` : Set chunk size (default: 131072)
* `-hf <hash>` : Choose hash (e.g. sha256, sha512, xxh64)
* `-t <threads>` : Number of processing threads (default: 16)

---

### 2. **Scan File System Paths**

Estimate deduplication for specific folders or drives.

**Example:**

```sh
DcsEstimateDedupRatio.exe C:\ D:\
```

---

### 3. **Scan SANsymphony Virtual Disks via PowerShell**

Use this method for estimating deduplication on SANsymphony-managed virtual disks.

**Steps:**

Open SANsymphony's Powershell window, move to the script's location.

```powershell
Connect-DcsServer
cd "C:\Tools\DedupEstimator"
.\DDestimate.ps1 -vDiskName "VDISK01"
# Optional: Enable BR-mode (32 KB chunks)
.\DDestimate.ps1 -vDiskName "VDISK01" -BRmode
Disconnect-DcsServer
```

> Note: The script creates a temporary snapshot of the vDisk for analysis. Snapshots are auto-deleted if the script completes. Clean up manually if interrupted.

---

## 📤 Output

The tool displays the **deduplication ratio** and writes results to a `.txt` file.

**Example:**

```
Deduplication Ratio: 8.55:1
# (Approx) Unique Data: 12% | Redundant Data: 88%
```

---

## ✅ Requirements

* Windows OS with administrative privileges
* For vDisk scans: DataCore SANsymphony PowerShell environment

---

## 📝 Notes

* Avoid interrupting the scan—it may take time depending on disk size.
* When scripting, use `--suppress-result` to hide output on screen.
* `--read-block-size` can improve performance on non-SANsymphony disks.

---

## 📁 Example Command Summary

```sh
# Scan raw disk with high accuracy
DcsEstimateDedupRatio.exe -raw --nosampling \\.\PHYSICALDRIVE1

# Scan folders with default settings
DcsEstimateDedupRatio.exe C:\Data D:\Backups

# PowerShell: Scan vDisk in BR mode
.\DDestimate.ps1 -vDiskName "VDISK01" -BRmode
```

---

## 📚 Documentation

For more details, refer to:
➡️ [Deduplication Estimation Tool for DataCore SANsymphony](https://docs.datacore.com/#)
