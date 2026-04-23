
$repoPath = Split-Path $PSScriptRoot -Parent
$hardeningScript = Join-Path $repoPath "DcsHardeningTool.ps1"

& $hardeningScript -NonInteractive -Action Apply -OsHardeningProfile Auto -LocalRepositoryPath $repoPath