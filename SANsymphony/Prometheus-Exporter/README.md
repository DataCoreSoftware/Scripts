
---

# 📡 DcsPrometheusExporter

A PowerShell-based Prometheus exporter to collect performance and configuration metrics from **DataCore SANsymphony** using REST APIs. Outputs metrics in Prometheus exposition format for ingestion via **windows_exporter**.

---

## 📦 Features

- Collects performance data from:
  - Servers
  - Hosts
  - Pools
  - Virtual Disks
  - Physical Disks
  - Ports
- Outputs `.prom` files to a directory compatible with `windows_exporter`
- Efficient logging, retry handling, and metric formatting
- Supports both continuous polling and one-time execution via `-RunOnce`

---

## 🧰 Prerequisites

Ensure the following are installed and configured:

### 1. PowerShell

- PowerShell 5.1 or later is required

### 2. Credential Manager Module

To securely store DataCore REST API credentials:
```powershell
Install-Module -Name CredentialManager
New-StoredCredential -Target 'datacore-api' -UserName 'restserver-username' -Password 'restserver-password' -Persist LocalMachine
````

* Replace values as appropriate.
* The `Target` must match `CredentialTarget` in `DcsPrometheusExporter.psd1`.

### 3. Windows Exporter

Install [windows\_exporter](https://github.com/prometheus-community/windows_exporter) with the `--collector.textfile.directory` flag:

```
--collector.textfile.directory="C:\Program Files\windows_exporter\textfile_inputs"
```

### 4. Prometheus Configuration

Add this job to your `prometheus.yml`:

```yml
  - job_name: 'windows_exporter'
    static_configs:
      - targets: ['<windows_exporter-ip>:9182']
```

---

## ⚙️ Configuration

Configuration is done via the `DcsPrometheusExporter.psd1` file. Below are the available options:

| Option                | Description                                                                 | Example                                      |
|-----------------------|-----------------------------------------------------------------------------|----------------------------------------------|
| `RESTServerIPAddress` | IP address of the DataCore REST server.                                     | `'127.0.0.1'`                             |
| `CredentialTarget`    | The name used to reference stored credentials in Windows Credential Manager.| `'datacore-api'`                             |
| `PromMetricsFilePath` | Output directory path where `.prom` metrics will be saved. Must match `--collector.textfile.directory` used by `windows_exporter`. | `'C:\Program Files\windows_exporter\textfile_inputs\'` |
| `IntervalSeconds`     | Interval (in seconds) between each data collection run (if not using `-RunOnce`). | `120` |
| `LogFileRetentionDays`       | Number of days to keep log files before auto-deletion.                      | `7` |
| `Resources`           | A dictionary specifying which resource types to collect metrics for. Each key can be set to `$true` or `$false`. See below for available resource keys. | `@{ servers = $true; ... }` |

### Available `Resources` keys:
- `servers`
- `hosts`
- `pools`
- `virtualdisks`
- `physicaldisks`
- `snapshots`
- `rollbacks`
- `ports`

Only the resources set to `$true` will be queried and included in the Prometheus output.


---

## 🖥️ Usage

### Run Manually

```powershell
.\DcsPrometheusExporter.ps1
```

### Run Once (e.g., via Task Scheduler)

```powershell
.\DcsPrometheusExporter.ps1 -RunOnce
```

---

## 🕒 Task Scheduler Setup

To run the script every 2 minutes:

1. Open **Task Scheduler** → *Create Task*
2. **Trigger**:

   * New → *On a schedule* → Repeat task every 2 minutes
3. **Action**:

   * Program/script: `powershell.exe`
   * Add arguments:

     ```powershell
     -ExecutionPolicy Bypass -File "C:\Path\To\DcsPrometheusExporter.ps1" -RunOnce
     ```
4. **Settings**:

   * Enable “Do not start a new instance if the task is already running”
   * Optionally use "On task completion" with delay (alternative to fixed interval)

---

## 📂 Logging

Log files are saved to:

```
<Script_path>\logs\DcsPrometheusExporter.log
```

* Old logs (older than `LogFileRetentionDays`) are automatically deleted.
* Logs include info, warning, and error levels.

---

## 🛠 Implementation Notes

* Uses `.NET StreamWriter` to safely write `.prom` files using atomic file replacement
* Handles SSL self-signed certs from DataCore
* Gracefully handles missing or empty performance data with retries
* Formats metrics in Prometheus exposition format

---

## 🔗 Related Resources

For complete setup instructions (DataCore Exporter + Windows Exporter + Prometheus + Grafana), refer to:

➡️ [Prometheus Exporter for DataCore SANsymphony](https://docs.datacore.com/Prometheus-Exporter-for-SANsymphony/prometheus-exporter-for-sansymphony/overview.htm)

---

## 👤 Maintainer

**Palegar Nikhil**
Email: *\[[palegar.nikhil@datacore.com](mailto:palegar.nikhil@datacore.com)]*
Organization: *DataCore Software*

---
