# Prometheus Corvault Collector

This code will ssh to the Seagate Corvault management port and collect
via the corvault-cli the controller and disk statistics.

pre-requirements are python3, paramiko and prometheus_client packages.

pip install -r pip-requirements.txt

On the Seagate Corvault create a new account and grant it monitor-only priviledges for CLI only.
Edit prometheus-corvault-collector.py and fill in the user credentials
```
CORVAULTHOST = corvault hostname or ip address
CORVAULTUSER = corvault account username
CORVAULTPASS = corvault account password
```

By default the collector will listen on port 9700 and run every 120 seconds.

I have included an example systemd script in case you wish to run it as a service,
just copy the python script to /usr/local/bin and make it executable.

