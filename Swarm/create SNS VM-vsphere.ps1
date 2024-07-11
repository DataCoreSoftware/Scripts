# Create VMware VM using PowerClI for DataCore Single Node Swarm (SNS)
# Skript provided as is, no support
# Creator: Steffen Merkel, DataCore Software, CE Region

param(
[string]$vmname,
[string]$variante)



#some variables
$vmname = "SNS-autoinstall"
#Configurations: Typ, CPUs, RAM GB, Disk0 GB, Disk1 GB, DataDisk count, DataDisk Size GB
$variante = (16,64,64,100,8,16)
$vcenter = "vcenter.dcs-testcenter.local"
$username = "administrator@sso.dcs-testcenter.local"
$password = "Terra001!"
$hostUsername = "root"
$hostPassword = "datacore"
$datacenter = "RZ-Gruen"
$Datastore = "SM-Div"
$vmhost = "esx-gruen-01.dcs-testcenter.local"
$managementnet = "VM Network"
$heartbeartnet = "isolated"
$downloadiso = $true

#connect to vcenter
Write-Host "Connecting to vCenter - $vcenter ..." -nonewline
$success = Connect-VIServer $vcenter -username $username -Password $password -warningaction silentlycontinue -force
if ( $success )
{
    Write-Host "Connected!" -Foregroundcolor Green
}
else
{
    Write-Host "Something is wrong, Aborting script" -Foregroundcolor Red
    exit
    # break
}
if ($downloadiso){
    $isolocalexists=[System.IO.File]::Exists("$env:temp\ubuntu-22.04.4-live-server-amd64.iso")
    if (!$isolocalexists){
        write-host "Downloading ISO"
        Invoke-WebRequest -Uri "https://releases.ubuntu.com/jammy/ubuntu-22.04.4-live-server-amd64.iso" -OutFile "$env:temp\ubuntu-22.04.4-live-server-amd64.iso"
    }
    
    $todatastore = 'vmstore:\' + $datacenter + '\' + $Datastore + '\'
    

    $ds = Get-Datastore -Name $Datastore
    
    New-PSDrive -Location $ds -Name DS -PSProvider VimDatastore -Root '\' | Out-Null
    
    $isoexist = Get-ChildItem -Path DS:\ -Include ubuntu-22.04.4-live-server-amd64.iso -Recurse | Select Name,FolderPath

    Remove-PSDrive -Name DS -Confirm:$false
    
    if (!$isoexists){
        write-host "Copying ISO"
        Copy-DatastoreItem -Item "$env:temp\ubuntu-22.04.4-live-server-amd64.iso" -Destination $todatastore -Force
    }
} 


 

# Stop script on error
$ErrorActionPreference = "stop"



$desired = @(

    @{

        Name = 'disk.enableuuid'

        Value = $true

    }

    
)



#try {$server = Get-VMHost $vmhost -ErrorAction Stop}
#catch 
#{
#"Fehler beim Verbinden mit dem Host!"
#exit
#}
#get CPU Frequency
$cpufrequency = $server.ExtensionData.summary.hardware.CpuMhz





    $vmexist = get-vm -name $vmname -ErrorAction SilentlyContinue
    If (!$vmexist){
 
                $cores = $variante[0]
                $memory = $variante[1]
                $disk0capacity = $variante[2]
                $disk1capacity = $variante[3]
                $datadiskcapacity = $variante[5]
                
                
            

            #}

                    
            $newvm = VMware.VimAutomation.Core\New-VM -Name $vmname -Datastore $Datastore -DiskGB $disk0capacity -MemoryGB $memory -NumCpu $cores -NetworkName $managementnet -CD -DiskStorageFormat Thin -GuestId rhel7_64Guest -VMHost $vmhost
            if ($disk1capacity -ne 0){New-HardDisk -VM $newvm -CapacityGB $disk1capacity}
            
            for ($i=0; $i -lt $variante[4]; $i++){
                New-HardDisk -VM $newvm -CapacityGB $variante[5] 
            }
            if ($downloadiso){
                $dsisopath = '[' + $Datastore + '] ubuntu-22.04.4-live-server-amd64.iso'
                VMware.VimAutomation.Core\Get-VM -Name $vmname | Get-CDDrive| Set-CDDrive  -IsoPath $dsisopath -StartConnected $true -Confirm:$false
                
            }
            #Memory Reservation
                $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
                $spec.memoryReservationLockedToMax = $true
                $newvm.ExtensionData.reconfigVM_Task($spec)
            #CPU Reservation
                $reservecpu = $cores * $cpufrequency
                $newvm | Get-VMResourceConfiguration |Set-VMResourceConfiguration -CpuReservationMhz $reservecpu
                

            $desired | %{

            $setting = Get-AdvancedSetting -Entity $newvm -Name $_.Name

            if($setting){

                if($setting.Value -eq $_.Value){

                    #Write-Output "Setting $($_.Name) present and set correctly"

                }

                else{

                    #Write-Output "Setting $($_.Name) present but not set correctly"

                    Set-AdvancedSetting -AdvancedSetting $setting -Value $_.Value -Confirm:$false

                }


            }
            else{

                #Write-Output "Setting $($_.Name) not present."

                New-AdvancedSetting -Name $_.Name -Value $_.Value -Entity $newvm -Confirm:$false

            }
        

        }
    
        }


#}
    else
    {
    write-host "VM "  $vmname  " existiert bereits. Nichts zu tun!"
    }


Disconnect-VIServer  -confirm:$false