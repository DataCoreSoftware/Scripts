##################################################################################################################################
# SANsymphony Deduplication Estimator Wrapper Script
# Written by:  Alexander Best
# Email:       Alexander.Best@DataCore.com
#
### THIS INFORMATION IS GATHERED BY A FUNCTION. ONLY MODIFY VALUE BEHIND ":" !!!
# Script-Version:     1.0
# Script-Date:        2025-07-18
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
<#
    .SYNOPSIS
        Estimation of deduplication opportunity in SANsymphony vDisks.

    .DESCRIPTION
    
    .PARAMETER 
		vDiskName [String]
		BRmode [Switch] Default-Value =$false
    
    .EXAMPLES
		1. DDestimate.ps1 -vDiskName test-05
		   Estimates deduplication ratio for Virtual Disk test-05

        2. DDestimate.ps1 -vDiskName test-05 -BRmode
		   Estimates deduplication ratio for Virtual Disk test-05 with 32KB wide hashing mode or BR license, instead of 128KB wide hashing mode of EN license

         
#>
###################################################################################################################################
###### PARAMETERS
[CmdletBinding(DefaultParameterSetName="Default")]
param (
    [Parameter(ParameterSetName="Default", Mandatory = $true, HelpMessage="Name of the Virtual Disk to analyse.")]
	[string]
	$vDiskName,

    [Parameter(ParameterSetName="Default", Mandatory = $false, HelpMessage="Turn on BR mode analysis with 32KB hashing width.")]
	[switch]$BRmode
	)
	
	
###################################################################################################################################
###### Main Code
$vDisk=get-dcsvirtualdisk -virtualdisk $vDiskName
if ($vDisk -eq $null)
		{
		"Virtual Disk '"+$vDiskName+"' not found, exiting without analysis!"
		}
else
	{
	$VDPerf=get-dcsperformancecounter -object $vDisk.id

	"Creating Snapshot for analysis ..."
	$Snap=Add-DcsSnapshot -Server (hostname) -VirtualDisk $vDiskName -Name ("Estimator-Temp for "+$vDisk.caption)
	$mapping=Serve-DcsVirtualDisk -virtualdisk $snap.caption -machine (hostname)
	"Waiting for Snapshot '"+$snap.caption+"' to become accessible ..."
	do {
		$null=get-dcsport -type loopback | update-dcsserverport 
		Update-hoststoragecache
		$PD=get-dcsphysicaldisk -disk $mapping.physicaldiskid
		if ($PD.Diskindex -eq -1)
			{
			"Snapshot not ready yet ..."
			sleep 5
			}
		else
			{
			"Snapshot ready to analyse."
			}
		
		} while ($PD.Diskindex -eq -1)
	# Perform the data scan ...
	#.\DcsEstimateDedupRatio.exe --raw ("\\.\PHYSICALDRIVE"+$PD.Diskindex) -hf sha256 --nosampling -s 131072 -t 4 --skip-zeroes
	if ($BRmode)
		{
		"Starting scan for SANsymphony BR license deduplication mode."
		$RunResult= .\DcsEstimateDedupRatio.exe --raw ("\\.\PHYSICALDRIVE"+$PD.Diskindex) -hf sha256 --nosampling -s 32768 -t 4 --skip-zeroes
		}
	else
		{
		"Starting scan for SANsymphony EN license deduplication mode."
		$RunResult= .\DcsEstimateDedupRatio.exe --raw ("\\.\PHYSICALDRIVE"+$PD.Diskindex) -hf sha256 --nosampling -s 131072 -t 4 --skip-zeroes
		}
#	"---"
#	$RunResult
#	"---"
	# Renaming results file 
	$Results=copy .\DedupEstimationResult.txt (".\"+$vDisk.caption+"_DedupEstimationResult.txt")
	# Analysing DcsEstimateDedupRatio.exe output data
	# Unique Bytes
	$value=$RunResult[6].split(":")[1].trim().split(" ")
	$Multiplier=("1"+$value[1].replace("i",""))/1
	$UniqueBytes=[decimal]$value[0]*$Multiplier
	# Non-Zero Bytes
	$value=$RunResult[7].split(":")[1].trim().split(" ")
	$Multiplier=("1"+$value[1].replace("i",""))/1
	$NonZeroBytes=[decimal]$value[0]*$Multiplier
	"Removing Snapshot '"+$snap.caption+"' after analysis ..."
	Unserve-DcsVirtualDisk -VirtualDisk $snap.caption -Machine (hostname)
	Remove-DcsSnapshot -snapshot $snap -yes

	(""+($VDperf.BytesAllocated / 1GB)+ " GiB allocated in vDisk '"+$vDisk.caption+"'" )
	(""+($NonZeroBytes / 1GB)+" GiB non-zero space in vDisk '"+$vDisk.caption+"' (Optimization may free some partial allocated SAUs!)")
	(""+($UniqueBytes / 1GB)+" GiB unique data in vDisk '"+$vDisk.caption+"'" )
	(""+($RunResult[9].split(":")[1].trim())+":1 estimated deduplication opportunity in '"+$vDisk.caption+"'" )
	$RunResult[10..12]

	}

