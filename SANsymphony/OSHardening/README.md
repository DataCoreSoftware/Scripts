# DCS Windows Hardening Tool

This repository provides the **DCS Hardening Tool** (`DcsHardeningTool.ps1`) to **apply**, **audit**, **backup**, and **restore** operating system hardening configurations using **HardeningKitty**.

`DcsHardeningTool.ps1` is the main entrypoint of this repository.  
Other standalone scripts are kept under `Examples\` as reference only.

---

## Scope and Supported Platforms

This tool is designed for **Windows Server editions**, based on the OS hardening profiles included in this repository:

- **Windows Server 2016** (Profile file: `datacore_ws2016.json`)
- **Windows Server 2019** (Profile file: `datacore_ws2019.json`)
- **Windows Server 2022** (Profile file: `datacore_ws2022.json`)
- **Windows Server 2025** (Profile file: `datacore_ws2025.json`)

The tool automatically detects the running operating system.  
If no matching OS hardening profile is found in the repository, execution stops with a clear message.

---

### OS Hardening Profiles

Each supported Windows Server version is mapped to a specific **OS Hardening Profile** (JSON).

- Profile files are stored in: `os-hardening-profiles\`
- Each profile references one or more HardeningKitty finding lists stored in: `lists\`

**Important (used for parameters):**  
When running in Non-Interactive mode, the `-OsHardeningProfile` parameter expects a **Profile ID** (for example: `DCS-WS2019`, `DCS-WS2022`, `DCS-WS2025`) rather than a JSON filename.

This design allows version-controlled hardening definitions per OS release.

---

### SANsymphony Compatibility

This hardening repository is validated for use with:

- **SANsymphony PSP20**
- **SANsymphony PSP21**

---

## What the Tool Does

`DcsHardeningTool.ps1` provides four main actions:

1. **Apply OS Hardening**  
   Applies the selected hardening finding lists using HardeningKitty (HailMary).

2. **Run OS Hardening Audit**  
   Runs an audit and produces **CSV reports** and **log files**.

3. **Backup current system configuration**  
   Exports current OS security configuration into a timestamped **CSV backup**.

4. **Restore system configuration from a backup CSV**  
   Reapplies settings from a backup CSV created by the backup action.

---

## Requirements

- An operating system with a matching profile present in `os-hardening-profiles\`
- PowerShell
- Run PowerShell **as Administrator** (recommended / typically required)

---

## HardeningKitty Dependency

The tool uses `settings.json` to download HardeningKitty automatically if it is not found locally.

For offline environments, manually place the module in: `HardeningKitty\HardeningKitty.psm1`

---

## Execution Modes and Examples

### Interactive Mode (Default)

Open PowerShell as Administrator, navigate to the repository root, and run:

```
.\DcsHardeningTool.ps1
```

Follow the on-screen menu.

---

### Non-Interactive Mode (Automation)

Non-Interactive mode is intended for automation and scripting scenarios.

**Examples:**

Run audit Non-interactive with OS profile ID `DCS-WS2025`:

```
.\DcsHardeningTool.ps1 -NonInteractive -ActionToRun Audit -OsHardeningProfile DCS-WS2025 -LocalRepositoryPath <Repository-Path>
```

Apply OS Hardening Non-interactive with auto selected OS profile:

```
.\DcsHardeningTool.ps1 -NonInteractive -ActionToRun Apply -OsHardeningProfile Auto -LocalRepositoryPath <Repository-Path>
```

Backup current system configuration Non-interactive:

```
.\DcsHardeningTool.ps1 -NonInteractive -ActionToRun Backup -LocalRepositoryPath <Repository-Path>
```

Restore current system configuration from a backup file Non-interactive:

```
.\DcsHardeningTool.ps1 -NonInteractive -ActionToRun Restore -RestoreBackupFile "Backup_YYYYMMDD_HHMMSS_NNN.csv" -LocalRepositoryPath <Repository-Path>
```

**Parameters:**

- `-ActionToRun` (required): `Apply | Audit | Backup | Restore`
- `-LocalRepositoryPath` (required): Path to repository root
- `-OsHardeningProfile` (optional): `Auto` or explicit **profile ID** (e.g., `DCS-WS2019`)
- `-RestoreBackupFile` (required for Non-Interactive Restore): Backup CSV **full path** or **filename** (filename is resolved under `backups\`)

---

## Output Structure

The tool automatically creates and uses:

Logs\  
- Audit_Report_<os>_<timestamp>_<config>.csv  
- Audit_Log_<os>_<timestamp>_<config>.log  

backups\  
- Backup_<timestamp>.csv  

HardeningKitty\  
Local HardeningKitty module (auto-downloaded if missing)

---

## Repository Structure

- DcsHardeningTool.ps1  
  Main entrypoint (interactive + automation mode)

- os-hardening-profiles\  
  OS profile definitions (JSON)

- lists\  
  HardeningKitty finding lists (CSV)

- settings.json  
  HardeningKitty download configuration

- windows_hardening_original_lists\  
  Baseline/reference material

- Examples\  
  Standalone example scripts (non-entrypoint)

---

## Safety Notice

- Backup/Restore operations affect security configuration only (not a full system backup).
- Always validate hardening changes in non-production environments before broad deployment.
