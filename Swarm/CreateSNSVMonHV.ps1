# Create VM for DataCore SingleNodeSwarm

# Set-ExecutionPolicy RemoteSigned

$vmname = "dcssns"
$vmpath = "C:\Hyper-V"
$vmdiskpath1 = "$vmpath\$vmname\Virtual Hard Disks"
$vmdiskpath2 = "C:\Hyper-V\Virtual Hard Disks"
$isopath = "C:\ISO\Ubuntu"
$ubtiso = "ubuntu-22.04.4-live-server-amd64.iso"
$diskcount = 8

$cpucount = 16
$vswitchname = "vSwitch0"
$vlanid = 1


New-VM -VMName $vmname -Generation 2 -MemoryStartupBytes 64GB -BootDevice CD -Path $vmpath -SwitchName $vswitchname
Set-VM -VMName $vmname -ProcessorCount $cpucount -StaticMemory -MemoryStartupBytes 64GB -AutomaticCheckpointsEnabled $false -Notes "Single Node Swarm v16.1"

New-VHD -Path $vmdiskpath1\$vmname-os.vhdx -SizeBytes 64GB -Fixed
Add-VMHardDiskDrive -VMName $vmname -Path $vmdiskpath1\$vmname-os.vhdx
New-VHD -Path $vmdiskpath1\$vmname-lib.vhdx -SizeBytes 100GB -Fixed
Add-VMHardDiskDrive -VMName $vmname -Path $vmdiskpath1\$vmname-lib.vhdx

Set-VMDvdDrive -VMName $vmname -ControllerNumber 0 -Path $isopath\$ubtiso
Add-VMScsiController -VMName $vmname

1 .. $diskcount | foreach {New-VHD -Path $vmdiskpath2\$vmname-snd0$_.vhdx -Fixed -SizeBytes 16GB}

1 .. $diskcount | foreach {Add-VMHardDiskDrive -VMname $vmname -ControllerNumber 1 -Path $vmdiskpath2\$vmname-snd0$_.vhdx}



Set-VMNetworkAdapterVlan -VMName $vmname -Access -VlanID $vlanid
Set-VMProcessor -VMName $vmname -ExposeVirtualizationExtensions $false
Set-VMFirmware -VMName $vmname -EnableSecureBoot ON -SecureBootTemplate "MicrosoftUEFICertificateAuthority" -FirstBootDevice $(Get-VMDvDDrive -VMName $vmname) -verbose



