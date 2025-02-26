#!/bin/bash
##################################################################################################################################
# SANsymphony / Linux - iSCSI rescan
# Written by:  Gaetan MARAIS
# Email:       gaetan.marais@DataCore.com
#
# Pre-requisites : This script as been wrote for ProxMox/Debian but should work on any linux system
#                  This will require netstat tools to work.
# Script detail: This script will create a 1 minute task on crontab that will check connectity to FrontEnd portal and availability of it
#                based on registred targets in /etc/iscsi/send_targets folder
#                Additionally this script will 
#                   - log operations in journalctl.
#                   - disable the open-iscsi service that cause a very large delay during the reboot of the node
#
### THIS INFORMATION IS GATHERED BY A FUNCTION. ONLY MODIFY VALUE BEHIND ":" !!!
# Script-Version:     1.0
# Script-Date:        2025-02-15
##################################################################################################################################
# IMPORTANT:
# The example scripts listed are just examples that have been tested against a very specific configuration 
# which does not guarantee they will perform in the same manner in all implementations.  
# DataCore advises that you test these scripts in a test configuration before implementing them in production. 
#
# THE EXAMPLE SCRIPTS ARE PROVIDED AND YOU ACCEPT THEM "AS IS" AND "WITH ALL FAULTS."  
# DATACORE EXPRESSLY DISCLAIMS ALL WARRANTIES AND CONDITIONS, WHETHER EXPRESS OR IMPLIED, 
# AND DATACORE EXPRESSLY DISCLAIMS ALL OTHER WARRANTIES AND CONDITIONS, INCLUDING ANY 
# IMPLIED WARRANTIES OF MERCHANTABILITY, NON-INFRINGEMENT, FITNESS FOR A PARTICULAR PURPOSE, 
# AND AGAINST HIDDEN DEFECTS TO THE FULLEST EXTENT PERMITTED BY LAW.  
#
# NO ADVICE OR INFORMATION, WHETHER ORAL OR WRITTEN, OBTAINED FROM DATACORE OR ELSEWHERE 
# WILL CREATE ANY WARRANTY OR CONDITION.  DATACORE DOES NOT WARRANT THAT THE EXAMPLE SCRIPTS 
# WILL MEET YOUR REQUIREMENTS OR THAT THEIR USE WILL BE UNINTERRUPTED, ERROR FREE, OR FREE OF 
# VARIATIONS FROM ANY DOCUMENTATION. UNDER NO CIRCUMSTANCES WILL DATACORE BE LIABLE FOR ANY INCIDENTAL, 
# INDIRECT, SPECIAL, PUNITIVE OR CONSEQUENTIAL DAMAGES, INCLUDING WITHOUT LIMITATION LOSS OF PROFITS, 
# SAVINGS, BUSINESS, GOODWILL OR DATA, COST OF COVER, RELIANCE DAMAGES OR ANY OTHER SIMILAR DAMAGES OR LOSS, 
# EVEN IF DATACORE HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGES AND REGARDLESS OF WHETHER 
# ARISING UNDER CONTRACT, WARRANTY, TORT (INCLUDING NEGLIGENCE), STRICT LIABILITY OR OTHERWISE. 
# EXCEPT AS LIMITED BY APPLICABLE LAW, DATACORE’S TOTAL LIABILITY SHALL IN NO EVENT EXCEED US$100.  
# THE LIABILITY LIMITATIONS SET FORTH HEREIN SHALL APPLY NOTWITHSTANDING ANY FAILURE OF ESSENTIAL PURPOSE 
# OF ANY LIMITED REMEDY PROVIDED OR THE INVALIDITY OF ANY OTHER PROVISION. SOME JURISDICTIONS DO NOT ALLOW 
# THE EXCLUSION OR LIMITATION OF INCIDENTAL OR CONSEQUENTIAL DAMAGES, SO THE ABOVE LIMITATION OR EXCLUSION MAY NOT APPLY TO YOU.
##################################################################################################################################
# Changelog
#
#
# Version 1.0 	- Initial Release
###################################################################################################################################


if [ $(whereis -b netstat | wc -w) -eq 1 ] ; then
  echo "netstat package is missing, script is aborted"
  echo "  try to install it with apt install net-tools"
  exit 10
fi

if [[ "$(systemctl is-enabled open-iscsi)" == "enabled" ]]; then systemctl disable open-iscsi ;fi


if [ "$1" == "-cronit" ] && [ $(grep -c $(basename $0) /etc/crontab) -eq 0 ]; then
  cp $0 /etc/cron.d
  echo "* * * * * root /etc/cron.d/$(basename $0) >/dev/null 2>&1">>/etc/crontab
  /etc/init.d/cron reload
fi



if [ $(grep -c $(basename $0) /etc/crontab) -eq 0 ]; then
  printf "\n\nScript is not in crontab !!! :(\n"
  printf "To add it into crontab, execute $0 -cronit\n"
fi



ISCSIPATH="/etc/iscsi/send_targets"
LIST=$(find $ISCSIPATH -type f)

for FILE in $LIST
do
  PORTAL=$(awk -F"=" '/discovery.sendtargets.address/ {print $2}' $FILE)

  #Check if server is already connected
  if [ $(netstat -an | grep $PORTAL:3260 | grep -c ESTABLISHED) != 1 ]; then
      NMAP=$(nmap -p 3260 $PORTAL)
      if [ $(echo $NMAP|grep -c "3260/tcp open") = 0 ]; then
        echo "Service iSCSI (3260/tcp) is not started on $PORTAL"|systemd-cat -t $0
      else
        echo "Portal $PORTAL is listening but node is not connected"|systemd-cat -t $0
        RESCAN=1
        iscsiadm -m discovery -t sendtargets -p $PORTAL --login|systemd-cat -t $0
      fi
  fi
done

if [ "$RESCAN" == "1" ] ; then iscsiadm -m session --rescan|systemd-cat -t $0; fi
