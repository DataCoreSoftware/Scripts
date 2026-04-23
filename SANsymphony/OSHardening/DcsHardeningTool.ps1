# *****************************************************************************
# Copyright ©2009-2026 DataCore Software Corporation. All rights reserved.
# *****************************************************************************
[CmdletBinding(DefaultParameterSetName = 'Interactive')]
param(
    # Interactive (default): show menu
    [Parameter(ParameterSetName = 'Interactive')]
    [switch]$Interactive,

    # Non-interactive: run one action automatically
    [Parameter(ParameterSetName = 'NonInteractive', Mandatory = $true)]
    [switch]$NonInteractive,

    # What to do in NonInteractive mode
    [Parameter(ParameterSetName = 'NonInteractive', Mandatory = $true)]
    [ValidateSet('Apply','Audit','Backup','Restore')]
    [string]$ActionToRun,

    [Parameter(ParameterSetName = 'NonInteractive', Mandatory = $true)]
    [string]$LocalRepositoryPath,

    # How to pick the profile for Apply/Audit
    [Parameter(ParameterSetName = 'NonInteractive')]
    [ValidateSet('Auto','DCS-WS2019','DCS-WS2025','WH-WS2019','WH-WS2025')]
    [string]$OsHardeningProfile = 'Auto'
,

    # Restore: backup CSV path or filename (filename is resolved under backups\)
    [Parameter(ParameterSetName = 'NonInteractive')]
    [Alias('RestoreFile','BackupFile','BackupPath')]
    [string]$RestoreBackupFile
)

function New-RunTimestamp {
    return (Get-Date -Format 'yyyyMMdd_HHmmss_fff')
}

function Get-HardeningKitty {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        # Optional override. If not provided, the version is read from settings.json
        [string]$Version,

        # Optional settings path. If not provided, it tries "$PSScriptRoot\settings.json"
        [string]$SettingsPath
    )

    $psm1Path = Join-Path $DestinationPath "HardeningKitty.psm1"
    if (Test-Path $psm1Path) { return }

    if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
        $SettingsPath = Join-Path $PSScriptRoot "settings.json"
    }

    if (-not (Test-Path $SettingsPath)) {
        throw "settings.json not found at: $SettingsPath"
    }

    $settings = Get-Content -Path $SettingsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop

    if (-not $settings.hardeningKitty) { throw "Missing 'hardeningKitty' section in settings.json." }
    if (-not $settings.hardeningKitty.github) { throw "Missing 'hardeningKitty.github' section in settings.json." }

    $owner     = [string]$settings.hardeningKitty.github.owner
    $repo      = [string]$settings.hardeningKitty.github.repo
    $tagFormat = [string]$settings.hardeningKitty.tagFormat
    $userAgent = [string]$settings.hardeningKitty.http.userAgent

    if ([string]::IsNullOrWhiteSpace($owner)) { throw "hardeningKitty.github.owner is empty." }
    if ([string]::IsNullOrWhiteSpace($repo)) { throw "hardeningKitty.github.repo is empty." }
    if ([string]::IsNullOrWhiteSpace($tagFormat)) { throw "hardeningKitty.tagFormat is empty." }
    if ([string]::IsNullOrWhiteSpace($userAgent)) { $userAgent = "DataCore-Hardening" }

    if ([string]::IsNullOrWhiteSpace($Version)) {
        $Version = [string]$settings.hardeningKitty.version
    }
    if ([string]::IsNullOrWhiteSpace($Version)) { throw "HardeningKitty version is not set (param Version or settings.json hardeningKitty.version)." }

    Write-Host ""
    Write-Host "HardeningKitty was not found. Downloading version $Version from $owner/$repo..." -ForegroundColor Yellow

    New-Item -Path $DestinationPath -ItemType Directory -Force | Out-Null

    $tag = $tagFormat.Replace("{version}", $Version)
    $headers = @{ "User-Agent" = $userAgent }

    # Force TLS 1.2 for GitHub compatibility (required on Server 2016)
    $previousSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $releaseApi = "https://api.github.com/repos/$owner/$repo/releases/tags/$tag"
    $release = (Invoke-WebRequest -Uri $releaseApi -Headers $headers -UseBasicParsing -ErrorAction Stop).Content | ConvertFrom-Json -ErrorAction Stop

    $zipUrl  = $release.zipball_url
    if ([string]::IsNullOrWhiteSpace($zipUrl)) { throw "Release metadata did not include zipball_url for tag '$tag' in $owner/$repo." }

    $zipFile = Join-Path $DestinationPath "HardeningKitty_$Version.zip"

    Invoke-WebRequest -Uri $zipUrl -Headers $headers -OutFile $zipFile -UseBasicParsing -ErrorAction Stop

    # Restore previous TLS settings
    [Net.ServicePointManager]::SecurityProtocol = $previousSecurityProtocol

    $tmpPath = Join-Path $DestinationPath "_tmp"
    New-Item -Path $tmpPath -ItemType Directory -Force | Out-Null

    Expand-Archive -Path $zipFile -DestinationPath $tmpPath -Force -ErrorAction Stop

    $topFolder = Get-ChildItem -Path $tmpPath -Directory | Select-Object -First 1
    if (-not $topFolder) { throw "HardeningKitty extraction failed." }

    Copy-Item -Path (Join-Path $topFolder.FullName "*") `
              -Destination $DestinationPath `
              -Recurse -Force

    Remove-Item -Path $tmpPath -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $zipFile -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path $psm1Path)) {
        throw "HardeningKitty.psm1 not found after download."
    }
}
function Initialize-HardeningKitty {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context
    )

    try {
        Get-HardeningKitty -DestinationPath $Context.HKPath -SettingsPath (Join-Path $Context.RepoPath "settings.json")

        $hkModulePath = Join-Path $Context.HKPath "HardeningKitty.psm1"
        if (-not (Test-Path $hkModulePath)) {
            throw "HardeningKitty.psm1 not found at: $hkModulePath"
        }

        Import-Module $hkModulePath -Force -ErrorAction Stop
    }
    catch {
        Write-Host "HardeningKitty initialization failed." -ForegroundColor Red
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

function Get-OsHardeningProfiles {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Context
    )

    $profiles = @()

    $profileFiles = Get-ChildItem -Path $Context.ProfilesPath -Filter "*.json" -File -ErrorAction SilentlyContinue
    if (-not $profileFiles -or $profileFiles.Count -eq 0) {
        return $profiles
    }

    foreach ($file in $profileFiles) {
        try {
            $content = Get-Content $file.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            continue;
        }
        $profiles += $content
    }

    return $profiles
}

function Select-OsHardeningProfile {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,

        [Parameter(Mandatory = $true)]
        [array]$Profiles
    )

    # Auto-detect based on current OS
    $windowsServerKey = Get-WindowsServerProfileKey

    if($Context.IsInteractive) {
        Write-Host ""
        Write-Host "Select Operating System Hardening Profile:" -ForegroundColor Yellow
        $profilesCandidates = @($Profiles | Where-Object { $_.osKey -eq $windowsServerKey })

        if (-not $profilesCandidates -or $profilesCandidates.Count -eq 0) {
            Write-Host "No matching profiles found for '$windowsServerKey'." -ForegroundColor Red
            return $null
        }

        foreach ($index in 0..($profilesCandidates.Count - 1)) {
            Write-Host "$($index + 1). $($profilesCandidates[$index].displayName)"
        }

        Write-Host ""
        $selectionRaw = Read-Host "Enter the number corresponding to your choice"

        [int]$selection = 0
        if (-not [int]::TryParse($selectionRaw, [ref]$selection)) {
            Write-Host "Invalid input. Enter a number." -ForegroundColor Red
            return $null
        }

        $selectedIndex = $selection - 1
        if ($selectedIndex -lt 0 -or $selectedIndex -ge $profilesCandidates.Count) {
            Write-Host "Invalid selection. Exiting script." -ForegroundColor Red
            return $null
        }

        $selectedProfile = $profilesCandidates[$selectedIndex]
        Write-Host ""
        Write-Host "You selected: $($selectedProfile.displayName)" -ForegroundColor Green
    }
    else{
        if($OsHardeningProfile -eq 'Auto') {
            $profilesCandidates = @($Profiles | Where-Object { $_.osKey -eq $windowsServerKey })

            if(-not $profilesCandidates -or $profilesCandidates.Count -eq 0) {
                Write-Host "No matching profile found for current OS '$windowsServerKey'. Exiting." -ForegroundColor Red
                return $null
            }

            $selectedProfile = $profilesCandidates[0]
            Write-Host "Auto-detected OS profile: $($selectedProfile.displayName)" -ForegroundColor Yellow
        }
        else {
            $profilesCandidates = @($Profiles | Where-Object { $_.profileId -eq $OsHardeningProfile })

            if(-not $profilesCandidates -or $profilesCandidates.Count -eq 0) {
                Write-Host "Specified OS profile '$OsHardeningProfile' not found. Exiting." -ForegroundColor Red
                return $null
            }

            $selectedProfile = $profilesCandidates[0]
            Write-Host "Using specified profile: $($selectedProfile.displayName)" -ForegroundColor Yellow
        }
    }

    return $selectedProfile
}

function Test-ListsAndConfigs {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ListsPath,

        [Parameter(Mandatory = $true)]
        [string[]]$SelectedConfigs
    )

    if (-not (Test-Path $ListsPath)) {
        Write-Host "Lists folder not found: $ListsPath" -ForegroundColor Red
        return $false
    }

    foreach ($config in $SelectedConfigs) {
        $cfgPath = Join-Path $ListsPath $config
        if (-not (Test-Path $cfgPath)) {
            Write-Host "Config file not found: $cfgPath" -ForegroundColor Red
            return $false
        }
    }

    return $true
}

function Invoke-OsHardeningAudit {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context
    )

    $profiles = Get-OsHardeningProfiles -Context $Context
    if ($profiles.Count -eq 0) {
        Write-Host "No valid OS hardening profiles found in '$($Context.ProfilesPath)'. Either there are no *.json files, the existing files have invalid JSON format, or are missing required properties." -ForegroundColor Red
        return
    }

    $selectedProfile = Select-OsHardeningProfile -Context $Context -Profiles $profiles
    if(-not $selectedProfile) {
        Write-Host "No profile selected. Exiting." -ForegroundColor Red
        return
    }

    $os = $selectedProfile.os
    $SelectedConfigs = [string[]]$selectedProfile.configs
    $listsPath = Join-Path $Context.RepoPath $selectedProfile.listsFolder

    if (-not (Test-ListsAndConfigs -ListsPath $ListsPath -SelectedConfigs $SelectedConfigs)) {
        return
    }

    foreach ($config in $SelectedConfigs) {
        Write-Host ""
        Write-Host "Running Audit for Hardening Configuration $config..." -ForegroundColor Cyan

        if($Context.IsInteractive) {
            Read-Host "Press Enter to continue"
        }

        $configName = [System.IO.Path]::GetFileNameWithoutExtension($config)
        $ts = New-RunTimestamp
        $auditReportFile = "Audit_Report_${os}_${ts}_${configName}.csv"
        $auditLogFile = "Audit_Log_${os}_${ts}_${configName}.log"

        $logFilePath = Join-Path $Context.LogPath $auditLogFile
        $reportFilePath = Join-Path $Context.LogPath $auditReportFile

        Invoke-HardeningKitty -Mode Audit -SkipMachineInformation -FileFindingList (Join-Path $listsPath $config) -Log -LogFile $logFilePath -Report -ReportFile $reportFilePath

        if($Context.IsInteractive) {
            Read-Host "Press Enter to continue"
        }
    }

    Write-Host "OS Hardening Audit Process completed."
}

function Invoke-OsHardeningApplication {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context
    )

    $profiles = Get-OsHardeningProfiles -Context $Context
    if ($profiles.Count -eq 0) {
        Write-Host "No valid OS hardening profiles found in '$($Context.ProfilesPath)'. Either there are no *.json files, the existing files have invalid JSON format, or are missing required properties." -ForegroundColor Red
        return
    }

    $selectedProfile = Select-OsHardeningProfile -Context $Context -Profiles $profiles
    if(-not $selectedProfile) {
        Write-Host "No profile selected. Exiting." -ForegroundColor Red
        return
    }

    $SelectedConfigs = [string[]]$selectedProfile.configs
    $listsPath = Join-Path $Context.RepoPath $selectedProfile.listsFolder

    if (-not (Test-ListsAndConfigs -ListsPath $ListsPath -SelectedConfigs $SelectedConfigs)) {
        return
    }

    foreach ($config in $SelectedConfigs) {
        Write-Host ""
        Write-Host "Applying Hardening Configuration: $config..." -ForegroundColor Cyan

        Invoke-HardeningKitty -Mode HailMary -SkipMachineInformation `
            -SkipRestorePoint `
            -FileFindingList (Join-Path $ListsPath $config)
    }

    Write-Host "OS Hardening Application Process completed."
}

function Invoke-Backup {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context
    )

    Write-Host ""
    Write-Host "Creating backup of current system configuration..." -ForegroundColor Yellow

    if (-not (Test-Path $Context.BackupPath)) {
        New-Item -Path $Context.BackupPath -ItemType Directory -Force | Out-Null
    }

    $ts = New-RunTimestamp
    $backupFile = Join-Path $Context.BackupPath ("Backup_{0}.csv" -f $ts)
    Invoke-HardeningKitty -Mode Config -SkipMachineInformation -Backup -BackupFile $backupFile

    Write-Host "Backup created: $backupFile" -ForegroundColor Green
    Write-Host "Process completed."
}

function Invoke-Restore {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context
    )

    Write-Host ""
    Write-Host "Restoring system configuration from a backup CSV..." -ForegroundColor Cyan
    Write-Host ""

    # If the backups folder does not exist, there is nothing to restore.
    if (-not (Test-Path $Context.BackupPath)) {
        Write-Host "Backups folder not found:" -ForegroundColor Yellow
        Write-Host "  $($Context.BackupPath)" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "No backups are available to restore." -ForegroundColor Yellow
        Write-Host "Create a backup first, then try Restore again." -ForegroundColor Yellow
        Write-Host ""
        return
    }

    Write-Host "Backups folder:" -ForegroundColor Yellow
    Write-Host "  $($Context.BackupPath)" -ForegroundColor Yellow
    Write-Host ""

    # Non-Interactive: require a restore file argument
    if (-not $Context.IsInteractive) {

        if (-not $Context.ContainsKey('RestoreBackupFile') -or [string]::IsNullOrWhiteSpace($Context.RestoreBackupFile)) {
            throw "Non-Interactive Restore requires -RestoreBackupFile (either a full path or a filename under 'backups\')."
        }

        $trimmed = $Context.RestoreBackupFile.Trim()

        # Support either a full path or a filename inside the backups folder.
        $backupFilePath = $trimmed
        if (-not (Test-Path $backupFilePath)) {
            $backupFilePath = Join-Path $Context.BackupPath $trimmed
        }

        if (-not (Test-Path $backupFilePath)) {
            throw "Restore backup file not found: '$backupFilePath'."
        }

        Invoke-HardeningKitty -Mode HailMary -SkipMachineInformation -SkipRestorePoint -FileFindingList $backupFilePath

        Write-Host ""
        Write-Host "Restore completed using:" -ForegroundColor Green
        Write-Host "  $backupFilePath" -ForegroundColor Green
        Write-Host "Process completed."
        return
    }

    # Interactive: prompt the user
    Write-Host "Type the backup filename to restore (filename only), or type 'exit' to cancel." -ForegroundColor Yellow
    Write-Host ""

    while ($true) {
        $inputName = Read-Host "Backup filename"

        if ([string]::IsNullOrWhiteSpace($inputName)) {
            Write-Host "Please enter a filename (or type 'exit' to cancel)." -ForegroundColor Red
            continue
        }

        $trimmed = $inputName.Trim()

        if ($trimmed -ieq "exit" -or $trimmed -ieq "q" -or $trimmed -ieq "quit") {
            Write-Host ""
            Write-Host "Restore canceled. No changes were applied." -ForegroundColor Yellow
            return
        }

        # Support either a full path or a filename inside the backups folder.
        $backupFilePath = $trimmed
        if (-not (Test-Path $backupFilePath)) {
            $backupFilePath = Join-Path $Context.BackupPath $trimmed
        }

        if (-not (Test-Path $backupFilePath)) {
            Write-Host ""
            Write-Host "File not found:" -ForegroundColor Yellow
            Write-Host "  $backupFilePath" -ForegroundColor Yellow
            Write-Host "Please type a valid backup filename, or type 'exit' to cancel." -ForegroundColor Yellow
            Write-Host ""
            continue
        }

        Invoke-HardeningKitty -Mode HailMary -SkipMachineInformation -SkipRestorePoint -FileFindingList $backupFilePath

        Write-Host ""
        Write-Host "Restore completed using:" -ForegroundColor Green
        Write-Host "  $backupFilePath" -ForegroundColor Green
        Write-Host "Process completed."
        return
    }
}

function New-RepoContext {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LocalRepoPath
    )

    $ctx = [ordered]@{
        RepoPath      = $LocalRepoPath
        ListsPath     = Join-Path $LocalRepoPath "lists"
        ProfilesPath  = Join-Path $LocalRepoPath "os-hardening-profiles"
        HKPath        = Join-Path $LocalRepoPath "HardeningKitty"
        BackupPath    = Join-Path $LocalRepoPath "backups"
        LogPath       = Join-Path $LocalRepoPath "Logs"
        Timestamp     = New-RunTimestamp
        IsInteractive = "Interactive"  # This will be overridden in Invoke-Main based on parameter set
        MainMenuOptions = @{
            1 = @{
                Text = "Apply OS Hardening"
                Run  = { param($c) Invoke-OsHardeningApplication -Context $c }
            }
            2 = @{
                Text = "Run OS Hardening Audit"
                Run  = { param($c) Invoke-OsHardeningAudit -Context $c}
            }
            3 = @{
                Text = "Create backup of current system configuration"
                Run  = { param($c) Invoke-Backup -Context $c }
            }
            4 = @{
                Text = "Restore system configuration from backups\backup.csv"
                Run  = { param($c) Invoke-Restore -Context $c }
            }
            5 = @{
                Text = "Exit"
                Run  = { param($c) return $false }
            }
        }
    }

    if (-not (Test-Path $ctx.LogPath)) {
        New-Item -Path $ctx.LogPath -ItemType Directory -Force | Out-Null
    }

    return $ctx
}

function Get-WindowsServerProfileKey {
    # Returns: "WS2016" | "WS2019" | "WS2022" | "WS2025"
    # Throws on non-server or unsupported builds.
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop

    # ProductType: 1=Workstation, 2=Domain Controller, 3=Server
    if ($os.ProductType -eq 1) {
        throw "This machine is not Windows Server. Caption='$($os.Caption)' Version='$($os.Version)' Build='$($os.BuildNumber)'."
    }

    $build = [int]$os.BuildNumber

    # Use base build ranges (robust) rather than parsing Caption text.
    if ($build -ge 26100) { return "WS2025" }   # Windows Server 2025 base build 26100 :contentReference[oaicite:1]{index=1}
    if ($build -ge 20348) { return "WS2022" }   # Windows Server 2022 base build 20348 :contentReference[oaicite:2]{index=2}
    if ($build -ge 17763) { return "WS2019" }   # Windows Server 2019 base build 17763 :contentReference[oaicite:3]{index=3}
    if ($build -ge 14393) { return "WS2016" }   # Windows Server 2016 base build 14393 :contentReference[oaicite:4]{index=4}

    throw "Unsupported Windows Server build '$build'. Caption='$($os.Caption)' Version='$($os.Version)'."
}
function Invoke-InteractiveMode {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context
    )

    $mainMenuOptions = $Context.MainMenuOptions

    while ($true) {
        Write-Host ""
        Write-Host "Select an option:" -ForegroundColor Yellow

        $menuOrder = $mainMenuOptions.Keys | Sort-Object
        foreach ($key in $menuOrder) {
            $item = $mainMenuOptions[$key]   # Now this is KEY access (correct)
            if ($null -eq $item) { continue }
            if (-not $item.ContainsKey('Text')) { continue }
            if ([string]::IsNullOrWhiteSpace($item.Text)) { continue }
            Write-Host "$key. $($item.Text)"
        }

        Write-Host ""
        $mainChoiceRaw = Read-Host "Enter your choice"

        [int]$mainChoice = 0
        if (-not [int]::TryParse($mainChoiceRaw, [ref]$mainChoice)) {
            Write-Host "Invalid input. Enter a number." -ForegroundColor Red
            continue
        }

        if (-not $mainMenuOptions.ContainsKey($mainChoice)) {
            Write-Host "Invalid option. Try again." -ForegroundColor Red
            continue
        }

        $result = & $mainMenuOptions[$mainChoice].Run $Context
        if ($result -eq $false) {
            break
        }
    }
}

function Invoke-NonInteractiveMode {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context
    )

    $mainMenuOptions = $Context.MainMenuOptions
    [int]$mainChoice = 0

    switch ($ActionToRun) {
        "Apply" { 
            $mainChoice = 1 
        }
        "Audit" { 
            $mainChoice = 2
        }
        "Backup" { 
            $mainChoice = 3
        }
        "Restore" { 
            $mainChoice = 4
        }
        Default { 
            throw "Unknown action to run: $ActionToRun" 
        }
    }

    $result = & $mainMenuOptions[$mainChoice].Run $Context
    if ($result -eq $false) {
        return
    }

}
function Invoke-Main {
    $isInteractive = ($PSCmdlet.ParameterSetName -eq 'Interactive')

    if($isInteractive) {
        Write-Host "Running in Interactive mode." -ForegroundColor Green
        $localRepoPath = $PSScriptRoot
    }
    else {
        Write-Host "Running in Non-Interactive mode. Action: $ActionToRun, Profile: $OsHardeningProfile" -ForegroundColor Green
        $localRepoPath = $LocalRepositoryPath
    }

    $ctx = New-RepoContext -LocalRepoPath $localRepoPath
    $ctx.IsInteractive = $isInteractive


    # Carry optional restore file into the context for Non-Interactive restore
    if (-not $isInteractive) {
        $ctx.RestoreBackupFile = $RestoreBackupFile
    }

    try {
        Initialize-HardeningKitty -Context $ctx
    }
    catch {
        return
    }

    if ($PSCmdlet.ParameterSetName -eq 'Interactive') {
        Invoke-InteractiveMode -Context $ctx
    }
    else {
        Invoke-NonInteractiveMode -Context $ctx
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Main
}