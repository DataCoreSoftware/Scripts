<#
    .SYNOPSIS
        This script collects the DataCore SANsymphony metrics and stores it to DcsPrometheusMetrics.prom file
    .DESCRIPTION
        This script fetches data from the DataCore SANsymphony REST API, formats it into Prometheus metrics, and saves it to a DcsPrometheusMetrics.prom file for monitoring purposes. By default, it retives metrics every 120 seconds.
    .CONFIGURATION FILE
        DcsPrometheusExporter.psd1
    .PARAMETER
        LogToFile
            [bool] To store log messages in the file (optional).
        RunOnce
            [switch] Runs the script only once (optional).
    .PREREQUISITE 
        
    .COMMAND TO RUN
        ./DcsPrometheusExporter.ps1
    .Output
        The collected metrics will be stored in DcsPrometheusMetrics.prom file
    Written by: Palegar Nikhil
    Email: palegar.nikhil@datacore.com
#>

param(
    [bool] $LogToFile = $true,
    [switch] $RunOnce
)


#Logging
$logFile = Join-Path -Path $PSScriptRoot -ChildPath "\logs\DcsPrometheusExporter.log"

if (-not(Test-Path $logFile)) {
    try{
        # Create an empty log file
        New-Item -Path $logFile -ItemType File -Force | Out-Null
    }
    catch {
        Write-Log "Failed to create log file $($logFile) : $($_.Exception.Message)"
        exit
    }
    
}

function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    
    $archiveFile = (Join-Path -Path $PSScriptRoot -ChildPath "\logs\DcsPrometheusExporter_{0}.log") -f ((Get-Date).AddDays(-1).ToString("yyyyMMdd"))

    if ($LogToFile -and (Test-Path $logFile)) {
        if ((Get-Date).Date -ne (Get-Item $logFile).LastWriteTime.Date) {
            Move-Item -Path $logFile -Destination $archiveFile
        }

        Get-ChildItem -Path (Join-Path -Path $PSScriptRoot -ChildPath "\logs") -Filter "DcsPrometheusExporter_*.log" | Where-Object {
            $_.LastWriteTime -lt (Get-Date).AddDays(-$logFileRetention)
        } | Remove-Item -Force
    }
    

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp [$Level] $Message"

    #Write to log file
    if($LogToFile) {
        try {
            $logMessage | Out-File -FilePath $logFile -Append
        }
        catch {
            Write-Log "Failed to write to log file $($logfile) : $($_.Exception.Message)"
        }
    }

    #Write to terminal
    Write-Host $logMessage
}

# Load the config
$configPath = "$PSScriptRoot\DcsPrometheusExporter.psd1"
if(-not(Test-Path $configPath)){
    Write-Log -Message "Configuration file $($configPath) not found" -Level "Error"
    exit
}
try {
    $config = Import-PowerShellDataFile -Path $configPath
}
catch {
    Write-Log -Message "Failed to load configuration file $($configPath) : $($_.Exception.Message)" -Level "Error"
    exit
}

# Use config values
# Rest Server and Credentials
$restServerip = $config.RESTServerIPAddress
if(-not $restServerip){
    Write-Log -Message "RESTServerIPAddress not specified in $($configPath)" -Level "Error"
    exit
}
$credentialTarget = $config.CredentialTarget
if(-not $credentialTarget){
    Write-Log -Message "CredentialTarget not specified in $($configPath)" -Level "Error"
}
$cred = Get-StoredCredential -Target $config.CredentialTarget
if (-not $cred) {
    Write-Log -Message "Credential $($credentialTarget) not found in Credential Manager" -Level "Error"
    Write-Log -Message "To add credentials, run the following commands:"
    Write-Log -Message "Install-Module -Name CredentialManager"
    Write-Log -Message "New-StoredCredential -Target '$($credentialTarget)' -UserName 'restserver-username' -Password 'restserver-password' -Persist LocalMachine"
    exit
}

$restServerUrl = "https://" + "$($restServerip)" + "/RestService/rest.svc/"
$header = @{
    "ServerHost" = $restServerip
    "Authorization" = "Basic " + "$($cred.UserName) " + "$($cred.GetNetworkCredential().Password)"
}

# Output Metric file path and Interval
$metricFilePath = $config.PromMetricsFilePath
if (-not $metricFilePath){
    Write-Log -Message "PromMetricsFilePath for .prom file not specified in $($configPath)" -Level "Error"
    exit
}

if (-not (Test-Path $metricFilePath)){
    Write-Log -Message "Path $($metricFilePath) doesn't exists for .prom file" -Level "Error"
    exit
}

$metricsFile = Join-Path -Path $config.PromMetricsFilePath -ChildPath "\DcsPrometheusMetrics.prom"
$tempMetricFile = Join-Path -Path $config.PromMetricsFilePath -ChildPath "\DcsPromMetrics.tmp"
$metricTimeInterval = $config.IntervalSeconds

# Get the Resources section which are true
$enabledResources = ($config.Resources.GetEnumerator() | Where-Object { $_.Value -eq $true }).Key
if(-not $enabledResources){
    Write-Log -Message "No rescources enabled for metric collection in $($configPath)" -Level "Warning"
    exit
}

# Check the log files retention time
$logFileRetention = $config.LogFileRetentionDays

#Invoke REST method
function InvokeRestAPI{
    param (
        # Parameter help description
        [Parameter(Mandatory = $true)]
        [String] $url
    )

    $response = $null

    $max_retries = 2
    for($i =0; $i -le $max_retries; $i++) {
        $response = Invoke-RestMethod -Uri $url -Headers $header -Method Get

        if($url -match "performance" -and $null -ne $response -and $response.Count -gt 0){
            $collectionTimeDate = $response[0].CollectionTime

            $collectionTimeYear = $collectionTimeDate.Year
    
            if($collectionTimeYear -gt 1){
                return $response
            }
            Write-Log -Message "Retrying performance data ($i of $max_retries)..."
            Start-Sleep 3
        }
        else {
            return $response
        }
    }

    Write-Log -Message "Failed to get valid PerformanceData for $($url)" -Level "Warning"
    return $response
}

# Function invokes REST API calls
function CallDcsRestAPI{
    param (
        # Parameter help description
        [Parameter(Mandatory = $true)]
        [String] $resourceUrl
    )
    $urlVersion = "2.0/"
    if ($resourceUrl -eq "ports" -or $resourceUrl -match "performance"){
        $urlVersion = "1.0/"
    }
    $url = $restServerUrl + $urlVersion + $resourceUrl

    try {
        $response = InvokeRestAPI($url)
        return $response
    }
    catch {
        if($_.Exception.Message -match "The underlying connection was closed: Could not establish trust relationship for the SSL/TLS secure channel."){
            try {
                # Bypassing the SSL certificate validation because the DataCore Rest service uses DataCoreSelfSignedCert
                Write-Log -Message "Bypassing SSL certificate validation" -Level "Warning"
                [System.Net.ServicePointManager]::ServerCertificateValidationCallback = [dummy]::GetDelegate()
                return InvokeRestAPI($url)
            }
            catch{
                Write-Log -Message "Failed to get data for $($resourceUrl). Status Code: $($_.Exception.Response.StatusCode). Error Message : $($_.Exception.Message)" -Level "Error"
                exit
            }
        }
        else {
            Write-Log -Message "Failed to get data for $($resourceUrl). Status Code: $($_.Exception.Response.StatusCode). Error Message : $($_.Exception.Message)" -Level "Error"
            exit
        }
    }
}

#Convert Server Data to Prometheus format
function ConvertServerDataToProm{
    param (
        # Parameter help description
        [PSCustomObject] $serverData
    )
    $serverMetrics = @{
        "State" = "gauge"
        "CacheState" = "gauge"
        "PowerState" = "gauge"
        "CacheSize" = "gauge"
        "TotalSystemMemory" = "gauge"
        "AvailableSystemMemory" = "gauge"
        "NullCounterMap" = "gauge"
        "InitiatorBytesTransferred" = "counter"
        "InitiatorBytesRead" = "counter"
        "InitiatorBytesWritten" = "counter"
        "InitiatorOperations" = "counter"
        "InitiatorReads" = "counter"
        "InitiatorWrites" = "counter"
        "TargetBytesTransferred" = "counter"
        "TargetBytesRead" = "counter"
        "TargetBytesWritten" = "counter"
        "TargetOperations" = "counter"
        "TargetReads" = "counter"
        "TargetWrites" = "counter"
        "TotalBytesMigrated" = "counter"
        "FreeCache" = "gauge"
        "CacheReadHits"  = "counter"
        "CacheReadMisses" = "counter"
        "CacheWriteHits" = "counter"
        "CacheWriteMisses" = "counter"
        "CacheReadHitBytes" = "counter"
        "CacheReadMissBytes" = "counter"
        "CacheWriteHitBytes" = "counter"
        "CacheWriteMissBytes" = "counter"
        "SupportRemainingBytesToSend" = "gauge"
        "SupportBytesSent" = "counter"
        "SupportPercentTransferred" = "gauge"
        "TotalBytesTransferred" = "counter"
        "TotalBytesRead" = "counter"
        "TotalBytesWritten" = "counter"
        "TotalOperations" = "counter"
        "TotalReads" = "counter"
        "TotalWrites" = "counter"
        "PollerProductiveCount" = "counter"
        "PollerUnproductiveCount" = "counter"
        "PollerDedicatedCPUs" = "gauge"
        "PollerLoad" = "gauge"
        "TargetMaxIOTime" = "gauge"
        "TargetTotalOperationsTime" = "gauge"
        "MirrorTargetMaxIOTime" = "gauge"
        "MirrorTargetTotalOperationsTime" = "gauge"
        "MirrorTargetBytesTransfered" = "counter"
        "MirrorTargetOperations" = "counter"
        "FrontEndTargetMaxIOTime" = "gauge"
        "FrontEndTargetBytesTransfered" = "counter"
        "FrontEndTargetOperations" = "counter"
        "FrontEndTargetTotalOperationsTime" = "gauge"
        "PoolMaxIOTime" = "gauge"
        "PoolTotalOperationsTime" = "gauge"
        "PoolBytesTransfered" = "counter"
        "PoolOperations" = "counter"
        "PhysicalDiskMaxIOTime" = "gauge"
        "PhysicalDiskBytesTransfered" = "counter"
        "PhysicalDiskOperations" = "counter"
        "PhysicalDiskTotalOperationsTime" = "gauge"
        "ReplicationBytesToSend" = "gauge"
        "ReplicationBufferPercentFreeSpace" = "gauge"
        "SupportPercentCollected" = "gauge"
        "DeduplicationRatioPercentage" = "gauge"
        "CompressionRatioPercentage" = "gauge"
        "DeduplicationPoolPercentFreeSpace" = "gauge"
        "DeduplicationPoolUsedSpace" = "gauge"
        "DeduplicationPoolFreeSpace" = "gauge"
        "DeduplicationPoolTotalSpace" = "gauge"
        "ExpectedDeduplicationPoolUsedSpace" = "gauge"
        "MaxReplicationTimeDifference" = "gauge"
        "DeduplicationPoolL2ARCUsedSpace" = "gauge"
        "DeduplicationPoolSpecialMirrorUsedSpace" = "gauge"
        "DeduplicationPoolL2ARCTotalSpace" = "gauge"
        "DeduplicationPoolSpecialMirrorTotalSpace" = "gauge"
     }
    $prom_serverMetric = @()

    # Static metadata metrics
    $infoData = @()
    $productData = @()
    $processorData = @()

    # Dynamic metrics
    $metricData = @{}

    $processor_data = @{
        0 = "Intel"
        6 = "IA64"
        9 = "AMD64"
        0xFFFF = "Unknown"
    }
    $metricPrefix = "datacore_server_"
    foreach($server in $serverData){
        if($null -eq $server.RegionNodeId){
            continue
        }
        $instance = $server.ExtendedCaption
        $caption = $server.Caption
        $osVersion = $server.OsVersion
        $productName = $server.ProductName
        $productversion = $server.ProductVersion
        $productType = $server.ProductType
        $server_id = $server.Id
        $processor = "{0}, {1} ({2} physical cores, {3} logical cores)" -f $server.ProcessorInfo.ProcessorName, $processor_data[$server.ProcessorInfo.CpuArchitecture], $server.ProcessorInfo.NumberPhysicalCores, $server.ProcessorInfo.NumberCores

        $infoData += "datacore_server_info{server=`"$instance`", caption=`"$caption`", os_version=`"$osVersion`"} 1"
        $productData += "datacore_server_product_info{server=`"$instance`", product_name=`"$productName`", product_version=`"$productversion`", product_type=`"$productType`"} 1"
        $processorData += "datacore_server_processor_info{server=`"$instance`", processor=`"$processor`"} 1"

        $global:IdMap[$server.Id] = $server.Caption
        $labelString =  "server=`"$instance`", id=`"$server_id`""

        $serverPerf = CallDcsRestAPI("performance/$($server_id)")

        foreach ($metric in $serverMetrics.Keys) {
            $name = $metricPrefix + ($metric).ToLower()

            if (-not $metricData.ContainsKey($metric)) {
                $metricData[$metric] = @()
            }

            if ($server.PSObject.Properties.Name -contains $metric -and $metric -ne "CacheSize"){
                if($server.($metric) -match "Value"){
                    $value = $server.($metric).Value
                }
                else {
                    $value = $server.($metric)
                }
            }
            else {
                $value = $serverPerf.($metric)
            }
    
            # Normalize booleans
            if ($value -is [bool]) {
                $value = if ($value) { 1 } else { 0 }
            }
    
            # Skip null or empty
            if ($null -ne $value -and "$value" -ne "") {
                $metricData[$metric] += "$name{$labelString} $value"
            }
        }
    }

    # Static HELP/TYPE
    $prom_serverMetric += "# HELP datacore_server_info Static metadata for the DataCore server"
    $prom_serverMetric += "# TYPE datacore_server_info gauge"
    $prom_serverMetric += ($infoData -join "`n") + "`n"

    $prom_serverMetric += "# HELP datacore_server_product_info Product info for the DataCore server"
    $prom_serverMetric += "# TYPE datacore_server_product_info gauge"
    $prom_serverMetric += ($productData -join "`n") + "`n"

    $prom_serverMetric += "# HELP datacore_server_processor_info Processor info for the DataCore server"
    $prom_serverMetric += "# TYPE datacore_server_processor_info gauge"
    $prom_serverMetric += ($processorData -join "`n") + "`n"

    # Dynamic metric HELP/TYPE
    foreach ($metric in $metricData.Keys) {
        $name = $metricPrefix + $metric.ToLower()
        $type = $serverMetrics[$metric]
        $prom_serverMetric += "# HELP $name DataCore server metric for $($metric)"
        $prom_serverMetric += "# TYPE $name $type"
        $prom_serverMetric += ($metricData[$metric] -join "`n") + "`n"
    }

    return $prom_serverMetric -join "`n"
}

#Convert Pool Data to Prometheus format
function ConvertPoolDataToProm{
    param (
        # Parameter help description
        [PSCustomObject] $poolData
    )
    $poolMetrics = @{
        "PoolStatus" = "gauge"
        "InSharedMode" = "gauge"
        "AutoTieringEnabled" = "gauge"
        "TierReservedPct" = "gauge"
        "ChunkSize" = "gauge"
        "MaxTierNumber" = "gauge"
        "NullCounterMap" = "gauge"
        "TotalBytesTransferred" = "counter"
        "TotalBytesRead" = "counter"
        "TotalBytesWritten" = "counter"
        "TotalBytesMigrated" = "counter"
        "TotalReads" = "counter"
        "TotalWrites" = "counter"
        "TotalOperations" = "counter"
        "BytesAllocated" = "gauge"
        "BytesAvailable" = "gauge"
        "BytesInReclamation" = "gauge"
        "BytesTotal" = "gauge"
        "PercentAllocated" = "gauge"
        "PercentAvailable" = "gauge"
        "TotalReadTime" = "counter"
        "TotalWriteTime" = "counter"
        "TotalOperationsTime" = "counter"
        "MaxReadTime" = "gauge"
        "MaxWriteTime" = "gauge"
        "MaxReadWriteTime" = "gauge"
        "MaxPoolBytes" = "gauge"
        "BytesReserved" = "gauge"
        "BytesAllocatedPercentage" = "gauge"
        "BytesReservedPercentage" = "gauge"
        "BytesInReclamationPercentage" = "gauge"
        "BytesAvailablePercentage" = "gauge"
        "BytesOverSubscribed" = "gauge"
        "EstimatedDepletionTime" = "gauge"
        "DeduplicationPoolPercentFreeSpace" = "gauge"
        "ExpectedDeduplicationPoolUsedSpace" = "gauge"
        "DeduplicationPoolUsedSpace" = "gauge"
        "DeduplicationPoolFreeSpace" = "gauge"
        "DeduplicationPoolTotalSpace" = "gauge"
     }
    $prom_poolMetric = @()

    # Static metadata metrics
    $infoData = @()

    # Dynamic metrics
    $metricData = @{}

    $metricPrefix = "datacore_pool_"
    foreach($pool in $poolData){
        $instance = $pool.ExtendedCaption
        $caption = $pool.Caption
        $pool_id = $pool.Id
        $server  = $global:IdMap[$pool.ServerId]

        $infoData += "datacore_pool_info{pool=`"$instance`", caption=`"$caption`", server=`"$server`"} 1"

        $labelString =  "pool=`"$instance`", id=`"$pool_id`""

        $poolPerf = CallDcsRestAPI("performance/$($pool_id)")

        foreach ($metric in $poolMetrics.Keys) {
            $name = $metricPrefix + ($metric).ToLower()

            if (-not $metricData.ContainsKey($metric)) {
                $metricData[$metric] = @()
            }

            if ($pool.PSObject.Properties.Name -contains $metric){
                if($pool.($metric) -match "Value"){
                    $value = $pool.($metric).Value
                }
                else {
                    $value = $pool.($metric)
                }
            }
            else {
                $value = $poolPerf.($metric)
            }
    
            # Normalize booleans
            if ($value -is [bool]) {
                $value = if ($value) { 1 } else { 0 }
            }
    
            # Skip null or empty
            if ($null -ne $value -and "$value" -ne "") {
                $metricData[$metric] += "$name{$labelString} $value"
            }
        }
    }

    # Static HELP/TYPE
    $prom_poolMetric += "# HELP datacore_pool_info Static metadata for the DataCore pool"
    $prom_poolMetric += "# TYPE datacore_pool_info gauge"
    $prom_poolMetric += ($infoData -join "`n") + "`n"

    # Dynamic metric HELP/TYPE
    foreach ($metric in $metricData.Keys) {
        $name = $metricPrefix + $metric.ToLower()
        $type = $poolMetrics[$metric]
        $prom_poolMetric += "# HELP $name DataCore pool metric for $($metric)"
        $prom_poolMetric += "# TYPE $name $type"
        $prom_poolMetric += ($metricData[$metric] -join "`n") + "`n"
    }

    return $prom_poolMetric -join "`n"
}

#Convert Virtual disk Data to Prometheus format
function ConvertVirtualDiskDataToProm{
    param (
        # Parameter help description
        [PSCustomObject] $virtualDiskData
    )
    $virtualDiskMetrics = @{
        "Size" = "gauge"
        "DiskStatus" = "gauge"
        "NullCounterMap" = "gauge"
        "TotalBytesTransferred" = "counter"
        "TotalBytesRead" = "counter"
        "TotalBytesWritten" = "counter"
        "TotalBytesMigrated" = "counter"
        "TotalReads" = "counter"
        "TotalWrites" = "counter"
        "TotalOperations" = "counter"
        "TotalOperationsTime" = "counter"
        "CacheReadHits" = "counter"
        "CacheReadMisses" = "counter"
        "CacheWriteHits" = "counter"
        "CacheWriteMisses" = "counter"
        "CacheReadHitBytes" = "counter"
        "CacheReadMissBytes" = "counter"
        "CacheWriteHitBytes" = "counter"
        "CacheWriteMissBytes" = "counter"
        "ReplicationBytesSent" = "counter"
        "ReplicationBytesToSend" = "gauge"
        "ReplicationTimeLag" = "gauge"
        "ReplicationTimeDifference" = "gauge"
        "InitializationPercentage" = "gauge"
        "TestModeProgressPercentage" = "gauge"
        "ConsistencyCheckPercentage" = "gauge"
        "BytesAllocated" = "gauge"
        "PercentAllocated" = "gauge"
        "BytesOutOfAffinity" = "gauge"
        "PercentBytesOutOfAffinity" = "gauge"
        "MaxReadWriteTime" = "gauge"
        "BytesTogglingEncryption" = "gauge"
        "PercentTogglingEncryption" = "gauge"
        "BytesOutOfSettings" = "gauge"
        "PercentBytesOutOfSettings" = "gauge"
     }
    $prom_virtualDiskMetric = @()

    # Static metadata metrics
    $infoData = @()

    # Dynamic metrics
    $metricData = @{}

    $metricPrefix = "datacore_virtualdisk_"
    foreach($virtualDisk in $virtualDiskData){
        if($null -eq $virtualDisk.StorageProfileId){
            continue
        }
        if(($virtualDisk.IsRollbackVirtualDisk) -and ($enabledResources -notcontains "rollbacks")){
            Write-Log -Message "Skipping metrics collection for rollback $($virtualDisk.Caption)"
            continue
        }
        if(($virtualDisk.IsSnapshotVirtualDisk) -and ($enabledResources -notcontains "snapshots")){
            Write-Log -Message "Skipping metrics collection for snapshot $($virtualDisk.Caption)"
            continue
        }
        $instance = $virtualDisk.ExtendedCaption
        $caption = $virtualDisk.Caption
        $scsiDeviceIdString  = $virtualDisk.ScsiDeviceIdString 
        $type  = $virtualDisk.Type
        $virtualDisk_id = $virtualDisk.Id
        $firstHost  = $global:IdMap[$virtualDisk.FirstHostId]
        $secondHost  = if ($virtualDisk.SecondHostId) { $global:IdMap[$virtualDisk.SecondHostId] } else { "N/A" }
        $backUpHost  = if ($virtualDisk.BackupHostId) { $global:IdMap[$virtualDisk.BackupHostId] } else { "N/A" }

        $infoData += "datacore_virtualdisk_info{virtualdisk=`"$instance`", caption=`"$caption`", scsi_device_id=`"$scsiDeviceIdString`", type=`"$type`", first_host=`"$firstHost`", second_host=`"$secondHost`", backup_host=`"$backUpHost`"} 1"

        $labelString =  "virtualdisk=`"$instance`", id=`"$virtualDisk_id`""

        $VirtualDiskPerf = CallDcsRestAPI("performance/$($virtualDisk_id)")

        foreach ($metric in $virtualDiskMetrics.Keys) {
            $name = $metricPrefix + ($metric).ToLower()

            if (-not $metricData.ContainsKey($metric)) {
                $metricData[$metric] = @()
            }

            if ($virtualDisk.PSObject.Properties.Name -contains $metric){
                if($virtualDisk.($metric) -match "Value"){
                    $value = $virtualDisk.($metric).Value
                }
                else {
                    $value = $virtualDisk.($metric)
                }
            }
            else {
                $value = $VirtualDiskPerf.($metric)
            }
    
            # Normalize booleans
            if ($value -is [bool]) {
                $value = if ($value) { 1 } else { 0 }
            }
    
            # Skip null or empty
            if ($null -ne $value -and "$value" -ne "") {
                $metricData[$metric] += "$name{$labelString} $value"
            }
        }
    }

    # Static HELP/TYPE
    $prom_virtualDiskMetric += "# HELP datacore_virtualdisk_info Static metadata for the DataCore virtual disk"
    $prom_virtualDiskMetric += "# TYPE datacore_virtualdisk_info gauge"
    $prom_virtualDiskMetric += ($infoData -join "`n") + "`n"

    # Dynamic metric HELP/TYPE
    foreach ($metric in $metricData.Keys) {
        $name = $metricPrefix + $metric.ToLower()
        $type = $virtualDiskMetrics[$metric]
        $prom_virtualDiskMetric += "# HELP $name DataCore virtual disk metric for $($metric)"
        $prom_virtualDiskMetric += "# TYPE $name $type"
        $prom_virtualDiskMetric += ($metricData[$metric] -join "`n") + "`n"
    }

    return $prom_virtualDiskMetric -join "`n"
}

function ConvertPhysicalDiskDataToProm{
    param (
        # Parameter help description
        [PSCustomObject] $physicalDiskData
    )
    $physicalDiskMetrics = @{
        "DiskStatus" = "gauge"
        "NullCounterMap" = "gauge"
        "TotalReadsTime" = "counter"
        "TotalWritesTime" = "counter"
        "TotalPendingCommands" = "gauge"
        "TotalReads" = "counter"
        "TotalWrites" = "counter"
        "TotalOperations" = "counter"
        "TotalBytesRead" = "counter"
        "TotalBytesWritten" = "counter"
        "TotalBytesTransferred" = "counter"
        "TotalOperationsTime" = "counter"
        "MaxReadTime" = "gauge"
        "MaxWriteTime" = "gauge"
        "MaxReadWriteTime" = "gauge"
        "PercentIdleTime" = "gauge"
        "AverageQueueLength" = "gauge"
     }
    $prom_physicalDiskMetric = @()

    # Static metadata metrics
    $infoData = @()

    # Dynamic metrics
    $metricData = @{}

    $metricPrefix = "datacore_physicaldisk_"
    foreach($physicalDisk in $physicalDiskData){
        if(($physicalDisk.Type -ne 4) -and ($null -eq $physicalDisk.DvaPoolDiskId -or $physicalDisk.DvaPoolDiskId -eq "")){
            continue
        } 
        $instance = $physicalDisk.ExtendedCaption
        $caption = $physicalDisk.Caption
        $serial  = $physicalDisk.InquiryData.Serial 
        $type  = $physicalDisk.Type
        $physicalDisk_id = $physicalDisk.Id
        $diskIndex = $physicalDisk.DiskIndex
        $hostName  = $global:IdMap[$physicalDisk.HostId]

        $infoData += "datacore_physicaldisk_info{physicaldisk=`"$instance`", caption=`"$caption`", disk_index=`"$diskIndex`", serial=`"$serial`", type=`"$type`", host=`"$hostName`"} 1"

        $labelString =  "physicaldisk=`"$instance`", disk_index=`"$diskIndex`", id=`"$physicalDisk_id`""

        $physicalDiskPerf = CallDcsRestAPI("performance/$($physicalDisk_id)")

        foreach ($metric in $physicalDiskMetrics.Keys) {
            $name = $metricPrefix + ($metric).ToLower()

            if (-not $metricData.ContainsKey($metric)) {
                $metricData[$metric] = @()
            }

            if ($physicalDisk.PSObject.Properties.Name -contains $metric){
                $value = $physicalDisk.($metric)
            }
            else {
                $value = $physicaldiskperf.($metric)
            }
    
            # Normalize booleans
            if ($value -is [bool]) {
                $value = if ($value) { 1 } else { 0 }
            }
    
            # Skip null or empty
            if ($null -ne $value -and "$value" -ne "") {
                $metricData[$metric] += "$name{$labelString} $value"
            }
        }
    }

    # Static HELP/TYPE
    $prom_physicalDiskMetric += "# HELP datacore_physicaldisk_info Static metadata for the DataCore physical disk"
    $prom_physicalDiskMetric += "# TYPE datacore_physicaldisk_info gauge"
    $prom_physicalDiskMetric += ($infoData -join "`n") + "`n"

    # Dynamic metric HELP/TYPE
    foreach ($metric in $metricData.Keys) {
        $name = $metricPrefix + $metric.ToLower()
        $type = $physicalDiskMetrics[$metric]
        $prom_physicalDiskMetric += "# HELP $name DataCore physical disk metric for $($metric)"
        $prom_physicalDiskMetric += "# TYPE $name $type"
        $prom_physicalDiskMetric += ($metricData[$metric] -join "`n") + "`n"
    }

    return $prom_physicalDiskMetric -join "`n"
}

function ConvertPortDataToProm{
    param (
        # Parameter help description
        [PSCustomObject] $portData
    )
    $portMetrics = @{
        "Role" = "gauge"
        "NullCounterMap" = "gauge"
        "InitiatorBytesTransferred" = "counter"
        "InitiatorBytesRead" = "counter"
        "InitiatorBytesWritten" = "counter"
        "InitiatorOperations" = "counter"
        "InitiatorReads" = "counter"
        "InitiatorWrites" = "counter"
        "InitiatorReadTime" = "counter"
        "InitiatorWriteTime" = "counter"
        "InitiatorMaxReadTime" = "gauge"
        "InitiatorMaxWriteTime" = "gauge"
        "TargetBytesTransferred" = "counter"
        "TargetBytesRead" = "counter"
        "TargetBytesWritten" = "counter"
        "TargetOperations" = "counter"
        "TargetReads" = "counter"
        "TargetWrites" = "counter"
        "TargetReadTime" = "counter"
        "TargetWriteTime" = "counter"
        "TargetTotalOperationsTime" = "counter"
        "TargetMaxReadTime" = "gauge"
        "TargetMaxWriteTime" = "gauge"
        "PendingInitiatorCommands" = "gauge"
        "PendingTargetCommands" = "gauge"
        "TotalPendingCommands" = "gauge"
        "LinkFailureCount" = "counter"
        "LossOfSyncCount" = "counter"
        "LossOfSignalCount" = "counter"
        "PrimitiveSeqProtocolErrCount" = "counter"
        "InvalidTransmissionWordCount" = "counter"
        "InvalidCrcCount" = "counter"
        "TotalBytesTransferred" = "counter"
        "TotalBytesRead" = "counter"
        "TotalBytesWritten" = "counter"
        "TotalOperations" = "counter"
        "TotalReads" = "counter"
        "TotalWrites" = "counter"
        "TargetMaxIOTime" = "gauge"
        "BusyCount" = "counter"
     }
    $prom_portMetric = @()

    # Static metadata metrics
    $infoData = @()

    # Dynamic metrics
    $metricData = @{}

    $metricPrefix = "datacore_port_"
    foreach($port in $portData){
        if($port.Caption -match "Microsoft iSCSI" -or $port.Caption -match "Loopback" -or $port.Caption -match "iqn"){
            continue
        }
        if(($null -eq $port.ServerPortProperties -or $port.ServerPortProperties -eq "") -or ($port.ServerPortProperties.Role -notin (1,2,4))){
            continue
        }
        $instance = $port.ExtendedCaption
        $caption = $port.Caption
        $porttype  = $port.PortType
        $portmode  = $port.PortMode
        $port_id = $port.Id
        $hostName  = if ($port.HostId) { $global:IdMap[$port.HostId] } else { "N/A" }

        $infoData += "datacore_port_info{port=`"$instance`", caption=`"$caption`", port_type=`"$porttype`", port_mode=`"$portmode`", host=`"$hostName`"} 1"

        $labelString =  "port=`"$instance`", id=`"$port_id`""

        $portPerf = CallDcsRestAPI("performance/$($port_id)")

        foreach ($metric in $portMetrics.Keys) {
            $name = $metricPrefix + ($metric).ToLower()

            if (-not $metricData.ContainsKey($metric)) {
                $metricData[$metric] = @()
            }

            if ($port.PSObject.Properties.Name -contains $metric){
                $value = $port.($metric)
            }
            elseif($portperf.PSObject.Properties.Name -contains $metric) {
                $value = $portperf.($metric)
            }
            else {
                if ($metric -eq "Role"){
                    $value = $port.ServerPortProperties.($metric)
                }
                else{
                    $value = $null
                }
            }
            # Normalize booleans
            if ($value -is [bool]) {
                $value = if ($value) { 1 } else { 0 }
            }
    
            # Skip null or empty
            if ($null -ne $value -and "$value" -ne "") {
                $metricData[$metric] += "$name{$labelString} $value"
            }
        }
    }

    # Static HELP/TYPE
    $prom_portMetric += "# HELP datacore_port_info Static metadata for the DataCore port"
    $prom_portMetric += "# TYPE datacore_port_info gauge"
    $prom_portMetric += ($infoData -join "`n") + "`n"

    # Dynamic metric HELP/TYPE
    foreach ($metric in $metricData.Keys) {
        $name = $metricPrefix + $metric.ToLower()
        $type = $portMetrics[$metric]
        $prom_portMetric += "# HELP $name DataCore port metric for $($metric)"
        $prom_portMetric += "# TYPE $name $type"
        $prom_portMetric += ($metricData[$metric] -join "`n") + "`n"
    }

    return $prom_portMetric -join "`n"
}

function ConvertHostDataToProm{
    param (
        # Parameter help description
        [PSCustomObject] $hostData
    )
    $hostMetrics = @{
        "MpioCapable" = "gauge"
        "Type" = "gauge"
        "AluaSupport" = "gauge"
        "State" = "gauge"
        "NullCounterMap" = "gauge"
        "TotalBytesTransferred" = "counter"
        "TotalBytesRead" = "counter"
        "TotalBytesWritten" = "counter"
        "TotalOperations" = "counter"
        "TotalReads" = "counter"
        "TotalWrites" = "counter"
        "MaxReadSize" = "gauge"
        "MaxWriteSize" = "gauge"
        "MaxOperationSize" = "gauge"
        "TotalBytesProvisioned" = "gauge"
     }
    $prom_hostMetric = @()

    # Dynamic metrics
    $metricData = @{}

    $metricPrefix = "datacore_host_"
    foreach($host_data in $hostData){

        $instance = $host_data.ExtendedCaption
        $host_id = $host_data.Id
        $global:IdMap[$host_data.Id] = $host_data.Caption

        $labelString =  "host=`"$instance`", id=`"$host_id`""

        $hostPerf = CallDcsRestAPI("performance/$($host_id)")

        foreach ($metric in $hostMetrics.Keys) {
            $name = $metricPrefix + ($metric).ToLower()

            if (-not $metricData.ContainsKey($metric)) {
                $metricData[$metric] = @()
            }

            if ($host_data.PSObject.Properties.Name -contains $metric){
                $value = $host_data.($metric)
            }
            else {
                $value = $hostPerf.($metric)
            }
    
            # Normalize booleans
            if ($value -is [bool]) {
                $value = if ($value) { 1 } else { 0 }
            }
    
            # Skip null or empty
            if ($null -ne $value -and "$value" -ne "") {
                $metricData[$metric] += "$name{$labelString} $value"
            }
        }
    }

    # Dynamic metric HELP/TYPE
    foreach ($metric in $metricData.Keys) {
        $name = $metricPrefix + $metric.ToLower()
        $type = $hostMetrics[$metric]
        $prom_hostMetric += "# HELP $name DataCore host metric for $($metric)"
        $prom_hostMetric += "# TYPE $name $type"
        $prom_hostMetric += ($metricData[$metric] -join "`n") + "`n"
    }

    return $prom_hostMetric -join "`n"
}

# Function calls DataCore SANsymphony REST APIs to collect metrics
function CollectMetrics {
    Write-Log -Message "Starting DataCore SANsymphony Metrics collection..."

    # Reset IdMap as global so other functions can access it
    $global:IdMap = @{}

    $promData = @()
    
    if($enabledResources -contains "servers") {
        Write-Log -Message "Start collecting Metrics for servers"
        $serverData = CallDcsRestAPI("servers")
        $serverPromData = ConvertServerDataToProm($serverData)
        $promData = $promData + $serverPromData
    }
    if ($enabledResources -contains "hosts") {
        Write-Log -Message "Start collecting Metrics for hosts"
        $hostData = CallDcsRestAPI("hosts")
        $hostPromData = ConvertHostDataToProm($hostData)
        $promData = $promData + $hostPromData
    }
    if ($enabledResources -contains "pools") {
        Write-Log -Message "Start collecting Metrics for pools"
        $poolData = CallDcsRestAPI("pools")
        $poolPromData = ConvertPoolDataToProm($poolData)
        $promData = $promData + $poolPromData
    }
    if ($enabledResources -contains "virtualdisks") {
        Write-Log -Message "Start collecting Metrics for virtual disks"
        $virtualDiskData = CallDcsRestAPI("virtualdisks")
        $virtualDiskPromData = ConvertVirtualDiskDataToProm($virtualDiskData)
        $promData = $promData + $virtualDiskPromData
    }
    if ($enabledResources -contains "physicaldisks") {
        Write-Log -Message "Start collecting Metrics for physical disks"
        $physicalDiskData = CallDcsRestAPI("physicaldisks")
        $physicalDiskPromData = ConvertPhysicalDiskDataToProm($physicalDiskData)
        $promData = $promData + $physicalDiskPromData
    }
    if ($enabledResources -contains "ports") {
        Write-Log -Message "Start collecting Metrics for ports"
        $portData = CallDcsRestAPI("ports")
        $portPromData = ConvertPortDataToProm($portData)
        $promData = $promData + $portPromData
    }
    Write-Log -Message "Completed Metrics collection"
    # Overwrite file with new content
    Write-Log -Message "Saving DataCore SANsymphony Prom Metrics in $($metricsFile)"
    #Delete temp file if exists
    if(Test-Path $tempMetricFile){
        Remove-Item -Path $tempMetricFile -Force -ErrorAction SilentlyContinue
    }

    #Write to temp file then replace the prom file
    try {
        $writer = [System.IO.StreamWriter]::new($tempMetricFile, $false, [System.Text.Encoding]::UTF8)
        $writer.Write($promData -join "`n")
        $writer.Close()

        Move-Item -Path $tempMetricFile -Destination $metricsFile -Force
    }
    catch {
        Write-Log -Message "Failed to save DataCore Prom Metrics in $($metricsFile) : $($_.Exception.Message)" -Level "Error"
        exit
    }
    Write-Log -Message "Successfully Saved DataCore SANsymphony Prom Metrics in $($metricsFile)"
    
}

## Return true for SSL Certification Validation
if (-not("dummy" -as [type])) {
    add-type -TypeDefinition @"
using System;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;

public static class Dummy {
    public static bool ReturnTrue(object sender,
        X509Certificate certificate,
        X509Chain chain,
        SslPolicyErrors sslPolicyErrors) { return true; }

    public static RemoteCertificateValidationCallback GetDelegate() {
        return new RemoteCertificateValidationCallback(Dummy.ReturnTrue);
    }
}
"@
}

# Check whether to call CollectMetrics only once or repeatedly
if ($RunOnce) {
    CollectMetrics
} else {
    while ($true) {
        CollectMetrics
        Write-Log -Message "Waiting for $($metricTimeInterval) seconds before collecting metrics"
        Start-Sleep -Seconds $metricTimeInterval
    }
}


