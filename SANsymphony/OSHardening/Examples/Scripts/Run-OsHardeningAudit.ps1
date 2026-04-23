
$repoPath = Split-Path $PSScriptRoot -Parent
$hardeningScript = Join-Path $repoPath "DcsHardeningTool.ps1"

& $hardeningScript -NonInteractive -Action Audit -OsHardeningProfile Auto -LocalRepositoryPath $repoPath