# ---------------------------------------------------------------------------------------------------------------------------------
# ---                                                                                                                           ---
# ---   Create Hyper-V VM for DataCore Single Node Swarm (SNS)                                                                  ---
# ---   Script provided as is, no support                                                                                       ---
# ---   Tested on Windows 11 with Hyper-V enabled                                                                               ---
# ---   Creator: Klaus Krebber, DataCore Software, CE Region                                                                    ---
# ---   Version 1.3.2, 04.07.2025                                                                                               ---
# ---                                                                                                                           ---
# ---   Please use the script carefully as it deletes an existing VM with the name configured in the variable $vmname           ---
# ---   without a warning!!!                                                                                                    ---
# ---	Checks if the SNS VM already exists and if yes the script deletes the VM and create it again                            ---
# ---                                                                                                                           ---
# ---   As the SNS deployment is based on Hardware templates the pre-configured ressources are fitting the template "smallA"    ---
# ---      CPU:   12-24                                                                                                         ---
# ---      RAM:   30-128 GB                                                                                                     ---
# ---      Disks: 8                                                                                                             ---
# ---        min: 8 GB                                                                                                          ---
# ---        max: 64 GB                                                                                                         ---
# ---                                                                                                                           ---
# ---------------------------------------------------------------------------------------------------------------------------------


# Set-ExecutionPolicy RemoteSigned


# ---------------------------------------------------------------------------------------------------------------------------------
# ---                         Declaration of variables for customization to deployment environment                              ---
# ---------------------------------------------------------------------------------------------------------------------------------
#
#
# Make your changes as required


# Global Environment / IT infrastructure
# Proxy configuration
#  - use "" for the URL if no Proxy for the Ubuntu ISO download is required
#  - use "" is no proxy authentication required
$proxyurl = ""
$proxyauth = ""

# Path to the Ubuntu ISO file, the name of Ubuntu ISO file and the Ubuntu Download URL (version in script: Ubuntu Server 22.04.5 LTS)
$isopath = "C:\Downloads"
$ubtiso = "ubuntu-22.04.5-live-server-amd64.iso"
$ubturl = "https://releases.ubuntu.com/22.04.5/$ubtiso"


# Variables for VM

# Name of VM, Default: dcssns
$vmname = "dcssns"

# Path for System + Data Disks and an additional path for the Storage Nodes-Disks
$vmpath = "C:\Hyper-V"
$vmdiskpath1 = "$vmpath\$vmname\Virtual Hard Disks"
$vmdiskpath2 = "C:\Hyper-V\Virtual Hard Disks"

# OS Disk size and Count,  Defaults: 75GB and 1 Disk (2 Disks for Software RAID1)
# Supported vallues
#   size:   >= 64GB
#   count:  1 or 2
$OSdisksize = 64GB
$osdiskcount = 1

# Additional Disk for /var and /var/lib, Defaults: 100GB and 1 Disk (2 Disks for Software RAID1)
# Supported vallue
#   size:   >= 100GB
#   count:  1 or 2
$libdisksize = 100GB
$libdiskcount = 1

# Disks for Storage Nodes, Defaults: 50GB and 8 disks
# To fit the 'smallA"-Template Disk count is fix 8, Disk size can be configured from 8GB to 64GB 
$sndisksize = 50GB
$sndiskcount = 8

# VHDX type: "Fixed" or "Dynamic", Type 'Fixed' is recommended
# VHDX type for OS + LIB Disks
$vhdxdtype = "Dynamic"
# VHDC type for Storage Node disks, Type 'Fixed' is recommended
$snvhdxtype = "Fixed"

# CPU and RAM settings, Defaults: 16 CPU Cores + 64GB
#   CPU Cores: 12 - 24
#   RAM: 64 - 128GB
$cpucount = 16
$RAMsize = 64GB

# Networking / Hyper-V Settings
#  vSwitch and VLAN ID, use for VLAN ID 0 if no VLAN ID required
#  optional static MAC Address for VM, default for MAC address: ""
$vswitchname = "vSwitch0"
$vlanid = 0
$staticMAC = ""



# ---------------------------------------------------------------------------------------------------------------------------------
# ---                                                                                                                           ---
# ---                                                     Main script                                                           ---
# ---                                                                                                                           ---
# ---------------------------------------------------------------------------------------------------------------------------------

clear

Write-Host ""
Write-Host "----------------------------------------------------------------------------"
Write-Host "--- Create VM for SNS"
Write-Host ""
Write-Host ""



# ---------------------------------------------------------------------------------------------------------------------------------
# Check if Ubuntu 22.04.x is already downloaded and in the configured directory. If not, download it
# ---



Write-Host "--- Check for Ubuntu ISO and download is there"

if (Test-Path -Path $isopath\$ubtiso) { 

    Write-Host "--- ISO file for Ubuntu installation is already there ... Nothing more to download!" -f Green
    Write-Host "" 

  } else {

    Write-Host "--- ISO for Ubuntu Server with round about 2 GB is downloading. Could take some time - good time for a coffee or a tea :)"

    if ( $proxyurl -eq "") { Invoke-WebRequest -Uri $ubturl -OutFile $isopath\$ubtiso } else { 

      if ( $proxyauth -eq "" ) { Invoke-WebRequest -Proxy $proxyurl -Uri $ubturl -OutFile $isopath\$ubtiso } else {
      
        Invoke-WebRequest -Proxy $proxyurl -ProxyUseDefaultCredentials -Uri $ubturl -OutFile $isopath\$ubtiso
        Write-Host "--- Download completed!" -f Green
        Write-Host ""
      
      }
    

    }

  }


# ---------------------------------------------------------------------------------------------------------------------------------
# Check if VM already exists. If yes, power the VM off and delete the existing VM including all files
# ---

Write-Host "--- Check if VM for SNS already exists and delete it if yes"

Get-VM $vmname 2>$null

if ($?) {

  get-vm $vmname |  where {$_.State -eq 'Running'} | Stop-VM -Force

  if ($?) {

    Write-Host "--- VM $vmname already exists -> will delete the VM and all belonging files" -f Red
    Remove-VM -Name $vmname -Force
    Write-Host "---   Delete all Disk files of the VM" -f Red
    Remove-Item -Path "$vmpath\$vmname", "$vmdiskpath2\$vmname-snd*" -Force -Recurse
    Write-Host "--- VM $vmname with all of its files and folders successfully deleted." -f Green
    Write-Host ""

  }
  
  }


# ---------------------------------------------------------------------------------------------------------------------------------
# Create VM for DataCore SNS
# ---

Write-Host "--- Create new VM " -NoNewline 
  Write-Host "$vmname" -f Cyan

New-VM -VMName $vmname -Generation 2 -MemoryStartupBytes $RAMsize -BootDevice CD -Path $vmpath -SwitchName $vswitchname | Out-Null
Set-VM -VMName $vmname -ProcessorCount $cpucount -StaticMemory -MemoryStartupBytes $RAMsize  -AutomaticCheckpointsEnabled $false -AutomaticStopAction TurnOff -Notes "Single Node Swarm v1.1"


# Create the Disks for the VM - 'Fixed' or 'Dynamic'

Write-Host "--- Create Disks for OS + Data"

if ( $vhdxdtype -eq "Fixed" ) {

# Create Disk(s) of type Fixed for OS 
  1 .. $osdiskcount | foreach {New-VHD -Path $vmdiskpath1\$vmname-sos$_.vhdx -Fixed -SizeBytes $OSdisksize | Out-Null}
  1 .. $osdiskcount | foreach {Add-VMHardDiskDrive -VMname $vmname -ControllerNumber 0 -Path $vmdiskpath1\$vmname-sos$_.vhdx}

# Create additional Disk(s) of type Fixed for /var + /var/lib
  1 .. $libdiskcount | foreach {New-VHD -Path $vmdiskpath1\$vmname-slib$_.vhdx -Fixed -SizeBytes $libdisksize | Out-Null}
  1 .. $libdiskcount | foreach {Add-VMHardDiskDrive -VMname $vmname -ControllerNumber 0 -Path $vmdiskpath1\$vmname-slib$_.vhdx}
  
}  else {

# Create Disk(s) of type Dynamic for OS 
  1 .. $osdiskcount | foreach {New-VHD -Path $vmdiskpath1\$vmname-sos$_.vhdx -Dynamic -SizeBytes $OSdisksize | Out-Null}
  1 .. $osdiskcount | foreach {Add-VMHardDiskDrive -VMname $vmname -ControllerNumber 0 -Path $vmdiskpath1\$vmname-sos$_.vhdx}

# Create additional Disk(s) of type Dynamic for /var + /var/lib
  1 .. $libdiskcount | foreach {New-VHD -Path $vmdiskpath1\$vmname-slib$_.vhdx -Dynamic -SizeBytes $libdisksize | Out-Null}
  1 .. $libdiskcount | foreach {Add-VMHardDiskDrive -VMname $vmname -ControllerNumber 0 -Path $vmdiskpath1\$vmname-slib$_.vhdx}

}

Write-Host "--- Create Disks for Storage Nodes"

# Add 2nd SCSI controller and create and add Storage Node disks to the controller
Set-VMDvdDrive -VMName $vmname -ControllerNumber 0 -Path $isopath\$ubtiso
Add-VMScsiController -VMName $vmname

if ( $snvhdxtype -eq "Fixed") {

  1 .. $sndiskcount | foreach {New-VHD -Path $vmdiskpath2\$vmname-snd0$_.vhdx -Fixed -SizeBytes $sndisksize | Out-Null}
  1 .. $sndiskcount | foreach {Add-VMHardDiskDrive -VMname $vmname -ControllerNumber 1 -Path $vmdiskpath2\$vmname-snd0$_.vhdx}

} else {

  1 .. $sndiskcount | foreach {New-VHD -Path $vmdiskpath2\$vmname-snd0$_.vhdx -Dynamic -SizeBytes $sndisksize | Out-Null}
  1 .. $sndiskcount | foreach {Add-VMHardDiskDrive -VMname $vmname -ControllerNumber 1 -Path $vmdiskpath2\$vmname-snd0$_.vhdx -InformationAction SilentlyContinue}

}

Write-Host "--- Configure Networking"

# Set VLAN and static MAC to Network Adapter if configured 
if ( $vlanid -ne 0 ) { Set-VMNetworkAdapterVlan -VMName $vmname -Access -VlanID $vlanid }
if ( $staticMAC -ne "" ) { Get-VM -name $vmname | Get-VMNetworkAdapter | Set-VMNetworkAdapter -StaticMacAddress $staticMAC }

Write-Host "--- Configure additional VM settings"

# Set some additional VM settings
Set-VMProcessor -VMName $vmname -ExposeVirtualizationExtensions $false
Set-VMFirmware -VMName $vmname -EnableSecureBoot ON -SecureBootTemplate "MicrosoftUEFICertificateAuthority"

if ( $osdiskcount -eq 1 ) {

  Set-VMFirmware -VMName $vmname -BootOrder $(Get-VMHardDiskDrive -VMName dcssns -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 1), $(Get-VMDvDDrive -VMName $vmname)

} else {

  Set-VMFirmware -VMName $vmname -BootOrder $(Get-VMHardDiskDrive -VMName dcssns -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 1), $(Get-VMHardDiskDrive -VMName dcssns -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 2), $(Get-VMDvDDrive -VMName $vmname)

}

# ---------------------------------------------------------------------------------------------------------------------------------
Write-Host ""
Write-Host ""
Write-Host "----------------------------------------------------------------------------------------------"
Write-Host "---                                                                                        ---"
Write-Host "---  All scripted work successfully done :)                                                ---" -f Green
Write-Host "---                                                                                        ---"
Write-Host "---  Please Power-on the VM and start with the installation of Ubuntu.                     ---"
Write-Host "---                                                                                        ---"
Write-Host "----------------------------------------------------------------------------------------------"
Write-Host ""
Write-Host ""

# ---------------------------------------------------------------------------------------------------------------------------------
# ---                                                         end of script                                                     ---
# ---------------------------------------------------------------------------------------------------------------------------------
