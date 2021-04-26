# Main Code
# Initializing DataCore PowerShell Environment 
$bpKey = 'BaseProductKey'
$regKey = get-Item "HKLM:\Software\DataCore\Executive"
$strProductKey = $regKey.getValue($bpKey)
$regKey = get-Item "HKLM:\$strProductKey"
$installPath = $regKey.getValue('InstallPath')
Import-Module "$installPath\DataCore.Executive.Cmdlets.dll" -ErrorAction:Stop -Warningaction:SilentlyContinue


$perfs_import =  @()
$perfs =  @()

if (Test-Path Size-CDP-Log.csv){

$perfs_import = Import-Csv Size-CDP-Log.csv | Foreach-Object {
   $_.CollectionTime = $_.CollectionTime -as [datetime]
   $_
}
write-host -ForegroundColor Green "Second execution, show data:"
}
else
{
write-host -ForegroundColor Green "Fist execution, collecting data ..."
}


[System.Reflection.Assembly]::LoadWithPartialName('Microsoft.VisualBasic') | Out-Null
$server = "localhost" # [Microsoft.VisualBasic.Interaction]::InputBox("Enter a DataCore server name or IP", "Server", "$env:computername")

#$Credential = get-Credential

$connect = Connect-DcsServer -Server $server # -Credential $Credential


$vdisks = Get-dcsvirtualdisk

foreach($vdisk in $vdisks) 
{ 

$perf = $vdisk | Get-DcsPerformanceCounter

    $perfs += New-Object PsObject -Property @{ 
        'Caption' = $vdisk.Caption
        'TotalBytesWritten' = $perf.TotalBytesWritten 
        'CollectionTime' = $perf.CollectionTime 
    } 

 }


if (Test-Path Size-CDP-Log.csv){

        foreach($perf in $perfs) 
                { 
                Add-content result_Size-CDP-Log.txt -value "Second execution, show data:"
                write-host ""
                Add-content result_Size-CDP-Log.txt -value ""
                write-host -ForegroundColor Green "--------------------------------------------------------"
                Add-content result_Size-CDP-Log.txt -value "--------------------------------------------------------"
                write-host ""
                Add-content result_Size-CDP-Log.txt -value ""
                write-host -ForegroundColor Green "vDisk: " $perf.Caption ""
                $content =  "vDisk: " + $perf.Caption
                Add-content result_Size-CDP-Log.txt -value $content
                write-host ""
                Add-content result_Size-CDP-Log.txt -value ""
                $perf_import = $perfs_import | where { $_.Caption -eq $perf.Caption }
                if ($perf_import){
                        $TimeRange = $perf.CollectionTime - $perf_import.CollectionTime 
                        write-host -ForegroundColor Green "Time range beetween two execution: " $TimeRange.Days " Day(s), " $TimeRange.Hours " Hour(s), " $TimeRange.Minutes " Minute(s), " $TimeRange.Seconds " Seconds"
                        $content =  "Time range beetween two execution: " + $TimeRange.Days + " Day(s), " + $TimeRange.Hours + " Hour(s), " + $TimeRange.Minutes + " Minute(s), " + $TimeRange.Seconds + " Seconds"
                        Add-content result_Size-CDP-Log.txt -value $content
                        $GB_Written = $perf.TotalBytesWritten - $perf_import.TotalBytesWritten
                        $GB_Written = $GB_Written / 1024 /1024 /1024
                        write-host -ForegroundColor Green "GB Written between time range :" $GB_Written
                        $content =  "GB Written between time range :" + $GB_Written
                        Add-content result_Size-CDP-Log.txt -value $content
                        } else {
                        write-host -ForegroundColor Red "vDisk not present in data collection"
                        Add-content result_Size-CDP-Log.txt -value "vDisk not present in data collection"
                        }
                }

Remove-Item Size-CDP-Log.csv
Pause

}
else{
        $perfs | export-csv Size-CDP-Log.csv
        write-host ""
        write-host -ForegroundColor Green "Data are collected and store in Size-CDP-Log.csv"
}



Disconnect-DcsServer
