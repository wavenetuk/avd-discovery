Set-StrictMode -Version Latest

function ConvertTo-DiscoveryNormalizedText {
	param(
		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[string]$Value
	)

	if ([string]::IsNullOrWhiteSpace($Value)) {
		return $null
	}

	return (($Value -replace '\s+', ' ').Trim())
}

function Get-DiscoveryOptionalPropertyValue {
	param(
		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[object]$Object,

		[Parameter(Mandatory = $true)]
		[string]$PropertyName
	)

	if ($null -eq $Object) {
		return $null
	}

	$property = $Object.PSObject.Properties[$PropertyName]
	if ($null -eq $property) {
		return $null
	}

	return $property.Value
}

function Get-DiscoveryMachineDetails {
	param(
		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[object]$ComputerSystem
	)

	if ($null -eq $ComputerSystem) {
		$ComputerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
	}

	$hostname = ConvertTo-DiscoveryNormalizedText -Value $ComputerSystem.Name
	$domain = ConvertTo-DiscoveryNormalizedText -Value $ComputerSystem.Domain
	if (-not [bool]$ComputerSystem.PartOfDomain) {
		$domain = ConvertTo-DiscoveryNormalizedText -Value (Get-DiscoveryOptionalPropertyValue -Object $ComputerSystem -PropertyName 'Workgroup')
	}

	return [PSCustomObject]@{
		Hostname     = $hostname
		Domain       = $domain
		PartOfDomain = [bool]$ComputerSystem.PartOfDomain
		Manufacturer = ConvertTo-DiscoveryNormalizedText -Value $ComputerSystem.Manufacturer
		Model        = ConvertTo-DiscoveryNormalizedText -Value $ComputerSystem.Model
	}
}

function Get-DiscoveryRegistryKeyValues {
	param([Parameter(Mandatory = $true)][string]$Path)
	if (-not (Test-Path -Path $Path)) { return $null }
	$item = Get-ItemProperty -Path $Path -ErrorAction Stop
	$values = [ordered]@{}
	foreach ($property in $item.PSObject.Properties) {
		if ($property.Name -notlike 'PS*') { $values[$property.Name] = $property.Value }
	}
	return [PSCustomObject]$values
}

function Merge-DiscoveryConfigurationObjects {
	param($BaseObject, $OverrideObject)
	$merged = [ordered]@{}
	foreach ($source in @($BaseObject, $OverrideObject)) {
		if ($null -ne $source) {
			foreach ($property in $source.PSObject.Properties) { $merged[$property.Name] = $property.Value }
		}
	}
	return [PSCustomObject]$merged
}

function Get-DiscoveryTimeSource {
	param($PolicyParameters, $LocalParameters, [string[]]$StatusLines)
	if (-not $PSBoundParameters.ContainsKey('PolicyParameters')) { $PolicyParameters = Get-DiscoveryRegistryKeyValues -Path 'HKLM:\SOFTWARE\Policies\Microsoft\W32Time\Parameters' }
	if (-not $PSBoundParameters.ContainsKey('LocalParameters')) { $LocalParameters = Get-DiscoveryRegistryKeyValues -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters' }
	if (-not $PSBoundParameters.ContainsKey('StatusLines')) { $StatusLines = @(w32tm.exe /query /status 2>$null) }
	$params = Merge-DiscoveryConfigurationObjects -BaseObject $LocalParameters -OverrideObject $PolicyParameters
	$configuredSource = ConvertTo-DiscoveryNormalizedText -Value (Get-DiscoveryOptionalPropertyValue -Object $params -PropertyName 'NtpServer')
	$type = ConvertTo-DiscoveryNormalizedText -Value (Get-DiscoveryOptionalPropertyValue -Object $params -PropertyName 'Type')
	$currentSource = $null; $stratum = $null; $lastSyncTime = $null; $lastSyncError = $null
	foreach ($line in $StatusLines) {
		if ($line -match '^Source\s*:\s*(.+)$') { $currentSource = $matches[1].Trim() }
		elseif ($line -match '^Stratum\s*:\s*(\d+)') { $stratum = [int]$matches[1] }
		elseif ($line -match '^Last Successful Sync Time\s*:\s*(.+)$') { $lastSyncTime = $matches[1].Trim() }
		elseif ($line -match '^Last Sync Error\s*:\s*(.+)$') { $lastSyncError = $matches[1].Trim() }
	}
	return [PSCustomObject]@{ ConfiguredSource = $configuredSource; ConfiguredType = $type; CurrentSource = $currentSource; Stratum = $stratum; LastSyncTime = $lastSyncTime; LastSyncError = if ($lastSyncError -eq '0x0') { $null } else { $lastSyncError }; NtpPolicyDetected = $null -ne $PolicyParameters; Error = $null }
}

function ConvertTo-DiscoveryInstallDate {
	param([AllowNull()][string]$RawDate)
	if ([string]::IsNullOrWhiteSpace($RawDate)) { return $null }
	foreach ($pattern in @('yyyyMMdd', 'yyyy-MM-dd', 'MM/dd/yyyy', 'dd/MM/yyyy')) {
		try { return ([datetime]::ParseExact($RawDate.Trim(), $pattern, $null)).ToString('yyyy-MM-dd') }
		catch { continue }
	}
	try { return ([datetime]::Parse($RawDate)).ToString('yyyy-MM-dd') }
	catch { return $RawDate }
}

function Test-DiscoveryInstalledApplicationEntry {
	param([Parameter(Mandatory = $true)][object]$RegistryEntry)
	$displayName = ConvertTo-DiscoveryNormalizedText -Value (Get-DiscoveryOptionalPropertyValue -Object $RegistryEntry -PropertyName 'DisplayName')
	if ([string]::IsNullOrWhiteSpace($displayName)) { return $false }
	if ((Get-DiscoveryOptionalPropertyValue -Object $RegistryEntry -PropertyName 'SystemComponent') -eq 1) { return $false }
	if (-not [string]::IsNullOrWhiteSpace((ConvertTo-DiscoveryNormalizedText -Value (Get-DiscoveryOptionalPropertyValue -Object $RegistryEntry -PropertyName 'ParentKeyName')))) { return $false }
	if ((ConvertTo-DiscoveryNormalizedText -Value (Get-DiscoveryOptionalPropertyValue -Object $RegistryEntry -PropertyName 'ReleaseType')) -in @('Hotfix', 'Update', 'Security Update')) { return $false }
	return $displayName -notmatch '^KB\d+'
}

function Get-DiscoveryInstalledApplications {
	param(
		[Parameter(Mandatory = $false)]
		[object[]]$RegistryEntries,

		[Parameter(Mandatory = $false)]
		[scriptblock]$ApplicationFilter
	)
	if (-not $PSBoundParameters.ContainsKey('RegistryEntries')) {
		$paths = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
		$RegistryEntries = @($paths | ForEach-Object { Get-ItemProperty -Path $_ -ErrorAction SilentlyContinue })
	}

	$applications = @($RegistryEntries | Where-Object { Test-DiscoveryInstalledApplicationEntry -RegistryEntry $_ } | ForEach-Object {
		$application = [PSCustomObject]@{
			Name = ConvertTo-DiscoveryNormalizedText -Value (Get-DiscoveryOptionalPropertyValue -Object $_ -PropertyName 'DisplayName')
			Publisher = ConvertTo-DiscoveryNormalizedText -Value (Get-DiscoveryOptionalPropertyValue -Object $_ -PropertyName 'Publisher')
			InstallDate = ConvertTo-DiscoveryInstallDate -RawDate (Get-DiscoveryOptionalPropertyValue -Object $_ -PropertyName 'InstallDate')
			Version = ConvertTo-DiscoveryNormalizedText -Value (Get-DiscoveryOptionalPropertyValue -Object $_ -PropertyName 'DisplayVersion')
		}
		if ($null -eq $ApplicationFilter -or (& $ApplicationFilter $application)) { $application }
	})
	return @($applications | Sort-Object -Property Name, Publisher, Version -Unique)
}

function Get-DiscoveryDefenderForEndpointStatus {
	param($StatusValues, $SenseService)
	$statusPath = 'HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status'
	if (-not $PSBoundParameters.ContainsKey('StatusValues')) { $StatusValues = Get-DiscoveryRegistryKeyValues -Path $statusPath }
	if (-not $PSBoundParameters.ContainsKey('SenseService')) { $SenseService = Get-Service -Name Sense -ErrorAction SilentlyContinue }
	$stateValue = Get-DiscoveryOptionalPropertyValue -Object $StatusValues -PropertyName 'OnboardingState'
	$orgId = Get-DiscoveryOptionalPropertyValue -Object $StatusValues -PropertyName 'OrgId'
	$onboarded = if ($null -eq $stateValue) { $null } else { [int]$stateValue -eq 1 }
	return [PSCustomObject]@{ Detected = ($null -ne $StatusValues) -or ($null -ne $SenseService) -or ($null -ne $stateValue) -or (-not [string]::IsNullOrWhiteSpace($orgId)); Onboarded = $onboarded; OnboardingState = if ($null -eq $onboarded) { 'Unknown' } elseif ($onboarded) { 'Onboarded' } else { 'Not Onboarded' }; OnboardingStateValue = $stateValue; OrgId = $orgId; SenseServiceInstalled = $null -ne $SenseService; SenseServiceStatus = if ($null -ne $SenseService) { [string]$SenseService.Status } else { 'NotInstalled' }; SenseServiceStartType = if ($null -ne $SenseService) { [string]$SenseService.StartType } else { $null }; RegistryPath = $statusPath }
}

function Get-DiscoveryAntivirus {
	param($InstalledApplications = @(), $SecurityCenterProducts, $DefenderStatus, $DefenderForEndpoint)
	if (-not $PSBoundParameters.ContainsKey('DefenderForEndpoint')) { $DefenderForEndpoint = Get-DiscoveryDefenderForEndpointStatus }
	if (-not $PSBoundParameters.ContainsKey('SecurityCenterProducts')) {
		try { $SecurityCenterProducts = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntivirusProduct -ErrorAction Stop) } catch { $SecurityCenterProducts = @() }
	}
	$products = @($SecurityCenterProducts | ForEach-Object { [PSCustomObject]@{ DisplayName = ConvertTo-DiscoveryNormalizedText -Value $_.displayName; InstanceGuid = ConvertTo-DiscoveryNormalizedText -Value $_.instanceGuid; PathToSignedProductExe = ConvertTo-DiscoveryNormalizedText -Value $_.pathToSignedProductExe; PathToSignedReportingExe = ConvertTo-DiscoveryNormalizedText -Value $_.pathToSignedReportingExe; ProductState = Get-DiscoveryOptionalPropertyValue -Object $_ -PropertyName 'productState' } })
	if (-not $PSBoundParameters.ContainsKey('DefenderStatus') -and $null -ne (Get-Command -Name Get-MpComputerStatus -ErrorAction SilentlyContinue)) { try { $DefenderStatus = Get-MpComputerStatus -ErrorAction Stop } catch { $DefenderStatus = $null } }
	if ($null -ne $DefenderStatus) { $DefenderStatus = [PSCustomObject]@{ AMServiceEnabled = Get-DiscoveryOptionalPropertyValue $DefenderStatus 'AMServiceEnabled'; AntispywareEnabled = Get-DiscoveryOptionalPropertyValue $DefenderStatus 'AntispywareEnabled'; AntivirusEnabled = Get-DiscoveryOptionalPropertyValue $DefenderStatus 'AntivirusEnabled'; RealTimeProtectionEnabled = Get-DiscoveryOptionalPropertyValue $DefenderStatus 'RealTimeProtectionEnabled'; NISEnabled = Get-DiscoveryOptionalPropertyValue $DefenderStatus 'NISEnabled'; QuickScanAge = Get-DiscoveryOptionalPropertyValue $DefenderStatus 'QuickScanAge'; FullScanAge = Get-DiscoveryOptionalPropertyValue $DefenderStatus 'FullScanAge' } }
	$pattern = 'Defender|CrowdStrike|SentinelOne|Sophos|Trend Micro|McAfee|Symantec|Norton|ESET|Bitdefender|Avast|AVG|Carbon Black|Cylance|Malwarebytes|Trellix|Secure Endpoint|Microsoft Defender'
	$matches = @($InstalledApplications | Where-Object { $_.Name -match $pattern -or $_.Publisher -match $pattern } | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; Publisher = $_.Publisher; Version = $_.Version } })
	if ($products.Count -eq 0 -and $null -ne $DefenderStatus -and $matches.Count -eq 0) { $matches = @([PSCustomObject]@{ Name = 'Microsoft Defender Antivirus'; Publisher = 'Microsoft Defender Antivirus'; Version = if ($DefenderStatus.AntivirusEnabled -eq $true) { 'Enabled' } elseif ($DefenderStatus.AntivirusEnabled -eq $false) { 'Disabled' } else { 'Unknown' } }) }
	return [PSCustomObject]@{ DefenderForEndpoint = $DefenderForEndpoint; SecurityCenterProducts = $products; SecurityCenterDetected = $products.Count -gt 0 -or $null -ne $DefenderStatus -or $DefenderForEndpoint.Detected; WindowsDefender = $DefenderStatus; InstalledApplicationMatches = $matches; Detected = $products.Count -gt 0 -or $null -ne $DefenderStatus -or $matches.Count -gt 0 -or $DefenderForEndpoint.Detected }
}

function Get-DiscoveryPrinterInventory {
	param([object[]]$PrinterObjects, [object[]]$DriverObjects)
	$errorMessage = $null
	if (-not $PSBoundParameters.ContainsKey('PrinterObjects')) { try { $PrinterObjects = @(Get-Printer -ErrorAction Stop) } catch { $errorMessage = $_.Exception.Message; $PrinterObjects = @() } }
	if (-not $PSBoundParameters.ContainsKey('DriverObjects')) { try { $DriverObjects = @(Get-PrinterDriver -ErrorAction Stop) } catch { $DriverObjects = @() } }
	$driverMap = @{}
	foreach ($driver in $DriverObjects) { $driverMap[$driver.Name] = $driver }
	$printers = @($PrinterObjects | ForEach-Object {
		$driverName = ConvertTo-DiscoveryNormalizedText -Value $_.DriverName
		$driver = if (-not [string]::IsNullOrWhiteSpace($driverName) -and $driverMap.ContainsKey($driverName)) { $driverMap[$driverName] } else { $null }
		[PSCustomObject]@{ Name = ConvertTo-DiscoveryNormalizedText -Value $_.Name; DriverName = $driverName; DriverVersion = if ($null -eq $driver) { $null } else { ConvertTo-DiscoveryNormalizedText -Value (Get-DiscoveryOptionalPropertyValue $driver 'DriverVersion') }; DriverProvider = if ($null -eq $driver) { $null } else { ConvertTo-DiscoveryNormalizedText -Value (Get-DiscoveryOptionalPropertyValue $driver 'Manufacturer') }; PortName = ConvertTo-DiscoveryNormalizedText -Value $_.PortName; Shared = $_.Shared; ShareName = if ($_.Shared) { ConvertTo-DiscoveryNormalizedText -Value $_.ShareName } else { $null }; PrinterStatus = [string]$_.PrinterStatus; Type = if ($_.PortName -like 'USB*') { 'Local-USB' } elseif ($_.PortName -like '\\*' -or $_.PortName -like 'WSD*') { 'Network' } elseif ($_.DriverName -eq 'Universal Print Class Driver') { 'UniversalPrint' } elseif ($_.PortName -eq 'PORTPROMPT:' -or $_.PortName -eq 'FILE:') { 'Virtual' } else { 'Other' } }
	})
	return [PSCustomObject]@{ PrinterCount = $printers.Count; Printers = $printers; Error = $errorMessage }
}

function Get-DiscoveryCommandOutputLines {
	param([Parameter(Mandatory = $true)][string]$Command, [string[]]$Arguments = @())
	try { return @(& $Command @Arguments 2>$null) }
	catch { return @() }
}

function Get-DiscoveryLanguagePacks {
	param($CapabilityObjects, [string[]]$DismLines, [string[]]$InstalledUiLanguages, $CurrentUserLanguages, [AllowNull()][string]$SystemLocale, [AllowNull()][string]$UiLanguageOverride)
	$installedCapabilities = @(); $capabilityQuerySucceeded = $false; $capabilityQueryError = $null
	if ($PSBoundParameters.ContainsKey('CapabilityObjects')) { $capabilityQuerySucceeded = $true }
	elseif ($null -ne (Get-Command -Name Get-WindowsCapability -ErrorAction SilentlyContinue)) { try { $CapabilityObjects = @(Get-WindowsCapability -Online -ErrorAction Stop); $capabilityQuerySucceeded = $true } catch { $capabilityQueryError = $_.Exception.Message } }
	if ($null -ne $CapabilityObjects) { $installedCapabilities = @($CapabilityObjects | Where-Object { $_.Name -like 'Language.*~~~*' -and $_.State -eq 'Installed' } | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; State = $_.State; Language = if ($_.Name -match '~~~([a-z]{2}-[A-Z]{2})~') { $matches[1] } else { $null } } }) }
	if (-not $capabilityQuerySucceeded) {
		if (-not $PSBoundParameters.ContainsKey('DismLines')) { $DismLines = Get-DiscoveryCommandOutputLines -Command 'dism.exe' -Arguments @('/Online', '/English', '/Get-Capabilities') }
		$currentCapabilityName = $null
		foreach ($line in $DismLines) {
			if ($line -match '^Capability Identity\s*:\s*(.+)$') { $currentCapabilityName = $matches[1].Trim(); continue }
			if ($line -match '^State\s*:\s*(.+)$') { $state = $matches[1].Trim(); if (-not [string]::IsNullOrWhiteSpace($currentCapabilityName) -and $currentCapabilityName -like 'Language.*~~~*' -and $state -eq 'Installed') { $installedCapabilities += [PSCustomObject]@{ Name = $currentCapabilityName; State = $state; Language = if ($currentCapabilityName -match '~~~([a-z]{2}-[A-Z]{2})~') { $matches[1] } else { $null } } }; $currentCapabilityName = $null }
		}
		if ($installedCapabilities.Count -gt 0) { $capabilityQuerySucceeded = $true }
	}
	if (-not $PSBoundParameters.ContainsKey('InstalledUiLanguages')) { try { $InstalledUiLanguages = @(Get-ChildItem -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MUI\UILanguages' -ErrorAction Stop | Select-Object -ExpandProperty PSChildName) } catch { $InstalledUiLanguages = @() } }
	if (-not $PSBoundParameters.ContainsKey('CurrentUserLanguages')) { if ($null -ne (Get-Command -Name Get-WinUserLanguageList -ErrorAction SilentlyContinue)) { try { $CurrentUserLanguages = @(Get-WinUserLanguageList | ForEach-Object { [PSCustomObject]@{ LanguageTag = $_.LanguageTag; Autonym = $_.Autonym; EnglishName = $_.EnglishName } }) } catch { $CurrentUserLanguages = @() } } else { $CurrentUserLanguages = @() } }
	if (-not $PSBoundParameters.ContainsKey('SystemLocale') -and $null -ne (Get-Command -Name Get-WinSystemLocale -ErrorAction SilentlyContinue)) { $SystemLocale = (Get-WinSystemLocale).Name }
	if (-not $PSBoundParameters.ContainsKey('UiLanguageOverride') -and $null -ne (Get-Command -Name Get-WinUILanguageOverride -ErrorAction SilentlyContinue)) { $UiLanguageOverride = Get-WinUILanguageOverride }
	return [PSCustomObject]@{ CapabilityQuerySucceeded = $capabilityQuerySucceeded; CapabilityQueryError = $capabilityQueryError; InstalledLanguageCapabilities = $installedCapabilities; InstalledLanguageTags = @($installedCapabilities | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Language) } | Select-Object -ExpandProperty Language -Unique); InstalledUiLanguages = @($InstalledUiLanguages); CurrentUserLanguages = @($CurrentUserLanguages); SystemLocale = $SystemLocale; UiLanguageOverride = $UiLanguageOverride }
}

function Get-DiscoveryUniversalPrint {
	param($ConnectorService, $ConnectorConfig, [string[]]$MonitorPorts, [object[]]$PrinterObjects)
	if (-not $PSBoundParameters.ContainsKey('ConnectorService')) { $ConnectorService = Get-Service -Name UniversalPrintConnector -ErrorAction SilentlyContinue }
	if (-not $PSBoundParameters.ContainsKey('ConnectorConfig')) { $ConnectorConfig = Get-DiscoveryRegistryKeyValues -Path 'HKLM:\SOFTWARE\Microsoft\UniversalPrintConnector' }
	if (-not $PSBoundParameters.ContainsKey('MonitorPorts')) { try { $MonitorPorts = @(Get-ChildItem -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors\Universal Print Monitor\Ports' -ErrorAction Stop | Select-Object -ExpandProperty PSChildName) } catch { $MonitorPorts = @() } }
	if (-not $PSBoundParameters.ContainsKey('PrinterObjects')) { try { $PrinterObjects = @(Get-Printer -ErrorAction Stop) } catch { $PrinterObjects = @() } }
	$cloudPrinters = @($PrinterObjects | Where-Object { $_.DriverName -eq 'Universal Print Class Driver' -or $_.PortName -in $MonitorPorts } | ForEach-Object { [PSCustomObject]@{ Name = ConvertTo-DiscoveryNormalizedText -Value $_.Name; DriverName = ConvertTo-DiscoveryNormalizedText -Value $_.DriverName; PortName = ConvertTo-DiscoveryNormalizedText -Value $_.PortName; Shared = $_.Shared; PrinterStatus = [string]$_.PrinterStatus } })
	$connectorRegistered = $null -ne $ConnectorService -or $null -ne $ConnectorConfig
	return [PSCustomObject]@{ InUse = $connectorRegistered -or $cloudPrinters.Count -gt 0; ConnectorInstalled = $null -ne $ConnectorService; ConnectorServiceStatus = if ($null -eq $ConnectorService) { 'NotInstalled' } else { [string]$ConnectorService.Status }; ConnectorConfigDetected = $null -ne $ConnectorConfig; ConnectorConfig = $ConnectorConfig; CloudPrinterCount = $cloudPrinters.Count; CloudPrinters = $cloudPrinters; UpMonitorPortCount = @($MonitorPorts).Count }
}

function Get-DiscoveryLoadedUserProfiles {
	param([object[]]$ProfileObjects, [string[]]$LoadedSids, [scriptblock]$AccountNameResolver)
	if (-not $PSBoundParameters.ContainsKey('ProfileObjects')) { $ProfileObjects = @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue) }
	if (-not $PSBoundParameters.ContainsKey('LoadedSids')) { $LoadedSids = @(Get-ChildItem -Path 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue | ForEach-Object { Split-Path -Path $_.Name -Leaf } | Where-Object { $_ -match '^S-1-(5-21|12-1)-' -and $_ -notin @('S-1-5-18', 'S-1-5-19', 'S-1-5-20') -and $_ -notlike '*_Classes' }) }
	$profileMap = @{}; foreach ($profile in $ProfileObjects | Where-Object { -not [string]::IsNullOrWhiteSpace($_.SID) }) { $profileMap[$profile.SID] = $profile }
	return @($LoadedSids | ForEach-Object { $sid = $_; $accountName = $sid; try { $accountName = if ($null -ne $AccountNameResolver) { & $AccountNameResolver $sid } else { ([System.Security.Principal.SecurityIdentifier]$sid).Translate([System.Security.Principal.NTAccount]).Value } } catch {}; $profile = if ($profileMap.ContainsKey($sid)) { $profileMap[$sid] } else { $null }; [PSCustomObject]@{ Sid = $sid; AccountName = $accountName; ProfilePath = if ($null -eq $profile) { $null } else { $profile.LocalPath }; Loaded = if ($null -eq $profile) { $true } else { [bool]$profile.Loaded } } })
}

function Get-DiscoveryUserMappedDriveState {
	param([Parameter(Mandatory = $true)][string]$Sid, [AllowNull()][string]$AccountName, [object[]]$DriveRegistryEntries)
	$networkRegistryPath = "Registry::HKEY_USERS\$Sid\Network"
	if (-not $PSBoundParameters.ContainsKey('DriveRegistryEntries')) { if (-not (Test-Path -Path $networkRegistryPath)) { $DriveRegistryEntries = @() } else { $DriveRegistryEntries = @(Get-ChildItem -Path $networkRegistryPath -ErrorAction SilentlyContinue | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; RegistryKeyPath = $_.PSPath; Values = Get-DiscoveryRegistryKeyValues -Path $_.PSPath } }) } }
	$mappedDrives = @($DriveRegistryEntries | ForEach-Object { $driveLetter = Split-Path -Path $_.Name -Leaf; $values = Get-DiscoveryOptionalPropertyValue $_ 'Values'; [PSCustomObject]@{ DriveLetter = if ([string]::IsNullOrWhiteSpace($driveLetter)) { $null } else { '{0}:' -f $driveLetter.TrimEnd(':') }; RemotePath = ConvertTo-DiscoveryNormalizedText -Value (Get-DiscoveryOptionalPropertyValue $values 'RemotePath'); UserName = ConvertTo-DiscoveryNormalizedText -Value (Get-DiscoveryOptionalPropertyValue $values 'UserName'); ProviderName = ConvertTo-DiscoveryNormalizedText -Value (Get-DiscoveryOptionalPropertyValue $values 'ProviderName'); ProviderType = Get-DiscoveryOptionalPropertyValue $values 'ProviderType'; ConnectionType = Get-DiscoveryOptionalPropertyValue $values 'ConnectionType'; DeferFlags = Get-DiscoveryOptionalPropertyValue $values 'DeferFlags'; RegistryKeyPath = Get-DiscoveryOptionalPropertyValue $_ 'RegistryKeyPath' } })
	return [PSCustomObject]@{ Sid = $Sid; AccountName = $AccountName; RegistryPath = $networkRegistryPath; MappedDrivesPresent = $mappedDrives.Count -gt 0; MappedDriveCount = $mappedDrives.Count; MappedDrives = $mappedDrives }
}

Export-ModuleMember -Function @(
	'ConvertTo-DiscoveryNormalizedText',
	'Get-DiscoveryOptionalPropertyValue',
	'Get-DiscoveryMachineDetails',
	'Get-DiscoveryRegistryKeyValues',
	'Merge-DiscoveryConfigurationObjects',
	'Get-DiscoveryTimeSource',
	'ConvertTo-DiscoveryInstallDate',
	'Test-DiscoveryInstalledApplicationEntry',
	'Get-DiscoveryInstalledApplications',
	'Get-DiscoveryDefenderForEndpointStatus',
	'Get-DiscoveryAntivirus',
	'Get-DiscoveryPrinterInventory',
	'Get-DiscoveryLanguagePacks',
	'Get-DiscoveryUniversalPrint',
	'Get-DiscoveryLoadedUserProfiles',
	'Get-DiscoveryUserMappedDriveState'
)