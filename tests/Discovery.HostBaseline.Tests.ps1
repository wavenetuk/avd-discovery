$hostBaselineModulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\scripts\common\Discovery.HostBaseline.psm1'
$commonModulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\scripts\common\Discovery.Common.psm1'
$adDsModulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\scripts\common\Discovery.ADDS.psm1'
$filePrintModulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\scripts\common\Discovery.FilePrint.psm1'
$sqlModulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\scripts\common\Discovery.SQL.psm1'
$rdsModulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\scripts\common\Discovery.RDS.psm1'

Import-Module -Name $commonModulePath -Force -ErrorAction Stop
Import-Module -Name $adDsModulePath -Force -ErrorAction Stop
Import-Module -Name $hostBaselineModulePath -Force -ErrorAction Stop
Import-Module -Name $filePrintModulePath -Force -ErrorAction Stop
Import-Module -Name $sqlModulePath -Force -ErrorAction Stop
Import-Module -Name $rdsModulePath -Force -ErrorAction Stop

Describe 'Discovery host baseline' {
	It 'rejects mutating commands in host workload entry scripts' {
		$scriptPath = [System.IO.Path]::GetTempFileName()
		try {
			Set-Content -Path $scriptPath -Value 'Start-Service -Name Spooler' -Encoding UTF8
			$failure = $null
			try { Assert-DiscoveryHostCollectorReadOnly -ScriptPath $scriptPath } catch { $failure = $_ }
			$failure | Should Not BeNullOrEmpty
			$failure.Exception.Message | Should Match 'Start-Service'
		}
		finally {
			Remove-Item -Path $scriptPath -Force -ErrorAction SilentlyContinue
		}
	}

	It 'normalizes domain-joined machine details' {
		$computerSystem = [PSCustomObject]@{
			Name           = '  sql-01  '
			Domain         = '  contoso.local '
			PartOfDomain   = $true
			Manufacturer   = ' Dell '
			Model          = ' PowerEdge '
		}

		$result = Get-DiscoveryMachineDetails -ComputerSystem $computerSystem

		$result.Hostname | Should Be 'sql-01'
		$result.Domain | Should Be 'contoso.local'
		$result.PartOfDomain | Should Be $true
		$result.Manufacturer | Should Be 'Dell'
		$result.Model | Should Be 'PowerEdge'
	}

	It 'uses the workgroup for a non-domain-joined machine' {
		$computerSystem = [PSCustomObject]@{
			Name           = 'print-01'
			Domain         = 'ignored.local'
			Workgroup      = ' WORKGROUP '
			PartOfDomain   = $false
			Manufacturer   = 'HP'
			Model          = 'Laser'
		}

		$result = Get-DiscoveryMachineDetails -ComputerSystem $computerSystem

		$result.Hostname | Should Be 'print-01'
		$result.Domain | Should Be 'WORKGROUP'
		$result.PartOfDomain | Should Be $false
	}

	It 'returns only eligible normalized installed applications' {
		$entries = @(
			[PSCustomObject]@{ DisplayName = '  SQL Server Management Studio '; Publisher = ' Microsoft '; InstallDate = '20260115'; DisplayVersion = '20.1' }
			[PSCustomObject]@{ DisplayName = 'KB5030000'; Publisher = 'Microsoft'; InstallDate = '20260116' }
			[PSCustomObject]@{ DisplayName = 'Security Update'; ReleaseType = 'Security Update' }
			[PSCustomObject]@{ DisplayName = 'Nested Component'; ParentKeyName = 'Parent' }
			[PSCustomObject]@{ DisplayName = 'SQL Server Management Studio'; Publisher = 'Microsoft'; InstallDate = '20260115'; DisplayVersion = '20.1' }
		)

		$applications = @(Get-DiscoveryInstalledApplications -RegistryEntries $entries)

		$applications.Count | Should Be 1
		$applications[0].Name | Should Be 'SQL Server Management Studio'
		$applications[0].InstallDate | Should Be '2026-01-15'
	}

	It 'classifies printers and enriches them with driver details' {
		$printers = @(
			[PSCustomObject]@{ Name = '  Finance Printer '; DriverName = 'Contoso Driver'; PortName = 'WSD-123'; Shared = $true; ShareName = 'Finance'; PrinterStatus = 'Normal' }
			[PSCustomObject]@{ Name = 'Cloud'; DriverName = 'Universal Print Class Driver'; PortName = 'UP1'; Shared = $false; PrinterStatus = 'Normal' }
		)
		$drivers = @([PSCustomObject]@{ Name = 'Contoso Driver'; DriverVersion = '2.1'; Manufacturer = 'Contoso' })

		$result = Get-DiscoveryPrinterInventory -PrinterObjects $printers -DriverObjects $drivers

		$result.PrinterCount | Should Be 2
		$result.Printers[0].Type | Should Be 'Network'
		$result.Printers[0].DriverProvider | Should Be 'Contoso'
		$result.Printers[1].Type | Should Be 'UniversalPrint'
	}

	It 'discovers installed language capabilities and locale settings' {
		$capabilities = @(
			[PSCustomObject]@{ Name = 'Language.Basic~~~en-GB~0.0.1.0'; State = 'Installed' }
			[PSCustomObject]@{ Name = 'Language.Basic~~~fr-FR~0.0.1.0'; State = 'NotPresent' }
		)
		$userLanguages = @([PSCustomObject]@{ LanguageTag = 'en-GB'; Autonym = 'English'; EnglishName = 'English (United Kingdom)' })

		$result = Get-DiscoveryLanguagePacks -CapabilityObjects $capabilities -InstalledUiLanguages @('en-GB') -CurrentUserLanguages $userLanguages -SystemLocale 'en-GB' -UiLanguageOverride 'en-GB'

		$result.CapabilityQuerySucceeded | Should Be $true
		$result.InstalledLanguageCapabilities.Count | Should Be 1
		$result.InstalledLanguageTags | Should Be @('en-GB')
		$result.CurrentUserLanguages[0].LanguageTag | Should Be 'en-GB'
		$result.SystemLocale | Should Be 'en-GB'
	}

	It 'detects Universal Print connectors and monitor-port queues' {
		$printers = @(
			[PSCustomObject]@{ Name = 'Cloud Queue'; DriverName = 'Other'; PortName = 'UP-001'; Shared = $false; PrinterStatus = 'Normal' }
			[PSCustomObject]@{ Name = 'Local Queue'; DriverName = 'Other'; PortName = 'USB001'; Shared = $false; PrinterStatus = 'Normal' }
		)

		$result = Get-DiscoveryUniversalPrint -ConnectorService ([PSCustomObject]@{ Status = 'Running' }) -ConnectorConfig ([PSCustomObject]@{ TenantId = 'tenant' }) -MonitorPorts @('UP-001') -PrinterObjects $printers

		$result.InUse | Should Be $true
		$result.ConnectorInstalled | Should Be $true
		$result.CloudPrinterCount | Should Be 1
		$result.CloudPrinters[0].Name | Should Be 'Cloud Queue'
		$result.UpMonitorPortCount | Should Be 1
	}

	It 'discovers file shares, SMB server settings, and print server role state' {
		$result = Get-DiscoveryFilePrintRoleState -ShareObjects @([PSCustomObject]@{ Name = 'Finance'; Path = 'D:\Shares\Finance'; Description = 'Finance documents'; Special = $false; ShareState = 'Online'; ConcurrentUserLimit = 50; EncryptData = $true }, [PSCustomObject]@{ Name = 'C$'; Special = $true }) -SmbServerConfiguration ([PSCustomObject]@{ EnableSMB1Protocol = $false; EnableSMB2Protocol = $true; EncryptData = $true; RequireSecuritySignature = $false; EnableSecuritySignature = $true }) -SpoolerService ([PSCustomObject]@{ Status = 'Running'; StartType = 'Automatic' }) -FeatureObjects @([PSCustomObject]@{ Name = 'FS-FileServer'; Installed = $true }, [PSCustomObject]@{ Name = 'Print-Server'; Installed = $true })

		$result.ShareCount | Should Be 1
		$result.Shares[0].Name | Should Be 'Finance'
		$result.FileServerRoleInstalled | Should Be $true
		$result.PrintServerRoleInstalled | Should Be $true
		$result.SmbServer.EnableSMB1Protocol | Should Be $false
		$result.PrintSpooler.Status | Should Be 'Running'
	}

	It 'discovers loaded user profiles and mapped drives' {
		$profiles = Get-DiscoveryLoadedUserProfiles -ProfileObjects @([PSCustomObject]@{ SID = 'S-1-5-21-100'; LocalPath = 'C:\Users\Alex'; Loaded = $true }) -LoadedSids @('S-1-5-21-100') -AccountNameResolver { param($sid) 'CONTOSO\Alex' }
		$drives = Get-DiscoveryUserMappedDriveState -Sid 'S-1-5-21-100' -AccountName 'CONTOSO\Alex' -DriveRegistryEntries @([PSCustomObject]@{ Name = 'Z'; RegistryKeyPath = 'Registry::HKEY_USERS\S-1-5-21-100\Network\Z'; Values = [PSCustomObject]@{ RemotePath = '\\fileserver\finance'; UserName = 'CONTOSO\Alex'; ProviderName = 'Microsoft Windows Network'; ProviderType = 1 } })

		$profiles[0].AccountName | Should Be 'CONTOSO\Alex'
		$profiles[0].ProfilePath | Should Be 'C:\Users\Alex'
		$drives.MappedDriveCount | Should Be 1
		$drives.MappedDrives[0].DriveLetter | Should Be 'Z:'
		$drives.MappedDrives[0].RemotePath | Should Be '\\fileserver\finance'
	}

	It 'detects Active Directory dependency evidence across host services' {
		$result = Get-DiscoveryAdDsDependencies -ServiceObjects @([PSCustomObject]@{ Name = 'ContosoSvc'; DisplayName = 'Contoso Service'; StartName = 'CONTOSO\svc-app'; State = 'Running'; StartMode = 'Auto' }) -ScheduledTaskObjects @([PSCustomObject]@{ TaskPath = '\Contoso\'; TaskName = 'Sync'; State = 'Ready'; Principal = [PSCustomObject]@{ UserId = 'CONTOSO\svc-task'; RunLevel = 'Highest' } }) -OdbcEntries @([PSCustomObject]@{ DsnName = 'Finance'; RegistryPath = 'HKLM:\ODBC\Finance'; Values = [PSCustomObject]@{ Server = 'sql.contoso.com'; UID = 'CONTOSO\sqluser'; Driver = 'SQL Server' } }) -TcpConnectionObjects @([PSCustomObject]@{ RemoteAddress = '10.0.0.10'; RemotePort = 389 }, [PSCustomObject]@{ RemoteAddress = '10.0.0.10'; RemotePort = 389 }) -LocalAddresses @('127.0.0.1') -ConfigFileReferences @([PSCustomObject]@{ FileName = 'app.config' })

		$result.HasDomainDependencies | Should Be $true
		$result.DomainServiceCount | Should Be 1
		$result.DomainScheduledTaskCount | Should Be 1
		$result.DomainOdbcSourceCount | Should Be 1
		$result.AdPortConnections[0].ConnectionCount | Should Be 2
		$result.ConfigFileReferenceCount | Should Be 1
	}

	It 'discovers domain controller topology and replication evidence' {
		$result = Get-DiscoveryADDSRoleState -ComputerSystem ([PSCustomObject]@{ DomainRole = 5 }) -ServiceObjects @([PSCustomObject]@{ Name = 'NTDS'; Status = 'Running'; StartType = 'Automatic' }, [PSCustomObject]@{ Name = 'DNS'; Status = 'Running'; StartType = 'Automatic' }) -ShareObjects @([PSCustomObject]@{ Name = 'SYSVOL' }, [PSCustomObject]@{ Name = 'NETLOGON' }) -Domain ([PSCustomObject]@{ DNSRoot = 'contoso.local'; NetBIOSName = 'CONTOSO'; DomainMode = 'Windows2016Domain'; PDCEmulator = 'dc01.contoso.local'; RIDMaster = 'dc01.contoso.local'; InfrastructureMaster = 'dc01.contoso.local' }) -Forest ([PSCustomObject]@{ Name = 'contoso.local'; ForestMode = 'Windows2016Forest'; Domains = @('contoso.local'); Sites = @('HQ'); SchemaMaster = 'dc01.contoso.local'; DomainNamingMaster = 'dc01.contoso.local' }) -DomainControllers @([PSCustomObject]@{ HostName = 'dc01.contoso.local'; Site = 'HQ'; IPv4Address = '10.0.0.10'; IsGlobalCatalog = $true; IsReadOnly = $false }) -ReplicationPartners @([PSCustomObject]@{ Partner = 'CN=NTDS Settings,CN=DC02'; LastReplicationSuccess = '2026-09-16T09:00:00'; LastReplicationResult = 0; ConsecutiveReplicationFailures = 0 })

		$result.IsDomainController | Should Be $true
		$result.SysvolShared | Should Be $true
		$result.NetlogonShared | Should Be $true
		$result.Domain.DnsRoot | Should Be 'contoso.local'
		$result.DomainControllerCount | Should Be 1
		$result.ReplicationPartners[0].LastReplicationResult | Should Be 0
	}

	It 'discovers SQL instances, services, and TCP settings without database access' {
		$details = @{ MSSQLSERVER = [PSCustomObject]@{ Setup = [PSCustomObject]@{ Edition = 'Developer Edition'; SQLPath = 'C:\Program Files\Microsoft SQL Server' }; Version = [PSCustomObject]@{ CurrentVersion = '16.0.1000.6' }; Tcp = [PSCustomObject]@{ TcpPort = '1433'; TcpDynamicPorts = '' } } }
		$result = Get-DiscoverySqlInstanceState -InstanceEntries @([PSCustomObject]@{ Name = 'MSSQLSERVER'; InstanceId = 'MSSQL16.MSSQLSERVER' }) -ServiceObjects @([PSCustomObject]@{ Name = 'MSSQLSERVER'; DisplayName = 'SQL Server'; State = 'Running'; StartMode = 'Auto'; StartName = 'CONTOSO\svc-sql' }) -InstanceDetails $details

		$result.SqlServerDetected | Should Be $true
		$result.InstanceCount | Should Be 1
		$result.Instances[0].Version | Should Be '16.0.1000.6'
		$result.Instances[0].TcpPort | Should Be '1433'
		$result.Instances[0].ServiceAccount | Should Be 'CONTOSO\svc-sql'
		$result.DatabaseInventory.Status | Should Be 'NotCollected'
	}

	It 'discovers installed Remote Desktop Services roles and services' {
		$topology = [PSCustomObject]@{ Status = 'Collected'; ConnectionBroker = 'rds-broker.contoso.local'; Servers = @([PSCustomObject]@{ Server = 'rds01.contoso.local'; Roles = @('RDS-RD-SERVER') }); Collections = @([PSCustomObject]@{ CollectionName = 'Desktops'; SessionHosts = @([PSCustomObject]@{ SessionHost = 'rds01.contoso.local' }) }); Licensing = @([PSCustomObject]@{ Mode = 'PerUser'; LicenseServer = @('license01.contoso.local') }) }
		$result = Get-DiscoveryRdsRoleState -FeatureObjects @([PSCustomObject]@{ Name = 'RDS-RD-Server'; DisplayName = 'Remote Desktop Session Host'; Installed = $true }, [PSCustomObject]@{ Name = 'RDS-Gateway'; DisplayName = 'Remote Desktop Gateway'; Installed = $true }) -ServiceObjects @([PSCustomObject]@{ Name = 'TermService'; DisplayName = 'Remote Desktop Services'; State = 'Running'; StartMode = 'Auto'; StartName = 'NetworkService' }) -Topology $topology

		$result.RdsRoleDetected | Should Be $true
		$result.InstalledRoleCount | Should Be 2
		$result.Services[0].Status | Should Be 'Running'
		$result.DeploymentInventory.Status | Should Be 'Collected'
		$result.DeploymentInventory.Collections[0].CollectionName | Should Be 'Desktops'
	}
}