[CmdletBinding()]
<#
.SYNOPSIS
Discovers installed Windows applications and key AVD host configuration details and exports the results to JSON.

.DESCRIPTION
This script inventories installed applications from the standard Windows uninstall registry locations for both machine-wide and per-user installs.
It also inspects host-side profile-management settings that are not available from the Azure management plane, including FSLogix configuration, FSLogix profile container locations and sizes, OneDrive Known Folder Move policy indicators, and per-user folder redirection signals.
It exports application data, customer abbreviation, collection timestamp, machine identity, and the discovered host configuration details.
The primary-application exclusion filters are loaded from config/appExclusions.config.json (in the repository root) so they can be updated without editing PowerShell code.

By default, the script removes hidden system components, child installer entries, and Windows update-style records that do not normally belong in a migration inventory.
Use -PrimaryApplicationsOnly to apply a stricter filter that further suppresses common runtimes, redistributables, helper components, add-ins, and support packages so the output focuses on top-level applications.
Use -NoGpresult to skip the gpresult /h HTML export, for example when running in a context where Group Policy data is unavailable or to reduce collection time.
Use -SkipConnectivityChecks to skip the AVD endpoint connectivity tests, useful when running locally during development or in environments where the timeout-based failures would slow the run down.

.PARAMETER OutputDirectory
Directory where the JSON export file will be written. Defaults to the directory containing this script.

.PARAMETER CustomerAbbreviation
Short customer code used in the export filename. If omitted, the script prompts for it.

.PARAMETER PrimaryApplicationsOnly
Applies stricter filtering to keep the inventory focused on primary installed applications rather than supporting components.

.PARAMETER NoGpresult
Skips the gpresult /h HTML export. Use this when running without access to Group Policy data or to reduce collection time.

.PARAMETER SkipConnectivityChecks
Skips the AVD endpoint connectivity tests. Use this to speed up local development test runs.

SAFETY FEATURES
  1. AST denylist assertion — the script parses its own source code at startup and throws
     before doing any discovery if a cmdlet that could mutate system or filesystem state is
     found outside the small set of permitted output-writing operations. Catches accidental
     write operations introduced by future edits before any discovery work is performed.
     Denied cmdlets: Set-ItemProperty, Remove-ItemProperty, Clear-ItemProperty,
     Set-Item (registry/filesystem mutations), Invoke-Expression, Set-Service, Stop-Service,
     Start-Service, Set-ExecutionPolicy, Register-ScheduledTask, Unregister-ScheduledTask.
     Permitted output operations (explicitly exempted): New-Item (output directory creation),
     Set-Content (JSON export), Move-Item (gpresult HTML relocation), Remove-Item (gpresult
     temp file cleanup).

  2. FSLogix share access is read-only — profile container paths are scanned using
     Get-ChildItem with -File to enumerate VHD/VHDX files and read their Length property.
     No files are opened, modified, or deleted.

.EXAMPLE
.\Invoke-AvdSessionHostAudit.ps1

.EXAMPLE
.\Invoke-AvdSessionHostAudit.ps1 -CustomerAbbreviation kcr

.EXAMPLE
.\Invoke-AvdSessionHostAudit.ps1 -CustomerAbbreviation kcr -PrimaryApplicationsOnly -OutputDirectory .\exports

.EXAMPLE
.\Invoke-AvdSessionHostAudit.ps1 -CustomerAbbreviation kcr -NoGpresult
#>
param(
	[Parameter(Mandatory = $false)]
	[string]$OutputDirectory = "",

	[Parameter(Mandatory = $false)]
	[string]$CustomerAbbreviation,

	[Parameter(Mandatory = $false)]
	[switch]$PrimaryApplicationsOnly,

	[Parameter(Mandatory = $false)]
	[switch]$NoGpresult,

	[Parameter(Mandatory = $false)]
	[switch]$SkipConnectivityChecks,

	[Parameter(Mandatory = $false)]
	[string]$GeneratedBy,

	[Parameter(Mandatory = $false)]
	[string]$ProjectCode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:PrimaryApplicationConfig = $null

# ------------------------------------------------------------------
# Read-only safeguards
# ------------------------------------------------------------------

function Assert-ScriptIsReadOnly {
	<#
	.SYNOPSIS
	Parses this script's AST and throws if any cmdlet that could mutate system or
	filesystem state is detected outside the permitted output-writing operations.
	Catches accidental write operations introduced by future edits before any
	discovery work is performed.
	#>

	# Cmdlets with no legitimate use in a read-only discovery script.
	$deniedCmdlets = @(
		'Set-ItemProperty',         # registry/filesystem property mutation
		'Remove-ItemProperty',      # registry property deletion
		'Clear-ItemProperty',       # registry property clear
		'Set-Item',                 # registry/filesystem value mutation
		'Invoke-Expression',        # arbitrary code execution
		'Set-Service',              # Windows service configuration
		'Stop-Service',             # Windows service state change
		'Start-Service',            # Windows service state change
		'Set-ExecutionPolicy',      # machine/user policy change
		'Register-ScheduledTask',   # scheduled task creation
		'Unregister-ScheduledTask'  # scheduled task deletion
	)

	# These cmdlets write output files only — they are intentional and permitted.
	# New-Item       : creates the output directory
	# Set-Content    : writes the JSON export
	# Move-Item      : relocates gpresult HTML from temp to output path
	# Remove-Item    : deletes the gpresult temp file
	$permittedWriteCmdlets = @('New-Item', 'Set-Content', 'Move-Item', 'Remove-Item')

	$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile(
		$PSCommandPath,
		[ref]$null,
		[ref]$null
	)

	$commandNodes = $scriptAst.FindAll(
		{ param($node) $node -is [System.Management.Automation.Language.CommandAst] },
		$true
	)

	$violations = foreach ($node in $commandNodes) {
		$name = $node.GetCommandName()
		if ($name -and $name -in $deniedCmdlets) { $name }
	}

	if ($violations) {
		throw (
			'Read-only assertion failed. The following cmdlet(s) are on the mutation denylist ' +
			'and must be reviewed before this script can run: ' +
			(($violations | Sort-Object -Unique) -join ', ')
		)
	}
}

function Get-OptionalPropertyValue {
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

function Get-NormalizedText {
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

function Convert-ToStringArray {
	param(
		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[object]$Value
	)

	if ($null -eq $Value) {
		return @()
	}

	if ($Value -is [System.Array]) {
		return @($Value | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [string]$_ })
	}

	if ([string]::IsNullOrWhiteSpace([string]$Value)) {
		return @()
	}

	return @([string]$Value)
}

function Get-RegistryKeyValues {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Path
	)

	if (-not (Test-Path -Path $Path)) {
		return $null
	}

	$item = Get-ItemProperty -Path $Path -ErrorAction Stop
	$values = [ordered]@{}

	foreach ($property in $item.PSObject.Properties) {
		if ($property.Name -like 'PS*') {
			continue
		}

		$values[$property.Name] = $property.Value
	}

	return [PSCustomObject]$values
}

function Merge-ConfigurationObjects {
	param(
		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[object]$BaseObject,

		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[object]$OverrideObject
	)

	$merged = [ordered]@{}

	foreach ($source in @($BaseObject, $OverrideObject)) {
		if ($null -eq $source) {
			continue
		}

		foreach ($property in $source.PSObject.Properties) {
			$merged[$property.Name] = $property.Value
		}
	}

	return [PSCustomObject]$merged
}

function Resolve-UserValuePath {
	param(
		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[string]$Value,

		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[string]$ProfilePath
	)

	$normalizedValue = Get-NormalizedText -Value $Value
	if ([string]::IsNullOrWhiteSpace($normalizedValue)) {
		return $null
	}

	$resolvedValue = $normalizedValue
	if (-not [string]::IsNullOrWhiteSpace($ProfilePath)) {
		$resolvedValue = $resolvedValue -replace '%USERPROFILE%', [System.Text.RegularExpressions.Regex]::Escape($ProfilePath)
		$resolvedValue = $resolvedValue -replace '%USERNAME%', [System.Text.RegularExpressions.Regex]::Escape((Split-Path -Path $ProfilePath -Leaf))
	}

	return [Environment]::ExpandEnvironmentVariables($resolvedValue)
}

function ConvertTo-BytesToGigabytes {
	param(
		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[double]$Bytes
	)

	if ($null -eq $Bytes) {
		return $null
	}

	return [Math]::Round(($Bytes / 1GB), 2)
}

function Get-PathInventoryItem {
	param(
		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[string]$Path,

		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[string]$TypeHint
	)

	$normalizedPath = Get-NormalizedText -Value $Path
	if ([string]::IsNullOrWhiteSpace($normalizedPath)) {
		return $null
	}

	$exists = $false
	$isDirectory = $false
	$isFile = $false
	$sizeBytes = $null
	$lastWriteTime = $null
	$errorMessage = $null

	try {
		$exists = Test-Path -Path $normalizedPath
		if ($exists) {
			$item = Get-Item -Path $normalizedPath -ErrorAction Stop
			$isDirectory = $item.PSIsContainer
			$isFile = -not $item.PSIsContainer
			if ($isFile) {
				$sizeBytes = [int64]$item.Length
			}
			$lastWriteTime = $item.LastWriteTime.ToString('s')
		}
	}
	catch {
		$errorMessage = $_.Exception.Message
	}

	[PSCustomObject]@{
		Path          = $normalizedPath
		TypeHint      = $TypeHint
		Exists        = $exists
		IsDirectory   = $isDirectory
		IsFile        = $isFile
		SizeBytes     = $sizeBytes
		SizeGB        = ConvertTo-BytesToGigabytes -Bytes $sizeBytes
		LastWriteTime = $lastWriteTime
		Error         = $errorMessage
	}
}

function Get-CommandOutputLines {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Command,

		[Parameter(Mandatory = $false)]
		[string[]]$Arguments = @()
	)

	$commandInfo = Get-Command -Name $Command -ErrorAction SilentlyContinue
	if ($null -eq $commandInfo) {
		return @()
	}

	try {
		return @(& $commandInfo.Source @Arguments 2>$null)
	}
	catch {
		return @()
	}
}

function ConvertTo-BooleanFromText {
	param(
		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[string]$Value
	)

	$normalizedValue = Get-NormalizedText -Value $Value
	if ([string]::IsNullOrWhiteSpace($normalizedValue)) {
		return $null
	}

	switch -Regex ($normalizedValue) {
		'^(YES|TRUE)$' { return $true }
		'^(NO|FALSE)$' { return $false }
		default { return $null }
	}
}

function Get-DsRegStatus {
	$lines = Get-CommandOutputLines -Command 'dsregcmd.exe' -Arguments @('/status')
	if (@($lines).Count -eq 0) {
		return $null
	}

	$interestingKeys = @(
		'AzureAdJoined',
		'EnterpriseJoined',
		'DomainJoined',
		'DomainName',
		'DeviceId',
		'TenantId',
		'TenantName',
		'WorkplaceJoined',
		'VirtualDesktop',
		'AzureAdPrt',
		'AzureAdPrtExpiryTime',
		'AzureAdPrtAuthority',
		'EnterprisePrt',
		'WamDefaultSet',
		'WamDefaultAuthority',
		'NgcSet'
	)

	$values = [ordered]@{}
	foreach ($line in $lines) {
		if ($line -match '^\s*([^:]+?)\s*:\s*(.*?)\s*$') {
			$key = ($matches[1] -replace '\s+', '')
			$value = $matches[2].Trim()
			if ($key -in $interestingKeys) {
				$values[$key] = $value
			}
		}
	}

	if ($values.Count -eq 0) {
		return $null
	}

	return [PSCustomObject]@{
		AzureAdJoined      = ConvertTo-BooleanFromText -Value (Get-OptionalPropertyValue -Object ([PSCustomObject]$values) -PropertyName 'AzureAdJoined')
		EnterpriseJoined   = ConvertTo-BooleanFromText -Value (Get-OptionalPropertyValue -Object ([PSCustomObject]$values) -PropertyName 'EnterpriseJoined')
		DomainJoined       = ConvertTo-BooleanFromText -Value (Get-OptionalPropertyValue -Object ([PSCustomObject]$values) -PropertyName 'DomainJoined')
		WorkplaceJoined    = ConvertTo-BooleanFromText -Value (Get-OptionalPropertyValue -Object ([PSCustomObject]$values) -PropertyName 'WorkplaceJoined')
		DomainName         = Get-OptionalPropertyValue -Object ([PSCustomObject]$values) -PropertyName 'DomainName'
		DeviceId           = Get-OptionalPropertyValue -Object ([PSCustomObject]$values) -PropertyName 'DeviceId'
		TenantId           = Get-OptionalPropertyValue -Object ([PSCustomObject]$values) -PropertyName 'TenantId'
		TenantName         = Get-OptionalPropertyValue -Object ([PSCustomObject]$values) -PropertyName 'TenantName'
		VirtualDesktop     = Get-OptionalPropertyValue -Object ([PSCustomObject]$values) -PropertyName 'VirtualDesktop'
		AzureAdPrt         = ConvertTo-BooleanFromText -Value (Get-OptionalPropertyValue -Object ([PSCustomObject]$values) -PropertyName 'AzureAdPrt')
		AzureAdPrtExpiryTime = Get-OptionalPropertyValue -Object ([PSCustomObject]$values) -PropertyName 'AzureAdPrtExpiryTime'
		AzureAdPrtAuthority  = Get-OptionalPropertyValue -Object ([PSCustomObject]$values) -PropertyName 'AzureAdPrtAuthority'
		EnterprisePrt      = ConvertTo-BooleanFromText -Value (Get-OptionalPropertyValue -Object ([PSCustomObject]$values) -PropertyName 'EnterprisePrt')
		WamDefaultSet      = ConvertTo-BooleanFromText -Value (Get-OptionalPropertyValue -Object ([PSCustomObject]$values) -PropertyName 'WamDefaultSet')
		WamDefaultAuthority  = Get-OptionalPropertyValue -Object ([PSCustomObject]$values) -PropertyName 'WamDefaultAuthority'
		NgcSet             = ConvertTo-BooleanFromText -Value (Get-OptionalPropertyValue -Object ([PSCustomObject]$values) -PropertyName 'NgcSet')
	}
}

function Get-DomainJoinDiscovery {
	$computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
	$domainRoleMap = @{
		0 = 'StandaloneWorkstation'
		1 = 'MemberWorkstation'
		2 = 'StandaloneServer'
		3 = 'MemberServer'
		4 = 'BackupDomainController'
		5 = 'PrimaryDomainController'
	}
	$dsRegStatus = Get-DsRegStatus
	$domainRole = Get-OptionalPropertyValue -Object $computerSystem -PropertyName 'DomainRole'
	$isDomainJoined = [bool]$computerSystem.PartOfDomain
	$isAzureAdJoined = if ($null -eq $dsRegStatus) { $false } else { [bool]$dsRegStatus.AzureAdJoined }
	$isWorkplaceJoined = if ($null -eq $dsRegStatus) { $false } else { [bool]$dsRegStatus.WorkplaceJoined }

	$joinType = 'Workgroup'
	if ($isDomainJoined -and $isAzureAdJoined) {
		$joinType = 'HybridAzureADJoined'
	}
	elseif ($isAzureAdJoined) {
		$joinType = 'AzureADJoined'
	}
	elseif ($isDomainJoined) {
		$joinType = 'ActiveDirectoryJoined'
	}
	elseif ($isWorkplaceJoined) {
		$joinType = 'WorkplaceJoined'
	}

	[PSCustomObject]@{
		JoinType          = $joinType
		Hostname          = Get-NormalizedText -Value $computerSystem.Name
		Domain            = Get-NormalizedText -Value $computerSystem.Domain
		PartOfDomain      = $isDomainJoined
		Workgroup         = Get-NormalizedText -Value (Get-OptionalPropertyValue -Object $computerSystem -PropertyName 'Workgroup')
		DomainRole        = if ($domainRoleMap.ContainsKey([int]$domainRole)) { $domainRoleMap[[int]$domainRole] } else { $domainRole }
		Manufacturer      = Get-NormalizedText -Value $computerSystem.Manufacturer
		Model             = Get-NormalizedText -Value $computerSystem.Model
		AzureAdJoined     = $isAzureAdJoined
		WorkplaceJoined   = $isWorkplaceJoined
		DsRegStatus       = $dsRegStatus
	}
}

function Get-EntraSsoDiscovery {
	$dsReg = Get-DsRegStatus

	$_lsaKerberos = Get-RegistryKeyValues -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters'
	$_lsaPku2u    = Get-RegistryKeyValues -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\pku2u'
	$_lsa         = Get-RegistryKeyValues -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
	$_whfbPolicy  = Get-RegistryKeyValues -Path 'HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork'
	$_tsPolicy    = Get-RegistryKeyValues -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'

	$_cloudKerbRaw = Get-OptionalPropertyValue -Object $_lsaKerberos -PropertyName 'CloudKerberosTicketRetrievalEnabled'
	$_pku2uRaw     = Get-OptionalPropertyValue -Object $_lsaPku2u    -PropertyName 'AllowOnlineID'
	$_credGuardRaw = Get-OptionalPropertyValue -Object $_lsa         -PropertyName 'LsaCfgFlags'
	$_whfbRaw      = Get-OptionalPropertyValue -Object $_whfbPolicy  -PropertyName 'Enabled'
	$_webAuthnRaw  = Get-OptionalPropertyValue -Object $_tsPolicy    -PropertyName 'fEnableWebAuthn'

	$_isAadJoined = $null -ne $dsReg -and $dsReg.AzureAdJoined -eq $true
	$_isDomJoined = $null -ne $dsReg -and $dsReg.DomainJoined  -eq $true
	$_isHaadj     = $_isAadJoined -and $_isDomJoined

	$_cloudKerb = if ($null -ne $_cloudKerbRaw) { [int]$_cloudKerbRaw -eq 1 } else { $false }
	$_pku2u     = if ($null -ne $_pku2uRaw)     { [int]$_pku2uRaw -eq 1 }     else { $null }
	$_credGuard = if ($null -ne $_credGuardRaw) { [int]$_credGuardRaw -gt 0 } else { $false }
	$_whfb      = if ($null -ne $_whfbRaw)      { [int]$_whfbRaw -eq 1 }      else { $null }
	$_webAuthn  = if ($null -ne $_webAuthnRaw)  { [int]$_webAuthnRaw -eq 1 }  else { $null }

	$_blockers   = [System.Collections.Generic.List[string]]::new()
	$_advisories = [System.Collections.Generic.List[string]]::new()
	$_notes      = [System.Collections.Generic.List[string]]::new()

	if (-not $_isAadJoined) {
		$_blockers.Add('Device is not Entra ID joined — Entra SSO requires AzureADJoined or HybridAzureADJoined') | Out-Null
	}

	if ($_isHaadj -and -not $_cloudKerb) {
		$_advisories.Add('Hybrid Entra joined but Cloud Kerberos Trust not enabled — Kerberos SSO to on-premises resources may not work') | Out-Null
	}

	if ($null -eq $dsReg -or $dsReg.AzureAdPrt -ne $true) {
		if ($script:IsSystemAccountMode) {
			$_notes.Add('PRT state is unavailable when running as SYSTEM account — run interactively for per-user PRT data') | Out-Null
		} elseif ($_isAadJoined) {
			$_advisories.Add('No Azure AD PRT detected for the running account — users may be prompted to authenticate') | Out-Null
		}
	}

	if ($_isAadJoined -and $null -ne $dsReg -and $dsReg.WamDefaultSet -ne $true) {
		$_advisories.Add('WAM (Web Account Manager) is not the default credential broker — modern authentication SSO may be impaired') | Out-Null
	}

	if ($_credGuard) {
		$_notes.Add('Credential Guard is enabled — NTLM and legacy credential delegation are blocked (expected in a secure AVD environment)') | Out-Null
	}

	[PSCustomObject]@{
		SsoCapable                 = $_blockers.Count -eq 0
		Blockers                   = @($_blockers)
		Advisories                 = @($_advisories)
		Notes                      = @($_notes)
		AzureAdPrt                 = if ($null -ne $dsReg) { $dsReg.AzureAdPrt }           else { $null }
		AzureAdPrtExpiry           = if ($null -ne $dsReg) { $dsReg.AzureAdPrtExpiryTime } else { $null }
		AzureAdPrtAuthority        = if ($null -ne $dsReg) { $dsReg.AzureAdPrtAuthority }  else { $null }
		EnterprisePrt              = if ($null -ne $dsReg) { $dsReg.EnterprisePrt }         else { $null }
		WamDefaultSet              = if ($null -ne $dsReg) { $dsReg.WamDefaultSet }         else { $null }
		WamDefaultAuthority        = if ($null -ne $dsReg) { $dsReg.WamDefaultAuthority }   else { $null }
		NgcSet                     = if ($null -ne $dsReg) { $dsReg.NgcSet }                else { $null }
		CloudKerberosTrustEnabled  = $_cloudKerb
		Pku2uAllowOnlineId         = $_pku2u
		CredentialGuardEnabled     = $_credGuard
		WhfbPolicyEnabled          = $_whfb
		WebAuthnRedirectorEnabled  = $_webAuthn
	}
}

function Get-IntuneEnrollmentDiscovery {
	# Primary enrollment record
	$enrollmentsPath = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
	$enrollmentRecords = @()
	try {
		$enrollmentRecords = @(Get-ChildItem -Path $enrollmentsPath -ErrorAction Stop | ForEach-Object {
			$values = Get-RegistryKeyValues -Path $_.PSPath
			if ($null -eq $values) { return }
			$providerID = Get-OptionalPropertyValue -Object $values -PropertyName 'ProviderID'
			if ([string]::IsNullOrWhiteSpace($providerID)) { return }
			[PSCustomObject]@{
				EnrollmentId     = Split-Path -Path $_.Name -Leaf
				ProviderID       = Get-NormalizedText -Value $providerID
				EnrollmentType   = Get-OptionalPropertyValue -Object $values -PropertyName 'EnrollmentType'
				EnrollmentState  = Get-OptionalPropertyValue -Object $values -PropertyName 'EnrollmentState'
				UPN              = Get-NormalizedText -Value (Get-OptionalPropertyValue -Object $values -PropertyName 'UPN')
				AADTenantId      = Get-NormalizedText -Value (Get-OptionalPropertyValue -Object $values -PropertyName 'AADTenantId')
				AADResourceID    = Get-NormalizedText -Value (Get-OptionalPropertyValue -Object $values -PropertyName 'AADResourceID')
			}
		} | Where-Object { $null -ne $_ })
	}
	catch {
	}

	# Intune-specific: MDM enrollment sub-key written by the Intune management extension
	$intuneRecords = @($enrollmentRecords | Where-Object { $_.ProviderID -eq 'MS DM Server' -or $_.ProviderID -like '*Intune*' })

	# PolicyManager device detail — populated when a device is Intune-managed
	$policyManagerDevice = Get-RegistryKeyValues -Path 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device'

	# Intune Management Extension service
	$imeService = Get-Service -Name 'IntuneManagementExtension' -ErrorAction SilentlyContinue

	# IME installation path / version
	$imeBinaryPath = 'C:\Program Files (x86)\Microsoft Intune Management Extension\agentexecutor.exe'
	$imeVersion = $null
	if (Test-Path -Path $imeBinaryPath) {
		$fvi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($imeBinaryPath)
		$imeVersion = Get-NormalizedText -Value $fvi.FileVersion
	}

	# MDM enrollment status from dsregcmd output (already collected in JoinState, but read directly here for independence)
	$mdmUrl = $null
	$mdmEnrolled = $false
	try {
		$mdmRegPath = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
		$mdmStatusPath = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\DeviceLock'
		if (Test-Path -Path $mdmRegPath) {
			Get-ChildItem -Path $mdmRegPath -ErrorAction SilentlyContinue | ForEach-Object {
				$v = Get-RegistryKeyValues -Path $_.PSPath
				if ($null -ne $v) {
					$url = Get-OptionalPropertyValue -Object $v -PropertyName 'MDMServiceUrl'
					if (-not [string]::IsNullOrWhiteSpace($url)) {
						$mdmUrl = Get-NormalizedText -Value $url
						$mdmEnrolled = $true
					}
				}
			}
		}
	}
	catch {
	}

	$enrolled = @($intuneRecords).Count -gt 0 -or $null -ne $imeService -or $mdmEnrolled

	[PSCustomObject]@{
		Enrolled                    = $enrolled
		MdmEnrolled                 = $mdmEnrolled
		MdmServiceUrl               = $mdmUrl
		IntuneRecordCount           = @($intuneRecords).Count
		IntuneEnrollmentRecords     = @($intuneRecords)
		ImeInstalled                = $null -ne $imeService
		ImeServiceStatus            = if ($null -eq $imeService) { 'NotInstalled' } else { [string]$imeService.Status }
		ImeVersion                  = $imeVersion
	}
}

function Get-LapsDiscovery {
	$windowsLapsPolicy = Get-RegistryKeyValues -Path 'HKLM:\SOFTWARE\Microsoft\Policies\LAPS'
	$windowsLapsPolicyManager = Get-RegistryKeyValues -Path 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\LAPS'
	$legacyLapsPolicy = Get-RegistryKeyValues -Path 'HKLM:\SOFTWARE\Policies\Microsoft Services\AdmPwd'
	$legacyLapsDllPath = 'C:\Program Files\LAPS\CSE\AdmPwd.dll'

	$windowsLapsConfigured = $null -ne $windowsLapsPolicy -or $null -ne $windowsLapsPolicyManager
	$legacyLapsConfigured = $null -ne $legacyLapsPolicy -or (Test-Path -Path $legacyLapsDllPath)
	$legacyEnabled = if ($null -eq $legacyLapsPolicy) { $false } else { [int](Get-OptionalPropertyValue -Object $legacyLapsPolicy -PropertyName 'AdmPwdEnabled') -eq 1 }
	$windowsBackupDirectory = if ($null -ne $windowsLapsPolicy) {
		Get-OptionalPropertyValue -Object $windowsLapsPolicy -PropertyName 'BackupDirectory'
	} elseif ($null -ne $windowsLapsPolicyManager) {
		Get-OptionalPropertyValue -Object $windowsLapsPolicyManager -PropertyName 'BackupDirectory'
	} else { $null }

	[PSCustomObject]@{
		InUse                    = $windowsLapsConfigured -or $legacyEnabled
		WindowsLapsConfigured    = $windowsLapsConfigured
		LegacyLapsConfigured     = $legacyLapsConfigured
		BackupDirectory          = $windowsBackupDirectory
		LegacyLapsDllPresent     = Test-Path -Path $legacyLapsDllPath
		WindowsLapsPolicy        = $windowsLapsPolicy
		WindowsLapsPolicyManager = $windowsLapsPolicyManager
		LegacyLapsPolicy         = $legacyLapsPolicy
	}
}

function Get-OutlookCachedModeDiscovery {
	$officeVersions = @('16.0', '15.0', '14.0')

	# Machine-wide group policy override (applies to all users)
	$machinePolicySettings = foreach ($version in $officeVersions) {
		$policyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Office\$version\Outlook\Cached Mode"
		$values = Get-RegistryKeyValues -Path $policyPath
		if ($null -eq $values) { continue }
		[PSCustomObject]@{
			OfficeVersion = $version
			RegistryPath  = $policyPath
			Enable        = Get-OptionalPropertyValue -Object $values -PropertyName 'Enable'
			SyncWindowSetting = Get-OptionalPropertyValue -Object $values -PropertyName 'SyncWindowSetting'
			SyncWindowSettingDays = Get-OptionalPropertyValue -Object $values -PropertyName 'SyncWindowSettingDays'
			RawValues     = $values
		}
	}

	# Per-user cached mode settings — skip when running as SYSTEM/machine account (no user hive loaded)
	$loadedUsers = if ($script:IsSystemAccountMode) { @() } else { Get-LoadedUserProfiles }
	$userSettings = foreach ($user in $loadedUsers) {
		$userVersionSettings = foreach ($version in $officeVersions) {
			$userCachedModePath = "Registry::HKEY_USERS\$($user.Sid)\Software\Microsoft\Office\$version\Outlook\Cached Mode"
			$values = Get-RegistryKeyValues -Path $userCachedModePath
			if ($null -eq $values) { continue }
			[PSCustomObject]@{
				OfficeVersion = $version
				RegistryPath  = $userCachedModePath
				Enable        = Get-OptionalPropertyValue -Object $values -PropertyName 'Enable'
				SyncWindowSetting = Get-OptionalPropertyValue -Object $values -PropertyName 'SyncWindowSetting'
				SyncWindowSettingDays = Get-OptionalPropertyValue -Object $values -PropertyName 'SyncWindowSettingDays'
				RawValues     = $values
			}
		}

		if (@($userVersionSettings).Count -eq 0) { continue }

		[PSCustomObject]@{
			Sid             = $user.Sid
			AccountName     = $user.AccountName
			VersionSettings = @($userVersionSettings)
		}
	}

	# Determine effective cached mode state: policy takes precedence over user setting
	$policyEnableValue = $null
	foreach ($policySetting in @($machinePolicySettings)) {
		$val = $policySetting.Enable
		if ($null -ne $val) {
			$policyEnableValue = $val
			break
		}
	}

	$anyUserEnabled = @($userSettings | ForEach-Object { $_.VersionSettings } | Where-Object { $_.Enable -eq 1 }).Count -gt 0
	$anyUserDisabled = @($userSettings | ForEach-Object { $_.VersionSettings } | Where-Object { $_.Enable -eq 0 }).Count -gt 0

	$effectiveState = if ($null -ne $policyEnableValue) {
		if ($policyEnableValue -eq 1) { 'EnabledByPolicy' } else { 'DisabledByPolicy' }
	}
	elseif ($anyUserEnabled) { 'Enabled' }
	elseif ($anyUserDisabled) { 'Disabled' }
	else { 'Unknown' }

	[PSCustomObject]@{
		EffectiveState          = $effectiveState
		Note                    = if ($script:IsSystemAccountMode) { 'Per-user Outlook cached mode registry settings skipped — script is running as a system/machine account. Run Invoke-AvdSessionHostAudit.ps1 interactively on the host to collect user-specific data.' } else { $null }
		PolicyConfigured        = @($machinePolicySettings).Count -gt 0
		PolicyEnableValue       = $policyEnableValue
		MachinePolicySettings   = @($machinePolicySettings)
		UserSettingCount        = @($userSettings).Count
		UserSettings            = @($userSettings)
	}
}

function Get-DefaultFileAssociationsDiscovery {
	$policyPaths = @(
		'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System',
		'HKCU:\SOFTWARE\Policies\Microsoft\Windows\System'
	)

	$policyLocations = foreach ($path in $policyPaths) {
		$values = Get-RegistryKeyValues -Path $path
		if ($null -eq $values) {
			continue
		}

		$xmlPath = Get-OptionalPropertyValue -Object $values -PropertyName 'DefaultAssociationsConfiguration'
		if ([string]::IsNullOrWhiteSpace($xmlPath)) {
			continue
		}

		[PSCustomObject]@{
			RegistryPath = $path
			XmlPath      = $xmlPath
			XmlFile      = Get-PathInventoryItem -Path $xmlPath -TypeHint 'File'
		}
	}

	$effectiveLocation = $null
	if (@($policyLocations).Count -gt 0) {
		$effectiveLocation = $policyLocations[0]
	}

	[PSCustomObject]@{
		Configured      = @($policyLocations).Count -gt 0
		PolicyLocations = @($policyLocations)
		EffectiveXmlPath = if ($null -eq $effectiveLocation) { $null } else { $effectiveLocation.XmlPath }
		EffectiveXmlFile = if ($null -eq $effectiveLocation) { $null } else { $effectiveLocation.XmlFile }
	}
}

function Get-FSLogixRedirectionsXmlDiscovery {
	param(
		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[string]$ComponentName,

		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[object]$EffectiveConfig
	)

	if ($null -eq $EffectiveConfig) {
		return [PSCustomObject]@{
			ComponentName          = $ComponentName
			Configured             = $false
			SourceFolders          = @()
			RedirectionsXmlFiles   = @()
			RedirectionsXmlInUse   = $false
		}
	}

	$sourceFolders = Convert-ToStringArray -Value (Get-OptionalPropertyValue -Object $EffectiveConfig -PropertyName 'RedirXMLSourceFolder')
	$xmlFiles = foreach ($sourceFolder in $sourceFolders) {
		$inventoryPath = if ($sourceFolder -match '(?i)\.xml$') { $sourceFolder } else { Join-Path -Path $sourceFolder -ChildPath 'Redirections.xml' }
		Get-PathInventoryItem -Path $inventoryPath -TypeHint 'File'
	}

	[PSCustomObject]@{
		ComponentName          = $ComponentName
		Configured             = @($sourceFolders).Count -gt 0
		SourceFolders          = @($sourceFolders)
		RedirectionsXmlFiles   = @($xmlFiles)
		RedirectionsXmlInUse   = @($xmlFiles | Where-Object { $null -ne $_ -and $_.Exists }).Count -gt 0
	}
}

function Get-FSLogixAppMaskingDiscovery {
	$localConfig = Get-RegistryKeyValues -Path 'HKLM:\SOFTWARE\FSLogix\Apps'
	$policyConfig = Get-RegistryKeyValues -Path 'HKLM:\SOFTWARE\Policies\FSLogix\Apps'
	$effectiveConfig = Merge-ConfigurationObjects -BaseObject $localConfig -OverrideObject $policyConfig
	$ruleDirectories = @(
		'C:\Program Files\FSLogix\Apps\Rules',
		'C:\Program Files\FSLogix\Apps\Rules\WVD',
		'C:\Program Files\FSLogix\Apps\Rules\Citrix',
		'C:\Program Files\FSLogix\Apps\Rules\RDSH'
	)

	$ruleFiles = foreach ($directory in $ruleDirectories) {
		if (-not (Test-Path -Path $directory)) {
			continue
		}

		Get-ChildItem -Path $directory -Include '*.fxr', '*.fxa' -File -Recurse -ErrorAction SilentlyContinue |
			ForEach-Object {
				[PSCustomObject]@{
					Name          = $_.Name
					FullName      = $_.FullName
					Extension     = $_.Extension
					SizeBytes     = [int64]$_.Length
					LastWriteTime = $_.LastWriteTime.ToString('s')
				}
			}
	}

	# HKLM:\SOFTWARE\FSLogix\Apps is written by the installer with InstallPath/InstallVersion.
	# Those keys are not App Masking configuration — exclude them when deciding if App Masking
	# has been deliberately configured.
	$installerOnlyKeys = @('InstallPath', 'InstallVersion')
	$localConfigHasMaskingSettings = $null -ne $localConfig -and
		@($localConfig.PSObject.Properties | Where-Object { $_.Name -notin $installerOnlyKeys }).Count -gt 0

	[PSCustomObject]@{
		Configured         = $localConfigHasMaskingSettings -or ($null -ne $policyConfig)
		EffectiveEnabled   = if ($null -eq $effectiveConfig) { $null } else { Get-OptionalPropertyValue -Object $effectiveConfig -PropertyName 'Enabled' }
		RuleDirectories    = @($ruleDirectories | ForEach-Object { Get-PathInventoryItem -Path $_ -TypeHint 'Directory' })
		RuleFileCount      = @($ruleFiles).Count
		RulesInUse         = @($ruleFiles).Count -gt 0
		RawLocalConfig     = $localConfig
		RawPolicyConfig    = $policyConfig
		RuleFiles          = @($ruleFiles)
	}
}

function Get-AntivirusDiscovery {
	param(
		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[object[]]$InstalledApplications
	)

	$securityCenterProducts = @()
	try {
		$securityCenterProducts = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName 'AntivirusProduct' -ErrorAction Stop | ForEach-Object {
			[PSCustomObject]@{
				DisplayName              = Get-NormalizedText -Value $_.displayName
				InstanceGuid             = Get-NormalizedText -Value $_.instanceGuid
				PathToSignedProductExe   = Get-NormalizedText -Value $_.pathToSignedProductExe
				PathToSignedReportingExe = Get-NormalizedText -Value $_.pathToSignedReportingExe
				ProductState             = Get-OptionalPropertyValue -Object $_ -PropertyName 'productState'
			}
		})
	}
	catch {
	}

	$defenderStatus = $null
	if ($null -ne (Get-Command -Name 'Get-MpComputerStatus' -ErrorAction SilentlyContinue)) {
		try {
			$mpStatus = Get-MpComputerStatus -ErrorAction Stop
			$defenderStatus = [PSCustomObject]@{
				AMServiceEnabled        = Get-OptionalPropertyValue -Object $mpStatus -PropertyName 'AMServiceEnabled'
				AntispywareEnabled      = Get-OptionalPropertyValue -Object $mpStatus -PropertyName 'AntispywareEnabled'
				AntivirusEnabled        = Get-OptionalPropertyValue -Object $mpStatus -PropertyName 'AntivirusEnabled'
				RealTimeProtectionEnabled = Get-OptionalPropertyValue -Object $mpStatus -PropertyName 'RealTimeProtectionEnabled'
				NISEnabled              = Get-OptionalPropertyValue -Object $mpStatus -PropertyName 'NISEnabled'
				QuickScanAge            = Get-OptionalPropertyValue -Object $mpStatus -PropertyName 'QuickScanAge'
				FullScanAge             = Get-OptionalPropertyValue -Object $mpStatus -PropertyName 'FullScanAge'
			}
		}
		catch {
		}
	}

	$pattern = 'Defender|CrowdStrike|SentinelOne|Sophos|Trend Micro|McAfee|Symantec|Norton|ESET|Bitdefender|Avast|AVG|Carbon Black|Cylance|Malwarebytes|Trellix|Secure Endpoint|Microsoft Defender'
	$applicationMatches = @($InstalledApplications | Where-Object {
		$_.Name -match $pattern -or $_.Publisher -match $pattern
	} | ForEach-Object {
		[PSCustomObject]@{
			Name      = $_.Name
			Publisher = $_.Publisher
			Version   = $_.Version
		}
	})

	[PSCustomObject]@{
		SecurityCenterProducts     = @($securityCenterProducts)
		SecurityCenterDetected     = @($securityCenterProducts).Count -gt 0
		WindowsDefender            = $defenderStatus
		InstalledApplicationMatches = $applicationMatches
		Detected                   = @($securityCenterProducts).Count -gt 0 -or $null -ne $defenderStatus -or @($applicationMatches).Count -gt 0
	}
}

function Get-LanguagePackDiscovery {
	$installedCapabilities = @()
	$capabilityQuerySucceeded = $false
	$capabilityQueryError = $null

	if ($null -ne (Get-Command -Name 'Get-WindowsCapability' -ErrorAction SilentlyContinue)) {
		try {
			$installedCapabilities = @(Get-WindowsCapability -Online -ErrorAction Stop |
				Where-Object {
					$_.Name -like 'Language.*~~~*' -and $_.State -eq 'Installed'
				} |
				ForEach-Object {
					[PSCustomObject]@{
						Name     = $_.Name
						State    = $_.State
						Language = if ($_.Name -match '~~~([a-z]{2}-[A-Z]{2})~') { $matches[1] } else { $null }
					}
				})
			$capabilityQuerySucceeded = $true
		}
		catch {
			$capabilityQueryError = $_.Exception.Message
		}
	}

	if (-not $capabilityQuerySucceeded) {
		$dismLines = Get-CommandOutputLines -Command 'dism.exe' -Arguments @('/Online', '/English', '/Get-Capabilities')
		$currentCapabilityName = $null
		foreach ($line in $dismLines) {
			if ($line -match '^Capability Identity\s*:\s*(.+)$') {
				$currentCapabilityName = $matches[1].Trim()
				continue
			}

			if ($line -match '^State\s*:\s*(.+)$') {
				$state = $matches[1].Trim()
				if (-not [string]::IsNullOrWhiteSpace($currentCapabilityName) -and $currentCapabilityName -like 'Language.*~~~*' -and $state -eq 'Installed') {
					$installedCapabilities += [PSCustomObject]@{
						Name     = $currentCapabilityName
						State    = $state
						Language = if ($currentCapabilityName -match '~~~([a-z]{2}-[A-Z]{2})~') { $matches[1] } else { $null }
					}
				}
				$currentCapabilityName = $null
			}
		}

		if (@($installedCapabilities).Count -gt 0) {
			$capabilityQuerySucceeded = $true
		}
	}

	$installedUiLanguages = @()
	try {
		$installedUiLanguages = @(Get-ChildItem -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MUI\UILanguages' -ErrorAction Stop |
			Select-Object -ExpandProperty PSChildName)
	}
	catch {
	}

	$currentUserLanguages = @()
	if ($null -ne (Get-Command -Name 'Get-WinUserLanguageList' -ErrorAction SilentlyContinue)) {
		try {
			$currentUserLanguages = @(Get-WinUserLanguageList | ForEach-Object {
				[PSCustomObject]@{
					LanguageTag = $_.LanguageTag
					Autonym     = $_.Autonym
					EnglishName = $_.EnglishName
				}
			})
		}
		catch {
		}
	}

	[PSCustomObject]@{
		CapabilityQuerySucceeded = $capabilityQuerySucceeded
		CapabilityQueryError     = $capabilityQueryError
		InstalledLanguageCapabilities = @($installedCapabilities)
		InstalledLanguageTags    = @($installedCapabilities | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Language) } | Select-Object -ExpandProperty Language -Unique)
		InstalledUiLanguages     = @($installedUiLanguages)
		CurrentUserLanguages     = @($currentUserLanguages)
		SystemLocale             = if ($null -eq (Get-Command -Name 'Get-WinSystemLocale' -ErrorAction SilentlyContinue)) { $null } else { (Get-WinSystemLocale).Name }
		UiLanguageOverride       = if ($null -eq (Get-Command -Name 'Get-WinUILanguageOverride' -ErrorAction SilentlyContinue)) { $null } else { Get-WinUILanguageOverride }
	}
}

function Get-LoadedUserProfiles {
	$userProfileMap = @{}
	foreach ($profile in (Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace($_.SID) })) {
		$userProfileMap[$profile.SID] = $profile
	}

	$excludedSids = @('S-1-5-18', 'S-1-5-19', 'S-1-5-20')
	$loadedSids = Get-ChildItem -Path 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue |
		Where-Object {
			$leaf = Split-Path -Path $_.Name -Leaf
			$leaf -match '^S-1-(5-21|12-1)-' -and $leaf -notin $excludedSids -and $leaf -notlike '*_Classes'
		} |
		ForEach-Object {
			Split-Path -Path $_.Name -Leaf
		}

	foreach ($sid in $loadedSids) {
		$accountName = $sid
		try {
			$accountName = ([System.Security.Principal.SecurityIdentifier]$sid).Translate([System.Security.Principal.NTAccount]).Value
		}
		catch {
		}

		$profile = $null
		if ($userProfileMap.ContainsKey($sid)) {
			$profile = $userProfileMap[$sid]
		}

		[PSCustomObject]@{
			Sid         = $sid
			AccountName = $accountName
			ProfilePath = if ($null -eq $profile) { $null } else { $profile.LocalPath }
			Loaded      = if ($null -eq $profile) { $true } else { [bool]$profile.Loaded }
		}
	}
}

function Get-UserMappedDriveState {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Sid,

		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[string]$AccountName
	)

	$networkRegistryPath = "Registry::HKEY_USERS\$Sid\Network"
	if (-not (Test-Path -Path $networkRegistryPath)) {
		return [PSCustomObject]@{
			Sid                 = $Sid
			AccountName         = $AccountName
			RegistryPath        = $networkRegistryPath
			MappedDrivesPresent = $false
			MappedDriveCount    = 0
			MappedDrives        = @()
		}
	}

	$mappedDrives = @(Get-ChildItem -Path $networkRegistryPath -ErrorAction SilentlyContinue | ForEach-Object {
		$driveLetter = Split-Path -Path $_.Name -Leaf
		$driveValues = Get-RegistryKeyValues -Path $_.PSPath

		[PSCustomObject]@{
			DriveLetter       = if ([string]::IsNullOrWhiteSpace($driveLetter)) { $null } else { '{0}:' -f $driveLetter.TrimEnd(':') }
			RemotePath        = if ($null -eq $driveValues) { $null } else { Get-NormalizedText -Value (Get-OptionalPropertyValue -Object $driveValues -PropertyName 'RemotePath') }
			UserName          = if ($null -eq $driveValues) { $null } else { Get-NormalizedText -Value (Get-OptionalPropertyValue -Object $driveValues -PropertyName 'UserName') }
			ProviderName      = if ($null -eq $driveValues) { $null } else { Get-NormalizedText -Value (Get-OptionalPropertyValue -Object $driveValues -PropertyName 'ProviderName') }
			ProviderType      = if ($null -eq $driveValues) { $null } else { Get-OptionalPropertyValue -Object $driveValues -PropertyName 'ProviderType' }
			ConnectionType    = if ($null -eq $driveValues) { $null } else { Get-OptionalPropertyValue -Object $driveValues -PropertyName 'ConnectionType' }
			DeferFlags        = if ($null -eq $driveValues) { $null } else { Get-OptionalPropertyValue -Object $driveValues -PropertyName 'DeferFlags' }
			RegistryKeyPath   = $_.PSPath
		}
	})

	[PSCustomObject]@{
		Sid                 = $Sid
		AccountName         = $AccountName
		RegistryPath        = $networkRegistryPath
		MappedDrivesPresent = @($mappedDrives).Count -gt 0
		MappedDriveCount    = @($mappedDrives).Count
		MappedDrives        = @($mappedDrives)
	}
}

function Get-CurrentSessionMappedDrives {
	$networkDrives = @()
	try {
		$networkDrives = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 4' -ErrorAction Stop | ForEach-Object {
			[PSCustomObject]@{
				DriveLetter      = Get-NormalizedText -Value $_.DeviceID
				ProviderName     = Get-NormalizedText -Value $_.ProviderName
				VolumeName       = Get-NormalizedText -Value $_.VolumeName
				FreeSpaceBytes   = Get-OptionalPropertyValue -Object $_ -PropertyName 'FreeSpace'
				SizeBytes        = Get-OptionalPropertyValue -Object $_ -PropertyName 'Size'
				FreeSpaceGB      = ConvertTo-BytesToGigabytes -Bytes (Get-OptionalPropertyValue -Object $_ -PropertyName 'FreeSpace')
				SizeGB           = ConvertTo-BytesToGigabytes -Bytes (Get-OptionalPropertyValue -Object $_ -PropertyName 'Size')
			}
		})
	}
	catch {
	}

	return @($networkDrives)
}

function Get-FolderState {
	param(
		[Parameter(Mandatory = $true)]
		[string]$FolderName,

		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[string]$RawPath,

		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[string]$ProfilePath,

		[Parameter(Mandatory = $true)]
		[string]$DefaultRelativePath
	)

	$resolvedPath = Resolve-UserValuePath -Value $RawPath -ProfilePath $ProfilePath
	$defaultPath = if ([string]::IsNullOrWhiteSpace($ProfilePath)) { $null } else { Join-Path -Path $ProfilePath -ChildPath $DefaultRelativePath }
	$isOneDrivePath = $false
	$isNetworkRedirected = $false
	$isCustomRedirected = $false

	if (-not [string]::IsNullOrWhiteSpace($resolvedPath)) {
		$isOneDrivePath = $resolvedPath -match '(?i)onedrive'
		$isNetworkRedirected = $resolvedPath.StartsWith('\\')
		if (-not [string]::IsNullOrWhiteSpace($defaultPath)) {
			$isCustomRedirected = $resolvedPath.TrimEnd('\') -ine $defaultPath.TrimEnd('\')
		}
	}

	[PSCustomObject]@{
		FolderName            = $FolderName
		RawPath               = $RawPath
		ResolvedPath          = $resolvedPath
		DefaultPath           = $defaultPath
		Exists                = if ([string]::IsNullOrWhiteSpace($resolvedPath)) { $false } else { Test-Path -Path $resolvedPath }
		IsOneDrivePath        = $isOneDrivePath
		IsNetworkRedirected   = $isNetworkRedirected
		IsCustomRedirected    = $isCustomRedirected
	}
}

function Get-UserShellFolderState {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Sid,

		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[string]$AccountName,

		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[string]$ProfilePath
	)

	$userShellFoldersPath = "Registry::HKEY_USERS\$Sid\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
	$userShellFolders = Get-RegistryKeyValues -Path $userShellFoldersPath

	if ($null -eq $userShellFolders) {
		return [PSCustomObject]@{
			Sid                           = $Sid
			AccountName                   = $AccountName
			ProfilePath                   = $ProfilePath
			RegistryPath                  = $userShellFoldersPath
			UserShellFoldersAvailable     = $false
			LikelyOneDriveKnownFolderMove = $false
			LikelyFolderRedirection       = $false
			Folders                       = @()
		}
	}

	$folders = @(
		Get-FolderState -FolderName 'Desktop' -RawPath (Get-OptionalPropertyValue -Object $userShellFolders -PropertyName 'Desktop') -ProfilePath $ProfilePath -DefaultRelativePath 'Desktop'
		Get-FolderState -FolderName 'Documents' -RawPath (Get-OptionalPropertyValue -Object $userShellFolders -PropertyName 'Personal') -ProfilePath $ProfilePath -DefaultRelativePath 'Documents'
		Get-FolderState -FolderName 'Pictures' -RawPath (Get-OptionalPropertyValue -Object $userShellFolders -PropertyName 'My Pictures') -ProfilePath $ProfilePath -DefaultRelativePath 'Pictures'
		Get-FolderState -FolderName 'Favorites' -RawPath (Get-OptionalPropertyValue -Object $userShellFolders -PropertyName 'Favorites') -ProfilePath $ProfilePath -DefaultRelativePath 'Favorites'
		Get-FolderState -FolderName 'AppDataRoaming' -RawPath (Get-OptionalPropertyValue -Object $userShellFolders -PropertyName 'AppData') -ProfilePath $ProfilePath -DefaultRelativePath 'AppData\Roaming'
	)
	$redirectedFolders = @($folders | Where-Object { $_.IsNetworkRedirected })

	[PSCustomObject]@{
		Sid                           = $Sid
		AccountName                   = $AccountName
		ProfilePath                   = $ProfilePath
		RegistryPath                  = $userShellFoldersPath
		UserShellFoldersAvailable     = $true
		LikelyOneDriveKnownFolderMove = @($folders | Where-Object { $_.IsOneDrivePath }).Count -gt 0
		LikelyFolderRedirection       = @($redirectedFolders).Count -gt 0
		RedirectedFolderCount         = @($redirectedFolders).Count
		RedirectedFolders             = @($redirectedFolders)
		Folders                       = $folders
	}
}

function Get-OneDrivePolicyState {
	# Registry paths where OneDrive KFM/policy values are written, in priority order.
	# Both Group Policy (ADMX via GPO) and Intune MDM write to the Policies hive.
	# Intune also writes to the MDM bridge path below, which we use to distinguish them.
	$policyPaths = @(
		'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive',
		'HKCU:\SOFTWARE\Policies\Microsoft\OneDrive'
	)

	# MDM bridge: Intune writes policy values here in addition to the Policies hive.
	# Presence of values here (when the Policies hive also has values) indicates Intune.
	$mdmBridgePath = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\OneDrive'
	$mdmBridgeValues = Get-RegistryKeyValues -Path $mdmBridgePath

	$policies = foreach ($path in $policyPaths) {
		$values = Get-RegistryKeyValues -Path $path
		if ($null -eq $values) {
			continue
		}

		# Determine policy source:
		#   - HKCU paths are always user-scoped Group Policy (not Intune MDM, which is machine-scoped)
		#   - HKLM Policies hive: check MDM bridge to distinguish Intune from GP
		$isHkcu   = $path -like 'HKCU:*'
		$isIntune = (-not $isHkcu) -and ($null -ne $mdmBridgeValues) -and (@($mdmBridgeValues.PSObject.Properties).Count -gt 0)
		$source   = if ($isHkcu) { 'GroupPolicy-User' } elseif ($isIntune) { 'Intune-MDM' } else { 'GroupPolicy-Computer' }

		[PSCustomObject]@{
			RegistryPath = $path
			Source       = $source
			Values       = $values
		}
	}

	$effectivePolicy = $null
	if (@($policies).Count -gt 0) {
		$effectivePolicy = $policies[0].Values
	}

	[PSCustomObject]@{
		PolicyDetected              = @($policies).Count -gt 0
		KFMSilentOptInTenantId      = if ($null -eq $effectivePolicy) { $null } else { Get-OptionalPropertyValue -Object $effectivePolicy -PropertyName 'KFMSilentOptIn' }
		KFMSilentOptInWithNotify    = if ($null -eq $effectivePolicy) { $null } else { Get-OptionalPropertyValue -Object $effectivePolicy -PropertyName 'KFMSilentOptInWithNotification' }
		KFMBlockOptIn               = if ($null -eq $effectivePolicy) { $null } else { Get-OptionalPropertyValue -Object $effectivePolicy -PropertyName 'KFMBlockOptIn' }
		KFMBlockOptOut              = if ($null -eq $effectivePolicy) { $null } else { Get-OptionalPropertyValue -Object $effectivePolicy -PropertyName 'KFMBlockOptOut' }
		SilentMoveDesktopEnabled    = if ($null -eq $effectivePolicy) { $null } else { Get-OptionalPropertyValue -Object $effectivePolicy -PropertyName 'KFMSilentOptInDesktop' }
		SilentMoveDocumentsEnabled  = if ($null -eq $effectivePolicy) { $null } else { Get-OptionalPropertyValue -Object $effectivePolicy -PropertyName 'KFMSilentOptInDocuments' }
		SilentMovePicturesEnabled   = if ($null -eq $effectivePolicy) { $null } else { Get-OptionalPropertyValue -Object $effectivePolicy -PropertyName 'KFMSilentOptInPictures' }
		PolicyLocations             = @($policies)
	}
}

function Get-OneDriveAndFolderRedirectionDiscovery {
	# Skip per-user shell folder and mapped drive checks when running as SYSTEM/machine account
	$loadedUsers = if ($script:IsSystemAccountMode) { @() } else { Get-LoadedUserProfiles }
	$userStates = foreach ($user in $loadedUsers) {
		Get-UserShellFolderState -Sid $user.Sid -AccountName $user.AccountName -ProfilePath $user.ProfilePath
	}
	$userMappedDriveStates = foreach ($user in $loadedUsers) {
		Get-UserMappedDriveState -Sid $user.Sid -AccountName $user.AccountName
	}
	$redirectedFolders = @($userStates | ForEach-Object { @($_.RedirectedFolders) })
	$mappedDrives = @($userMappedDriveStates | ForEach-Object { @($_.MappedDrives) })
	$currentSessionMappedDrives = Get-CurrentSessionMappedDrives

	[PSCustomObject]@{
		OneDrivePolicies              = Get-OneDrivePolicyState
		Note                          = if ($script:IsSystemAccountMode) { 'Per-user shell folder, folder redirection, and mapped drive data skipped — script is running as a system/machine account. Run Invoke-AvdSessionHostAudit.ps1 interactively on the host to collect user-specific data.' } else { $null }
		LoadedUserCount               = @($loadedUsers).Count
		UsersWithKnownFolderMove      = @($userStates | Where-Object { $_.LikelyOneDriveKnownFolderMove }).Count
		UsersWithFolderRedirection    = @($userStates | Where-Object { $_.LikelyFolderRedirection }).Count
		RedirectedFolderCount         = @($redirectedFolders).Count
		UsersWithMappedDrives         = @($userMappedDriveStates | Where-Object { $_.MappedDrivesPresent }).Count
		MappedDriveCount              = @($mappedDrives).Count
		CurrentSessionMappedDriveCount = @($currentSessionMappedDrives).Count
		CurrentSessionMappedDrives    = @($currentSessionMappedDrives)
		LoadedUserFolderStates        = @($userStates)
		LoadedUserMappedDriveStates   = @($userMappedDriveStates)
		RedirectedFolders             = @($redirectedFolders)
		MappedDrives                  = @($mappedDrives)
	}
}

function Get-FSLogixProfileFiles {
	param(
		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[string[]]$ProfileLocations
	)

	if ($null -eq $ProfileLocations) {
		return @()
	}

	$results = foreach ($location in $ProfileLocations) {
		$normalizedLocation = Get-NormalizedText -Value $location
		if ([string]::IsNullOrWhiteSpace($normalizedLocation)) {
			continue
		}

		$profileFiles = @()
		$errorMessage = $null
		$locationExists = $false

		try {
			$locationExists = Test-Path -Path $normalizedLocation
			if ($locationExists) {
				foreach ($filter in @('*.vhd', '*.vhdx')) {
					$profileFiles += Get-ChildItem -Path $normalizedLocation -Filter $filter -File -Recurse -ErrorAction SilentlyContinue
				}
			}
		}
		catch {
			$errorMessage = $_.Exception.Message
		}

		$deduplicatedFiles = $profileFiles | Sort-Object -Property FullName -Unique
		$totalBytes = 0
		foreach ($file in @($deduplicatedFiles)) {
			$totalBytes += [int64]$file.Length
		}

		[PSCustomObject]@{
			Location                = $normalizedLocation
			Accessible              = $null -eq $errorMessage
			Exists                  = $locationExists
			ProfileContainerCount   = @($deduplicatedFiles).Count
			TotalSizeBytes          = if ($null -eq $totalBytes) { 0 } else { [int64]$totalBytes }
			TotalSizeGB             = ConvertTo-BytesToGigabytes -Bytes $totalBytes
			ScanError               = $errorMessage
		}
	}

	return @($results)
}

function Get-FSLogixDiscovery {
	$localConfigPath = 'HKLM:\SOFTWARE\FSLogix\Profiles'
	$policyConfigPath = 'HKLM:\SOFTWARE\Policies\FSLogix\Profiles'
	$localConfig = Get-RegistryKeyValues -Path $localConfigPath
	$policyConfig = Get-RegistryKeyValues -Path $policyConfigPath
	$effectiveConfig = Merge-ConfigurationObjects -BaseObject $localConfig -OverrideObject $policyConfig
	$odfcLocalConfig = Get-RegistryKeyValues -Path 'HKLM:\SOFTWARE\FSLogix\ODFC'
	$odfcPolicyConfig = Get-RegistryKeyValues -Path 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'
	$odfcEffectiveConfig = Merge-ConfigurationObjects -BaseObject $odfcLocalConfig -OverrideObject $odfcPolicyConfig
	$profileLocations = @()
	$cloudCacheLocations = @()
	$odfcCloudCacheLocations = @()

	if ($null -ne $effectiveConfig) {
		$profileLocations = Convert-ToStringArray -Value (Get-OptionalPropertyValue -Object $effectiveConfig -PropertyName 'VHDLocations')
		$cloudCacheLocations = Convert-ToStringArray -Value (Get-OptionalPropertyValue -Object $effectiveConfig -PropertyName 'CCDLocations')
		if (@($profileLocations).Count -eq 0) {
			$profileLocations = @($cloudCacheLocations)
		}
	}

	if ($null -ne $odfcEffectiveConfig) {
		$odfcCloudCacheLocations = Convert-ToStringArray -Value (Get-OptionalPropertyValue -Object $odfcEffectiveConfig -PropertyName 'CCDLocations')
	}

	$frxService = Get-Service -Name 'frxsvc' -ErrorAction SilentlyContinue
	$profileLocationInventory = Get-FSLogixProfileFiles -ProfileLocations $profileLocations
	$totalProfileBytes = 0
	$totalProfileCount = 0
	foreach ($locationInventory in @($profileLocationInventory)) {
		$totalProfileBytes += [int64]$locationInventory.TotalSizeBytes
		$totalProfileCount += [int64]$locationInventory.ProfileContainerCount
	}

	[PSCustomObject]@{
		Installed                   = ($null -ne $localConfig) -or ($null -ne $policyConfig) -or ($null -ne $frxService)
		ServiceName                 = if ($null -eq $frxService) { 'frxsvc' } else { $frxService.Name }
		ServiceStatus               = if ($null -eq $frxService) { 'NotInstalled' } else { [string]$frxService.Status }
		ConfigDetected              = ($null -ne $localConfig) -or ($null -ne $policyConfig)
		EffectiveEnabled            = if ($null -eq $effectiveConfig) { $null } else { Get-OptionalPropertyValue -Object $effectiveConfig -PropertyName 'Enabled' }
		ProfileLocations            = $profileLocations
		CloudCacheInUse             = @($cloudCacheLocations).Count -gt 0 -or @($odfcCloudCacheLocations).Count -gt 0
		CloudCacheLocations         = @($cloudCacheLocations)
		CloudCacheLocalCachePath    = if ($null -eq $effectiveConfig) { $null } else { Get-OptionalPropertyValue -Object $effectiveConfig -PropertyName 'CcdLocalCachePath' }
		VolumeType                  = if ($null -eq $effectiveConfig) { $null } else { Get-OptionalPropertyValue -Object $effectiveConfig -PropertyName 'VolumeType' }
		SizeInMBs                   = if ($null -eq $effectiveConfig) { $null } else { Get-OptionalPropertyValue -Object $effectiveConfig -PropertyName 'SizeInMBs' }
		IsDynamic                   = if ($null -eq $effectiveConfig) { $null } else { Get-OptionalPropertyValue -Object $effectiveConfig -PropertyName 'IsDynamic' }
		FlipFlopProfileDirectoryName = if ($null -eq $effectiveConfig) { $null } else { Get-OptionalPropertyValue -Object $effectiveConfig -PropertyName 'FlipFlopProfileDirectoryName' }
		DeleteLocalProfileWhenVHDShouldApply = if ($null -eq $effectiveConfig) { $null } else { Get-OptionalPropertyValue -Object $effectiveConfig -PropertyName 'DeleteLocalProfileWhenVHDShouldApply' }
		ConcurrentUserSessions      = if ($null -eq $effectiveConfig) { $null } else { Get-OptionalPropertyValue -Object $effectiveConfig -PropertyName 'ConcurrentUserSessions' }
		AccessNetworkAsComputerObject = if ($null -eq $effectiveConfig) { $null } else { Get-OptionalPropertyValue -Object $effectiveConfig -PropertyName 'AccessNetworkAsComputerObject' }
		OfficeCloudCacheLocations   = @($odfcCloudCacheLocations)
		RedirectionsXml             = @(
			(Get-FSLogixRedirectionsXmlDiscovery -ComponentName 'Profiles' -EffectiveConfig $effectiveConfig)
			(Get-FSLogixRedirectionsXmlDiscovery -ComponentName 'ODFC' -EffectiveConfig $odfcEffectiveConfig)
		)
		AppMasking                  = Get-FSLogixAppMaskingDiscovery
		ProfileLocationInventory    = $profileLocationInventory
		ProfileContainerCount       = $totalProfileCount
		ProfileContainerTotalBytes  = if ($null -eq $totalProfileBytes) { 0 } else { [int64]$totalProfileBytes }
		ProfileContainerTotalGB     = ConvertTo-BytesToGigabytes -Bytes $totalProfileBytes
		RawLocalConfig              = $localConfig
		RawPolicyConfig             = $policyConfig
		OfficeContainerLocalConfig  = $odfcLocalConfig
		OfficeContainerPolicyConfig = $odfcPolicyConfig
	}
}

function Test-TcpEndpoint {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Hostname,

		[Parameter(Mandatory = $true)]
		[int]$Port,

		[Parameter(Mandatory = $false)]
		[int]$TimeoutMs = 5000
	)

	$connected = $false
	$errorMessage = $null
	$latencyMs = $null
	$client = $null

	try {
		$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
		$client = [System.Net.Sockets.TcpClient]::new()
		$connectTask = $client.ConnectAsync($Hostname, $Port)
		if ($connectTask.Wait($TimeoutMs)) {
			$stopwatch.Stop()
			$connected = $client.Connected
			if ($connected) {
				$latencyMs = [int]$stopwatch.ElapsedMilliseconds
			}
			else {
				$errorMessage = 'Connection refused'
			}
		}
		else {
			$stopwatch.Stop()
			$errorMessage = 'Connection timed out'
		}
	}
	catch {
		$inner = $_.Exception.InnerException
		$errorMessage = if ($null -ne $inner) { $inner.Message } else { $_.Exception.Message }
	}
	finally {
		if ($null -ne $client) {
			$client.Close()
			$client.Dispose()
		}
	}

	[PSCustomObject]@{
		Connected = $connected
		LatencyMs = $latencyMs
		Error     = $errorMessage
	}
}

function Get-AvdConnectivityDiscovery {
	$endpoints = @(
		[PSCustomObject]@{ Hostname = 'login.microsoftonline.com';                  Port = 443;  Category = 'AzureAD';               Required = $true  }
		[PSCustomObject]@{ Hostname = 'login.windows.net';                          Port = 443;  Category = 'AzureAD';               Required = $true  }
		[PSCustomObject]@{ Hostname = 'aadcdn.msftauth.net';                        Port = 443;  Category = 'AzureAD';               Required = $true  }
		[PSCustomObject]@{ Hostname = 'rdgateway.wvd.microsoft.com';                Port = 443;  Category = 'AVDService';            Required = $true  }
		[PSCustomObject]@{ Hostname = 'rdbroker.wvd.microsoft.com';                 Port = 443;  Category = 'AVDService';            Required = $true  }
		[PSCustomObject]@{ Hostname = 'rdweb.wvd.microsoft.com';                    Port = 443;  Category = 'AVDService';            Required = $true  }
		[PSCustomObject]@{ Hostname = 'rddiagnostics.wvd.microsoft.com';            Port = 443;  Category = 'AVDService';            Required = $true  }
		[PSCustomObject]@{ Hostname = 'client.wvd.microsoft.com';                   Port = 443;  Category = 'AVDService';            Required = $true  }
		[PSCustomObject]@{ Hostname = 'management.azure.com';                       Port = 443;  Category = 'AzureManagement';       Required = $true  }
		[PSCustomObject]@{ Hostname = 'mrsglobalsteus2prod.blob.core.windows.net';  Port = 443;  Category = 'AzureStorage';          Required = $true  }
		[PSCustomObject]@{ Hostname = 'wvdportalstorageblob.blob.core.windows.net'; Port = 443;  Category = 'AzureStorage';          Required = $true  }
		[PSCustomObject]@{ Hostname = 'catalogartifact.azureedge.net';              Port = 443;  Category = 'AzureStorage';          Required = $true  }
		[PSCustomObject]@{ Hostname = 'gcs.prod.monitoring.core.windows.net';       Port = 443;  Category = 'Monitoring';            Required = $true  }
		[PSCustomObject]@{ Hostname = 'v10.events.data.microsoft.com';              Port = 443;  Category = 'Monitoring';            Required = $false }
		[PSCustomObject]@{ Hostname = 'kms.core.windows.net';                       Port = 1688; Category = 'Activation';            Required = $true  }
		[PSCustomObject]@{ Hostname = 'azkms.core.windows.net';                     Port = 1688; Category = 'Activation';            Required = $false }
		[PSCustomObject]@{ Hostname = 'www.msftconnecttest.com';                    Port = 443;  Category = 'InternetCheck';         Required = $true  }
		[PSCustomObject]@{ Hostname = 'ocsp.msocsp.com';                            Port = 80;   Category = 'CertificateValidation'; Required = $true  }
		[PSCustomObject]@{ Hostname = 'crl.microsoft.com';                          Port = 80;   Category = 'CertificateValidation'; Required = $true  }
		[PSCustomObject]@{ Hostname = '169.254.169.254';                            Port = 80;   Category = 'AzureIMDS';             Required = $false }
	)

	Write-Host '  Testing AVD network connectivity endpoints...' -ForegroundColor DarkGray
	Write-Host ''

	$results = foreach ($endpoint in $endpoints) {
		$label = "$($endpoint.Hostname):$($endpoint.Port)"
		$requiredLabel = if ($endpoint.Required) { '[Required]' } else { '[Optional]' }
	Write-Host -NoNewline "  $requiredLabel $($endpoint.Category.PadRight(22)) $label ... " -ForegroundColor Gray

		$result = Test-TcpEndpoint -Hostname $endpoint.Hostname -Port $endpoint.Port

		if ($result.Connected) {
			Write-Host (Format-Ansi "`e[92mOK  ($($result.LatencyMs)ms)`e[0m")
		}
		else {
			Write-Host (Format-Ansi "`e[91mFAILED  — $($result.Error)`e[0m")
		}

		[PSCustomObject]@{
			Hostname  = $endpoint.Hostname
			Port      = $endpoint.Port
			Category  = $endpoint.Category
			Required  = $endpoint.Required
			Connected = $result.Connected
			LatencyMs = $result.LatencyMs
			Error     = $result.Error
		}
	}

	$requiredResults = @($results | Where-Object { $_.Required })
	$requiredPassed  = @($requiredResults | Where-Object { $_.Connected })
	$requiredFailed  = @($requiredResults | Where-Object { -not $_.Connected })

	Write-Host ''
	$_reachStr = "$(@($requiredPassed).Count)/$(@($requiredResults).Count) required endpoints reachable"
	if (@($requiredFailed).Count -eq 0) {
		Write-Host (Format-Ansi "  `e[92m$_reachStr`e[0m")
	} else {
		Write-Host (Format-Ansi "  `e[93m$_reachStr`e[0m")
		Write-Host (Format-Ansi "  `e[93mFailed required endpoints:`e[0m")
		foreach ($failed in $requiredFailed) {
			Write-Host (Format-Ansi "    `e[91m— $($failed.Hostname):$($failed.Port)  ($($failed.Error))`e[0m")
		}
	}
	Write-Host ''

	# Only emit results that are notable: required failures and optional failures.
	# All-passing required endpoints are omitted to keep the output compact.
	$notableResults = @($results | Where-Object { -not $_.Connected })

	[PSCustomObject]@{
		AllRequiredReachable     = @($requiredFailed).Count -eq 0
		RequiredEndpointCount    = @($requiredResults).Count
		RequiredReachableCount   = @($requiredPassed).Count
		RequiredUnreachableCount = @($requiredFailed).Count
		FailedEndpoints          = @($notableResults)
		Results                  = @($results)
	}
}

function Get-TeamsMediaOptimizationDiscovery {
	# WebRTC redirector service
	$webRtcService = Get-Service -Name 'RDWebRTCSvc' -ErrorAction SilentlyContinue

	# WebRTC redirector binary — derive version from the installed executable
	$webRtcBinaryPaths = @(
		'C:\Program Files\Microsoft Remote Desktop WebRTC Redirector\RDWebRTCSvc.exe',
		'C:\Program Files (x86)\Microsoft Remote Desktop WebRTC Redirector\RDWebRTCSvc.exe'
	)
	$webRtcBinaryInfo = $null
	foreach ($binaryPath in $webRtcBinaryPaths) {
		if (Test-Path -Path $binaryPath) {
			$fvi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($binaryPath)
			$webRtcBinaryInfo = [PSCustomObject]@{
				Path           = $binaryPath
				FileVersion    = Get-NormalizedText -Value $fvi.FileVersion
				ProductVersion = Get-NormalizedText -Value $fvi.ProductVersion
			}
			break
		}
	}

	# IsWVDEnvironment registry key — required for new Teams (2.x) media optimization
	$teamsRegistryConfig = Get-RegistryKeyValues -Path 'HKLM:\SOFTWARE\Microsoft\Teams'
	$isWvdEnvironment = if ($null -eq $teamsRegistryConfig) { $null } else { Get-OptionalPropertyValue -Object $teamsRegistryConfig -PropertyName 'IsWVDEnvironment' }

	# Classic Teams VDI exclusion registry (set by Teams installer in VDI mode)
	$classicTeamsVdiConfig = Get-RegistryKeyValues -Path 'HKLM:\SOFTWARE\Microsoft\Teams\VdiPartner'

	# Policy that can suppress Teams AV optimization on RDS/AVD
	$rdPolicyConfig = Get-RegistryKeyValues -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
	$avOptimizationDisabledByPolicy = if ($null -eq $rdPolicyConfig) { $false } else {
		(Get-OptionalPropertyValue -Object $rdPolicyConfig -PropertyName 'fDisableAudioCapture') -eq 1 -or
		(Get-OptionalPropertyValue -Object $rdPolicyConfig -PropertyName 'fDisableCam') -eq 1
	}

	# Determine Teams installations from the application list is not available here,
	# so check common install paths directly
	$classicTeamsPath = 'C:\Program Files (x86)\Microsoft\Teams\current\Teams.exe'
	$newTeamsPath = 'C:\Program Files\WindowsApps'
	$newTeamsMsixPresent = $false
	try {
		$newTeamsMsixPresent = @(Get-ChildItem -Path $newTeamsPath -Filter 'MSTeams_*' -Directory -ErrorAction Stop).Count -gt 0
	}
	catch {
	}

	$classicTeamsInstalled = Test-Path -Path $classicTeamsPath
	$serviceInstalled = $null -ne $webRtcService
	$serviceRunning = $serviceInstalled -and [string]$webRtcService.Status -eq 'Running'
	$isWvdFlagSet = $isWvdEnvironment -eq 1

	$optimizationReadyClassic = $serviceRunning -and $classicTeamsInstalled
	$optimizationReadyNewTeams = $serviceRunning -and $isWvdFlagSet -and $newTeamsMsixPresent

	[PSCustomObject]@{
		OptimizationReadyClassicTeams  = $optimizationReadyClassic
		OptimizationReadyNewTeams      = $optimizationReadyNewTeams
		WebRtcRedirectorInstalled      = $serviceInstalled
		WebRtcRedirectorServiceStatus  = if ($null -eq $webRtcService) { 'NotInstalled' } else { [string]$webRtcService.Status }
		WebRtcRedirectorBinary         = $webRtcBinaryInfo
		IsWvdEnvironmentFlagSet        = $isWvdFlagSet
		IsWvdEnvironmentValue          = $isWvdEnvironment
		ClassicTeamsInstalled          = $classicTeamsInstalled
		NewTeamsMsixPresent            = $newTeamsMsixPresent
		AvOptimizationDisabledByPolicy = $avOptimizationDisabledByPolicy
		RdPolicyConfig                 = $rdPolicyConfig
		ClassicTeamsVdiConfig          = $classicTeamsVdiConfig
	}
}

function Get-TimeSourceDiscovery {
	$configuredSource = $null
	$currentSource = $null
	$stratum = $null
	$lastSyncTime = $null
	$lastSyncError = $null
	$type = $null
	$errorMessage = $null

	$ntpServerPolicy = Get-RegistryKeyValues -Path 'HKLM:\SOFTWARE\Policies\Microsoft\W32Time\Parameters'
	$ntpServerLocal = Get-RegistryKeyValues -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
	$effectiveNtpParams = Merge-ConfigurationObjects -BaseObject $ntpServerLocal -OverrideObject $ntpServerPolicy

	if ($null -ne $effectiveNtpParams) {
		$configuredSource = Get-NormalizedText -Value (Get-OptionalPropertyValue -Object $effectiveNtpParams -PropertyName 'NtpServer')
		$type = Get-NormalizedText -Value (Get-OptionalPropertyValue -Object $effectiveNtpParams -PropertyName 'Type')
	}

	$w32tmLines = Get-CommandOutputLines -Command 'w32tm.exe' -Arguments @('/query', '/status')
	foreach ($line in $w32tmLines) {
		if ($line -match '^Source\s*:\s*(.+)$') {
			$currentSource = $matches[1].Trim()
		}
		elseif ($line -match '^Stratum\s*:\s*(\d+)') {
			$stratum = [int]$matches[1]
		}
		elseif ($line -match '^Last Successful Sync Time\s*:\s*(.+)$') {
			$lastSyncTime = $matches[1].Trim()
		}
		elseif ($line -match '^Last Sync Error\s*:\s*(.+)$') {
			$lastSyncError = $matches[1].Trim()
		}
	}

	[PSCustomObject]@{
		ConfiguredSource  = $configuredSource
		ConfiguredType    = $type
		CurrentSource     = $currentSource
		Stratum           = $stratum
		LastSyncTime      = $lastSyncTime
		LastSyncError     = if ($lastSyncError -eq '0x0') { $null } else { $lastSyncError }
		NtpPolicyDetected = $null -ne $ntpServerPolicy
		Error             = $errorMessage
	}
}

function Get-PrinterDiscovery {
	$printers = @()
	$errorMessage = $null

	try {
		$allPrinters = @(Get-Printer -ErrorAction Stop)
		$driverMap = @{}
		try {
			Get-PrinterDriver -ErrorAction Stop | ForEach-Object {
				$driverMap[$_.Name] = $_
			}
		}
		catch {
		}

		$printers = @($allPrinters | ForEach-Object {
			$driverName = Get-NormalizedText -Value $_.DriverName
			$driver = if (-not [string]::IsNullOrWhiteSpace($driverName) -and $driverMap.ContainsKey($driverName)) { $driverMap[$driverName] } else { $null }

			[PSCustomObject]@{
				Name              = Get-NormalizedText -Value $_.Name
				DriverName        = $driverName
				DriverVersion     = if ($null -eq $driver) { $null } else { Get-NormalizedText -Value (Get-OptionalPropertyValue -Object $driver -PropertyName 'DriverVersion') }
				DriverProvider    = if ($null -eq $driver) { $null } else { Get-NormalizedText -Value (Get-OptionalPropertyValue -Object $driver -PropertyName 'Manufacturer') }
				PortName          = Get-NormalizedText -Value $_.PortName
				Shared            = $_.Shared
				ShareName         = if ($_.Shared) { Get-NormalizedText -Value $_.ShareName } else { $null }
				PrinterStatus     = [string]$_.PrinterStatus
				Type              = if ($_.PortName -like 'USB*') { 'Local-USB' }
									elseif ($_.PortName -like '\\*' -or $_.PortName -like 'WSD*') { 'Network' }
									elseif ($_.DriverName -eq 'Universal Print Class Driver') { 'UniversalPrint' }
									elseif ($_.PortName -eq 'PORTPROMPT:' -or $_.PortName -eq 'FILE:') { 'Virtual' }
									else { 'Other' }
			}
		})
	}
	catch {
		$errorMessage = $_.Exception.Message
	}

	[PSCustomObject]@{
		PrinterCount      = @($printers).Count
		Printers          = @($printers)
		Error             = $errorMessage
	}
}

function Get-UniversalPrintDiscovery {
	$connectorService = Get-Service -Name 'UniversalPrintConnector' -ErrorAction SilentlyContinue
	$connectorConfig = Get-RegistryKeyValues -Path 'HKLM:\SOFTWARE\Microsoft\UniversalPrintConnector'
	$upMonitorPorts = @()
	try {
		$upMonitorPorts = @(Get-ChildItem -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors\Universal Print Monitor\Ports' -ErrorAction Stop |
			Select-Object -ExpandProperty PSChildName)
	}
	catch {
	}

	$upPrinters = @()
	try {
		$upPrinters = @(Get-Printer -ErrorAction Stop | Where-Object {
			$_.DriverName -eq 'Universal Print Class Driver' -or $_.PortName -in $upMonitorPorts
		} | ForEach-Object {
			[PSCustomObject]@{
				Name       = Get-NormalizedText -Value $_.Name
				DriverName = Get-NormalizedText -Value $_.DriverName
				PortName   = Get-NormalizedText -Value $_.PortName
				Shared     = $_.Shared
				PrinterStatus = [string]$_.PrinterStatus
			}
		})
	}
	catch {
	}

	$connectorRegistered = $null -ne $connectorService -or $null -ne $connectorConfig
	$cloudPrintersPresent = @($upPrinters).Count -gt 0

	[PSCustomObject]@{
		InUse                       = $connectorRegistered -or $cloudPrintersPresent
		ConnectorInstalled          = $null -ne $connectorService
		ConnectorServiceStatus      = if ($null -eq $connectorService) { 'NotInstalled' } else { [string]$connectorService.Status }
		ConnectorConfigDetected     = $null -ne $connectorConfig
		ConnectorConfig             = $connectorConfig
		CloudPrinterCount           = @($upPrinters).Count
		CloudPrinters               = @($upPrinters)
		UpMonitorPortCount          = @($upMonitorPorts).Count
	}
}

function Get-ConfigFileServerReferences {
	<#
	.SYNOPSIS
	Scans application config files under Program Files for references to remote servers
	or domain-joined machines — UNC paths, FQDNs, and connection-string server keywords.
	Only text-based config file types up to 1 MB are inspected. Windows system directories
	and common redistributable/framework folders are excluded to reduce noise.
	#>

	$scanRoots = @(
		$env:ProgramFiles,
		${env:ProgramFiles(x86)}
	) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path $_) } | Sort-Object -Unique

	# File extensions to scan (text-based config formats only)
	$configExtensions = @('.ini', '.cfg', '.config', '.xml', '.conf', '.properties', '.env', '.yaml', '.yml')

	# Folder name fragments to skip — Windows components, runtimes, redistributables
	$excludedFolderPatterns = @(
		'Windows NT', 'Windows Kits', 'Windows Mail', 'Windows Media',
		'Microsoft.NET', 'dotnet', 'Microsoft Visual C++', 'Microsoft Visual Studio',
		'WindowsPowerShell', 'Windows Defender', 'Windows Security',
		'Microsoft\EdgeUpdate', 'Microsoft\Edge\Application',
		'Common Files\microsoft shared', 'Common Files\System',
		'Common Files\Services'
	)

	# Regex patterns that indicate a server/domain reference in a config value
	# 1. UNC path:            \\server  or  \\server.domain.com
	# 2. FQDN assignment:     keyword=server.domain.tld  (must have at least one dot-separated label before a 2+ char TLD)
	# 3. Connection strings:  Server=x, Data Source=x, Host=x, hostname=x, address=x, DataSource=x
	$uncPattern        = [regex]'(?i)\\\\[A-Za-z0-9_-][A-Za-z0-9_.-]+'
	$fqdnValuePattern  = [regex]'(?i)(?:server|host|hostname|address|data[\s_-]*source|datasource|endpoint|url|uri|broker|gateway|proxy)\s*[=:]\s*([A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+){1,}\.[A-Za-z]{2,})'
	$maxFileSizeBytes  = 1MB

	$findings = @()

	foreach ($root in $scanRoots) {
		try {
			$files = @(Get-ChildItem -Path $root -Recurse -File -ErrorAction SilentlyContinue |
				Where-Object {
					$configExtensions -contains $_.Extension.ToLowerInvariant() -and
					$_.Length -le $maxFileSizeBytes -and
					-not ($excludedFolderPatterns | Where-Object { $_.FullName -like "*$_*" })
				})
		}
		catch { continue }

		foreach ($file in $files) {
			try {
				$content = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
			}
			catch { continue }

			$matchedRefs = @()

			# UNC paths
			foreach ($m in $uncPattern.Matches($content)) {
				$val = $m.Value.TrimEnd('/', '\', ' ', '"', "'")
				# Skip loopback and well-known non-domain tokens
				if ($val -notmatch '\\\\(localhost|127\.|::1)') {
					$matchedRefs += [PSCustomObject]@{ Type = 'UncPath'; Value = $val }
				}
			}

			# FQDN / connection-string references
			foreach ($m in $fqdnValuePattern.Matches($content)) {
				$fqdn = $m.Groups[1].Value.Trim('"', "'", ' ', ';', ',')
				# Skip localhost variants, pure IP addresses, and .local mDNS names that may be non-AD
				if ($fqdn -notmatch '^(localhost|127\.|0\.0\.0\.0|::1)' -and
				    $fqdn -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
					$matchedRefs += [PSCustomObject]@{ Type = 'FqdnReference'; Value = $fqdn }
				}
			}

			if ($matchedRefs.Count -gt 0) {
				# Deduplicate references within this file
				$dedupedRefs = $matchedRefs | Group-Object -Property Type, Value | ForEach-Object {
					$_.Group[0]
				}
				$findings += [PSCustomObject]@{
					FilePath   = $file.FullName
					FileName   = $file.Name
					SizeBytes  = $file.Length
					References = @($dedupedRefs)
				}
			}
		}
	}

	return @($findings)
}

function Get-ActiveDirectoryDependencyDiscovery {
	<#
	.SYNOPSIS
	Checks whether the host has dependencies on Active Directory that would block or
	complicate a move to Entra-only (Azure AD) join. Examines services running as domain
	accounts, scheduled tasks running as domain accounts, ODBC data sources pointing at
	domain servers or using domain credentials, active TCP connections to common AD
	ports (88, 135, 389, 445, 464, 636, 3268, 3269), and application config files under
	Program Files that reference remote servers or domain-joined machines by name.

	TCP connections are deduplicated by remote address + port so that hundreds of SMB
	sessions to the same file server appear as a single entry with a connection count.
	#>

	# --- Domain-account services ---
	$domainServices = @()
	try {
		$domainServices = @(Get-CimInstance -ClassName Win32_Service `
			-Property Name,DisplayName,StartName,State,StartMode `
			-ErrorAction Stop |
			Where-Object {
				$acct = $_.StartName
				-not [string]::IsNullOrEmpty($acct) -and
				$acct -match '\\' -and
				$acct -notmatch '^(LocalSystem$|NT AUTHORITY\\|NT SERVICE\\|LOCAL SERVICE$|NETWORK SERVICE$)'
			} | ForEach-Object {
				[PSCustomObject]@{
					Name        = $_.Name
					DisplayName = Get-NormalizedText -Value $_.DisplayName
					Account     = $_.StartName
					State       = [string]$_.State
					StartMode   = [string]$_.StartMode
				}
			})
	}
	catch { }

	# --- Domain-account scheduled tasks ---
	$domainTasks = @()
	try {
		$domainTasks = @(Get-ScheduledTask -ErrorAction Stop | ForEach-Object {
			$principal = $_.Principal
			if ($null -eq $principal) { return }
			$userId = $null
			try { $userId = [string]$principal.UserId } catch { return }
			if ([string]::IsNullOrEmpty($userId)) { return }
			if ($userId -notmatch '\\') { return }
			if ($userId -match '^(SYSTEM$|S-1-5-18$|LOCAL SERVICE$|NETWORK SERVICE$|BUILTIN\\|NT AUTHORITY\\|NT SERVICE\\|S-1-5-)') { return }
			$runLevel  = $null; try { $runLevel  = [string]$principal.RunLevel } catch { }
			$taskState = $null; try { $taskState = [string]$_.State        } catch { }
			[PSCustomObject]@{
				TaskPath = [string]$_.TaskPath
				TaskName = [string]$_.TaskName
				Account  = $userId
				RunLevel = $runLevel
				State    = $taskState
			}
		})
	}
	catch { }

	# --- ODBC data sources (system DSNs — 32-bit and 64-bit) ---
	$odbcSources = @()
	try {
		$odbcPaths = @(
			'HKLM:\SOFTWARE\ODBC\ODBC.INI',
			'HKLM:\SOFTWARE\WOW6432Node\ODBC\ODBC.INI'
		)
		$domainPattern = '\\\\[A-Za-z0-9_.-]+\.[A-Za-z]{2,}|\\\\[A-Za-z0-9_-]+'

		foreach ($odbcRoot in $odbcPaths) {
			if (-not (Test-Path $odbcRoot)) { continue }
			$dsnNames = @(Get-ChildItem -Path $odbcRoot -ErrorAction SilentlyContinue |
				Where-Object { $_.PSChildName -ne 'ODBC Data Sources' } |
				Select-Object -ExpandProperty PSChildName)
			foreach ($dsn in $dsnNames) {
				$vals = Get-RegistryKeyValues -Path "$odbcRoot\$dsn"
				if ($null -eq $vals) { continue }
				$server = $vals.Server
				$uid    = $vals.UID
				$dbq    = $vals.DBQ
				$driver = $vals.Driver

				$serverFlag = (-not [string]::IsNullOrWhiteSpace($server) -and (
					$server -match '\.' -or $server -match '^\\\\'))
				$credFlag   = (-not [string]::IsNullOrWhiteSpace($uid) -and $uid -match '\\')
				$dbqFlag    = (-not [string]::IsNullOrWhiteSpace($dbq) -and $dbq -match $domainPattern)

				if ($serverFlag -or $credFlag -or $dbqFlag) {
					$odbcSources += [PSCustomObject]@{
						DsnName      = $dsn
						RegistryPath = "$odbcRoot\$dsn"
						Driver       = Get-NormalizedText -Value $driver
						Server       = Get-NormalizedText -Value $server
						Uid          = Get-NormalizedText -Value $uid
						Dbq          = Get-NormalizedText -Value $dbq
						FlagReasons  = @(
							if ($serverFlag) { 'DomainServer' }
							if ($credFlag)   { 'DomainCredential' }
							if ($dbqFlag)    { 'DomainPath' }
						)
					}
				}
			}
		}
	}
	catch { }

	# --- Active TCP connections to common AD ports ---
	# 88=Kerberos, 135=RPC/EPM, 389=LDAP, 445=SMB, 464=Kpasswd,
	# 636=LDAPS, 3268=GC-LDAP, 3269=GC-LDAPS
	#
	# Connections are grouped by {RemoteAddress, RemotePort} — an AVD host can have
	# thousands of active SMB sessions to the same file server, so emitting each
	# individual connection would produce a huge payload.
	$adPorts = @(88, 135, 389, 445, 464, 636, 3268, 3269)
	$adPortMap = @{
		88   = 'Kerberos'
		135  = 'RPC/Endpoint Mapper'
		389  = 'LDAP'
		445  = 'SMB'
		464  = 'Kerberos Password Change'
		636  = 'LDAPS'
		3268 = 'Global Catalog LDAP'
		3269 = 'Global Catalog LDAPS'
	}
	$adConnections = @()
	try {
		$localIPs = @('127.0.0.1', '::1')
		try {
			$localIPs += @([System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
				ForEach-Object { $_.ToString() })
		}
		catch { }

		$adConnections = @(
			Get-NetTCPConnection -State Established -ErrorAction Stop |
			Where-Object { $_.RemotePort -in $adPorts -and $_.RemoteAddress -notin $localIPs } |
			Group-Object -Property RemoteAddress, RemotePort |
			ForEach-Object {
				$sample = $_.Group[0]
				[PSCustomObject]@{
					RemoteAddress   = $sample.RemoteAddress
					RemotePort      = $sample.RemotePort
					Service         = $adPortMap[$sample.RemotePort]
					ConnectionCount = $_.Count
				}
			}
		)
	}
	catch { }

	# --- Config file server references ---
	$configFileRefs = Get-ConfigFileServerReferences

	$hasDependencies = @($domainServices).Count -gt 0 -or
	                   @($domainTasks).Count -gt 0 -or
	                   @($odbcSources).Count -gt 0 -or
	                   @($adConnections).Count -gt 0 -or
	                   @($configFileRefs).Count -gt 0

	[PSCustomObject]@{
		HasDomainDependencies        = $hasDependencies
		DomainServiceCount           = @($domainServices).Count
		DomainScheduledTaskCount     = @($domainTasks).Count
		DomainOdbcSourceCount        = @($odbcSources).Count
		AdPortConnectionCount        = @($adConnections).Count
		ConfigFileReferenceCount     = @($configFileRefs).Count
		DomainServices               = @($domainServices)
		DomainScheduledTasks         = @($domainTasks)
		OdbcSources                  = @($odbcSources)
		AdPortConnections            = @($adConnections)
		ConfigFileServerReferences   = @($configFileRefs)
	}
}

function Get-GroupPolicyDiscovery {
	param(
		[Parameter(Mandatory = $true)]
		[string]$OutputPath
	)

	$errorMessage = $null
	$succeeded = $false
	$tempFile = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ([System.Guid]::NewGuid().ToString('N') + '.html')

	try {
		$gpresultArgs = @('/h', $tempFile, '/f')
		if ($script:IsSystemAccountMode) { $gpresultArgs += @('/scope', 'computer') }
		$gpresultOutput = & gpresult.exe @gpresultArgs 2>&1
		$exitCode = $LASTEXITCODE

		if (Test-Path -Path $tempFile) {
			Move-Item -Path $tempFile -Destination $OutputPath -Force
			$succeeded = $true
		}
		else {
			$capturedText = ($gpresultOutput | ForEach-Object { $_.ToString() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' '
			$errorMessage = if ([string]::IsNullOrWhiteSpace($capturedText)) { "gpresult exited with code $exitCode and did not produce an output file" } else { $capturedText.Trim() }
		}
	}
	catch {
		$errorMessage = $_.Exception.Message
	}
	finally {
		if (Test-Path -Path $tempFile) {
			Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
		}
	}

	[PSCustomObject]@{
		Succeeded        = $succeeded
		Note             = if ($script:IsSystemAccountMode -and $succeeded) { 'Report contains computer policy only (no user RSoP) — script is running as a system/machine account. Run Invoke-AvdSessionHostAudit.ps1 interactively on the host to include user Group Policy.' } else { $null }
		HtmlReportPath   = if ($succeeded) { $OutputPath } else { $null }
		Error            = $errorMessage
	}
}

function Get-PrimaryApplicationConfigPath {
	$fileName    = 'appExclusions.config.json'
	$candidates  = @(
		(Join-Path $PSScriptRoot $fileName),                                      # same folder as script
		(Join-Path (Split-Path $PSScriptRoot -Parent) "config\$fileName")         # canonical repo layout
	)
	foreach ($path in $candidates) {
		if (Test-Path -Path $path) { return $path }
	}
	return $candidates[0]  # not found — caller will handle the null return from Get-PrimaryApplicationConfig
}

function Get-PrimaryApplicationConfig {
	param(
		[Parameter(Mandatory = $true)]
		[string]$ConfigPath
	)

	if (-not (Test-Path -Path $ConfigPath)) {
		return $null
	}

	$config = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
	$namePatterns = $config.PrimaryApplicationFilters.NamePatterns
	$publisherPatterns = $config.PrimaryApplicationFilters.PublisherPatterns
	$supportingNamePattern = $config.PrimaryApplicationFilters.SupportingPublisherNamePattern

	if ($null -eq $namePatterns -or $namePatterns.Count -eq 0) {
		throw "Primary application config file does not contain any NamePatterns: $ConfigPath"
	}

	if ($null -eq $publisherPatterns -or $publisherPatterns.Count -eq 0) {
		throw "Primary application config file does not contain any PublisherPatterns: $ConfigPath"
	}

	if ([string]::IsNullOrWhiteSpace($supportingNamePattern)) {
		throw "Primary application config file does not contain SupportingPublisherNamePattern: $ConfigPath"
	}

	return $config
}

function Test-IncludeApplication {
	param(
		[Parameter(Mandatory = $true)]
		[object]$RegistryEntry
	)

	$displayName = Get-NormalizedText -Value (Get-OptionalPropertyValue -Object $RegistryEntry -PropertyName 'DisplayName')
	if ([string]::IsNullOrWhiteSpace($displayName)) {
		return $false
	}

	$systemComponent = Get-OptionalPropertyValue -Object $RegistryEntry -PropertyName 'SystemComponent'
	if ($systemComponent -eq 1) {
		return $false
	}

	$parentKeyName = Get-NormalizedText -Value (Get-OptionalPropertyValue -Object $RegistryEntry -PropertyName 'ParentKeyName')
	if (-not [string]::IsNullOrWhiteSpace($parentKeyName)) {
		return $false
	}

	$releaseType = Get-NormalizedText -Value (Get-OptionalPropertyValue -Object $RegistryEntry -PropertyName 'ReleaseType')
	if ($releaseType -in @('Hotfix', 'Update', 'Security Update')) {
		return $false
	}

	if ($displayName -match '^KB\d+') {
		return $false
	}

	return $true
}

function Test-PrimaryApplication {
	param(
		[Parameter(Mandatory = $true)]
		[object]$Application
	)

	$name = Get-NormalizedText -Value $Application.Name
	$publisher = Get-NormalizedText -Value $Application.Publisher

	if ([string]::IsNullOrWhiteSpace($name)) {
		return $false
	}

	if ($null -eq $script:PrimaryApplicationConfig) {
		return $true  # no config loaded — include all applications
	}

	$namePatterns = $script:PrimaryApplicationConfig.PrimaryApplicationFilters.NamePatterns
	$publisherPatterns = $script:PrimaryApplicationConfig.PrimaryApplicationFilters.PublisherPatterns
	$supportingNamePattern = $script:PrimaryApplicationConfig.PrimaryApplicationFilters.SupportingPublisherNamePattern

	foreach ($pattern in $namePatterns) {
		if ($name -match $pattern) {
			return $false
		}
	}

	if (-not [string]::IsNullOrWhiteSpace($publisher)) {
		foreach ($pattern in $publisherPatterns) {
			if ($publisher -match $pattern -and $name -match $supportingNamePattern) {
				return $false
			}
		}
	}

	return $true
}

function Convert-InstallDate {
	param(
		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[string]$RawDate
	)

	if ([string]::IsNullOrWhiteSpace($RawDate)) {
		return $null
	}

	$datePatterns = @('yyyyMMdd', 'yyyy-MM-dd', 'MM/dd/yyyy', 'dd/MM/yyyy')
	foreach ($pattern in $datePatterns) {
		try {
			$parsed = [datetime]::ParseExact($RawDate.Trim(), $pattern, $null)
			return $parsed.ToString('yyyy-MM-dd')
		}
		catch {
			continue
		}
	}

	try {
		return ([datetime]::Parse($RawDate)).ToString('yyyy-MM-dd')
	}
	catch {
		return $RawDate
	}
}

function Get-InstalledApplications {
	param(
		[Parameter(Mandatory = $false)]
		[bool]$PrimaryApplicationsOnlyMode = $false
	)

	$uninstallRegistryPaths = @(
		'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
		'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
		'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
	)

	$apps = foreach ($path in $uninstallRegistryPaths) {
		Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
			Where-Object {
				Test-IncludeApplication -RegistryEntry $_
			} |
			ForEach-Object {
				$displayName = Get-NormalizedText -Value (Get-OptionalPropertyValue -Object $_ -PropertyName 'DisplayName')
				$publisher = Get-NormalizedText -Value (Get-OptionalPropertyValue -Object $_ -PropertyName 'Publisher')
				$installDate = Get-OptionalPropertyValue -Object $_ -PropertyName 'InstallDate'
				$displayVersion = Get-NormalizedText -Value (Get-OptionalPropertyValue -Object $_ -PropertyName 'DisplayVersion')

				[PSCustomObject]@{
					Name        = $displayName
					Publisher   = if ([string]::IsNullOrWhiteSpace($publisher)) { $null } else { $publisher }
					InstallDate = Convert-InstallDate -RawDate $installDate
					Version     = if ([string]::IsNullOrWhiteSpace($displayVersion)) { $null } else { $displayVersion }
				}
			}
	}

	$deduplicatedApps = $apps |
		Sort-Object -Property Name, Publisher, Version -Unique

	if ($PrimaryApplicationsOnlyMode) {
		return $deduplicatedApps | Where-Object {
			Test-PrimaryApplication -Application $_
		}
	}

	return $deduplicatedApps
}

function Get-RdpShortpathDiscovery {
	<#
	.SYNOPSIS
	Reports whether RDP Shortpath is configured and whether it has been used recently.

	.DESCRIPTION
	RDP Shortpath has two independent modes — both can be enabled simultaneously:

	  Managed Networks  — UDP transport over ExpressRoute/VPN/direct LAN. Enabled by setting
	                      fUseUdpPortRedirector = 1 in the WinStation or Group Policy hive.
	                      Listens on a configurable UDP port (default 3390).

	  Public Networks   — UDP transport over the internet using STUN/TURN. Enabled by setting
	                      ICEControl = 2 in the same hives. Requires the AVD host agent and
	                      outbound UDP to the STUN endpoints. No fixed inbound port required.

	Configuration is read from three hives in precedence order:
	  1. HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services  (Group Policy)
	  2. HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp  (WinStation)
	  3. HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server  (RD Session Host)

	Recent usage is inferred from the RdpCoreTS operational event log:
	  Event 131 — "Shortpath transport established" (managed or public network)
	  Event 70  — "A connection was established using UDP transport" (legacy UDP indicator)

	UdpListenerActive reports whether the configured UDP port has an active listener, which
	confirms the service is running and the firewall has not silently blocked the bind.
	#>

	$gpPath     = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
	$winStaPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
	$rdSrvPath  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'

	$gpVals     = Get-RegistryKeyValues -Path $gpPath
	$winStaVals = Get-RegistryKeyValues -Path $winStaPath
	$rdSrvVals  = Get-RegistryKeyValues -Path $rdSrvPath

	# Helper: resolve a DWORD flag from the three hives in precedence order
	function Resolve-Flag {
		param([string]$Name, [object]$Gp, [object]$WinSta, [object]$RdSrv)
		foreach ($pair in @(
			[PSCustomObject]@{ V = $Gp;     S = 'GroupPolicy'      }
			[PSCustomObject]@{ V = $WinSta; S = 'LocalWinStation'  }
			[PSCustomObject]@{ V = $RdSrv;  S = 'LocalRdServer'    }
		)) {
			if ($null -eq $pair.V) { continue }
			$raw = Get-OptionalPropertyValue -Object $pair.V -PropertyName $Name
			if ($null -ne $raw) { return [PSCustomObject]@{ RawValue = [int]$raw; Source = $pair.S } }
		}
		return [PSCustomObject]@{ RawValue = $null; Source = 'NotConfigured' }
	}

	# --- Managed network Shortpath ---
	# fUseUdpPortRedirector: 1 = enabled, 0 or absent = disabled
	$managedFlag = Resolve-Flag -Name 'fUseUdpPortRedirector' -Gp $gpVals -WinSta $winStaVals -RdSrv $rdSrvVals
	$managedEnabled = if ($null -ne $managedFlag.RawValue) { $managedFlag.RawValue -eq 1 } else { $false }

	# UdpPortNumber: default 3390 when not explicitly set
	$udpPortFlag = Resolve-Flag -Name 'UdpPortNumber' -Gp $gpVals -WinSta $winStaVals -RdSrv $rdSrvVals
	$udpPort     = if ($null -ne $udpPortFlag.RawValue -and $udpPortFlag.RawValue -gt 0) { $udpPortFlag.RawValue } else { 3390 }
	$udpPortSource = if ($null -ne $udpPortFlag.RawValue -and $udpPortFlag.RawValue -gt 0) { $udpPortFlag.Source } else { 'Default' }

	# Check whether the UDP listener is actually bound on the configured port
	$udpListenerActive = $false
	try {
		$udpEndpoints = Get-NetUDPEndpoint -ErrorAction SilentlyContinue
		if ($udpEndpoints) {
			$udpListenerActive = @($udpEndpoints | Where-Object { $_.LocalPort -eq $udpPort }).Count -gt 0
		}
	}
	catch { }

	# --- Public network Shortpath ---
	# ICEControl: 2 = enabled, 1 = disabled explicitly, 0 or absent = disabled
	$iceFlag           = Resolve-Flag -Name 'ICEControl' -Gp $gpVals -WinSta $winStaVals -RdSrv $rdSrvVals
	$publicEnabled     = if ($null -ne $iceFlag.RawValue) { $iceFlag.RawValue -eq 2 } else { $false }
	$iceControlDisplay = switch ($iceFlag.RawValue) {
		$null { 'NotConfigured' }
		0     { 'Disabled'      }
		1     { 'Disabled'      }
		2     { 'Enabled'       }
		default { "Unknown ($($iceFlag.RawValue))" }
	}

	# --- Recent usage — RdpCoreTS operational event log ---
	# Event 131: "Shortpath transport established for RDP connection"
	# Event 70:  "A connection was established using UDP transport" (older builds)
	$shortpathUsedRecently   = $false
	$shortpathEventQueryDays = 7
	$shortpathEventCount131  = 0
	$shortpathEventCount70   = 0
	$shortpathLastEventTime  = $null
	$recentShortpathEvents   = @()

	try {
		$cutoff = (Get-Date).AddDays(-$shortpathEventQueryDays)
		$logName = 'Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Operational'
		# Event 131: shortpath only when the message says UDP (TCP connections are normal RDP, not shortpath)
		# Event 70:  shortpath only when the message mentions UDP transport
		$events = @(Get-WinEvent -LogName $logName -ErrorAction SilentlyContinue |
			Where-Object { $_.Id -in @(131, 70) -and $_.TimeCreated -ge $cutoff -and $_.Message -match '(?i)UDP' })

		if (@($events).Count -gt 0) {
			$shortpathUsedRecently  = $true
			$shortpathEventCount131 = @($events | Where-Object { $_.Id -eq 131 }).Count
			$shortpathEventCount70  = @($events | Where-Object { $_.Id -eq 70 }).Count
			$shortpathLastEventTime = ($events | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated.ToString('s')
			$recentShortpathEvents  = @($events |
				Group-Object -Property Id, Message |
				ForEach-Object {
					$latest = ($_.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1)
					[PSCustomObject]@{
						Id          = $latest.Id
						Count       = $_.Count
						LastSeen    = $latest.TimeCreated.ToString('s')
						Message     = $latest.Message
					}
				} | Sort-Object LastSeen -Descending)
		}
	}
	catch { }

	# --- AVD host agent — carries the STUN/TURN client needed for public Shortpath ---
	$agentService = Get-Service -Name 'RDAgentBootLoader' -ErrorAction SilentlyContinue
	$agentVersion = $null
	$agentBinaryPaths = @(
		'C:\Program Files\Microsoft RDInfra\RDAgent\RDAgentBootLoader.exe',
		'C:\Program Files\Microsoft RDInfra\RDAgentBootLoader.exe'
	)
	foreach ($p in $agentBinaryPaths) {
		if (Test-Path -Path $p) {
			$fvi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($p)
			$agentVersion = Get-NormalizedText -Value $fvi.FileVersion
			break
		}
	}

	[PSCustomObject]@{
		ManagedNetworkShortpath = [PSCustomObject]@{
			Enabled           = $managedEnabled
			Source            = $managedFlag.Source
			UdpPort           = $udpPort
			UdpPortSource     = $udpPortSource
			UdpListenerActive = $udpListenerActive
		}
		PublicNetworkShortpath  = [PSCustomObject]@{
			Enabled            = $publicEnabled
			ICEControlValue    = $iceFlag.RawValue
			ICEControlDisplay  = $iceControlDisplay
			Source             = $iceFlag.Source
		}
		ShortpathUsedRecently        = $shortpathUsedRecently
		ShortpathRecentEventLookback = "${shortpathEventQueryDays}d"
		ShortpathEvent131Count       = $shortpathEventCount131
		ShortpathEvent70Count        = $shortpathEventCount70
		ShortpathLastEventTime       = $shortpathLastEventTime
		RecentShortpathEvents        = $recentShortpathEvents
		AvdAgentService              = if ($null -eq $agentService) { $null } else { [string]$agentService.Status }
		AvdAgentVersion              = $agentVersion
	}
}

function Get-RdpRedirectionDiscovery {
	<#
	.SYNOPSIS
	Reports the effective RDP device-redirection and session settings on this host.

	.DESCRIPTION
	Reads three registry hives in priority order:
	  1. HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services  (Group Policy — highest precedence)
	  2. HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp  (local WinStation config)
	  3. HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server  (general RD Session Host settings)

	For each redirection, 'Effective' reflects the highest-precedence source that has a value.
	A value of $true means the redirection is ENABLED (allowed); $false means DISABLED (blocked).
	'Source' indicates which hive supplied the effective value: GroupPolicy, LocalWinStation, or LocalRdServer.
	#>

	# Registry paths in descending precedence order
	$gpPath        = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
	$winStaPath    = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
	$rdServerPath  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'

	$gpVals       = Get-RegistryKeyValues -Path $gpPath
	$winStaVals   = Get-RegistryKeyValues -Path $winStaPath
	$rdServerVals = Get-RegistryKeyValues -Path $rdServerPath

	# Helper: reads a DWORD from the three hives in priority order and converts to a
	# boolean redirection-enabled value. fDisable* values: 0 = enabled, 1 = disabled.
	# fAllow* / fEnable* values: 0 = disabled, 1 = enabled. Pass -Inverted for fDisable* keys.
	function Resolve-RdpFlag {
		param(
			[string]$Name,
			[switch]$Inverted,   # set for fDisable* keys (0 means allowed)
			[object]$Gp,
			[object]$WinSta,
			[object]$RdServer
		)
		foreach ($pair in @([PSCustomObject]@{V=$Gp;S='GroupPolicy'}, [PSCustomObject]@{V=$WinSta;S='LocalWinStation'}, [PSCustomObject]@{V=$RdServer;S='LocalRdServer'})) {
			if ($null -eq $pair.V) { continue }
			$raw = Get-OptionalPropertyValue -Object $pair.V -PropertyName $Name
			if ($null -eq $raw) { continue }
			$enabled = if ($Inverted) { [int]$raw -eq 0 } else { [int]$raw -ne 0 }
			return [PSCustomObject]@{ Enabled = $enabled; Source = $pair.S; RawValue = [int]$raw }
		}
		return [PSCustomObject]@{ Enabled = $null; Source = 'NotConfigured'; RawValue = $null }
	}

	# Helper: reads a plain value (non-boolean) from the three hives in priority order.
	function Resolve-RdpValue {
		param([string]$Name, [object]$Gp, [object]$WinSta, [object]$RdServer)
		foreach ($pair in @([PSCustomObject]@{V=$Gp;S='GroupPolicy'}, [PSCustomObject]@{V=$WinSta;S='LocalWinStation'}, [PSCustomObject]@{V=$RdServer;S='LocalRdServer'})) {
			if ($null -eq $pair.V) { continue }
			$raw = Get-OptionalPropertyValue -Object $pair.V -PropertyName $Name
			if ($null -ne $raw) { return [PSCustomObject]@{ Value = $raw; Source = $pair.S } }
		}
		return [PSCustomObject]@{ Value = $null; Source = 'NotConfigured' }
	}

	# --- Device redirections ---
	# fDisable* keys: 0 = redirection allowed, 1 = blocked  (-Inverted)
	# fEnable* / fAllow* keys: 0 = disabled, 1 = enabled
	$clipboard        = Resolve-RdpFlag -Name 'fDisableClip'             -Inverted -Gp $gpVals -WinSta $winStaVals -RdServer $rdServerVals
	$driveRedir       = Resolve-RdpFlag -Name 'fDisableCdm'              -Inverted -Gp $gpVals -WinSta $winStaVals -RdServer $rdServerVals
	$printerRedir     = Resolve-RdpFlag -Name 'fDisableCpm'              -Inverted -Gp $gpVals -WinSta $winStaVals -RdServer $rdServerVals
	$comPortRedir     = Resolve-RdpFlag -Name 'fDisableCCM'              -Inverted -Gp $gpVals -WinSta $winStaVals -RdServer $rdServerVals
	$lptPortRedir     = Resolve-RdpFlag -Name 'fDisableLPT'              -Inverted -Gp $gpVals -WinSta $winStaVals -RdServer $rdServerVals
	$smartCardRedir   = Resolve-RdpFlag -Name 'fEnableSmartCard'                   -Gp $gpVals -WinSta $winStaVals -RdServer $rdServerVals
	$audioPlayRedir   = Resolve-RdpFlag -Name 'fDisableAudio'            -Inverted -Gp $gpVals -WinSta $winStaVals -RdServer $rdServerVals
	$audioRecRedir    = Resolve-RdpFlag -Name 'fDisableAudioCapture'     -Inverted -Gp $gpVals -WinSta $winStaVals -RdServer $rdServerVals
	$videoCapRedir    = Resolve-RdpFlag -Name 'fDisableCameraRedir'      -Inverted -Gp $gpVals -WinSta $winStaVals -RdServer $rdServerVals
	$usbRedir         = Resolve-RdpFlag -Name 'fDisableUsbRedirection'   -Inverted -Gp $gpVals -WinSta $winStaVals -RdServer $rdServerVals
	$pnpRedir         = Resolve-RdpFlag -Name 'fDisablePNPRedir'         -Inverted -Gp $gpVals -WinSta $winStaVals -RdServer $rdServerVals

	# --- Session / security settings ---
	$denyConnections  = Resolve-RdpFlag -Name 'fDenyTSConnections'                 -Gp $gpVals -WinSta $winStaVals -RdServer $rdServerVals
	$promptPassword   = Resolve-RdpFlag -Name 'fPromptForPassword'                 -Gp $gpVals -WinSta $winStaVals -RdServer $rdServerVals
	$nlaRequired      = Resolve-RdpFlag -Name 'UserAuthentication'                 -Gp $gpVals -WinSta $winStaVals -RdServer $rdServerVals
	$maxIdleTime      = Resolve-RdpValue -Name 'MaxIdleTime'                       -Gp $gpVals -WinSta $winStaVals -RdServer $rdServerVals
	$maxDisconTime    = Resolve-RdpValue -Name 'MaxDisconnectionTime'              -Gp $gpVals -WinSta $winStaVals -RdServer $rdServerVals
	$maxConnTime      = Resolve-RdpValue -Name 'MaxConnectionTime'                 -Gp $gpVals -WinSta $winStaVals -RdServer $rdServerVals
	$securityLayer    = Resolve-RdpValue -Name 'SecurityLayer'                     -Gp $gpVals -WinSta $winStaVals -RdServer $rdServerVals
	$encryptionLevel  = Resolve-RdpValue -Name 'MinEncryptionLevel'                -Gp $gpVals -WinSta $winStaVals -RdServer $rdServerVals
	$colorDepth       = Resolve-RdpValue -Name 'ColorDepth'                        -Gp $gpVals -WinSta $winStaVals -RdServer $rdServerVals

	# Human-readable decode maps
	$secLayerMap  = @{ 0 = 'RDP'; 1 = 'Negotiate'; 2 = 'SSL/TLS' }
	$encLevelMap  = @{ 1 = 'Low'; 2 = 'ClientCompatible'; 3 = 'High'; 4 = 'FIPSCompliant' }
	$colorDepthMap = @{ 8 = '8bpp'; 15 = '15bpp'; 16 = '16bpp'; 24 = '24bpp'; 32 = '32bpp' }

	function Format-Milliseconds {
		param([object]$V)
		if ($null -eq $V.Value -or [int]$V.Value -eq 0) { return [PSCustomObject]@{ Value = $V.Value; Display = 'NoLimit'; Source = $V.Source } }
		$ms = [int]$V.Value
		$display = if ($ms -ge 60000) { "$([Math]::Round($ms/60000,1)) min" } else { "$ms ms" }
		return [PSCustomObject]@{ Value = $V.Value; Display = $display; Source = $V.Source }
	}

	[PSCustomObject]@{
		# Device redirections
		ClipboardRedirection        = $clipboard
		DriveRedirection            = $driveRedir
		PrinterRedirection          = $printerRedir
		ComPortRedirection          = $comPortRedir
		LptPortRedirection          = $lptPortRedir
		SmartCardRedirection        = $smartCardRedir
		AudioPlaybackRedirection    = $audioPlayRedir
		AudioCaptureRedirection     = $audioRecRedir
		VideoCaptureRedirection     = $videoCapRedir
		UsbRedirection              = $usbRedir
		PnpDeviceRedirection        = $pnpRedir
		# Session / security
		RdpConnectionsAllowed       = if ($null -eq $denyConnections.Enabled) { [PSCustomObject]@{ Enabled = $null; Source = 'NotConfigured'; RawValue = $null } } else { [PSCustomObject]@{ Enabled = -not $denyConnections.Enabled; Source = $denyConnections.Source; RawValue = $denyConnections.RawValue } }
		NetworkLevelAuthRequired    = $nlaRequired
		PromptForPassword           = $promptPassword
		SecurityLayer               = [PSCustomObject]@{ Value = $securityLayer.Value; Display = if ($null -ne $securityLayer.Value -and $secLayerMap.ContainsKey([int]$securityLayer.Value)) { $secLayerMap[[int]$securityLayer.Value] } else { $null }; Source = $securityLayer.Source }
		EncryptionLevel             = [PSCustomObject]@{ Value = $encryptionLevel.Value; Display = if ($null -ne $encryptionLevel.Value -and $encLevelMap.ContainsKey([int]$encryptionLevel.Value)) { $encLevelMap[[int]$encryptionLevel.Value] } else { $null }; Source = $encryptionLevel.Source }
		ColorDepth                  = [PSCustomObject]@{ Value = $colorDepth.Value; Display = if ($null -ne $colorDepth.Value -and $colorDepthMap.ContainsKey([int]$colorDepth.Value)) { $colorDepthMap[[int]$colorDepth.Value] } else { $null }; Source = $colorDepth.Source }
		MaxIdleTime                 = Format-Milliseconds -V $maxIdleTime
		MaxDisconnectionTime        = Format-Milliseconds -V $maxDisconTime
		MaxConnectionTime           = Format-Milliseconds -V $maxConnTime
		GroupPolicyRawValues        = $gpVals
		LocalWinStationRawValues    = $winStaVals
	}
}

function Get-MachineDetails {
	$computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
	$hostname = Get-NormalizedText -Value $computerSystem.Name
	$domain = Get-NormalizedText -Value $computerSystem.Domain

	if (-not $computerSystem.PartOfDomain) {
		$domain = Get-NormalizedText -Value (Get-OptionalPropertyValue -Object $computerSystem -PropertyName 'Workgroup')
	}

	[PSCustomObject]@{
		Hostname = $hostname
		Domain   = $domain
		PartOfDomain = [bool]$computerSystem.PartOfDomain
		Manufacturer = Get-NormalizedText -Value $computerSystem.Manufacturer
		Model        = Get-NormalizedText -Value $computerSystem.Model
	}
}

function Get-CustomerAbbreviation {
	param(
		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[string]$Value
	)

	$abbreviation = Get-NormalizedText -Value $Value
	while ([string]::IsNullOrWhiteSpace($abbreviation)) {
		$abbreviation = Get-NormalizedText -Value (Read-Host 'Enter customer abbreviation for the export filename')
	}

	return $abbreviation.ToLowerInvariant()
}

function New-ExportFilePath {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Directory,

		[Parameter(Mandatory = $true)]
		[string]$CustomerCode,

		[Parameter(Mandatory = $true)]
		[string]$Hostname
	)

	$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
	$fileName = '{0}-{1}-avd-discovery-{2}.json' -f $CustomerCode, $Hostname.ToLowerInvariant(), $timestamp
	return Join-Path -Path $Directory -ChildPath $fileName
}

function Write-AvdHtmlReport {
	param(
		[Parameter(Mandatory = $true)]
		$Data,

		[Parameter(Mandatory = $true)]
		[string]$OutputPath,

		[Parameter(Mandatory = $true)]
		[string]$Title,

		[Parameter(Mandatory = $false)]
		[string]$SourceJsonFileName
	)

	$resolvedTitle = $Title
	$looksLikeCommand = -not [string]::IsNullOrWhiteSpace($resolvedTitle) -and (
		($resolvedTitle.Length -gt 120 -and (
			$resolvedTitle -match '(?i)(Get-Location|ParseFile|Write-AvdHtmlReport|ConvertFrom-Json|Join-Path)' -or
			($resolvedTitle -match '\$[A-Za-z_][A-Za-z0-9_]*' -and $resolvedTitle -match ';')
		)) -or
		$resolvedTitle -match '(?i)(^|\s)(?:\.\\|[A-Za-z]:\\)[^\r\n]+\.ps1\b.*\s-[A-Za-z][A-Za-z0-9]*'
	)
	if ([string]::IsNullOrWhiteSpace($resolvedTitle) -or $looksLikeCommand) {
		if ($Data.PSObject.Properties['HostPools']) {
			$resolvedTitle = if ([string]::IsNullOrWhiteSpace($Data.CustomerAbbreviation)) { 'AVD Metrics Report' } else { "AVD Metrics Report - $($Data.CustomerAbbreviation)" }
		}
		elseif ($Data.PSObject.Properties['Machine']) {
			$resolvedTitle = if ($Data.Machine -and -not [string]::IsNullOrWhiteSpace($Data.Machine.Hostname)) { "AVD Host Audit Report - $($Data.Machine.Hostname)" } else { 'AVD Host Audit Report' }
		}
		else {
			$resolvedTitle = 'AVD Discovery Report'
		}
	}

	$jsonPayload = $Data | ConvertTo-Json -Depth 12 -Compress
	$payloadB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($jsonPayload))
	$titleJson = $resolvedTitle | ConvertTo-Json -Compress
	$titleHtml = [System.Net.WebUtility]::HtmlEncode($resolvedTitle)
	$sourceJson = $SourceJsonFileName | ConvertTo-Json -Compress
	$generatedAtJson = (Get-Date).ToString('s') | ConvertTo-Json -Compress

	$htmlTemplate = @'
<!DOCTYPE html>
<html lang="en">
<head>
	<meta charset="utf-8">
	<meta name="viewport" content="width=device-width, initial-scale=1">
	<title>__REPORT_TITLE_HTML__</title>
	<style>
		:root {
			--bg: #eef1f4;
			--bg-2: #ffffff;
			--panel: rgba(255, 255, 255, 0.78);
			--panel-2: rgba(247, 249, 251, 0.84);
			--panel-soft: rgba(0, 109, 203, 0.08);
			--text: #1d252c;
			--muted: #66727d;
			--accent: #006dcb;
			--accent-2: #0058a8;
			--accent-3: #7fb9ea;
			--line: rgba(29, 37, 44, 0.12);
			--shadow: 0 18px 42px rgba(29, 37, 44, 0.08);
			--block-inner-shadow: inset 0 0 26px rgba(29, 37, 44, 0.035), inset 0 1px 0 rgba(255, 255, 255, 0.72);
			--radius: 20px;
		}
		* { box-sizing: border-box; }
		body {
			margin: 0;
			font-family: "Segoe UI", "Aptos", system-ui, sans-serif;
			color: var(--text);
			background:
				radial-gradient(circle at top left, rgba(0, 109, 203, 0.08), transparent 22%),
				radial-gradient(circle at top right, rgba(0, 109, 203, 0.06), transparent 28%),
				radial-gradient(circle at 50% 120%, rgba(29, 37, 44, 0.05), transparent 34%),
				linear-gradient(180deg, var(--bg-2) 0%, var(--bg) 100%);
			background-attachment: fixed;
			position: relative;
			overflow-x: hidden;
		}
		body::before,
		body::after {
			content: "";
			position: fixed;
			inset: auto;
			pointer-events: none;
			filter: blur(52px);
			opacity: 0.22;
			z-index: 0;
		}
		body::before {
			top: 72px;
			left: -120px;
			width: 320px;
			height: 320px;
			background: radial-gradient(circle, rgba(0, 109, 203, 0.08), transparent 68%);
		}
		body::after {
			right: -100px;
			bottom: 48px;
			width: 280px;
			height: 280px;
			background: radial-gradient(circle, rgba(29, 37, 44, 0.06), transparent 68%);
		}
		.page {
			width: min(1500px, calc(100vw - 32px));
			margin: 24px auto 40px;
			position: relative;
			z-index: 1;
		}
		.hero {
			padding: 28px;
			border: 1px solid rgba(29, 37, 44, 0.10);
			border-radius: 28px;
			background:
				linear-gradient(135deg, rgba(255, 255, 255, 0.98), rgba(248, 249, 251, 0.98) 44%, rgba(240, 246, 252, 0.98)),
				radial-gradient(circle at top right, rgba(0, 109, 203, 0.08), transparent 32%);
			color: var(--text);
			box-shadow: 0 18px 42px rgba(29, 37, 44, 0.08), var(--block-inner-shadow);
			backdrop-filter: blur(18px) saturate(114%);
			-webkit-backdrop-filter: blur(18px) saturate(114%);
			position: relative;
			overflow: hidden;
		}
		.hero::after {
			content: "";
			position: absolute;
			inset: auto -70px -90px auto;
			width: 240px;
			height: 240px;
			border-radius: 50%;
			background: radial-gradient(circle, rgba(0, 109, 203, 0.06), transparent 66%);
			pointer-events: none;
		}
		.hero::before {
			content: "";
			position: absolute;
			inset: 0;
			background: linear-gradient(135deg, rgba(255, 255, 255, 0.34), rgba(255, 255, 255, 0.08) 24%, transparent 48%);
			pointer-events: none;
		}
		.hero h1 {
			margin: 0 0 10px;
			font-size: clamp(28px, 4vw, 42px);
			line-height: 1.05;
			letter-spacing: -0.03em;
			color: #000000;
		}
		.hero p {
			margin: 0;
			max-width: 80ch;
			color: rgba(102, 114, 125, 0.95);
			line-height: 1.5;
			overflow-wrap: anywhere;
		}
		.hero-meta, .kpi-grid {
			display: grid;
			gap: 12px;
		}
		.hero-meta {
			margin-top: 18px;
			grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
		}
		.chip {
			display: inline-flex;
			align-items: center;
			flex-wrap: wrap;
			gap: 6px;
			padding: 10px 16px;
			border-radius: 999px;
			background: rgba(255, 255, 255, 0.82);
			border: 1px solid rgba(29, 37, 44, 0.10);
			box-shadow: 0 10px 22px rgba(29, 37, 44, 0.05), inset 0 0 18px rgba(29, 37, 44, 0.03), inset 0 1px 0 rgba(255, 255, 255, 0.66);
			backdrop-filter: blur(12px) saturate(108%);
			-webkit-backdrop-filter: blur(12px) saturate(108%);
			font-size: 13px;
			letter-spacing: 0.02em;
			min-width: 0;
			overflow-wrap: anywhere;
		}
		.chip strong,
		.chip span {
			min-width: 0;
			overflow-wrap: anywhere;
		}
		.toolbar {
			display: flex;
			flex-wrap: wrap;
			gap: 12px;
			align-items: center;
			justify-content: space-between;
			margin: 18px 0 14px;
		}
		.toolbar-left {
			display: flex;
			flex-wrap: wrap;
			gap: 10px;
			align-items: center;
			min-width: 0;
		}
		.toolbar input {
			width: min(420px, 100%);
			padding: 13px 16px;
			border: 1px solid rgba(29, 37, 44, 0.12);
			border-radius: 14px;
			background: rgba(255, 255, 255, 0.88);
			color: var(--text);
			outline: none;
			box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.66);
			backdrop-filter: blur(12px) saturate(108%);
			-webkit-backdrop-filter: blur(12px) saturate(108%);
		}
		.toolbar input::placeholder {
			color: rgba(102, 114, 125, 0.72);
		}
		.toolbar .note {
			color: var(--muted);
			font-size: 14px;
			overflow-wrap: anywhere;
		}
		.kpi-grid {
			grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
			margin-bottom: 18px;
		}
		.card, .section, .data-card {
			background: var(--panel);
			border: 1px solid rgba(29, 37, 44, 0.10);
			border-radius: var(--radius);
			box-shadow: 0 14px 30px rgba(29, 37, 44, 0.07), inset 0 0 24px rgba(29, 37, 44, 0.03), inset 0 1px 0 rgba(255, 255, 255, 0.62);
			backdrop-filter: blur(12px) saturate(108%);
			-webkit-backdrop-filter: blur(12px) saturate(108%);
		}
		.card {
			background: linear-gradient(180deg, rgba(255, 255, 255, 0.94), rgba(244, 248, 252, 0.88));
			border: 1px solid rgba(255, 255, 255, 0.68);
			box-shadow: 0 0 22px rgba(29, 37, 44, 0.10), 0 0 40px rgba(29, 37, 44, 0.07), inset 0 0 30px rgba(29, 37, 44, 0.04), inset 0 1px 0 rgba(255, 255, 255, 0.88), inset 0 -18px 32px rgba(255, 255, 255, 0.18);
			backdrop-filter: blur(16px) saturate(128%);
			-webkit-backdrop-filter: blur(16px) saturate(128%);
			display: flex;
			flex-direction: column;
			justify-content: space-between;
			gap: 6px;
			padding: 18px 18px 16px 22px;
			min-height: 118px;
			position: relative;
			overflow: hidden;
			background: linear-gradient(180deg, rgba(255, 255, 255, 0.99), rgba(247, 250, 253, 0.97) 58%, rgba(241, 247, 252, 0.92));
		}
		.card::before {
			content: "";
			position: absolute;
			inset: 0 auto 0 0;
			width: 4px;
			background: linear-gradient(180deg, var(--accent-3), var(--accent));
		}
		.card::after {
			content: "";
			position: absolute;
			inset: 0;
			background:
				linear-gradient(180deg, rgba(255, 255, 255, 0.34), rgba(255, 255, 255, 0.08) 34%, transparent 72%),
				linear-gradient(180deg, rgba(0, 109, 203, 0.045), transparent 38%),
				radial-gradient(circle at top left, rgba(255, 255, 255, 0.28), transparent 34%),
				radial-gradient(circle at top right, rgba(0, 109, 203, 0.05), transparent 28%);
			pointer-events: none;
		}
		.card > * {
			position: relative;
			z-index: 1;
		}
		.section::after,
		.data-card::after {
			content: "";
			position: absolute;
			inset: 0;
			background:
				linear-gradient(180deg, rgba(0, 109, 203, 0.025), transparent 36%),
				radial-gradient(circle at top left, rgba(0, 109, 203, 0.025), transparent 32%);
			pointer-events: none;
		}
		.eyebrow {
			margin: 0;
			color: #101828;
			font-size: 12px;
			font-weight: 700;
			letter-spacing: 0.10em;
			text-transform: uppercase;
			line-height: 1.35;
		}
		.metric {
			margin: 0;
			font-size: clamp(28px, 3vw, 36px);
			line-height: 1;
			letter-spacing: -0.04em;
			white-space: normal;
			overflow-wrap: break-word;
			word-break: normal;
		}
		.card.join-type .metric {
			font-size: clamp(24px, 2.5vw, 32px);
			white-space: normal;
			overflow-wrap: break-word;
			word-break: normal;
		}
		.subtle {
			margin: 0;
			color: var(--muted);
			font-size: 13px;
			line-height: 1.35;
			overflow-wrap: anywhere;
		}
		.section {
			padding: 20px;
			margin-top: 16px;
			background: linear-gradient(180deg, rgba(255, 255, 255, 0.98), rgba(246, 248, 250, 0.96));
			position: relative;
			overflow: hidden;
		}
		.section::before,
		.data-card::before {
			content: "";
			position: absolute;
			inset: 0 0 auto 0;
			height: 1px;
			background: linear-gradient(90deg, rgba(0, 109, 203, 0.18), rgba(0, 109, 203, 0.02));
			pointer-events: none;
		}
		.section h2 {
			margin: 0 0 8px;
			font-size: 22px;
			letter-spacing: -0.02em;
			color: #000000;
		}
		.section > p {
			margin: 0 0 14px;
			color: var(--muted);
			line-height: 1.45;
			overflow-wrap: anywhere;
		}
		.stat-list {
			display: grid;
			gap: 8px;
		}
		.stat-row {
			display: flex;
			justify-content: space-between;
			align-items: flex-start;
			flex-wrap: wrap;
			gap: 18px;
			padding-bottom: 8px;
			border-bottom: 1px solid var(--line);
			font-size: 14px;
		}
		.stat-row:last-child { border-bottom: 0; padding-bottom: 0; }
		.muted { color: var(--muted); }
		.bar-list {
			display: grid;
			gap: 10px;
		}
		.bar-item {
			display: grid;
			gap: 6px;
		}
		.bar-label {
			display: flex;
			justify-content: space-between;
			align-items: flex-start;
			flex-wrap: wrap;
			gap: 16px;
			font-size: 13px;
			color: var(--muted);
			min-width: 0;
		}
		.bar-track {
			height: 12px;
			border-radius: 999px;
			background: rgba(0, 109, 203, 0.10);
			overflow: hidden;
		}
		.bar-fill {
			height: 100%;
			border-radius: inherit;
			background: linear-gradient(90deg, var(--accent-3), var(--accent), var(--accent-2));
		}
		table {
			width: 100%;
			border-collapse: collapse;
			font-size: 14px;
			min-width: 760px;
		}
		th, td {
			padding: 12px 10px;
			text-align: left;
			vertical-align: top;
			border-bottom: 1px solid var(--line);
			white-space: nowrap;
			overflow-wrap: normal;
			word-break: normal;
		}
		th {
			font-size: 12px;
			text-transform: uppercase;
			letter-spacing: 0.08em;
			color: var(--muted);
		}
		tbody tr:hover {
			background: rgba(0, 109, 203, 0.06);
		}
		.table-wrap {
			overflow-x: auto;
			overflow-y: hidden;
			width: 100%;
			max-width: 100%;
			border-radius: 14px;
			border: 1px solid rgba(29, 37, 44, 0.10);
			background: rgba(250, 251, 252, 0.76);
			backdrop-filter: blur(12px) saturate(108%);
			-webkit-backdrop-filter: blur(12px) saturate(108%);
		}
		.badge {
			display: inline-flex;
			align-items: center;
			padding: 4px 9px;
			border-radius: 999px;
			background: rgba(0, 109, 203, 0.12);
			color: #0058a8;
			font-size: 12px;
			font-weight: 700;
			letter-spacing: 0.03em;
			max-width: 100%;
			overflow-wrap: anywhere;
		}
		.badge.neutral {
			background: rgba(29, 37, 44, 0.08);
			color: #52606c;
		}
		details {
			border: 1px solid rgba(29, 37, 44, 0.10);
			border-radius: 14px;
			background: rgba(248, 249, 251, 0.80);
			padding: 10px 12px;
			overflow: hidden;
			backdrop-filter: blur(12px) saturate(108%);
			-webkit-backdrop-filter: blur(12px) saturate(108%);
		}
		details + details { margin-top: 10px; }
		summary {
			cursor: pointer;
			font-weight: 700;
			color: var(--text);
			overflow-wrap: anywhere;
		}
		.section-grid {
			display: grid;
			grid-template-columns: repeat(2, minmax(0, 1fr));
			gap: 14px;
		}
		.data-card {
			padding: 0;
			overflow: hidden;
			background: linear-gradient(180deg, rgba(255, 255, 255, 1), rgba(246, 248, 250, 1));
			position: relative;
		}
		.data-card.wide {
			grid-column: 1 / -1;
		}
		.data-card.compact .data-card-body {
			padding-top: 12px;
		}
		.data-card.compact .key-value {
			gap: 6px;
		}
		.data-card-head {
			display: flex;
			align-items: center;
			justify-content: space-between;
			gap: 12px;
			padding: 14px 18px;
			border-bottom: 1px solid rgba(29, 37, 44, 0.08);
			background: linear-gradient(90deg, rgba(0, 109, 203, 0.08), rgba(0, 109, 203, 0.015));
		}
		.data-card-head h3 {
			margin: 0;
			font-size: 17px;
			letter-spacing: -0.02em;
			overflow-wrap: anywhere;
			flex: 1 1 auto;
			color: #000000;
		}
		.section-actions {
			display: flex;
			gap: 8px;
			flex: 0 0 auto;
		}
		.section-button {
			appearance: none;
			border: 1px solid rgba(29, 37, 44, 0.12);
			background: #ffffff;
			color: var(--text);
			border-radius: 999px;
			padding: 7px 12px;
			font: inherit;
			font-size: 12px;
			font-weight: 700;
			letter-spacing: 0.03em;
			cursor: pointer;
		}
		.section-button:hover {
			background: rgba(0, 109, 203, 0.04);
		}
		.data-card-body {
			padding: 14px 18px 16px;
		}
		.key-value {
			display: grid;
			gap: 6px;
		}
		.kv-row {
			display: grid;
			grid-template-columns: minmax(120px, 180px) 1fr;
			gap: 12px;
			padding-bottom: 6px;
			border-bottom: 1px solid var(--line);
			font-size: 14px;
		}
		.kv-row:last-child { border-bottom: 0; padding-bottom: 0; }
		.kv-row dt {
			color: var(--muted);
			font-weight: 600;
			overflow-wrap: anywhere;
		}
		.kv-row dd {
			margin: 0;
			min-width: 0;
			overflow-wrap: anywhere;
			word-break: break-word;
		}
		.chips {
			display: flex;
			flex-wrap: wrap;
			gap: 8px;
		}
		pre {
			margin: 0;
			padding: 18px;
			overflow: auto;
			border-radius: 14px;
			background: rgba(243, 246, 249, 0.98);
			color: #33414d;
			font-size: 12px;
			line-height: 1.5;
			max-height: 560px;
			white-space: pre-wrap;
			overflow-wrap: anywhere;
		}
		.hidden { display: none !important; }
		@media (max-width: 720px) {
			.page { width: min(100vw - 18px, 1500px); margin-top: 10px; }
			.hero, .section, .card { padding: 16px; }
			.kv-row { grid-template-columns: 1fr; gap: 4px; }
			.toolbar { align-items: stretch; }
			.toolbar input { width: 100%; }
			.section-grid { grid-template-columns: 1fr; }
			table { min-width: 640px; }
			th, td { white-space: normal; overflow-wrap: break-word; }
		}
	</style>
</head>
<body>
	<div class="page">
		<section class="hero">
			<h1 id="report-title"></h1>
			<div class="hero-meta" id="hero-meta"></div>
		</section>
		<div class="toolbar">
			<div class="toolbar-left">
				<span class="chip"><strong>Offline</strong> self-contained HTML report</span>
			</div>
			<div class="note" id="source-note"></div>
		</div>
		<section class="kpi-grid" id="kpi-grid"></section>
		<section class="section hidden" id="primary-table-section">
			<h2 id="primary-table-title"></h2>
			<p id="primary-table-copy"></p>
			<div class="table-wrap" id="primary-table-wrap"></div>
		</section>
		<section class="section hidden" id="secondary-table-section">
			<h2 id="secondary-table-title"></h2>
			<p id="secondary-table-copy"></p>
			<div class="table-wrap" id="secondary-table-wrap"></div>
		</section>
		<section class="section" id="data-sections">
			<h2>Structured Data</h2>
			<div class="section-grid" id="data-grid"></div>
		</section>
		<section class="section">
			<h2>Raw JSON</h2>
			<p>Full source payload for copy/paste, ad-hoc browser search, or diffing.</p>
			<pre id="raw-json"></pre>
		</section>
	</div>
	<script>
		const REPORT_TITLE = __REPORT_TITLE__;
		const SOURCE_JSON = __SOURCE_JSON__;
		const GENERATED_AT = __GENERATED_AT__;
		const PAYLOAD_B64 = __REPORT_PAYLOAD__;

		function decodeUtf8Base64(input) {
			const binary = atob(input);
			const bytes = new Uint8Array(binary.length);
			for (let i = 0; i < binary.length; i += 1) {
				bytes[i] = binary.charCodeAt(i);
			}
			return new TextDecoder().decode(bytes);
		}

		const data = JSON.parse(decodeUtf8Base64(PAYLOAD_B64));

		function isPlainObject(value) {
			return value !== null && typeof value === 'object' && !Array.isArray(value);
		}

		function normalizeCollection(value) {
			if (Array.isArray(value)) { return value; }
			if (isPlainObject(value)) {
				const values = Object.values(value);
				if (!values.length) { return []; }
				if (values.every((item) => isPlainObject(item))) { return values; }
				return [value];
			}
			return [];
		}

		function toNumber(value) {
			return typeof value === 'number' && Number.isFinite(value) ? value : null;
		}

		function average(values) {
			const clean = values.filter((value) => typeof value === 'number' && Number.isFinite(value));
			if (!clean.length) { return null; }
			return clean.reduce((sum, value) => sum + value, 0) / clean.length;
		}

		function formatDisplayText(value) {
			const source = String(value);
			const compact = source.replace(/[^A-Za-z0-9]/g, '').toLowerCase();
			const directOverrides = {
				azureadjoined: 'Entra ID Joined',
				hybridazureadjoined: 'Hybrid Entra ID Joined',
				activedirectoryjoined: 'Active Directory Joined',
				workplacejoined: 'Workplace Joined'
			};
			return directOverrides[compact] || source;
		}

		function formatValue(value) {
			if (value === null || value === undefined || value === '') { return 'None'; }
			if (typeof value === 'boolean') { return value ? 'Yes' : 'No'; }
			if (typeof value === 'number') {
				if (Math.abs(value) >= 1000) { return value.toLocaleString(); }
				return Number.isInteger(value) ? String(value) : value.toFixed(2).replace(/\.00$/, '');
			}
			if (Array.isArray(value)) { return value.length ? value.map((item) => formatDisplayText(item)).join(', ') : 'None'; }
			if (isPlainObject(value)) { return Object.keys(value).length + ' field(s)'; }
			return formatDisplayText(value);
		}

		function formatLabel(value) {
			if (value === null || value === undefined || value === '') { return 'Unnamed'; }
			const source = String(value);
			const compact = source.replace(/[^A-Za-z0-9]/g, '').toLowerCase();
			const directOverrides = {
				fslogix: 'FSLogix',
				entrasso: 'Entra SSO',
				onedrive: 'OneDrive',
				ad: 'AD',
				avd: 'AVD',
				vnet: 'VNET',
				vnetname: 'VNET Name',
				vnetresourcegroup: 'VNET Resource Group',
				vnetaddressprefixes: 'VNET Address Prefixes',
				vnetcustomdnsservers: 'VNET Custom DNS Servers',
				laps: 'LAPS',
				teamsmediaoptimization: 'Teams Media Optimisations',
				teamsmediaoptimisation: 'Teams Media Optimisations',
				activedirectorydependencies: 'Active Directory Dependencies',
				avdconnectivity: 'AVD Connectivity',
				rdpshortpath: 'RDP Shortpath',
				rdpredirection: 'RDP Redirection',
				usershellfoldersavailable: 'User Shell Folders Available'
			};
			if (directOverrides[compact]) { return directOverrides[compact]; }
			const wordOverrides = {
				ad: 'AD',
				api: 'API',
				app: 'App',
				apps: 'Apps',
				arm: 'ARM',
				avd: 'AVD',
				cpu: 'CPU',
				fs: 'FS',
				gp: 'GP',
				html: 'HTML',
				id: 'ID',
				intune: 'Intune',
				json: 'JSON',
				kfm: 'KFM',
				laps: 'LAPS',
				rdp: 'RDP',
				sku: 'SKU',
				sso: 'SSO',
				upn: 'UPN',
				url: 'URL',
				vm: 'VM'
			};
			const formatted = source
				.replace(/[_-]+/g, ' ')
				.replace(/([A-Z]+)([A-Z][a-z])/g, '$1 $2')
				.replace(/([a-z0-9])([A-Z])/g, '$1 $2')
				.split(/\s+/)
				.filter(Boolean)
				.map((part) => {
					const lower = part.toLowerCase();
					if (wordOverrides[lower]) { return wordOverrides[lower]; }
					return /^[A-Z0-9]{2,}$/.test(part) ? part : part.charAt(0).toUpperCase() + part.slice(1);
				})
				.join(' ');
			return formatted.replace(/\bOne Drive\b/g, 'OneDrive').replace(/\bV Net\b/g, 'VNET');
		}

		function summarizeItemLabel(item, index) {
			if (isPlainObject(item)) {
				const preferredKeys = ['DisplayName', 'Name', 'Hostname', 'UPN', 'UserPrincipalName', 'Path', 'ComponentName', 'TransportType', 'SkuName'];
				for (const key of preferredKeys) {
					if (item[key]) { return String(item[key]); }
				}
			}
			return 'Item ' + (index + 1);
		}

		function isWideSection(key, value, kind) {
			if (kind === 'host') {
				if (new Set(['Machine', 'ActiveDirectoryDependencies', 'AvdConnectivity', 'GroupPolicy', 'UserProfileExperience']).has(key)) { return true; }
				if (new Set(['JoinState', 'EntraSso', 'FSLogix', 'RdpShortpath', 'RdpRedirection', 'Antivirus', 'IntuneEnrollment', 'Laps', 'TeamsMediaOptimization', 'UniversalPrint', 'TimeSource', 'Printers']).has(key)) { return false; }
			}
			if (kind === 'metrics' && new Set(['CommandOptions', 'ArmCallStats', 'LicenseSummary', 'UnlicensedUsers']).has(key)) { return true; }
			if (Array.isArray(value)) { return true; }
			if (!isPlainObject(value)) { return false; }
			const keys = Object.keys(value);
			if (keys.length > (kind === 'host' ? 7 : 5)) { return true; }
			return keys.some((childKey) => {
				const child = value[childKey];
				return Array.isArray(child) || isPlainObject(child);
			});
		}

		function setDetailsState(root, open) {
			root.querySelectorAll('details').forEach((node) => {
				node.open = open;
			});
		}

		function createSectionActions(body) {
			const detailNodes = Array.from(body.querySelectorAll('details'));
			if (!detailNodes.length) { return null; }
			const actions = document.createElement('div');
			actions.className = 'section-actions';
			const button = document.createElement('button');
			button.type = 'button';
			button.className = 'section-button';
			const syncLabel = () => {
				button.textContent = detailNodes.every((node) => node.open) ? 'Collapse All' : 'Expand All';
			};
			button.addEventListener('click', () => {
				const shouldOpen = !detailNodes.every((node) => node.open);
				setDetailsState(body, shouldOpen);
				syncLabel();
			});
			detailNodes.forEach((node) => node.addEventListener('toggle', syncLabel));
			syncLabel();
			actions.appendChild(button);
			return actions;
		}

		function orderedSectionEntries(kind, source) {
			const order = kind === 'metrics'
				? ['CustomerAbbreviation', 'CollectedAt', 'MetricPeriodStart', 'MetricPeriodEnd', 'HostPools', 'CommandOptions', 'LicenseSummaryStatus', 'LicenseSummary', 'UnlicensedUsers', 'ArmCallStats']
				: ['__ExecutionContext', 'Machine', 'JoinState', 'EntraSso', 'FSLogix', 'UserProfileExperience', 'RdpShortpath', 'RdpRedirection', 'ActiveDirectoryDependencies', 'AvdConnectivity', 'GroupPolicy', 'Antivirus', 'IntuneEnrollment', 'Laps', 'TeamsMediaOptimization', 'UniversalPrint', 'TimeSource', 'Printers'];
			const rank = new Map(order.map((key, index) => [key, index]));
			const entries = Object.entries(source);
			if (kind === 'host') {
				entries.push(['__ExecutionContext', {
					CustomerAbbreviation: data.CustomerAbbreviation,
					CollectedAt: data.CollectedAt,
					CollectionMode: data.CollectionMode,
					RunningAsAccount: data.RunningAsAccount,
					DiscoveryType: data.DiscoveryType,
					GeneratedBy: data.GeneratedBy,
					ProjectCode: data.ProjectCode,
					PrimaryApplicationsOnly: data.PrimaryApplicationsOnly
				}]);
			}
			return entries.sort(([leftKey], [rightKey]) => {
				const leftRank = rank.has(leftKey) ? rank.get(leftKey) : 999;
				const rightRank = rank.has(rightKey) ? rank.get(rightKey) : 999;
				if (leftRank !== rightRank) { return leftRank - rightRank; }
				return leftKey.localeCompare(rightKey);
			});
		}

		function createBadge(text, variant) {
			const badge = document.createElement('span');
			badge.className = 'badge' + (variant ? ' ' + variant : '');
			badge.textContent = text;
			return badge;
		}

		function createCard(label, value, detail) {
			const article = document.createElement('article');
			article.className = 'card';
			article.dataset.card = String(label || '').toLowerCase().replace(/[^a-z0-9]+/g, '-');
			const eyebrow = document.createElement('p');
			eyebrow.className = 'eyebrow';
			eyebrow.textContent = label;
			const metric = document.createElement('p');
			metric.className = 'metric';
			metric.textContent = formatValue(value);
			const subtle = document.createElement('p');
			subtle.className = 'subtle';
			subtle.textContent = detail || '';
			article.append(eyebrow, metric, subtle);
			return article;
		}

		function createSummaryCard(label, value, detail, variant) {
			const card = createCard(label, value, detail);
			if (variant) { card.classList.add(variant); }
			return card;
		}

		function createStatList(items) {
			const wrapper = document.createElement('div');
			wrapper.className = 'stat-list';
			items.forEach((item) => {
				const row = document.createElement('div');
				row.className = 'stat-row';
				const label = document.createElement('span');
				label.className = 'muted';
				label.textContent = item.label;
				const value = document.createElement('strong');
				value.textContent = formatValue(item.value);
				row.append(label, value);
				wrapper.appendChild(row);
			});
			return wrapper;
		}

		function createBarList(items) {
			const wrapper = document.createElement('div');
			wrapper.className = 'bar-list';
			const max = Math.max(...items.map((item) => item.value), 0);
			items.forEach((item) => {
				const node = document.createElement('div');
				node.className = 'bar-item';
				const label = document.createElement('div');
				label.className = 'bar-label';
				const left = document.createElement('span');
				left.textContent = item.label;
				const right = document.createElement('strong');
				right.textContent = formatValue(item.value);
				label.append(left, right);
				const track = document.createElement('div');
				track.className = 'bar-track';
				const fill = document.createElement('div');
				fill.className = 'bar-fill';
				fill.style.width = max > 0 ? ((item.value / max) * 100).toFixed(1) + '%' : '0%';
				track.appendChild(fill);
				node.append(label, track);
				wrapper.appendChild(node);
			});
			return wrapper;
		}

		function objectArrayColumns(rows, preferredKeys) {
			const discovered = [];
			rows.slice(0, 20).forEach((row) => {
				Object.keys(row || {}).forEach((key) => {
					if (!discovered.includes(key)) { discovered.push(key); }
				});
			});
			const preferred = (preferredKeys || []).filter((key) => discovered.includes(key));
			const remainder = discovered.filter((key) => !preferred.includes(key));
			return preferred.concat(remainder).slice(0, 10);
		}

		function createObjectTable(rows, preferredKeys) {
			if (!rows.length) {
				const empty = document.createElement('p');
				empty.className = 'muted';
				empty.textContent = 'No rows available.';
				return empty;
			}
			const table = document.createElement('table');
			const columns = objectArrayColumns(rows, preferredKeys);
			const thead = document.createElement('thead');
			const headRow = document.createElement('tr');
			columns.forEach((column) => {
				const th = document.createElement('th');
				th.textContent = formatLabel(column);
				headRow.appendChild(th);
			});
			thead.appendChild(headRow);
			const tbody = document.createElement('tbody');
			rows.slice(0, 250).forEach((row) => {
				const tr = document.createElement('tr');
				tr.dataset.search = JSON.stringify(row).toLowerCase();
				columns.forEach((column) => {
					const td = document.createElement('td');
					td.textContent = formatValue(row ? row[column] : null);
					tr.appendChild(td);
				});
				tbody.appendChild(tr);
			});
			table.append(thead, tbody);
			return table;
		}

		function wrapTable(table) {
			const wrap = document.createElement('div');
			wrap.className = 'table-wrap';
			wrap.appendChild(table);
			return wrap;
		}

		function renderPrimitiveList(values) {
			const wrapper = document.createElement('div');
			wrapper.className = 'chips';
			values.forEach((value) => wrapper.appendChild(createBadge(formatValue(value), 'neutral')));
			return wrapper;
		}

		function renderStructuredValue(value, depth) {
			const level = depth || 0;
			if (value === null || value === undefined || value === '') {
				const empty = document.createElement('span');
				empty.className = 'muted';
				empty.textContent = 'None';
				return empty;
			}
			if (typeof value !== 'object') {
				const span = document.createElement('span');
				span.textContent = formatValue(value);
				return span;
			}
			if (Array.isArray(value)) {
				if (!value.length) {
					const emptyArray = document.createElement('span');
					emptyArray.className = 'muted';
					emptyArray.textContent = 'Empty list';
					return emptyArray;
				}
				if (value.every((item) => item === null || ['string', 'number', 'boolean'].includes(typeof item))) {
					return renderPrimitiveList(value);
				}
				if (value.every((item) => isPlainObject(item))) {
					return wrapTable(createObjectTable(value, []));
				}
				const container = document.createElement('div');
				value.forEach((item, index) => {
					const details = document.createElement('details');
					const summary = document.createElement('summary');
					summary.textContent = summarizeItemLabel(item, index);
					details.append(summary, renderStructuredValue(item, level + 1));
					container.appendChild(details);
				});
				return container;
			}
			const wrapper = document.createElement('div');
			const primitiveEntries = [];
			const complexEntries = [];
			Object.entries(value).forEach(([key, child]) => {
				const primitiveArray = Array.isArray(child) && child.every((item) => item === null || ['string', 'number', 'boolean'].includes(typeof item)) && child.length <= 12;
				if (child === null || child === undefined || typeof child !== 'object' || primitiveArray) {
					primitiveEntries.push([key, child]);
				} else {
					complexEntries.push([key, child]);
				}
			});
			if (primitiveEntries.length) {
				const dl = document.createElement('dl');
				dl.className = 'key-value';
				primitiveEntries.forEach(([key, child]) => {
					const row = document.createElement('div');
					row.className = 'kv-row';
					const dt = document.createElement('dt');
					dt.textContent = formatLabel(key);
					const dd = document.createElement('dd');
					if (Array.isArray(child)) {
						dd.appendChild(renderPrimitiveList(child));
					} else if (typeof child === 'boolean') {
						dd.appendChild(createBadge(child ? 'Yes' : 'No', child ? '' : 'neutral'));
					} else {
						dd.textContent = formatValue(child);
					}
					row.append(dt, dd);
					dl.appendChild(row);
				});
				wrapper.appendChild(dl);
			}
			complexEntries.forEach(([key, child]) => {
				const details = document.createElement('details');
				const summary = document.createElement('summary');
				summary.textContent = formatLabel(key);
				details.append(summary, renderStructuredValue(child, level + 1));
				wrapper.appendChild(details);
			});
			return wrapper;
		}

		function reportKind() {
			if (Array.isArray(data.HostPools) || isPlainObject(data.HostPools)) { return 'metrics'; }
			if (Array.isArray(data.Applications) || data.DiscoveryType === 'LocalAvdHost') { return 'host'; }
			return 'generic';
		}

		function heroMetaEntries(kind) {
			const entries = [
				['Generated', data.CollectedAt || GENERATED_AT],
				['Customer', data.CustomerAbbreviation || 'n/a'],
				['Generated By', data.GeneratedBy || 'n/a'],
				['Project Code', data.ProjectCode || 'n/a']
			];
			if (kind === 'metrics') { entries.push(['Window', (data.LookbackDays || 'n/a') + ' day(s)']); }
			if (kind === 'host') { entries.push(['Host', data.Machine && data.Machine.Hostname ? data.Machine.Hostname : 'n/a']); }
			return entries;
		}

		function metricsSummary() {
			const hostPools = normalizeCollection(data.HostPools);
			const storage = normalizeCollection(data.StorageAccountScan);
			return [
				{ label: 'Host Pools', value: data.HostPoolCount || hostPools.length, detail: 'AVD pools covered in this export' },
				{ label: 'Subscriptions', value: data.SubscriptionCount, detail: 'Azure subscriptions scanned' },
				{ label: 'Authorised Users', value: data.LicenseSummaryUserCount, detail: 'Unique users resolved from access assignments' },
				{ label: 'Unlicensed Users', value: data.UnlicensedUserCount == null ? 'n/a' : data.UnlicensedUserCount, detail: 'Users with access but no qualifying licence' },
				{ label: 'Avg CPU', value: average(hostPools.map((item) => toNumber(item.AvgCpuPercent))), detail: 'Mean average CPU across pools' },
				{ label: 'Avg Memory', value: average(hostPools.map((item) => toNumber(item.AvgMemUsedPercent))), detail: 'Mean memory used percentage across pools' },
				{ label: 'Peak Sessions', value: Math.max(...hostPools.map((item) => toNumber(item.PeakConcurrentSessions) || 0), 0), detail: 'Highest peak concurrency in any pool' },
				{ label: 'Storage Scans', value: storage.length, detail: 'Storage accounts in the FSLogix scan set' }
			];
		}

		function hostSummary() {
			const fsLogix = data.FSLogix || {};
			const sso = data.EntraSso || {};
			const adDeps = data.ActiveDirectoryDependencies || {};
			const connectivity = data.AvdConnectivity || {};
			const fsLogixDiscovered = !!(
				fsLogix.Installed ||
				fsLogix.ConfigDetected ||
				(fsLogix.ServiceStatus && fsLogix.ServiceStatus !== 'NotInstalled') ||
				toNumber(fsLogix.ProfileContainerCount) > 0 ||
				normalizeCollection(fsLogix.ProfileLocationInventory).length
			);
			const requiredTotal = toNumber(connectivity.RequiredEndpointCount);
			const requiredPassed = toNumber(connectivity.RequiredReachableCount);
			let connectivityValue = 'n/a';
			let connectivityDetail = 'AVD endpoint connectivity checks';
			if (data.ConnectivityChecksSkipped) {
				connectivityValue = 'Skipped';
				connectivityDetail = 'Connectivity checks were skipped for this run';
			} else if (requiredTotal > 0) {
				connectivityValue = requiredPassed + '/' + requiredTotal + ' passed';
				connectivityDetail = connectivity.AllRequiredReachable ? 'All required endpoints reachable' : 'Some required endpoints were unreachable';
			}
			return [
				{ label: 'Applications', value: data.ApplicationCount || normalizeCollection(data.Applications).length, detail: 'Installed apps included in the export' },
				{ label: 'Join Type', value: data.JoinState && data.JoinState.JoinType ? data.JoinState.JoinType : 'n/a', detail: 'Detected device join state', variant: 'join-type' },
				{ label: 'FSLogix', value: fsLogixDiscovered ? 'Found' : 'Missing', detail: 'Profile container platform status' },
				{ label: 'Entra SSO', value: sso.SsoCapable ? 'Capable' : 'Review', detail: 'Host-side SSO readiness summary' },
				{ label: 'AD Dependencies', value: adDeps.HasDomainDependencies ? 'Present' : 'None', detail: 'Services, tasks, ODBC, and live port usage' },
				{ label: 'Connectivity', value: connectivityValue, detail: connectivityDetail }
			];
		}

		function buildTable(sectionIdPrefix, title, copy, rows, preferredKeys) {
			if (!rows.length) { return; }
			document.getElementById(sectionIdPrefix + '-section').classList.remove('hidden');
			document.getElementById(sectionIdPrefix + '-title').textContent = title;
			document.getElementById(sectionIdPrefix + '-copy').textContent = copy;
			const wrap = document.getElementById(sectionIdPrefix + '-wrap');
			wrap.innerHTML = '';
			wrap.appendChild(createObjectTable(rows, preferredKeys));
		}

		function hasRenderableValue(value) {
			if (value === null || value === undefined || value === '') { return false; }
			if (Array.isArray(value)) { return value.length > 0; }
			if (isPlainObject(value)) { return Object.keys(value).length > 0; }
			return true;
		}

		function pickObjectFields(source, keys) {
			const result = {};
			(keys || []).forEach((key) => {
				if (!source || !Object.prototype.hasOwnProperty.call(source, key)) { return; }
				const value = source[key];
				if (!hasRenderableValue(value)) { return; }
				result[key] = value;
			});
			return result;
		}

		function createGroupedSection(title, entries) {
			if (!entries.length) { return null; }
			const panel = document.createElement('article');
			panel.className = 'data-card wide';
			panel.dataset.search = entries.map((entry) => {
				const key = Array.isArray(entry) ? entry[0] : entry.key;
				const value = Array.isArray(entry) ? entry[1] : entry.value;
				return key + ' ' + JSON.stringify(value);
			}).join(' ').toLowerCase();
			const head = document.createElement('div');
			head.className = 'data-card-head';
			const heading = document.createElement('h3');
			heading.textContent = title;
			head.appendChild(heading);
			const body = document.createElement('div');
			body.className = 'data-card-body';
			const grid = document.createElement('div');
			grid.className = 'section-grid';
			entries.forEach((entry) => {
				const key = Array.isArray(entry) ? entry[0] : entry.key;
				const value = Array.isArray(entry) ? entry[1] : entry.value;
				const titleText = Array.isArray(entry) ? (key === '__ExecutionContext' ? 'Execution Context' : formatLabel(key)) : (entry.title || (key === '__ExecutionContext' ? 'Execution Context' : formatLabel(key)));
				const card = document.createElement('article');
				card.className = 'data-card compact';
				card.dataset.search = (key + ' ' + JSON.stringify(value)).toLowerCase();
				const cardHead = document.createElement('div');
				cardHead.className = 'data-card-head';
				const cardHeading = document.createElement('h3');
				cardHeading.textContent = titleText;
				cardHead.appendChild(cardHeading);
				const cardBody = document.createElement('div');
				cardBody.className = 'data-card-body';
				cardBody.appendChild(renderStructuredValue(value, 0));
				const actions = createSectionActions(cardBody);
				if (actions) { cardHead.appendChild(actions); }
				card.append(cardHead, cardBody);
				grid.appendChild(card);
			});
			body.appendChild(grid);
			panel.append(head, body);
			return panel;
		}

		function buildHostStructuredSections() {
			const dataGrid = document.getElementById('data-grid');
			const skip = new Set(['Applications', 'CustomerAbbreviation', 'GeneratedBy', 'ProjectCode', 'CollectedAt', 'CollectionMode', 'RunningAsAccount', 'DiscoveryType', 'PrimaryApplicationsOnly', 'ApplicationCount', 'ConnectivityChecksSkipped']);
			const groupedKeys = [
				['System Details', ['__ExecutionContext', 'Machine', 'JoinState', 'TimeSource', 'Antivirus', 'IntuneEnrollment', 'Laps']],
				['Office Details', ['UserProfileExperience', 'OutlookCachedMode', 'TeamsMediaOptimization', 'RdpRedirection']],
				['Access And Connectivity', ['EntraSso', 'ActiveDirectoryDependencies', 'AvdConnectivity', 'RdpShortpath']],
				['Printing And Peripherals', ['UniversalPrint', 'Printers']],
				['Policy And Configuration', ['GroupPolicy', 'DefaultFileAssociations', 'LanguagePacks']]
			];
			const entryMap = new Map(orderedSectionEntries('host', data).filter(([key]) => !skip.has(key)));
			if (entryMap.has('FSLogix')) {
				const fsLogix = entryMap.get('FSLogix') || {};
				const configurationAndComponents = pickObjectFields(fsLogix, [
					'Installed', 'ServiceName', 'ServiceStatus', 'ConfigDetected', 'EffectiveEnabled', 'CloudCacheInUse', 'CloudCacheLocations', 'CloudCacheLocalCachePath',
					'VolumeType', 'SizeInMBs', 'IsDynamic', 'FlipFlopProfileDirectoryName', 'DeleteLocalProfileWhenVHDShouldApply', 'ConcurrentUserSessions',
					'AccessNetworkAsComputerObject', 'OfficeCloudCacheLocations', 'RedirectionsXml', 'AppMasking', 'RawLocalConfig', 'RawPolicyConfig', 'OfficeContainerLocalConfig', 'OfficeContainerPolicyConfig'
				]);
				const profileStorageAndInventory = pickObjectFields(fsLogix, [
					'ProfileLocations', 'ProfileLocationInventory', 'ProfileContainerCount', 'ProfileContainerTotalBytes', 'ProfileContainerTotalGB'
				]);
				const fsLogixEntries = [];
				if (Object.keys(configurationAndComponents).length) {
					fsLogixEntries.push({ key: 'FSLogixConfiguration', title: 'Configuration And Components', value: configurationAndComponents });
				}
				if (Object.keys(profileStorageAndInventory).length) {
					fsLogixEntries.push({ key: 'FSLogixProfileStorage', title: 'Profile Storage And Inventory', value: profileStorageAndInventory });
				}
				const fsLogixSection = createGroupedSection('FSLogix', fsLogixEntries);
				if (fsLogixSection) { dataGrid.appendChild(fsLogixSection); }
				entryMap.delete('FSLogix');
			}
			groupedKeys.forEach(([title, keys]) => {
				const entries = keys.filter((key) => entryMap.has(key)).map((key) => [key, entryMap.get(key)]);
				keys.forEach((key) => entryMap.delete(key));
				const section = createGroupedSection(title, entries);
				if (section) { dataGrid.appendChild(section); }
			});
			const remaining = Array.from(entryMap.entries());
			const remainderSection = createGroupedSection('Additional Details', remaining);
			if (remainderSection) { dataGrid.appendChild(remainderSection); }
		}

		function buildStructuredSections(kind) {
			if (kind === 'host') {
				buildHostStructuredSections();
				return;
			}
			const dataGrid = document.getElementById('data-grid');
			const skip = kind === 'metrics'
				? new Set(['StorageAccountScan'])
				: new Set(['Applications', 'CustomerAbbreviation', 'GeneratedBy', 'ProjectCode', 'CollectedAt', 'CollectionMode', 'RunningAsAccount', 'DiscoveryType', 'PrimaryApplicationsOnly', 'ApplicationCount']);
			orderedSectionEntries(kind, data).forEach(([key, value]) => {
				if (skip.has(key)) { return; }
				const panel = document.createElement('article');
				panel.className = 'data-card ' + (kind === 'host' ? 'compact' : (isWideSection(key, value, kind) ? 'wide' : 'compact'));
				panel.dataset.search = (key + ' ' + JSON.stringify(value)).toLowerCase();
				const head = document.createElement('div');
				head.className = 'data-card-head';
				const heading = document.createElement('h3');
				heading.textContent = key === '__ExecutionContext' ? 'Execution Context' : formatLabel(key);
				head.appendChild(heading);
				const body = document.createElement('div');
				body.className = 'data-card-body';
				body.appendChild(renderStructuredValue(value, 0));
				const actions = createSectionActions(body);
				if (actions) { head.appendChild(actions); }
				panel.append(head, body);
				dataGrid.appendChild(panel);
			});
		}

		function init() {
			const kind = reportKind();
			document.getElementById('report-title').textContent = REPORT_TITLE;
			const heroMeta = document.getElementById('hero-meta');
			heroMetaEntries(kind).forEach(([label, value]) => {
				const chip = document.createElement('div');
				chip.className = 'chip';
				chip.innerHTML = '<strong>' + label + ':</strong> <span>' + String(formatValue(value)).replace(/</g, '&lt;') + '</span>';
				heroMeta.appendChild(chip);
			});
			document.getElementById('source-note').textContent = SOURCE_JSON ? 'Source JSON: ' + SOURCE_JSON : 'Generated: ' + GENERATED_AT;
			document.getElementById('raw-json').textContent = JSON.stringify(data, null, 2);
			const kpis = kind === 'metrics' ? metricsSummary() : kind === 'host' ? hostSummary() : Object.keys(data).slice(0, 8).map((key) => ({ label: key, value: data[key], detail: 'Top-level field' }));
			const kpiGrid = document.getElementById('kpi-grid');
			kpis.forEach((item) => kpiGrid.appendChild(createSummaryCard(item.label, item.value, item.detail, item.variant)));
			if (kind === 'metrics') {
				buildTable('primary-table', 'Host Pools', 'Per-pool operational and performance summary.', normalizeCollection(data.HostPools), ['Name', 'SubscriptionName', 'Location', 'HostPoolType', 'HostCount', 'AvgCpuPercent', 'AvgMemUsedPercent', 'PeakConcurrentSessions', 'TotalFailedConnections', 'DiagnosticsStatus']);
				buildTable('secondary-table', 'Storage Accounts', 'FSLogix storage scan results included in the export.', normalizeCollection(data.StorageAccountScan), ['StorageAccountName', 'SubscriptionName', 'ResourceGroup', 'Location', 'SkuName', 'PublicNetworkAccess', 'PrivateEndpointCount', 'DefaultAction', 'FileShareCount']);
			} else if (kind === 'host') {
				buildTable('primary-table', 'Applications', 'Installed application inventory from the host export.', normalizeCollection(data.Applications), ['Name', 'Publisher', 'InstallDate', 'Version', 'InstallLocation']);
			}
			buildStructuredSections(kind);
		}

		init();
	</script>
</body>
</html>
'@

	$htmlContent = $htmlTemplate.Replace('__REPORT_TITLE__', $titleJson)
	$htmlContent = $htmlContent.Replace('__REPORT_TITLE_HTML__', $titleHtml)
	$htmlContent = $htmlContent.Replace('__SOURCE_JSON__', $sourceJson)
	$htmlContent = $htmlContent.Replace('__GENERATED_AT__', $generatedAtJson)
	$htmlContent = $htmlContent.Replace('__REPORT_PAYLOAD__', ($payloadB64 | ConvertTo-Json -Compress))

	Set-Content -Path $OutputPath -Value $htmlContent -Encoding UTF8
	return $OutputPath
}

# ------------------------------------------------------------------
# Console output helpers
# ------------------------------------------------------------------

$script:_checkLabel   = ''
$script:_ansiSupported = $host.Name -notmatch 'ISE'
$script:_spinnerSupported = $false
$script:_progressId = 1

try {
	$script:_spinnerSupported = $script:_ansiSupported -and [Environment]::UserInteractive -and -not [Console]::IsOutputRedirected -and -not [Console]::IsInputRedirected
} catch {
	$script:_spinnerSupported = $false
}

function Format-Ansi {
	param([string]$Text)
	if ($script:_ansiSupported) { return $Text }
	return ($Text -replace "`e\[[0-9;]*[mK]", '')
}

function Write-LiveProgress {
	param(
		[string]$Activity,
		[string]$Status,
		[int]$Pct = -1,
		[switch]$Completed
	)

	if ($script:_spinnerSupported) { return }

	$progressParams = @{
		Id          = $script:_progressId
		Activity    = $Activity
		Status      = $Status
	}

	if ($Pct -ge 0) {
		$progressParams['PercentComplete'] = [Math]::Min([Math]::Max($Pct, 0), 100)
	}

	if ($Completed.IsPresent) {
		$progressParams['Completed'] = $true
	}

	try { Write-Progress @progressParams } catch { }
}

function Write-Banner {
	param([string[]]$Lines)
	$maxLen = ($Lines | Measure-Object -Property Length -Maximum).Maximum
	$width  = [Math]::Max(60, $maxLen + 4)
	$border = '═' * $width
	Write-Host ''
	Write-Host (Format-Ansi "  `e[1m`e[96m╔$border╗`e[0m")
	foreach ($line in $Lines) {
		$padded = ' ' + $line.PadRight($width - 1)
		Write-Host (Format-Ansi "  `e[96m║`e[0m`e[97m$padded`e[0m`e[96m║`e[0m")
	}
	Write-Host (Format-Ansi "  `e[1m`e[96m╚$border╝`e[0m")
	Write-Host ''
}

function Write-Rule {
	param([string]$Title = '', [int]$Width = 62)
	if (-not [string]::IsNullOrEmpty($Title)) {
		Write-Host ''
		Write-Host (Format-Ansi "  `e[90m$('─' * $Width)`e[0m")
		Write-Host (Format-Ansi "  `e[1m`e[96m$Title`e[0m")
		Write-Host (Format-Ansi "  `e[90m$('─' * $Width)`e[0m")
	} else {
		Write-Host ''
		Write-Host (Format-Ansi "  `e[90m$('─' * $Width)`e[0m")
		Write-Host ''
	}
}

# Shared state for the background spinner — accessed by both the main thread and the runspace.
$script:_spinnerState = [hashtable]::Synchronized(@{
	Active   = $false
	Activity = 'AVD Session Host Audit'
	Status   = ''
	Pct      = -1
	Run      = $false
	Lock     = [System.Threading.SemaphoreSlim]::new(1, 1)
})
$script:_spinnerJob = $null

function Start-SpinnerRunspace {
	if ($script:_spinnerJob) { return }  # already running
	$state       = $script:_spinnerState
	$state.Run   = $true
	$rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
	$rs.Open()
	$rs.SessionStateProxy.SetVariable('_st', $state)
	$ps = [System.Management.Automation.PowerShell]::Create()
	$ps.Runspace = $rs
	[void]$ps.AddScript({
		$frames = @('|', '/', '-', '\')
		$idx    = 0
		$purple = "`e[95m"; $bold = "`e[1m"; $dim = "`e[2m"; $reset = "`e[0m"
		function Get-TrimmedSpinnerStatus {
			param(
				[string]$Activity,
				[string]$Status,
				[int]$Pct
			)

			$maxWidth = 0
			try { $maxWidth = [Math]::Max([Console]::WindowWidth - 1, 0) } catch { $maxWidth = 0 }
			if ($maxWidth -le 0) { return $Status }

			$barWidth = if ($Pct -ge 0) { 28 } else { 0 }
			$reservedWidth = 6 + $Activity.Length + $barWidth
			$availableStatusWidth = [Math]::Max($maxWidth - $reservedWidth, 12)

			if ([string]::IsNullOrEmpty($Status) -or $Status.Length -le $availableStatusWidth) {
				return $Status
			}

			if ($availableStatusWidth -le 3) {
				return $Status.Substring(0, [Math]::Min($Status.Length, $availableStatusWidth))
			}

			return $Status.Substring(0, $availableStatusWidth - 3) + '...'
		}

		while ($_st.Run) {
			if (-not $_st.Active) { Start-Sleep -Milliseconds 50; continue }
			$s   = $frames[$idx % 4]; $idx++
			$act = $_st.Activity; $sts = $_st.Status; $pct = $_st.Pct
			$sts = Get-TrimmedSpinnerStatus -Activity $act -Status $sts -Pct $pct
			$barStr = ''
			if ($pct -ge 0) {
				$w = 20; $f = [Math]::Min([int]($pct / 100.0 * $w), $w)
				$barStr = "  $dim[$reset$purple$('█' * $f)$dim$('░' * ($w - $f))]$reset  $pct%"
			}
			$line    = "$purple$bold $s  $act$reset  $dim$sts$reset$barStr"
			if ($_st.Lock.Wait(50)) {
				try     { [Console]::Write("`r$line`e[K") }
				finally { [void]$_st.Lock.Release() }
			}
			Start-Sleep -Milliseconds 100
		}
	})
	$script:_spinnerJob = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke() }
}

function Stop-SpinnerRunspace {
	if (-not $script:_spinnerJob) { return }
	$script:_spinnerState.Active = $false
	$script:_spinnerState.Run    = $false
	try { [void]$script:_spinnerJob.PS.EndInvoke($script:_spinnerJob.Handle) } catch {}
	$script:_spinnerJob.PS.Dispose()
	$script:_spinnerJob.RS.Dispose()
	$script:_spinnerJob = $null
}

function Write-SpinnerLine {
	# Not used in this script but kept for parity with the metrics script
	param([string]$Status, [int]$Pct = -1)
	$script:_spinnerState.Status = $Status
	if ($Pct -ge 0) { $script:_spinnerState.Pct = $Pct }
}

function Clear-SpinnerLine {
	Stop-SpinnerRunspace
	Write-LiveProgress -Activity 'AVD Session Host Audit' -Status 'Complete' -Completed
	if ($script:_spinnerSupported) {
		try { [Console]::Write("`r`e[K") } catch { }
	}
	try { [Console]::WriteLine() } catch { Write-Host '' }
}

function Write-CheckStart {
	param([string]$Name, [int]$Indent = 4)
	$script:_checkLabel = (' ' * $Indent) + $Name.PadRight(30) + '  '
	$_pct = -1
	if ($script:_progressTotal -gt 0 -and $script:_spinnerSupported) {
		$_pct = [Math]::Min([int](($script:_progressStep / $script:_progressTotal) * 100), 100)
		$script:_spinnerState.Status   = $Name
		$script:_spinnerState.Pct      = $_pct
		$script:_spinnerState.Active   = $true
		Start-SpinnerRunspace
	} elseif ($script:_progressTotal -gt 0) {
		$_pct = [Math]::Min([int](($script:_progressStep / $script:_progressTotal) * 100), 100)
		Write-LiveProgress -Activity 'AVD Session Host Audit' -Status $Name -Pct $_pct
	}
}

function Write-CheckResult {
	param(
		[ValidateSet('Success', 'Skipped', 'Failed', 'Info')]
		[string]$Status,
		[string]$Detail = ''
	)
	$ansiColor = switch ($Status) {
		'Success' { "`e[92m"  }  # Bright green
		'Skipped' { "`e[93m"  }  # Bright yellow
		'Failed'  { "`e[91m"  }  # Bright red
		'Info'    { "`e[90m"  }  # Dark gray
	}
	$suffix = if ($Detail) { "  ($Detail)" } else { '' }
	if ($script:_progressTotal -gt 0 -and $script:_spinnerSupported) {
		$script:_spinnerState.Active = $false  # pause spinner between checks
		[void]$script:_spinnerState.Lock.Wait()  # wait for any in-flight frame to finish
		try {
			[Console]::Write("`r`e[K")
			[Console]::WriteLine("$ansiColor$($script:_checkLabel)$Status$suffix`e[0m")
		} finally {
			[void]$script:_spinnerState.Lock.Release()
		}
		$script:_progressStep++
	} else {
		if ($script:_progressTotal -gt 0) {
			$_pct = [Math]::Min([int]((($script:_progressStep + 1) / $script:_progressTotal) * 100), 100)
			$_progressStatus = "$($script:_checkLabel.Trim())$Status$suffix"
			Write-LiveProgress -Activity 'AVD Session Host Audit' -Status $_progressStatus -Pct $_pct
			$script:_progressStep++
		}
		$color = switch ($Status) {
			'Success' { 'Green'   }
			'Skipped' { 'Yellow'  }
			'Failed'  { 'Red'     }
			'Info'    { 'DarkGray'}
		}
		Write-Host "$($script:_checkLabel)$Status$suffix" -ForegroundColor $color
	}
}

try {
	Assert-ScriptIsReadOnly

	# Detect whether we are running as SYSTEM or a machine account (e.g. via Azure Run Command).
	# In that context, per-user checks (HKCU/HKEY_USERS, gpresult user RSoP) are meaningless.
	$currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
	$script:IsSystemAccountMode = $currentIdentity.IsSystem -or $currentIdentity.Name -match '\\\S+\$$'
	$script:RunningAsAccount = Get-NormalizedText -Value $currentIdentity.Name

	$script:PrimaryApplicationConfig = Get-PrimaryApplicationConfig -ConfigPath (Get-PrimaryApplicationConfigPath)
	$customerCode = Get-CustomerAbbreviation -Value $CustomerAbbreviation
	$scriptStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

	Write-Banner @(
		'AVD Discovery  —  Session Host Audit',
		'',
		"Customer  :  $customerCode",
		"Machine   :  $($env:COMPUTERNAME)",
		"Account   :  $($script:RunningAsAccount)",
		"Mode      :  $(if ($script:IsSystemAccountMode) { 'System Account (Run Command)' } else { 'Interactive' })"
	)

	$script:_progressStep  = 0
	$script:_progressTotal = 20

	Write-Rule 'HOST INVENTORY'

	Write-CheckStart 'Machine Details'
	$machineDetails = Get-MachineDetails
	Write-CheckResult 'Success' "$($machineDetails.Hostname)  |  $($machineDetails.Manufacturer) $($machineDetails.Model)"

	Write-CheckStart 'Domain / Join State'
	$joinDiscovery = Get-DomainJoinDiscovery
	Write-CheckResult 'Success' "Join Type: $($joinDiscovery.JoinType)"

	Write-CheckStart 'Entra SSO'
	$entraSsoDiscovery = Get-EntraSsoDiscovery
	$_ssoDetail = if (-not $entraSsoDiscovery.SsoCapable) {
		"Not Entra-joined  |  $(@($entraSsoDiscovery.Blockers).Count) blocker(s)"
	} elseif ($entraSsoDiscovery.AzureAdPrt -eq $true) {
		"Capable  |  PRT: Active$(if ($entraSsoDiscovery.WamDefaultSet -eq $true) { '  |  WAM: Set' })"
	} elseif ($script:IsSystemAccountMode) {
		"Capable  |  PRT: N/A (system mode)"
	} else {
		"Capable  |  PRT: None"
	}
	Write-CheckResult 'Success' $_ssoDetail

	Write-CheckStart 'Intune Enrollment'
	$intuneEnrollmentDiscovery = Get-IntuneEnrollmentDiscovery
	Write-CheckResult 'Success'

	Write-CheckStart 'LAPS'
	$lapsDiscovery = Get-LapsDiscovery
	Write-CheckResult 'Success'

	Write-CheckStart 'Installed Applications'
	$installedApps = Get-InstalledApplications -PrimaryApplicationsOnlyMode $PrimaryApplicationsOnly.IsPresent
	Write-CheckResult 'Success' "$(@($installedApps).Count) app(s)$(if ($PrimaryApplicationsOnly.IsPresent) { ' (primary only)' })"

	Write-CheckStart 'Antivirus'
	$antivirusDiscovery = Get-AntivirusDiscovery -InstalledApplications $installedApps
	Write-CheckResult 'Success'

	Write-CheckStart 'Active Directory Dependencies'
	$adDependencyDiscovery = Get-ActiveDirectoryDependencyDiscovery
	$_adDetail = "Services: $($adDependencyDiscovery.DomainServiceCount)  |  Tasks: $($adDependencyDiscovery.DomainScheduledTaskCount)  |  ODBC: $($adDependencyDiscovery.DomainOdbcSourceCount)  |  AD Port Connections: $($adDependencyDiscovery.AdPortConnectionCount)  |  Config Files: $($adDependencyDiscovery.ConfigFileReferenceCount)"
	Write-CheckResult 'Success' $_adDetail

	Write-CheckStart 'FSLogix'
	$fsLogixDiscovery = Get-FSLogixDiscovery
	Write-CheckResult 'Success'

	Write-CheckStart 'OneDrive / Folder Redirection'
	$userProfileExperience = Get-OneDriveAndFolderRedirectionDiscovery
	Write-CheckResult 'Success'

	Write-CheckStart 'Default File Associations'
	$defaultFileAssociationDiscovery = Get-DefaultFileAssociationsDiscovery
	Write-CheckResult 'Success'

	Write-CheckStart 'Outlook Cached Mode'
	$outlookCachedModeDiscovery = Get-OutlookCachedModeDiscovery
	Write-CheckResult 'Success'

	Write-CheckStart 'Language Packs'
	$languagePackDiscovery = Get-LanguagePackDiscovery
	Write-CheckResult 'Success'

	Write-CheckStart 'Universal Print'
	$universalPrintDiscovery = Get-UniversalPrintDiscovery
	Write-CheckResult 'Success'

	Write-CheckStart 'Printers'
	$printerDiscovery = Get-PrinterDiscovery
	Write-CheckResult 'Success' "$($printerDiscovery.PrinterCount) printer(s) found"

	Write-CheckStart 'Time Source'
	$timeSourceDiscovery = Get-TimeSourceDiscovery
	Write-CheckResult 'Success'

	Write-CheckStart 'Teams Media Optimisation'
	$teamsMediaOptimizationDiscovery = Get-TeamsMediaOptimizationDiscovery
	Write-CheckResult 'Success'

	Write-CheckStart 'RDP Redirection'
	$rdpRedirectionDiscovery = Get-RdpRedirectionDiscovery
	Write-CheckResult 'Success'

	Write-CheckStart 'RDP Shortpath'
	$rdpShortpathDiscovery = Get-RdpShortpathDiscovery
	Write-CheckResult 'Success'

	$resolvedOutputDirectory = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { Join-Path (Split-Path $PSScriptRoot -Parent) 'output\vm-discovery' } else { [System.IO.Path]::GetFullPath($OutputDirectory) }
	$resolvedOutputPath = New-ExportFilePath -Directory $resolvedOutputDirectory -CustomerCode $customerCode -Hostname $machineDetails.Hostname
	$outputDirectory = Split-Path -Path $resolvedOutputPath -Parent

	if (-not [string]::IsNullOrWhiteSpace($outputDirectory) -and -not (Test-Path -Path $outputDirectory)) {
		New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
	}

	Write-CheckStart 'Group Policy'
	$gpResultHtmlPath = if ($NoGpresult.IsPresent) { $null } else { [System.IO.Path]::ChangeExtension($resolvedOutputPath, '.gpresult.html') }
	$groupPolicyDiscovery = if ($NoGpresult.IsPresent) {
		Write-CheckResult 'Skipped' '-NoGpresult specified'
		$null
	} else {
		$_gp = Get-GroupPolicyDiscovery -OutputPath $gpResultHtmlPath
		if ($_gp.Succeeded) {
			Write-CheckResult 'Success' "HTML report: $(Split-Path $gpResultHtmlPath -Leaf)"
		} else {
			Write-CheckResult 'Skipped' 'gpresult returned no data'
		}
		$_gp
	}

	Clear-SpinnerLine

	Write-Rule 'AVD CONNECTIVITY'
	$avdConnectivityDiscovery = if ($SkipConnectivityChecks.IsPresent) {
		Write-Host '  Skipped  (-SkipConnectivityChecks specified)' -ForegroundColor DarkGray
		$null
	} else {
		Get-AvdConnectivityDiscovery
	}

	$exportObject = [PSCustomObject]@{
		CustomerAbbreviation = $customerCode
		GeneratedBy          = if ([string]::IsNullOrWhiteSpace($GeneratedBy)) { $null } else { $GeneratedBy }
		ProjectCode          = if ([string]::IsNullOrWhiteSpace($ProjectCode))  { $null } else { $ProjectCode }
		CollectedAt          = (Get-Date).ToString('s')
		CollectionMode       = if ($script:IsSystemAccountMode) { 'SystemAccount' } else { 'Interactive' }
		RunningAsAccount     = $script:RunningAsAccount
		Machine              = $machineDetails
		DiscoveryType        = 'LocalAvdHost'
		JoinState            = $joinDiscovery
		EntraSso             = $entraSsoDiscovery
		PrimaryApplicationsOnly = $PrimaryApplicationsOnly.IsPresent
		ApplicationCount     = @($installedApps).Count
		FSLogix              = $fsLogixDiscovery
		UserProfileExperience = $userProfileExperience
		Antivirus            = $antivirusDiscovery
		Laps                 = $lapsDiscovery
		IntuneEnrollment     = $intuneEnrollmentDiscovery
		DefaultFileAssociations = $defaultFileAssociationDiscovery
		OutlookCachedMode    = $outlookCachedModeDiscovery
		LanguagePacks        = $languagePackDiscovery
		UniversalPrint       = $universalPrintDiscovery
		Printers             = $printerDiscovery
		TimeSource           = $timeSourceDiscovery
		TeamsMediaOptimization = $teamsMediaOptimizationDiscovery
		RdpRedirection       = $rdpRedirectionDiscovery
		RdpShortpath         = $rdpShortpathDiscovery
		ActiveDirectoryDependencies = $adDependencyDiscovery
		AvdConnectivity      = $avdConnectivityDiscovery
		ConnectivityChecksSkipped = $SkipConnectivityChecks.IsPresent
		GroupPolicy          = $groupPolicyDiscovery
		Applications         = $installedApps
	}

	$exportObject | ConvertTo-Json -Depth 10 |
		ForEach-Object { [regex]::Replace($_, '(?m)^(    )+', { param($m) '  ' * ($m.Value.Length / 4) }) } |
		ForEach-Object { $_ -replace ':  ', ': ' } |
		Set-Content -Path $resolvedOutputPath -Encoding UTF8
	$resolvedHtmlPath = [System.IO.Path]::ChangeExtension($resolvedOutputPath, '.html')
	Write-AvdHtmlReport -Data $exportObject -OutputPath $resolvedHtmlPath -Title "AVD Host Audit Report - $($machineDetails.Hostname)" -SourceJsonFileName (Split-Path $resolvedOutputPath -Leaf) | Out-Null

	$_elapsed = $scriptStopwatch.Elapsed
	$_elapsedStr = if ($_elapsed.TotalMinutes -ge 1) {
		"$([Math]::Floor($_elapsed.TotalMinutes))m $($_elapsed.Seconds)s"
	} else { "$([Math]::Round($_elapsed.TotalSeconds, 1))s" }

	Write-Rule
	Write-Host (Format-Ansi "  `e[92mDiscovery complete in $_elapsedStr`e[0m")
	Write-Host "  Applications  :  $(@($installedApps).Count)" -ForegroundColor DarkGray
	Write-Host "  Output file   :  $resolvedOutputPath" -ForegroundColor Cyan
	Write-Host "  HTML report   :  $resolvedHtmlPath" -ForegroundColor Cyan
	if ($null -ne $groupPolicyDiscovery -and $groupPolicyDiscovery.Succeeded) {
		Write-Host "  GP report     :  $gpResultHtmlPath" -ForegroundColor Cyan
	}
	Write-Host ''
}
catch {
	try { Clear-SpinnerLine } catch { }
	$errLocation = if ($_.InvocationInfo) { " [line $($_.InvocationInfo.ScriptLineNumber)]" } else { '' }
	Write-Error "Failed to discover applications or write JSON output.${errLocation} $($_.Exception.Message)"
	exit 1
}
