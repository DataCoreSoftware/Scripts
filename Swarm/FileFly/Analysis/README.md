# Folder Analysis (filefly-analyzer)

PowerShell script that analyzes a folder: file age, storage usage by file type, and
(optionally) by owner. The result is an interactive HTML report with charts plus a
CSV export of the file type breakdown.

## Features

- Age breakdown: share of data older than 1 / 3 / 5 years
- File type distribution by size and count (pie charts, top N + "Other")
- Long-term trend: cumulative storage size per month
- Top 10 largest files
- Optional: owner distribution (via `Get-Acl`, slow for large file counts)
- Export as HTML report (with Chart.js) and CSV

## Usage

```powershell
.\Folder-Analysis-HTML.ps1 -FolderPath "D:\Shares\Projects"
```

### Parameters

| Parameter         | Required | Default                                       | Description |
|-------------------|:--------:|------------------------------------------------|--------------|
| `-FolderPath`      | Yes      | –                                               | Folder to analyze |
| `-OutputPath`      | No       | `.\FolderAnalysis_<timestamp>.html`             | Path of the HTML report |
| `-IncludeOwner`    | No       | disabled                                        | Additionally determines storage distribution by file owner |
| `-TopExtensions`   | No       | `10`                                             | Number of file types shown individually; the rest are grouped as "Other" |

### Example with owner breakdown

```powershell
.\Folder-Analysis-HTML.ps1 -FolderPath "\\server\share" -IncludeOwner -TopExtensions 15
```

The report opens automatically in the default browser once generated.

## Output

- `FolderAnalysis_<timestamp>.html` – interactive report
- `FolderAnalysis_<timestamp>_Dateitypen.csv` – file type statistics as CSV

Both files are ignored by Git (see `.gitignore`).
