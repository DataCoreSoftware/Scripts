#!/usr/bin/env python3
"""
  This scripts collects disk statistics from Corvault
  pre-requirements:  apt-get install python-paramiko , python3-pip ; pip3 install prometheus_client
"""

import paramiko
import os
import json
import time, sys, getopt, traceback
from prometheus_client.core import REGISTRY, GaugeMetricFamily
from prometheus_client import start_http_server

CORVAULT_HOST     = "cv.acme.com"
CORVAULT_USERNAME = "monitoronly"
CORVAULT_PASS     = "MYPASSWORD"


class CustomCollector(object):

    def __init__(self):
        pass

    def collect(self):
        try:
            ssh = paramiko.SSHClient()
            ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
            ssh.load_system_host_keys()
            ssh.connect(CORVAULT_HOST, username=CORVAULT_USERNAME, password=CORVAULT_PASS, port=22)

            ssh_stdin, ssh_stdout, ssh_stderr = ssh.exec_command("set cli-parameters json; show disk-statistics")
            exit_code = ssh_stdout.channel.recv_exit_status()

            # strip out stdin and convert it to a json object
            payload=''
            # strip the cli-parameters results
            x=16
            for line in ssh_stdout:
                if x < 0:
                    if not line.startswith('#'):
                        payload += line.strip() + '\n'
                x-=1
            drives = json.loads(payload)

            ssh_stdin, ssh_stdout, ssh_stderr = ssh.exec_command("set cli-parameters json; show controller-statistics")
            

            payload2=''
            x=16
            for line in ssh_stdout:
              if x < 0:
                if not line.startswith('#'):
                  payload2 += line.strip() + '\n'
              x-=1
            print(payload2)
            controllers = json.loads(payload2)

            # cleanup ssh session
            ssh.close()

            # Define Controller Metrics
            corvault_controller_cpuload = GaugeMetricFamily("seagate_corvault_controller_cpuload","cpu load",labels=['host','id'])
            corvault_controller_reads   = GaugeMetricFamily("seagate_corvault_controller_reads","reads",labels=['host','id'])
            corvault_controller_writes  = GaugeMetricFamily("seagate_corvault_controller_writes","writes",labels=['host','id'])
            corvault_controller_rca_hits= GaugeMetricFamily("seagate_corvault_controller_rca_hits","read cache hits",labels=['host','id'])
            corvault_controller_rca_miss=  GaugeMetricFamily("seagate_corvault_controller_rca_miss","read cache miss",labels=['host','id'])
            corvault_controller_wca_hits=  GaugeMetricFamily("seagate_corvault_controller_wca_hits","write cache hits",labels=['host','id'])
            corvault_controller_wca_miss=  GaugeMetricFamily("seagate_corvault_controller_wca_miss","write cache miss",labels=['host','id'])
            corvault_controller_bps =  GaugeMetricFamily("seagate_corvault_controller_bps","bytes per second",labels=['host','id'])
            corvault_controller_iops=  GaugeMetricFamily("seagate_corvault_controller_iops","I/O per second",labels=['host','id'])
            corvault_controller_wca_used=  GaugeMetricFamily("seagate_corvault_controller_wca_used","write cache used",labels=['host','id'])
            # Define Disk Metrics
            corvault_disk_poweron = GaugeMetricFamily("seagate_corvault_disk_poweron","power on hours",labels=['host','id'])
            corvault_disk_reads   = GaugeMetricFamily("seagate_corvault_disk_reads","disk reads",labels=['host','id'])
            corvault_disk_writes  = GaugeMetricFamily("seagate_corvault_disk_writes","disk writes",labels=['host','id'])
            corvault_disk_io_timeouts  = GaugeMetricFamily("seagate_corvault_disk_io_timeouts","I/O Timeouts",labels=['host','id','cid'])
            corvault_disk_media_errors = GaugeMetricFamily("seagate_corvault_disk_media_errors","Media Errors",labels=['host','id','cid'])
            corvault_disk_bad_blocks = GaugeMetricFamily("seagate_corvault_disk_bad_blocks","Bad Blocks",labels=['host','id','cid'])
            corvault_disk_block_reassigns = GaugeMetricFamily("seagate_corvault_disk_block_reassigns","Block Reassigns",labels=['host','id','cid'])
            
            j=0
            while j < len(controllers['controller-statistics']):
                controller = controllers['controller-statistics'][j]
                controller_ID = controller['durable-id']
                controller_cpu = controller['cpu-load']
                controller_bps = controller['bytes-per-second-numeric']
                controller_iops = controller['iops']
                controller_reads = controller['number-of-reads']
                controller_writes = controller['number-of-writes']
                controller_rca_hits = controller['read-cache-hits']
                controller_rca_miss = controller['read-cache-misses']
                controller_wca_hits = controller['write-cache-hits']
                controller_wca_miss = controller['write-cache-misses']
                controller_wca_used = controller['write-cache-used']

                corvault_controller_cpuload.add_metric([CORVAULT_HOST,controller_ID],float(controller_cpu))
                corvault_controller_reads.add_metric([CORVAULT_HOST,controller_ID],float(controller_reads))
                corvault_controller_writes.add_metric([CORVAULT_HOST,controller_ID],float(controller_writes))
                corvault_controller_rca_hits.add_metric([CORVAULT_HOST,controller_ID],float(controller_rca_hits))
                corvault_controller_rca_miss.add_metric([CORVAULT_HOST,controller_ID],float(controller_rca_miss))
                corvault_controller_wca_hits.add_metric([CORVAULT_HOST,controller_ID],float(controller_wca_hits))
                corvault_controller_wca_miss.add_metric([CORVAULT_HOST,controller_ID],float(controller_wca_miss))
                corvault_controller_wca_used.add_metric([CORVAULT_HOST,controller_ID],float(controller_wca_used))
                corvault_controller_bps.add_metric([CORVAULT_HOST,controller_ID],float(controller_bps))
                corvault_controller_iops.add_metric([CORVAULT_HOST,controller_ID],float(controller_iops))
                j+=1

            i=0
            while i < len(drives['disk-statistics']):
                disk = drives['disk-statistics'][i]
                disk_ID = disk['durable-id']
                disk_poweron = disk['power-on-hours']
                disk_reads = disk['number-of-reads']
                disk_writes = disk['number-of-writes']
                disk_iotimeouts_1 = disk['io-timeout-count-1']
                disk_iotimeouts_2 = disk['io-timeout-count-2']
                disk_mediaerrs_1  = disk['number-of-media-errors-1']
                disk_mediaerrs_2  = disk['number-of-media-errors-2']
                disk_bad_blocks_1 = disk['number-of-bad-blocks-1']
                disk_bad_blocks_2 = disk['number-of-bad-blocks-2']
                disk_block_reassigns_1 = disk['number-of-block-reassigns-1']
                disk_block_reassigns_2 = disk['number-of-block-reassigns-2']
            
                corvault_disk_poweron.add_metric([CORVAULT_HOST,disk_ID],float(disk_poweron))
                corvault_disk_reads.add_metric([CORVAULT_HOST,disk_ID],float(disk_reads))
                corvault_disk_writes.add_metric([CORVAULT_HOST,disk_ID],float(disk_writes))
                corvault_disk_io_timeouts.add_metric([CORVAULT_HOST,disk_ID,'1'],float(disk_iotimeouts_1))
                corvault_disk_io_timeouts.add_metric([CORVAULT_HOST,disk_ID,'2'],float(disk_iotimeouts_2))
                corvault_disk_media_errors.add_metric([CORVAULT_HOST,disk_ID,'1'],float(disk_mediaerrs_1))
                corvault_disk_media_errors.add_metric([CORVAULT_HOST,disk_ID,'2'],float(disk_mediaerrs_2))
                corvault_disk_bad_blocks.add_metric([CORVAULT_HOST,disk_ID,'1'],float(disk_bad_blocks_1))
                corvault_disk_bad_blocks.add_metric([CORVAULT_HOST,disk_ID,'2'],float(disk_bad_blocks_2))
                corvault_disk_block_reassigns.add_metric([CORVAULT_HOST,disk_ID,'1'],float(disk_block_reassigns_1))
                corvault_disk_block_reassigns.add_metric([CORVAULT_HOST,disk_ID,'2'],float(disk_block_reassigns_2))
                i+=1
            

            yield corvault_controller_cpuload
            yield corvault_controller_reads
            yield corvault_controller_writes
            yield corvault_controller_rca_hits
            yield corvault_controller_rca_miss
            yield corvault_controller_wca_hits
            yield corvault_controller_wca_miss
            yield corvault_controller_wca_used
            yield corvault_controller_bps
            yield corvault_controller_iops
            yield corvault_disk_poweron
            yield corvault_disk_reads
            yield corvault_disk_writes
            yield corvault_disk_io_timeouts
            yield corvault_disk_media_errors
            yield corvault_disk_bad_blocks
            yield corvault_disk_block_reassigns

        except:
            traceback.print_exc()

if __name__ == '__main__':
    start_http_server(9700)
    REGISTRY.register(CustomCollector())
    while True:
        time.sleep(120)
