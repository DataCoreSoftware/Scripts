##################################################################################################################################
# SANsymphony Message & Alert exporter to CSV
# Written by:  Alexander Best
# Email:       Alexander.Best@DataCore.com
#
### THIS INFORMATION IS GATHERED BY A FUNCTION. ONLY MODIFY VALUE BEHIND ":" !!!
# Script-Version:     1.0
# Script-Date:        2024-05-03
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
        Export SANsymphony Log Messages or Alerts to CSV files for external processing

    .DESCRIPTION
    
    .PARAMETER 
        LastDay [Switch] Default-Value =$false
		LastWeek [Switch] Default-Value =$false
		LastMonth [Switch] Default-Value =$false
		AlertsOnly [Switch] Default-Value =$false
		StartTime [DateTime]
		EndTime [DateTime]
		Outpath [String]
    
    .EXAMPLES
		1. DcsMsg-toCSV.ps1 -LastDay -OutPath c:\Messages.csv
		   Exports all log messages from the last 24 hours and writes them to a file named c:\Messages.csv

        2. DcsMsg-toCSV.ps1 -LastWeek -AlertsOnly 
		   Exports all alert messages from the last 7 days and writes them to screen

        3. DcsMsg-toCSV.ps1 -StartDate (get-date).adddays(-3) -EndDate (get-date)  
		   Exports all log messages from the last 3 days and writes them to screen
         
#>
###################################################################################################################################
###### PARAMETERS
[CmdletBinding(DefaultParameterSetName="Default")]
Param(
    [Parameter(ParameterSetName="Default", Mandatory = $false, HelpMessage="Exports last 24 hours of messages or alerts.")]
	[Switch]
	$LastDay,

    [Parameter(ParameterSetName="Default", Mandatory = $false, HelpMessage="Exports last 7 days of messages or alerts.")]
	[Switch]
	$LastWeek,

    [Parameter(ParameterSetName="Default", Mandatory = $false, HelpMessage="Exports last month of messages or alerts.")]
	[Switch]
	$LastMonth,

    [Parameter(ParameterSetName="Default", Mandatory = $false, HelpMessage="Limits output to alerts only.")]
	[Switch]
	$AlertsOnly,
	
    [Parameter(ParameterSetName="Default", Mandatory = $false, HelpMessage="Oldest timestamp of messages or alerts to export.")]
	[DateTime]
	$StartTime,

    [Parameter(ParameterSetName="Default", Mandatory = $false, HelpMessage="Newest timestamp of messages or alerts to export.")]
	[DateTime]
	$EndTime,

    [Parameter(ParameterSetName="Default", Mandatory = $false, HelpMessage="Export path and filename to save the output. When not provided, output is going to screen.")]
	[String]
	$Outpath = $null

)

if ($LastDay)
	{
	$StartTime = (get-date).adddays(-1)
	$EndTime = (get-date)
	}

if ($LastWeek)
	{
	$StartTime = (get-date).adddays(-7)
	$EndTime = (get-date)
	}

if ($LastMonth)
	{
	$StartTime = (get-date).addmonths(-1)
	$EndTime = (get-date)
	}

if ($StartTime -eq $null -or $EndTime -eq $Null)
	{
	"Missing or incomplete timespan. Please provide start and end date or specify a period of last day/week/month."
	}
else
	{
	$Output=@('"Timestamp","Source","Level","Message"')
	if ($AlertsOnly)
		{
		$Alerts=@(get-dcsalert | sort-object -property timestamp | where {$_.timestamp -ge $StartTime -and $_.timestamp -le $EndTime})
		if ($Alerts.count -eq 0)
			{
			"No alerts during specified time period!"
			}
		else
			{
			foreach ($Alert in $Alerts)
				{
				$OutputTemp='"'+$Alert.timestamp+'","'+$Alert.MachineName+'","'+$Alert.level+'","'
				$MessageText=$Alert.MessageText
				For ($i=0;$i -lt $Alert.MessageData.count;$i++)
					{
					$MessageText=$MessageText.replace("{"+$i+"}",$Alert.MessageData[$i])
					}
				$OutputTemp+=$MessageText+'"'
				$Output+=$OutputTemp
				}
			}
		}
	else
		{
		$Messages=@(Get-DcsLogMessage -StartTime $StartTime -Endtime $EndTime | sort-object -property timestamp)
		if ($Messages.count -eq 0)
			{
			"No log messages during specified time period!"
			}
		else
			{
			foreach ($Message in $Messages)
				{
				$OutputTemp='"'+$Message.timestamp+'","'+$Message.MachineName+'","'+$Message.level+'","'
				$MessageText=$Message.MessageText
				For ($i=0;$i -lt $Message.MessageData.count;$i++)
					{
					$MessageText=$MessageText.replace("{"+$i+"}",$Message.MessageData[$i])
					}
				$OutputTemp+=$MessageText+'"'
				$Output+=$OutputTemp
				}
			}
		}
	if ($Outpath -eq "")
		{
		$Output
		}
	else
		{
		$Output > $Outpath
		("Saved the messages in file: "+$outpath)
		}
	}
