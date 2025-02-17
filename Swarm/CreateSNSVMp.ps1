# ---------------------------------------------------------------------------------------------------------------------------------
# ---                                                                                                                           ---
# ---   Create Hyper-V VM for DataCore Single Node Swarm (SNS)                                                                  ---
# ---   Script provided as is, no support                                                                                       ---
# ---   Tested on Windows 11 with Hyper-V enabled                                                                               ---
# ---   Creator: Klaus Krebber, DataCore Software, CE Region                                                                    ---
# ---   Version 1.2, 17.02.2025                                                                                                 ---
# ---                                                                                                                           ---
# ---   Use the script carefully as it deletes an existing VM without asking!!!                                                 ---
# ---	Checks if the SNS VM already exists and if yes the script deletes the VM and create it again                            ---
# ---                                                                                                                           ---
# ---------------------------------------------------------------------------------------------------------------------------------


# Recommndation after running the Skript
#   set 64GB HDD as second boot device manually

# Set-ExecutionPolicy RemoteSigned


# ---------------------------------------------------------------------------------------------------------------------------------
# ---                       Declaration of variables for customization to deployment environment                                ---
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

# Path to the Ubuntu ISO file, the name of Ubuntu ISO file and the Ubuntu Download URL (Ubuntu Server 22.04.4 LTS)
$isopath = "C:\Downloads"
$ubtiso = "ubuntu-22.04.5-live-server-amd64.iso"
$ubturl = "https://releases.ubuntu.com/22.04.5/$ubtiso"


# Variables for VM

# Name of VM, Default dcssns
$vmname = "dcssns"

# Path for System + Data Disks and an additional path for the Storage Nodes-Disks
$vmpath = "C:\Hyper-V"
$vmdiskpath1 = "$vmpath\$vmname\Virtual Hard Disks"
$vmdiskpath2 = "C:\Hyper-V\Virtual Hard Disks"

# OS Disk size and Count - default size 64GB and 1 disk (2 Disks for Software RAID1)
$OSdisksize = 64GB
$osdiskcount = 1

# Additional Disk for /var and /var/lib, default size 100GB and 1 disk (2 Disks for Software RAID1)
$libdisksize = 100GB
$libdiskcount = 1

# Disks for Storage Nodes, Default size 50GB and 8 disks
$sndisksize = 50GB
$sndiskcount = 8

# VHDX type: "Fixed" or "Dynamic", Type 'Fixed' is recommended
# VHDX type for OS + LIB Disks
$vhdxdtype = "Dynamic"
# VHDC type for Storage Node disks, Type 'Fixed' is recommended
$snvhdxtype = "Fixed"

# CPU and RAM settings
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
# Check if Ubuntu 22.04 is already downloaded and in the configured directory. If not, download it
# ---



Write-Host "--- Check for Ubuntu ISO and download is not there"

if (Test-Path -Path $isopath\$ubtiso) { 

    Write-Host "ISO file for Ubuntu installation is already there ... Nothing more to download!" 

  } else {

    Write-Host "ISO for Ubuntu Server with round about 2 GB is downloading. Could take some time - go for a coffee :)"

    if ( $proxyurl -eq "") { Invoke-WebRequest -Uri $ubturl -OutFile $isopath\$ubtiso } else { 

      if ( $proxyauth -eq "" ) { Invoke-WebRequest -Proxy $proxyurl -Uri $ubturl -OutFile $isopath\$ubtiso } else {
      
        Invoke-WebRequest -Proxy $proxyurl -ProxyUseDefaultCredentials -Uri $ubturl -OutFile $isopath\$ubtiso
        Write-Host "Download completed!"
      
      }
    

    }

  }


# ---------------------------------------------------------------------------------------------------------------------------------
# Check if VM already exists. If yes, power the VM off and delete the existing VM including all files
# ---

Write-Host "--- Check if SNS VM exists and delete if yes"

Get-VM $vmname 2>$null

if ($?) {

  get-vm $vmname |  where {$_.State -eq 'Running'} | Stop-VM -Force

  if ($?) {
    Remove-VM -Name $vmname -Force
    Remove-Item -Path "$vmpath\$vmname", "$vmdiskpath2\$vmname-snd*" -Force -Recurse
  }

  }


# ---------------------------------------------------------------------------------------------------------------------------------
# Create VM for DataCore SNS
# ---

Write-Host "--- Create new VM"

New-VM -VMName $vmname -Generation 2 -MemoryStartupBytes $RAMsize -BootDevice CD -Path $vmpath -SwitchName $vswitchname
Set-VM -VMName $vmname -ProcessorCount $cpucount -StaticMemory -MemoryStartupBytes $RAMsize  -AutomaticCheckpointsEnabled $false -AutomaticStopAction TurnOff -Notes "Single Node Swarm v1.1"


# Create the Disks for the VM - 'Fixed' or 'Dynamic'

Write-Host "--- Create Disks for OS + Data"

if ( $vhdxdtype -eq "Fixed" ) {

# Create Disk(s) of type Fixed for OS 
  1 .. $osdiskcount | foreach {New-VHD -Path $vmdiskpath1\$vmname-sos$_.vhdx -Fixed -SizeBytes $OSdisksize}
  1 .. $osdiskcount | foreach {Add-VMHardDiskDrive -VMname $vmname -ControllerNumber 0 -Path $vmdiskpath1\$vmname-sos$_.vhdx}

# Create additional Disk(s) of type Fixed for /var + /var/lib
  1 .. $libdiskcount | foreach {New-VHD -Path $vmdiskpath1\$vmname-slib$_.vhdx -Fixed -SizeBytes $libdisksize}
  1 .. $libdiskcount | foreach {Add-VMHardDiskDrive -VMname $vmname -ControllerNumber 0 -Path $vmdiskpath1\$vmname-slib$_.vhdx}
  
}  else {

# Create Disk(s) of type Dynamic for OS 
  1 .. $osdiskcount | foreach {New-VHD -Path $vmdiskpath1\$vmname-sos$_.vhdx -Dynamic -SizeBytes $OSdisksize}
  1 .. $osdiskcount | foreach {Add-VMHardDiskDrive -VMname $vmname -ControllerNumber 0 -Path $vmdiskpath1\$vmname-sos$_.vhdx}

# Create additional Disk(s) of type Dynamic for /var + /var/lib
  1 .. $libdiskcount | foreach {New-VHD -Path $vmdiskpath1\$vmname-slib$_.vhdx -Dynamic -SizeBytes $libdisksize}
  1 .. $libdiskcount | foreach {Add-VMHardDiskDrive -VMname $vmname -ControllerNumber 0 -Path $vmdiskpath1\$vmname-slib$_.vhdx}

}

Write-Host "--- Create Disks for Storage Nodes"

# Add 2nd SCSI controller and create and add Storage Node disks to the controller
Set-VMDvdDrive -VMName $vmname -ControllerNumber 0 -Path $isopath\$ubtiso
Add-VMScsiController -VMName $vmname

if ( $snvhdxtype -eq "Fixed") {

  1 .. $sndiskcount | foreach {New-VHD -Path $vmdiskpath2\$vmname-snd0$_.vhdx -Fixed -SizeBytes $sndisksize}
  1 .. $sndiskcount | foreach {Add-VMHardDiskDrive -VMname $vmname -ControllerNumber 1 -Path $vmdiskpath2\$vmname-snd0$_.vhdx}

} else {

  1 .. $sndiskcount | foreach {New-VHD -Path $vmdiskpath2\$vmname-snd0$_.vhdx -Dynamic -SizeBytes $sndisksize}
  1 .. $sndiskcount | foreach {Add-VMHardDiskDrive -VMname $vmname -ControllerNumber 1 -Path $vmdiskpath2\$vmname-snd0$_.vhdx}

}

Write-Host "--- Configure Networking"

# Set VLAN and static MAC to Network Adapter if configured 
if ( $vlanid -ne 0 ) { Set-VMNetworkAdapterVlan -VMName $vmname -Access -VlanID $vlanid }
if ( $staticMAC -ne "" ) { Get-VM -name $vmname | Get-VMNetworkAdapter | Set-VMNetworkAdapter -StaticMacAddress $staticMAC }

Write-Host "--- Configure additional VM settings"

# Set some additional VM settings
Set-VMProcessor -VMName $vmname -ExposeVirtualizationExtensions $false
Set-VMFirmware -VMName $vmname -EnableSecureBoot ON -SecureBootTemplate "MicrosoftUEFICertificateAuthority" -FirstBootDevice $(Get-VMDvDDrive -VMName $vmname) -verbose



# ---------------------------------------------------------------------------------------------------------------------------------
Write-Host ""
Write-Host ""
Write-Host "----------------------------------------------------------------------------------------------"
Write-Host "---                                                                                        ---"
Write-Host "---  All scripted work successfully done :)                                                ---"
Write-Host "---                                                                                        ---"
Write-Host "---  Please change manually the Boot order to die OS Disk(s) as 2nd (and 3rd) boot device  ---"
Write-Host "---                                                                                        ---"
Write-Host "----------------------------------------------------------------------------------------------"
Write-Host ""
Write-Host ""

# ---------------------------------------------------------------------------------------------------------------------------------
# ---                                                         end of script                                                     ---
# ---------------------------------------------------------------------------------------------------------------------------------
