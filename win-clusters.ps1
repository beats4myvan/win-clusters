#
# HW P1 (NLB)
#

# Set local credentials
$Password = ConvertTo-SecureString -AsPlainText "Password1" -Force
$LocalUser = "Administrator" 
$LC = New-Object System.Management.Automation.PSCredential($LocalUser, $Password)

# Set domain credentials
$Domain = "WSAA.LAB"
$DomainUser = "$Domain\Administrator" 
$DC = New-Object System.Management.Automation.PSCredential($DomainUser, $Password)

# Clone VHDs
cp 'C:\BAK\WIN-SRV-2K19-ST\VHD\WIN-SRV-2K19-ST.vhdx' C:\HV\HW31-DC.vhdx
cp 'C:\BAK\WIN-SRV-2K19-ST\VHD\WIN-SRV-2K19-ST.vhdx' C:\HV\HW31-SRV1.vhdx
cp 'C:\BAK\WIN-SRV-2K19-ST\VHD\WIN-SRV-2K19-ST.vhdx' C:\HV\HW31-SRV2.vhdx

# Create VMs (add -MemoryMaximumBytes to Set-VM)
New-VM -Name HW31-DC -MemoryStartupBytes 1536mb -VHDPath C:\HV\HW31-DC.vhdx -Generation 2 -SwitchName "Hyper-V Internal Switch" | Set-VM -CheckpointType Production -AutomaticCheckpointsEnabled $false
New-VM -Name HW31-SRV1 -MemoryStartupBytes 1536mb -VHDPath C:\HV\HW31-SRV1.vhdx -Generation 2 -SwitchName "Hyper-V Internal Switch" | Set-VM -CheckpointType Production -AutomaticCheckpointsEnabled $false
New-VM -Name HW31-SRV2 -MemoryStartupBytes 1536mb -VHDPath C:\HV\HW31-SRV2.vhdx -Generation 2 -SwitchName "Hyper-V Internal Switch" | Set-VM -CheckpointType Production -AutomaticCheckpointsEnabled $false

# Start VMs
Start-VM -Name HW31-DC, HW31-SRV1, HW31-SRV2

# Ensure that the Administrator password (Password1) is set in each VM
pause

# Change OS name
Invoke-Command -VMName HW31-DC -Credential $LC -ScriptBlock { Rename-Computer -NewName HW31-DC -Restart  }
Invoke-Command -VMName HW31-SRV1 -Credential $LC -ScriptBlock { Rename-Computer -NewName HW31-SRV1 -Restart  }
Invoke-Command -VMName HW31-SRV2 -Credential $LC -ScriptBlock { Rename-Computer -NewName HW31-SRV2 -Restart  }

# Set network settings for the first NIC on each VM
Invoke-Command -VMName HW31-DC -Credential $LC -ScriptBlock { New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress "192.168.66.2" -PrefixLength 24 -DefaultGateway 192.168.66.1 }
Invoke-Command -VMName HW31-SRV1 -Credential $LC -ScriptBlock { New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress "192.168.66.10" -PrefixLength 24 -DefaultGateway 192.168.66.1 ; Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses 192.168.66.2 }
Invoke-Command -VMName HW31-SRV2 -Credential $LC -ScriptBlock { New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress "192.168.66.11" -PrefixLength 24 -DefaultGateway 192.168.66.1 ; Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses 192.168.66.2 }

# Install AD DS + DNS on the DC
Invoke-Command -VMName HW31-DC -Credential $LC -ScriptBlock { Install-WindowsFeature AD-Domain-Services, DNS -IncludeManagementTools }
Invoke-Command -VMName HW31-DC -Credential $LC -ScriptBlock { Install-ADDSForest -CreateDnsDelegation:$false -DatabasePath "C:\Windows\NTDS" -DomainMode "WinThreshold" -DomainName $args[0] -ForestMode "WinThreshold" -InstallDns:$true -LogPath "C:\Windows\NTDS" -NoRebootOnCompletion:$false -SysvolPath "C:\Windows\SYSVOL" -Force:$true -SafeModeAdministratorPassword $args[1] } -ArgumentList $Domain, $Password

# Wait for the AD to be setup
pause

# Join other machines to the domain
Invoke-Command -VMName HW31-SRV1, HW31-SRV2 -Credential $LC -ScriptBlock { Add-Computer -DomainName $args[0] -Credential $args[1] -Restart } -ArgumentList $Domain, $DC

# Wait for the VMs to join to the domain
pause

# Add second NIC to both HW31-SRV1 and HW31-SRV2
Add-VMNetworkAdapter -VMName HW31-SRV1,HW31-SRV2 -SwitchName "Hyper-V Internal Switch" -Passthru | Set-VMNetworkAdapter -MacAddressSpoofing On

# Set the IP address for the second NICs
Invoke-Command -VMName HW31-SRV1 -Credential $DC -ScriptBlock { New-NetIPAddress -InterfaceAlias "Ethernet 2" -IPAddress "192.168.66.110" -PrefixLength 24 }
Invoke-Command -VMName HW31-SRV2 -Credential $DC -ScriptBlock { New-NetIPAddress -InterfaceAlias "Ethernet 2" -IPAddress "192.168.66.111" -PrefixLength 24 }
Invoke-Command -VMName HW31-SRV1, HW31-SRV2 -Credential $DC -ScriptBlock { Set-NetIPInterface -InterfaceAlias "Ethernet 2" -AddressFamily IPv4 -Forwarding Enabled }

# Install NLB feature + IIS Role on member VMs
Invoke-Command -VMName HW31-SRV1, HW31-SRV2 -Credential $DC -ScriptBlock { Install-WindowsFeature NLB, Web-Server -IncludeManagementTools }

# Set customized web pages on each NLB VM
Invoke-Command -VMName HW31-SRV1, HW31-SRV2 -Credential $DC -ScriptBlock { Set-Content -Path C:\inetpub\wwwroot\index.html -Value "<h1>Hello world!</h1><br /><br /><i>Served by $(hostname)</i>" -Force }

# Configure the NLB cluster
Invoke-Command -VMName HW31-SRV1 -Credential $DC -ScriptBlock { New-NlbCluster -InterfaceName "Ethernet 2" -OperationMode Unicast -ClusterPrimaryIP 192.168.66.100 -ClusterName NLBCluster }
Invoke-Command -VMName HW31-SRV1 -Credential $DC -ScriptBlock { Add-NlbClusterNode -InterfaceName "Ethernet 2" -NewNodeName "HW31-SRV2" -NewNodeInterface "Ethernet 2" }
Invoke-Command -VMName HW31-SRV1 -Credential $DC -ScriptBlock { Get-NlbClusterPortRule | Set-NlbClusterPortRule -NewProtocol Tcp -NewStartPort 80 -NewEndPort 80 -NewMode Multiple -NewAffinity None }

# Add a DNS record
Invoke-Command -VMName HW31-DC -Credential $DC -ScriptBlock { Add-DNSServerResourceRecordA -ZoneName WSAA.LAB -Name web -Ipv4Address 192.168.66.100 }

# Log on to the DC, open a browser and navigate to http://web.wsaa.lab and refresh a few times


#
# HW M3 P2 (WSFC)
#

# Set local credentials
$Password = ConvertTo-SecureString -AsPlainText "Password1" -Force
$LocalUser = "Administrator" 
$LC = New-Object System.Management.Automation.PSCredential($LocalUser, $Password)

# Set domain credentials
$Domain = "WSAA.LAB"
$DomainUser = "$Domain\Administrator" 
$DC = New-Object System.Management.Automation.PSCredential($DomainUser, $Password)

# Clone VHDs
cp 'C:\BAK\WIN-SRV-2K19-ST\VHD\WIN-SRV-2K19-ST.vhdx' C:\HV\HW32-DC.vhdx
cp 'C:\BAK\WIN-SRV-2K19-ST\VHD\WIN-SRV-2K19-ST.vhdx' C:\HV\HW32-SRV1.vhdx
cp 'C:\BAK\WIN-SRV-2K19-ST\VHD\WIN-SRV-2K19-ST.vhdx' C:\HV\HW32-SRV2.vhdx
cp 'C:\BAK\WIN-SRV-2K19-ST\VHD\WIN-SRV-2K19-ST.vhdx' C:\HV\HW32-SRV3.vhdx

# Create VMs (add -MemoryMaximumBytes to Set-VM)
New-VM -Name HW32-DC -MemoryStartupBytes 1536mb -VHDPath C:\HV\HW32-DC.vhdx -Generation 2 -SwitchName "Hyper-V Internal Switch" | Set-VM -CheckpointType Production -AutomaticCheckpointsEnabled $false
New-VM -Name HW32-SRV1 -MemoryStartupBytes 1536mb -VHDPath C:\HV\HW32-SRV1.vhdx -Generation 2 -SwitchName "Hyper-V Internal Switch" | Set-VM -CheckpointType Production -AutomaticCheckpointsEnabled $false
New-VM -Name HW32-SRV2 -MemoryStartupBytes 1536mb -VHDPath C:\HV\HW32-SRV2.vhdx -Generation 2 -SwitchName "Hyper-V Internal Switch" | Set-VM -CheckpointType Production -AutomaticCheckpointsEnabled $false
New-VM -Name HW32-SRV3 -MemoryStartupBytes 1536mb -VHDPath C:\HV\HW32-SRV3.vhdx -Generation 2 -SwitchName "Hyper-V Internal Switch" | Set-VM -CheckpointType Production -AutomaticCheckpointsEnabled $false

# Start VMs
Start-VM -Name HW32-DC, HW32-SRV1, HW32-SRV2, HW32-SRV3

# Ensure that the Administrator password  is set in each VM
pause

# Change OS name
Invoke-Command -VMName HW32-DC -Credential $LC -ScriptBlock { Rename-Computer -NewName HW32-DC -Restart  }
Invoke-Command -VMName HW32-SRV1 -Credential $LC -ScriptBlock { Rename-Computer -NewName HW32-SRV1 -Restart  }
Invoke-Command -VMName HW32-SRV2 -Credential $LC -ScriptBlock { Rename-Computer -NewName HW32-SRV2 -Restart  }
Invoke-Command -VMName HW32-SRV3 -Credential $LC -ScriptBlock { Rename-Computer -NewName HW32-SRV3 -Restart  }

# Set network settings for the first NIC on each VM
Invoke-Command -VMName HW32-DC -Credential $LC -ScriptBlock { New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress "192.168.66.2" -PrefixLength 24 -DefaultGateway 192.168.66.1 }
Invoke-Command -VMName HW32-SRV1 -Credential $LC -ScriptBlock { New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress "192.168.66.10" -PrefixLength 24 -DefaultGateway 192.168.66.1 ; Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses 192.168.66.2 }
Invoke-Command -VMName HW32-SRV2 -Credential $LC -ScriptBlock { New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress "192.168.66.11" -PrefixLength 24 -DefaultGateway 192.168.66.1 ; Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses 192.168.66.2 }
Invoke-Command -VMName HW32-SRV3 -Credential $LC -ScriptBlock { New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress "192.168.66.12" -PrefixLength 24 -DefaultGateway 192.168.66.1 ; Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses 192.168.66.2 }

# Install AD DS + DNS on the DC
Invoke-Command -VMName HW32-DC -Credential $LC -ScriptBlock { Install-WindowsFeature AD-Domain-Services, DNS -IncludeManagementTools }
Invoke-Command -VMName HW32-DC -Credential $LC -ScriptBlock { Install-ADDSForest -CreateDnsDelegation:$false -DatabasePath "C:\Windows\NTDS" -DomainMode "WinThreshold" -DomainName $args[0] -ForestMode "WinThreshold" -InstallDns:$true -LogPath "C:\Windows\NTDS" -NoRebootOnCompletion:$false -SysvolPath "C:\Windows\SYSVOL" -Force:$true -SafeModeAdministratorPassword $args[1] } -ArgumentList $Domain, $Password

# Wait for the AD to be setup
pause

# Join other machines to the domain
Invoke-Command -VMName HW32-SRV1, HW32-SRV2, HW32-SRV3 -Credential $LC -ScriptBlock { Add-Computer -DomainName $args[0] -Credential $args[1] -Restart } -ArgumentList $Domain, $DC

# Wait for the VMs to join to the domain
pause

# Add second NIC for storage to all VMs
Add-VMNetworkAdapter -VMName HW32-DC, HW32-SRV1, HW32-SRV2, HW32-SRV3 -SwitchName "Storage"

# Add third NIC for cluster communication to all member servers
Add-VMNetworkAdapter -VMName HW32-SRV1, HW32-SRV2, HW32-SRV3 -SwitchName "Private"

# Set the IP address for the second NICs
Invoke-Command -VMName HW32-DC -Credential $DC -ScriptBlock { Rename-NetAdapter -Name "Ethernet 2" -NewName "Storage" ; New-NetIPAddress -InterfaceAlias "Storage" -IPAddress "192.168.67.2" -PrefixLength 24 }
Invoke-Command -VMName HW32-SRV1 -Credential $DC -ScriptBlock { Rename-NetAdapter -Name "Ethernet 2" -NewName "Storage" ; New-NetIPAddress -InterfaceAlias "Storage" -IPAddress "192.168.67.10" -PrefixLength 24 }
Invoke-Command -VMName HW32-SRV2 -Credential $DC -ScriptBlock { Rename-NetAdapter -Name "Ethernet 2" -NewName "Storage" ; New-NetIPAddress -InterfaceAlias "Storage" -IPAddress "192.168.67.11" -PrefixLength 24 }
Invoke-Command -VMName HW32-SRV3 -Credential $DC -ScriptBlock { Rename-NetAdapter -Name "Ethernet 2" -NewName "Storage" ; New-NetIPAddress -InterfaceAlias "Storage" -IPAddress "192.168.67.12" -PrefixLength 24 }

# Set the IP address for the third NICs
Invoke-Command -VMName HW32-SRV1 -Credential $DC -ScriptBlock { Rename-NetAdapter -Name "Ethernet 3" -NewName "Private" ; New-NetIPAddress -InterfaceAlias "Private" -IPAddress "192.168.68.10" -PrefixLength 24 }
Invoke-Command -VMName HW32-SRV2 -Credential $DC -ScriptBlock { Rename-NetAdapter -Name "Ethernet 3" -NewName "Private" ; New-NetIPAddress -InterfaceAlias "Private" -IPAddress "192.168.68.11" -PrefixLength 24 }
Invoke-Command -VMName HW32-SRV3 -Credential $DC -ScriptBlock { Rename-NetAdapter -Name "Ethernet 3" -NewName "Private" ; New-NetIPAddress -InterfaceAlias "Private" -IPAddress "192.168.68.12" -PrefixLength 24 }

# Install iSCSI Target
Invoke-Command -VMName HW32-DC -Credential $DC -ScriptBlock { Install-WindowsFeature FS-iSCSITarget-Server }

# Create iSCSI virtual hard disk (quorum)
Invoke-Command -VMName HW32-DC -Credential $DC -ScriptBlock { New-IscsiVirtualDisk -Path "C:\iscsi-disk-quorum.vhdx" -Size 1GB }

# Create iSCSI target (quorum)
Invoke-Command -VMName HW32-DC -Credential $DC -ScriptBlock { New-IscsiServerTarget -TargetName "quorum" -InitiatorId @("IPAddress:192.168.67.10", "IPAddress:192.168.67.11", "IPAddress:192.168.67.12") }

# Attach iSCSI virtual hard disk to an iSCSI target (quorum)
Invoke-Command -VMName HW32-DC -Credential $DC -ScriptBlock { Add-IscsiVirtualDiskTargetMapping -TargetName "quorum" -DevicePath "C:\iscsi-disk-quorum.vhdx" }

# Create iSCSI virtual hard disk (storage)
Invoke-Command -VMName HW32-DC -Credential $DC -ScriptBlock { New-IscsiVirtualDisk -Path "C:\iscsi-disk-storage.vhdx" -Size 5GB }

# Create iSCSI target (storage)
Invoke-Command -VMName HW32-DC -Credential $DC -ScriptBlock { New-IscsiServerTarget -TargetName "storage" -InitiatorId @("IPAddress:192.168.67.10", "IPAddress:192.168.67.11", "IPAddress:192.168.67.12") }

# Attach iSCSI virtual hard disk to an iSCSI target (storage)
Invoke-Command -VMName HW32-DC -Credential $DC -ScriptBlock { Add-IscsiVirtualDiskTargetMapping -TargetName "storage" -DevicePath "C:\iscsi-disk-storage.vhdx" }

# Start iSCSI Initiator service on all member VMs
Invoke-Command -VMName HW32-SRV1, HW32-SRV2, HW32-SRV3 -Credential $DC -ScriptBlock { Start-Service msiscsi ; Set-Service msiscsi -StartupType Automatic }

# Work out iSCSI targets on member #1
# Create new iSCSI target portal
Invoke-Command -VMName HW32-SRV1 -Credential $DC -ScriptBlock { New-IscsiTargetPortal -TargetPortalAddress "192.168.67.2" -InitiatorPortalAddress "192.168.67.10" -InitiatorInstanceName "ROOT\ISCSIPRT\0000_0" }

# Connect to an iSCSI target
Invoke-Command -VMName HW32-SRV1 -Credential $DC -ScriptBlock { Get-IscsiTarget | foreach { Connect-IscsiTarget -NodeAddress $_.NodeAddress -TargetPortalAddress "192.168.67.2" -InitiatorPortalAddress "192.168.67.10" -IsPersistent $true } }

# Initialize and format the disks
Invoke-Command -VMName HW32-SRV1 -Credential $DC -ScriptBlock { Initialize-Disk -Number 1 -PartitionStyle GPT ; New-Volume -DiskNumber 1 -FriendlyName "iSCSIDiskQuorum" -FileSystem NTFS -DriveLetter Q }
Invoke-Command -VMName HW32-SRV1 -Credential $DC -ScriptBlock { Initialize-Disk -Number 2 -PartitionStyle GPT ; New-Volume -DiskNumber 2 -FriendlyName "iSCSIDiskStorage" -FileSystem NTFS -DriveLetter S }

# Work out iSCSI targets on member #2
# Create new iSCSI target portal
Invoke-Command -VMName HW32-SRV2 -Credential $DC -ScriptBlock { New-IscsiTargetPortal -TargetPortalAddress "192.168.67.2" -InitiatorPortalAddress "192.168.67.11" -InitiatorInstanceName "ROOT\ISCSIPRT\0000_0" }

# Connect to an iSCSI target
Invoke-Command -VMName HW32-SRV2 -Credential $DC -ScriptBlock { Get-IscsiTarget | foreach { Connect-IscsiTarget -NodeAddress $_.NodeAddress -TargetPortalAddress "192.168.67.2" -InitiatorPortalAddress "192.168.67.11" -IsPersistent $true } }

# Work out iSCSI targets on member #3
# Create new iSCSI target portal
Invoke-Command -VMName HW32-SRV3 -Credential $DC -ScriptBlock { New-IscsiTargetPortal -TargetPortalAddress "192.168.67.2" -InitiatorPortalAddress "192.168.67.12" -InitiatorInstanceName "ROOT\ISCSIPRT\0000_0" }

# Connect to an iSCSI target
Invoke-Command -VMName HW32-SRV3 -Credential $DC -ScriptBlock { Get-IscsiTarget | foreach { Connect-IscsiTarget -NodeAddress $_.NodeAddress -TargetPortalAddress "192.168.67.2" -InitiatorPortalAddress "192.168.67.12" -IsPersistent $true } }

# Install failover role + file server role on all member VMs
Invoke-Command -VMName HW32-SRV1, HW32-SRV2, HW32-SRV3 -Credential $DC -ScriptBlock { Install-WindowsFeature FS-FileServer, Failover-Clustering -IncludeManagementTools -Restart }

# Wait for all member servers to reboot
pause

# Test cluster - optional step
# Invoke-Command -VMName HW32-SRV1 -Credential $DC -ScriptBlock { Test-Cluster -Node HW32-SRV1, HW32-SRV2, HW32-SRV3 }

# Create the cluster
Invoke-Command -VMName HW32-SRV1 -Credential $DC -ScriptBlock { New-Cluster -Name ClusterHW -Node HW32-SRV1, HW32-SRV2, HW32-SRV3 -StaticAddress 192.168.66.33 -NoStorage }

# Add quorum disk
Invoke-Command -VMName HW32-SRV1 -Credential $DC -ScriptBlock { $DQ = Get-ClusterAvailableDisk | Where -Property Size -Eq 1GB ; $DQ | Add-ClusterDisk ; Set-ClusterQuorum -DiskWitness $DQ.Name }

# Add shared volume to the cluster
Invoke-Command -VMName HW32-SRV1 -Credential $DC -ScriptBlock { $DS = Get-ClusterAvailableDisk | Where -Property Size -Eq 5GB ; $DS | Add-ClusterDisk ; Add-ClusterSharedVolume $DS.Name }

# Add scale out file server role
Invoke-Command -VMName HW32-SRV1 -Credential $DC -ScriptBlock { Add-ClusterScaleOutFileServerRole }

# Prepare and share the folder
Invoke-Command -VMName HW32-SRV1 -Credential $DC -ScriptBlock { New-Item -Path C:\ClusterStorage\Volume1\Shares\DATA -Type Directory -Force }
Invoke-Command -VMName HW32-SRV1 -Credential $DC -ScriptBlock { New-SmbShare -Name "DATA" -Path "C:\ClusterStorage\Volume1\Shares\DATA" -FullAccess Everyone }

# Log on to the HW32-SRV1 machine, open Failover Cluster Manager and examine the result


#
# HW M3 P3 (Docker)
#

# Set local credentials
$Password = ConvertTo-SecureString -AsPlainText "Password1" -Force
$LocalUser = "Administrator" 
$LC = New-Object System.Management.Automation.PSCredential($LocalUser, $Password)

# Set domain credentials
$Domain = "WSAA.LAB"
$DomainUser = "$Domain\Administrator" 
$DC = New-Object System.Management.Automation.PSCredential($DomainUser, $Password)

# Clone VHDs
cp 'C:\BAK\WIN-SRV-2K19-ST\VHD\WIN-SRV-2K19-ST.vhdx' C:\HV\HW33-DC.vhdx
cp 'C:\BAK\WIN-SRV-2K19-ST\VHD\WIN-SRV-2K19-ST.vhdx' C:\HV\HW33-SRV1.vhdx
cp 'C:\BAK\WIN-SRV-2K19-ST\VHD\WIN-SRV-2K19-ST.vhdx' C:\HV\HW33-SRV2.vhdx

# Create VMs (add -MemoryMaximumBytes to Set-VM)
New-VM -Name HW33-DC -MemoryStartupBytes 1536mb -VHDPath C:\HV\HW33-DC.vhdx -Generation 2 -SwitchName "Hyper-V Internal Switch" | Set-VM -CheckpointType Production -AutomaticCheckpointsEnabled $false
New-VM -Name HW33-SRV1 -MemoryStartupBytes 3072mb -VHDPath C:\HV\HW33-SRV1.vhdx -Generation 2 -SwitchName "Hyper-V Internal Switch" | Set-VM -CheckpointType Production -AutomaticCheckpointsEnabled $false
New-VM -Name HW33-SRV2 -MemoryStartupBytes 3072mb -VHDPath C:\HV\HW33-SRV2.vhdx -Generation 2 -SwitchName "Hyper-V Internal Switch" | Set-VM -CheckpointType Production -AutomaticCheckpointsEnabled $false

# Prepare member VMs for nested virtualization
Set-VMMemory -VMName HW33-SRV1, HW33-SRV2 -DynamicMemoryEnabled $false 
Set-VMProcessor -VMName HW33-SRV1, HW33-SRV2 -ExposeVirtualizationExtensions $true
Get-VMNetworkAdapter -VMName HW33-SRV1, HW33-SRV2 | Set-VMNetworkAdapter -MacAddressSpoofing On

# Start VMs
Start-VM -Name HW33-DC, HW33-SRV1, HW33-SRV2

# Ensure that the Administrator password (Password1) is set in each VM
pause

# Change OS name
Invoke-Command -VMName HW33-DC -Credential $LC -ScriptBlock { Rename-Computer -NewName HW33-DC -Restart  }
Invoke-Command -VMName HW33-SRV1 -Credential $LC -ScriptBlock { Rename-Computer -NewName HW33-SRV1 -Restart  }
Invoke-Command -VMName HW33-SRV2 -Credential $LC -ScriptBlock { Rename-Computer -NewName HW33-SRV2 -Restart  }

# Set network settings for the first NIC on each VM
Invoke-Command -VMName HW33-DC -Credential $LC -ScriptBlock { New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress "192.168.66.2" -PrefixLength 24 -DefaultGateway 192.168.66.1 }
Invoke-Command -VMName HW33-SRV1 -Credential $LC -ScriptBlock { New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress "192.168.66.10" -PrefixLength 24 -DefaultGateway 192.168.66.1 ; Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses 192.168.66.2 }
Invoke-Command -VMName HW33-SRV2 -Credential $LC -ScriptBlock { New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress "192.168.66.11" -PrefixLength 24 -DefaultGateway 192.168.66.1 ; Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses 192.168.66.2 }

# Install AD DS + DNS on the DC
Invoke-Command -VMName HW33-DC -Credential $LC -ScriptBlock { Install-WindowsFeature AD-Domain-Services, DNS -IncludeManagementTools }
Invoke-Command -VMName HW33-DC -Credential $LC -ScriptBlock { Install-ADDSForest -CreateDnsDelegation:$false -DatabasePath "C:\Windows\NTDS" -DomainMode "WinThreshold" -DomainName $args[0] -ForestMode "WinThreshold" -InstallDns:$true -LogPath "C:\Windows\NTDS" -NoRebootOnCompletion:$false -SysvolPath "C:\Windows\SYSVOL" -Force:$true -SafeModeAdministratorPassword $args[1] } -ArgumentList $Domain, $Password

# Wait for the AD to be setup
pause

# Add a DNS forwarder in DC
Invoke-Command -VMName HW33-DC -Credential $DC -ScriptBlock { Add-DnsServerForwarder -IPAddress 8.8.8.8 }

# Join other machines to the domain
Invoke-Command -VMName HW33-SRV1, HW33-SRV2 -Credential $LC -ScriptBlock { Add-Computer -DomainName $args[0] -Credential $args[1] -Restart } -ArgumentList $Domain, $DC

# Wait for the VMs to join to the domain
pause

# Role installation
Invoke-Command -VMName HW33-SRV1, HW33-SRV2 -Credential $DC -ScriptBlock { Install-WindowsFeature -Name Containers, FS-FileServer, Hyper-V -IncludeManagementTools -Restart }

# Wait for the roles to be installed on the VMs
pause

# Install Docker Provider
Invoke-Command -VMName HW33-SRV1, HW33-SRV2 -Credential $DC -ScriptBlock { Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force ; Install-Module -Name DockerMsftProvider -Repository PSGallery -Force }

# Install Docker
Invoke-Command -VMName HW33-SRV1, HW33-SRV2 -Credential $DC -ScriptBlock { Install-Package -Name Docker -ProviderName DockerMsftProvider -Force }

# Ensure the Docker service is started
Invoke-Command -VMName HW33-SRV1, HW33-SRV2 -Credential $DC -ScriptBlock { Start-Service docker }

# Add set of firewall rules to enable correct communication between nodes
Invoke-Command -VMName HW33-SRV1, HW33-SRV2 -Credential $DC -ScriptBlock { New-NetFirewallRule -DisplayName "Docker Port 2376/tcp" -Direction Inbound -LocalPort 2376 -Protocol TCP -Action Allow }
Invoke-Command -VMName HW33-SRV1, HW33-SRV2 -Credential $DC -ScriptBlock { New-NetFirewallRule -DisplayName "Docker Port 2377/tcp" -Direction Inbound -LocalPort 2377 -Protocol TCP -Action Allow }
Invoke-Command -VMName HW33-SRV1, HW33-SRV2 -Credential $DC -ScriptBlock { New-NetFirewallRule -DisplayName "Docker Port 4789/udp" -Direction Inbound -LocalPort 4789 -Protocol UDP -Action Allow }
Invoke-Command -VMName HW33-SRV1, HW33-SRV2 -Credential $DC -ScriptBlock { New-NetFirewallRule -DisplayName "Docker Port 7946/tcp" -Direction Inbound -LocalPort 7946 -Protocol TCP -Action Allow }
Invoke-Command -VMName HW33-SRV1, HW33-SRV2 -Credential $DC -ScriptBlock { New-NetFirewallRule -DisplayName "Docker Port 7946/udp" -Direction Inbound -LocalPort 7946 -Protocol UDP -Action Allow }

# Initialize the Swarm on node #1 (HW33-SRV1)
Invoke-Command -VMName HW33-SRV1 -Credential $DC -ScriptBlock { docker swarm init --advertise-addr 192.168.66.10 ; docker swarm join-token -q worker > c:\swarm-token.txt }

# Join node #2 (HW33-SRV2) to the Swarm
Invoke-Command -VMName HW33-SRV2 -Credential $DC -ScriptBlock { docker swarm join --token $(type \\HW33-SRV1\c$\swarm-token.txt) 192.168.66.10:2377 }

# Check the status of the Swarm
Invoke-Command -VMName HW33-SRV1 -Credential $DC -ScriptBlock { docker node ls }