# Prometheus Corvault Collector

This code will ssh to the Seagate Corvault management port and collect
via the corvault-cli the controller and disk statistics.

More information about their CLI can be found here https://www.seagate.com/content/dam/seagate/migrated-assets/www-content/support-content/raid-storage-systems/corvault/_shared/files/204813400-00-A-Exos_CORVAULT_CLI_Reference_Guide.pdf

pre-requirements are python3, paramiko and prometheus_client packages.

```
pip install -r pip-requirements.txt
```

On the Seagate Corvault create a new account and grant it monitor-only priviledges for CLI only.
Edit prometheus-corvault-collector.py and fill in the user credentials
```
CORVAULTHOST = corvault hostname or ip address
CORVAULTUSER = corvault account username
CORVAULTPASS = corvault account password
```

By default the collector will listen on port 9700 and run every 120 seconds.

The following metrics are provided:
| Metric Name | Description |labels|
|----------------------------------|-------------|-----|
|seagate_corvault_controller_cpuload| Controller CPU Load| host, controller_id |
|seagate_corvault_controller_reads| total reads| host, controller_id |
|seagate_corvault_controller_writes|total writes | host, controller_id |
|seagate_corvault_controller_rca_hits| read cache hits| host, controller_id |
|seagate_corvault_controller_rca_miss| read cache misses| host, controller_id |
|seagate_corvault_controller_wca_hits| write cache hits| host, controller_id |
|seagate_corvault_controller_wca_miss|write cache misses| host, controller_id |
|seagate_corvault_controller_wca_used|write cache used | host, controller_id |
|seagate_corvault_controller_bps|bytes per second| host, controller_id |
|seagate_corvault_controller_iops|i/o operations per second| host, controller_id |
|seagate_corvault_disk_poweron|disk powerOn hours| host, disk_id |
|seagate_corvault_disk_reads|total reads| host, disk_id |
|seagate_corvault_disk_writes|total writes | host, disk_id |
|seagate_corvault_disk_io_timeouts|total io timeouts| host, disk_id , controller_id|
|seagate_corvault_disk_media_errors|total media errors| host, disk_id , controller_id|
|seagate_corvault_disk_bad_blocks|total bad blocks | host, disk_id , controller_id|
|seagate_corvault_disk_block_reassigns|total block reassigns| host, disk_id , controller_id|


I have included an example systemd script in case you wish to run it as a service,
just copy the python script to /usr/local/bin and make it executable.



