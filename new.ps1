	
	
	write-output "Stage0" > $env:USERPROFILE\.install_windows_machine.stage
	
	
	
	Invoke-Expression ((new-object net.webclient).DownloadString('https://chocolatey.org/install.ps1'))
	
	choco install -y dotnet4.6.2
	
	choco install -y PowerShell
	
	choco install IIS-WebServerRole IIS-ASPNET IIS-ASPNET45 IIS-RequestMonitor IIS-BasicAuthentication IIS-WindowsAuthentication IIS-WebSockets --source windowsfeatures

    choco install -y adobereader googlechrome firefox skype 7zip

	choco install -y visualstudiocode notepadplusplus filezilla keepass fiddler4 agentransack

    choco install -y  --allowemptychecksum vlc

	choco install -y reportviewer2012 reportviewer2010sp1

    choco install -y --allowemptychecksum webpi 

    choco install -y git tortoisesvn poshgit nuget.commandline curl sysinternals

    choco install -y  --allowemptychecksum gitextensions

    choco install -y --allowemptychecksum ilspy 

    choco install -y  --allowemptychecksum linqpad4

    choco install -y --allowemptychecksum winmerge 

    choco install -y nodejs

    choco install -y  --allowemptychecksum putty

    choco install -y  --allowemptychecksum jq

	if ($env:PROCESSOR_ARCHITECTURE = "x86") {
		choco install -y sql-server-management-studio --version 13.0.16106.4
	} else {
		choco install -y sql-server-management-studio
	}
	
	Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
	
	$env:visualStudio:setupFolder = "d:\"
		
    choco install -y visualstudio2015Professional