<#/**************************************************************************
*                                                                           *
*                                  NOTICE                                   *
*                                                                           *
*           COPYRIGHT (c) 1998-2016 DATACORE SOFTWARE CORPORATION           *
*                                                                           *
*                            ALL RIGHTS RESERVED                            *
*                                                                           *
*                                                                           *
*    This Computer Program is CONFIDENTIAL and a TRADE SECRET of            *
*    DATACORE SOFTWARE CORPORATION. Any reproduction of this program        *
*    without the express written consent of DATACORE SOFTWARE CORPORATION   *
*    is a violation of the copyright laws and may subject you to criminal   *
*    prosecution.                                                           *
*                                                                           *
*****************************************************************************#>

##################################################################################################################################
# SANsymphony-V Configuration Backup Script
#
### THIS INFORMATION IS GATHERED BY A FUNCTION. ONLY MODIFY VALUE BEHIND ":" !!!
# Script-Version:     1.0.21
# Script-Date:        2016-12-13
##################################################################################################################################
# Changelog
#
# Version 1.0.21 - Adjusted script to honor "windowstyle hidden" option on restart.
#
# Version 1.0.20 - Adjusted Powershell version detection to also honor version 5
#
# Version 1.0.19 - Corrected reference of determining local backup path for the governor
#
# Version 1.0.18 - Corrected determining short name of hostname / FQDN which was $null due to a pipeline issue
#
# Version 1.0.17 - Adjusted script to honor domain joined systems (hostname is FQDN, that´s why the name needs to be split off)
#
# Version 1.0.16 - Upgraded functions.
#
# Version 1.0.15 - Corrected an issue on election of the script governor
#
# Version 1.0.14 - Upgraded functions.
#
# Version 1.0.13 - Upgraded functions.
#
# Version 1.0.12 - Adjustment to allow differently configured, local backup drives. The folder name, where the root resides, must still match!
#                  OK: "B:\SSY-V-Backup\" on Server A will work nicely with "C:\SSY-V-Backup\" on Server B
#                  NOT OK: "B:\SSY-V-Bup\" on Server A will NOT work "C:\SSY-V-Backup\" on Server B because the Share-Names will be distinguished from the last foldername.
#
# Version 1.0.11 - Adjustment in "installmode" to honor already configured system.
#
# Version 1.0.10 - Adjustment in "installmode" for interop with ADK
#                - upgraded various functions within the script
#
# Version 1.0.9 - Upgraded version of stage-1 function.
#
# Version 1.0.8 - Upgraded version of some functions. Stabilized hash function.
#
# Version 1.0.7 - Upgraded version of some functions.
#
# Version 1.0.6 - Upgraded version of some functions.
#               - Protected script against potential missing users (DCSadmin or Administrator)
#
# Version 1.0.5 - Updated dcsservice-connection function produced false positive messages on disconnect.
#               - Zip-foldercontent created an error that was not caught correctly. Therefore the result of the function was incorrect in certain cases.
#               - again modified backup procedure check operation to ensure that backups have enough time to get created.
#
# Version 1.0.4 - Upgraded version of some functions.
#               - modified backup procedure to ensure that backups have enough time to get created.
#
# Version 1.0.3 - Modified script so it handles domain-joined DataCore Servers correctly. The hostname then is full qualified which breaks some things.
#                 - Necessary modifications in elect-governor and backup-functions. Basically $server.hostname was replaced by $(@($Server.hostname -split "\.")[0])) to gather only the hostname
#
# Version 1.0.2 - Corrected a false-positive error message in "cleanup-folder" function.
#
# Version 1.0.1 - Changed copy-code to avoid "throwing" an error and interupting the script execution through SSY-V scheduler.
#                 Instead this is handled "internally" and logged to the log file.
#               - Changed the serverlist creation to just contain servers that are currently running (Offline or Online). This protects the script to fail because of offline shares.
#               - Changed check of backup-configuration cmdlt. Using the file created instead of the return code.
#
# Version 1.0 	- Initial Release
###################################################################################################################################
<#
    .SYNOPSIS
        Backup SSY-V Configuration

    .DESCRIPTION
    
    .PARAMETER 
        overWriteLogFile [boolean] Default-Value = $false
        installScript [boolean] Default-Value = $false
        ssyvServerBackupFolder [string] Default-Value = "C:\SSY-V-Backup\"
        ssyvServerBackupTTL [int] Default-Value = 14
        additionalUNCPathFolder [string] Default-Value = ""
        additionalUNCBackupTTL [int] Default-Value = 30
        forceBackup [boolean] Default-Value = $false
    
    .EXAMPLES
		1. backup-configuration.ps1
            Issues the script with default parameters. The script will run a backup in the servergroup. Therefore all servers need
            to have an appropriate UNC-share configured. The expected name of the UNC-Share is the folder-name of the local backup path.
            For instance: "C:\SSY-V-Backup" will expect an UNC share on every SSY-V server with "SSY-V-Backup$"

        2. backup-configuration.ps1 -overWriteLogFile $true
            Will issue the script but won´t provide a time-stamp in front of the logfile-name. Therefore with the next run this logfile will
            be overwritten.

        3. backup-configuration.ps1 -installScript $true 
            Script will run the install-mode with default parameters: Backup-Folder locally to "c:\SSY-V-Backup". Backups are kept for 14 days

        4. backup-configuration.ps1 -installScript $true -additionalUNCPathFolder "\\mybackup-server\remote-share"
            Script will run the install-mode with default parameters: Backup-Folder locally to "c:\SSY-V-Backup". Also additional copys will be
            stored on the UNC-path "\\mybackup-server\remote-share". Backups within the server group are kept for 14 days. On the remote-share 
            backups are kept for 30 days.

        5. backup-configuration.ps1 -ssyvServerBackupFolder "C:\Mybackup" -forcebackup $true
            Script will run with the path of the backup "C:\Mybackup". Therefore it will expect a share with name "Mybackup$" on all other
            SSY-V servers. If the UNC path is not there on the SSY-V Servers in the group backup-script will fail to copy DCSobjectmodel to 
            other SSY-V servers or sync backups within the server group. The script will proceed  with the backup even if it is not the GOVERNOR 
            of this servergroup. The GOVERNOR-mechanism is used that the script only runs once in the servergroup.

        6. backup-configuration.ps1 -ssyvServerBackupTTL 44 
            Script will run and keep backups within the servergroup for 44 days (instead of 14 which is default). After that the backups will be deleted.

        7. backup-configuration.ps1 -additionalUNCBackupTTL 300 
            Script will run and keep backups on remote backup share 300 days (instead of 30 which is default). After that the backups will be deleted.
            
#>
###################################################################################################################################
###### PARAMETERS
[CmdletBinding(DefaultParameterSetName="Default")]
Param(
    [Parameter(ParameterSetName="Default", Mandatory = $false, HelpMessage="Should the logfile be overwritten?")]
	[boolean]
	$overWriteLogFile = $false,

    [Parameter(ParameterSetName="Default", Mandatory = $false, HelpMessage="Should the script be installed as a scheduled task?")]
	[boolean]
	$installScript = $false,
    
    [Parameter(ParameterSetName="Default", Mandatory = $false, HelpMessage="Should the script installation ignore different parameters? Usually the installscript does also force an update of the parameters but this may be needed in automatisms.")]
	[boolean]
	$installScriptIgnoreDifferentActionParameters = $false,

    [Parameter(ParameterSetName="Default", Mandatory = $false, HelpMessage="Should the result of the script checksum check be ignored?")]
	[boolean]
	$ignoreScriptChecksum = $false,

    [Parameter(ParameterSetName="Default", Mandatory = $false, HelpMessage="Which local folder should be used to store the backup-files locally and within SSY-V Servergroup?")]
	[string]
	$ssyvServerBackupFolder = "C:\SSY-V-Backup\",
    
    [Parameter(ParameterSetName="Default", Mandatory = $false, HelpMessage="How long should the local backups be kept (in days)?")]
	[int]
	$ssyvServerBackupTTL = 14,
    
    [Parameter(ParameterSetName="Default", Mandatory = $false, HelpMessage="Which remote (UNC) folder should be used to store the backup-files?")]
	[string]
	$additionalUNCPathFolder = "", 

    [Parameter(ParameterSetName="Default", Mandatory = $false, HelpMessage="How long should the remote backups be kept (in days)?")]
	[int]
	$additionalUNCBackupTTL = 30,

    [Parameter(ParameterSetName="Default", Mandatory = $false, HelpMessage="Should the batchmode be used?")]
	[boolean]
	$batchmode = $false,

    [Parameter(ParameterSetName="Default", Mandatory = $false, HelpMessage="Should the governor election process be ignored?")]
	[boolean]
	$forceBackup = $false,

    [Parameter(ParameterSetName="Default", Mandatory = $false, HelpMessage="Was the quick edit mode enabled?")]
	[string]
	$quickeditMode = "",

    [Parameter(ParameterSetName="Default", Mandatory = $false, HelpMessage="Should the verbose logging be displayed in the interactive window?")]
	[boolean]
	$showVerboseLogging = $false
)
###################################################################################################################################
###### Configuring the Script window
$windowTitle="DataCore SANsymphony-V Backup-Configuration"
$pshost = get-host
if ($($pshost.Name) -notmatch "ISE Host" -and [Environment]::UserInteractive)
{
    $pswindow = $pshost.ui.rawui
    #### Size of the window
    ### we need to adjust the buffer
    $newsize = $pswindow.buffersize
    $newsize.height = 3000
    $newsize.width = 120
    $pswindow.buffersize = $newsize
    ### and of course the window size itself.
    $newsize = $pswindow.windowsize
    $newsize.height = 50
    $newsize.width = 120
    $pswindow.windowsize = $newsize
}
### And the title
if ([Environment]::UserInteractive)
{
    $Host.UI.RawUI.WindowTitle = "$windowTitle"
}
#----------------------------------------------------------------------------------------------------------------------------------
##### Initializing Windows Forms 
[void] [System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms")
[void] [System.Reflection.Assembly]::LoadWithPartialName("System.Drawing") 
[void] [System.Reflection.Assembly]::LoadWithPartialName('Microsoft.VisualBasic')
###################################################################################################################################
###### FUNCTIONS

###################################################################################################################################
##### FUNCTIONS STARTING WITH >A<
#----------------------------------------------------------------------------------------------------------------------------------
function autorunPs1Script($action,$scope,$scriptAbsolutePath,$scriptParameters)
{
    # Version 1.5

    $privAction = [string]$action
    $privScope = [string]$scope
    $privScriptAbsolutePath = [string]$scriptAbsolutePath
    $privScriptParameters = [string]$scriptParameters

    $privMessagePrefix = "$($MyInvocation.InvocationName) :"
    multi-PurposeLogging -message "$privMessagePrefix Function invoked with parameter privaction >$privaction< and privScriptAbsolutePath >$privScriptAbsolutePath<." -level "verbose"
    
    $errorOccured = $false

    ## Action
    if ( -not ( "$privAction" -ieq "enable" -or "$privAction" -ieq "disable" ) )
    {
        multi-PurposeLogging -message "$privMessagePrefix parameter privaction has to be >enable< or >disable<." -level "error"
        $errorOccured = $true
    }
    elseif ( "$privAction" -ieq "enable" )
    {
        if ( "$privScriptAbsolutePath" -eq "" )
        {
            multi-PurposeLogging -message "$privMessagePrefix parameter privScriptAbsolutePath is empty. Can´t continue." -level "error"
            $errorOccured = $true
        }
        else
        {
            if ( -not ( test-path -Path "$privScriptAbsolutePath" ) )
            {
                multi-PurposeLogging -message "$privMessagePrefix could not find file in >$privScriptAbsolutePath<. Can´t continue." -level "error"
                $errorOccured = $true
            }
        }
    }
    ## Scriptabsolutepath empty -> disable all
    if ( "$privScriptAbsolutePath" -ieq "" )
    {
        multi-PurposeLogging -message "$privMessagePrefix parameter privScriptAbsolutePath is empty. Will disable all autorun entries." -level "information"
    }
    ## Scope
    if ( "$privScope" -ieq "" )
    {
        multi-PurposeLogging -message "$privMessagePrefix parameter privScope is empty. Will use >currentUser< as default." -level "warning"
        $privScope = "currentuser"
    }
    else
    {
        if ( -not ( "$privScope" -ieq "currentUser" ) -and  -not ( "$privScope" -ieq "localMachine" ) -and  -not ( "$privScope" -ieq "all" ) )
        {
            multi-PurposeLogging -message "$privMessagePrefix parameter privScope has invalid value >$privScope<. Allowed are >currentUser<, >localMachine< and >all<. Can´t continue." -level "error"
            $errorOccured = $true
        }
    }

    ### THE DOING
    if ( $errorOccured -eq $false )
    {
        $powerShellPath = $null
        $powerShellPath = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
        $batchFolderPath = $null
        $batchFolderPath = "$globalMyScriptFolderPath"+"autorun\"

        ### PREPARATION
        if ( -not ( "$privScriptAbsolutePath" -ieq "" ) )
        {
            $keyName = $null
            $keyName = @($privScriptAbsolutePath -split "\\")[-1]
            $batchFileName = $null
            $batchFileName = "$keyName.bat"
            
            if ( "$privAction" -ieq "enable" )
            {
                $useBatchLayer = $false
                $scriptStartString = $null
                if ( "$privScriptParameters" -ieq "" )
                {
                    $scriptStartString = "$powerShellPath "+"`"& `"$privScriptAbsolutePath`"`""
                }
                else
                {
                    $scriptStartString = "$powerShellPath "+"`"& `"$privScriptAbsolutePath`" $privScriptParameters`""
                }
        
                multi-PurposeLogging -message "$privMessagePrefix      keyname >$keyName<." -level "verbose"
                multi-PurposeLogging -message "$privMessagePrefix      batchFileName >$batchFileName<." -level "verbose"
                multi-PurposeLogging -message "$privMessagePrefix      scriptStartString >$scriptStartString<." -level "verbose"

                ### If the script start string is greater or equal 255
                if ( $($scriptStartString.length) -ge 255 )
                {
                    multi-PurposeLogging -message "$privMessagePrefix      scriptStartString length is >$($scriptStartString.length)<. Need to adjust behavior with an additional batch-layer." -level "verbose"
                    multi-PurposeLogging -message "$privMessagePrefix      this is the batch file path: >$batchFolderPath$batchFileName<." -level "verbose"
                    $useBatchLayer = $true

                    ### Creating the Temp-Folder
                    $result = $null
                    $result = create-Folder -absolutePath "$batchFolderPath"
                    if ( $result -eq $false )
                    {
                        $errorOccured = $true
                    }

                    ### Creating the batch file
                    # Delete
                    if ( $errorOccured -eq $false )
                    {
                        # If it is not there, deleting
                        if ( test-path -LiteralPath "$batchFolderPath$batchFileName" -ErrorAction SilentlyContinue )
                        {
                            try
                            {
                                multi-PurposeLogging -message "$privMessagePrefix      deleting existing file: >$batchFolderPath$batchFileName<." -level "verbose"
                                $result = $null
                                $result = Remove-Item -LiteralPath "$batchFolderPath$batchFileName" -Force -Confirm:$false -ErrorAction Stop
                                multi-PurposeLogging -message "$privMessagePrefix           success." -level "verbose"
                            }
                            catch
                            {
                                $errorOccured = $true
                                multi-PurposeLogging -message "$privMessagePrefix           failed." -level "verbose"
                            }
                        }
                    }
                    # Create
                    if ( $errorOccured -eq $false )
                    {
                        multi-PurposeLogging -message "$privMessagePrefix      creating batch file: >$batchFolderPath$batchFileName<." -level "verbose"
                        $result = $null
                        $result =  $scriptStartString | out-file -FilePath "$batchFolderPath$batchFileName" -Encoding ascii
                        if ( $result -eq $false )
                        {
                            $errorOccured = $true
                        }
                    }
                    # Validate
                    if ( $errorOccured -eq $false )
                    {
                        multi-PurposeLogging -message "$privMessagePrefix      validating batch file: >$batchFolderPath$batchFileName<." -level "verbose"
                        $result = $null
                        $result = get-content -LiteralPath "$batchFolderPath$batchFileName"
                        if ( -not ( "$result" -imatch "$([regex]::escape("$scriptStartString"))" ) )
                        {
                            $errorOccured = $true
                        }
                    }
                }
            }
        }
        
        ### PREPARE THE REGISTRY HIVE
        if ( $errorOccured -eq $false )
        {
            ##### SCOPE CURRENT USER
            if ( "$privScope" -ieq "currentuser" -or "$privScope" -ieq "all" ) 
            {
                $HKCUparentPath = $null
                $HKCUparentPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\"
                $HKCUrunPath = $null
                $HKCUrunPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run\"
                ### checking if the key is there
                if ( -not ( test-path -path "$HKCUrunPath" -ErrorAction SilentlyContinue ) )
                {
                    multi-PurposeLogging -message "$privMessagePrefix Current User: RUN registry key not found. Creating..." -level "information"
                    try
                    {
                        New-Item -Path "$HKCUparentPath" -Name "Run" -ErrorAction SilentlyContinue
                        multi-PurposeLogging -message "$privMessagePrefix     success." -level "success"
                    }
                    catch
                    {
                        multi-PurposeLogging -message "$privMessagePrefix     failed. This is the last error-message >$($error[0])<." -level "error"
                        $errorOccured = $true
                    }
                }
            }
            ##### SCOPE LOCAL MACHINE
            if ( "$privScope" -ieq "localmachine" -or "$privScope" -ieq "all" ) 
            {
                $HKLMparentPath = $null
                $HKLMparentPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\"
                $HKLMrunPath = $null
                $HKLMrunPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run\"
                ### checking if the key is there
                if ( -not ( test-path -path "$HKLMrunPath" -ErrorAction SilentlyContinue ) )
                {
                    multi-PurposeLogging -message "$privMessagePrefix Current User: RUN registry key not found. Creating..." -level "information"
                    try
                    {
                        New-Item -Path "$HKLMparentPath" -Name "Run" -ErrorAction SilentlyContinue
                        multi-PurposeLogging -message "$privMessagePrefix     success." -level "success"
                    }
                    catch
                    {
                        multi-PurposeLogging -message "$privMessagePrefix     failed. This is the last error-message >$($error[0])<." -level "error"
                        $errorOccured = $true
                    }
                }
            }
        }

        ### CREATING / ENABLE
        if ( "$privAction" -ieq "enable" )
        {
            ##### SCOPE CURRENT USER
            if ( "$privScope" -ieq "currentuser" -or "$privScope" -ieq "all" ) 
            {
                $HKCUparentPath = $null
                $HKCUparentPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\"
                $HKCUrunPath = $null
                $HKCUrunPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run\"
                $value = $null
                if ( $useBatchLayer -eq $true )
                {
                    $value = "$powerShellPath `"$batchFolderPath$batchFileName`""
                }
                else
                {
                    $value = "$scriptStartString"
                }
                # Checking the length
                if ( $value.length -ge 255 )
                {
                    multi-PurposeLogging -message "$privMessagePrefix      value for key is longer than 255 characters. This won´t work!" -level "error"
                    $errorOccured = $true
                }

                ### Checking if we already have a subkey
                if ( $errorOccured -eq $false )
                {
                    multi-PurposeLogging -message "$privMessagePrefix creating Autorun key for current user." -level "Information"
                    $result = $null
                    $result = registryValue -registryFullPath "$HKCUrunPath$keyName" -registryKeyValue "$value" -registryKeyType "string" -action "create"
                    if ( $result -eq $false )
                    {
                        multi-PurposeLogging -message "$privMessagePrefix     failed. This is the last error-message >$($error[0])<." -level "error"
                        $errorOccured = $true
                    }
                    else
                    {
                        multi-PurposeLogging -message "$privMessagePrefix     success." -level "success"
                    }
                }
            }

            ##### SCOPE LOCAL MACHINE
            if ( "$privScope" -ieq "localmachine" -or "$privScope" -ieq "all" ) 
            {
                $HKLMparentPath = $null
                $HKLMparentPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\"
                $HKLMrunPath = $null
                $HKLMrunPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run\"
                $value = $null
                if ( $useBatchLayer -eq $true )
                {
                    $value = "$batchFolderPath$batchFileName"
                }
                else
                {
                    $value = "$scriptStartString"
                }
                # Checking the length
                if ( $value.length -ge 255 )
                {
                    multi-PurposeLogging -message "$privMessagePrefix      value for key is longer than 255 characters. This won´t work!" -level "error"
                    $errorOccured = $true
                }

                ### Checking if we already have a subkey
                if ( $errorOccured -eq $false )
                {
                    multi-PurposeLogging -message "$privMessagePrefix creating Autorun key for local machine." -level "Information"
                    $result = $null
                    $result = registryValue -registryFullPath "$HKLMrunPath$keyName" -registryKeyValue "$value" -registryKeyType "String" -action "create"
                    if ( $result -eq $false )
                    {
                        multi-PurposeLogging -message "$privMessagePrefix     failed. This is the last error-message >$($error[0])<." -level "error"
                        $errorOccured = $true
                    }
                    else
                    {
                        multi-PurposeLogging -message "$privMessagePrefix     success." -level "success"
                    }
                }
            }
        }
        ### DELETING / DISABLE
        elseif ( "$privAction" -ieq "disable" )
        {
            ##### SCOPE CURRENT USER
            if ( "$privScope" -ieq "currentuser" -or "$privScope" -ieq "all" ) 
            {
                $result = $true
                $HKCUparentPath = $null
                $HKCUparentPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\"
                $HKCUrunPath = $null
                $HKCUrunPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run\"
                if ( -not ( "$privScriptAbsolutePath" -eq "" ) )
                {
                    multi-PurposeLogging -message "$privMessagePrefix Removing Autorun key >$keyName< for current user." -level "Information"
                    $result = $null
                    $result = registryValue -registryFullPath "$HKCUrunPath$keyName" -action "delete"
                    if ( $result -eq $false )
                    {
                        $errorOccured = $true
                    }
                }
                else
                {
                    $autostartItems = $null
                    $autostartItems = get-itemproperty -path "$HKCUrunPath"
                    multi-PurposeLogging -message "$privMessagePrefix Removing all autorun keys for current user." -level "Information"
                    
                    foreach ( $item in $autostartItems)
                    {
                        # the key name
                        $itemPropertyName = $null
                        $itemPropertyName = $(($item -split "=" )[0] ) -replace "@{",""
                        
                        # Deleting the item
                        $result = $null
                        $result = registryValue -registryFullPath "$HKCUrunPath$itemPropertyName" -action "delete"
                        if ( $result -eq $false )
                        {
                            $errorOccured = $true
                        }
                    }
                }

                ### Deleting the batch files
                if ( -not ( "$privScriptAbsolutePath" -ieq "" ) )
                {
                    # check if we have a batch file for the current script and delete only that on
                    multi-PurposeLogging -message "$privMessagePrefix deleting potential batch file >$batchFileName<." -level "verbose"
                    try
                    {
                        if ( -not ( "$batchFileName" -ieq "" ) -and ( test-path -literalpath "$batchFolderPath$batchFileName" -ErrorAction SilentlyContinue ) )
                        {
                            $result = $null
                            $result = Remove-Item -LiteralPath "$batchFolderPath$batchFileName" -force -confirm:$false -ErrorAction stop
                            multi-PurposeLogging -message "$privMessagePrefix     success." -level "verbose"
                        }
                        else
                        {
                            multi-PurposeLogging -message "$privMessagePrefix     no batch file found. Skipping." -level "verbose"
                        }
                    }
                    catch
                    {
                        multi-PurposeLogging -message "$privMessagePrefix     error. This is the last errormessage >$($error[0])<." -level "verbose"
                        $errorOccured = $true
                    }
                }
                elseif ( "$privScope" -ieq "all" )
                {
                    # We delete all items in the folder.
                    multi-PurposeLogging -message "$privMessagePrefix deleting all potential batch files in >$batchFolderPath<." -level "verbose"
                    try
                    {
                        if ( test-path -literalpath "$batchFolderPath" -erroraction SilentlyContinue )
                        {
                            $result = $null
                            $result = get-childitem -LiteralPath "$batchFolderPath" -force -Recurse -ErrorAction stop | Remove-Item -Confirm:$false -ErrorAction stop
                            multi-PurposeLogging -message "$privMessagePrefix     success." -level "verbose"
                        }
                        else
                        {
                            multi-PurposeLogging -message "$privMessagePrefix     >$batchFolderPath< does not exist. Skipping." -level "verbose"
                        }
                    }
                    catch
                    {
                        multi-PurposeLogging -message "$privMessagePrefix     error. This is the last errormessage >$($error[0])<." -level "verbose"
                        $errorOccured = $true
                    }
                }

                ### Has an error occured?
                if ( $errorOccured -eq $true )
                {
                    multi-PurposeLogging -message "$privMessagePrefix     failed. This is the last error-message >$($error[0])<." -level "error"
                    $errorOccured = $true
                }
                else
                {
                    multi-PurposeLogging -message "$privMessagePrefix     success." -level "success"
                }
            }

            ##### SCOPE LOCAL MACHINE
            if ( "$privScope" -ieq "localmachine" -or "$privScope" -ieq "all" ) 
            {
                $result = $true
                $HKLMparentPath = $null
                $HKLMparentPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\"
                $HKLMrunPath = $null
                $HKLMrunPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run\"
                if ( -not ( "$privScriptAbsolutePath" -eq "" ) )
                {
                    multi-PurposeLogging -message "$privMessagePrefix removing Autorun key >$keyName< for local machine." -level "Information"
                    $result = $null
                    $result = registryValue -registryFullPath "$HKLMrunPath$keyName" -action "delete"
                    if ( $result -eq $false )
                    {
                        $errorOccured = $true
                    }
                }
                else
                {
                    $autostartItems = $null
                    $autostartItems = get-itemproperty -path "$HKLMrunPath"
                    multi-PurposeLogging -message "$privMessagePrefix Removing all autorun keys for local machine." -level "Information"
                    
                    foreach ( $item in $autostartItems)
                    {
                        # the key name
                        $itemPropertyName = $null
                        $itemPropertyName = $(($item -split "=" )[0] ) -replace "@{",""
                        
                        # Deleting the item
                        $result = $null
                        $result = registryValue -registryFullPath "$HKLMrunPath$itemPropertyName" -action "delete"
                        if ( $result -eq $false )
                        {
                            $errorOccured = $true
                        }
                    }
                }

                ### Deleting the batch files
                if ( -not ( "$privScriptAbsolutePath" -ieq "" ) )
                {
                    # check if we have a batch file for the current script and delete only that on
                    multi-PurposeLogging -message "$privMessagePrefix deleting potential batch file >$batchFileName<." -level "verbose"
                    try
                    {
                        if ( -not ( "$batchFileName" -ieq "" ) -and ( test-path -literalpath "$batchFolderPath$batchFileName" -ErrorAction SilentlyContinue ) )
                        {
                            $result = $null
                            $result = Remove-Item -LiteralPath "$batchFolderPath$batchFileName" -force -confirm:$false -ErrorAction stop
                            multi-PurposeLogging -message "$privMessagePrefix     success." -level "verbose"
                        }
                        else
                        {
                            multi-PurposeLogging -message "$privMessagePrefix     no batch file found. Skipping." -level "verbose"
                        }
                    }
                    catch
                    {
                        multi-PurposeLogging -message "$privMessagePrefix     error. This is the last errormessage >$($error[0])<." -level "verbose"
                        $errorOccured = $true
                    }
                }
                elseif ( "$privScope" -ieq "all" )
                {
                    # We delete all items in the folder.
                    multi-PurposeLogging -message "$privMessagePrefix deleting all potential batch files in >$batchFolderPath<." -level "verbose"
                    try
                    {
                        if ( test-path -literalpath "$batchFolderPath" -erroraction SilentlyContinue )
                        {
                            $result = $null
                            $result = get-childitem -LiteralPath "$batchFolderPath" -force -Recurse -ErrorAction stop | Remove-Item -Confirm:$false -ErrorAction stop
                            multi-PurposeLogging -message "$privMessagePrefix     success." -level "verbose"
                        }
                        else
                        {
                            multi-PurposeLogging -message "$privMessagePrefix     >$batchFolderPath< does not exist. Skipping." -level "verbose"
                        }
                    }
                    catch
                    {
                        multi-PurposeLogging -message "$privMessagePrefix     error. This is the last errormessage >$($error[0])<." -level "verbose"
                        $errorOccured = $true
                    }
                }
                
                
                ### Has an error occured?
                if ( $errorOccured -eq $true )
                {
                    multi-PurposeLogging -message "$privMessagePrefix     failed. This is the last error-message >$($error[0])<." -level "error"
                    $errorOccured = $true
                }
                else
                {
                    multi-PurposeLogging -message "$privMessagePrefix     success." -level "success"
                }
            }
        }
    }

    ### Return the value
    if ( $errorOccured -eq $true )
    {
        multi-PurposeLogging -message "$privMessagePrefix returns >false<." -level "error"
        return $false
    }
    else
    {
        multi-PurposeLogging -message "$privMessagePrefix returns >true<." -level "success"
        return $true
    }
}


###################################################################################################################################
##### FUNCTIONS STARTING WITH >B<

###################################################################################################################################
##### FUNCTIONS STARTING WITH >C<
#----------------------------------------------------------------------------------------------------------------------------------
function cleanup-Folder($absolutePathToFolder, $TTLinDays, $examineAllFiles)
{
    # Version 1.3

    $privAbsolutePathToFolder = [string]$absolutePathToFolder
    $privExamineAllFiles = [boolean]$examineAllFiles
    $privTTLinDays = [int]$TTLinDays
    $privMessagePrefix = "$($MyInvocation.InvocationName) :"
    multi-PurposeLogging -message "$privMessagePrefix Function invoked. Parameter privAbsolutePathToFolder has value >$privAbsolutePathToFolder<, >privTTLinDays< has value >$privTTLinDays<, privExamineAllFiles is >$privExamineAllFiles<." -level "verbose"
    
    $errorOccured = $false

    if ( $privTTLinDays -eq "" -or $privTTLinDays -eq $null)
    {
        multi-PurposeLogging -message "$privMessagePrefix privTTLInDays is null or empty. Will use default-value of 100." -level "warning"
        $privTTLinDays = 100
    }
    
    ##### Checking the path value
    ### Must not be emtpy because this will clean up the folder the script currently has its focus in.
    if ( "$privAbsolutePathToFolder" -eq "" -or $privAbsolutePathToFolder -eq $null)
    {
        multi-PurposeLogging -message "$privMessagePrefix privAbsolutePathToFolder is null or empty. Aborting due to safety reasons." -level "error"
        $errorOccured = $true        
    }
    ## Finding Paths that contain only a UNC + Drive Character or a Drive character + \ like \\myunc\c$ or \\myunc\c$\ or \\myunc\c or \\myunc\c\
    if ( "$privAbsolutePathToFolder" -match "^\\\\[a-z,A-Z,0-9,-,.]+\\[a-z]{1}?\$`$" -or "$privAbsolutePathToFolder" -match "^\\\\[a-z,A-Z,0-9,-,.]+\\[a-z]{1}?\$\\`$" -or "$privAbsolutePathToFolder" -match "^\\\\[a-z,A-Z,0-9,-,.]+\\[a-z]{1}?`$" -or "$privAbsolutePathToFolder" -match "^\\\\[a-z,A-Z,0-9,-,.]+\\[a-z]{1}?\\`$")
    {
        multi-PurposeLogging -message "$privMessagePrefix detected a path that seems to be a root of a drive. This can cause unexpected deletion results! Aborting ..." -level "error"
        $errorOccured = $true
    }
    ## Finding Paths that contain only a Drive Character or a Drive Character + \ like c: or c:\
    if ( "$privAbsolutePathToFolder" -match "^[a-z]{1}?:\\`$" -or "$privAbsolutePathToFolder" -match "^[a-z]{1}?:`$")
    {
        multi-PurposeLogging -message "$privMessagePrefix detected a path that seems to be a root of a drive. This can cause unexpected deletion results! Aborting ..." -level "error"
        $errorOccured = $true
    }
    ### Protecting various system relevant folders
    if ( "$privAbsolutePathToFolder" -match "^[a-z]{1}?:\\Program" -or "$privAbsolutePathToFolder" -match "^[a-z]{1}?:\\Windows\\")
    {
        multi-PurposeLogging -message "$privMessagePrefix detected a path that seems to be a root of a drive. This can cause unexpected deletion results! Aborting ..." -level "error"
        $errorOccured = $true
    }

    ### THE DOING ONLY IF THE PATHS ARE OK
    if ( $errorOccured -eq $false )
    {
        ## getting the date of today and the date upon which should be deleted
        $privToday = $null
        $privToday = get-date
        $privTTLDate = $null
        $privTTLDate = $privToday.AddDays(-$privTTLinDays)
        multi-PurposeLogging -message "$privMessagePrefix calculated expiration date and time is >$privTTLDate<." -level "information"
        ## now we get all items that are older
        $privExpiredFolderContent = $null
        $privExpiredFolderContent = Get-ChildItem -Path "$privAbsolutePathToFolder" -recurse -ErrorAction SilentlyContinue | where {$_.LastWriteTime -lt $privTTLDate}
        $privErrorOccured = $false
        if ( $privExpiredFolderContent )
        {
            multi-PurposeLogging -message "$privMessagePrefix the following files will be deleted: >$($privExpiredFolderContent.Name)<." -level "information"
            ## Going through the list
            foreach ( $privContentItem in $privExpiredFolderContent )
            {
                $proceedWithDeletion = $false
                # Only if the file is existent...
                if ( Get-Item -Path "$( $privContentItem.FullName )" -ErrorAction SilentlyContinue)
                {
                    ## check if we should clean up all 
                    if ( $privExamineAllFiles -eq $true )
                    {
                        $proceedWithDeletion = $true
                    }
                    else
                    {
                        if ( "$($privContentItem.Extension)" -ieq ".log" )
                        {
                            $proceedWithDeletion = $true
                        }
                        else
                        {
                            $proceedWithDeletion = $false
                        }
                    }

                    if ( $proceedWithDeletion -eq $true )
                    {
                        $privResult = $null
                        $privResult = Remove-Item -Path "$($privContentItem.FullName)" -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
                        if ( -not $? )
                        {
                            multi-PurposeLogging -message "$privMessagePrefix could not delete file >$($privContentItem.FullName)<." -level "warning"
                            $errorOccured = $true
                        }
                    }
                }
                ### Otherwise it might have been deleted by the folder above ;)
            }
        }
        else
        {
            multi-PurposeLogging -message "$privMessagePrefix there are no files older than >$privTTLinDays< days." -level "verbose"
        }
    }

    ### Return value of the function
    if ( $errorOccured -eq $false )
    {
        multi-PurposeLogging -message "$privMessagePrefix returns >true<." -level "success"
        return $true
    }
    else
    {
        multi-PurposeLogging -message "$privMessagePrefix returns >false<." -level "error"
        return $false
    }
}
#----------------------------------------------------------------------------------------------------------------------------------
function configure-QuickEditMode($targetValue,$silent)
{
    # Version 1.2

    $privTargetValue = [boolean]$targetValue
    $privSilent = $silent
    $privMessagePrefix = "$($MyInvocation.InvocationName) :"
    
    if ( $privSilent -ne $true -and $privSilent -ne $false )
    {
        $privSilent = $true
    }

    if ( $privSilent -eq $false )
    {
        multi-PurposeLogging -message "$privMessagePrefix Function invoked. Parameter privTargetValue has value >$privTargetValue<. privSilent has value >$privSilent<." -level "verbose"
        multi-PurposeLogging -message "$privMessagePrefix Setting Quickedit registry key(s) to >$privTargetValue<." -level "information"
    }
    
    $errorOccured = $false
    $quickEditWasEnabled = $false

    # Doing the configuration
    try
    {
        ### the base key
        $basepath = "HKCU:\Console"
        if ( $(get-itemproperty -path "$basepath" -name Quickedit -erroraction silentlycontinue).quickedit -eq 1)
        {
            $quickEditWasEnabled = $true
        }
        Set-ItemProperty –path "$basepath" –name QuickEdit –value $privTargetValue

        ### All Subkeys
        $subKeys = Get-ChildItem -Path "$basepath"
        $restartScript=$false

        foreach ($key in $subKeys)
        {
            if ( get-itemproperty -path "$basepath\$($key.pschildname)" -name Quickedit -erroraction silentlycontinue )
            {
                if ( $(get-itemproperty -path "$basepath\$($key.pschildname)" -name Quickedit -erroraction silentlycontinue ).quickedit -eq 1 )
                {
                    $quickEditWasEnabled = $true
                }
                Set-ItemProperty –path "$basepath\$($key.pschildname)" –name QuickEdit –value $privTargetValue
            }
        }
        
        if ( $privSilent -eq $false )
        {
            multi-PurposeLogging -message "$privMessagePrefix success." -level "success"
        }
    }
    catch
    {
        if ( $privSilent -eq $false )
        {
            multi-PurposeLogging -message "$privMessagePrefix failed. This is the last error-message >$($error[0])<." -level "error"
        }
        $errorOccured = $true
    }
    
    ## Return value
    if ( $errorOccured -eq $true )
    {
        if ( $privSilent -eq $false )
        {
            multi-PurposeLogging -message "$privMessagePrefix returns >false<." -level "error"
        }
        return $false
    }
    else
    {
        if  ($quickEditWasEnabled -eq $true )
        {
            $returnCode = "wasEnabled"
        }
        else
        {
            $returnCode = "wasDisabled"
        }

        if ( $privSilent -eq $false )
        {
            multi-PurposeLogging -message "$privMessagePrefix returns quick edit status >$returnCode<." -level "success"
        }
        return $returnCode
    }
}
#----------------------------------------------------------------------------------------------------------------------------------
function console-logging($message, $level, $logVerboseToSession)
{
    # Version 1.1
    $privlogVerboseToSession = [boolean]$logVerboseToSession
    ### Depending on the global setting / parameter
    # Showverboselogging = parameter
    if ( $showVerboseLogging -eq $true -or $privlogVerboseToSession -eq $true )
    {
        $logVerboseToConsole = $true
    }
    else
    {
        $logVerboseToConsole = $false
    }

    # this function is used to write output to a console session if it is interactive.
    $privLoggingMessage = $message
    $privLevel = $level

    if ($privLevel -ieq "warning")
    {
        write-host $privLoggingMessage -ForegroundColor Yellow
    }
    elseif ($privLevel -ieq "error")
    {
        write-host $privLoggingMessage -ForegroundColor red
    }
    elseif ($privLevel -ieq "success")
    {
        write-host $privLoggingMessage -ForegroundColor green
    }
    elseif ($privLevel -ieq "information")
    {
        write-host $privLoggingMessage -ForegroundColor White
    }
    elseif ($privLevel -ieq "verbose")
    {
        if ( $logVerboseToConsole -eq $true )
        {
            write-host $privLoggingMessage -ForegroundColor Gray
        }
    }
    else
    {
        write-host $privLoggingMessage -ForegroundColor Cyan
    }
}
#----------------------------------------------------------------------------------------------------------------------------------
function create-Folder($absolutePath)
{
    # Version 1.1

    ### This function is used to create a Folder with given absolute path. If the folder is already there nothing is done.
    # The path variable must contain something.
    if ( $absolutePath -ne "" )
    {
        if ( test-path -Path "$absolutePath" )
        {
            return $true
        }
        else
        {
            $result = $null
            $result = New-Item -Path "$absolutePath" -ItemType directory -Force -ErrorAction SilentlyContinue -confirm:$false
            if ( $? -eq $true )
            {
                return $true
            }
            else
            {
                return $false
            }
        }
    }
    else
    {
        return $false
    }
}
#----------------------------------------------------------------------------------------------------------------------------------
function create-SSY-V-Configuration-Backup($backupPath, $temporaryFolder)
{
    # Version 1.5
    ## Two separate sections of the path are needed so folders with the hostnames can be dynamically inserted.
    $errorOccured = $false

    try
    {
        $privTemporaryFolder = [string]$temporaryFolder
        $privbackupPath = [string]$backupPath
    }
    catch
    {
        $errorOccured = $true
    }    

    $privMessagePrefix = "$($MyInvocation.InvocationName) :"
    multi-PurposeLogging -message "$privMessagePrefix Function invoked. Parameter privbackupPath has value >$privbackupPath<, privTemporaryFolder is >$privTemporaryFolder<." -level "verbose"

    if ( "$privbackupPath" -eq "" )
    {
        multi-PurposeLogging -message "$privMessagePrefix please provide a backup path." -level "error"    
        $errorOccured = $true    
    }
    elseif ( -not ($privbackupPath.Substring($privbackupPath.Length -1, 1) -ieq "\" ) )
    {
        multi-PurposeLogging -message "$privMessagePrefix missing backslash. Adding it to the path provided." -level "warning"
        $privbackupPath = "$privbackupPath\"
    }

    ### The Doing
    if ( $errorOccured -eq $false )
    {
        ### Connecting to the SSY-V service
        $myConnection = dcsService-Connection -action "connect" -user "$username" -password "$password" -hostname "$(hostname)" -usePassThroughAuth $true -retryCount 5 -retryTimeOut 45

        ### If we got an connection
	    if ( $myConnection )
        {
            $ssyvServers = $null
            $ssyvServers = @(Get-DcsServer | where {$_.RegionNodeID -ne $null -and $_.state -ne "NotPresent" })

            ### BACK UP THE CURRENT PATH
            multi-PurposeLogging -message "$privMessagePrefix Backing up the current backup path." -level "information"
            $serverBackupPathHashtable = @{}
            foreach ( $dcsserver in $ssyvServers )
            {
                $serverID = $null
                $serverID = $dcsserver.id
                $currentBackupPath = $null
                $currentBackupPath = $dcsserver.BackupStorageFolder

                ## Adding the information to the hashtable
                $serverBackupPathHashtable.Add("$serverId","$currentBackupPath")
            }

            ### SETTING THE BACKUP PATH FOR TEMPORARY USE
            multi-PurposeLogging -message "$privMessagePrefix Setting temporary backup paths >$privTemporaryFolder<." -level "information"
            foreach ( $dcsserver in $ssyvServers )
            {
                ### First we need to check the configuration of the task
                if ( -not ( "$ssyvScheduledTaskName" -ieq "" ) )
                {
                    multi-PurposeLogging -message "$privMessagePrefix          ssyvScheduledTaskName : $ssyvScheduledTaskName" -level "verbose"
                    
                    ## Get the task
                    $taskId = $null
                    $taskId = $( get-dcstask -task "$ssyvScheduledTaskName" ).id
                    multi-PurposeLogging -message "$privMessagePrefix          taskId : $taskId" -level "verbose"
                    
                    ## The action for this server
                    $actionCaption = $null
                    if ( -not ( "$taskId" -eq "" ) )
                    {
                        $actionCaption = $( Get-DcsAction -Task "$taskid" | where { $_.caption -ilike "*on $($($dcsserver.hostname).split('.')[0])" } ).caption
                    }
                    multi-PurposeLogging -message "$privMessagePrefix          actionCaption : $actionCaption" -level "verbose"

                    ## Extract the local path
                    $thisServersRootBackupFolder = $null
                    if ( -not ( "$actionCaption" -eq "" ) )
                    {
                        $thisServersRootBackupFolder = $( $( $actionCaption -split "-ssyvServerBackupFolder")[1].Trim() -split " ")[0] -replace "`"",""  -replace "'",""
                    }
                    
                    ## Analysis
                    if ( -not ( "$thisServersRootBackupFolder" -eq "" ) )
                    {
                        if ( "$thisServersRootBackupFolder" -ieq "$privbackupPath" )
                        {
                            $thisServerLocalBackupRootFolder = $privbackupPath
                            multi-PurposeLogging -message "$privMessagePrefix          local backup path for server >$($($dcsserver.hostname).split('.')[0])< >$thisServersRootBackupFolder< does match backup path >$privbackupPath<. Will use >$privbackupPath<." -level "verbose"
                        }
                        else
                        {
                            multi-PurposeLogging -message "$privMessagePrefix          local backup path for server >$($($dcsserver.hostname).split('.')[0])< >$thisServersRootBackupFolder< does not match provided backup path >$privbackupPath<. Will use >$thisServersRootBackupFolder<." -level "verbose"
                            $thisServerLocalBackupRootFolder = $thisServersRootBackupFolder
                        }
                    }
                    else
                    {
                        multi-PurposeLogging -message "$privMessagePrefix          could not determine local backup path for server >$($($dcsserver.hostname).split('.')[0])< through the action. Will use default >$privbackupPath<." -level "warning"
                        $thisServerLocalBackupRootFolder = $privbackupPath
                    }
                }
                else
                {
                    $thisServerLocalBackupRootFolder = $privbackupPath
                }

                ### This is new and takes car of the governor path
                if ( $($($dcsserver.hostname).split('.')[0]) -ieq $(hostname) )
                {
                    $governorLocalBackupRootFolder = $null
                    $governorLocalBackupRootFolder = $thisServerLocalBackupRootFolder
                    multi-PurposeLogging -message "$privMessagePrefix          governorLocalBackupRootFolder : $governorLocalBackupRootFolder" -level "verbose"
                }

                $temporaryBackupPath = $null
                $temporaryBackupPath = "$thisServerLocalBackupRootFolder$($($dcsserver.hostname).split('.')[0])\$privTemporaryFolder\"
                
                $result = Set-DcsBackUpFolder -Server "$($($dcsserver.hostname).split('.')[0])" -Folder "$temporaryBackupPath"
                if ( $result )
                {
                    multi-PurposeLogging -message "$privMessagePrefix     >$($($dcsserver.hostname).split('.')[0])< success." -level "success"
                }
                else
                {
                    multi-PurposeLogging -message "$privMessagePrefix     >$($($dcsserver.hostname).split('.')[0])< failed." -level "error"
                    $errorOccured = $true
                }
            }

            ### INVOKING THE BACKUP
            if ( $errorOccured -eq $false )
            {
                multi-PurposeLogging -message "$privMessagePrefix invoking configuration backup." -level "information"
                $result = $null
                $result = Backup-DcsConfiguration

                ### We will wait a little before we proceed...
                sleepTimer -sleeptime 1 -maxCounter 5
            }

            ### WAITING / CHECKING FOR THE BACKUP RESULT
            if ( $errorOccured -eq $false )
            {
                ### This has been changed in 1.0.5 - Start
                ### Since the "backup-configuration" cmdlet does not provide a return value we have to check ourselves...
                foreach ( $dcsserver in $ssyvServers )
                {
                    ### depending if the servername is the local or the remote server.
                    $zipCheckPathPath = $null
                    if ( $($($dcsserver.hostname).split('.')[0]) -ieq "$(hostname)" )
                    {
                        $zipCheckPathPath = "$governorLocalBackupRootFolder$($($dcsserver.hostname).split('.')[0])\$privTemporaryFolder\"
                    }
                    else
                    {
                        $zipCheckPathPath = "\\$($($dcsserver.hostname).split('.')[0])\$globalMySSYVServerShareName\$($($dcsserver.hostname).split('.')[0])\$privTemporaryFolder\"
                    }
                    
                    multi-PurposeLogging -message "$privMessagePrefix zipCheckPathPath : $zipCheckPathPath" -level "verbose"

                    ### Checking for the backup result - depending on the configuration size a backup will take its time to be created
                    $retryMaxCount = 60
                    $i = 1
                    $waitTime = 5
                    $zipOldSize = -1
                    $zipDetected = $false

                    while ( $i -le $retryMaxCount )
                    {
                        ### checking if there is a zip
                        if ( $zipDetected -eq $false )
                        {
                            if ( $(Get-ChildItem -Path "$zipCheckPathPath" -ErrorAction SilentlyContinue | where { $_.Extension -ieq ".zip"} ).count -eq 1 )
                            {
                                multi-PurposeLogging -message "$privMessagePrefix >$($($dcsserver.hostname).split('.')[0])< ZIP file detected." -level "verbose"
                                $zipDetected = $true
                            }
                            else
                            {
                                multi-PurposeLogging -message "$privMessagePrefix >$($($dcsserver.hostname).split('.')[0])< waiting for the backup to finish. Sleep >$waitTime< seconds (>$i< of >$retryMaxCount<)." -level "verbose"
                            }
                            sleepTimer -sleeptime 1 -maxCounter $waitTime
                        }

                        # checking if the creation of the zip is still running. this is done through a size-check.
                        if ( $zipDetected -eq $true )
                        {
                            sleepTimer -sleeptime 1 -maxCounter $waitTime
                            multi-PurposeLogging -message "$privMessagePrefix     >$($($dcsserver.hostname).split('.')[0]))< performing size check (old zipsize >$zipOldSize<)." -level "verbose"
                            $currentZipSize = $(Get-ChildItem -Path "$zipCheckPathPath" -ErrorAction SilentlyContinue | where { $_.Extension -ieq ".zip"} ).length
                            multi-PurposeLogging -message "$privMessagePrefix          >$($($dcsserver.hostname).split('.')[0])< current zip size is >$currentZipSize<)." -level "verbose"
                            if ( $currentZipSize -eq $zipOldSize )
                            {
                                multi-PurposeLogging -message "$privMessagePrefix          >$($($dcsserver.hostname).split('.')[0])< success. Zip size has not changed since last check." -level "success"
                                break
                            }
                            else
                            {
                                if ( $currentzipSize -eq 0 )
                                {
                                    $zipOldSize = -1
                                }
                                else
                                {
                                    $zipOldSize = $currentZipSize
                                }
                                multi-PurposeLogging -message "$privMessagePrefix          >$($($dcsserver.hostname).split('.')[0])< waiting for the backup to finish. Sleep >$waitTime< seconds (>$i< of >$retryMaxCount<)." -level "verbose"
                                sleepTimer -sleeptime 1 -maxCounter $waitTime
                            }
                        }
                        
                        ### Sleeping
                        if ( $i -eq $retryMaxCount )
                        {
                            multi-PurposeLogging -message "$privMessagePrefix     >$($($dcsserver.hostname).split('.')[0])< failed. Error: $($error[0])." -level "error"
                            $errorOccured = $true
                            break
                        }
                        $i++
                    }
                }
            }

            ### Anyways we reset the backup configuration path to the thing before
            multi-PurposeLogging -message "$privMessagePrefix restoring original backup path for server all servers." -level "information"
            foreach ( $dcsserver in $ssyvServers )
            {
                $serverID = $null
                $serverID = $dcsserver.id

                $originalBackupPath = $null
                $originalBackupPath = $serverBackupPathHashtable.get_item("$serverID")

                # Using the script default path if there has not been stored somethign in the hashtable
                if ( $originalBackupPath -eq "" )
                {
                    $originalBackupPath = "$privbackupPath$($($dcsserver.hostname).split('.')[0])\"
                }

                $result = $null
                $result = Set-DcsBackUpFolder -Server "$serverID" -Folder "$originalBackupPath"
                
                if ( $result )
                {
                    multi-PurposeLogging -message "$privMessagePrefix     >$($($dcsserver.hostname).split('.')[0])< success." -level "success"
                }
                else
                {
                    multi-PurposeLogging -message "$privMessagePrefix     >$($($dcsserver.hostname).split('.')[0])< failed." -level "error"
                    $errorOccured = $true
                }
            }

            ### Anyways we close the connection
            $myConnection = dcsService-Connection -action "disconnect" -dataCoreServerSession $myConnection
        }
        else
        {
            multi-PurposeLogging -message "$privMessagePrefix could not connect to DCSX." -level "error"
            $errorOccured = $true
        }
    }

    ### the Returning value
    if ( $errorOccured -eq $true )
    {
        multi-PurposeLogging -message "$privMessagePrefix returns >false<" -level "error"
        return $false
    }
    else
    {
        multi-PurposeLogging -message "$privMessagePrefix returns >true<." -level "success"
        return $true
    }
}
#----------------------------------------------------------------------------------------------------------------------------------
function create-SSY-V-Powershellscripttask($taskName, $taskDescription, $taskScriptPath, $maxRuntime, $startTime, $argumentList, $triggerType, $dayinterval, $monitorID, $monitorState, $monitorComparison, $IgnoreActionReplacement)
{
    # Version 1.4

    $privTaskName = [string]$taskName
    $privTaskDescription = [string]$taskDescription
    $privtaskScriptPath = [string]$taskScriptPath
    $privdayinterval = [string]$dayinterval
    $privmaxRuntime = [string]$maxRuntime
    $privStarttime = [string]$startTime
    $privArgumentList = [string]$argumentList
    $privtriggerType = [string]$triggerType
    $privmonitorID = [string]$monitorID
    $privmonitorState = [string]$monitorState
    $privmonitorComparison = [string]$monitorComparison
    $privIgnoreActionReplacement = [boolean]$IgnoreActionReplacement

    $privMessagePrefix = "$($MyInvocation.InvocationName) :"
    multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix Function invoked. Parameter privTaskName has value >$privTaskName<, privTaskDescription has value >$privTaskDescription<, privtaskScriptPath is >$privtaskScriptPath<, privdayinterval is >$privdayinterval<, privmaxRuntime is >$privmaxRuntime< privStarttime is >$privStarttime<, argumentList is >$argumentList<, privtriggerType is >$privtriggerType<, privmonitorID is >$privmonitorID<, privmonitorState is >$privmonitorState<, privmonitorComparison is >$privmonitorComparison<." -level "verbose"
    
    $errorOccured = $false

    ### Parameter Validation
    if ( $privTaskName -eq "" -or $privTaskDescription -eq "" -or $privtaskScriptPath -eq "" )
    {
        multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix please provide at taskname and taskdescription." -level "error"    
        $errorOccured = $true    
    }

    if ( "$privtriggerType" -ieq "monitor" )
    {
        if ( "$privmonitorID" -eq "" -or "$privmonitorState" -eq "" -or "$privmonitorComparison" -eq "")
        {
            multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix Monitor was chosen as trigger type, but no monitorID, MonitorComparison or MonitorState provided." -level "error"
            $errorOccured = $true
        }
    }
    elseif ( "$privtriggerType" -ieq "time" )
    {
        if ( "$privStarttime" -eq "")
        {
            multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix Time was chosen as trigger type, but no privStarttime provided." -level "error"
            $errorOccured = $true
        }
    }
    elseif ( "$privtriggerType" -ieq "none" )
    {
        multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix no trigger type will be used." -level "verbose"
    }
    else
    {
        multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix unknown TriggerType >$privtriggerType<. Allowed are >time< and >monitor<." -level "error"
        $errorOccured = $true
    }

    ### Setting a default value
    if ( "$privmaxRuntime" -eq "" )
    {
        multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix no script max runtime provided. Choosing 30 minutes as default." -level "warning"
        $privmaxRuntime = "00:30:00"
    }


    ### THE DOING
    if ( $errorOccured -eq $false )
    {
        ### Connecting to the SSY-V service
        $myConnection = dcsService-Connection -action "connect" -user "$username" -password "$password" -hostname "$(hostname)" -usePassThroughAuth $true -retryCount 5 -retryTimeOut 45

        ### If we got an connection
	    if ( $myConnection )
        {
            $taskExists = $false
            $triggerExists = $false
            $actionExists = $false
            multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix Checking if the task exists." -level "information"
            
            ### CHECKING IF THE TASK EXISTS
            $result = $null
            $result = Get-DcsTask | where {$_.caption -ieq "$privTaskName"} -ErrorAction SilentlyContinue
        
            if ( $result -eq $null )
            {
                multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix task >$privTaskName< does not exist in the servergroup." -level "information"
                ### Creating the task
                multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix creating the task >$privTaskName<." -level "information"
                $taskisRunning = $true
                while ( $taskisRunning -eq $true )
                {
                    $result = $null
                    $result = Get-DcsTask | where {$_.caption -ieq "$privTaskName"} -ErrorAction SilentlyContinue
                    if ( $result )
                    {
                        break
                        multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix     task exists." -level "success"
                        $taskExists = $true
                    }
                    try
                    {
                        $result = $null
                        $result = add-dcstask -Name "$privTaskName" -Description "$privTaskDescription" -MaxRunTime $privmaxRuntime -ErrorAction Stop
                        sleepTimer -sleeptime 1 -maxCounter 30
                        multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix     success." -level "success"
                        $taskExists = $true
                        $taskisRunning = $false
                    }
                    catch
                    {
                        if ( "$($error[0])" -imatch "already exists in the configuration." )
                        {
                            $taskisRunning = $true
                            multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix     the task is currently running. Waiting for it to finish." -level "warning"
                            sleepTimer -sleeptime 1 -maxCounter 30
                        }
                        else
                        {
                            multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix     failed. This is the last errormessage: >$($error[0])<." -level "error"
                            $taskExists = $false
                            $errorOccured = $true
                        }
                    }
                }
            }
            else
            {
                multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix     success." -level "success"
                $taskExists = $true
            }

            ### CREATING THE TRIGGER
            if ( $taskExists -eq $true -and $errorOccured -eq $false )
            {
                multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix Checking for trigger in task." -level "information"
            
                sleepTimer -sleeptime 1 -maxCounter 2
                $result = $null

                ### Checking for the trigger depending on the privTriggerType
                if ( "$privtriggerType" -ieq "monitor" )
                {
                    if ( $privmonitorID -like "T*" )
                    {
                        $result = Get-DcsTrigger -Task "$privTaskName"
                        if ( $($result.type) -imatch "monitortrigger")
                        {
                            multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix at least one monitor trigger found." -level "verbose"
                            if ( $($result.MonitorTemplateTypeId) -ieq "$privmonitorID" )
                            {
                                multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix trigger found with monitor template ID." -level "verbose"
                                $triggerExists = $true
                            }
                        }
                    }
                    else
                    {
                        multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix this functionality is not implemented yet." -level "error"
                        $errorOccured = $true
                    }
                }
                elseif ( "$privtriggerType" -ieq "time" )
                {
                    $result = $null
                    $result = Get-DcsTrigger -Task "$privTaskName" | where {$_.type -ieq "ScheduledTrigger"}
                    if ( $result )
                    {
                        $triggerExists = $true
                    }
                }
                elseif ($privtriggerType -ieq "none")
                {
                    $triggerExists = $true
                }

                ### IF TRIGGER IS NOT THERE -> CREATE.
                if ( $triggerExists -eq $false )
                {
                    multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix no trigger found in task." -level "information"
                    ### TIME
                    if ( $privtriggerType -ieq "time" )
                    {
                        multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix creating recurring time trigger for task." -level "information"
                        $result = $null
                        $result = Add-DcsTrigger -Task "$privTaskName" -StartTime $privStarttime -DayInterval $privdayinterval -SignalDuration 00:00:00
                        if ( $result )
                        {
                            multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix     success." -level "success"
                            $triggerExists = $true
                        }
                        else
                        {
                            multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix     failed." -level "error"
                            $triggerExists = $false
                            $errorOccured = $true
                        }
                    }
                    ### MONITOR TEMPLATE
                    elseif ( $privtriggerType -ieq "monitor" )
                    {
                        multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix creating monitor trigger for task." -level "information"
                        $result = $null
                        if ( $privmonitorID -like "T(*" )
                        {
                            $result = Add-DcsTrigger -Task "$privTaskName" -TemplateTypeId "$privmonitorID" -MonitorState "$privmonitorState" -Comparison "$privmonitorComparison"
                            if ( $result )
                            {
                                multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix     success." -level "success"
                                $triggerExists = $true
                            }
                            else
                            {
                                multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix     failed." -level "error"
                                $triggerExists = $false
                                $errorOccured = $true
                            }
                        }
                        else
                        {
                            multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix this functionality is not implemented yet." -level "error"
                            $errorOccured = $true
                        }
                    }
                }
                else
                {
                    multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix     success." -level "success"
                    $triggerExists = $true
                }
            }
            
            ### CREATING THE ACTION        
            if ( $triggerExists -eq $true -and $taskExists -eq $true -and $errorOccured -eq $false )
            {
                multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix Checking if there is an action for this server >$(hostname)<." -level "information"
                
                $localServerID = $null
                $localServerID = (Get-DcsServer -Server "$(hostname)").id
                
                sleepTimer -sleeptime 1 -maxCounter 2
                $result = $null
                $result = Get-DcsAction -Task "$privTaskName" | where {$_.serverid -ieq "$localServerID" -and $_.filename -ieq "$privtaskScriptPath"}
                $createAction = $false

                if ( $result -eq $null )
                {
                    multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix      no action found in task for this server." -level "information"
                    $createAction = $true
                }
                else
                {
                    if ( $privIgnoreActionReplacement -eq $true )
                    {
                        multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix          >privIgnoreActionReplacement< is >true< so skipping replacement of action." -level "information"
                        $actionExists = $true                        
                    }
                    elseif ( "$($result.ScriptParams)" -ieq "$privArgumentList" )
                    {
                        multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix          success." -level "success"
                        $actionExists = $true                        
                    }
                    else
                    {
                        multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix      action found but parameters do not match. Removing old action." -level "information"
                        $createAction = $true
                        ## Deleting the old action
                        $result = Remove-DcsAction -Action "$($result.id)"
                        if ( $? -eq $true )
                        {
                            multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix          success." -level "success"
                        }
                        else
                        {
                            multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix          failed." -level "error"
                            $errorOccured = $true
                        }
                    }
                }

                if ( $createAction -eq $true -and $errorOccured -eq $false )
                {
                    multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix creating action to perform backup script on this server." -level "information"
                    $result = $null
                    if ( $privArgumentList -eq "" )
                    {
                        $result = Add-DcsAction -Task "$privTaskName" -Server $localServerID -ScriptAction PowerShell -FilePath "$privtaskScriptPath"
                    }
                    else
                    {
                        $result = Add-DcsAction -Task "$privTaskName" -Server $localServerID -ScriptAction PowerShell -FilePath "$privtaskScriptPath" -ScriptParams "$privArgumentList"
                    }

                    if ( $result )
                    {
                        multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix     success." -level "success"
                        $actionExists = $true
                    }
                    else
                    {
                        multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix     failed." -level "error"
                        $actionExists = $false
                        $errorOccured = $true
                    }
                }
            }

            ### Anyways we close the connection
            $myConnection = dcsService-Connection -action "disconnect" -dataCoreServerSession $myConnection
        }
        else
        {
            multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix could not connect to DCSX." -level "error"
            $errorOccured = $true
        }
    }

    ### the Return value
    if ( $errorOccured -eq $true )
    {
        multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix returns >false<" -level "error"
        return $false
    }
    else
    {
        multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix returns >true<" -level "success"
        return $true
    }
}

###################################################################################################################################
##### FUNCTIONS STARTING WITH >D<
#----------------------------------------------------------------------------------------------------------------------------------
function DataCorePSModule($action)
{
    # Version 1.3

    $privAction = [string]$action.toLower()

    $privMessagePrefix = "$($MyInvocation.InvocationName) :"
    multi-PurposeLogging -message "$privMessagePrefix Function invoked with parameter privAction >$privAction<." -level "verbose"
    
    $errorOccured = $false
    if ( -not ( "$privaction" -ieq "load" ) -and -not ( "$privAction" -ieq "unload" ) )
    {
        multi-PurposeLogging -message "$privMessagePrefix wrong parameter value for privAction. Only >load< and >unload< is allowed." -level "error"
        $errorOccured = $true
    }

    ### The Doing
    if ( $errorOccured -eq $false )
    {
        if ( "$privAction" -ieq "load" )
        {
            ### Unload the module if loaded
            multi-PurposeLogging -message "$privMessagePrefix Checking for already loaded DataCore Powershell module ..." -level "verbose"
            if ( -not ( $( Get-Module -name "DataCore.Executive.Cmdlets" ) -eq $null ) )
            {
                multi-PurposeLogging -message "$privMessagePrefix unloading already loaded DataCore Powershell module ..." -level "verbose"
                $result = $null
                $result = DataCorePSModule -action "unload"
                if ( $result -eq $false )
                {
                    $errorOccured = $true
                }
            }

            ### Loading the module
            if ( $errorOccured -eq $false )
            {
                multi-PurposeLogging -message "$privMessagePrefix Loading DataCore Powershell module ..." -level "information"
                # Get the installation path of SANsymphonyV
                $bpKey = 'BaseProductKey'
                $regKey = Get-Item "HKLM:\Software\DataCore\Executive" -ErrorAction SilentlyContinue
                if ( -not ( "$regKey" -ieq "" ) )
                {
                    $strProductKey = $regKey.getValue($bpKey)
                    $regKey = Get-Item "HKLM:\$strProductKey" -ErrorAction SilentlyContinue
                    $installPath = $regKey.getValue('InstallPath')
                    ### We can´t use this directly in IF as this does not give true or false back
                    # import the module
                    Import-Module "$installPath\DataCore.Executive.Cmdlets.dll" -DisableNameChecking -ErrorAction SilentlyContinue
                    # Check the result
                    if ( $? -eq $true )
                    {
                        if ( get-module -Name "DataCore.Executive.Cmdlets" )
                        {
                            multi-PurposeLogging -message "$privMessagePrefix     success." -level "success"
                        }
                        else
                        {
                            multi-PurposeLogging -message "$privMessagePrefix     failed. This is the last error-message >$($error[0])<." -level "error"
                            $errorOccured = $true
                        }
                    }
                    else
                    {
                        multi-PurposeLogging -message "$privMessagePrefix     error loading powershell module." -level "error"
                        $errorOccured = $true
                    }
                }
                else
                {
                    multi-PurposeLogging -message "$privMessagePrefix could not find registry hive for SANsymphony-V. It seems that it is not installed." -level "error"
                    $errorOccured = $true
                }
            }
            else
            {
                multi-PurposeLogging -message "$privMessagePrefix failed to unload the module." -level "error"
                $errorOccured = $true
            }
        }
        elseif ( "$privAction" -eq "unload" )
        {
            $moduleLoaded = $false
            # We will unload the module if it is already loaded. To make shure everything is fine when we load it!
            if ( get-module -Name "DataCore.Executive.Cmdlets" )
            {
                multi-PurposeLogging -message "$privMessagePrefix DataCore Commandlets loaded. Will unload them..." -level "information"
                ### We can´t use this directly in IF as this does not give true or false back
                Remove-Module -Name "DataCore.Executive.Cmdlets" -ErrorAction SilentlyContinue
                if ( $? -eq $true )
                {
                    multi-PurposeLogging -message "$privMessagePrefix     success." -level "success"
                }
                else
                {
                    multi-PurposeLogging -message "$privMessagePrefix     failed. This is the last error-message >$($error[0])<." -level "error"
                    $errorOccured = $true
                }
            }
            else
            {
                multi-PurposeLogging -message "$privMessagePrefix DataCore Commandlets not loaded." -level "information"
            }
        }
    }

    ### Return value of the function
    if ( $errorOccured -eq $false )
    {
        multi-PurposeLogging -message "$privMessagePrefix returns >true<." -level "success"
        return $true
    }
    else
    {
        multi-PurposeLogging -message "$privMessagePrefix returns >false<." -level "error"
        return $false
    }
}
#----------------------------------------------------------------------------------------------------------------------------------
function dcsService-Connection($user, $password, $hostname, $action, $dataCoreServerSession, $usePassThroughAuth, $powerShellVersion, $retryCount, $retryTimeOut)
{
    # Version 1.9
    $ErrorOccured = $false

    try
    {
        # checking if we have an interactive anvironment
        if ([Environment]::UserInteractive)
        {
            $privScriptEnvironment = "interactive"
        }
        else
        {
            $privScriptEnvironment = "batch"
        }
        # Parameters
        $privUser = "$user"
        $privPassword = "$password"
        $privHostname = "$hostname"
        $privPowerShellVersion = "$powerShellVersion"
        $privAction = "$action"
        $privDataCoreServersession = $dataCoreServersession
        $privUsePassThroughAuth = [boolean]$usePassThroughAuth
        $privRetryCount = $retryCount
        $privRetryTimeout = $retryTimeOut
    }
    catch
    {
        $ErrorOccured = $true
    }

    $privMessagePrefix = "$($MyInvocation.InvocationName) :"
    multi-PurposeLogging -message "$privMessagePrefix Function invoked with parameters: privuser is >$privUser<, privPassword length is >$($privPassword.length)<, privHostname is >$privHostname<, privAction is >$privAction<, privDataCoreServersession is >$privDataCoreServersession<, privUsePassthroughAuth is >$privUsePassThroughAuth<, privPowershellversion is >$privPowerShellVersion<, privRetryCount is >$privRetryCount<, privRetryTimeout is >$privRetryTimeout<." -level "verbose" 

    ### CHECKING
    # some basic stuff...
    if ( -not ( "$privAction" -ieq "connect" ) -and -not ( "$privAction" -ieq "disconnect" ) -and -not ( "$privAction" -ieq "cleanup" ) )
    {
        multi-PurposeLogging -message "$privMessagePrefix wrong parameter for >privAction<. Only >connect<, >disconnect< and >cleanup< is allowed." -level "error" 
        $ErrorOccured = $true
    }
    # If no Powershell-Version is provided we use the "failsafe" mode for 2.0
    if ( $privPowerShellVersion -eq $null )
    {
        multi-PurposeLogging -message "$privMessagePrefix no Powershell version provided. Assuming Powershell 2.0 for fail safe reasons." -level "warning" 
        $privPowerShellVersion = "2.0"
    }
    # On connection: If we have an batch environment and no passthrough auth or username and password we exit here..
    if ( "$privAction" -ieq "connect" -and `
         ( ( $privScriptEnvironment -eq "batch" -and $privUsePassThroughAuth -ne $true ) -and `
           ( $privScriptEnvironment -eq "batch" -and ($privUser -eq "" -or $privUser -eq $null ) ) -and `
           ( $privScriptEnvironment -eq "batch" -and ($privPassword -eq "" -or $privPassword -eq $null ) ) ) )
    {
        multi-PurposeLogging -message "$privMessagePrefix script runnning in batch mode but neiter >privUsePassthroughauth< nor >privUser< or >privPassword< provided. " -level "error" 
        $ErrorOccured = $true
    }
    # On Disconnect we need a valid session.
    if ( "$privAction" -ieq "disconnect" -and $privDataCoreServersession -eq $null )
    {
        multi-PurposeLogging -message "$privMessagePrefix no valid >dataCoreServerSession< provided." -level "error" 
        multi-PurposeLogging -message "$privMessagePrefix     if you do not know your session use the >cleanup< action instead." -level "error" 
        $ErrorOccured = $true
    }

    ### Checking if we have the DataCore Module loaded
    if ( $ErrorOccured -eq $false )
    {
        if ( $( Get-Module -name "DataCore.Executive.Cmdlets" ) -eq $null )
        {
            $result = $null
            $result = DataCorePSModule -action "load"
            if ( $result -eq $false )
            {
                $errorOccured = $true
            }
        }
        else
        {
            multi-PurposeLogging -message "$privMessagePrefix DataCore CMdlet module already loaded." -level "verbose"
        }
    }

    ### THE DOING
    if ( $ErrorOccured -eq $false )
    {
        ### CONNECT
        # The rest of the checks is inside because it does not make sense somewhere else.
        if ( "$privAction" -ieq "connect")
        {
            ### Retry Count
            if ( $privRetryCount -lt 1 -or "$privRetryCount" -eq "" -or $privRetryCount -eq $null )
            {
                multi-PurposeLogging -message "$privMessagePrefix using default retry count of 5." -level "warning" 
                $privRetryCount = 5
            }
            ### Retry Timeout
            if ( $privRetryTimeout -lt 1 -or "$privRetryTimeout" -eq "" -or $privRetryTimeout -eq $null )
            {
                multi-PurposeLogging -message "$privMessagePrefix using default retry timeout of 30s." -level "warning" 
                $privRetryTimeout = 30
            }
            ### checking the required information regarding hostname. this is only necessary for the connect
            if ( "$privHostname" -eq "" -or $privHostname -eq $null)
            {
                multi-PurposeLogging -message "$privMessagePrefix no hostname specified. Assuming local server is target." -level "warning" 
                $privHostname = hostname
            }
            
            ### IF THERE IS NO PASS THROUGH AUTH ASK FOR CREDENTIALS
            $privMyCredential = $null
            if ( $privUsePassThroughAuth -eq $false )
            {
                # Getting the credentials ready
                if ( $privUser -eq $null -or "$privUser" -eq "" -or $privPassword -eq $null -or "$privPassword" -eq "" )
                {
                    multi-PurposeLogging -message "$privMessagePrefix No user or no password provided. Please provide credentials!" -level "warning" 
                    if ( "$powerShellVersion" -eq "2.0" )
                    {
                        $privMyCredential = get-credential
                    }
                    elseif ( "$privPowerShellVersion" -like "3.*" -or "$privPowerShellVersion" -like "4.*" )
                    {
                        $privMyCredential = get-credential -Message "Please provide valid credentials for the DataCore Executive Service connection."
                    }
                    else
                    {
                        multi-PurposeLogging -message "$privMessagePrefix no valid PS-Version provided." -level "error" 
                        $ErrorOccured = $true
                    }
                }
                else
                {
                    $privSecureString = ConvertTo-SecureString $privPassword -AsPlainText -Force
                    $privMyCredential = new-object system.management.automation.PSCredential $privUser,$privSecureString
                }

                ### Checking if we got a credential
                if ( -not $privMyCredential)
                {
                    multi-PurposeLogging -message "$privMessagePrefix no credentials could be created." -level "error" 
                    $ErrorOccured = $true
                }
            }
            
            ### if there is still no error we can proceed.
            if ( $ErrorOccured -eq $false )
            {
                $i = 1
                while ( $i -le $privRetryCount )
                {
                    try
                    {
                        $privDcsServerConnection = $null
                        # With Passthrough authentication
                        if ( $usePassThroughAuth -eq $true )
                        {
                            multi-PurposeLogging -message "$privMessagePrefix Connecting to the DataCore Executive service with passthrough authentication." -level "information" 
                            $privDcsServerConnection = Connect-DcsServer -Server "$privHostname" -ErrorAction SilentlyContinue
                        }
                        # or with credentials
                        else
                        {
                            multi-PurposeLogging -message "$privMessagePrefix Connecting to the DataCore Executive service." -level "information"     
                            $privDcsServerConnection = Connect-DcsServer -Credential $privMyCredential -Server "$privHostname" -ErrorAction SilentlyContinue
                        }
                        
                        if ( $privDcsServerConnection )
                        {
                            multi-PurposeLogging -message "$privMessagePrefix     success (try >$i< of >$privRetryCount<)." -level "success" 
                            # resetting the error variable if we could not connect the try upfront.
                            $ErrorOccured = $false
                            break
                        }
                    }
                    catch
                    {
                        multi-PurposeLogging -message "$privMessagePrefix     failed (try >$i< of >$privRetryCount<). This is the error-message: >$($Error[0])<." -level "error" 
                        $ErrorOccured = $true
                    }

                    # Increment and sleep
                    multi-PurposeLogging -message "$privMessagePrefix     sleeping >$privRetryTimeout< seconds and the retrying." -level "verbose" 
                    $i++

                    ### Sleeping before we retry
                    sleepTimer -sleeptime 1 -maxCounter $privRetryTimeout
                }
            }
        }
        ### DISCONNECT
        elseif ( "$privAction" -eq "disconnect" )
        {
            multi-PurposeLogging -message "$privMessagePrefix Disconnecting from DataCore Server Session." -level "information" 
            try
            {
                Disconnect-DcsServer -connection $privDataCoreServersession -ErrorAction stop
                multi-PurposeLogging -message "$privMessagePrefix     success." -level "success" 
            }
            catch
            {
                multi-PurposeLogging -message "$privMessagePrefix     failed (try >$i< of >$privRetryCount<). This is the error-message: >$($Error[0])<." -level "error" 
                $ErrorOccured = $true
            }
        }
        ### CLEANUP
        elseif ( "$privaction" -ieq "cleanup" )
        {
            multi-PurposeLogging -message "$privMessagePrefix cleaning all DataCore Server Sessions from this Powershell-Session." -level "information" 
            $removedSessions = 0
            while ( $true )
            {
                $temp = $null
                try
                {
                    $temp = Get-DcsServer
                }
                catch
                {
                    # just do nothing
                }

                # if we got an result
                if ($temp -ne $null)
                {
                    Disconnect-DcsServer -ErrorAction SilentlyContinue
                    if ( $? -eq $true )
                    {
                        multi-PurposeLogging -message "$privMessagePrefix successfully disconnected session." -level "success" 
                        $removedSessions++
                    }
                    else
                    {
                        multi-PurposeLogging -message "$privMessagePrefix failed to disconnect session. This is the error-message: >$($Error[0])<." -level "error" 
                        $ErrorOccured = $true
                    }

                    # sleep
                    sleepTimer -sleeptime 1 -maxCounter 2
                }
                else
                {
                    # we break the loop and reset the error.
                    $ErrorOccured = $false
                    break
                }
            }

            multi-PurposeLogging -message "$privMessagePrefix >$removedSessions< connections have been cleared from this Powershell-Session." -level "information" 
        }
    }

    ### Return value of the function
    if ( $errorOccured -eq $false )
    {
        if ( "$privAction" -ieq "connect" )
        {
            multi-PurposeLogging -message "$privMessagePrefix returns the session token." -level "success"
            return $privDcsServerConnection
        }
        elseif ( "$privAction" -ieq "disconnect" -or "$privAction" -ieq "cleanup" )
        {
            multi-PurposeLogging -message "$privMessagePrefix returns >true<." -level "success"
            return $true
        }
    }
    else
    {
        multi-PurposeLogging -message "$privMessagePrefix returns >false<." -level "error"
        return $false
    }
}

###################################################################################################################################
##### FUNCTIONS STARTING WITH >E<
#----------------------------------------------------------------------------------------------------------------------------------
function elect-SSY-V-Script-Governor($skipElection)
{
    # Version 1.2

    $privSkipElection = [string]$skipElection
    
    $privMessagePrefix = "$($MyInvocation.InvocationName) :"
    multi-PurposeLogging -message "$privMessagePrefix Function invoked with parameter privSkipElection >$privSkipElection<." -level "verbose"

    ### Connecting to the SSY-V server
    $myConnection = $null
    $myConnection = dcsService-Connection -action "connect" -hostname "$(hostname)" -usePassThroughAuth $true -retryCount 5 -retryTimeOut 45

    ### If we got an connection we can proceed
	if ( $myConnection )
    {
        if ( $privSkipElection -eq $false )
        {
            # Check for Governor existence and loop until only a single Governor is identified.
            $Governors = 0
            $Governor = $null
            $Online=$true
            while ( $Governors -eq 0 -or $Governor -eq $null -and $Online )
            {
	            # Servers in Remote Server Group do not have a RegionNodeId, check Governor status only for servers in the local Server Group
	            ### This has been changed in 1.0.1 - Start
                $Servers = $null
                $Servers = @(Get-DcsServer | where {$_.RegionNodeID -ne $null -and $_.state -ne "NotPresent" })
                ### This has been changed in 1.0.1 - End
                #$Servers = @(Get-DcsServer | where {$_.RegionNodeID -ne $null})
                $ServerCount = $null
                $ServerCount = $Servers.count
	            $Governor = $null
	            $Governors = 0
	            $Myself = $null
	            foreach ( $Server in $Servers )
		        {
                    ### This has been changed in 1.0.3 - Start
		            if ( $(Hostname) -ieq $(@($Server.hostname -split "\.")[0]) )
			        {
			            # Identify myself
			            $Myself = $Server
			            # Check if I am online or not
			            if ( (Get-DcsServer -Server $Myself).state -imatch "Online" )
				        {
				            $Online = $True
				        }
			            else
				        {
				            $Online = $False
				        }
		            }
                    ### This has been changed in 1.0.3 - End
		            if ( ($Server.description).startswith("[GOVERNOR]") -and $Governor -eq $null -and $Server.State -imatch "Online" )
			        {
			            #Governor Located
			            $Governor = $Server
			            $Governors++
			            # Wait for a random time to not collide with other hotspare scripts running in the same server group
			            sleep ( get-Random -minimum 0 -Maximum $ServerCount -SetSeed (Get-Date).millisecond )
			        }
		            elseif ( $Server.description.startswith("[GOVERNOR]" ) -and $Governor -ne $null) 
			        {
			            #Duplicate Governor detected, remove second find
			            $Governors++
                        multi-PurposeLogging -message "$privMessagePrefix Detected >$($Server.caption)< to be a duplicate Governor and removed his Governor status." -level "warning"
			            $null = set-dcsserverproperties -Server $Server -Description ($Server.description).replace("[GOVERNOR]","")
			            # Wait for a random time to not collide with other hotspare scripts running in the same server group
			            sleep (get-Random -minimum 0 -Maximum $ServerCount -SetSeed (Get-Date).millisecond)
                    }
		            elseif ( $Server.description.startswith("[GOVERNOR]" ) -and $Server.State -inotmatch "Online") 
			        {
			            $Governors++
			            #Offline Governor detected, remove him
                        multi-PurposeLogging -message "$privMessagePrefix Detected >$($Server.caption)<  to be an offline Governor and removed his Governor status." -level "warning"
			            $null = set-dcsserverproperties -Server $Server -Description ($Server.description).replace("[GOVERNOR]","")
			            # Wait for a random time to not collide with other hotspare scripts running in the same server group
			            sleep (get-Random -minimum 0 -Maximum $ServerCount -SetSeed (Get-Date).millisecond)
                    }
		        }
	
	            if ( $Governor -eq $null -and $Online )
		        {
		            # No Governor elected, make myself the new Governor if I am online
                    multi-PurposeLogging -message "$privMessagePrefix No Governor found, electing myself as active Governor." -level "information"
		            $null = Set-DcsServerProperties -Server $Myself -Description ("[GOVERNOR]"+$Myself.Description)
		        }
            }
        }
        else
        {
            $Servers = @( Get-DcsServer | where {$_.RegionNodeID -ne $null} )
        }
        
        ### Anyways we close the connection
        $myConnection = dcsService-Connection -action "disconnect" -dataCoreServerSession $myConnection
    }
    else
    {
        multi-PurposeLogging -message "$privMessagePrefix could not connect to DCSX." -level "error"
        $errorOccured = $true
    }

    ### Returning the value depending if this server was elected or not.
    if ( $privSkipElection -eq $true )
    {
        multi-PurposeLogging -message "$privMessagePrefix parameter >privSkipElection< was used to ignore election. Function returns an object set of all other servers >$Servers<." -level "success"
        return $Servers
    }
    elseif ( $Myself -eq $Governor )
	{
        multi-PurposeLogging -message "$privMessagePrefix this server was elected. Function returns an object set of all other servers >$Servers<." -level "success"
        return $Servers
    }
    else
    {
        multi-PurposeLogging -message "$privMessagePrefix this server was not elected. Function returns >false<." -level "error"
        return $false
    }
}
#----------------------------------------------------------------------------------------------------------------------------------
function export-SSY-V-DcsObjectModel ($backupPath, $temporaryFolder)
{
    # Version 1.2
    ## Two seperate sections of the path need to be gathered as the function inserts hostnames into the path dynamically.
    $errorOccured = $false

    try
    {
        $privTemporaryFolder = [string]$temporaryFolder
        $privbackupPath = [string]$backupPath
    }
    catch
    {
        $errorOccured = $true
    }
    
    $privMessagePrefix = "$($MyInvocation.InvocationName) :"
    multi-PurposeLogging -message "$privMessagePrefix Function invoked. Parameter privbackupPath has value >$privbackupPath<, privTemporaryFolder is >$privTemporaryFolder<." -level "verbose"
        
    ### Parameter Validation
    if ( "$privbackupPath" -eq "" )
    {
        multi-PurposeLogging -message "$privMessagePrefix please provide a backup path." -level "error"    
        $errorOccured = $true    
    }
    elseif ( -not ($privbackupPath.Substring($privbackupPath.Length -1, 1) -ieq "\" ) )
    {
        multi-PurposeLogging -message "$privMessagePrefix missing backslash. Adding it to the path provided." -level "warning"
        $privbackupPath = "$privbackupPath\"
    }

    ### The Doing
    if ( $errorOccured -eq $false )
    {
        ### Connecting to the SSY-V service
        $myConnection = dcsService-Connection -action "connect" -user "$username" -password "$password" -hostname "$(hostname)" -usePassThroughAuth $true -retryCount 5 -retryTimeOut 45

        ### If we got an connection we modify the cache
	    if ( $myConnection )
        {
            ### EXPORT MODEL
            $targetBackupPath = $null
            $targetBackupPath = "$privbackupPath$(hostname)\$privTemporaryFolder\"
            multi-PurposeLogging -message "$privMessagePrefix invoking export dcsobjectmodel command and exporting object model to >$targetBackupPath<." -level "information"
            $result = $null
            $result = Export-DcsObjectModel -OutputDirectory "$targetBackupPath"

            ### We need to wait a little ...
            sleepTimer -sleeptime 1 -maxCounter 3

            $objectModelPath = "$targetBackupPath"+"DcsObjectModel.xml"
            if ( Get-Item -Path "$objectModelPath" -ErrorAction SilentlyContinue )    
            {
                multi-PurposeLogging -message "$privMessagePrefix     success." -level "success"
            }
            else
            {
                multi-PurposeLogging -message "$privMessagePrefix     failed." -level "error"
                $errorOccured = $true
            }

            ### Anyways we close the connection
            $myConnection = dcsService-Connection -action "disconnect" -dataCoreServerSession $myConnection
        }
        else
        {
            multi-PurposeLogging -message "$privMessagePrefix could not connect to DCSX." -level "error"
            $errorOccured = $true
        }
    }

    ### the Returning value
    if ( $errorOccured -eq $true )
    {
        multi-PurposeLogging -message "$privMessagePrefix returns >false<" -level "error"
        return $false
    }
    else
    {
        multi-PurposeLogging -message "$privMessagePrefix returns >true<." -level "success"
        return $true
    }
}

###################################################################################################################################
##### FUNCTIONS STARTING WITH >F<
#----------------------------------------------------------------------------------------------------------------------------------
function file-Logging($message, $logFileAbsolutePathName, $append)
{
    # Version 1.6
    $privMessagePrefix = "$($MyInvocation.InvocationName) :"

    $privAbsolutePathToLogFile = [string]$logFileAbsolutePathName
    $privLoggingMessage = [string]$message   
    $privAppend = [boolean]$append

    $ErrorOccured = $false

    ### Parameter checking
    if ( "$privLoggingMessage" -eq "" )
    {
        # We should have at least on blank in the line.
        $privLoggingMessage = " "
    }
    # Checking if a path is provided
    if ( "$privAbsolutePathToLogFile" -eq "" -or $privAbsolutePathToLogFile -eq $null)
    {
        if ([Environment]::UserInteractive)
        {
            Write-Host ">>>>> $privMessagePrefix empty string provided for path value. Can´t log the message >$privLoggingMessage<." -ForegroundColor Red
        }
        $ErrorOccured = $true
    }
    else
    {
        # Checking if the provided path is a folder
        if (Test-Path -path "$privAbsolutePathToLogFile" -PathType Container)
        {
            if ([Environment]::UserInteractive)
            {
                Write-Host ">>>>> $privMessagePrefix Can´t log the message >$privLoggingMessage< to a folder." -ForegroundColor Red
            }
            $ErrorOccured = $true
        }
        # Checking if the file is there
        else
        {
            # If it is not yet there and we have append = true we will fail
            if ( ! (Test-Path -path "$privAbsolutePathToLogFile") -and $privAppend -eq $true )
            {
                $privAppend = $false
            }
        }
    }

    # Writing to the file
    if ( $ErrorOccured -eq $false )
    {
        ### Checking the encoding if there is content in the file.
        $encoding = "unknown"
        [byte[]]$byte = get-content -Encoding byte -ReadCount 4 -TotalCount 4 -Path "$privAbsolutePathToLogFile" -ErrorAction SilentlyContinue
        if ($byte -ne $null)
        {
            if ( $byte[0] -eq 0xef -and $byte[1] -eq 0xbb -and $byte[2] -eq 0xbf )
            { 
                $encoding = "UTF8"
            }
            elseif ($byte[0] -eq 0xfe -and $byte[1] -eq 0xff)
            {
                $encoding = "Unicode"
            }
            elseif ($byte[0] -eq 0 -and $byte[1] -eq 0 -and $byte[2] -eq 0xfe -and $byte[3] -eq 0xff)
            {
                $encoding = "UTF32"
            }
            elseif ($byte[0] -eq 0x2b -and $byte[1] -eq 0x2f -and $byte[2] -eq 0x76)
            {
                $encoding = "UTF7"
            }
            else
            {
                $encoding = "ASCII"
            }
        }
        ### if there is no content: Assuming ASCII
        else
        {
            $encoding = "ASCII"
        }

        ### Writing the content to file
        if ($privAppend -eq $false)
        {
            Write-Output "$privLoggingMessage" | Out-File -filePath "$privAbsolutePathToLogFile" -Encoding $encoding
        }
        else
        {
            # We can only append if a file is already there.
            if (Get-Item -Path "$privAbsolutePathToLogFile" -Force -ErrorAction SilentlyContinue)
            {
                Write-Output "$privLoggingMessage" | Out-File -filePath "$privAbsolutePathToLogFile" -Encoding $encoding -Append
            }
            else
            {
                if ( [Environment]::UserInteractive )
                {
                    Write-Host ">>>>> $privMessagePrefix could not find path >$privAbsolutePathToLogFile<." -ForegroundColor Red
                }
            }
        }
    }
}

###################################################################################################################################
##### FUNCTIONS STARTING WITH >G<
#----------------------------------------------------------------------------------------------------------------------------------
function get-NiceTimeStamp()
{
    # function to get a nice timestamp with the following format
    $date = Get-Date -Format yyyy-MM-dd__HH-mm-ss
    return $date
}
#----------------------------------------------------------------------------------------------------------------------------------
function get-osLanguage()
{
    $privMessagePrefix = "$($MyInvocation.InvocationName) :"
    multi-PurposeLogging -message "$privMessagePrefix Function invoked without parameters." -level "verbose"
    
    # Getting the OS Language from WMI
    $languageCode = $null
    $languageCode = ($Win32_OS = Get-WmiObject Win32_OperatingSystem).oslanguage
    $languageInstalled = $null
    if ($languageCode -eq "1031")
    {
        $languageInstalled = "german"
        multi-PurposeLogging -message "$privMessagePrefix returns >$languageInstalled<." -level "success"
        return $languageInstalled
    }
    elseif ($languageCode -eq "1033")
    {
        $languageInstalled = "english"
        multi-PurposeLogging -message "$privMessagePrefix returns >$languageInstalled<." -level "success"
        return $languageInstalled
    }
    else
    {
        multi-PurposeLogging -message "$privMessagePrefix returns >false<." -level "error"
        return $false
    }
}
#----------------------------------------------------------------------------------------------------------------------------------
function get-PowershellVersion()
{
    # Version 1.1
    $privMessagePrefix = "$($MyInvocation.InvocationName) :"
    multi-PurposeLogging -message "$privMessagePrefix Function invoked without parameters." -level "verbose"

    $ErrorOccured = $false 
    $psVersion = $null
    
    ### The Doing
    if ( $ErrorOccured -eq $false )
    {
        # Tryining to get the PSversion from an PS Object
        $psversionObject = $null
        $psversionObject = $PSVersionTable.PSVersion
        $majorVersion = $null
        $majorVersion = $psversionObject.Major
        $minorVersion = $null
        $minorVersion = $psversionObject.Minor
        $psVersion = [float]$("$majorVersion" + "." + "$minorVersion")
        
        # if we do not get any Information then its either PS Version 1.0 because this table was introduced in 2.0 or Powershell is not available at all
        if ( $psVersion -eq $null )
        {
            ## We are checking against the registry if PS is available at all
            # moving to the HKLM drive
            Set-Location HKLM:
            $registryValue = $null
            $registryValue = Get-ItemProperty HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\PowerShell\1\PowerShellEngine -ErrorAction SilentlyContinue
            if ( $registryValue -ne $null )
            {
                $psVersion = [float]$($registryValue.PowerShellVersion)
            }
            else
            {
                multi-PurposeLogging -message "$privMessagePrefix could not determine Powershell version." -level "error"
                $ErrorOccured = $false
            }
        }
    }

    ### Return value of the function
    if ( $ErrorOccured -eq $true )
    {
        multi-PurposeLogging -message "$privMessagePrefix returns >false<." -level "error"
        return $false
    }
    else
    {
        multi-PurposeLogging -message "$privMessagePrefix psversion is >$psVersion<." -level "verbose"
        return [float]$psVersion
    }
}
#----------------------------------------------------------------------------------------------------------------------------------
function get-scriptabsolutefolderpath()
{
    # Version 1.1

    # gets the parent path of the script. Is used to determine where to write logs etc.
    $ErrorOccured = $false

    ### THE DOING
    $myAbsoluteScriptPath = $null
    $myAbsoluteScriptPath = $($MyInvocation.PSCommandPath) -split "\\"
    $myAbsoluteScriptPath = $myAbsoluteScriptPath[0..($myAbsoluteScriptPath.count-2)] -join '\'
    $myAbsoluteScriptPath += "\"
    if ( $myAbsoluteScriptPath )
    {
        # if we have a string not like C:\ or any other drive mapping 
        if ( $myAbsoluteScriptPath -notlike "*:\*")
        {
            $ErrorOccured = $true
        }
        else
        {
            # Adding a Backslash if necessary
            $pathStringLength = $($myAbsoluteScriptPath.Length)
            if ( $( "$myAbsoluteScriptPath".Substring($pathStringLength-1) ) -ne "\" )
            {
                $myAbsoluteScriptPath = "$myAbsoluteScriptPath" + "\"
            }
        }
    }
    else
    {
        $ErrorOccured = $true
    }
    
    ### Return value of the function
    if ( $ErrorOccured -eq $true )
    {
        return $false
    }
    else
    {
        return "$myAbsoluteScriptPath"
    }
}
#----------------------------------------------------------------------------------------------------------------------------------
function get-scriptDate($path)
{
    $privPath = "$path"
    $privMessagePrefix = "$($MyInvocation.InvocationName) :"
    multi-PurposeLogging -message "$privMessagePrefix Function invoked with parameter path >$path<." -level "verbose"

    $privScriptDate = $null
    $privScriptDate = get-content "$privPath" | select-string -pattern "^# Script-Date:"
    $privScriptDate = ($privScriptDate -replace "# Script-Date:","").trim()

    if ($privScriptDate)
    {
        multi-PurposeLogging -message "$privMessagePrefix Function returns >$privScriptDate<." -level "success"
        return $privScriptDate
    }
    else
    {
        multi-PurposeLogging -message "$privMessagePrefix could not find ># Script-Date:<. Function returns >false<." -level "warning"
        return $false
    }
}
#----------------------------------------------------------------------------------------------------------------------------------
function get-scriptName()
{
    # gets the parent path of the script. Is used to determine where to write logs etc.
    $myAbsoluteScriptPath = $null
    $myAbsoluteScriptPath = $($MyInvocation.PSCommandPath) -split "\\"
    $globalMyScriptName = $myAbsoluteScriptPath[($myAbsoluteScriptPath.count-1)] -replace ".ps1"
    if ( $globalMyScriptName )
    {
        return "$globalMyScriptName"
    }
    else
    {
        return $false
    }
}
#----------------------------------------------------------------------------------------------------------------------------------
function get-scriptParametersAsString($absolutePathToScript,$includeIgnoreParameters)
{
    # Version 1.1

    # gets the parameters in a re-usable format for powershell.exe
    # non-logging function - we fly blind...
    $privAbsolutePathToScript = [string]$absolutePathToScript
    $privIncludeIgnoreParameters = [boolean]$includeIgnoreParameters

    $ErrorOccured = $false

    ### Parameter Check
    if ( "$privAbsolutePathToScript" -eq "")
    {
        $ErrorOccured = $true
    }
    else
    {
        if ( -not ( test-path -path "$privAbsolutePathToScript" ) )
        {
            $ErrorOccured = $true
        }
    }

    ### THE DOING
    if ( $ErrorOccured -eq $false )
    {
        $parametersAsString = ""
        
        $parameters = $null
        $parameters = $( get-command "$privAbsolutePathToScript" ).Parameters
        $parameterKeys = $null
        $parameterKeys = $parameters.Keys

        foreach ( $parameterKey in $parameterKeys )
        {
            try
            {
                $parameter = $null
                $parameter = Get-Variable $parameterKey -ErrorAction Stop
                $parameterName = $null
                $parameterName = [string]$($parameter.Name)
                
                # Standard-Operation is to exclude "ignore-" parameters. But override also processes them.
                if ( -not ( "$parameterName" -ilike "ignore*" ) -or $privIncludeIgnoreParameters -eq $true )
                {
                    $parameterValue = $null
                    $parameterValue = $($parameter.value)
                    if ( "$parameterValue" -ieq "false" )
                    {
                        $parameterValue = 0
                    }
                    elseif ( "$parameterValue" -ieq "true" )
                    {
                        $parameterValue = 1
                    }
                    else
                    {
                        $parameterValue = "'$parameterValue'"
                    }

                    $parametersAsString+="-$parameterName "
                    $parametersAsString+="$parameterValue "
                }
            }
            catch
            {
                # Do nothing
            }
        }
    }

    ### Return value of the function
    if ( $ErrorOccured -eq $true )
    {
        return $false
    }
    else
    {
        return "$parametersAsString"
    }
}
#----------------------------------------------------------------------------------------------------------------------------------
function get-scriptVersion($path)
{
    # Version 1.1
    $privPath = "$path"
    $privMessagePrefix = "$($MyInvocation.InvocationName) :"
    multi-PurposeLogging -message "$privMessagePrefix Function invoked with parameter path >$path<." -level "verbose"

    $privScriptVersion = $null
    $privScriptVersion = get-content "$privPath" | Select-String -pattern "^# Script-Version:"
    $privScriptVersion = ($privScriptVersion -replace "# Script-Version:","").trim()

    if ($privScriptVersion)
    {
        multi-PurposeLogging -message "$privMessagePrefix Function returns >$privScriptVersion<." -level "success"
        return $privScriptVersion
    }
    else
    {
        multi-PurposeLogging -message "$privMessagePrefix could not find ># Script-Version:<. Function returns >false<." -level "warning"
        return $false
    }
}

###################################################################################################################################
##### FUNCTIONS STARTING WITH >H<

###################################################################################################################################
##### FUNCTIONS STARTING WITH >I<

###################################################################################################################################
##### FUNCTIONS STARTING WITH >J<

###################################################################################################################################
##### FUNCTIONS STARTING WITH >K<

###################################################################################################################################
##### FUNCTIONS STARTING WITH >L<

###################################################################################################################################
##### FUNCTIONS STARTING WITH >M<
#----------------------------------------------------------------------------------------------------------------------------------
function multi-PurposeLogging
{
	param (
		[parameter(Mandatory = $true, Position = 0)]
		[string]$Message,
		[parameter(Mandatory = $false, Position = 1)]
		[ValidateSet('information', 'error', 'warning', 'success', 'verbose')]
		[string]$Level = 'information',
		[parameter(Mandatory = $false)]
		[int]$IndentLevel = 0,
		[parameter(Mandatory = $false)]
		[string]$AbsolutePathToLogfile,
		[parameter(Mandatory = $false)]
		[bool]$CreateTimeStamp = $true,
		[parameter(Mandatory = $false)]
		[bool]$LogVerboseToSession
	)
	# Version 1.5
	
	## Downstream dependencies:
	# - get-NiceTimeStamp
	# - get-scriptabsolutepath
	# - create-Folder
	# - console-logging	
	# - file-logging	
	
	## 'Local variables' ##
	$privAbsolutePathToLogfile = $absolutePathToLogfile
	$privCreateTimeStamp = $createTimeStamp
	$privMessage = $message
	$privLevel = $level
	$privlogVerboseToSession = $logVerboseToSession
	[string]$privPaddingCharacter = ' '
	[int]$privPaddingMultiplier = 4
	
	## Parameter Checking for the logging function ##
	
	# We Need to enforce a logfile if we are not in an interactive session	
	if ([string]::IsNullOrWhiteSpace($privAbsolutePathToLogfile))
	{
		# No value for this argument was passed with the call, therefore		
		# attempt to default to global logfile path from the calling script		
		$scriptLogFilePath = ( Get-Variable -Name globalMyLogFileAbsolutePath -Scope global -ValueOnly -ErrorAction SilentlyContinue )
		if (-not ([string]::IsNullOrWhiteSpace($scriptLogFilePath)))
		{
			$privAbsolutePathToLogfile = $scriptLogFilePath
		}
	}
	
	if (-not ([environment]::UserInteractive))
	{
		if ([string]::IsNullOrEmpty($privAbsolutePathToLogfile))
		{
			return $false
		}
	}
	
	## Format the log message elements ##
	
	#  Add a Timestamp?
	if ($privCreateTimeStamp)
	{
		[string]$privLoggingMessage += "$(get-NiceTimeStamp)  |  "
	}
	
	# Set the Log Level	
	switch ($privLevel)
	{
		'information'
		{ $privLoggingMessage += "INFORMATION  |  "; break }
		'error'
		{ $privLoggingMessage += "ERROR        |  "; break }
		'warning'
		{ $privLoggingMessage += "WARNING      |  "; break }
		'success'
		{ $privLoggingMessage += "SUCCESS      |  "; break }
		'verbose'
		{ $privLoggingMessage += "VERBOSE      |  " }
	}
	
	# Create an indenting level, if set		
	if ($IndentLevel -gt 0)
	{
		$privPadding = $privPaddingCharacter * ( $privPaddingMultiplier * $IndentLevel )
		$privLoggingMessage += $privPadding
	}
	
	# Permit "auto-attribution" - Get the name of the calling function	
	# from the stack and prepend to the message, if the first character	
	# in the message is the @ symbol			
	
	if ($message[0] -eq '@')
	{
		$privCallStack 		= Get-PSCallStack
		$privCallerName 	= $privCallStack[1].Command
		$privLoggingMessage += $privCallerName
		$privLoggingMessage += ':'
		#remove the '@' from the msg string
		$Message = $Message -replace '@',' '
	}
	
	# Add the log message itself	
	$privLoggingMessage += "$message"
	
	## Do the actual logging ##
	
	#Log to the console only if we are running interactively	
	if ([Environment]::UserInteractive)
	{
		console-logging -message "$privLoggingMessage" -level "$privLevel" -logVerboseToSession $privlogVerboseToSession
	}
	
	#Log to file in all scenarios
	file-Logging -message "$privLoggingMessage" -logFileAbsolutePathName "$privAbsolutePathToLogfile" -append $true	
}

###################################################################################################################################
##### FUNCTIONS STARTING WITH >N<
#----------------------------------------------------------------------------------------------------------------------------------
function NtfsPermission($fileOrFolderPath, $UserOrGroup, $accessPermission, $permissionType, $inheritMode, $propagationMode, $modificationType )
{
    ### Examples for the usage of this function
    <##
    ## Hyper-V Knoten
    $myfolder = "c:\test"
    $mygroup = "user1"
    $myaccessPermission = "ReadAndExecute"
    $myInheritMode = "containerinherit,objectinherit"
    $mypropagationmode = "none"
    $mymodificationtype = "setrule"
    $mypermissiontype = "allow"
    $result = NtfsPermission -fileOrFolderPath "$myfolder" -UserOrGroup "$mygroup" -accessPermission "$myaccessPermission" -permissionType "$mypermissiontype" -inheritMode "$myInheritMode" -propagationMode "$mypropagationmode" -modificationType "$mymodificationType"

    $myfolder = "c:\test"
    $mygroup = "group1"
    $myaccessPermission = "ReadAndExecute"
    $myInheritMode = "none"
    $mypropagationmode = "none"
    $mymodificationtype = "setrule"
    $mypermissiontype = "allow"
    $result = NtfsPermission -fileOrFolderPath "$myfolder" -UserOrGroup "$mygroup" -accessPermission "$myaccessPermission" -permissionType "$mypermissiontype" -inheritMode "$myInheritMode" -propagationMode "$mypropagationmode" -modificationType "$mymodificationType"

    $myfolder = "C:\test\subfolder-a"
    $mygroup = "subfolder-a_re"
    $myaccessPermission = "ReadAndExecute"
    $myInheritMode = "none"
    $mypropagationmode = "none"
    $mymodificationtype = "setrule"
    $mypermissiontype = "allow"
    $result = NtfsPermission -fileOrFolderPath "$myfolder" -UserOrGroup "$mygroup" -accessPermission "$myaccessPermission" -permissionType "$mypermissiontype" -inheritMode "$myInheritMode" -propagationMode "$mypropagationmode" -modificationType "$mymodificationType"

    $myfolder = "C:\test\anotherfolder"
    $mygroup = "anothergroup_fullaccess"
    $myaccessPermission = "FullControl"
    $myInheritMode = "containerinherit,objectinherit"
    $mypropagationmode = "inheritonly"
    $mymodificationtype = "addrule"
    $mypermissiontype = "allow"
    $result = NtfsPermission -fileOrFolderPath "$myfolder" -UserOrGroup "$mygroup" -accessPermission "$myaccessPermission" -permissionType "$mypermissiontype" -inheritMode "$myInheritMode" -propagationMode "$mypropagationmode" -modificationType "$mymodificationType"
    ##>

    $privFileOrFolderPath = $fileOrFolderPath
    $privUserOrGroup = $UserOrGroup
    $privAccessPermission = $accessPermission
    $privPermissionType = $permissionType
    $privInheritMode = $inheritMode
    $privPropagationMode = $propagationMode
    $privModificationType = $modificationType
    
    $privMessagePrefix = "$($MyInvocation.InvocationName) :"
    multi-PurposeLogging -message "$privMessagePrefix Function invoked. Parameter privFileOrFolderPath has value >$privFileOrFolderPath< privUserOrGroup >$privUserOrGroup<, privAccessPermission >$privAccessPermission<, privPermissionType >$privPermissionType<, privInheritMode is >$privInheritMode<, privPropagationMode >$privPropagationMode<, privModificationType is >$privModificationType<." -level "verbose"
    
    $errorOccured = $false
    
    ##### Parameter-Checking  
    # Check if the parameters are there    
    if ( ! ( $privFileOrFolderPath.length -gt 1 ) -and `
         ! ( $privUserOrGroup.length -gt 1 ) -and `
         ! ( $privAccessPermission.length -gt 1 ) -and  `
         ! ( $privModificationType.length -gt 1 ) )
    {
        multi-PurposeLogging -message "$privMessagePrefix please provide at least >privFileOrFolderPath<, >privUserOrGroup<, >privAccessPermission< and >privModificationType<." -level "error"
        $errorOccured = $true
    }
    # check the values for inherit-mode
    if (   ! ( $($privInheritMode) -ieq "containerinherit,objectinherit" ) -and `
           ! ( $($privInheritMode) -ieq "containerinherit" ) -and ` 
           ! ( $($privInheritMode) -ieq "objectinherit" )  -and `
           ! ( $($privInheritMode) -ieq "none" ) )
    {
        multi-PurposeLogging -message "$privMessagePrefix wrong parameter provided for >privInheritMode<. Allowed are >containerinherit<, >objectinherit<, >none< or >containerinherit,objectinherit<." -level "error"
        $errorOccured = $true
    }
    # validate permission
    if (   ! ( $($privPermissionType) -ieq "allow" ) -and `
           ! ( $($privPermissionType) -ieq "deny" ) )
    {
        multi-PurposeLogging -message "$privMessagePrefix wrong parameter provided for >privPermissionType<. Allowed are >allow<, >deny<." -level "error"
        $errorOccured = $true
    }
    # check modification-type
    if (   ! ( $($privModificationType) -ieq "addrule" ) -and `
           ! ( $($privModificationType) -ieq "setrule" ) )
    {
        multi-PurposeLogging -message "$privMessagePrefix wrong parameter provided for >privModificationType<. Allowed are >addrule<, >setrule<." -level "error"
        $errorOccured = $true
    }
    # check Propagation    
    if (    ! ( $($privPropagationMode) -ieq "none" ) -and `
            ! ( $($privPropagationMode) -ieq "inheritonly" ) )
    {
        multi-PurposeLogging -message "$privMessagePrefix wrong parameter provided for >privPropagationMode<. Allowed are >none<, >inheritonly<." -level "error"
        $errorOccured = $true
    }
    # Check the provided access-permissions which should be applied.
    $privAccessPermissionArray = @()
    $privAccessPermissionArray = $privAccessPermission -split ","
    foreach ($item in $privAccessPermissionArray)
    {
        ## alowed permissions : ListDirectory, ReadData, WriteData, CreateFiles, CreateDirectories, AppendData, ReadExtendedAttributes, 
        # WriteExtendedAttributes, Traverse, ExecuteFile, DeleteSubdirectoriesAndFiles, ReadAttributes, WriteAttributes, Write, Delete, 
        # ReadPermissions, Read, ReadAndExecute, Modify, ChangePermissions, TakeOwnership, Synchronize, FullControl
        $permission = $null
        $item = $item.trim()
        if ( ( $($item) -ieq "read" ) )
        {
            $permission = "Read"
        }
        elseif ( $($item) -ieq "execute" ) 
        {
            $permission = "Execute"
        }
        elseif ( $($item) -ieq "readandexecute" )
        {
            $permission = "ReadAndExecute"
        }
        elseif ( $($item) -ieq "modify" )
        {
            $permission = "Modify"
        }        
        elseif ( $($item) -ieq "fullcontrol" )
        {
            $permission = "FullControl"
        } 
        elseif ( $($item) -ieq "delete" )
        {
            $permission = "Delete"
        } 
        elseif ( $($item) -ieq "writeattributes" )
        {
            $permission = "WriteAttributes"
        } 
        elseif ( $($item) -ieq "writeextendedattributes" )
        {
            $permission = "WriteExtendedAttributes"
        } 
        else
        {
            multi-PurposeLogging -message "$privMessagePrefix wrong parameter provided for >privAccessPermission<. Allowed are >read<, >execute<, >readandexecute<, >modify<, >fullcontrol<, >delete<, >writeattributes<, >writeextendedattributes<." -level "warning"
            multi-PurposeLogging -message "$privMessagePrefix skipping >$item<." -level "warning"
            $errorOccured = $true
        }

        ## Add to the permissions list
        $privAccessPermissionList = ""
        $privAccessPermissionList = "$privAccessPermissionList" + "$permission"
        $privAccessPermissionCounter = 0
        ## Add a separator
        if ( ( $privAccessPermissionCounter -ne 0 ) -and `
             ( $privAccessPermissionCounter -ne $($privAccessPermissionArray.Length()) ) )
        {
            $privAccessPermissionList = "$privAccessPermissionList" + ","
        }

        $privAccessPermissionCounter++
    }

    ##### The Doing
    ## Testing for the path
    if ( ! (get-item -Path "$privFileOrFolderPath" -ErrorAction SilentlyContinue ) )
    {
        multi-PurposeLogging -message "$privMessagePrefix could not find >$privFileOrFolderPath<." -level "error"
        $errorOccured = $true
    }

    ## Adding the ACL
    if ($errorOccured -eq $false)
    {
        ### Grab the current ACL data
        $currentACL = @()
        $currentACL = Get-Acl "$privFileOrFolderPath"

        ### on rule modification (set)
        if ( $($privModificationType) -ieq "setrule")
        {
            multi-PurposeLogging -message "$privMessagePrefix modifying access rule for >$privFileOrFolderPath<. User/group >$privUserOrGroup< and permission >$privAccessPermissionList<." -level "information"

            ### create the modified access rule
            try
            {
                $modifiedAccessRule = New-Object system.security.accesscontrol.filesystemaccessrule("$privUserOrGroup","$privAccessPermissionList","$privInheritMode","$privPropagationMode","$privPermissionType")
                $modifiedACL = $currentACL
                $modifiedACL.SetAccessRule($modifiedAccessRule)
                ### write the ACL
                Set-Acl "$privFileOrFolderPath" $modifiedACL -ErrorAction SilentlyContinue
                if ($?)
                {
                    multi-PurposeLogging -message "$privMessagePrefix success." -level "success"
                }
                else
                {
                    throw $($error[0])
                }
            }
            catch
            {
                multi-PurposeLogging -message "$privMessagePrefix failed. This is the error-message >$($error[0])<." -level "error"
                $errorOccured = $true
            }
        }
        ### on rule creation
        elseif ( $($privModificationType) -ieq "addrule" )
        {
            multi-PurposeLogging -message "$privMessagePrefix creating access rule for >$privFileOrFolderPath<. User/group >$privUserOrGroup< and permission >$privAccessPermissionList<." -level "information"

            ### create the new access rule
            try
            {
                $newAccessRule = New-Object system.security.accesscontrol.filesystemaccessrule("$privUserOrGroup","$privAccessPermissionList","$privInheritMode","$privPropagationMode","$privPermissionType")
                $newACL = $currentACL
                $newACL.AddAccessRule($newAccessRule)
                ### write the ACL
                Set-Acl "$privFileOrFolderPath" $newACL -ErrorAction SilentlyContinue
                if ($?)
                {
                    multi-PurposeLogging -message "$privMessagePrefix success." -level "success"
                }
                else
                {
                    throw $($error[0])
                }
            }
            catch
            {
                multi-PurposeLogging -message "$privMessagePrefix failed. This is the error-message >$($error[0])<." -level "error"
                $errorOccured = $true
            }
        }
    }

    ### the Returning value
    if ($errorOccured -eq $true)
    {
        multi-PurposeLogging -message "$privMessagePrefix returns >false<" -level "error"
        return $false
    }
    else
    {
        multi-PurposeLogging -message "$privMessagePrefix returns >true<" -level "success"
        return $true
    }
}

###################################################################################################################################
##### FUNCTIONS STARTING WITH >O<

###################################################################################################################################
##### FUNCTIONS STARTING WITH >P<
#----------------------------------------------------------------------------------------------------------------------------------
function pause()
{
    # Function to wait for keystroke
	$null = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
#----------------------------------------------------------------------------------------------------------------------------------
function powerShellProfiles($action)
{
    # Version 1.1

    $privaction = $action.toLower()
    $privMessagePrefix = "$($MyInvocation.InvocationName) :"
    
    $errorOccured = $false

    multi-PurposeLogging -message "$privMessagePrefix Function invoked. Parameter privAction has value >$privaction<. " -level "verbose"
    multi-PurposeLogging -message "$privMessagePrefix Setting Powershell profiles to >$privaction<." -level "information"
    
    if ( $privaction -ne "enable" -and $privaction -ne "disable" )
    {
        $errorOccured = $true
        multi-PurposeLogging -message "$privMessagePrefix Function invoked. Parameter privTargetValue has value >$privTargetValue<. privSilent has value >$privSilent<." -level "verbose"
        multi-PurposeLogging -message "$privMessagePrefix Setting Quickedit registry key(s) to >$privTargetValue<." -level "information"
    }

    # Doing the configuration
    try
    {
        $profileArray = @(  $($profile),
                            $($profile.AllUsersAllHosts),
                            $($profile.AllUsersCurrentHost),
                            $($profile.CurrentUserAllHosts),
                            $($profile.CurrentUserCurrentHost)
                        )
        
        $profileFound = $false
        $attachString = "_disabled"
        $guidString = "$([System.Guid]::NewGuid().ToString())"
        
        foreach ( $item in $profileArray )
        {
            $profilePath = $item

            if ( $privaction -eq "disable" )
            {
                if ( Test-Path -path "$profilePath" -ErrorAction SilentlyContinue )
                {
                    # check if there is already a file with "disabled"
                    $profileFile = Get-Item -Path "$profilePath"
                    $parentPath = ($profileFile).DirectoryName
                    $filename = ($profileFile).BaseName
                    $fileExtension = ($profileFile).Extension
                
                    $disabledFileName = "$filename$attachString"
                
                    if ( test-path -path "$parentPath\$disabledFileName$fileExtension" -ErrorAction SilentlyContinue )
                    {
                        multi-PurposeLogging -message "$privMessagePrefix      Found already disabled profile >$parentPath\$disabledFileName$fileExtension" -level "verbose"
                        $newfileName=$($disabledFileName -replace "$attachString","_$guidstring")
                        multi-PurposeLogging -message "$privMessagePrefix      renaming to >$newfileName<." -level "verbose"
                        $result = $null
                        $result = Move-Item "$parentPath\$disabledFileName$fileExtension" -Destination "$parentPath\$newfileName$fileExtension" -Force -Confirm:$false
                        if ( $? -eq $false )
                        {
                            $errorOccured = $true
                        }
                    }
                    else
                    {
                        $newfileName = "$filename$attachString"
                    }

                    # Renaming the current profile.
                    multi-PurposeLogging -message "$privMessagePrefix      disabling profile >$profilePath<." -level "verbose"

                    $result = $null
                    $result = Move-Item "$parentPath\$filename$fileExtension" -Destination "$parentPath\$disabledFileName$fileExtension" -Force -Confirm:$false
                    if ( $? -eq $false )
                    {
                        $errorOccured = $true
                    }
                    
                    ### Store that we found at least on profile.  
                    $profileFound = $true
                }
                else
                {
                    multi-PurposeLogging -message "$privMessagePrefix no profile found in path >$profilePath<." -level "verbose"
                }
            }
            elseif ( $privaction -eq "enable" )
            {
                $restoreProfile = $true

                ### Get the filename of the disabled file. this is a string operation.
                $baseName = $($profilePath -split "\\")[-1] -replace ".ps1",""
                $parentFolderArray = $($profilePath -split "\\" )
                $parentFolder = $parentFolderArray[0..($parentFolderArray.count-2)] -join '\'
                $parentFolder = "$parentFolder" + "\"
                $disabledFileName = "$parentFolder$baseName$attachString.ps1"

                if ( Test-Path -path "$profilePath" -ErrorAction SilentlyContinue )
                {
                    multi-PurposeLogging -message "$privMessagePrefix already profile found in path >$profilePath<." -level "verbose"
                    $restoreProfile = $false
                }
                
                if ( Test-Path -path "$disabledFileName" -ErrorAction SilentlyContinue )
                {
                    if ( $restoreProfile -eq $true )
                    {
                        # Renaming the current profile.
                        multi-PurposeLogging -message "$privMessagePrefix profile found in path  >$disabledFileName<." -level "verbose"
                        multi-PurposeLogging -message "$privMessagePrefix restoring profile >$profilePath<." -level "verbose"
                        $result = $null
                        $result = Move-Item "$disabledFileName" -Destination "$profilePath" -Force -Confirm:$false
                        if ( $? -eq $false )
                        {
                            $errorOccured = $true
                        }
                    }
                    else
                    {
                        multi-PurposeLogging -message "$privMessagePrefix skipping restore as a new profile has been created found in path >$profilePath<." -level "warning"
                    }
                }
                else
                {
                    multi-PurposeLogging -message "$privMessagePrefix no disabled profile found in path >$disabledFileName<." -level "verbose"
                }
            }
        }
    }
    catch
    {
        multi-PurposeLogging -message "$privMessagePrefix an error occured while >$privaction< the Powershell profiles." -level "error"
    }

    ## Returning the value of the Function.
    if ( $ErrorOccured -eq $true )
    {
        multi-PurposeLogging -message "$privMessagePrefix returns >false<." -level "error"
        return $false
    }
    else
    {
        if ( $privaction -eq "disable" )
        {
            if ( $profileFound -eq $true )
            {
                multi-PurposeLogging -message "$privMessagePrefix returns the value >profilefound<." -level "success"
                return "profilefound"
            }
            elseif ( $profileFound -eq $false )
            {
                multi-PurposeLogging -message "$privMessagePrefix returns the value >noprofilefound<." -level "success"
                return "noprofilefound"
            }
        }
        else
        {
            multi-PurposeLogging -message "$privMessagePrefix returns >true<." -level "success"
            return $true
        }
    }
}
#----------------------------------------------------------------------------------------------------------------------------------
function prepare-Logfile($logFileAbsolutePath)
{
    # Version 1.2
    $errorOccured = $false
    $privLogFileAbsolutePath = $logFileAbsolutePath

    ### Now we get the path to the log-folder and -file ready.
    $privLogFileFolderAbsolutePath = "$privLogFileAbsolutePath" -split "\\"
    $privLogFileName = $privLogFileFolderAbsolutePath[-1]
    $privLogFileFolderAbsolutePath = $privLogFileFolderAbsolutePath[0..($privLogFileFolderAbsolutePath.count-2)] -join '\'
    $privLogFileFolderAbsolutePath += "\" 

    ## checking if the folder exists / otherwise creating:
    if (! (get-item -Path "$privLogFileFolderAbsolutePath" -ErrorAction SilentlyContinue ) )
    {
        if ( ! ( create-Folder -absolutePath "$privLogFileFolderAbsolutePath" ) )
        {
            $errorOccured = $true
        }
    }

    ### Checking for the file and creating if necessary
    if ($errorOccured -eq $false)
    {
        if ( ! (get-item -Path "$privLogFileAbsolutePath" -ErrorAction SilentlyContinue ) )
        {
            if ( ! (New-Item -Path "$privLogFileAbsolutePath" -ItemType file -ErrorAction SilentlyContinue) )
            {
                $errorOccured = $true
            }
        }
    }

    ### Returning the value
    if ($errorOccured -eq $true)
    {
        return $false
    }
    else
    {
        return $true
    }
}

###################################################################################################################################
##### FUNCTIONS STARTING WITH >Q<

###################################################################################################################################
##### FUNCTIONS STARTING WITH >R<

###################################################################################################################################
##### FUNCTIONS STARTING WITH >S<
#----------------------------------------------------------------------------------------------------------------------------------
function sha512hash($absolutePath,$silent)
{
    # Version 1.3
    $privAbsolutePath = "$absolutePath"
    $privSilent = $silent

    $privMessagePrefix = "$($MyInvocation.InvocationName) :"
    if ($privSilent -ne $true)
    {
        $privSilent = $false
        multi-PurposeLogging -message "$privMessagePrefix Function invoked. Parameter privAbsolutePath has value >$privAbsolutePath<, privSilent has value >$privSilent<)." -level "verbose"
    }
    
    ### parameter checking
    if ($privAbsolutePath -eq "" -or $privAbsolutePath -eq $null)
    {
        multi-PurposeLogging -message "$privMessagePrefix no path provided." -level "error"
        return $false
    }

    ### checking if the file is there.
    $fullPath = Resolve-Path $absolutePath
    if (Test-Path -path "$fullPath" -ErrorAction SilentlyContinue)
    {
        ### getting the hash
        $hashProvider = new-object -TypeName System.Security.Cryptography.SHA512CryptoServiceProvider
        $fileToHash = [System.IO.File]::Open($fullPath,[System.IO.Filemode]::Open, [System.IO.FileAccess]::Read)
        $hashResult=[System.BitConverter]::ToString($hashProvider.ComputeHash($fileToHash))
        multi-PurposeLogging -message "$privMessagePrefix     file >$fullpath< has hash >$hashResult<." -level "verbose"
        $fileToHash.Dispose()
        if ($privSilent -ne $true)
        {
            multi-PurposeLogging -message "$privMessagePrefix returns the file hash." -level "success"
        }
        return $hashResult
    }
    else
    {
        multi-PurposeLogging -message "$privMessagePrefix there is no item in path provided." -level "error"
        return $false        
    }
}
#----------------------------------------------------------------------------------------------------------------------------------
function sleepTimer($sleeptime,$maxCounter)
{
    # Version 1.1
    $privSleepTime = [int32]$sleeptime
    $privMaxCounter = [int32]$maxCounter
    $counter = 1

    if ($privSleepTime -eq 0)
    {
        $privSleepTime = 1
    }
    if ($privMaxCounter -eq 0)
    {
        $privMaxCounter = 3
    }

    while ($counter -le $privMaxCounter)
    {
        sleep $privSleepTime
        if ([Environment]::UserInteractive -and $counter -eq $privMaxCounter)
        { Write-Host "." }
        elseif ([Environment]::UserInteractive)
        { Write-Host -NoNewline "." }
        $counter++
    }
}
#----------------------------------------------------------------------------------------------------------------------------------
function stage-0($quickeditProtection,$ensureElevation)
{
    # Version 1.8
    $privQuickeditProtection = [boolean]$quickeditProtection
    $privEnsureElevation = [boolean]$ensureElevation
    
    $privMessagePrefix = "$($MyInvocation.InvocationName) :"
    $stage0error = $false
        
    ## Generating the path to the logfile.
    if ( $overWriteLogFile -eq $false )
    {
        Set-Variable -Name globalMyLogFileName ("$(get-NiceTimeStamp)__$globalMyScriptName.log") -Scope global
    }
    else
    {
        Set-Variable -Name globalMyLogFileName ("$globalMyScriptName.log") -Scope global
    }
    
    ### SECURING THE POWERSHELL ENVIRONMENT (quickedit disable) AND RESTART THE SCRIPT
    if ( $privQuickeditProtection -eq $true )
    {
        $pshost = $null
        $pshost = get-host
        if ( $($pshost.Name) -match "ISE Host" -or [Environment]::UserInteractive )
        {
            $result = $null
            $result = configure-QuickEditMode -targetValue 0
            if ( $result -ieq "wasEnabled" )
            {
                ### Set the global quickedit mode
                Set-Variable -Name quickeditMode -Value "$result" -Force -Scope Global

                $parameterString = $null
                $parameterString = get-scriptParametersAsString -absolutePathToScript "$globalMyScriptFolderPath$globalMyScriptName.ps1"

                if ( -not ( $parameterString -eq $false ) )
                {
                    # If we have window style hidden, we need to pass this to the restarted script as well.
                    if ( $(get-process -Id $PID).MainWindowHandle -eq 0 )
                    {
                        $arguments = " -windowstyle hidden "
                    }
                    else
                    {
                        $arguments = ""
                    }
                    
                    ### KICKING THE NEW PROCESS 
                    start-Process -FilePath powershell.exe "$arguments $("$globalMyScriptFolderPath"+"$globalMyScriptName.ps1") $parameterstring" 

                    ### JUST EXIT THIS INCARNATION OF THE SCRIPT
                    exit
                }
                else
                {
                    $stage0error = $true
                    $errorMessage = "ERROR GETTING THE PARAMETER STRING. STAGE-0"
                    if ( [Environment]::UserInteractive )
                    {
                        write-host "$errorMessage" -ForegroundColor Red
                    }
                    else
                    {
                        throw $errorMessage
                    }
                }
            }
        }
    }
    
    ### ENSURING ELEVATION
    if ( $privEnsureElevation -eq $true )
    {
        $identity = $null
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = $null
        $principal = New-Object Security.Principal.WindowsPrincipal $identity
        $shellIsElevated = $null
        $shellIsElevated = $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)

        ### Elevating the script
        if ( $shellIsElevated -eq $false )
        {
            try
            {
                $parameterString = $null
                $parameterString = get-scriptParametersAsString -absolutePathToScript "$globalMyScriptFolderPath$globalMyScriptName.ps1"

                if ( -not ( $parameterString -eq $false ) )
                {               
                    ### KICKING THE NEW PROCESS 
                    $newProcess = $null
                    $newProcess = new-object System.Diagnostics.ProcessStartInfo "PowerShell"
                    $newProcess.Arguments = "& $("$globalMyScriptFolderPath"+"$globalMyScriptName.ps1") $parameterstring"
                    $newProcess.Verb = "runas"
                    $result = $null
                    $result = [System.Diagnostics.Process]::Start($newProcess)
                    
                    ### JUST EXIT THIS INCARNATION OF THE SCRIPT
                    exit
                }
                else
                {
                    $stage0error = $true
                    $errorMessage = "ERROR GETTING THE PARAMETER STRING. STAGE-0"
                    if ( [Environment]::UserInteractive )
                    {
                        write-host "$errorMessage" -ForegroundColor Red
                    }
                    else
                    {
                        throw $errorMessage
                    }
                }
            }
            catch
            {
                $stage0error = $true
                $errorMessage = $null
                $errorMessage = "!!! ERROR - YOU NEED TO BE PART OF THE ADMINISTRATORS GROUP. PLEASE RERUN THIS SCRIPT WITH A PROPER ACCOUNT !!!"
                if ( [Environment]::UserInteractive )
                {
                    write-host "$errorMessage" -ForegroundColor Red
                }
                else
                {
                    throw "$errorMessage"
                }
            }
        }
    }

    ### BUILDING THE LOG FILE PATH
    $currentLogPath = $null
    $currentLogPath = "$globalMyScriptFolderPath" + "$logFileFolderName"
    if ( -not ( "$currentLogPath" -like "*\" ) )
    {
        $currentLogPath += "\"
    }
    $currentLogPath += "$globalMyLogFileName" 

    ## Initializing  the logging environment
    # This must be behind the "restart" of the script - otherwise we will have 0kb files lying around
    if ( prepare-Logfile -logFileAbsolutePath "$currentLogPath" )
    {
        Set-Variable -Name globalMyLogFileAbsolutePath ( $currentLogPath ) -Scope global
    }
    else
    {
        $stage0error = $true
    }

    ### Now we can do 
    # we can start the actual script-run if the logging-preparation was successfull
    if ( $globalMyLogFileAbsolutePath -ne $false )
    {
        write-Logitem -itemType "start"
        ### logging the variables:
        multi-PurposeLogging -message "$privMessagePrefix globalMyScriptName: >$globalMyScriptName<." -level "verbose"
        multi-PurposeLogging -message "$privMessagePrefix globalMyScriptFolderPath: >$globalMyScriptFolderPath<." -level "verbose"
        multi-PurposeLogging -message "$privMessagePrefix globalMyLogFileAbsolutePath: >$globalMyLogFileAbsolutePath<." -level "verbose"

        ## Getting the script version
        Set-Variable -Name globalMyScriptVersion ( get-scriptVersion -path "$globalMyScriptFolderPath$globalMyScriptName.ps1" ) -Scope global
        ## Getting the script date
        Set-Variable -Name globalMyScriptDate ( get-scriptDate -path "$globalMyScriptFolderPath$globalMyScriptName.ps1" ) -Scope global

        ### Getting Powershell-Version
        $privPSVersion = $null
        $privPSVersion = get-powershellversion
        if ( $privPSVersion -like "3*" -or $privPSVersion -like "4*" -or $privPSVersion -like "5*" )
        {
            set-variable -Name globalMyPSVersion ($privPSVersion) -Scope global
            multi-PurposeLogging -message "$privMessagePrefix valid Powershell version found." -level "success"
        }
        else
        {
            multi-PurposeLogging -message "$privMessagePrefix no valid Powershell version found. Need at least Powershell 3.0 environment." -level "error"
            $stage0error = $true
        }
    }
    else
    {
        multi-PurposeLogging -message "$privMessagePrefix no valid logfile path provided." -level "error"
        $stage0error = $true
    }

    ### Result for the stage - Returning the Value of the major function.
    if ( $stage0error -eq $false )
    {
        multi-PurposeLogging -message "$privMessagePrefix returns >true<." -level "success"
        return $true
    }
    else
    {
        multi-PurposeLogging -message "$privMessagePrefix returns >false<." -level "error"
        return $false
    }
}
#----------------------------------------------------------------------------------------------------------------------------------
function stage-1($powershellProfileHandling,$ssyvCmdletLoadEnforced,$quickeditProtection,$checkAutorunPs1Script,$loadConfigurationXML,$serverHardwareConfigurationXMLFileName,$serverDeploymentConfigurationXMLFileName,$expectedScriptFolder,$validateUsercontext,$doNotClearAutologon)
{
    # Version 1.15
    $privPowershellProfileHandling = [boolean]$powershellProfileHandling
    $privSsyvCmdletLoadEnforced = [boolean]$ssyvCmdletLoadEnforced
    $privCheckAutorunPs1Script = [boolean]$checkAutorunPs1Script
    $privQuickeditProtection = [boolean]$quickeditProtection
    $privLoadConfigurationXML = [boolean]$loadConfigurationXML
    $privServerHardwareConfigurationXMLFileName = [string]$serverHardwareConfigurationXMLFileName
    $privServerDeploymentConfigurationXMLFileName = [string]$serverDeploymentConfigurationXMLFileName
    $privExpectedScriptFolder = [string]$expectedScriptFolder
    $privValidateUsercontext = [boolean]$validateUsercontext
    $privDoNotClearAutologon = [boolean]$doNotClearAutologon

    $stage1error = $false
    $privMessagePrefix = "$($MyInvocation.InvocationName) :"
    multi-PurposeLogging -message "$privMessagePrefix invoked with parameters privPowershellProfileHandling >$privPowershellProfileHandling<, privSsyvCmdletLoadEnforced >$privSsyvCmdletLoadEnforced<, privCheckAutorunPs1Script >$privCheckAutorunPs1Script<, privQuickeditProtection >$privQuickeditProtection<, privLoadConfigurationXML >$privLoadConfigurationXML<, privServerHardwareConfigurationXMLFileName >$privServerHardwareConfigurationXMLFileName<, privServerDeploymentConfigurationXMLFileName >$privServerDeploymentConfigurationXMLFileName<, privExpectedScriptFolder >$privExpectedScriptFolder<, privValidateUsercontext >$privValidateUsercontext<." -level "verbose"

    # - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    ##### CHECKSUM CHECK
    ### We validate the checksum of the script
    $currentScriptChecksum = sha512hash -absolutePath "$globalMyScriptFolderPath$globalMyScriptName.ps1"
    multi-PurposeLogging -message "$privMessagePrefix Main script calculated checksum is: >$currentScriptChecksum<." -level "verbose"
    $compareScriptChecksum = $null
    if ( test-path -path "$globalMyScriptFolderPath\$globalMyScriptName.ps1.sha512" )
    {
        $compareScriptChecksum = ([string](Get-Content -Path "$globalMyScriptFolderPath\$globalMyScriptName.ps1.sha512" -force -ErrorAction SilentlyContinue)).replace("`n|`r","").trim()
    }
    multi-PurposeLogging -message "$privMessagePrefix Main script compare checksum is:    >$compareScriptChecksum<." -level "verbose"
    #If it is equal everything is fine
    if ( "$currentScriptChecksum" -eq "$compareScriptChecksum" )
    {
        multi-PurposeLogging -message "$privMessagePrefix Checksum for >$globalMyScriptName< validated." -level "success"
    }
    else
    {
        multi-PurposeLogging -message "$privMessagePrefix someone tampered the script >$globalMyScriptName<." -level "error"
        if ( $ignoreScriptChecksum -eq $false )
        {
            $stage1error = $true
        }
        else
        {
            multi-PurposeLogging -message "$privMessagePrefix ignoring checksum error due to >ignoreScriptChecksum< variable." -level "error"
        }
    }

    # - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    ##### LOGGING THE LIBRARY LOAD STATUS
    multi-PurposeLogging -message "$privMessagePrefix Library Load (Custom) is >$globalMyCustomLibraryLoaded<." -level "verbose"
    multi-PurposeLogging -message "$privMessagePrefix Library Load (Vendor) is >$globalMyVendorLibraryLoaded<." -level "verbose"

    # - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    ##### CLEARING AUTOLOGON INFORMATION
    if ( $stage1error -eq $false -and $privDoNotClearAutologon -eq $false)
    {
        if ( get-command "modify-autoWindowsLogon" -ErrorAction SilentlyContinue  )
        {
            $result = $null
            $result = modify-autoWindowsLogon -enabled $false
            if ( $result -eq $false)
            {
                $stage1error = $true
            }
        }
        else
        {
            multi-PurposeLogging -message "$privMessagePrefix function for modifying autologon not found. It is therefore impossible to use it." -level "verbose"
        }
    }
    else
    {
        multi-PurposeLogging -message "$privMessagePrefix autologon information was not cleared because of an error in stage1 upfront." -level "verbose"
    }

    # - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    ##### DISABLEING AUTORUN INFORMATION IF FOUND
    if ( $stage1error -eq $false -and $privCheckAutorunPs1Script -eq $true )
    {
        $result = $null
        $result = autorunPs1Script -action "disable" -scope "all"
        if ( $result -eq $false)
        {
            $stage1error = $true
        }
    }
    else
    {
        multi-PurposeLogging -message "$privMessagePrefix checking for script in autorun was turned off through parameter privCheckAutorunPs1Script is >false< or stage1 hit an error upfront." -level "verbose"
    }

    # - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    ##### QUICKEDIT MODE PROTECTION / HANDLING
    if ( $stage1error -eq $false -and $privQuickeditProtection -eq $true )
    {
        ### if quickeditmode was detected
        if ( $quickeditMode -ieq "wasenabled" -or $quickeditMode -ieq "wasdisabled" )
        {
            multi-PurposeLogging -message "$privMessagePrefix script was restarted. QuickeditMode parameter is >$quickeditMode<." -level "verbose"
        }
    
        ### Resetting the value for the quickedit mode as it was before. As this is only valid for new sessions it is safe to do this right away.
        if ( $quickeditMode -ieq "wasenabled" )
        {
            $result = $null
            $result = configure-QuickEditMode -targetValue 1 -silent $false
        }
        elseif ( $quickeditMode -ieq "wasdisabled" )
        {
            $result = $null
            $result = configure-QuickEditMode -targetValue 0 -silent $false
        }
    }
    else
    {
        multi-PurposeLogging -message "$privMessagePrefix quickedit protection was turned off through parameter >privQuickeditProtection< is >false< or stage1 hit an error upfront." -level "verbose"
    }
    
    # - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    ##### LOADING THE NEEDED POWERSHELL MODULE
    ## DataCore SSY-V
    if ( $stage1error -eq $false -and $privSsyvCmdletLoadEnforced -eq $true )
    {
        if ( $(DataCorePSModule -action "load" ) -eq $false)
        {
            $stage1error = $true
        }
    }
    else
    {
        multi-PurposeLogging -message "$privMessagePrefix SANsymphony-V cmdlets not loaded due to parameter >privSsyvCmdletLoadEnforced< is >false<." -level "verbose"
    }

    # - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    ##### DISABLING POWERSHELL PROFILES UPFRONT
    if ( $stage1error -eq $false -and $privPowershellProfileHandling -eq $true )
    {
        $myResult = $null
        $myResult = powerShellProfiles -action "disable"
        if ( $myResult -eq $false )
        {
            $stage1error = $true
        }
    }
    else
    {
        multi-PurposeLogging -message "$privMessagePrefix powershell profiles not being processed due to parameter >privPowershellProfileHandling< is >false< or error occured in previous step." -level "verbose"
    }

    # - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    ##### CONFIGURATION LOAD
    if ( $stage1error -eq $false -and $privLoadConfigurationXML -eq $true )
    {
        ### GATHERING THE VENDOR STRING OF THE SERVER
        if ( $stage1error -eq $false )
        {
            $vendorString = $null
            $vendorString = ( get-wmiobject win32_computersystem ).Manufacturer
            if ( $vendorString -ne "" )
            {
                multi-PurposeLogging -message "$privMessagePrefix vendor detected is >$vendorString<." -level "success"
                Set-Variable -Name globalMyComputerVendor ("$vendorString") -Scope global
            }
            else
            {
                multi-PurposeLogging -message "$privMessagePrefix could not determine computer vendor from >win32_computersystem< WMI object." -level "warning"
            }
        }

        ### GATHERING THE SYSTEM MODEL
        if ( $stage1error -eq $false )
        {
            $modelString = $null
            $modelString = ( get-wmiobject win32_computersystem ).Model
            if ( $modelString -ne "" )
            {
                $modelString = ( $modelString -replace " ","-" ).trim()
                multi-PurposeLogging -message "$privMessagePrefix computer model detected is >$modelString<." -level "success"
                Set-Variable -Name globalMyComputerModel ("$modelString") -Scope global
            }
            else
            {
                multi-PurposeLogging -message "$privMessagePrefix could not determine computer Model from >win32_computersystem< WMI object." -level "warning"
            }
        }

        ### LOADING THE CONFIGURATION OF THIS DEPLOYMENT
        if ( $stage1error -eq $false )
        {
            ### if the configuration provided through script parameter is ""
            if ( $privServerDeploymentConfigurationXMLFileName -ieq "" )
            {
                # Using the default file name for this deployment
                $privServerDeploymentConfigurationXMLFileName = "$globalMyComputerModel"+"__Deployment-Configuration.xml"
            }
            multi-PurposeLogging -message "$privMessagePrefix privServerDeploymentConfigurationXMLFileName: >$privServerDeploymentConfigurationXMLFileName<" -level "verbose"
        
            # Checking if we can find the configuration file
            $result = $null
            $result = find-absolutePath -folderToSearch "$globalMyScriptFolderPath" -fileNameToSearch "$privServerDeploymentConfigurationXMLFileName"
            if ( $result -eq $false )
            {
                multi-PurposeLogging -message "$privMessagePrefix could not find >$serverDeploymentConfigurationXMLFileName< in >$globalMyScriptFolderPath<." -level "error"
                $stage1error = $true
            }
            else
            {
                # Load the configuration as a global XML configuration variable
                multi-PurposeLogging -message "$privMessagePrefix loading Deploy-Configuration-XML >$result< into global configuration variable." -level "information"
                Set-Variable -Name globalMyServerDeploymentConfigurationXMLFilePath ( "$result" ) -Scope global
                Set-Variable -Name globalMyServerDeploymentConfigurationXML ( [XML] ( Get-Content -path "$result" ) ) -Scope global
            }

            ### if the configuration provided through script parameter is ""
            if ( $privServerHardwareConfigurationXMLFileName -ieq "" )
            {
                $privServerHardwareConfigurationXMLFileName = "$globalMyComputerModel"+"__Hardware-Configuration.xml"
            }
            multi-PurposeLogging -message "$privMessagePrefix privServerHardwareConfigurationXMLFileName: >$privServerHardwareConfigurationXMLFileName<" -level "verbose"

            # Checking if we can find the configuration file
            $result = $null
            $result = find-absolutePath -folderToSearch "$globalMyScriptFolderPath" -fileNameToSearch "$privServerHardwareConfigurationXMLFileName"
            if ( $result -eq $false )
            {
                multi-PurposeLogging -message "$privMessagePrefix could not find >$serverHardwareConfigurationXMLFileName< in >$globalMyScriptFolderPath<." -level "error"
                $stage1error = $true
            }
            else
            {
                # Load the configuration as a global XML configuration variable
                multi-PurposeLogging -message "$privMessagePrefix loading HW-Configuration-XML >$result< into global configuration variable." -level "information"
                Set-Variable -Name globalMyServerHardwareConfigurationXMLFilePath ( "$result" ) -Scope global
                Set-Variable -Name globalMyServerHardwareConfigurationXML ( [XML] ( Get-Content -path "$result" ) ) -Scope global
            }
        }
    }
    else
    {
        multi-PurposeLogging -message "$privMessagePrefix configuration file not loaded due to parameter >privLoadConfigurationXML< is >false< or error occured in previous step." -level "verbose"
    }

    # - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    ##### PATH CHECK
    if ( $stage1error -eq $false -and -not ( "$privExpectedScriptFolder" -eq "" ) )
    {
        if ( -not ( "$globalMyScriptFolderPath" -ilike "$expectedScriptFolder*" ) )
        {
            multi-PurposeLogging -message "$privMessagePrefix wrong script path detected. Please make sure that the Folder is >$expectedScriptFolder<." -level "error"
            $stage1error = $true
            if ( [Environment]::UserInteractive -and $batchMode -eq $false )
            {
                $result = $null
                $result = myMessageBox -title "$windowTitle" -heading "Deployment error" -messageType "error" -iconFile "$iconFilePath" -buttonStyle "ok" -message "Wrong script path detected. Please make sure that the RCW-Folder is >$expectedScriptFolder<."
            }
        }
    }

    # - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    ##### USER CONTEXT CHECK
    ### CHECK IF DEPLOYMENT IS ALREADY RUNNING
    if ( $stage1error -eq $false -and $privValidateUsercontext -eq $true )
    {
        $currentUserName = $null
        $currentUserName = $env:USERNAME
        multi-PurposeLogging -message "$privMessagePrefix current user is >$currentUserName<." -level "verbose"
        $currentUserDomain = $null
        $currentUserDomain = $env:USERDNSDOMAIN
        multi-PurposeLogging -message "$privMessagePrefix current domain is >$currentUserDomain<." -level "verbose"
        $currentUserSID = $null
        $currentUserSID = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.value
        multi-PurposeLogging -message "$privMessagePrefix current user SID >$currentUserSID<." -level "verbose"

        ### STATUS IS GLOBAL
        Set-Variable -Name globalMyStatusXMLAbsolutePath ("$globalMyScriptFolderPath$statusFolderName"+"\status.xml") -Scope global
        multi-PurposeLogging -message "$privMessagePrefix status xml path >$globalMyStatusXMLAbsolutePath<." -level "verbose"

        # Checking if the file is there
        if ( Test-Path -Path "$globalMyStatusXMLAbsolutePath" -ErrorAction SilentlyContinue )
        {
            ### Reading the Status file
            multi-PurposeLogging -message "$privMessagePrefix existing status xml path in >$globalMyStatusXMLAbsolutePath< found." -level "verbose"
        }
        # otherwise creating
        else
        {
            multi-PurposeLogging -message "$privMessagePrefix creating status xml in path >$globalMyStatusXMLAbsolutePath<." -level "information"
            # create the status XML file
            $result = $null
            $result = create-statusXML -absoluteFilePath "$globalMyStatusXMLAbsolutePath"
            if ( $result -eq $false )
            {
                $stage1error = $true
            }
        }

        ### Checking the content
        if ( $stage1error -eq $false )
        {
            ### Reading
            multi-PurposeLogging -message "$privMessagePrefix reading and analysing status xml file." -level "information"
            Set-Variable -Name globalMyCurrentDeploymentStatus ( [XML] ( Get-Content -path "$globalMyStatusXMLAbsolutePath" -ErrorAction SilentlyContinue ) ) -Scope global
        }

        try
        {
            $statusDeploymentRunning = $null
            $statusDeploymentRunning = [System.Convert]::ToBoolean( $globalMyCurrentDeploymentStatus.DeploymentStatus.Running )
            $statusAccountHandover = $null
            $statusAccountHandover = [System.Convert]::ToBoolean( $globalMyCurrentDeploymentStatus.DeploymentStatus.AccountHandOver )

            ## If the deployment is running we check user and SID
            if ( $statusDeploymentRunning -eq $true -and $statusAccountHandover -eq $false )
            {
                $continue = $false
                $statusUsername = $null
                $statusUsername = $globalMyCurrentDeploymentStatus.DeploymentStatus.Username
                $statusUserdomain = $null
                $statusUserdomain = $globalMyCurrentDeploymentStatus.DeploymentStatus.Userdomain
                $statusUserSID = $null
                $statusUserSID = $globalMyCurrentDeploymentStatus.DeploymentStatus.SID

                if ( "$statusUsername" -ieq "" -and "$statusUserSID" -ieq "" )
                {
                    multi-PurposeLogging -message "$privMessagePrefix status does not contain Username and SID but >Running< is >true<. Resetting status." -level "warning"
                    $continue = $true
                    $resetStatus = $true
                }
                else
                {
                    # Status XML User name contains a value
                    if ( "$statusUsername" -ieq "$currentUserName" )
                    {
                        $usernameEquals = $true
                    }
                    else
                    {
                        $usernameEquals = $false
                    }

                    # Status XML Domainname contains a value
                    if ( "$statusUserdomain" -ieq "$currentUserDomain" )
                    {
                        $domainEquals = $true
                    }
                    else
                    {
                        $domainEquals = $false
                    }

                    # Status XML SID contains a value
                    if ( -not ( "$statusUserSID" -ieq "" ) )
                    {
                        if ( "$statusUserSID" -ieq "$currentUserSID" )
                        {
                            $sidEquals = $true
                        }
                        else
                        {
                            $sidEquals = $false
                        }
                    }

                    if ( $sidEquals -eq $true -and $usernameEquals -eq $true -and $domainEquals -eq $true )
                    {
                        multi-PurposeLogging -message "$privMessagePrefix current username, userdomain and SID match the status xml content." -level "information"
                        $continue = $true
                    }
                    elseif ( $usernameEquals -eq $true -and $domainEquals -eq $true )
                    {
                        multi-PurposeLogging -message "$privMessagePrefix current username and userdomain match the status xml content, but the SID is different." -level "warning"
                        $continue = $true
                    }
                }
            }
            else
            {
                $continue = $true
                $resetStatus = $true
            }

            ### If we detected another deployment user.
            if ( $continue -eq $false )
            {
                multi-PurposeLogging -message "$privMessagePrefix it seems that the deployment is running already under another username >$statusUsername< with SID >$statusUserSID< (domain >$statusUserdomain<). Please be patient and / or connect to this user." -level "Error"
                $stage1error = $true
            }
            
            ### Reset status - Writing to the XML
            if ( $resetStatus -eq $true )
            {
                multi-PurposeLogging -message "$privMessagePrefix writing current information to status XML file." -level "information"
                $globalMyCurrentDeploymentStatus.DeploymentStatus.Username = "$currentUserName"
                $globalMyCurrentDeploymentStatus.DeploymentStatus.Userdomain = "$currentUserDomain"
                $globalMyCurrentDeploymentStatus.DeploymentStatus.SID = "$currentUsersid"
                $globalMyCurrentDeploymentStatus.DeploymentStatus.AccountHandOver = "false"
                $globalMyCurrentDeploymentStatus.DeploymentStatus.Running = "true"
                # Saving to the status XML
                $globalMyCurrentDeploymentStatus.Save("$globalMyStatusXMLAbsolutePath")
            }
        }
        catch
        {
            multi-PurposeLogging -message "$privMessagePrefix an error occured while analyzing the status XML. This is the last errormessage: >$($error[0])<." -level "Error"
            $stage1error = $true
        }
    }
       


    # - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    ### Returning the value of this major function.
    if ( $stage1error -eq $false )
    {
        multi-PurposeLogging -message "$privMessagePrefix returns >true<." -level "success"
        return $true
    }
    else
    {
        multi-PurposeLogging -message "$privMessagePrefix returns >false<." -level "error"
        return $false
    }
}
#----------------------------------------------------------------------------------------------------------------------------------
function stage-2()
{
    $stage2error = $false
    $privMessagePrefix = "$($MyInvocation.InvocationName) :"
    
    ### SETTING THE GLOBAL VARIABLE FOR THE OS LANGUAGE
    if ( $stage2error -eq $false )
    {
        Set-Variable -Name globalMyOSLanguage (get-osLanguage) -Scope global
        if ( -not ( $globalMyOSLanguage -ieq "english" ) -and -not ( $globalMyOSLanguage -ieq "german" ) )
        {
            $stage2error = $true
        }
    }

    ### CHECKING PATH VALUES
    if ( -not ( $ssyvServerBackupFolder.Substring($ssyvServerBackupFolder.Length -1, 1 ) -ieq "\" ) )
    {
        multi-PurposeLogging -message "$privMessagePrefix missing backslash for >globalMyLocalBackupFolder<. Adding it to the path provided." -level "warning"
        Set-Variable -Name globalMyLocalBackupFolder "$ssyvServerBackupFolder\" -Scope global
    }
    else
    {
        Set-Variable -Name globalMyLocalBackupFolder "$ssyvServerBackupFolder" -Scope global
    }
    if ( -not ( "$additionalUNCPathFolder" -eq "" ) )
    {
        if ( -not ( $additionalUNCPathFolder.Substring($additionalUNCPathFolder.Length -1, 1 ) -ieq "\" ) )
        {
            multi-PurposeLogging -message "$privMessagePrefix missing backslash for >globalMyRemoteBackupFolder<. Adding it to the path provided." -level "warning"
            Set-Variable -Name globalMyRemoteBackupFolder "$additionalUNCPathFolder\" -Scope global
        }
        else
        {
            Set-Variable -Name globalMyRemoteBackupFolder "$additionalUNCPathFolder" -Scope global
        }
    }
    else
    {
        Set-Variable -Name globalMyRemoteBackupFolder $false -Scope global
    }

    ### CHECKING THE TTL VALUES
    if ( $ssyvServerBackupTTL -lt 1 )
    {
        multi-PurposeLogging -message "$privMessagePrefix value less than 1 provided for ssyvServerBackupTTL. Forcing at least 1 day to keep." -level "warning"
        Set-Variable -Name globalMylocalServerBackupTTL 1 -Scope global
    }
    else
    {
        Set-Variable -Name globalMylocalServerBackupTTL $ssyvServerBackupTTL -Scope global
    }
    if ( $additionalUNCBackupTTL -lt 1 )
    {
        multi-PurposeLogging -message "$privMessagePrefix value less than 1 provided for additionalUNCBackupTTL. Forcing at least 1 day to keep." -level "warning"
        Set-Variable -Name globalMyglobalMyRemoteBackupFolderTTL 1 -Scope global
    }
    else
    {
        Set-Variable -Name globalMyglobalMyRemoteBackupFolderTTL $additionalUNCBackupTTL -Scope global
    }   

    ### INSTALLING THE SCRIPT
    if ( $stage2error -eq $false )
    {
        if ( $installScript -eq $true )
        {
            multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix installing the DataCore SANsymphony-V solution." -level "information"

            # CREATING THE LOCAL TARGET DIRECTORY AND ADJUSTING PERMISSIONS
            if ( $stage2error -eq $false )
            {
                # Create the folder
                if ( -not ( Get-Item -Path "$globalMyLocalBackupFolder" -ErrorAction SilentlyContinue ) )
                {
                    multi-PurposeLogging -message "$privMessagePrefix local path not found. Creating >$globalMyLocalBackupFolder<." -level "warning"
                    $result = $null
                    $result = New-Item -ItemType directory -Path "$globalMyLocalBackupFolder"
                    if ( $? -eq $true )
                    {
                        multi-PurposeLogging -message "$privMessagePrefix success." -level "success"
                    }
                    else
                    {
                        multi-PurposeLogging -message "$privMessagePrefix failed." -level "error"
                        $stage2error = $true
                    }
                }

                # Add NTFS permissions for DcsAdmin
                $result = $null
                $result = NtfsPermission -fileOrFolderPath "$ssyvServerBackupFolder" -UserOrGroup "DcsAdmin" -accessPermission "FullControl" -permissionType "allow" -inheritMode "containerinherit,objectinherit" -propagationMode "none" -modificationType "addrule"
                if ( $result -eq $false )
                {
                    $stage2error = $true
                }
            }

            ### CHECKING THAT THE USERS EXIST ON THE SYSTEM
            if ( $stage2error -eq $false )
            {
                $localAdministrator = $false
                $localDcsAdmin = $false

                $localAccounts = $null
                $localAccounts = Get-WmiObject -Class Win32_UserAccount -Namespace "root\cimv2" -Filter "LocalAccount='$True'"
                foreach ($localAccount in $localAccounts)
                {
                    if ( $($localAccount.name) -ieq "administrator" )
                    {
                        $localAdministrator = $true
                    }
                    elseif ( $($localAccount.name) -ieq "dcsadmin" )
                    {
                        $localDcsAdmin = $true
                    }
                }

                if ( $localAdministrator -eq $false )
                {
                    multi-PurposeLogging -message "$privMessagePrefix could not find local account with name >Administrator<." -level "error"
                    $stage2error = $true
                }
                if ( $localDcsAdmin -eq $false )
                {
                    multi-PurposeLogging -message "$privMessagePrefix could not find local account with name >DCSAdmin<." -level "error"
                    $stage2error = $true
                }
            }

            ### CREATE THE SHARE NAME FOR BACKUPS WITHIN SSY-V GROUP
            if ( $stage2error -eq $false )
            {
                Set-Variable -Name globalMySSYVServerShareName "$((Get-Item -Path "$globalMyLocalBackupFolder" -ErrorAction SilentlyContinue).BaseName)$" -Scope global
                multi-PurposeLogging -message "$privMessagePrefix share name is >$globalMySSYVServerShareName<." -level "verbose"
            }

            ### CREATING A WINDOWS SHARE WITH ACCESS for DCSADMIN
            if ( $stage2error -eq $false )
            {
                if ( -not ( Get-SmbShare -name "$globalMySSYVServerShareName" -ErrorAction SilentlyContinue ) )
                {
                    multi-PurposeLogging -message "$privMessagePrefix local path is not shared. Creating SMB share with name >$globalMySSYVServerShareName<." -level "warning"
                    $result = $null
                    $result = New-SmbShare -Description "SMB Share for integrated SSY-V Backup script - DCSAdmin+Administrator has full access" -FullAccess DCSAdmin,Administrator -Path "$globalMyLocalBackupFolder" -Name "$globalMySSYVServerShareName" -ConcurrentUserLimit 128
                    if ( $? -eq $true )
                    {
                        multi-PurposeLogging -message "$privMessagePrefix success." -level "success"
                    }
                    else
                    {
                        multi-PurposeLogging -message "$privMessagePrefix failed." -level "error"
                        $stage2error = $true
                    }
                }
            }

            ### INSTALLING THE SCHEDULED TASK AND ALL TRIGGERS
            if ( $stage2error -eq $false )
            {
                $scriptTaskArgumentList = $null
                $scriptTaskArgumentList = "-ssyvServerBackupFolder `"$ssyvServerBackupFolder`" -ssyvServerBackupTTL $ssyvServerBackupTTL -additionalUNCPathFolder `"$additionalUNCPathFolder`" -additionalUNCBackupTTL $additionalUNCBackupTTL"
            
                $result = $null
                $result = create-SSY-V-Powershellscripttask -taskName "$ssyvScheduledTaskName" -taskDescription "$ssyvScheduledTaskDescription" -maxRuntime "00:30:00" -dayinterval "1" -startTime "06:17PM" -taskScriptPath "$globalMyScriptFolderPath$globalMyScriptName.ps1" -triggerType "time" -argumentList "$scriptTaskArgumentList" -IgnoreActionReplacement $installScriptIgnoreDifferentActionParameters
                if ( $result -eq $false )
                {
                    $stage2error = $true
                    multi-PurposeLogging -message "$privMessagePrefix solution failed to install." -level "error"
                }
                else
                {
                    multi-PurposeLogging -message "$privMessagePrefix solution was installed successfully." -level "success"
                    multi-PurposeLogging -message "$privMessagePrefix exiting script due to installation mode." -level "warning"
                    multi-PurposeLogging -message "$privMessagePrefix setting all stages to completed=true." -level "verbose"
                    $stage2completed                   = $true
                    $stage3completed                   = $true
                    $stage5completed                   = $true
                    $stage10completed                  = $true
                }

                write-Logitem -itemType "smallseperator"
                stage-n
                exit
            }
        }
        else
        ### CREATE THE SHARE NAME FOR BACKUPS WITHIN SSY-V GROUP
        {
            Set-Variable -Name globalMySSYVServerShareName "$((Get-Item -Path "$globalMyLocalBackupFolder" -ErrorAction SilentlyContinue).BaseName)$" -Scope global
            multi-PurposeLogging -message "$privMessagePrefix share name is >$globalMySSYVServerShareName<." -level "verbose"
        }
    }
    
    ### PERFORMING THE ELECTION OF THE SCRIPT MASTER
    if ( $stage2error -eq $false )
    {
        $result = $null
        $result = elect-SSY-V-Script-Governor -skipElection $forceBackup
        if ($result -eq $false)
        {
            multi-PurposeLogging -message "$privMessagePrefix exiting script because I was not the governor." -level "warning"
            multi-PurposeLogging -message "$privMessagePrefix setting all stages to completed=true." -level "verbose"
            write-Logitem -itemType "smallseperator"
            $stage2completed                   = $true
            $stage3completed                   = $true
            $stage5completed                   = $true
            $stage10completed                  = $true
            
            stage-n
            exit
        }
        else
        {
            Set-Variable -Name globalMySSYVServerObjects ($result) -Scope global
        }
    }

    ### Result for the stage - Returning the Value of the major function.
    if ( $stage2error -eq $false )
    {
        multi-PurposeLogging -message "$privMessagePrefix returns >true<." -level "success"
        return $true
    }
    else
    {
        multi-PurposeLogging -message "$privMessagePrefix returns >>false<<." -level "error"
        return $false
    }
}
#----------------------------------------------------------------------------------------------------------------------------------
function stage-3()
{
    $stage3error = $false
    $privMessagePrefix = "$($MyInvocation.InvocationName) :"

    ### DOING THE BACKUP OF CONFIGURATION
    if ( $stage3error -eq $false )
    {
        $temporaryfolder = $null
        $temporaryfolder = "$([System.Guid]::NewGuid().ToString())"

        $result = $null
        $result = create-SSY-V-Configuration-Backup -backupPath "$globalMyLocalBackupFolder" -temporaryFolder "$temporaryfolder"
        if ( $result -eq $false )
        {
            $stage3error = $true
        }
    }

    ### DOING THE LOCAL EXPORT OF DCSOBJECTMODEL
    if ( $stage3error -eq $false )
    {
        $result = $null
        $result = export-SSY-V-DcsObjectModel -backupPath "$globalMyLocalBackupFolder" -temporaryFolder "$temporaryfolder"
        if ( $result -eq $false )
        {
            $stage3error = $true
        }
    }

    ### COPY THE DCSOBJECTMODEL TO EACH REMOTE SSY-V Server
    if ( $stage3error -eq $false )
    {
        $myServerName = $null
        $myServerName = hostname
        if ( -not ( "$globalMySSYVServerObjects" -eq "" ) )
        {
            multi-PurposeLogging -message "$privMessagePrefix copying dcsobjectmodel to other servers." -level "information"
            foreach ( $server in $globalMySSYVServerObjects )
            {
                if ( -not ($(@($Server.hostname -split "\.")[0]) -ieq "$myServerName" ) )
                {
                    $source = "$globalMyLocalBackupFolder$myServerName\$temporaryfolder\dcsobjectmodel.xml"
                    $destination = "\\$(@($Server.hostname -split "\.")[0])\$globalMySSYVServerShareName\$(@($Server.hostname -split "\.")[0])\$temporaryfolder\"
                
                    multi-PurposeLogging -message "$privMessagePrefix source >$source<, destination >$destination<." -level "verbose"
                    try 
                    {
                        $result = Copy-Item -Path "$source" -Destination "$destination" -Force -Confirm:$false -ErrorAction SilentlyContinue
                        multi-PurposeLogging -message "$privMessagePrefix     >$(@($Server.hostname -split "\.")[0])< success." -level "success"
                    }
                    catch
                    {
                        multi-PurposeLogging -message "$privMessagePrefix     >$(@($Server.hostname -split "\.")[0])< failed. Errormessage: >$($Error[0])<." -level "error"
                        $stage3error = $true
                    }
                }
            }
        }
        else
        {
            $stage3error = $true
            multi-PurposeLogging -message "$privMessagePrefix empty variable globalMySSYVServerObjects. Somthing is wrong!" -level "error"
        }
    }

    ### ZIPPING THE FOLDER CONTENT
    if ( $stage3error -eq $false )
    {
        $myServerName = $null
        $myServerName = hostname
        if ( -not ( "$globalMySSYVServerObjects" -eq "" ) )
        {
            $currentTimeStamp = $null
            $currentTimeStamp = get-NiceTimeStamp

            $currentZipFiles = @()

            multi-PurposeLogging -message "$privMessagePrefix zipping all backups on local and other servers." -level "information"
            foreach ( $server in $globalMySSYVServerObjects )
            {
                ## File name is dependent on server name
                $zipFileName = $null
                $zipFileName = "$currentTimeStamp"+"__"+"$(@($Server.hostname -split "\.")[0]).zip"

                $folderToZip = $null
                # If the server is not the local server
                if ( -not ($(@($Server.hostname -split "\.")[0]) -ieq "$myServerName" ) )
                {
                    $folderToZip = "\\$(@($Server.hostname -split "\.")[0])\$globalMySSYVServerShareName\$(@($Server.hostname -split "\.")[0])\$temporaryfolder\"
                }
                else
                {
                    $folderToZip = "$globalMyLocalBackupFolder$myServerName\$temporaryfolder\"
                }

                ### Checking the result.
                $result = $null
                $result = zip-foldercontent -absolutePathToSourceFolder "$folderToZip" -zipFileName "$zipFileName"
                if ( $result -eq $false )
                {
                    multi-PurposeLogging -message "$privMessagePrefix     >$(@($Server.hostname -split "\.")[0])< failed." -level "error"
                    $stage3error = $true
                }
                else
                {
                    multi-PurposeLogging -message "$privMessagePrefix     >$(@($Server.hostname -split "\.")[0])< success." -level "success"

                    $currentZipFiles += "$result"
                    ### Deleting the source folder
                    multi-PurposeLogging -message "$privMessagePrefix deleting the temporary folder >$folderToZip<." -level "information"
                    $result = $null
                    $result = Remove-Item -Path "$folderToZip" -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
                    if ( $? -eq $true )
                    {
                        multi-PurposeLogging -message "$privMessagePrefix     success." -level "success"
                    }
                    else
                    {
                        multi-PurposeLogging -message "$privMessagePrefix     failed." -level "error"
                        $stage3error = $true
                    }
                }
            }
        }
        else
        {
            $stage3error = $true
            multi-PurposeLogging -message "$privMessagePrefix empty variable globalMySSYVServerObjects. Somthing is wrong!" -level "error"
        }
    }

    ### SETTING A GLOBAL VARIABLE FOR THE BACKUP FILES.
    if ( $currentZipFiles -eq $null )
    {
        $stage3error = $true
    }
    else
    {
        Set-Variable -Name globalMyBackupZipFiles ($currentZipFiles) -Scope global
    }

    ##### Result of the stage
    if ( $stage3error -eq $true )
    {
        multi-PurposeLogging -message "$privMessagePrefix returns >false<." -level "error"
        return $false
    }
    else
    {
        multi-PurposeLogging -message "$privMessagePrefix returns >true<." -level "success"
        return $true
    }
}
#----------------------------------------------------------------------------------------------------------------------------------
function stage-5()
{
    $stage5error=$false
    $privMessagePrefix = "$($MyInvocation.InvocationName) :"

    ### COPYING THE DATA TO ALL SERVERS WITHIN SERVER GROUP
    if ( $stage5error -eq $false )
    {
        $myServerName = $null
        $myServerName = hostname
        multi-PurposeLogging -message "$privMessagePrefix syncing the backups to all servers in the configuration." -level "information"

        foreach ( $backup in $globalMyBackupZipFiles )
        {
            ### need to find the folder name
            $foldername = $null
            foreach ( $server in $globalMySSYVServerObjects )
            {
                if ( "$backup" -like "*\$(@($Server.hostname -split "\.")[0])\*")
                {
                    $foldername = $(@($Server.hostname -split "\.")[0])
                }
            }

            foreach ( $server in $globalMySSYVServerObjects )
            {
                $copyError = $false
            
                ### getting some stuff that will affect paths
                if ( $(@($Server.hostname -split "\.")[0]) -ieq "$myServerName" )
                {
                    $remoteServer = $false
                }
                else
                {
                    $remoteServer = $true
                }

                ### creating the paths
                $source = "$backup"
                if ( $remoteServer -eq $true )
                {
                    $destination = "\\$(@($Server.hostname -split "\.")[0])\$globalMySSYVServerShareName\$foldername\"
                }
                else
                {
                    $destination = "$globalMyLocalBackupFolder$foldername\"
                }

                ### Checking if the Destination-path exists
                if ( -not ( Get-Item -Path "$destination" -ErrorAction SilentlyContinue ) )
                {
                    multi-PurposeLogging -message "$privMessagePrefix destinationpath >$destination< is missing. Creating directory." -level "information"
                    $result =  New-Item -Path "$destination" -ItemType directory -ErrorAction SilentlyContinue
                    if ( $? -eq $true )
                    {
                        multi-PurposeLogging -message "$privMessagePrefix     success." -level "success"
                    }
                    else
                    {
                        multi-PurposeLogging -message "$privMessagePrefix     failed." -level "error"
                        $copyError = $true
                    }
                }

                ### Copying the data
                if ( $copyError -eq $false -and "$backup" -notlike "$destination*" -and $foldername -ne $null )
                {
                    multi-PurposeLogging -message "$privMessagePrefix copying file >$backup< to directory >$destination<." -level "information"

                    try 
                    {
                        $result = Copy-Item -Path "$backup" -Destination "$destination" -Force -Confirm:$false -ErrorAction SilentlyContinue
                        multi-PurposeLogging -message "$privMessagePrefix     success." -level "success"
                    }
                    catch
                    {
                        multi-PurposeLogging -message "$privMessagePrefix     failed." -level "error"
                        $stage3error = $true
                    }
                }

                ### Pushing the error outside the loop
                if ( $copyError -eq $true )
                {
                    $stage5error = $true
                }
            }
        }
    }

    ### COPYING THE DATA TO A DEFINED REMOTE SERVER
    if ( $stage5error -eq $false )
    {
        if ( $globalMyRemoteBackupFolder -ne $false)
        {
            multi-PurposeLogging -message "$privMessagePrefix remote backup folder provided. Syncing the backups to >$globalMyRemoteBackupFolder<" -level "information"
            foreach ( $backup in $globalMyBackupZipFiles )
            {
                ### need to find the folder name
                $foldername = $null
                foreach ( $server in $globalMySSYVServerObjects )
                {
                    if ( "$backup" -like "*\$(@($Server.hostname -split "\.")[0])\*")
                    {
                        $foldername = $(@($Server.hostname -split "\.")[0])
                    }
                }

                $copyError = $false

                ### creating the paths
                $source = "$backup"
                $destination = "$globalMyRemoteBackupFolder$foldername\"
                    
                ### Checking if the Destination-path exists
                if ( -not ( Get-Item -Path "$destination" -ErrorAction SilentlyContinue ) )
                {
                    multi-PurposeLogging -message "$privMessagePrefix destinationpath >$destination< is missing. Creating directory." -level "information"
                    $result = New-Item -Path "$destination" -ItemType directory -ErrorAction SilentlyContinue
                    if ( $? -eq $true )
                    {
                        multi-PurposeLogging -message "$privMessagePrefix     success." -level "success"
                    }
                    else
                    {
                        multi-PurposeLogging -message "$privMessagePrefix     failed." -level "error"
                        $copyError = $true
                    }
                }

                ### Copying the data
                if ( $copyError -eq $false -and $foldername -ne $null )
                {
                    multi-PurposeLogging -message "$privMessagePrefix copying file >$backup< to directory >$destination<." -level "information"
                    $result = Copy-Item -Path "$backup" -Destination "$destination" -Force -Confirm:$false -ErrorAction SilentlyContinue
                    if ( $? -eq $true )
                    {
                        multi-PurposeLogging -message "$privMessagePrefix     success." -level "success"
                    }
                    else
                    {
                        multi-PurposeLogging -message "$privMessagePrefix     failed." -level "error"
                        $copyError = $true
                    }
                }

                ### Pushing the error outside the loop
                if ( $copyError -eq $true )
                {
                    $stage5error = $true
                }
            }
        }
        else
        {
            multi-PurposeLogging -message "$privMessagePrefix no remote backup folder provided via parameter. Skipping copy of files to additional UNC path." -level "information"
        }
    }

    ##### Result of the stage
    if ( $stage5error -eq $true )
    {
        multi-PurposeLogging -message "$privMessagePrefix returns >false<." -level "error"
        return $false
    }
    else
    {
        multi-PurposeLogging -message "$privMessagePrefix returns >true<." -level "success"
        return $true
    }
}
#----------------------------------------------------------------------------------------------------------------------------------
function stage-10()
{
    $stage10error = $false
    $privMessagePrefix = "$($MyInvocation.InvocationName) :"

    ### DELETING FILES THAT ARE OLDER THAN THE SPECIFIED DAYS ON THE SSY-V HOSTS
    if ( $stage10error -eq $false )
    {
        multi-PurposeLogging -message "$privMessagePrefix cleaning up folders on SSY-V hosts." -level "information"
        foreach ( $server in $globalMySSYVServerObjects )
        {
            $deletionError = $false
            $myServerName = hostname

            ### getting some stuff that will affect paths
            if ( $($(@($Server.hostname -split "\.")[0])) -ieq "$myServerName" )
            {
                $remoteServer = $false
            }
            else
            {
                $remoteServer = $true
            }

            ### creating the paths
            if ( $remoteServer -eq $true )
            {
                $folderPath = "\\$(@($Server.hostname -split "\.")[0])\$globalMySSYVServerShareName"
            }
            else
            {
                $folderPath = "$globalMyLocalBackupFolder"
            }

            ### Cleaning up the directory
            $result = $null
            $result = cleanup-Folder -absolutePathToFolder "$folderPath" -TTLinDays $globalMylocalServerBackupTTL
            
            if ( $result -eq $true )
            {
                multi-PurposeLogging -message "$privMessagePrefix     >$(@($Server.hostname -split "\.")[0])< success." -level "success"
            }
            else
            {
                multi-PurposeLogging -message "$privMessagePrefix     >$(@($Server.hostname -split "\.")[0])< failed." -level "error"
                $deletionError = $true
            }
        
            ### Pushing the error outside the loop
            if ( $deletionError -eq $true )
            {
                $stage10error = $true
            }
        }
    }

    ### DELETING FILES THAT ARE OLDER THAN THE SPECIFIED DAYS ON REMOTE UNC
    if ( $stage10error -eq $false )
    {
        if ( $globalMyRemoteBackupFolder -ne $false )
        {
            multi-PurposeLogging -message "$privMessagePrefix cleaning up data on additional UNC share >$globalMyRemoteBackupFolder<." -level "information"
            ### Cleaning up the directory
            $result = $null
            $result = cleanup-Folder -absolutePathToFolder "$globalMyRemoteBackupFolder" -TTLinDays $globalMyglobalMyRemoteBackupFolderTTL
            
            if ( $result )
            {
                multi-PurposeLogging -message "$privMessagePrefix     success." -level "success"
            }
            else
            {
                multi-PurposeLogging -message "$privMessagePrefix     failed." -level "error"
                $stage10error = $true
            }
        }
        else
        {
            multi-PurposeLogging -message "$privMessagePrefix no remote backup folder provided via parameter. Skipping copy of files to additional UNC path." -level "information"
        }
    }

    ##### Result of the stage
    if ($stage10error -eq $true)
    {
        multi-PurposeLogging -message "$privMessagePrefix returns >false<." -level "error"
        return $false
    }
    else
    {
        multi-PurposeLogging -message "$privMessagePrefix returns >true<." -level "success"
        return $true
    }
}
#----------------------------------------------------------------------------------------------------------------------------------
function stage-n()
{
    # Version 1.10
    $privMessagePrefix = "$($MyInvocation.InvocationName) :"

    ### Restoring the powershell profile (if the functions is available.
    try
    {
        if ( $powershellProfileHandling -eq $true )
        {
            $myresult = $null
            $myresult = powerShellProfiles -action "enable"
        }
    }
    catch
    {
        # Do nothing
    }

    ### We are cleaning up potential open powershell-connections.
    if ( get-module -name "DataCore.Executive.Cmdlets" -ErrorAction SilentlyContinue )
    {
        multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix DataCore SSY-V Cmdlets loaded. Cleaning up potential PS-Sessions." -level "verbose"
        try
        {
            $result = $null
            $result = dcsService-Connection -action "cleanup"
        }
        catch
        {
            multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "$privMessagePrefix could not cleanup sessions due to missing function >dcsservice-connection<." -level "verbose"
        }
    }

    ### we are allways cleaning up the logfiles.
    try
    {
        $privLogFolderAbsolutePath = (Get-Item "$globalMyLogFileAbsolutePath" -Force -ErrorAction SilentlyContinue).DirectoryName
        $privResult = cleanup-Folder -absolutePathToFolder "$privLogFolderAbsolutePath" -TTLinDays "$logttlInDays"
    }
    catch
    {
        # do nothing
    }

    ### And writing a script finish message
    write-Logitem -itemType "end"

    ### Reaction of the override
    if ( $globalMyBatchModeOverride -eq $true )
    {
        $batchmode = $true
    }

    ### Waiting for the user to close the window if the script was double-clicked.
    if ($($pshost.Name) -notmatch "ISE Host" -and [Environment]::UserInteractive -and $batchmode -eq $false )
    {
        multi-PurposeLogging -absolutePathToLogfile "$globalMyLogFileAbsolutePath" -createTimeStamp $true -message "PRESS ANY KEY TO PROCEED." -level "information"
        Pause
    }

    ### If the user is DCSAdmin and the session is not interactive then it is likely the scheduler that runs the script If an error occured we throw a powershell error to provoke logging.
    if ( [Environment]::UserName -ieq "dcsadmin" -and ( ! ([Environment]::UserInteractive) ) )
    {
        if ($stage1completed -eq $false)
        {
            $errorMessage="Script error occured in stage 0. Please review the script logfile under >$globalMyLogFileAbsolutePath<."
            ### And throw the error
            Throw "$errorMessage"
        }
        elseif ($stage2completed -eq $false)
        {
            $errorMessage="Script error occured in stage 1. Please review the script logfile under >$globalMyLogFileAbsolutePath<."
            ### And throw the error
            Throw "$errorMessage"
        }
        elseif ($stage3completed -eq $false)
        {
            $errorMessage="Script error occured in stage 2. Please review the script logfile under >$globalMyLogFileAbsolutePath<."
            ### And throw the error
            Throw "$errorMessage"
        }
        elseif ($stage5completed -eq $false)
        {
            $errorMessage="Script error occured in stage 3. Please review the script logfile under >$globalMyLogFileAbsolutePath<."
            ### And throw the error
            Throw "$errorMessage"
        }
        elseif ($stage10completed -eq $false)
        {
            $errorMessage="Script error occured in stage 5. Please review the script logfile under >$globalMyLogFileAbsolutePath<."
            ### And throw the error
            Throw "$errorMessage"
        }
        elseif ($stage15completed -eq $false)
        {
            $errorMessage="Script error occured in stage 10. Please review the script logfile under >$globalMyLogFileAbsolutePath<."
            ### And throw the error
            Throw "$errorMessage"
        }
    }
}
###################################################################################################################################
##### FUNCTIONS STARTING WITH >T<

###################################################################################################################################
##### FUNCTIONS STARTING WITH >U<

###################################################################################################################################
##### FUNCTIONS STARTING WITH >V<

###################################################################################################################################
##### FUNCTIONS STARTING WITH >W<
#----------------------------------------------------------------------------------------------------------------------------------
function write-Logitem($itemType)
{
    # Version 1.1

    # This function uses multi-purpose-logging to write a "common" log message like Skript start, end, seperators.
    if ( $itemType -ieq "start" )
    {
        multi-PurposeLogging -message "==============================================================================" -level "verbose" -logVerboseToSession $true
        multi-PurposeLogging -message ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> SCRIPT START <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<" -level "verbose" -logVerboseToSession $true
        multi-PurposeLogging -message "==============================================================================" -level "verbose" -logVerboseToSession $true
    }
    elseif ($itemType -ieq "end" )
    {
        multi-PurposeLogging -message "==============================================================================" -level "verbose" -logVerboseToSession $true
        multi-PurposeLogging -message ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> SCRIPT END <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<" -level "verbose" -logVerboseToSession $true
        multi-PurposeLogging -message "==============================================================================" -level "verbose" -logVerboseToSession $true
    }
    elseif ($itemType -ieq "smallseperator" )
    {
        multi-PurposeLogging -message "------------------------------------------------------------------------------" -level "verbose" -logVerboseToSession $true
    }
    elseif ($itemType -ieq "largeseperator" )
    {
        multi-PurposeLogging -message "==============================================================================" -level "verbose" -logVerboseToSession $true
    }
}

###################################################################################################################################
##### FUNCTIONS STARTING WITH >X<

###################################################################################################################################
##### FUNCTIONS STARTING WITH >Y<

###################################################################################################################################
##### FUNCTIONS STARTING WITH >Z<
#----------------------------------------------------------------------------------------------------------------------------------
function zip-foldercontent($absolutePathToSourceFolder, $zipFileName)
{
    # Version 1.1
    $privAbsolutePathToSourceFolder = "$absolutePathToSourceFolder"
    $privZipFileName = "$zipFileName"

    $privMessagePrefix = "$($MyInvocation.InvocationName) :"
    multi-PurposeLogging -message "$privMessagePrefix Function invoked. Parameter privZipFileName has value >$privZipFileName< and privAbsolutePathToSourceFolder >$privAbsolutePathToSourceFolder<." -level "verbose"
    
    $errorOccured=$false

    ### checking if the sourcefolder is there.
    if ($privAbsolutePathToSourceFolder -eq "")
    {
        multi-PurposeLogging -message "$privMessagePrefix error. Parameter privAbsolutePathToSourceFolder is empty string." -level "error"
        $errorOccured = $true
    }
    else
    {
        ### Checking if the folder is existent
        if ( ! (get-item -Path "$privAbsolutePathToSourceFolder" -ErrorAction SilentlyContinue) )
        {
            multi-PurposeLogging -message "$privMessagePrefix could not find folder >$privAbsolutePathToSourceFolder<." -level "error"
            $errorOccured = $true
        }
        else
        {
            ### Checking if there is content in the folder
            if ( $(Get-ChildItem -Path "$privAbsolutePathToSourceFolder") -eq $null)
            {
                multi-PurposeLogging -message "$privMessagePrefix no child items (files / folders) in >$privAbsolutePathToSourceFolder<." -level "warning"
            }
        }
    }
    ### Checking if we have a filename provided
    if ( $privZipFileName -eq "")
    {
        multi-PurposeLogging -message "$privMessagePrefix no zip filename provided. Using folder name instead." -level "warning"
        $privZipFileName = "$((get-item -Path "$privAbsolutePathToSourceFolder" -ErrorAction SilentlyContinue).BaseName)"".zip"
    }
    elseif ( ! ($privZipFileName.Substring($privZipFileName.Length -4, 4) -ieq ".zip" ) )
    {
        multi-PurposeLogging -message "$privMessagePrefix no zip extension provided. Adding >.zip< to file name." -level "warning"
        $privZipFileName="$privZipFileName.zip"
    }

    ### The Doing
    if ($errorOccured -eq $false)
    {
        $parentDirectory = $null
        $parentDirectory = "$((Get-Item -Path "$privAbsolutePathToSourceFolder").parent.FullName)\"

        $absolutePathToZipFile=$null
        $absolutePathToZipFile="$parentDirectory$privZipFileName"

        ### Checking if the destination file is already there.
        if (Get-Item -Path "$absolutePathToZipFile" -ErrorAction SilentlyContinue)
        {
            multi-PurposeLogging -message "$privMessagePrefix zip file >$absolutePathToZipFile< already existent." -level "warning"
            $basename=(Get-Item -Path "$absolutePathToZipFile" -ErrorAction SilentlyContinue).BaseName
            $newname="$basename"+"__$(get-NiceTimeStamp).zip"
            multi-PurposeLogging -message "$privMessagePrefix renaming file to >$newname<." -level "information"
            
            $result=rename-Item -Path "$absolutePathToZipFile" "$newname" -Force -Confirm:$false
            if ( $? -eq $true )
            {
                multi-PurposeLogging -message "$privMessagePrefix success." -level "success"
            }
            else
            {
                multi-PurposeLogging -message "$privMessagePrefix failed." -level "error"
                $errorOccured = $true
            }
        }

        ### Zipping the folder content
        multi-PurposeLogging -message "$privMessagePrefix zipping folder content of >$privAbsolutePathToSourceFolder< to >$absolutePathToZipFile<." -level "information"
        Add-Type -Assembly System.IO.Compression.FileSystem
        ### The error is only caught through a try-catch
        try
        {
            $compressionLevel = [System.IO.Compression.CompressionLevel]::Optimal
            [System.IO.Compression.ZipFile]::CreateFromDirectory($privAbsolutePathToSourceFolder, $absolutePathToZipFile, $compressionLevel, $false)

            if (Get-Item -Path "$absolutePathToZipFile" -ErrorAction SilentlyContinue)
            {
                multi-PurposeLogging -message "$privMessagePrefix success." -level "success"
            }
            else
            {
                multi-PurposeLogging -message "$privMessagePrefix failed." -level "error"
                $errorOccured = $true
            }
        }
        catch
        {
            multi-PurposeLogging -message "$privMessagePrefix failed." -level "error"
            $errorOccured = $true            
        }
    }

    ### Return value of the function
    if ($errorOccured -eq $false)
    {
        multi-PurposeLogging -message "$privMessagePrefix returns the path to the zip-file >$absolutePathToZipFile<." -level "success"
        return $absolutePathToZipFile
    }
    else
    {
        multi-PurposeLogging -message "$privMessagePrefix returns >false<." -level "error"
        return $false
    }
}

###################################################################################################################################
##### SCRIPT MAIN
#### VARIABLES
## Script
$quickeditProtection                    = $true
$ensureElevation                        = $false
$powershellProfileHandling              = $false
$ssyvCmdletLoadEnforced                 = $true
$checkAutorunPs1Script                  = $false
$loadConfigurationXML                   = $false
$validateUsercontext                    = $false
$doNotClearAutologon                    = $true
$logttlInDays                           = 100
$expectedScriptFolder                   = ""
$logFileFolderName                      = "log"
$statusFolderName                       = ""
## Information for the Task
$ssyvScheduledTaskName                  = "Configuration-Backup"
$ssyvScheduledTaskDescription           = "Do not modify this task or its name as this script will recreate it."

#----------------------------------------------------------------------------------------------------------------------------------
### STAGE-STATUS INIT
$stage0completed                   = $false
$stage1completed                   = $false
$stage2completed                   = $false
$stage3completed                   = $false
$stage5completed                   = $false
$stage10completed                  = $false
#----------------------------------------------------------------------------------------------------------------------------------
### STAGE 0 - preparing all necessary stuff
### Setting needed global variables
## Getting the Script-Name
Set-Variable -Name globalMyScriptName ( get-scriptname ) -Scope global
## Getting the Script-Absolute Path
Set-Variable -Name globalMyScriptFolderPath ( get-scriptabsolutefolderpath ) -Scope global

$stage0completed = stage-0 -quickeditProtection $quickeditProtection -ensureElevation $ensureElevation
write-Logitem -itemType "smallseperator"

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### STAGE 1 - creating scripting environment
if ($stage0completed -eq $true)
{
    $stage1completed = stage-1 -powershellProfileHandling $powershellProfileHandling -ssyvCmdletLoadEnforced $ssyvCmdletLoadEnforced -quickeditProtection $quickeditProtection -checkAutorunPs1Script $checkAutorunPs1Script -loadConfigurationXML $loadConfigurationXML -serverHardwareConfigurationXMLFileName $serverHardwareConfigurationXMLFileName -serverDeploymentConfigurationXMLFileName $serverDeploymentConfigurationXMLFileName -expectedScriptFolder $expectedScriptFolder -validateUsercontext $validateUsercontext -doNotClearAutologon $doNotClearAutologon
    write-Logitem -itemType "smallseperator"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### STAGE 2
if ($stage1completed -eq $true)
{
    $stage2completed = stage-2
    write-Logitem -itemType "smallseperator"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### STAGE 3
if ($stage2completed -eq $true)
{
    $stage3completed = stage-3
    write-Logitem -itemType "smallseperator"
}
       
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### STAGE 5
if ($stage3completed -eq $true)
{
    $stage5completed = stage-5
    write-Logitem -itemType "smallseperator"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### STAGE 10
if ($stage5completed -eq $true)
{
    $stage10completed = stage-10
    write-Logitem -itemType "smallseperator"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
##### CLOSE DOWN
### STAGE N - END OF SCRIPT
stage-n
