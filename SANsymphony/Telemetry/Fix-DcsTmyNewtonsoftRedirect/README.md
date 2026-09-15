# Fix-DcsTmyNewtonsoftRedirect

A small PowerShell workaround for the DataCore **DcsTmy** (Intelligence / telemetry) service failing to
connect after an in‑place upgrade — the service reports **Error 1002 / 1033** and stops transmitting.

## The problem

The telemetry service loads `Newtonsoft.Json` via an assembly **binding redirect** in its `.config` files.
When the shipped `Newtonsoft.Json.dll` is upgraded (e.g. to `13.0.0.0`) but the redirect in the deployed
config still points at the old version (e.g. `11.0.0.0`), the versions mismatch. The Azure IoT device
client uses Newtonsoft to (de)serialize the **device twin**, so the twin call fails, the connect sequence
aborts, and the service loops on 1002/1033 while never sending data.

This typically appears only after an **in‑place upgrade** (a clean install ships the correct config), when
the upgrade does not refresh the runtime‑modified `DcsTmy.exe.config`.

## What the script does

1. Stops the `DcsTmy` service (if running).
2. Detects the deployed `Newtonsoft.Json.dll` assembly version (per config folder).
3. Sets the `Newtonsoft.Json` `<bindingRedirect>` in every telemetry `.config` to match — backing up each
   file it changes to `*.orig.bak`.
4. Starts the service again.

It is **idempotent** (safe to re‑run — already‑correct files are skipped), isolates per‑file failures,
verifies each write, and always brings the service back up even if a config update fails.

## Requirements

- Windows with the DataCore telemetry component installed.
- Windows PowerShell 5.1+ (built in).
- Run **elevated** (Administrator) — it manages a service and writes under `Program Files`.

## Usage

```powershell
# Preview only — changes nothing
.\Fix-DcsTmyNewtonsoftRedirect.ps1 -WhatIf

# Apply the fix
.\Fix-DcsTmyNewtonsoftRedirect.ps1
```

If PowerShell blocks the script, run it via:

```powershell
powershell -ExecutionPolicy Bypass -File .\Fix-DcsTmyNewtonsoftRedirect.ps1
```

## Parameters

| Parameter        | Default                                             | Description |
|------------------|-----------------------------------------------------|-------------|
| `-TelemetryRoot` | `%ProgramW6432%\DataCore\Extensions\TMY`            | Folder to scan for `.config` files (recursive). Falls back to `C:\Program Files\DataCore\Extensions\TMY`. |
| `-ServiceName`   | `DcsTmy`                                             | Service to stop/start. |
| `-TargetVersion` | *(auto‑detected)*                                   | Force a specific redirect version (e.g. `13.0.0.0`) instead of detecting it from the DLL. |
| `-NoRestart`     | *(off)*                                             | Leave the service stopped after updating. |
| `-WhatIf`        | *(off)*                                             | Preview all actions without changing anything. |

## Output & exit codes

- Timestamped `INFO` / `WARN` / `ERROR` log lines to the console.
- Exit code **0** on success, **1** if any step reported a problem (useful for RMM / deployment tools).

## Rollback

Each changed file is backed up once as `<name>.config.orig.bak` next to the original. To revert a file,
stop the service, restore the `.orig.bak`, and start the service.

## Limitations

- This is a **runtime workaround** applied to the machine — it does **not** change the installer. A later
  full upgrade could re‑introduce the stale config until the packaging fix ships, so re‑run after upgrading.
- It corrects the config only; it does not itself verify that telemetry reconnects afterward.

## Disclaimer

Provided **as‑is, without warranty of any kind**. It modifies service configuration and restarts a service;
review it and test with `-WhatIf` before running in production, and ensure you have backups. Use at your own risk.

## License

Released under the [MIT License](LICENSE).
