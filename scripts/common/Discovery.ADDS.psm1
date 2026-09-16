Set-StrictMode -Version Latest

$hostBaselineModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Discovery.HostBaseline.psm1'
Import-Module -Name $hostBaselineModulePath -ErrorAction Stop

function Get-DiscoveryConfigFileServerReferences {
	param([string[]]$ScanRoots)
	if (-not $PSBoundParameters.ContainsKey('ScanRoots')) { $ScanRoots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) }
	$extensions = @('.ini', '.cfg', '.config', '.xml', '.conf', '.properties', '.env', '.yaml', '.yml')
	$excluded = @('Windows NT', 'Windows Kits', 'Windows Mail', 'Windows Media', 'Microsoft.NET', 'dotnet', 'Microsoft Visual C++', 'Microsoft Visual Studio', 'WindowsPowerShell', 'Windows Defender', 'Windows Security', 'Microsoft\EdgeUpdate', 'Microsoft\Edge\Application', 'Common Files\microsoft shared', 'Common Files\System', 'Common Files\Services')
	$uncPattern = [regex]'(?i)\\\\[A-Za-z0-9_-][A-Za-z0-9_.-]+'
	$fqdnPattern = [regex]'(?i)(?:server|host|hostname|address|data[\s_-]*source|datasource|endpoint|url|uri|broker|gateway|proxy)\s*[=:]\s*([A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+){1,}\.[A-Za-z]{2,})'
	$findings = @()
	foreach ($root in $ScanRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path $_) } | Sort-Object -Unique) {
		$files = @(Get-ChildItem -Path $root -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $filePath = $_.FullName; $extensions -contains $_.Extension.ToLowerInvariant() -and $_.Length -le 1MB -and -not ($excluded | Where-Object { $filePath -like "*$_*" }) })
		foreach ($file in $files) {
			try { $content = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8) } catch { continue }
			$references = @()
			foreach ($match in $uncPattern.Matches($content)) { $value = $match.Value.TrimEnd('/', '\', ' ', '"', "'"); if ($value -notmatch '\\\\(localhost|127\.|::1)') { $references += [PSCustomObject]@{ Type = 'UncPath'; Value = $value } } }
			foreach ($match in $fqdnPattern.Matches($content)) { $value = $match.Groups[1].Value.Trim('"', "'", ' ', ';', ','); if ($value -notmatch '^(localhost|127\.|0\.0\.0\.0|::1)' -and $value -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { $references += [PSCustomObject]@{ Type = 'FqdnReference'; Value = $value } } }
			if ($references.Count -gt 0) { $findings += [PSCustomObject]@{ FilePath = $file.FullName; FileName = $file.Name; SizeBytes = $file.Length; References = @($references | Group-Object -Property Type, Value | ForEach-Object { $_.Group[0] }) } }
	}
	}
	return @($findings)
}

function Get-DiscoveryAdDsDependencies {
	param([object[]]$ServiceObjects, [object[]]$ScheduledTaskObjects, [object[]]$OdbcEntries, [object[]]$TcpConnectionObjects, [string[]]$LocalAddresses, [object[]]$ConfigFileReferences)
	if (-not $PSBoundParameters.ContainsKey('ServiceObjects')) { try { $ServiceObjects = @(Get-CimInstance -ClassName Win32_Service -Property Name,DisplayName,StartName,State,StartMode -ErrorAction Stop) } catch { $ServiceObjects = @() } }
	$domainServices = @($ServiceObjects | Where-Object { $_.StartName -and $_.StartName -match '\\' -and $_.StartName -notmatch '^(LocalSystem$|NT AUTHORITY\\|NT SERVICE\\|LOCAL SERVICE$|NETWORK SERVICE$)' } | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; DisplayName = ConvertTo-DiscoveryNormalizedText $_.DisplayName; Account = $_.StartName; State = [string]$_.State; StartMode = [string]$_.StartMode } })
	if (-not $PSBoundParameters.ContainsKey('ScheduledTaskObjects')) { try { $ScheduledTaskObjects = @(Get-ScheduledTask -ErrorAction Stop) } catch { $ScheduledTaskObjects = @() } }
	$domainTasks = @($ScheduledTaskObjects | ForEach-Object { $principal = $_.Principal; $userId = if ($null -eq $principal) { $null } else { [string]$principal.UserId }; if ($userId -and $userId -match '\\' -and $userId -notmatch '^(SYSTEM$|S-1-5-18$|LOCAL SERVICE$|NETWORK SERVICE$|BUILTIN\\|NT AUTHORITY\\|NT SERVICE\\|S-1-5-)') { [PSCustomObject]@{ TaskPath = [string]$_.TaskPath; TaskName = [string]$_.TaskName; Account = $userId; RunLevel = [string]$principal.RunLevel; State = [string]$_.State } } })
	if (-not $PSBoundParameters.ContainsKey('OdbcEntries')) { $OdbcEntries = @(); foreach ($root in @('HKLM:\SOFTWARE\ODBC\ODBC.INI', 'HKLM:\SOFTWARE\WOW6432Node\ODBC\ODBC.INI')) { if (Test-Path $root) { $OdbcEntries += @(Get-ChildItem -Path $root -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -ne 'ODBC Data Sources' } | ForEach-Object { [PSCustomObject]@{ DsnName = $_.PSChildName; RegistryPath = $_.PSPath; Values = Get-DiscoveryRegistryKeyValues $_.PSPath } }) } } }
	$odbcSources = @($OdbcEntries | ForEach-Object { $values = $_.Values; $server = Get-DiscoveryOptionalPropertyValue $values 'Server'; $uid = Get-DiscoveryOptionalPropertyValue $values 'UID'; $dbq = Get-DiscoveryOptionalPropertyValue $values 'DBQ'; $driver = Get-DiscoveryOptionalPropertyValue $values 'Driver'; $serverFlag = $server -and ($server -match '\.' -or $server -match '^\\\\'); $credFlag = $uid -and $uid -match '\\'; $dbqFlag = $dbq -and $dbq -match '\\\\[A-Za-z0-9_.-]+\.[A-Za-z]{2,}|\\\\[A-Za-z0-9_-]+'; if ($serverFlag -or $credFlag -or $dbqFlag) { [PSCustomObject]@{ DsnName = $_.DsnName; RegistryPath = $_.RegistryPath; Driver = ConvertTo-DiscoveryNormalizedText $driver; Server = ConvertTo-DiscoveryNormalizedText $server; Uid = ConvertTo-DiscoveryNormalizedText $uid; Dbq = ConvertTo-DiscoveryNormalizedText $dbq; FlagReasons = @(if ($serverFlag) { 'DomainServer' }; if ($credFlag) { 'DomainCredential' }; if ($dbqFlag) { 'DomainPath' }) } } })
	$ports = @{ 88 = 'Kerberos'; 135 = 'RPC/Endpoint Mapper'; 389 = 'LDAP'; 445 = 'SMB'; 464 = 'Kerberos Password Change'; 636 = 'LDAPS'; 3268 = 'Global Catalog LDAP'; 3269 = 'Global Catalog LDAPS' }
	if (-not $PSBoundParameters.ContainsKey('TcpConnectionObjects')) { try { $TcpConnectionObjects = @(Get-NetTCPConnection -State Established -ErrorAction Stop) } catch { $TcpConnectionObjects = @() } }
	if (-not $PSBoundParameters.ContainsKey('LocalAddresses')) { $LocalAddresses = @('127.0.0.1', '::1'); try { $LocalAddresses += @([System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) | ForEach-Object { $_.ToString() }) } catch {} }
	$adConnections = @($TcpConnectionObjects | Where-Object { $ports.ContainsKey([int]$_.RemotePort) -and $_.RemoteAddress -notin $LocalAddresses } | Group-Object -Property RemoteAddress, RemotePort | ForEach-Object { $sample = $_.Group[0]; [PSCustomObject]@{ RemoteAddress = $sample.RemoteAddress; RemotePort = $sample.RemotePort; Service = $ports[[int]$sample.RemotePort]; ConnectionCount = $_.Count } })
	if (-not $PSBoundParameters.ContainsKey('ConfigFileReferences')) { $ConfigFileReferences = Get-DiscoveryConfigFileServerReferences }
	return [PSCustomObject]@{ HasDomainDependencies = $domainServices.Count -gt 0 -or $domainTasks.Count -gt 0 -or $odbcSources.Count -gt 0 -or $adConnections.Count -gt 0 -or $ConfigFileReferences.Count -gt 0; DomainServiceCount = $domainServices.Count; DomainScheduledTaskCount = $domainTasks.Count; DomainOdbcSourceCount = $odbcSources.Count; AdPortConnectionCount = $adConnections.Count; ConfigFileReferenceCount = $ConfigFileReferences.Count; DomainServices = $domainServices; DomainScheduledTasks = $domainTasks; OdbcSources = $odbcSources; AdPortConnections = $adConnections; ConfigFileServerReferences = @($ConfigFileReferences) }
}

function Get-DiscoveryADDSRoleState {
	param($ComputerSystem, [object[]]$ServiceObjects, [object[]]$ShareObjects, $Domain, $Forest, [object[]]$DomainControllers, [object[]]$ReplicationPartners)
	if (-not $PSBoundParameters.ContainsKey('ComputerSystem')) { $ComputerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop }
	if (-not $PSBoundParameters.ContainsKey('ServiceObjects')) { $ServiceObjects = @(Get-Service -Name NTDS, DNS -ErrorAction SilentlyContinue) }
	if (-not $PSBoundParameters.ContainsKey('ShareObjects')) { try { $ShareObjects = @(Get-SmbShare -ErrorAction Stop) } catch { $ShareObjects = @() } }
	$isDomainController = [int](Get-DiscoveryOptionalPropertyValue -Object $ComputerSystem -PropertyName 'DomainRole') -ge 4
	$activeDirectoryAvailable = $null -ne (Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction SilentlyContinue)
	if ($isDomainController -and $activeDirectoryAvailable) {
		Import-Module ActiveDirectory -ErrorAction SilentlyContinue
		if (-not $PSBoundParameters.ContainsKey('Domain')) { try { $Domain = Get-ADDomain -ErrorAction Stop } catch {} }
		if (-not $PSBoundParameters.ContainsKey('Forest')) { try { $Forest = Get-ADForest -ErrorAction Stop } catch {} }
		if (-not $PSBoundParameters.ContainsKey('DomainControllers')) { try { $DomainControllers = @(Get-ADDomainController -Filter * -ErrorAction Stop) } catch { $DomainControllers = @() } }
		if (-not $PSBoundParameters.ContainsKey('ReplicationPartners')) { try { $ReplicationPartners = @(Get-ADReplicationPartnerMetadata -Target $env:COMPUTERNAME -ErrorAction Stop) } catch { $ReplicationPartners = @() } }
	}
	$services = @($ServiceObjects | ForEach-Object { [PSCustomObject]@{ Name = [string]$_.Name; Status = [string]$_.Status; StartType = [string](Get-DiscoveryOptionalPropertyValue -Object $_ -PropertyName 'StartType') } })
	return [PSCustomObject]@{
		IsDomainController = $isDomainController
		ActiveDirectoryModuleAvailable = $activeDirectoryAvailable
		DirectoryServices = $services
		SysvolShared = @($ShareObjects | Where-Object { $_.Name -eq 'SYSVOL' }).Count -gt 0
		NetlogonShared = @($ShareObjects | Where-Object { $_.Name -eq 'NETLOGON' }).Count -gt 0
		Domain = [PSCustomObject]@{ DnsRoot = ConvertTo-DiscoveryNormalizedText (Get-DiscoveryOptionalPropertyValue -Object $Domain 'DNSRoot'); NetBiosName = ConvertTo-DiscoveryNormalizedText (Get-DiscoveryOptionalPropertyValue -Object $Domain 'NetBIOSName'); DomainMode = ConvertTo-DiscoveryNormalizedText (Get-DiscoveryOptionalPropertyValue -Object $Domain 'DomainMode'); PdcEmulator = ConvertTo-DiscoveryNormalizedText (Get-DiscoveryOptionalPropertyValue -Object $Domain 'PDCEmulator'); RidMaster = ConvertTo-DiscoveryNormalizedText (Get-DiscoveryOptionalPropertyValue -Object $Domain 'RIDMaster'); InfrastructureMaster = ConvertTo-DiscoveryNormalizedText (Get-DiscoveryOptionalPropertyValue -Object $Domain 'InfrastructureMaster') }
		Forest = [PSCustomObject]@{ Name = ConvertTo-DiscoveryNormalizedText (Get-DiscoveryOptionalPropertyValue -Object $Forest 'Name'); ForestMode = ConvertTo-DiscoveryNormalizedText (Get-DiscoveryOptionalPropertyValue -Object $Forest 'ForestMode'); Domains = @((Get-DiscoveryOptionalPropertyValue -Object $Forest 'Domains')); Sites = @((Get-DiscoveryOptionalPropertyValue -Object $Forest 'Sites')); SchemaMaster = ConvertTo-DiscoveryNormalizedText (Get-DiscoveryOptionalPropertyValue -Object $Forest 'SchemaMaster'); DomainNamingMaster = ConvertTo-DiscoveryNormalizedText (Get-DiscoveryOptionalPropertyValue -Object $Forest 'DomainNamingMaster') }
		DomainControllerCount = @($DomainControllers).Count
		DomainControllers = @($DomainControllers | ForEach-Object { [PSCustomObject]@{ HostName = ConvertTo-DiscoveryNormalizedText (Get-DiscoveryOptionalPropertyValue -Object $_ 'HostName'); Site = ConvertTo-DiscoveryNormalizedText (Get-DiscoveryOptionalPropertyValue -Object $_ 'Site'); IPv4Address = ConvertTo-DiscoveryNormalizedText (Get-DiscoveryOptionalPropertyValue -Object $_ 'IPv4Address'); IsGlobalCatalog = Get-DiscoveryOptionalPropertyValue -Object $_ 'IsGlobalCatalog'; IsReadOnly = Get-DiscoveryOptionalPropertyValue -Object $_ 'IsReadOnly' } })
		ReplicationPartnerCount = @($ReplicationPartners).Count
		ReplicationPartners = @($ReplicationPartners | ForEach-Object { [PSCustomObject]@{ Partner = ConvertTo-DiscoveryNormalizedText (Get-DiscoveryOptionalPropertyValue -Object $_ 'Partner'); LastReplicationSuccess = Get-DiscoveryOptionalPropertyValue -Object $_ 'LastReplicationSuccess'; LastReplicationResult = Get-DiscoveryOptionalPropertyValue -Object $_ 'LastReplicationResult'; ConsecutiveReplicationFailures = Get-DiscoveryOptionalPropertyValue -Object $_ 'ConsecutiveReplicationFailures' } })
	}
}

Export-ModuleMember -Function @('Get-DiscoveryConfigFileServerReferences', 'Get-DiscoveryAdDsDependencies', 'Get-DiscoveryADDSRoleState')