@{
    # DataCore API Configuration
    RESTServerIPAddress = '127.0.0.1'
    CredentialTarget = 'datacore-api'  # Name in Credential Manager

    # Prometheus Metrics Output Directory Path
    PromMetricsFilePath = 'C:\Program Files\windows_exporter\textfile_inputs\'

    # Polling Interval (in seconds)
    IntervalSeconds = 120

    # Number of days to retain old log files before deletion (in days)
    LogFileRetentionDays = 7

    # Resources metrics to collect
    Resources = @{
        servers = $true
        pools = $true
        virtualdisks = $true
        physicaldisks = $true
        snapshots = $false
        rollbacks = $false
        ports = $true
        hosts = $true
    }
}
