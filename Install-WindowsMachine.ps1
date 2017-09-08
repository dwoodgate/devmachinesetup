Param
(
    [Parameter(Mandatory = $False)]
    $stage = "Stage0",

    [Parameter(Mandatory = $False)]
    [ValidateSet("2013", "2015", "2017")]
    $vsVersion = "2015",

    [Parameter(Mandatory = $False)]
    [ValidateSet("Community", "Professional", "Enterprise")]
    $vsEdition = "Professional",

    [Parameter(Mandatory = $False)]
    [ValidateSet("Local", "Iso", "Web")]
    $vsSource = "Local",

    [Parameter(Mandatory = $False)]
    $vsLocalPath = "D:\",

    [Parameter(Mandatory = $False)]
    $vsIsoPath,

    [Parameter(Mandatory = $False)]
    $codeBaseDir = "C:\Code",
	
    [Parameter(Mandatory = $False)]
    $stagePath = "$env:USERPROFILE\.install_windows_machine.stage"
)




#
# Function to create a path if it does not exist
#
function CreatePathIfNotExists($pathName) {
    if (!(Test-Path -Path $pathName)) {
        New-Item -ItemType directory -Path $pathName
    }
}

function GetStage {
    if (!(Test-Path -Path $stagePath)) {
        return $Script:stage
    } 
    return Get-Content $stagePath -TotalCount 1
}

function Mount-Iso([string] $isoPath) {
    if ( -not (Test-Path $isoPath)) { throw "$isoPath does not exist" }
	
    if ($(Test-Windows8orGreater)) {
        Write-Host "Mounting $isoPath using powershell"
        Mount-DiskImage -ImagePath $isoPath
        $driveLetter = (Get-DiskImage $isoPath | Get-Volume).DriveLetter
        return ($driveLetter + ":\")
    }
    else {
        $driveLetter = ls function:[i-z]: -n | ? { !(test-path $_) } | random
        Write-Host "Mounting $isoPath using ImDisk"
        (& "imdisk" -a -f $isoPath -m $driveLetter) | out-null
        return ($driveLetter + "\")
    }
}

function Dismount-Iso([string] $driveLetter) {
    start-sleep -s 5

    if ($(Test-Windows8orGreater)) {
        Write-Host "Unmounting $driveLetter using powershell"
        Get-Volume ($driveLetter.Replace(":\", "")) | Get-DiskImage | Dismount-DiskImage
    }
    else {
        Write-Host "Unmounting $driveLetter using ImDisk"
        (& "imdisk" -D -m ($driveLetter.Replace("\", ""))) | out-null
    }
}

function Test-Windows8orGreater {
    $osVersion = [Environment]::OSVersion.Version
    return $osVersion -ge (new-object 'Version' 6, 2)
}

function Test-ImDisk {
    if ( -not (Get-Command ImDisk)) { throw "ImDisk does not exist" }
}

#Adapted from https://gist.github.com/altrive/5329377
#Based on <http://gallery.technet.microsoft.com/scriptcenter/Get-PendingReboot-Query-bdb79542>
function Test-PendingReboot {
    if (Get-ChildItem "HKLM:\Software\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending" -EA Ignore) { return $true }
    if (Get-Item "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired" -EA Ignore) { return $true }
    if (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -EA Ignore) { return $true }
    try { 
        $util = [wmiclass]"\\.\root\ccm\clientsdk:CCM_ClientUtilities"
        $status = $util.DetermineIfRebootPending()
        if (($status -ne $null) -and $status.RebootPending) {
            return $true
        }
    }
    catch {}
 
    return $false
}

function CreateScheduledTask ($scriptPath) {
    SCHTASKS /Create /TN "Install-WindowsMachine" /SC ONLOGON /TR Powershell.exe /IT /RL HIGHEST /F
	$doc = [XML] (& SCHTASKS /QUERY /TN "Install-WindowsMachine" /XML)
	$child = $doc.CreateElement("UserId", $doc.Task.NamespaceURI)
	$doc.Task.Triggers.LogonTrigger.AppendChild( $child )
    $doc.Task.Triggers.LogonTrigger.UserId = $doc.Task.Principals.Principal.UserId
    $child = $doc.CreateElement("Delay", $doc.Task.NamespaceURI)
    $doc.Task.Triggers.LogonTrigger.AppendChild( $child )
    $doc.Task.Triggers.LogonTrigger.Delay = "PT30S"
	$doc.Task.Settings.DisallowStartIfOnBatteries = "false"
	$doc.Task.Settings.StopIfGoingOnBatteries = "false"
	$doc.Task.Settings.StartWhenAvailable = "true"
	$child = $doc.CreateElement("Arguments", $doc.Task.NamespaceURI)
	$doc.Task.Actions.Exec.AppendChild($child)
	$doc.Task.Actions.Exec.Arguments = "-ExecutionPolicy Bypass -File `"$scriptPath`""
	$taskXmlFile = [System.IO.Path]::GetTempFileName()
	$doc.Save($taskXmlFile)
	SCHTASKS /Create /TN "Install-WindowsMachine" /XML $taskXmlFile /F 
}

#
# Function to install VSIX extensions
#
$vsixInstallerCommand2013 = "$($env:VS120COMNTOOLS)..\IDE\VsixInstaller.exe"
$vsixInstallerCommand2015 = "$($env:VS140COMNTOOLS)..\IDE\VSIXInstaller.exe"
$vsixInstallerCommand2017 = "C:\Program Files (x86)\Microsoft Visual Studio\2017\$vsEdition\Common7\IDE\VsixInstaller.exe"
$vsixInstallerCommandGeneralArgs = " /q /a "

function InstallVSExtension($extensionUrl, $extensionFileName, $vsVersion) {
    
    Write-Host "Installing extension " $extensionFileName
    
    # Select the appropriate VSIX installer
    if ($vsVersion -eq "2013") {
        $vsixInstallerCommand = $vsixInstallerCommand2013
    }
    if ($vsVersion -eq "2015") {
        $vsixInstallerCommand = $vsixInstallerCommand2015
    }
    if ($vsVersion -eq "2017") {
        $vsixInstallerCommand = $vsixInstallerCommand2017
    }

    # Download the extension
    Invoke-WebRequest $extensionUrl -OutFile $extensionFileName

    # Quiet Install of the Extension
    $proc = Start-Process -FilePath "$vsixInstallerCommand" -ArgumentList ($vsixInstallerCommandGeneralArgs + $extensionFileName) -PassThru
    $proc.WaitForExit()
    if ( $proc.ExitCode -ne 0 ) {
        Write-Host "Unable to install extension " $extensionFileName " due to error " $proc.ExitCode -ForegroundColor Red
    }

    # Delete the downloaded extension file from the local system
    Remove-Item $extensionFileName
}

$AUSettigns = (New-Object -com "Microsoft.Update.AutoUpdate").Settings
$AUSettigns.NotificationLevel = 1
$AUSettigns.Save()
#
# [Stage0] Installing Operating System Components as well as chocolatey itself. Needs to happen before ANY other runs!
#

if ( $(GetStage) -eq "Stage0" ) {
    Set-ExecutionPolicy Unrestricted

    Invoke-Expression ((new-object net.webclient).DownloadString('https://chocolatey.org/install.ps1'))
	
    if (-not $(Test-Windows8orGreater)) {
        Write-Host "Checking imdisk installed"
        choco install -y imdisk
        Test-ImDisk
    }
	
    if (-not $(Test-Windows8orGreater)) {
        dism /online /enable-feature /featurename:IIS-WebServerRole /featurename:NetFx3 /featurename:WCF-HTTP-Activation  /featurename:IIS-WebServer /featurename:IIS-Metabase /featurename:IIS-ManagementConsole /featurename:IIS-ManagementService /featurename:IIS-ManagementScriptingTools /featurename:IIS-ApplicationDevelopment /featurename:IIS-NetFxExtensibility /featurename:IIS-ASP /featurename:IIS-ASPNET /featurename:IIS-ISAPIExtensions /featurename:IIS-ISAPIFilter /featurename:IIS-ServerSideIncludes /featurename:IIS-CommonHttpFeatures /featurename:IIS-DefaultDocument /featurename:IIS-DirectoryBrowsing /featurename:IIS-HttpErrors /featurename:IIS-HttpRedirect /featurename:IIS-StaticContent /featurename:IIS-HealthAndDiagnostics /featurename:IIS-HttpLogging /featurename:IIS-RequestMonitor /featurename:IIS-Performance /featurename:IIS-HttpCompressionDynamic /featurename:IIS-HttpCompressionStatic /featurename:IIS-Security /featurename:IIS-BasicAuthentication /featurename:IIS-RequestFiltering /featurename:IIS-WindowsAuthentication
    }
    else {
        Enable-WindowsOptionalFeature -FeatureName NetFx3 -Online -All -NoRestart
        Enable-WindowsOptionalFeature -FeatureName WCF-Services45 -Online -All -NoRestart
        Enable-WindowsOptionalFeature -FeatureName WCF-TCP-PortSharing45  -All -Online -NoRestart
        Enable-WindowsOptionalFeature -FeatureName NetFx4-AdvSrvs -Online -All -NoRestart
        Enable-WindowsOptionalFeature -FeatureName NetFx4Extended-ASPNET45 -All -Online -NoRestart
        Enable-WindowsOptionalFeature -FeatureName IIS-WebServerRole -Online -All -NoRestart
        Enable-WindowsOptionalFeature -FeatureName IIS-ASPNET -Online -All -NoRestart 
        Enable-WindowsOptionalFeature -FeatureName IIS-ASPNET45 -Online -All -NoRestart 
        Enable-WindowsOptionalFeature -FeatureName IIS-RequestMonitor -Online -All -NoRestart 
        Enable-WindowsOptionalFeature -FeatureName IIS-BasicAuthentication -Online -All -NoRestart 
        Enable-WindowsOptionalFeature -FeatureName IIS-WindowsAuthentication -Online -All -NoRestart 
        Enable-WindowsOptionalFeature -FeatureName IIS-WebSockets -Online -All -NoRestart
    }

    CreateScheduledTask -scriptPath $MyInvocation.MyCommand.Path
    Write-Output "Stage1" > $stagePath
    Restart-Computer
    Exit
}


#
# [Stage1]
#

if ( $(GetStage) -eq "Stage1" ) {

    if ($(Test-PendingReboot)) {
        Restart-Computer
        Exit
    }

    choco install -y dotnet4.6.2 PowerShell
    
    Write-Output "Stage2" > $stagePath
    Restart-Computer
    Exit
}

#
# [Stage2] Tools needed for PC, IT, and Dev
#

if ( $(GetStage) -eq "Stage2" ) {

    if ($(Test-PendingReboot)) {
        Restart-Computer
        Exit
    }

    choco install -y chocolateygui googlechrome 7zip visualstudiocode agentransack notepadplusplus chocolateygui
    choco install -y --allowemptychecksum winmerge putty
#    choco install -y  --allowemptychecksum vlc
#    choco install -y adobereader firefox skype filezilla keepass fiddler4 nuget.commandline curl sysinternals
    choco install -y reportviewer2012 reportviewer2010sp1
    choco install -y git tortoisesvn poshgit nodejs
    choco install -y  --allowemptychecksum webpi gitextensions ilspy linqpad4 jq

    Install-PackageProvider -Name NuGet -Force

    Write-Output "Stage3" > $stagePath
    Restart-Computer
    Exit
}

#
# [Stage3] node packages
#
if ( $(GetStage) -eq "Stage3" ) {
    
    #
    # Phase #2 Will use the runtimes/tools above to install additional packages
    #

    RefreshEnv.cmd      # Ships with chocolatey and re-loads environment variables in the current session

    npm install -g jspm
    npm install -g moment
    npm install -g bower
    npm install -g gulp

    Write-Output "Stage4" > $stagePath
    Restart-Computer
    Exit
}

#
# [Stage4] Installing a version of Visual Studio (based on Chocolatey)
#
if ( $(GetStage) -eq "Stage4" ) {

    if ($(Test-PendingReboot)) {
        Restart-Computer
        Exit
    }

    if ($vsVersion -eq "2015") {
        if ($vsSource -eq "Local") {
            $env:visualStudio:setupFolder = $vsLocalPath
        }
        if ($vsSource -eq "Iso") {
            $iso = Mount-iso $vsIsoPath
            $env:visualStudio:setupFolder = $iso
        }
        
        choco install -y visualstudio2015Professional
        
        if ($vsSource -eq "Iso") {
            Dismount-Iso $iso
        }
		
    } 
    elseif ($vsVersion -eq "2017") {
        switch ($vsEdition) {
            "Community" {
                choco install visualstudio2017community -y #--package-parameters "--allWorkloads --includeRecommended --includeOptional --passive --locale en-US"
            }
            "Professional" {
                choco install visualstudio2017professional -y #--package-parameters "--allWorkloads --includeRecommended --includeOptional --passive --locale en-US"
            }            
            "Enterprise" {
                choco install visualstudio2017enterprise -y #--package-parameters "--allWorkloads --includeRecommended --includeOptional --passive --locale en-US"
            }
        }
    }
    Write-Output "Stage5" > $stagePath
    Restart-Computer
    Exit
}


#
# [Stage5] Database Platform Tools
#
if ( $(GetStage) -eq "Stage5" ) {
    if ($(Test-PendingReboot)) {
        Restart-Computer 
        Exit
    }
    if ($env:PROCESSOR_ARCHITECTURE = "x86") {
        choco install -y sql-server-management-studio --version 13.0.16106.4
    }
    else {
        choco install -y sql-server-management-studio
    }
	
    choco install -y --allowemptychecksum dbeaver 

    Write-Output "Stage6" > $stagePath
    if ($(Test-PendingReboot)) {
        Restart-Computer
        Exit
    }
}

#
# [Stage6] Visual Studio Extensions
#

if ( $(GetStage) -eq "Stage6") {
    if ($(Test-PendingReboot)) {
        Restart-Computer
        Exit
    }
    if ($vsVersion -eq "2015") {

        # Refreshing the environment path variables
        RefreshEnv.cmd
	
        choco install ankhsvn -y
	
        # Indent Guides
        # https://visualstudiogallery.msdn.microsoft.com/e792686d-542b-474a-8c55-630980e72c30
        InstallVSExtension -extensionUrl "https://visualstudiogallery.msdn.microsoft.com/e792686d-542b-474a-8c55-630980e72c30/file/48932/20/IndentGuide%20v14.vsix" `
            -extensionFileName "IndentGuide.vsix" -vsVersion $vsVersion
    
        # Web Essentials 2015
        # https://visualstudiogallery.msdn.microsoft.com/ee6e6d8c-c837-41fb-886a-6b50ae2d06a2
        InstallVSExtension -extensionUrl "https://visualstudiogallery.msdn.microsoft.com/ee6e6d8c-c837-41fb-886a-6b50ae2d06a2/file/146119/37/Web%20Essentials%202015.1%20v1.0.207.vsix" `
            -extensionFileName "WebEssentials2015.vsix" -vsVersion $vsVersion
    
        # jQuery Code Snippets
        # https://visualstudiogallery.msdn.microsoft.com/577b9c03-71fb-417b-bcbb-94b6d3d326b8
        InstallVSExtension -extensionUrl "https://visualstudiogallery.msdn.microsoft.com/577b9c03-71fb-417b-bcbb-94b6d3d326b8/file/84997/6/jQueryCodeSnippets.vsix" `
            -extensionFileName "jQueryCodeSnippets.vsix" -vsVersion $vsVersion
    
        # F# PowerTools
        # https://visualstudiogallery.msdn.microsoft.com/136b942e-9f2c-4c0b-8bac-86d774189cff
        InstallVSExtension -extensionUrl "https://visualstudiogallery.msdn.microsoft.com/136b942e-9f2c-4c0b-8bac-86d774189cff/file/124201/33/FSharpVSPowerTools.vsix" `
            -extensionFileName "FSharpPowerTools.vsix" -vsVersion $vsVersion
    
        # Snippet Designer
        # https://visualstudiogallery.msdn.microsoft.com/B08B0375-139E-41D7-AF9B-FAEE50F68392
        InstallVSExtension -extensionUrl "https://visualstudiogallery.msdn.microsoft.com/B08B0375-139E-41D7-AF9B-FAEE50F68392/file/5131/12/SnippetDesigner.vsix" `
            -extensionFileName "SnippetDesigner.vsix" -vsVersion $vsVersion
    
        # SideWaffle Template Pack
        # https://visualstudiogallery.msdn.microsoft.com/a16c2d07-b2e1-4a25-87d9-194f04e7a698
        InstallVSExtension -extensionUrl "https://visualstudiogallery.msdn.microsoft.com/a16c2d07-b2e1-4a25-87d9-194f04e7a698/referral/110630" `
            -extensionFileName "SideWaffle.vsix" -vsVersion $vsVersion
    
        # GraphEngine VSExt
        # https://visualstudiogallery.msdn.microsoft.com/12835dd2-2d0e-4b8e-9e7e-9f505bb909b8
        InstallVSExtension -extensionUrl "https://visualstudiogallery.msdn.microsoft.com/12835dd2-2d0e-4b8e-9e7e-9f505bb909b8/file/161997/14/GraphEngineVSExtension.vsix" `
            -extensionFileName "GraphEngine.vsix" -vsVersion $vsVersion
    
        # Bing Developer Assistant
        # https://visualstudiogallery.msdn.microsoft.com/5d01e3bd-6433-47f2-9c6d-a9da52d172cc
        # Not using it anymore, distracts IntelliSense...
        #    InstallVSExtension -extensionUrl "https://visualstudiogallery.msdn.microsoft.com/5d01e3bd-6433-47f2-9c6d-a9da52d172cc/file/150980/8/DeveloperAssistant_2015.vsix" `
        #                       -extensionFileName "DevAssistant.vsix" -vsVersion $vsVersion
    
        # RegEx Tester
        # https://visualstudiogallery.msdn.microsoft.com/16b9d664-d88c-460e-84a5-700ab40ba452
        InstallVSExtension -extensionUrl "https://visualstudiogallery.msdn.microsoft.com/16b9d664-d88c-460e-84a5-700ab40ba452/file/31824/18/RegexTester-v1.5.2.vsix" `
            -extensionFileName "RegExTester.vsix" -vsVersion $vsVersion
    
        # Web Compiler
        # https://visualstudiogallery.msdn.microsoft.com/3b329021-cd7a-4a01-86fc-714c2d05bb6c
        InstallVSExtension -extensionUrl "https://visualstudiogallery.msdn.microsoft.com/3b329021-cd7a-4a01-86fc-714c2d05bb6c/file/164873/38/Web%20Compiler%20v1.10.306.vsix" `
            -extensionFileName "WebCompiler.vsix" -vsVersion $vsVersion
    
        # OpenCommandLine
        # https://visualstudiogallery.msdn.microsoft.com/4e84e2cf-2d6b-472a-b1e2-b84932511379
        InstallVSExtension -extensionUrl "https://visualstudiogallery.msdn.microsoft.com/4e84e2cf-2d6b-472a-b1e2-b84932511379/file/151803/35/Open%20Command%20Line%20v2.0.168.vsix" `
            -extensionFileName "OpenCommandLine.vsix" -vsVersion $vsVersion
    
        # Refactoring Essentials for VS2015
        # https://visualstudiogallery.msdn.microsoft.com/68c1575b-e0bf-420d-a94b-1b0f4bcdcbcc
        InstallVSExtension -extensionUrl "https://visualstudiogallery.msdn.microsoft.com/68c1575b-e0bf-420d-a94b-1b0f4bcdcbcc/file/146895/20/RefactoringEssentials.vsix" `
            -extensionFileName "RefactoringEssentials.vsix" -vsVersion $vsVersion
    
        # AllJoyn System Bridge Templates
        # https://visualstudiogallery.msdn.microsoft.com/aea0b437-ef07-42e3-bd88-8c7f906d5da8
        InstallVSExtension -extensionUrl "https://visualstudiogallery.msdn.microsoft.com/aea0b437-ef07-42e3-bd88-8c7f906d5da8/file/165147/8/DeviceSystemBridgeTemplate.vsix" `
            -extensionFileName "AllJoynSysBridge.vsix" -vsVersion $vsVersion
    
        # ASP.NET Project Templates for traditional ASP.NET Projects
        # https://visualstudiogallery.msdn.microsoft.com/9402d38e-2a85-434e-8d6a-8fc075068a42
        InstallVSExtension -extensionUrl "https://visualstudiogallery.msdn.microsoft.com/9402d38e-2a85-434e-8d6a-8fc075068a42/referral/149131" `
            -extensionFileName "AspNetTemplates.vsix" -vsVersion $vsVersion
                           
        # .Net Portability Analyzer
        # https://visualstudiogallery.msdn.microsoft.com/1177943e-cfb7-4822-a8a6-e56c7905292b
        InstallVSExtension -extensionUrl "https://visualstudiogallery.msdn.microsoft.com/1177943e-cfb7-4822-a8a6-e56c7905292b/file/138960/3/ApiPort.vsix" `
            -extensionFileName "NetPortabilityAnalyzer.vsix" -vsVersion $vsVersion

        # Caliburn.Micro Windows 10 Templates for VS2015
        # https://visualstudiogallery.msdn.microsoft.com/b6683732-01ed-4bb3-a2d3-a633a5378997
        InstallVSExtension -extensionUrl "https://visualstudiogallery.msdn.microsoft.com/b6683732-01ed-4bb3-a2d3-a633a5378997/file/165880/5/CaliburnUniversalTemplatePackage.vsix" `
            -extensionFileName "CaliburnTemplates.vsix" -vsVersion $vsVersion

        # Color Theme Editor
        # https://visualstudiogallery.msdn.microsoft.com/6f4b51b6-5c6b-4a81-9cb5-f2daa560430b
        InstallVSExtension -extensionUrl "https://visualstudiogallery.msdn.microsoft.com/6f4b51b6-5c6b-4a81-9cb5-f2daa560430b/file/169990/1/ColorThemeEditor.vsix" `
            -extensionFileName "ColorThemeEditor.vsix" -vsVersion $vsVersion

        # Productivity Power Tools
        # https://visualstudiogallery.msdn.microsoft.com/34ebc6a2-2777-421d-8914-e29c1dfa7f5d
        InstallVSExtension -extensionUrl "https://visualstudiogallery.msdn.microsoft.com/34ebc6a2-2777-421d-8914-e29c1dfa7f5d/file/169971/1/ProPowerTools.vsix" `
            -extensionFileName "ProPowerTools.vsix" -vsVersion $vsVersion
                       
    }

    if ($vsVersion -eq "2017") {

        # Refreshing the environment path variables
        RefreshEnv.cmd

        # Productivity Power Tools
        # https://marketplace.visualstudio.com/items?itemName=GitHub.GitHubExtensionforVisualStudio
        InstallVSExtension -extensionUrl "https://visualstudiogallery.msdn.microsoft.com/75be44fb-0794-4391-8865-c3279527e97d/file/159055/36/GitHub.VisualStudio.vsix" `
            -extensionFileName "GitHubExtensionsForVS.vsix" -vsVersion $vsVersion

        # Snippet Designer
        # https://marketplace.visualstudio.com/items?itemName=vs-publisher-2795.SnippetDesigner
        InstallVSExtension -extensionUrl "https://visualstudiogallery.msdn.microsoft.com/b08b0375-139e-41d7-af9b-faee50f68392/file/5131/16/SnippetDesigner.vsix" `
            -extensionFileName "SnippetDesigner.vsix" -vsVersion $vsVersion

        # Web Essentials 2017
        # https://marketplace.visualstudio.com/items?itemName=MadsKristensen.WebExtensionPack2017
        InstallVSExtension -extensionUrl "https://visualstudiogallery.msdn.microsoft.com/a5a27916-2099-4c5b-a3ff-6a46e4b01298/file/236262/11/Web%20Essentials%202017%20v1.5.8.vsix" `
            -extensionFileName "WebEssentials2017.vsix" -vsVersion $vsVersion

        # Productivity Power Tools 2017
        # https://marketplace.visualstudio.com/items?itemName=VisualStudioProductTeam.ProductivityPowerPack2017
        InstallVSExtension -extensionUrl "https://visualstudiogallery.msdn.microsoft.com/11693073-e58a-45b3-8818-b2cf5d925af7/file/244442/4/ProductivityPowerTools2017.vsix" `
            -extensionFileName "ProductivityPowertools2017.vsix" -vsVersion $vsVersion

        # Power Commands 2017
        # https://marketplace.visualstudio.com/items?itemName=VisualStudioProductTeam.PowerCommandsforVisualStudio
        InstallVSExtension -extensionUrl "https://visualstudiogallery.msdn.microsoft.com/80f73460-89cd-4d93-bccb-f70530943f82/file/242896/4/PowerCommands.vsix" `
            -extensionFileName "PowerCommands2017.vsix" -vsVersion $vsVersion

        # Power Shell Tools 2017
        # https://marketplace.visualstudio.com/items?itemName=AdamRDriscoll.PowerShellToolsforVisualStudio2017-18561
        InstallVSExtension -extensionUrl "https://visualstudiogallery.msdn.microsoft.com/8389e80d-9e40-4fc1-907c-a07f7842edf2/file/257196/1/PowerShellTools.15.0.vsix" `
            -extensionFileName "PowerShellTools2017.vsix" -vsVersion $vsVersion

    }
    Write-Output "Cleanup" > $stagePath
    if ($(Test-PendingReboot)) {
        Restart-Computer
        Exit
    }
}

#
# [Cleanup] Remove the scheduled login job
#
if ( $(GetStage) -eq "Cleanup") {
    $AUSettigns = (New-Object -com "Microsoft.Update.AutoUpdate").Settings
    $AUSettigns.NotificationLevel = 4
    $AUSettigns.Save()
    SCHTASKS /Delete /TN "Install-WindowsMachine" /F
}