#############################
### Run from Hyper-V Host ###
#############################

#run from Host to expand C: drives in VMs to 120GB. This is required as Install-AKSHCI checks free space on C (should check free space in CSV)
$VMs=Get-VM -VMName WSLab*azshci*
$VMs | Get-VMHardDiskDrive -ControllerLocation 0 | Resize-VHD -SizeBytes 120GB
#VM Credentials
$secpasswd = ConvertTo-SecureString "LS1setup!" -AsPlainText -Force
$VMCreds = New-Object System.Management.Automation.PSCredential ("corp\LabAdmin", $secpasswd)
Foreach ($VM in $VMs){
    Invoke-Command -VMname $vm.name -Credential $VMCreds -ScriptBlock {
        $part=Get-Partition -DriveLetter c
        $sizemax=($part |Get-PartitionSupportedSize).SizeMax
        $part | Resize-Partition -Size $sizemax
    }
}

###################
### Run from DC ###
###################

#region Create 2 node cluster (just simple. Not for prod - follow hyperconverged scenario for real clusters https://github.com/microsoft/WSLab/tree/master/Scenarios/S2D%20Hyperconverged)
# LabConfig
$Servers="AzsHCI1","AzSHCI2"
$ClusterName="AzSHCI-Cluster"

# Install features for management on server
Install-WindowsFeature -Name RSAT-Clustering,RSAT-Clustering-Mgmt,RSAT-Clustering-PowerShell,RSAT-Hyper-V-Tools

# Update servers
Invoke-Command -ComputerName $servers -ScriptBlock {
    #Grab updates
    $ScanResult=Invoke-CimMethod -Namespace "root/Microsoft/Windows/WindowsUpdate" -ClassName "MSFT_WUOperations" -MethodName ScanForUpdates -Arguments @{SearchCriteria="IsInstalled=0"}
    #apply updates (if not empty)
    if ($ScanResult.Updates){
        Invoke-CimMethod -Namespace "root/Microsoft/Windows/WindowsUpdate" -ClassName "MSFT_WUOperations" -MethodName InstallUpdates -Arguments @{Updates=$ScanResult.Updates}
    }
}

# Check if restart is required and reboot
$ServersToReboot=($result | Where-Object PendingReboot -eq $true).PSComputerName
if ($ServersToReboot){
    Restart-Computer -ComputerName $ServersToReboot -Protocol WSMan -Wait -For PowerShell
    #failsafe - sometimes it evaluates, that servers completed restart after first restart (hyper-v needs 2)
    Start-sleep 20
}

# Install features on servers
Invoke-Command -computername $Servers -ScriptBlock {
    Enable-WindowsOptionalFeature -FeatureName Microsoft-Hyper-V -Online -NoRestart 
    Install-WindowsFeature -Name "Failover-Clustering","RSAT-Clustering-Powershell","Hyper-V-PowerShell"
}

# restart servers
Restart-Computer -ComputerName $servers -Protocol WSMan -Wait -For PowerShell
#failsafe - sometimes it evaluates, that servers completed restart after first restart (hyper-v needs 2)
Start-sleep 20

# create vSwitch
Invoke-Command -ComputerName $servers -ScriptBlock {New-VMSwitch -Name vSwitch -EnableEmbeddedTeaming $TRUE -NetAdapterName (Get-NetIPAddress -IPAddress 10.* ).InterfaceAlias}

#create cluster
New-Cluster -Name $ClusterName -Node $Servers
Start-Sleep 5
Clear-DNSClientCache

#add file share witness
#Create new directory
    $WitnessName=$ClusterName+"Witness"
    Invoke-Command -ComputerName DC -ScriptBlock {new-item -Path c:\Shares -Name $using:WitnessName -ItemType Directory}
    $accounts=@()
    $accounts+="corp\$($ClusterName)$"
    $accounts+="corp\Domain Admins"
    New-SmbShare -Name $WitnessName -Path "c:\Shares\$WitnessName" -FullAccess $accounts -CimSession DC
#Set NTFS permissions
    Invoke-Command -ComputerName DC -ScriptBlock {(Get-SmbShare $using:WitnessName).PresetPathAcl | Set-Acl}
#Set Quorum
    Set-ClusterQuorum -Cluster $ClusterName -FileShareWitness "\\DC\$WitnessName"

#Enable S2D
Enable-ClusterS2D -CimSession $ClusterName -Verbose -Confirm:0
#endregion

#region Download AKS HCI module
$ProgressPreference='SilentlyContinue' #for faster download
Invoke-WebRequest -Uri "https://aka.ms/aks-hci-download" -UseBasicParsing -OutFile "$env:USERPROFILE\Downloads\AKS-HCI-Public-Preview-Oct-2020.zip"
$ProgressPreference='Continue' #return progress preference back
#unzip
Expand-Archive -Path "$env:USERPROFILE\Downloads\AKS-HCI-Public-Preview-Oct-2020.zip" -DestinationPath "$env:USERPROFILE\Downloads" -Force
Expand-Archive -Path "$env:USERPROFILE\Downloads\AksHci.Powershell.zip" -DestinationPath "$env:USERPROFILE\Downloads\AksHci.Powershell" -Force

#endregion

#region setup AKS (PowerShell)
    #Copy PowerShell module to nodes
    $ClusterName="AzSHCI-Cluster"
    $vSwitchName="vSwitch"
    $VolumeName="AKS"
    $Servers=(Get-ClusterNode -Cluster $ClusterName).Name

    #Copy module to nodes
    $PSSessions=New-PSSession -ComputerName $Servers
    foreach ($PSSession in $PSSessions){
        $Folders=Get-ChildItem -Path $env:USERPROFILE\Downloads\AksHci.Powershell\ 
        foreach ($Folder in $Folders){
            Copy-Item -Path $folder.FullName -Destination $env:ProgramFiles\windowspowershell\modules -ToSession $PSSession -Recurse -Force
        }
    }


    #why this does not work? Why I need to login ot server to run initialize AKSHCINode???
    <#Invoke-Command -ComputerName $servers -ScriptBlock {
        Initialize-AksHciNode
    }#>

    #Enable CredSSP
    # Temporarily enable CredSSP delegation to avoid double-hop issue
    foreach ($Server in $servers){
        Enable-WSManCredSSP -Role "Client" -DelegateComputer $Server -Force
    }
    Invoke-Command -ComputerName $servers -ScriptBlock { Enable-WSManCredSSP Server -Force }

    $password = ConvertTo-SecureString "LS1setup!" -AsPlainText -Force
    $Credentials = New-Object System.Management.Automation.PSCredential ("CORP\LabAdmin", $password)

    Invoke-Command -ComputerName $servers -Credential $Credentials -Authentication Credssp -ScriptBlock {
        Initialize-AksHciNode
    }

    #Create  volume for AKS
    New-Volume -FriendlyName $VolumeName -CimSession $ClusterName -Size 1TB -StoragePoolFriendlyName S2D*
    #make sure failover clustering management tools are installed on nodes
    Invoke-Command -ComputerName $servers -ScriptBlock {
        Install-WindowsFeature -Name RSAT-Clustering-PowerShell
    }
    #configure aks
    Invoke-Command -ComputerName $servers[0] -ScriptBlock {
        Set-AksHciConfig -vnetName $using:vSwitchName -deploymentType MultiNode -wssdDir c:\clusterstorage\$using:VolumeName\Images -wssdImageDir c:\clusterstorage\$using:VolumeName\Images -cloudConfigLocation c:\clusterstorage\$using:VolumeName\Config -ClusterRoleName "$($using:ClusterName)_AKS"
    }

    #validate config
    Invoke-Command -ComputerName $servers[0] -ScriptBlock {
        Get-AksHciConfig
    }

    #note: this step might need to run twice. As for first time it times out on https://github.com/Azure/aks-hci/issues/28 . Before second attempt, unistall-akshci first and set config again
    Invoke-Command -ComputerName $servers[0] -Credential $Credentials -Authentication Credssp -ScriptBlock {
        #Uninstall-AksHCI
        #Set-AksHciConfig -vnetName $using:vSwitchName -deploymentType MultiNode -wssdDir c:\clusterstorage\$using:VolumeName\Images -wssdImageDir c:\clusterstorage\$using:VolumeName\Images -cloudConfigLocation c:\clusterstorage\$using:VolumeName\Config -ClusterRoleName "$($using:ClusterName)_AKS"
        Install-AksHci
    }

    # Disable CredSSP
    Disable-WSManCredSSP -Role Client
    Invoke-Command -ComputerName $servers -ScriptBlock { Disable-WSManCredSSP Server }
#endregion

#region create AKS HCI cluster
$ClusterName="AzSHCI-Cluster"
Invoke-Command -ComputerName $ClusterName -ScriptBlock {
    New-AksHciCluster -clusterName demo -linuxNodeCount 1 -linuxNodeVmSize Standard_A2_v2 -controlplaneVmSize Standard_A2_v2 -loadBalancerVmSize Standard_A2_v2 #smallest possible VMs
}
#VM Sizes
<#
$global:vmSizeDefinitions =
@(
    # Name, CPU, MemoryGB
    ([VmSize]::Default, "4", "4"),
    ([VmSize]::Standard_A2_v2, "2", "4"),
    ([VmSize]::Standard_A4_v2, "4", "8"),
    ([VmSize]::Standard_D2s_v3, "2", "8"),
    ([VmSize]::Standard_D4s_v3, "4", "16"),
    ([VmSize]::Standard_D8s_v3, "8", "32"),
    ([VmSize]::Standard_D16s_v3, "16", "64"),
    ([VmSize]::Standard_D32s_v3, "32", "128"),
    ([VmSize]::Standard_DS2_v2, "2", "7"),
    ([VmSize]::Standard_DS3_v2, "2", "14"),
    ([VmSize]::Standard_DS4_v2, "8", "28"),
    ([VmSize]::Standard_DS5_v2, "16", "56"),
    ([VmSize]::Standard_DS13_v2, "8", "56"),
    ([VmSize]::Standard_K8S_v1, "4", "2"),
    ([VmSize]::Standard_K8S2_v1, "2", "2"),
    ([VmSize]::Standard_K8S3_v1, "4", "6"),
    ([VmSize]::Standard_NK6, "6", "12"),
    ([VmSize]::Standard_NV6, "6", "64"),
    ([VmSize]::Standard_NV12, "12", "128")

)
#>
#endregion

#region onboard cluster to Azure ARC
$ClusterName="AzSHCI-Cluster"

#download Azure module
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
if (!(Get-InstalledModule -Name Az.StackHCI -ErrorAction Ignore)){
    Install-Module -Name Az.StackHCI -Force
}

#login to azure
#download Azure module
if (!(Get-InstalledModule -Name az.accounts -ErrorAction Ignore)){
    Install-Module -Name Az.Accounts -Force
}
Login-AzAccount -UseDeviceAuthentication

#select context if more available
$context=Get-AzContext -ListAvailable
if (($context).count -gt 1){
    $context | Out-GridView -OutputMode Single | Set-AzContext
}

#select subscription
$subscriptions=Get-AzSubscription
if (($subscriptions).count -gt 1){
    $subscriptions | Out-GridView -OutputMode Single | Select-AzSubscription
}

$subscriptionID=(Get-AzSubscription).ID

#register Azure Stack HCI
#add some trusted sites (to be able to authenticate with Register-AzStackHCI)
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\EscDomains\live.com\login" /v https /t REG_DWORD /d 2
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\EscDomains\microsoftonline.com\login" /v https /t REG_DWORD /d 2
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\EscDomains\msauth.net\aadcdn" /v https /t REG_DWORD /d 2
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\EscDomains\msauth.net\logincdn" /v https /t REG_DWORD /d 2
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\EscDomains\msftauth.net\aadcdn" /v https /t REG_DWORD /d 2
#and register
Register-AzStackHCI -SubscriptionID $subscriptionID -ComputerName $ClusterName


#or more complex
<#
#grab location
if (!(Get-InstalledModule -Name Az.Resources -ErrorAction Ignore)){
    Install-Module -Name Az.Resources -Force
}
$Location=Get-AzLocation | Where-Object Providers -Contains "Microsoft.AzureStackHCI" | Out-GridView -OutputMode Single
Register-AzStackHCI -SubscriptionID $subscriptionID -Region $location.location -ComputerName $ClusterName
#>

#Install Azure Stack HCI RSAT Tools to all nodes
$Servers=(Get-ClusterNode -Cluster $ClusterName).Name
Invoke-Command -ComputerName $Servers -ScriptBlock {
    Install-WindowsFeature -Name RSAT-Azure-Stack-HCI
}

#Validate registration (query on just one node is needed)
Invoke-Command -ComputerName $ClusterName -ScriptBlock {
    Get-AzureStackHCI
}

#register AKS
#https://docs.microsoft.com/en-us/azure-stack/aks-hci/connect-to-arc

if (!(Get-InstalledModule -Name Az.Resources -ErrorAction Ignore)){
    Install-Module -Name Az.Resources -Force
}
if (!(Get-Azcontext)){
    Login-AzAccount -UseDeviceAuthentication
}
$tenantID=(Get-AzContext).Tenant.Id
$subscriptionID=(Get-AzSubscription).ID
$resourcegroup="$ClusterName-rg"
$location="westeurope"
$AKSClusterName="demo"

#create new service principal for cluster demo
#Connect-AzAccount -Tenant $tenantID
$servicePrincipalDisplayName="$($ClusterName)_AKS_$AKSClusterName"
$sp = New-AzADServicePrincipal -DisplayName $servicePrincipalDisplayName -Scope  "/subscriptions/$subscriptionID/resourceGroups/$resourcegroup"
$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sp.Secret)
$UnsecureSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
$ClientID=$sp.ApplicationId

#register namespace Microsoft.KubernetesConfiguration and Microsoft.Kubernetes
Register-AzResourceProvider -ProviderNamespace Microsoft.Kubernetes
Register-AzResourceProvider -ProviderNamespace Microsoft.KubernetesConfiguration

#onboard cluster
Invoke-Command -ComputerName $ClusterName -ScriptBlock {
    #generage kubeconfig first
    Get-AksHciCredential -clusterName demo
    #onboard
    Install-AksHciArcOnboarding -clusterName $using:AKSClusterName -tenantId $using:tenantID -subscriptionId $using:subscriptionID -resourcegroup $using:resourcegroup -Location $using:location -clientId $using:ClientID -clientSecret $using:UnsecureSecret
}

#check onboarding
#generate kubeconfig (this step was already done)
<#
Invoke-Command -ComputerName $ClusterName -ScriptBlock {
    Get-AksHciCredential -clusterName demo
}
#>
#copy kubeconfig
$session=New-PSSession -ComputerName $ClusterName
Copy-Item -Path "$env:userprofile\.kube" -Destination $env:userprofile -FromSession $session -Recurse
#copy kubectl
Copy-Item -Path $env:ProgramFiles\AksHCI\ -Destination $env:ProgramFiles -FromSession $session -Recurse
#validate onboarding
& "c:\Program Files\AksHci\kubectl.exe" logs job/azure-arc-onboarding -n azure-arc-onboarding --follow

#endregion

#region cleanup
Get-AzResourceGroup -Name "$ClusterName-rg" | Remove-AzResourceGroup #-Force
$principals=Get-AzADServicePrincipal -DisplayNameBeginsWith $ClusterName
foreach ($principal in $principals){
    Remove-AzADServicePrincipal -ObjectId $principal.id #-Force
}
Get-AzADApplication -DisplayNameStartWith $ClusterName | Remove-AzADApplication
#endregion

#TBD: Create sample application
#https://techcommunity.microsoft.com/t5/azure-stack-blog/azure-kubernetes-service-on-azure-stack-hci-deliver-storage/ba-p/1703996
#TBD: Enable monitoring
#https://docs.microsoft.com/en-us/azure/azure-monitor/insights/container-insights-enable-arc-enabled-clusters

######################################
# following code is work-in-progress #
######################################

######################
### Run from Win10 ###
######################

#region Windows Admin Center on Win10

    #install WAC
    #Download Windows Admin Center if not present
    if (-not (Test-Path -Path "$env:USERPROFILE\Downloads\WindowsAdminCenter.msi")){
        $ProgressPreference='SilentlyContinue' #for faster download
        Invoke-WebRequest -UseBasicParsing -Uri https://aka.ms/WACDownload -OutFile "$env:USERPROFILE\Downloads\WindowsAdminCenter.msi"
        $ProgressPreference='Continue' #return progress preference back
    }
    #Install Windows Admin Center (https://docs.microsoft.com/en-us/windows-server/manage/windows-admin-center/deploy/install)
    Start-Process msiexec.exe -Wait -ArgumentList "/i $env:USERPROFILE\Downloads\WindowsAdminCenter.msi /qn /L*v log.txt SME_PORT=6516 SSL_CERTIFICATE_OPTION=generate"
    #Open Windows Admin Center
    Start-Process "C:\Program Files\Windows Admin Center\SmeDesktop.exe"

#endregion

#region setup AKS (win10)
    #import wac module
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process -Force
    Import-Module "$env:ProgramFiles\windows admin center\PowerShell\Modules\ExtensionTools"
    # List feeds
    Get-Feed "https://localhost:6516/"


    #add feed
    #download nupgk (included in aks-hci module)
    $ProgressPreference='SilentlyContinue' #for faster download
    Invoke-WebRequest -Uri "https://aka.ms/aks-hci-download" -UseBasicParsing -OutFile "$env:USERPROFILE\Downloads\AKS-HCI-Public-Preview-Oct-2020.zip"
    $ProgressPreference='Continue' #return progress preference back
    #unzip
    Expand-Archive -Path "$env:USERPROFILE\Downloads\AKS-HCI-Public-Preview-Oct-2020.zip" -DestinationPath "$env:USERPROFILE\Downloads" -Force
    Expand-Archive -Path "$env:USERPROFILE\Downloads\AksHci.Powershell.zip" -DestinationPath "$env:USERPROFILE\Downloads\AksHci.Powershell" -Force
    $Filename=Get-ChildItem -Path $env:userprofile\downloads\ | Where-Object Name -like "msft.sme.aks.*.nupkg"
    New-Item -Path "C:\WACFeeds\" -Name Feeds -ItemType Directory -Force
    Copy-Item -Path $FileName.FullName -Destination "C:\WACFeeds\"
    Add-Feed -GatewayEndpoint "https://localhost:6516/" -Feed "C:\WACFeeds\"

    # List Kubernetes extensions (you need to log into WAC in Edge for this command to succeed)
    Get-Extension "https://localhost:6516/" | where title -like *kubernetes*

    # Install Kubernetes Extension
    $extension=Get-Extension "https://localhost:6516/" | where title -like *kubernetes*
    Install-Extension -ExtensionId $extension.id

#endregion

###################
### Run from DC ###
###################

#region Windows Admin Center on GW

#Install Edge
$ProgressPreference='SilentlyContinue' #for faster download
Invoke-WebRequest -Uri "https://aka.ms/edge-msi" -UseBasicParsing -OutFile "$env:USERPROFILE\Downloads\MicrosoftEdgeEnterpriseX64.msi"
$ProgressPreference='Continue' #return progress preference back
#start install
Start-Process -Wait -Filepath msiexec.exe -Argumentlist "/i $env:UserProfile\Downloads\MicrosoftEdgeEnterpriseX64.msi /q"
#start Edge
start-sleep 5
& "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"


#install WAC
$GatewayServerName="WACGW"

#Download Windows Admin Center if not present
if (-not (Test-Path -Path "$env:USERPROFILE\Downloads\WindowsAdminCenter.msi")){
    $ProgressPreference='SilentlyContinue' #for faster download
    Invoke-WebRequest -UseBasicParsing -Uri https://aka.ms/WACDownload -OutFile "$env:USERPROFILE\Downloads\WindowsAdminCenter.msi"
    $ProgressPreference='Continue' #return progress preference back
}
#Create PS Session and copy install files to remote server
Invoke-Command -ComputerName $GatewayServerName -ScriptBlock {Set-Item -Path WSMan:\localhost\MaxEnvelopeSizekb -Value 4096}
$Session=New-PSSession -ComputerName $GatewayServerName
Copy-Item -Path "$env:USERPROFILE\Downloads\WindowsAdminCenter.msi" -Destination "$env:USERPROFILE\Downloads\WindowsAdminCenter.msi" -ToSession $Session

#Install Windows Admin Center
Invoke-Command -Session $session -ScriptBlock {
    Start-Process msiexec.exe -Wait -ArgumentList "/i $env:USERPROFILE\Downloads\WindowsAdminCenter.msi /qn /L*v log.txt REGISTRY_REDIRECT_PORT_80=1 SME_PORT=443 SSL_CERTIFICATE_OPTION=generate"
}

$Session | Remove-PSSession

#add certificate to trusted root certs
start-sleep 10
$cert = Invoke-Command -ComputerName $GatewayServerName -ScriptBlock {Get-ChildItem Cert:\LocalMachine\My\ |where subject -eq "CN=Windows Admin Center"}
$cert | Export-Certificate -FilePath $env:TEMP\WACCert.cer
Import-Certificate -FilePath $env:TEMP\WACCert.cer -CertStoreLocation Cert:\LocalMachine\Root\

#Configure Resource-Based constrained delegation
$gatewayObject = Get-ADComputer -Identity $GatewayServerName
$computers = (Get-ADComputer -Filter *).Name

foreach ($computer in $computers){
    $computerObject = Get-ADComputer -Identity $computer
    Set-ADComputer -Identity $computerObject -PrincipalsAllowedToDelegateToAccount $gatewayObject
}
 

#Download AKS HCI module
$ProgressPreference='SilentlyContinue' #for faster download
Invoke-WebRequest -Uri "https://aka.ms/aks-hci-download" -UseBasicParsing -OutFile "$env:USERPROFILE\Downloads\AKS-HCI-Public-Preview-Oct-2020.zip"
$ProgressPreference='Continue' #return progress preference back
#unzip
Expand-Archive -Path "$env:USERPROFILE\Downloads\AKS-HCI-Public-Preview-Oct-2020.zip" -DestinationPath "$env:USERPROFILE\Downloads" -Force
Expand-Archive -Path "$env:USERPROFILE\Downloads\AksHci.Powershell.zip" -DestinationPath "$env:USERPROFILE\Downloads" -Force

#copy nupkg to WAC
$GatewayServerName="WACGW1"
$PSSession=New-PSSession -ComputerName $GatewayServerName
$Filename=Get-ChildItem -Path $env:userprofile\downloads\ | where Name -like "msft.sme.aks.*.nupkg"
Invoke-Command -ComputerName $GatewayServerName -ScriptBlock {
    New-Item -Path "C:\WACFeeds\" -Name Feeds -ItemType Directory -Force
}
Copy-Item -Path $FileName.FullName -Destination "C:\WACFeeds\" -ToSession $PSSession

#grab WAC Posh from GW
Copy-Item -Recurse -Force -Path "$env:ProgramFiles\windows admin center\PowerShell\Modules\ExtensionTools" -Destination "$env:ProgramFiles\windows admin center\PowerShell\Modules\" -FromSession $PSSession

#import wac module
Import-Module "$env:ProgramFiles\windows admin center\PowerShell\Modules\ExtensionTools"

# List feeds
Get-Feed "https://$GatewayServerName"
#add feed
Add-Feed -GatewayEndpoint "https://$GatewayServerName" -Feed "C:\WACFeeds\"

# List all extensions Does not work
Get-Extension "https://$GatewayServerName"

<#
PS C:\Windows\system32> Get-Extension "https://$GatewayServerName"
Invoke-WebRequest : {"error":{"code":"PathTooLongException","message":"The specified path, file name, or both are too
long. The fully qualified file name must be less than 260 characters, and the directory name must be less than 248
characters."}}
At C:\Program Files\windows admin center\PowerShell\Modules\ExtensionTools\ExtensionTools.psm1:236 char:17
+     $response = Invoke-WebRequest @params
+                 ~~~~~~~~~~~~~~~~~~~~~~~~~
    + CategoryInfo          : InvalidOperation: (System.Net.HttpWebRequest:HttpWebRequest) [Invoke-WebRequest], WebExc
   eption
    + FullyQualifiedErrorId : WebCmdletWebResponseException,Microsoft.PowerShell.Commands.InvokeWebRequestCommand
Failed to get the extensions
At C:\Program Files\windows admin center\PowerShell\Modules\ExtensionTools\ExtensionTools.psm1:238 char:9
+         throw "Failed to get the extensions"
+         ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    + CategoryInfo          : OperationStopped: (Failed to get the extensions:String) [], RuntimeException
    + FullyQualifiedErrorId : Failed to get the extensions
#>

#endregion

<#setup AKS (WAC GW) - does not work, bug
    #copy nupkg to WAC
    $GatewayServerName="WACGW1"
    $PSSession=New-PSSession -ComputerName $GatewayServerName
    $Filename=Get-ChildItem -Path $env:userprofile\downloads\ | where Name -like "msft.sme.aks.*.nupkg"
    Invoke-Command -ComputerName $GatewayServerName -ScriptBlock {
        New-Item -Path "C:\WACFeeds\" -Name Feeds -ItemType Directory -Force
    }
    Copy-Item -Path $FileName.FullName -Destination "C:\WACFeeds\" -ToSession $PSSession


    #grab WAC Posh from GW
    Copy-Item -Recurse -Force -Path "$env:ProgramFiles\windows admin center\PowerShell\Modules\ExtensionTools" -Destination "$env:ProgramFiles\windows admin center\PowerShell\Modules\" -FromSession $PSSession

    #import wac module
    Import-Module "$env:ProgramFiles\windows admin center\PowerShell\Modules\ExtensionTools"

    # List feeds
    Get-Feed "https://$GatewayServerName"
    #add feed
    Add-Feed -GatewayEndpoint "https://$GatewayServerName" -Feed "C:\WACFeeds\"

    # List all extensions Does not work
    Get-Extension "https://$GatewayServerName"

#>

