#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Workaround for DcsTmy telemetry not connecting after upgrade (Error 1002 / 1033),
    caused by a stale Newtonsoft.Json binding redirect in the telemetry .config files
    (e.g. redirect pinned to 11.0.0.0 while the deployed DLL is 13.0.0.0).

    Stops the DcsTmy service (if running), sets the Newtonsoft.Json <bindingRedirect>
    in every telemetry .config to match the deployed Newtonsoft.Json.dll (backing up each
    file it changes), then starts the service again. The service is always brought back up
    (unless -NoRestart), even if a config update fails.

.EXAMPLE
    .\Fix-DcsTmyNewtonsoftRedirect.ps1
.EXAMPLE
    .\Fix-DcsTmyNewtonsoftRedirect.ps1 -WhatIf          # preview, change nothing
.EXAMPLE
    .\Fix-DcsTmyNewtonsoftRedirect.ps1 -TargetVersion 13.0.0.0 -NoRestart
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$TelemetryRoot = "$env:ProgramW6432\DataCore\Extensions\TMY",
    [string]$ServiceName   = 'DcsTmy',
    [string]$TargetVersion,          # auto-detected per config folder / globally if omitted
    [switch]$NoRestart               # leave the service stopped
)

$ErrorActionPreference = 'Stop'
$AsmName = 'Newtonsoft.Json'
$AsmNs   = 'urn:schemas-microsoft-com:asm.v1'
$errorCount = 0

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    Write-Host ("[{0}] [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message)
}

function Get-NewtonsoftAssemblyVersion {
    param([string]$Directory)
    $dll = Join-Path $Directory 'Newtonsoft.Json.dll'
    if (Test-Path -LiteralPath $dll) {
        try { return [System.Reflection.AssemblyName]::GetAssemblyName($dll).Version.ToString() } catch { return $null }
    }
    return $null
}

# --- Resolve telemetry root -------------------------------------------------------------
if (-not (Test-Path -LiteralPath $TelemetryRoot)) {
    $fallback = "C:\Program Files\DataCore\Extensions\TMY"
    if (Test-Path -LiteralPath $fallback) { $TelemetryRoot = $fallback }
    else { Write-Log "Telemetry folder not found: $TelemetryRoot" 'ERROR'; exit 1 }
}
Write-Log "Telemetry root: $TelemetryRoot"

# --- Global fallback target version (best effort) ---------------------------------------
if (-not $TargetVersion) {
    $anyDll = Get-ChildItem -LiteralPath $TelemetryRoot -Recurse -Filter 'Newtonsoft.Json.dll' -File -ErrorAction SilentlyContinue |
              Select-Object -First 1
    if ($anyDll) {
        $TargetVersion = Get-NewtonsoftAssemblyVersion -Directory $anyDll.DirectoryName
    }
    if (-not $TargetVersion) { $TargetVersion = '13.0.0.0' }
    Write-Log "Fallback target $AsmName version: $TargetVersion"
}

# --- Capture service handle -------------------------------------------------------------
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

try {
    # --- 1. Stop the DcsTmy service if running -----------------------------------------
    if ($svc -and $svc.Status -eq 'Running') {
        if ($PSCmdlet.ShouldProcess($ServiceName, 'Stop service')) {
            Write-Log "Stopping service $ServiceName..."
            try {
                Stop-Service -Name $ServiceName -Force
                $svc.WaitForStatus('Stopped', (New-TimeSpan -Seconds 90))
                Write-Log "Service stopped."
            } catch {
                Write-Log "Service did not stop cleanly: $($_.Exception.Message). Files it holds may be locked." 'WARN'
                $errorCount++
            }
        }
    } elseif ($svc) {
        Write-Log "Service $ServiceName is '$($svc.Status)'; not stopping."
    } else {
        Write-Log "Service $ServiceName not found; continuing with config update only." 'WARN'
    }

    # --- 2. Update the Newtonsoft.Json binding redirect in each config -----------------
    $configs = Get-ChildItem -LiteralPath $TelemetryRoot -Recurse -Filter '*.config' -File -ErrorAction SilentlyContinue
    $updated = 0; $already = 0; $skipped = 0

    foreach ($cfg in $configs) {
        try {
            $xml = New-Object System.Xml.XmlDocument
            $xml.PreserveWhitespace = $true                 # keep original formatting
            try { $xml.Load($cfg.FullName) }
            catch { Write-Log "SKIP (not valid XML): $($cfg.FullName)"; $skipped++; continue }

            $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
            $ns.AddNamespace('a', $AsmNs)
            $redirects = $xml.SelectNodes("//a:dependentAssembly[a:assemblyIdentity/@name='$AsmName']/a:bindingRedirect", $ns)
            if (-not $redirects -or $redirects.Count -eq 0) { continue }   # no Newtonsoft redirect here

            # Prefer the Newtonsoft.Json.dll in this config's own folder; fall back to global.
            $ver = Get-NewtonsoftAssemblyVersion -Directory $cfg.DirectoryName
            if (-not $ver) { $ver = $TargetVersion }
            $desiredOld = "0.0.0.0-$ver"

            $needsChange = $false
            foreach ($r in $redirects) {
                if ($r.oldVersion -ne $desiredOld -or $r.newVersion -ne $ver) { $needsChange = $true }
            }
            if (-not $needsChange) { Write-Log "OK (already $ver): $($cfg.FullName)"; $already++; continue }

            if ($PSCmdlet.ShouldProcess($cfg.FullName, "Set $AsmName redirect -> $ver")) {
                $bak = "$($cfg.FullName).orig.bak"
                if (-not (Test-Path -LiteralPath $bak)) { Copy-Item -LiteralPath $cfg.FullName -Destination $bak -Force }
                if ($cfg.IsReadOnly) { Set-ItemProperty -LiteralPath $cfg.FullName -Name IsReadOnly -Value $false }

                foreach ($r in $redirects) {
                    $r.SetAttribute('oldVersion', $desiredOld)
                    $r.SetAttribute('newVersion', $ver)
                }
                $xml.Save($cfg.FullName)

                # verify the change actually landed
                $check = New-Object System.Xml.XmlDocument
                $check.Load($cfg.FullName)
                $cns = New-Object System.Xml.XmlNamespaceManager($check.NameTable)
                $cns.AddNamespace('a', $AsmNs)
                $ok = $true
                foreach ($r in $check.SelectNodes("//a:dependentAssembly[a:assemblyIdentity/@name='$AsmName']/a:bindingRedirect", $cns)) {
                    if ($r.newVersion -ne $ver) { $ok = $false }
                }
                if ($ok) { Write-Log "UPDATED -> $ver (backup: $bak): $($cfg.FullName)"; $updated++ }
                else { Write-Log "VERIFY FAILED (still not $ver): $($cfg.FullName)" 'ERROR'; $errorCount++ }
            }
        }
        catch {
            Write-Log "FAILED to update $($cfg.FullName): $($_.Exception.Message)" 'ERROR'
            $errorCount++
        }
    }
    Write-Log "Configs: $updated updated, $already already correct, $skipped skipped."
}
finally {
    # --- 3. Always bring the service back up (unless -NoRestart) -----------------------
    if ($NoRestart) {
        Write-Log "Service left stopped (-NoRestart). Start it with: Start-Service $ServiceName"
    }
    elseif (-not $svc) {
        Write-Log "Service $ServiceName not present; nothing to start."
    }
    else {
        try {
            $svc.Refresh()
            if ($svc.Status -eq 'Running') {
                Write-Log "Service $ServiceName already running."
            }
            elseif ($PSCmdlet.ShouldProcess($ServiceName, 'Start service')) {
                Write-Log "Starting service $ServiceName..."
                Start-Service -Name $ServiceName -ErrorAction Stop
                $svc.WaitForStatus('Running', (New-TimeSpan -Seconds 90))
                Write-Log "Service started."
            }
        }
        catch {
            Write-Log "Could not start $ServiceName - $($_.Exception.Message). If it is Disabled, enable it then run: Start-Service $ServiceName" 'WARN'
            $errorCount++
        }
    }
}

if ($errorCount -gt 0) { Write-Log "Completed with $errorCount problem(s)." 'WARN'; exit 1 }
Write-Log "Done."
exit 0
