# Folder Analysis Script (HTML Report with Charts)
# Analyzes file age and storage usage by file type and generates an
# interactive HTML report (trend chart, file type/owner pie charts,
# age breakdown 1/3/5 years, top 10 files).

param(
    [Parameter(Mandatory=$true)]
    [string]$FolderPath,

    [Parameter(Mandatory=$false)]
    [string]$OutputPath = ".\FolderAnalysis_$(Get-Date -Format 'yyyyMMdd_HHmmss').html",

    # Owner lookup via Get-Acl is slow for very large numbers of files.
    # Disabled by default, enable with -IncludeOwner.
    [Parameter(Mandatory=$false)]
    [switch]$IncludeOwner,

    # How many file types are shown individually, the rest is grouped as "Other"
    [Parameter(Mandatory=$false)]
    [int]$TopExtensions = 10,

    # Internal flag: set automatically when the script relaunches itself under a
    # different user account, so the user-context prompt is not shown twice.
    [Parameter(Mandatory=$false)]
    [switch]$ElevatedRelaunch
)

# ------------------------------------------------------------------------------------
# Preparation
# ------------------------------------------------------------------------------------

# Ask which Windows user account should be used to access the folder.
# Skipped automatically on the relaunched child process (-ElevatedRelaunch).
if (-not $ElevatedRelaunch) {
    Write-Host ""
    Write-Host "Which user account should be used to access the folder?" -ForegroundColor Cyan
    Write-Host "  [1] Current user ($env:USERDOMAIN\$env:USERNAME)  (default)"
    Write-Host "  [2] A different user (you will be prompted for credentials)"
    $contextChoice = (Read-Host "Choice (1/2, default 1)").Trim()
    Write-Host "You entered: '$contextChoice'" -ForegroundColor DarkGray

    if ($contextChoice -in @('2','different','d','other','o')) {
        Write-Host "Opening the credential prompt now..." -ForegroundColor Yellow
        $cred = Get-Credential -Message "Enter credentials to run the analysis as a different user"
        if (-not $cred) {
            Write-Error "No credentials provided (dialog was cancelled). Aborting."
            exit 1
        }
        Write-Host "Credentials received for user: $($cred.UserName)" -ForegroundColor Green

        Write-Host "Relaunching the analysis as '$($cred.UserName)' ..." -ForegroundColor Yellow

        $relaunchArgs = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
            '-FolderPath', "`"$FolderPath`"",
            '-OutputPath', "`"$OutputPath`"",
            '-TopExtensions', $TopExtensions,
            '-ElevatedRelaunch'
        )
        if ($IncludeOwner) { $relaunchArgs += '-IncludeOwner' }

        try {
            # Note: -Credential cannot be combined with -NoNewWindow, so this opens
            # a separate console window running under the chosen account.
            Start-Process -FilePath 'powershell.exe' -Credential $cred -ArgumentList $relaunchArgs -Wait -ErrorAction Stop
            Write-Host "Analysis finished under the alternate user account. Check the output path for the report." -ForegroundColor Green
        } catch {
            Write-Error "Could not start the analysis as '$($cred.UserName)': $($_.Exception.Message)"
        }
        exit
    } else {
        Write-Host "Using current user context ($env:USERDOMAIN\$env:USERNAME)." -ForegroundColor Green
    }
}

if (-not (Test-Path $FolderPath)) {
    Write-Error "Folder '$FolderPath' does not exist."
    exit 1
}

$scriptStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

Write-Host "Analyzing folder: $FolderPath" -ForegroundColor Cyan
Write-Host "Please wait..." -ForegroundColor Yellow

function Format-Duration {
    param([TimeSpan]$Span)
    if ($Span.TotalHours -ge 1) { return $Span.ToString('hh\:mm\:ss') }
    return $Span.ToString('mm\:ss')
}

# Scan phase: total file count is unknown in advance, so we show a live counter
# with elapsed time instead of a percentage/ETA.
$scanStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
$scanCount = 0
$lastScanUpdate = [DateTime]::MinValue

Get-ChildItem -Path $FolderPath -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    $files.Add($_)
    $scanCount++
    $nowTick = Get-Date
    if (($nowTick - $lastScanUpdate).TotalMilliseconds -gt 150) {
        Write-Progress -Activity "Scanning folder" `
            -Status "$scanCount files found - elapsed $(Format-Duration $scanStopwatch.Elapsed)"
        $lastScanUpdate = $nowTick
    }
}
Write-Progress -Activity "Scanning folder" -Completed
$scanStopwatch.Stop()
Write-Host "Scan finished: $scanCount files found in $(Format-Duration $scanStopwatch.Elapsed)." -ForegroundColor Cyan

$totalFiles = $files.Count
$now = Get-Date

if ($totalFiles -eq 0) {
    Write-Warning "No files found."
    exit 0
}

# ------------------------------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------------------------------

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1TB) { return "{0:N2} TB" -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes Bytes"
}

function ToGiB {
    param([long]$Bytes)
    [math]::Round($Bytes / 1GB, 3)
}

# ------------------------------------------------------------------------------------
# Age breakdown (1 / 3 / 5 years)
# ------------------------------------------------------------------------------------

$threshold1Year  = $now.AddYears(-1)
$threshold3Years = $now.AddYears(-3)
$threshold5Years = $now.AddYears(-5)

$olderThan1Year  = $files | Where-Object { $_.LastWriteTime -lt $threshold1Year }
$olderThan3Years = $files | Where-Object { $_.LastWriteTime -lt $threshold3Years }
$olderThan5Years = $files | Where-Object { $_.LastWriteTime -lt $threshold5Years }

$totalSize  = ($files | Measure-Object -Property Length -Sum).Sum
$size1Year  = ($olderThan1Year  | Measure-Object -Property Length -Sum).Sum
$size3Years = ($olderThan3Years | Measure-Object -Property Length -Sum).Sum
$size5Years = ($olderThan5Years | Measure-Object -Property Length -Sum).Sum

if (-not $totalSize)  { $totalSize  = 0 }
if (-not $size1Year)  { $size1Year  = 0 }
if (-not $size3Years) { $size3Years = 0 }
if (-not $size5Years) { $size5Years = 0 }

$pct1Year  = if ($totalSize -gt 0) { [math]::Round(($size1Year  / $totalSize) * 100, 1) } else { 0 }
$pct3Years = if ($totalSize -gt 0) { [math]::Round(($size3Years / $totalSize) * 100, 1) } else { 0 }
$pct5Years = if ($totalSize -gt 0) { [math]::Round(($size5Years / $totalSize) * 100, 1) } else { 0 }

# ------------------------------------------------------------------------------------
# File type breakdown (by bytes and by count)
# ------------------------------------------------------------------------------------

$byExtensionAll = $files | Group-Object Extension | ForEach-Object {
    $ext = if ($_.Name -eq '') { '(none)' } else { $_.Name.ToLower() }
    $size = ($_.Group | Measure-Object -Property Length -Sum).Sum
    [PSCustomObject]@{
        FileType = $ext
        Count    = $_.Count
        Size     = $size
    }
}

$byExtensionBytes = $byExtensionAll | Sort-Object Size -Descending
$byExtensionCount = $byExtensionAll | Sort-Object Count -Descending

function Get-TopWithOther {
    param($SortedList, [string]$ValueField, [int]$Top)
    $topItems = $SortedList | Select-Object -First $Top
    $rest = $SortedList | Select-Object -Skip $Top
    $restSum = ($rest | Measure-Object -Property $ValueField -Sum).Sum
    if (-not $restSum) { $restSum = 0 }
    $result = @()
    foreach ($item in $topItems) { $result += $item }
    if ($restSum -gt 0) {
        $result += [PSCustomObject]@{
            FileType = 'Other'
            Count    = ($rest | Measure-Object -Property Count -Sum).Sum
            Size     = ($rest | Measure-Object -Property Size -Sum).Sum
        }
    }
    return $result
}

$topByBytes = Get-TopWithOther -SortedList $byExtensionBytes -ValueField 'Size'  -Top $TopExtensions
$topByCount = Get-TopWithOther -SortedList $byExtensionCount -ValueField 'Count' -Top $TopExtensions

# Table: Top 100 by count with % of files
$top100ByCount = $byExtensionCount | Select-Object -First 100 | ForEach-Object {
    [PSCustomObject]@{
        FileType   = $_.FileType
        Count      = $_.Count
        PercentOfFiles = if ($totalFiles -gt 0) { [math]::Round(($_.Count / $totalFiles) * 100, 2) } else { 0 }
    }
}

# ------------------------------------------------------------------------------------
# Owner breakdown (optional, via Get-Acl)
# ------------------------------------------------------------------------------------

$ownerData = @()
if ($IncludeOwner) {
    Write-Host "Determining file owners (this can take a while for many files)..." -ForegroundColor Yellow

    $ownerTotal = $files.Count
    $ownerSw = [System.Diagnostics.Stopwatch]::StartNew()
    $ownerRaw = New-Object System.Collections.Generic.List[object]
    $lastOwnerUpdate = [DateTime]::MinValue

    for ($i = 0; $i -lt $ownerTotal; $i++) {
        $f = $files[$i]
        try {
            $owner = (Get-Acl -Path $f.FullName -ErrorAction Stop).Owner
        } catch {
            $owner = 'Unknown'
        }
        $ownerRaw.Add([PSCustomObject]@{ Owner = $owner; Length = $f.Length })

        $nowTick = Get-Date
        if (($nowTick - $lastOwnerUpdate).TotalMilliseconds -gt 150 -or $i -eq ($ownerTotal - 1)) {
            $done = $i + 1
            $percent = [math]::Min(100, [math]::Round(($done / $ownerTotal) * 100, 1))
            $avgPerItem = $ownerSw.Elapsed.TotalSeconds / $done
            $remaining = [TimeSpan]::FromSeconds([math]::Max(0, $avgPerItem * ($ownerTotal - $done)))
            Write-Progress -Activity "Determining file owners" `
                -Status "$done / $ownerTotal ($percent%) - ETA $(Format-Duration $remaining)" `
                -PercentComplete $percent
            $lastOwnerUpdate = $nowTick
        }
    }
    Write-Progress -Activity "Determining file owners" -Completed
    $ownerSw.Stop()
    Write-Host "Owner lookup finished in $(Format-Duration $ownerSw.Elapsed)." -ForegroundColor Cyan

    $ownerGroups = $ownerRaw | Group-Object Owner | ForEach-Object {
        [PSCustomObject]@{
            Owner = $_.Name
            Size  = ($_.Group | Measure-Object -Property Length -Sum).Sum
            Count = $_.Count
        }
    } | Sort-Object Size -Descending

    $ownerTopRaw = Get-TopWithOther -SortedList ($ownerGroups | ForEach-Object {
        [PSCustomObject]@{ FileType = $_.Owner; Count = $_.Count; Size = $_.Size }
    }) -ValueField 'Size' -Top 8

    $ownerData = $ownerTopRaw | ForEach-Object {
        [PSCustomObject]@{ Owner = $_.FileType; Count = $_.Count; Size = $_.Size }
    }
}

# ------------------------------------------------------------------------------------
# Long-term trend (cumulative size per month, by LastWriteTime)
# ------------------------------------------------------------------------------------

$monthlyBuckets = $files | Group-Object { $_.LastWriteTime.ToString('yyyy-MM') } | ForEach-Object {
    [PSCustomObject]@{
        Month = $_.Name
        Size  = ($_.Group | Measure-Object -Property Length -Sum).Sum
    }
} | Sort-Object Month

$cumulative = 0
$trendLabels = @()
$trendValues = @()
foreach ($bucket in $monthlyBuckets) {
    $cumulative += $bucket.Size
    $trendLabels += $bucket.Month
    $trendValues += ToGiB $cumulative
}

# ------------------------------------------------------------------------------------
# Top 10 largest files
# ------------------------------------------------------------------------------------

$top10 = $files | Sort-Object Length -Descending | Select-Object -First 10 | ForEach-Object {
    [PSCustomObject]@{
        Name     = $_.FullName
        Size     = Format-Size $_.Length
        Modified = $_.LastWriteTime.ToString('yyyy-MM-dd')
    }
}

# ------------------------------------------------------------------------------------
# Prepare JSON data for charts
# ------------------------------------------------------------------------------------

$colorPalette = @('#0d2b45','#f5b400','#1d9a9a','#b5136f','#e2665a','#8a7530','#a8d66b','#4caf50','#66d19e','#29b6c7','#c9c9c9')

$typeByBytesJson = ($topByBytes | ForEach-Object { [PSCustomObject]@{ label = $_.FileType; value = ToGiB $_.Size; valueRaw = $_.Size } }) | ConvertTo-Json -Compress
$typeByCountJson = ($topByCount | ForEach-Object { [PSCustomObject]@{ label = $_.FileType; value = $_.Count } }) | ConvertTo-Json -Compress
$ownerJson       = ($ownerData  | ForEach-Object { [PSCustomObject]@{ label = $_.Owner;    value = ToGiB $_.Size; valueRaw = $_.Size } }) | ConvertTo-Json -Compress
$trendJson       = [PSCustomObject]@{ labels = $trendLabels; values = $trendValues } | ConvertTo-Json -Compress
$top100Json      = $top100ByCount | ConvertTo-Json -Compress
$top10Json       = $top10 | ConvertTo-Json -Compress
$colorsJson      = $colorPalette | ConvertTo-Json -Compress

if ($typeByBytesJson -notmatch '^\[') { $typeByBytesJson = "[$typeByBytesJson]" }
if ($typeByCountJson -notmatch '^\[') { $typeByCountJson = "[$typeByCountJson]" }
if ($ownerJson       -notmatch '^\[') { $ownerJson       = "[$ownerJson]" }
if ($top100Json      -notmatch '^\[') { $top100Json      = "[$top100Json]" }
if ($top10Json       -notmatch '^\[') { $top10Json       = "[$top10Json]" }

$hasOwnerData = if ($ownerData.Count -gt 0) { 'true' } else { 'false' }

# ------------------------------------------------------------------------------------
# HTML template (static, placeholders are replaced afterwards)
# ------------------------------------------------------------------------------------

$htmlTemplate = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Folder Analysis: __FOLDERPATH__</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
<style>
  :root {
    --navy:#0d2b45; --gold:#f5b400; --teal:#1d9a9a; --magenta:#b5136f;
    --bg:#f4f6f8; --card:#ffffff; --text:#1e2530; --muted:#6b7684; --border:#e3e7ec;
  }
  * { box-sizing: border-box; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
  body {
    margin:0; padding:32px; background:var(--bg); color:var(--text);
    font-family: 'Segoe UI', Roboto, Arial, sans-serif;
  }
  .print-btn {
    position:fixed; top:20px; right:20px; z-index:100;
    background:var(--navy); color:#fff; border:none; border-radius:8px;
    padding:10px 18px; font-size:14px; font-weight:600; cursor:pointer;
    box-shadow:0 2px 6px rgba(0,0,0,0.15);
  }
  .print-btn:hover { background:#123a5e; }
  h1 { font-size:26px; margin:0 0 4px 0; color:var(--navy); }
  .subtitle { color:var(--muted); margin-bottom:28px; font-size:14px; }
  .grid { display:grid; grid-template-columns: repeat(3, 1fr); gap:18px; margin-bottom:24px; }
  .stat-card {
    background:var(--card); border:1px solid var(--border); border-radius:12px;
    padding:20px; box-shadow:0 1px 3px rgba(0,0,0,0.04);
  }
  .stat-card .label { color:var(--muted); font-size:13px; margin-bottom:6px; text-transform:uppercase; letter-spacing:0.03em;}
  .stat-card .value { font-size:28px; font-weight:700; color:var(--navy); }
  .stat-card .sub { font-size:13px; color:var(--muted); margin-top:4px; }
  .card {
    background:var(--card); border:1px solid var(--border); border-radius:12px;
    padding:24px; margin-bottom:24px; box-shadow:0 1px 3px rgba(0,0,0,0.04);
  }
  .card h2 { margin-top:0; font-size:18px; color:var(--navy); }
  .callout {
    background:#fff7e0; border:1px solid #f5d98a; border-radius:10px; padding:16px 20px;
    font-size:16px; font-weight:600; color:#7a5b00; margin:16px 0;
  }
  .two-col { display:grid; grid-template-columns: 1fr 1fr; gap:24px; }
  table { width:100%; border-collapse:collapse; font-size:14px; }
  th, td { text-align:left; padding:8px 10px; border-bottom:1px solid var(--border); }
  th { color:var(--muted); font-weight:600; text-transform:uppercase; font-size:11px; letter-spacing:0.03em; }
  td.num, th.num { text-align:right; }
  .filename { word-break:break-all; font-size:13px; }
  .age-bars { display:flex; flex-direction:column; gap:14px; }
  .age-row { display:grid; grid-template-columns: 110px 1fr 90px; align-items:center; gap:12px; }
  .age-row .bar-bg { background:#eef1f4; border-radius:6px; height:16px; overflow:hidden; }
  .age-row .bar-fill { height:100%; border-radius:6px; background:linear-gradient(90deg, var(--navy), var(--teal)); }
  .age-row .pct { text-align:right; font-weight:600; color:var(--navy); }
  .scroll-table { max-height:420px; overflow-y:auto; }
  footer { text-align:center; color:var(--muted); font-size:12px; margin-top:20px; }
  canvas { max-width:100%; }
  .chart-print-img { display:none; max-width:100%; height:auto; }
  .chart-print-img.is-active { display:block; margin:0 auto; }

  @media print {
    @page { size: A4 portrait; margin: 14mm; }
    body { padding:0; background:#fff; }
    .print-btn { display:none; }
    .card, .stat-card { box-shadow:none; border:1px solid #d8dde3; }
    .grid { break-inside: avoid; page-break-inside: avoid; }
    .two-col { display:block; }
    .scroll-table { max-height:none; overflow:visible; }
    table { font-size:12px; }
    tr, td, th { break-inside: avoid; }
    .card h2 { break-after: avoid; }

    /* Charts are never split across a page break */
    .chart-page { break-inside: avoid; page-break-inside: avoid; }
    /* Each of these charts starts on its own fresh page */
    .chart-page-new {
      break-before: page; page-break-before: always;
      break-inside: avoid; page-break-inside: avoid;
    }
  }
</style>
</head>
<body>

<button class="print-btn" onclick="printReport()">Save as PDF / Print</button>

<h1>Folder Analysis Report</h1>
<div class="subtitle">Folder: <strong>__FOLDERPATH__</strong> &nbsp;|&nbsp; Generated on __TIMESTAMP__</div>

<div class="grid">
  <div class="stat-card">
    <div class="label">Total Files</div>
    <div class="value">__TOTALFILES__</div>
  </div>
  <div class="stat-card">
    <div class="label">Total Size</div>
    <div class="value">__TOTALSIZE__</div>
  </div>
  <div class="stat-card">
    <div class="label">Older than 1 Year</div>
    <div class="value">__PCT1__%</div>
    <div class="sub">__SIZE1__ (__COUNT1__ files)</div>
  </div>
</div>

<div class="card chart-page">
  <h2>Long-term Trend (cumulative size)</h2>
  <div class="callout">__PCT1__% of data has not been modified for at least 12 months.</div>
  <canvas id="trendChart" height="90"></canvas>
  <img id="trendChart_img" class="chart-print-img" alt="Long-term trend chart">
</div>

<div class="card">
  <h2>Breakdown by Age</h2>
  <div class="age-bars">
    <div class="age-row">
      <div>Older than 1 year</div>
      <div class="bar-bg"><div class="bar-fill" style="width:__PCT1__%"></div></div>
      <div class="pct">__PCT1__%</div>
    </div>
    <div class="age-row">
      <div>Older than 3 years</div>
      <div class="bar-bg"><div class="bar-fill" style="width:__PCT3__%"></div></div>
      <div class="pct">__PCT3__%</div>
    </div>
    <div class="age-row">
      <div>Older than 5 years</div>
      <div class="bar-bg"><div class="bar-fill" style="width:__PCT5__%"></div></div>
      <div class="pct">__PCT5__%</div>
    </div>
  </div>
  <table style="margin-top:20px;">
    <tr><th>Period</th><th class="num">Count</th><th class="num">Size</th><th class="num">Share</th></tr>
    <tr><td>Older than 1 year</td><td class="num">__COUNT1__</td><td class="num">__SIZE1__</td><td class="num">__PCT1__%</td></tr>
    <tr><td>Older than 3 years</td><td class="num">__COUNT3__</td><td class="num">__SIZE3__</td><td class="num">__PCT3__%</td></tr>
    <tr><td>Older than 5 years</td><td class="num">__COUNT5__</td><td class="num">__SIZE5__</td><td class="num">__PCT5__%</td></tr>
  </table>
</div>

<div class="two-col">
  <div class="card chart-page-new">
    <h2>File Type Breakdown (by Bytes)</h2>
    <canvas id="typeBytesChart"></canvas>
    <img id="typeBytesChart_img" class="chart-print-img" alt="File type breakdown by bytes">
  </div>
  <div class="card chart-page-new">
    <h2>File Type Breakdown (by Count)</h2>
    <canvas id="typeCountChart"></canvas>
    <img id="typeCountChart_img" class="chart-print-img" alt="File type breakdown by count">
  </div>
</div>

__OWNER_SECTION__

<div class="card">
  <h2>Top 100 File Types by Count</h2>
  <div class="scroll-table">
    <table>
      <tr><th>Rank</th><th>Type</th><th class="num">Count</th><th class="num">% of Files</th></tr>
      <tbody id="top100Body"></tbody>
    </table>
  </div>
</div>

<div class="card">
  <h2>Top 10 Largest Files</h2>
  <table>
    <tr><th>Rank</th><th>File</th><th class="num">Size</th><th class="num">Modified</th></tr>
    <tbody id="top10Body"></tbody>
  </table>
</div>

<footer>Generated by the Folder Analysis Script &mdash; __TIMESTAMP__</footer>

<script>
const colors = __COLORS__;
const trend = __TREND__;
const typeBytes = __TYPEBYTES__;
const typeCount = __TYPECOUNT__;
const owner = __OWNER__;
const top100 = __TOP100__;
const top10 = __TOP10__;
const hasOwnerData = __HASOWNER__;

const charts = {};

charts.trendChart = new Chart(document.getElementById('trendChart'), {
  type: 'bar',
  data: {
    labels: trend.labels,
    datasets: [{
      label: 'Cumulative Size (GiB)',
      data: trend.values,
      backgroundColor: '#7fb3d5',
      borderRadius: 2
    }]
  },
  options: {
    responsive: true,
    animation: false,
    plugins: { legend: { display: false } },
    scales: {
      x: { ticks: { maxTicksLimit: 14 }, grid: { display: false } },
      y: { title: { display: true, text: 'GiB (cumulative)' } }
    }
  }
});

function makePie(canvasId, dataArr, unit) {
  charts[canvasId] = new Chart(document.getElementById(canvasId), {
    type: 'pie',
    data: {
      labels: dataArr.map(d => d.label + ' (' + d.value + (unit ? ' ' + unit : '') + ')'),
      datasets: [{
        data: dataArr.map(d => d.value),
        backgroundColor: colors
      }]
    },
    options: {
      responsive: true,
      animation: false,
      plugins: { legend: { position: 'right', labels: { boxWidth: 14, font: { size: 11 } } } }
    }
  });
}

makePie('typeBytesChart', typeBytes, 'GiB');
makePie('typeCountChart', typeCount, '');
if (hasOwnerData) { makePie('ownerChart', owner, 'GiB'); }

// Print / Save-as-PDF fix: canvases don't reliably reflow in the print engine,
// so we swap each canvas for a static snapshot image right before printing.
// Visibility is toggled directly via JS (not only CSS) so exactly one of
// canvas/image is ever visible, regardless of how the PDF/print is generated.
function prepareChartsForPrint() {
  Object.keys(charts).forEach(id => {
    const canvasEl = document.getElementById(id);
    const img = document.getElementById(id + '_img');
    if (img && canvasEl) {
      img.src = charts[id].toBase64Image('image/png', 1);
      img.classList.add('is-active');
      canvasEl.style.display = 'none';
    }
  });
}
function restoreChartsAfterPrint() {
  Object.keys(charts).forEach(id => {
    const canvasEl = document.getElementById(id);
    const img = document.getElementById(id + '_img');
    if (img && canvasEl) {
      img.classList.remove('is-active');
      img.removeAttribute('src');
      canvasEl.style.display = '';
    }
  });
}
window.addEventListener('beforeprint', prepareChartsForPrint);
window.addEventListener('afterprint', restoreChartsAfterPrint);

function printReport() {
  prepareChartsForPrint();
  // give the browser a moment to apply the display changes before the print dialog opens
  setTimeout(() => window.print(), 50);
}



const top100Body = document.getElementById('top100Body');
top100.forEach((row, i) => {
  const tr = document.createElement('tr');
  tr.innerHTML = `<td>${i+1}</td><td>${row.FileType}</td><td class="num">${row.Count}</td><td class="num">${row.PercentOfFiles}%</td>`;
  top100Body.appendChild(tr);
});

const top10Body = document.getElementById('top10Body');
top10.forEach((row, i) => {
  const tr = document.createElement('tr');
  tr.innerHTML = `<td>${i+1}</td><td class="filename">${row.Name}</td><td class="num">${row.Size}</td><td class="num">${row.Modified}</td>`;
  top10Body.appendChild(tr);
});
</script>

</body>
</html>
'@

$ownerSection = ""
if ($IncludeOwner -and $ownerData.Count -gt 0) {
    $ownerSection = @'
<div class="card chart-page-new">
  <h2>File Owner Breakdown</h2>
  <canvas id="ownerChart"></canvas>
  <img id="ownerChart_img" class="chart-print-img" alt="File owner breakdown">
</div>
'@
}

# ------------------------------------------------------------------------------------
# Replace placeholders
# ------------------------------------------------------------------------------------

$html = $htmlTemplate
$html = $html.Replace('__FOLDERPATH__', $FolderPath)
$html = $html.Replace('__TIMESTAMP__', (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$html = $html.Replace('__TOTALFILES__', $totalFiles)
$html = $html.Replace('__TOTALSIZE__', (Format-Size $totalSize))
$html = $html.Replace('__PCT1__', $pct1Year)
$html = $html.Replace('__PCT3__', $pct3Years)
$html = $html.Replace('__PCT5__', $pct5Years)
$html = $html.Replace('__COUNT1__', $olderThan1Year.Count)
$html = $html.Replace('__COUNT3__', $olderThan3Years.Count)
$html = $html.Replace('__COUNT5__', $olderThan5Years.Count)
$html = $html.Replace('__SIZE1__', (Format-Size $size1Year))
$html = $html.Replace('__SIZE3__', (Format-Size $size3Years))
$html = $html.Replace('__SIZE5__', (Format-Size $size5Years))
$html = $html.Replace('__OWNER_SECTION__', $ownerSection)
$html = $html.Replace('__COLORS__', $colorsJson)
$html = $html.Replace('__TREND__', $trendJson)
$html = $html.Replace('__TYPEBYTES__', $typeByBytesJson)
$html = $html.Replace('__TYPECOUNT__', $typeByCountJson)
$html = $html.Replace('__OWNER__', $(if ($ownerJson) { $ownerJson } else { '[]' }))
$html = $html.Replace('__TOP100__', $top100Json)
$html = $html.Replace('__TOP10__', $top10Json)
$html = $html.Replace('__HASOWNER__', $hasOwnerData)

# ------------------------------------------------------------------------------------
# Save
# ------------------------------------------------------------------------------------

$html | Out-File -FilePath $OutputPath -Encoding UTF8
Write-Host "`nHTML report saved to: $OutputPath" -ForegroundColor Green

# Optional: CSV export of the file type breakdown (as in the original script)
$csvPath = $OutputPath -replace '\.html$', '_FileTypes.csv'
$byExtensionBytes | Select-Object FileType, Count, @{N='Size_Bytes';E={$_.Size}} |
    Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Host "CSV export saved to: $csvPath" -ForegroundColor Green

$scriptStopwatch.Stop()
Write-Host "Total processing time: $(Format-Duration $scriptStopwatch.Elapsed)" -ForegroundColor Cyan

# Open HTML in default browser
try { Invoke-Item $OutputPath } catch { }