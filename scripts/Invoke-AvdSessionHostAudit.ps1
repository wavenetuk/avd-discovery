[CmdletBinding()]
<#
.SYNOPSIS
Discovers installed Windows applications and key AVD host configuration details and exports the results to JSON.

.DESCRIPTION
This script inventories installed applications from the standard Windows uninstall registry locations for both machine-wide and per-user installs.
It also inspects host-side profile-management settings that are not available from the Azure management plane, including FSLogix configuration, FSLogix profile container locations and sizes, OneDrive Known Folder Move policy indicators, and per-user folder redirection signals.
It exports application data, customer abbreviation, collection timestamp, machine identity, and the discovered host configuration details.
The primary-application exclusion filters are loaded from config/appExclusions.config.json (in the repository root) so they can be updated without editing PowerShell code.
When the script is copied outside the repository, it falls back to portable mode: optional config files are used if present beside the script, the JSON export defaults to the script folder, and HTML generation is skipped unless the shared generator is also available.

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

.PARAMETER NoHtml
Skips HTML report generation even when the shared JSON report generator script is available.

SAFETY FEATURES
	1. AST denylist assertion - the script parses its own source code at startup and throws
     before doing any discovery if a cmdlet that could mutate system or filesystem state is
     found outside the small set of permitted output-writing operations. Catches accidental
     write operations introduced by future edits before any discovery work is performed.
     Denied cmdlets: Set-ItemProperty, Remove-ItemProperty, Clear-ItemProperty,
     Set-Item (registry/filesystem mutations), Invoke-Expression, Set-Service, Stop-Service,
     Start-Service, Set-ExecutionPolicy, Register-ScheduledTask, Unregister-ScheduledTask.
     Permitted output operations (explicitly exempted): New-Item (output directory creation),
     Set-Content (JSON export), Move-Item (gpresult HTML relocation), Remove-Item (gpresult
     temp file cleanup).

	2. FSLogix share access is read-only - profile container paths are scanned using
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
	[switch]$NoHtml,

	[Parameter(Mandatory = $false)]
	[string]$GeneratedBy,

	[Parameter(Mandatory = $false)]
	[string]$ProjectCode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:PrimaryApplicationConfig = $null
$script:AuditTranscriptPath = $null
$script:AuditFailureLogPath = $null
$script:AuditPortableMode = $false
$script:AuditArchiveBaseName = $null
$script:AuditGeneratedArtifacts = [System.Collections.Generic.List[string]]::new()
$script:AuditArchivePath = $null
$script:AuditExitCode = 0

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

	# These cmdlets write output files only - they are intentional and permitted.
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

function Get-DefenderForEndpointOnboardingDiscovery {
	$statusPath = 'HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status'
	$status = Get-RegistryKeyValues -Path $statusPath
	$senseService = Get-Service -Name 'Sense' -ErrorAction SilentlyContinue
	$onboardingStateValue = Get-OptionalPropertyValue -Object $status -PropertyName 'OnboardingState'
	$orgId = Get-OptionalPropertyValue -Object $status -PropertyName 'OrgId'
	$onboarded = $null
	if ($null -ne $onboardingStateValue) {
		$onboarded = [int]$onboardingStateValue -eq 1
	}

	[PSCustomObject]@{
		Detected             = ($null -ne $status) -or ($null -ne $senseService) -or ($null -ne $onboardingStateValue) -or (-not [string]::IsNullOrWhiteSpace($orgId))
		Onboarded            = $onboarded
		OnboardingState      = if ($null -eq $onboarded) { 'Unknown' } elseif ($onboarded) { 'Onboarded' } else { 'Not Onboarded' }
		OnboardingStateValue = $onboardingStateValue
		OrgId                = $orgId
		SenseServiceInstalled = $null -ne $senseService
		SenseServiceStatus   = if ($null -ne $senseService) { [string]$senseService.Status } else { 'NotInstalled' }
		SenseServiceStartType = if ($null -ne $senseService) { [string]$senseService.StartType } else { $null }
		RegistryPath         = $statusPath
	}
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

function Resolve-ReportGeneratorScriptPath {
	$candidatePaths = @(
		(Join-Path $PSScriptRoot 'Invoke-HtmlReportGenerator.ps1')
	)

	foreach ($candidatePath in $candidatePaths) {
		if (Test-Path -Path $candidatePath) {
			return $candidatePath
		}
	}

	return $null
}

function Invoke-OptionalHtmlReportGeneration {
	param(
		[Parameter(Mandatory = $true)]
		[string]$JsonPath,

		[Parameter(Mandatory = $true)]
		[string]$ReportType,

		[Parameter(Mandatory = $true)]
		[string]$OutputPath
	)

	$generatorPath = Resolve-ReportGeneratorScriptPath
	if ([string]::IsNullOrWhiteSpace($generatorPath)) {
		return [PSCustomObject]@{
			Requested       = $true
			Status          = 'GeneratorNotFound'
			Message         = 'Shared HTML generator script was not found.'
			HtmlPath        = $null
			GeneratorScript = $null
			GeneratedAt     = $null
		}
	}

	try {
		$result = & $generatorPath -JsonPath $JsonPath -ReportType $ReportType -OutputPath $OutputPath
		return [PSCustomObject]@{
			Requested       = $true
			Status          = 'Generated'
			Message         = 'HTML report generated successfully.'
			HtmlPath        = $result.HtmlPath
			GeneratorScript = $generatorPath
			GeneratedAt     = (Get-Date).ToString('s')
		}
	}
	catch {
		Write-Verbose "HTML report generation failed: $($_.Exception.Message)"
		return [PSCustomObject]@{
			Requested       = $true
			Status          = 'Failed'
			Message         = $_.Exception.Message
			HtmlPath        = $null
			GeneratorScript = $generatorPath
			GeneratedAt     = $null
		}
	}
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
		$_blockers.Add('Device is not Entra ID joined - Entra SSO requires AzureADJoined or HybridAzureADJoined') | Out-Null
	}

	if ($_isHaadj -and -not $_cloudKerb) {
		$_advisories.Add('Hybrid Entra joined but Cloud Kerberos Trust not enabled - Kerberos SSO to on-premises resources may not work') | Out-Null
	}

	if ($null -eq $dsReg -or $dsReg.AzureAdPrt -ne $true) {
		if ($script:IsSystemAccountMode) {
			$_notes.Add('PRT state is unavailable when running as SYSTEM account - run interactively for per-user PRT data') | Out-Null
		} elseif ($_isAadJoined) {
			$_advisories.Add('No Azure AD PRT detected for the running account - users may be prompted to authenticate') | Out-Null
		}
	}

	if ($_isAadJoined -and $null -ne $dsReg -and $dsReg.WamDefaultSet -ne $true) {
		$_advisories.Add('WAM (Web Account Manager) is not the default credential broker - modern authentication SSO may be impaired') | Out-Null
	}

	if ($_credGuard) {
		$_notes.Add('Credential Guard is enabled - NTLM and legacy credential delegation are blocked (expected in a secure AVD environment)') | Out-Null
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

	# PolicyManager device detail - populated when a device is Intune-managed
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
	$windowsLapsGroupPolicy = Get-RegistryKeyValues -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\LAPS'
	$windowsLapsPolicyManager = Get-RegistryKeyValues -Path 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\LAPS'
	$legacyLapsPolicy = Get-RegistryKeyValues -Path 'HKLM:\SOFTWARE\Policies\Microsoft Services\AdmPwd'
	$legacyLapsDllPath = 'C:\Program Files\LAPS\CSE\AdmPwd.dll'

	$windowsLapsConfigured = $null -ne $windowsLapsPolicy -or $null -ne $windowsLapsGroupPolicy -or $null -ne $windowsLapsPolicyManager
	$legacyLapsConfigured = $null -ne $legacyLapsPolicy -or (Test-Path -Path $legacyLapsDllPath)
	$legacyEnabled = if ($null -eq $legacyLapsPolicy) { $false } else { [int](Get-OptionalPropertyValue -Object $legacyLapsPolicy -PropertyName 'AdmPwdEnabled') -eq 1 }
	$windowsBackupDirectory = if ($null -ne $windowsLapsPolicy) {
		Get-OptionalPropertyValue -Object $windowsLapsPolicy -PropertyName 'BackupDirectory'
	} elseif ($null -ne $windowsLapsGroupPolicy) {
		Get-OptionalPropertyValue -Object $windowsLapsGroupPolicy -PropertyName 'BackupDirectory'
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
		WindowsLapsGroupPolicy   = $windowsLapsGroupPolicy
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

	# Per-user cached mode settings - skip when running as SYSTEM/machine account (no user hive loaded)
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
		Note                    = if ($script:IsSystemAccountMode) { 'Per-user Outlook cached mode registry settings skipped - script is running as a system/machine account. Run Invoke-AvdSessionHostAudit.ps1 interactively on the host to collect user-specific data.' } else { $null }
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
	$rulesInUse = @($ruleFiles).Count -gt 0

	[PSCustomObject]@{
		Configured         = $rulesInUse
		EffectiveEnabled   = if ($null -eq $effectiveConfig) { $null } else { Get-OptionalPropertyValue -Object $effectiveConfig -PropertyName 'Enabled' }
		RuleDirectories    = @($ruleDirectories | ForEach-Object { Get-PathInventoryItem -Path $_ -TypeHint 'Directory' })
		RuleFileCount      = @($ruleFiles).Count
		RulesInUse         = $rulesInUse
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

	$defenderForEndpoint = Get-DefenderForEndpointOnboardingDiscovery
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

	if (@($securityCenterProducts).Count -eq 0 -and $null -ne $defenderStatus -and @($applicationMatches).Count -eq 0) {
		$defenderState = if ($defenderStatus.AntivirusEnabled -eq $true) {
			'Enabled'
		} elseif ($defenderStatus.AntivirusEnabled -eq $false) {
			'Disabled'
		} else {
			'Unknown'
		}
		$applicationMatches = @([PSCustomObject]@{
			Name      = 'Microsoft Defender Antivirus'
			Publisher = 'Microsoft Defender Antivirus'
			Version   = $defenderState
		})
	}

	[PSCustomObject]@{
		DefenderForEndpoint         = $defenderForEndpoint
		SecurityCenterProducts      = @($securityCenterProducts)
		SecurityCenterDetected      = @($securityCenterProducts).Count -gt 0 -or $null -ne $defenderStatus -or $defenderForEndpoint.Detected
		WindowsDefender             = $defenderStatus
		InstalledApplicationMatches  = $applicationMatches
		Detected                    = @($securityCenterProducts).Count -gt 0 -or $null -ne $defenderStatus -or @($applicationMatches).Count -gt 0 -or $defenderForEndpoint.Detected
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
		#   - HKCU paths are user-scoped policy hive values
		#   - HKLM Policies hive values may be mirrored by Intune MDM or written locally
		$isHkcu   = $path -like 'HKCU:*'
		$isIntune = (-not $isHkcu) -and ($null -ne $mdmBridgeValues) -and (@($mdmBridgeValues.PSObject.Properties).Count -gt 0)
		$source   = if ($isHkcu) { 'Registry-HKCU' } elseif ($isIntune) { 'Intune-MDM' } else { 'Registry-HKLM' }

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
		Note                          = if ($script:IsSystemAccountMode) { 'Per-user shell folder, folder redirection, and mapped drive data skipped - script is running as a system/machine account. Run Invoke-AvdSessionHostAudit.ps1 interactively on the host to collect user-specific data.' } else { $null }
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

function Test-InteractivePromptAvailable {
	return [Environment]::UserInteractive
}

function Read-YesNoPrompt {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Prompt,

		[Parameter(Mandatory = $false)]
		[bool]$Default = $false
	)

	if (-not (Test-InteractivePromptAvailable)) {
		return $Default
	}

	$suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
	while ($true) {
		$response = Get-NormalizedText -Value (Read-Host "$Prompt $suffix")
		if ([string]::IsNullOrWhiteSpace($response)) {
			return $Default
		}

		switch ($response.ToLowerInvariant()) {
			'y' { return $true }
			'yes' { return $true }
			'n' { return $false }
			'no' { return $false }
			default {
				Write-Host '  Please answer yes or no.' -ForegroundColor DarkGray
			}
		}
	}
}

function Ensure-AzAccountsModuleAvailable {
	if (Get-Module -ListAvailable -Name 'Az.Accounts') {
		Import-Module -Name 'Az.Accounts' -Force -ErrorAction Stop
		return $true
	}

	if (-not (Read-YesNoPrompt -Prompt 'Az.Accounts is not installed. Install it now so FSLogix share usage stats can be collected?' -Default:$false)) {
		return $false
	}

	try {
		Write-Host ''
		Write-Host '  Attempting to install Az.Accounts for the current user...' -ForegroundColor Cyan
		Install-Module -Name 'Az.Accounts' -Scope CurrentUser -Force -AllowClobber -Repository 'PSGallery' -ErrorAction Stop | Out-Null
		Import-Module -Name 'Az.Accounts' -Force -ErrorAction Stop
		return $true
	}
	catch {
		Write-Host ''
		Write-Host '  Az.Accounts could not be installed in this session.' -ForegroundColor DarkYellow
		Write-Host '  Run this command in the same PowerShell session, then rerun the audit:' -ForegroundColor Cyan
		Write-Host '  Install-Module -Name Az.Accounts -Scope CurrentUser -Force -AllowClobber -Repository PSGallery' -ForegroundColor DarkGray
		Write-Host '  If you are prompted to trust the repository, answer yes.' -ForegroundColor DarkGray
		Write-Host '  Azure Files share usage stats will be skipped for this run.' -ForegroundColor DarkYellow
		return $false
	}
}

function Connect-RequestedAzAccount {
	param(
		[Parameter(Mandatory = $false)]
		$CurrentContext
	)

	Write-Host ''
	if ($CurrentContext -and $CurrentContext.Account -and -not [string]::IsNullOrWhiteSpace([string]$CurrentContext.Account.Id)) {
		Write-Host "  Current Azure context: $($CurrentContext.Account.Id)" -ForegroundColor DarkGray
	}
	Write-Host '  Sign in to the Azure account to use for detailed FSLogix share usage stats.' -ForegroundColor Cyan
	Write-Host '  Use the Azure sign-in window that opens next.' -ForegroundColor DarkGray
	Write-Host ''

	Connect-AzAccount -ErrorAction Stop | Out-Null

	$connectedContext = Get-AzContext
	if (-not $connectedContext -or -not $connectedContext.Account) {
		throw 'Azure authentication completed without an active context.'
	}

	Write-Host "  Signed in as: $($connectedContext.Account.Id)" -ForegroundColor DarkGray
	Write-Host ''

	return $connectedContext
}

function Invoke-ArmRequest {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Path,

		[string]$Method = 'GET',

		[Parameter(Mandatory = $false)]
		[string]$Payload
	)

	$callParams = @{ Path = $Path; Method = $Method; ErrorAction = $ErrorActionPreference }
	if ($PSBoundParameters.ContainsKey('Payload')) { $callParams['Payload'] = $Payload }
	Invoke-AzRestMethod @callParams
}

function Get-StorageAccountByName {
	param(
		[Parameter(Mandatory = $true)]
		[string[]]$Names,

		[Parameter(Mandatory = $true)]
		[object[]]$Subscriptions
	)

	$found = [System.Collections.Generic.List[PSCustomObject]]::new()
	$nameSet = [System.Collections.Generic.HashSet[string]]::new($Names, [System.StringComparer]::OrdinalIgnoreCase)

	foreach ($sub in $Subscriptions) {
		Set-AzContext -SubscriptionId $sub.Id -WarningAction SilentlyContinue | Out-Null
		$resp = Invoke-ArmRequest -Path "/subscriptions/$($sub.Id)/providers/Microsoft.Storage/storageAccounts?api-version=2023-01-01" -Method GET -ErrorAction SilentlyContinue
		if (-not $resp -or $resp.StatusCode -ne 200) { continue }

		foreach ($sa in @(($resp.Content | ConvertFrom-Json).value)) {
			if (-not $nameSet.Contains($sa.name)) { continue }
			$rgParts = $sa.id -split '/'
			$rgIdx   = [Array]::IndexOf($rgParts, 'resourceGroups')
			$rg      = if ($rgIdx -ge 0) { $rgParts[$rgIdx + 1] } else { $null }
			$found.Add([PSCustomObject]@{
				SubscriptionId   = $sub.Id
				SubscriptionName = $sub.Name
				ResourceGroup    = $rg
				Resource         = $sa
			})
		}
	}
	return $found.ToArray()
}

function Get-FSLogixAzureFilesLocationInfo {
	param(
		[string[]]$ProfileLocations
	)

	if ($null -eq $ProfileLocations -or @($ProfileLocations).Count -eq 0) {
		return @()
	}

	$results = foreach ($location in @($ProfileLocations)) {
		$normalizedLocation = Get-NormalizedText -Value $location
		if ([string]::IsNullOrWhiteSpace($normalizedLocation)) { continue }
		if ($normalizedLocation -notmatch '^(?<prefix>\\\\)(?<account>[A-Za-z0-9-]+)\.file\.core\.windows\.net\\(?<share>[^\\/]+)') { continue }

		[PSCustomObject]@{
			Location           = $normalizedLocation
			StorageAccountName = $matches.account
			ShareName          = $matches.share
		}
	}

	return @($results)
}

function Get-StorageAccountShareUsageMap {
	param(
		[Parameter(Mandatory = $true)]
		[PSCustomObject]$StorageAccount
	)

	$sa = $StorageAccount.Resource
	$subId = $StorageAccount.SubscriptionId
	$rg = $StorageAccount.ResourceGroup
	$name = $sa.name

	$shareUsageMap = @{}
	$sharesResp = Invoke-ArmRequest -Path "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Storage/storageAccounts/$name/fileServices/default/shares?api-version=2023-01-01&`$expand=stats" -Method GET -ErrorAction SilentlyContinue
	if (-not $sharesResp -or $sharesResp.StatusCode -ne 200) {
		$sharesResp = Invoke-ArmRequest -Path "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Storage/storageAccounts/$name/fileServices/default/shares?api-version=2023-01-01" -Method GET -ErrorAction SilentlyContinue
	}

	if ($sharesResp -and $sharesResp.StatusCode -eq 200) {
		foreach ($share in @(($sharesResp.Content | ConvertFrom-Json).value)) {
			$shareProperties = $share.properties
			$usedBytes = if ($shareProperties.PSObject.Properties['shareUsageBytes']) { [int64]$shareProperties.shareUsageBytes } else { $null }
			$shareUsageMap[[string]$share.name.ToLowerInvariant()] = [PSCustomObject]@{
				ShareName = $share.name
				UsedBytes = $usedBytes
				UsedGB = if ($null -ne $usedBytes) { [Math]::Round($usedBytes / 1GB, 2) } else { $null }
				UsageStatsAvailable = $true
			}
		}
	}

	return $shareUsageMap
}

function Get-FSLogixAzureFilesShareUsage {
	param(
		[string[]]$ProfileLocations
	)

	if ($null -eq $ProfileLocations -or @($ProfileLocations).Count -eq 0) {
		return [PSCustomObject]@{
			Prompted = $false
			Enabled = $false
			Authenticated = $false
			DetectedLocationCount = 0
			ResolvedLocationCount = 0
			LocationUsage = @{}
			TotalUsedBytes = $null
			TotalUsedGB = $null
			UsageSource = 'FilesystemWalk'
			SkippedReason = 'No Azure Files profile locations detected'
		}
	}

	$azureLocationInfo = @(Get-FSLogixAzureFilesLocationInfo -ProfileLocations $ProfileLocations)
	if (-not $azureLocationInfo.Count) {
		return [PSCustomObject]@{
			Prompted = $false
			Enabled = $false
			Authenticated = $false
			DetectedLocationCount = 0
			ResolvedLocationCount = 0
			LocationUsage = @{}
			TotalUsedBytes = $null
			TotalUsedGB = $null
			UsageSource = 'FilesystemWalk'
			SkippedReason = 'No Azure Files profile locations detected'
		}
	}

	if (-not (Read-YesNoPrompt -Prompt 'FSLogix profile storage appears to use Azure Files. Sign in to Azure and collect detailed share usage stats?' -Default:$false)) {
		return [PSCustomObject]@{
			Prompted = $true
			Enabled = $false
			Authenticated = $false
			DetectedLocationCount = $azureLocationInfo.Count
			ResolvedLocationCount = 0
			LocationUsage = @{}
			TotalUsedBytes = $null
			TotalUsedGB = $null
			UsageSource = 'FilesystemWalk'
			SkippedReason = 'Azure Files share usage scan was declined by the user'
		}
	}

	$originalContext = $null
	$authenticatedContext = $null
	$locationUsage = @{}
	try {
		if (-not (Ensure-AzAccountsModuleAvailable)) {
			return [PSCustomObject]@{
				Prompted = $true
				Enabled = $false
				Authenticated = $false
				DetectedLocationCount = $azureLocationInfo.Count
				ResolvedLocationCount = 0
				LocationUsage = @{}
				TotalUsedBytes = $null
				TotalUsedGB = $null
				UsageSource = 'FilesystemWalk'
				SkippedReason = 'Az.Accounts could not be installed in this session; install it manually and rerun the audit'
			}
		}

		try {
			Disable-AzContextAutosave -Scope Process | Out-Null
		}
		catch {
		}

		$originalContext = Get-AzContext -ErrorAction SilentlyContinue
		if (-not $originalContext -or -not $originalContext.Account) {
			$authenticatedContext = Connect-RequestedAzAccount -CurrentContext $originalContext
		}
		else {
			$authenticatedContext = $originalContext
		}

		$subscriptions = @(Get-AzSubscription -ErrorAction Stop | Where-Object { $_.State -eq 'Enabled' })
		if (-not $subscriptions.Count) {
			throw 'No enabled Azure subscriptions are available in the current context.'
		}

		$storageAccountNames = @($azureLocationInfo | Select-Object -ExpandProperty StorageAccountName -Unique)
		$storageAccounts = @(Get-StorageAccountByName -Names $storageAccountNames -Subscriptions $subscriptions)
		if (-not $storageAccounts.Count) {
			throw 'No matching Azure Files storage accounts were found in the accessible subscriptions.'
		}

		$storageAccountsByName = @{}
		foreach ($storageAccount in $storageAccounts) {
			$storageAccountsByName[$storageAccount.Resource.name.ToLowerInvariant()] = $storageAccount
		}

		foreach ($storageAccountName in $storageAccountNames) {
			$storageAccount = $storageAccountsByName[$storageAccountName.ToLowerInvariant()]
			if ($null -eq $storageAccount) { continue }
			$shareUsageMap = Get-StorageAccountShareUsageMap -StorageAccount $storageAccount
			$matchingLocations = @($azureLocationInfo | Where-Object { $_.StorageAccountName -ieq $storageAccountName })
			foreach ($locationInfo in $matchingLocations) {
				$shareUsage = $shareUsageMap[$locationInfo.ShareName.ToLowerInvariant()]
				if ($null -eq $shareUsage -or $null -eq $shareUsage.UsedBytes) { continue }
				$locationUsage[$locationInfo.Location.ToLowerInvariant()] = [PSCustomObject]@{
					Location = $locationInfo.Location
					StorageAccountName = $locationInfo.StorageAccountName
					ShareName = $locationInfo.ShareName
					UsedBytes = [int64]$shareUsage.UsedBytes
					UsedGB = [double]$shareUsage.UsedGB
					UsageSource = 'AzureFilesShareStats'
					UsageStatsAvailable = [bool]$shareUsage.UsageStatsAvailable
				}
			}
		}

		$usedBytesTotal = 0
		foreach ($entry in $locationUsage.Values) {
			$usedBytesTotal += [int64]$entry.UsedBytes
		}

		return [PSCustomObject]@{
			Prompted = $true
			Enabled = $true
			Authenticated = $null -ne $authenticatedContext -and $null -ne $authenticatedContext.Account
			DetectedLocationCount = $azureLocationInfo.Count
			ResolvedLocationCount = $locationUsage.Count
			LocationUsage = $locationUsage
			TotalUsedBytes = [int64]$usedBytesTotal
			TotalUsedGB = ConvertTo-BytesToGigabytes -Bytes $usedBytesTotal
			UsageSource = if ($locationUsage.Count -eq $azureLocationInfo.Count) { 'Azure Files share stats' } else { 'Mixed Azure Files share stats and filesystem walk' }
			SkippedReason = $null
		}
	}
	catch {
		Write-Warning "Azure Files share usage was skipped: $($_.Exception.Message)"
		return [PSCustomObject]@{
			Prompted = $true
			Enabled = $false
			Authenticated = $false
			DetectedLocationCount = $azureLocationInfo.Count
			ResolvedLocationCount = 0
			LocationUsage = @{}
			TotalUsedBytes = $null
			TotalUsedGB = $null
			UsageSource = 'FilesystemWalk'
			SkippedReason = $_.Exception.Message
		}
	}
	finally {
		if ($null -ne $originalContext) {
			try {
				Set-AzContext -Context $originalContext -WarningAction SilentlyContinue | Out-Null
			}
			catch {
			}
		}
	}
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
	$azureFilesShareUsage = Get-FSLogixAzureFilesShareUsage -ProfileLocations $profileLocations
	$profileInventoryUsesAzureFiles = $azureFilesShareUsage.Enabled -and $azureFilesShareUsage.ResolvedLocationCount -gt 0
	$profileInventoryDetails = @()
	$totalProfileBytes = 0
	$totalProfileCount = 0
	$profileTotalSourceValues = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	foreach ($locationInventory in @($profileLocationInventory)) {
		$locationKey = if ($locationInventory.PSObject.Properties['Location']) { Get-NormalizedText -Value $locationInventory.Location } else { $null }
		$azureUsage = $null
		if ($profileInventoryUsesAzureFiles -and -not [string]::IsNullOrWhiteSpace($locationKey)) {
			$azureUsage = $azureFilesShareUsage.LocationUsage[$locationKey.ToLowerInvariant()]
		}

		$effectiveTotalBytes = [int64]$locationInventory.TotalSizeBytes
		$effectiveTotalGB = $locationInventory.TotalSizeGB
		$usageSource = 'Filesystem walk'
		$usageStatsAvailable = $false
		$shareUsageBytes = $null
		$shareUsageGB = $null
		if ($null -ne $azureUsage -and $null -ne $azureUsage.UsedBytes) {
			$effectiveTotalBytes = [int64]$azureUsage.UsedBytes
			$effectiveTotalGB = [Math]::Round(($effectiveTotalBytes / 1GB), 2)
			$usageSource = 'Azure Files share stats'
			$usageStatsAvailable = [bool]$azureUsage.UsageStatsAvailable
			$shareUsageBytes = [int64]$azureUsage.UsedBytes
			$shareUsageGB = [double]$azureUsage.UsedGB
		}

		$totalProfileBytes += [int64]$effectiveTotalBytes
		$totalProfileCount += [int64]$locationInventory.ProfileContainerCount
		[void]$profileTotalSourceValues.Add($usageSource)
		$profileInventoryDetails += [PSCustomObject]@{
			Location                = $locationInventory.Location
			Accessible              = $locationInventory.Accessible
			Exists                  = $locationInventory.Exists
			ProfileContainerCount    = $locationInventory.ProfileContainerCount
			TotalSizeBytes          = [int64]$effectiveTotalBytes
			TotalSizeGB             = $effectiveTotalGB
			ScanError               = $locationInventory.ScanError
			UsageSource             = $usageSource
			UsageStatsAvailable     = $usageStatsAvailable
			ShareUsageBytes         = $shareUsageBytes
			ShareUsageGB            = $shareUsageGB
			OriginalTotalSizeBytes  = $locationInventory.TotalSizeBytes
			OriginalTotalSizeGB     = $locationInventory.TotalSizeGB
		}
	}
	$profileTotalSource = if ($profileTotalSourceValues.Count -gt 1) { 'Mixed Azure Files share stats and filesystem walk' } elseif ($profileTotalSourceValues.Contains('Azure Files share stats')) { 'Azure Files share stats' } else { 'Filesystem walk' }

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
		AzureFilesShareStats        = [PSCustomObject]@{
			Prompted               = $azureFilesShareUsage.Prompted
			Enabled                = $azureFilesShareUsage.Enabled
			Authenticated          = $azureFilesShareUsage.Authenticated
			DetectedLocationCount  = $azureFilesShareUsage.DetectedLocationCount
			ResolvedLocationCount  = $azureFilesShareUsage.ResolvedLocationCount
			UsageSource            = $profileTotalSource
			SkippedReason          = $azureFilesShareUsage.SkippedReason
		}
		ProfileLocationInventory    = $profileInventoryDetails
		ProfileContainerCount       = $totalProfileCount
		ProfileContainerTotalBytes  = if ($null -eq $totalProfileBytes) { 0 } else { [int64]$totalProfileBytes }
		ProfileContainerTotalGB     = ConvertTo-BytesToGigabytes -Bytes $totalProfileBytes
		ProfileContainerTotalSource = $profileTotalSource
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

function Get-AvdConnectivityEndpointChecks {
	Set-StrictMode -Off
	try {
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

		$connectivityChecks = [System.Collections.ArrayList]::new()
		foreach ($endpoint in $endpoints) {
			$label = "$($endpoint.Hostname):$($endpoint.Port)"
			$requiredLabel = if ($endpoint.Required) { '[Required]' } else { '[Optional]' }

			$check = Test-TcpEndpoint -Hostname $endpoint.Hostname -Port $endpoint.Port

			[void]$connectivityChecks.Add([PSCustomObject]@{
				Hostname  = $endpoint.Hostname
				Port      = $endpoint.Port
				Category  = $endpoint.Category
				Required  = $endpoint.Required
				Connected = $check.Connected
				LatencyMs = $check.LatencyMs
				Error     = $check.Error
			})
		}

		return @($connectivityChecks)
	}
	finally {
		Set-StrictMode -Version Latest
	}
}

function Get-AvdConnectivityDiscovery {
	Set-StrictMode -Off
	try {
		$connectivityChecks = @(Get-AvdConnectivityEndpointChecks)
		$requiredChecks = @($connectivityChecks | Where-Object { $_.Required })
		$passedChecks = @($requiredChecks | Where-Object { $_.Connected })
		$failedChecks = @($requiredChecks | Where-Object { -not $_.Connected })
		$notableChecks = @($connectivityChecks | Where-Object { -not $_.Connected })

		Write-Host ''
		$_reachStr = "$($passedChecks.Count)/$($requiredChecks.Count) required endpoints reachable"
		if ($failedChecks.Count -eq 0) {
			Write-Host (Format-Ansi "  `e[92m$_reachStr`e[0m")
		} else {
			Write-Host (Format-Ansi "  `e[93m$_reachStr`e[0m")
			Write-Host (Format-Ansi "  `e[93mFailed required endpoints:`e[0m")
			foreach ($failedCheck in $failedChecks) {
				Write-Host (Format-Ansi "    `e[91m- $($failedCheck.Hostname):$($failedCheck.Port)  ($($failedCheck.Error))`e[0m")
			}
		}
		Write-Host ''

		[PSCustomObject]@{
			AllRequiredReachable     = $failedChecks.Count -eq 0
			RequiredEndpointCount    = $requiredChecks.Count
			RequiredReachableCount   = $passedChecks.Count
			RequiredUnreachableCount = $failedChecks.Count
			FailedEndpoints          = @($notableChecks)
			Results                  = @($connectivityChecks)
		}
	}
	finally {
		Set-StrictMode -Version Latest
	}
}

function Get-TeamsMediaOptimizationDiscovery {
	# WebRTC redirector service
	$webRtcService = Get-Service -Name 'RDWebRTCSvc' -ErrorAction SilentlyContinue

	# WebRTC redirector binary - derive version from the installed executable
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

	# IsWVDEnvironment registry key - required for new Teams (2.x) media optimization
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
	or domain-joined machines - UNC paths, FQDNs, and connection-string server keywords.
	Only text-based config file types up to 1 MB are inspected. Windows system directories
	and common redistributable/framework folders are excluded to reduce noise.
	#>

	$scanRoots = @(
		$env:ProgramFiles,
		${env:ProgramFiles(x86)}
	) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path $_) } | Sort-Object -Unique

	# File extensions to scan (text-based config formats only)
	$configExtensions = @('.ini', '.cfg', '.config', '.xml', '.conf', '.properties', '.env', '.yaml', '.yml')

	# Folder name fragments to skip - Windows components, runtimes, redistributables
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

	# --- ODBC data sources (system DSNs - 32-bit and 64-bit) ---
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
	# Connections are grouped by {RemoteAddress, RemotePort} - an AVD host can have
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
		if ($script:IsSystemAccountMode) {
			$gpresultArgs += @('/scope', 'computer')
		}
		else {
			$gpresultArgs += @('/user', [System.Security.Principal.WindowsIdentity]::GetCurrent().Name, '/scope', 'user')
		}
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
		Note             = if ($succeeded -and -not $script:IsSystemAccountMode) { 'Report contains user policy only (run elevated or as SYSTEM to capture computer policy as well).' } elseif ($script:IsSystemAccountMode -and $succeeded) { 'Report contains computer policy only (no user RSoP) - script is running as a system/machine account. Run Invoke-AvdSessionHostAudit.ps1 interactively on the host to include user Group Policy.' } else { $null }
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
	return $candidates[0]  # not found - caller will handle the null return from Get-PrimaryApplicationConfig
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
		return $true  # no config loaded - include all applications
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
	RDP Shortpath has two independent modes - both can be enabled simultaneously:

	  Managed Networks  - UDP transport over ExpressRoute/VPN/direct LAN. Enabled by setting
	                      fUseUdpPortRedirector = 1 in the WinStation or Group Policy hive.
	                      Listens on a configurable UDP port (default 3390).

	  Public Networks   - UDP transport over the internet using STUN/TURN. Enabled by setting
	                      ICEControl = 2 in the same hives. Requires the AVD host agent and
	                      outbound UDP to the STUN endpoints. No fixed inbound port required.

	Configuration is read from three hives in precedence order:
	  1. HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services  (Group Policy)
	  2. HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp  (WinStation)
	  3. HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server  (RD Session Host)

	Recent usage is inferred from the RdpCoreTS operational event log:
	  Event 131 - "Shortpath transport established" (managed or public network)
	  Event 70  - "A connection was established using UDP transport" (legacy UDP indicator)

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

	# --- Recent usage - RdpCoreTS operational event log ---
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

	# --- AVD host agent - carries the STUN/TURN client needed for public Shortpath ---
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
	  1. HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services  (Group Policy - highest precedence)
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

function ConvertTo-SafePathSegment {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Value
	)

	$segment = Get-NormalizedText -Value $Value
	if ([string]::IsNullOrWhiteSpace($segment)) {
		return 'customer'
	}

	$segment = $segment -replace '[<>:"/\\|?*]+', '-'
	$segment = $segment.Trim(' ', '.', '-', '_')
	if ([string]::IsNullOrWhiteSpace($segment)) {
		return 'customer'
	}

	return $segment
}

function Test-RepoLayoutAvailable {
	$repoRoot = Split-Path -Path $PSScriptRoot -Parent
	$requiredPaths = @(
		(Join-Path $repoRoot 'config\appExclusions.config.json'),
		(Join-Path $repoRoot 'scripts\Invoke-HtmlReportGenerator.ps1')
	)

	foreach ($path in $requiredPaths) {
		if (-not (Test-Path -Path $path)) {
			return $false
		}
	}

	return $true
}

function Resolve-AuditOutputDirectory {
	param(
		[Parameter(Mandatory = $true)]
		[string]$CustomerCode,

		[Parameter(Mandatory = $false)]
		[string]$RequestedOutputDirectory
	)

	if (-not [string]::IsNullOrWhiteSpace($RequestedOutputDirectory)) {
		return [System.IO.Path]::GetFullPath($RequestedOutputDirectory)
	}

	if (Test-RepoLayoutAvailable) {
		return (Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'output\vm-discovery')
	}

	return $PSScriptRoot
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

function Wait-ForInteractiveErrorAcknowledgement {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Message
	)

	if (-not [Environment]::UserInteractive) {
		return
	}

	if ($Host.Name -notin @('ConsoleHost', 'Visual Studio Code Host')) {
		return
	}

	Write-Host ''
	Write-Host $Message -ForegroundColor Yellow
	try {
		[void](Read-Host 'Press Enter to close this window')
	}
	catch {
	}
}

function Write-SessionHostAuditFailureLog {
	param(
		[Parameter(Mandatory = $true)]
		[System.Management.Automation.ErrorRecord]$ErrorRecord,

		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[string]$PreferredPath
	)

	$logPath = $null
	if (-not [string]::IsNullOrWhiteSpace($PreferredPath)) {
		$logPath = [System.IO.Path]::ChangeExtension($PreferredPath, '.error.log')
	} else {
		$logPath = $script:AuditFailureLogPath
	}

	$logDirectory = Split-Path -Path $logPath -Parent
	if (-not [string]::IsNullOrWhiteSpace($logDirectory) -and -not (Test-Path -Path $logDirectory)) {
		New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
	}

	$scriptLine = if ($ErrorRecord.InvocationInfo) { $ErrorRecord.InvocationInfo.ScriptLineNumber } else { $null }
	$scriptName = if ($ErrorRecord.InvocationInfo) { $ErrorRecord.InvocationInfo.ScriptName } else { $null }
	$locationText = if ($null -ne $scriptLine) { "$scriptName line $scriptLine" } else { 'unknown location' }
	$body = @(
		'AVD Session Host Audit failure log',
		"Timestamp: $(Get-Date -Format s)",
		"Script: $PSCommandPath",
		"Location: $locationText",
		"Error: $($ErrorRecord.Exception.Message)",
		''
	)

	if ($ErrorRecord.ScriptStackTrace) {
		$body += 'Script stack trace:'
		$body += $ErrorRecord.ScriptStackTrace
		$body += ''
	}

	if ($ErrorRecord.Exception.StackTrace) {
		$body += 'Exception stack trace:'
		$body += $ErrorRecord.Exception.StackTrace
		$body += ''
	}

	$body += 'Full error record:'
	$body += ($ErrorRecord | Out-String)

	$body | Set-Content -Path $logPath -Encoding UTF8
	return $logPath
}

function Add-SessionHostAuditArtifact {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Path
	)

	if ([string]::IsNullOrWhiteSpace($Path)) {
		return
	}

	[void]$script:AuditGeneratedArtifacts.Add($Path)
}

function Compress-PortableAuditArtifacts {
	param(
		[Parameter(Mandatory = $false)]
		[string]$SourceDirectory,

		[Parameter(Mandatory = $false)]
		[string]$ArchiveBaseName
	)

	if (-not $script:AuditPortableMode) {
		return $null
	}

	if ([string]::IsNullOrWhiteSpace($SourceDirectory)) {
		return $null
	}

	if ([string]::IsNullOrWhiteSpace($ArchiveBaseName)) {
		$ArchiveBaseName = 'audit-results'
	}

	$existingArtifacts = @(
		$script:AuditGeneratedArtifacts |
			Where-Object {
				-not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -Path $_)
			} |
			Sort-Object -Unique
	)

	if ($existingArtifacts.Count -eq 0) {
		return $null
	}

	$archiveName = '{0}.zip' -f $ArchiveBaseName
	$archivePath = Join-Path -Path $SourceDirectory -ChildPath $archiveName
	if (Test-Path -Path $archivePath) {
		Remove-Item -Path $archivePath -Force
	}

	Compress-Archive -Path $existingArtifacts -DestinationPath $archivePath -Force
	return $archivePath
}

function Remove-PortableAuditArtifacts {
	param(
		[Parameter(Mandatory = $false)]
		[string]$ArchivePath,

		[Parameter(Mandatory = $false)]
		[string[]]$PreservePaths = @()
	)

	if (-not $script:AuditPortableMode) {
		return
	}

	$normalizedPreservePaths = @(
		$PreservePaths |
			Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
			ForEach-Object { $_.TrimEnd() } |
			Sort-Object -Unique
	)

	$artifactPaths = @(
		$script:AuditGeneratedArtifacts |
			Where-Object {
				-not [string]::IsNullOrWhiteSpace($_) -and
				(Test-Path -Path $_) -and
				($_.TrimEnd() -ne $ArchivePath) -and
				($_.TrimEnd() -notin $normalizedPreservePaths)
			} |
			Sort-Object -Unique
	)

	foreach ($artifactPath in $artifactPaths) {
		try {
			Remove-Item -Path $artifactPath -Force -ErrorAction Stop
		}
		catch {
			Write-Warning "Could not remove portable artifact '$artifactPath': $($_.Exception.Message)"
		}
	}
}

# ------------------------------------------------------------------
# Console output helpers
# ------------------------------------------------------------------

$script:_checkLabel   = ''
$script:_ansiSupported = $false
$script:_spinnerSupported = $false
$script:_fancyConsoleSupported = $false
$script:_progressId = 1

function Test-AnsiConsoleSupport {
	if ($host.Name -match 'ISE') { return $false }
	if ($env:TERM -eq 'dumb') { return $false }
	if ($PSVersionTable.PSEdition -ne 'Core') { return $false }

	try {
		if ($Host.UI -and $Host.UI.SupportsVirtualTerminal) { return $true }
	} catch {}

	try {
		if (-not ('AvdConsole.NativeMethods' -as [type])) {
			Add-Type -Namespace AvdConsole -Name NativeMethods -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern IntPtr GetStdHandle(int nStdHandle);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out int lpMode);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetConsoleMode(IntPtr hConsoleHandle, int dwMode);
'@
		}

		$stdoutHandle = [AvdConsole.NativeMethods]::GetStdHandle(-11)
		if ($stdoutHandle -eq [IntPtr]::Zero -or $stdoutHandle -eq [IntPtr](-1)) { return $false }

		$mode = 0
		if (-not [AvdConsole.NativeMethods]::GetConsoleMode($stdoutHandle, [ref]$mode)) { return $false }

		$virtualTerminalProcessing = 0x0004
		if (($mode -band $virtualTerminalProcessing) -eq 0) {
			[void][AvdConsole.NativeMethods]::SetConsoleMode($stdoutHandle, ($mode -bor $virtualTerminalProcessing))
		}

		$verifiedMode = 0
		if (-not [AvdConsole.NativeMethods]::GetConsoleMode($stdoutHandle, [ref]$verifiedMode)) { return $false }

		return (($verifiedMode -band $virtualTerminalProcessing) -ne 0)
	} catch {
		return $false
	}
}

$script:_ansiSupported = Test-AnsiConsoleSupport

try {
	$script:_fancyConsoleSupported = $script:_ansiSupported -and ($PSVersionTable.PSEdition -eq 'Core')
} catch {
	$script:_fancyConsoleSupported = $false
}

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
	Write-Host ''
	$border = '-' * $width
	if ($script:_fancyConsoleSupported) {
		Write-Host (Format-Ansi "  `e[1m`e[96m+$border+`e[0m")
		foreach ($line in $Lines) {
			$padded = ' ' + $line.PadRight($width - 1)
			Write-Host (Format-Ansi "  `e[96m|`e[0m`e[97m$padded`e[0m`e[96m|`e[0m")
		}
		Write-Host (Format-Ansi "  `e[1m`e[96m+$border+`e[0m")
	} else {
		Write-Host "  +$border+"
		foreach ($line in $Lines) {
			$padded = ' ' + $line.PadRight($width - 1)
			Write-Host "  |$padded|"
		}
		Write-Host "  +$border+"
	}
	Write-Host ''
}

function Write-Rule {
	param([string]$Title = '', [int]$Width = 62)
	$rule = '-' * $Width
	if (-not [string]::IsNullOrEmpty($Title)) {
		Write-Host ''
		if ($script:_fancyConsoleSupported) {
			Write-Host (Format-Ansi "  `e[90m$rule`e[0m")
			Write-Host (Format-Ansi "  `e[1m`e[96m$Title`e[0m")
			Write-Host (Format-Ansi "  `e[90m$rule`e[0m")
		} else {
			Write-Host "  $rule"
			Write-Host "  $Title"
			Write-Host "  $rule"
		}
	} else {
		Write-Host ''
		if ($script:_fancyConsoleSupported) {
			Write-Host (Format-Ansi "  `e[90m$rule`e[0m")
		} else {
			Write-Host "  $rule"
		}
		Write-Host ''
	}
}

# Shared state for the background spinner - accessed by both the main thread and the runspace.
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
				$barStr = "  ${dim}[${reset}${purple}$(('#' * $f))${dim}$(('.' * ($w - $f)))]${reset}  $pct%"
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
	$script:AuditPortableMode = [string]::IsNullOrWhiteSpace($OutputDirectory) -and -not (Test-RepoLayoutAvailable)
	$script:AuditArchiveBaseName = '{0}-audit-results' -f (ConvertTo-SafePathSegment -Value $customerCode)
	$resolvedOutputDirectory = $null
	$resolvedOutputDirectory = Resolve-AuditOutputDirectory -CustomerCode $customerCode -RequestedOutputDirectory $OutputDirectory
	if (-not (Test-Path -Path $resolvedOutputDirectory)) {
		New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
	}
	$script:AuditTranscriptPath = Join-Path -Path $resolvedOutputDirectory -ChildPath 'Invoke-AvdSessionHostAudit.transcript.txt'
	$script:AuditFailureLogPath = Join-Path -Path $resolvedOutputDirectory -ChildPath 'Invoke-AvdSessionHostAudit.error.log'
	try {
		Start-Transcript -Path $script:AuditTranscriptPath -Force | Out-Null
	}
	catch {
		$script:AuditTranscriptPath = $null
	}
	$scriptStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
	$resolvedOutputPath = $null

	Write-Banner @(
		'AVD Discovery - Session Host Audit',
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

	$resolvedOutputPath = New-ExportFilePath -Directory $resolvedOutputDirectory -CustomerCode $customerCode -Hostname $machineDetails.Hostname
	$outputDirectory = Split-Path -Path $resolvedOutputPath -Parent

	if (-not [string]::IsNullOrWhiteSpace($outputDirectory) -and -not (Test-Path -Path $outputDirectory)) {
		New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
	}
	Add-SessionHostAuditArtifact -Path $resolvedOutputPath

	Write-CheckStart 'Group Policy'
	$shouldRunGpresult = -not $NoGpresult.IsPresent -and [bool]$joinDiscovery.PartOfDomain
	$gpResultHtmlPath = if ($shouldRunGpresult) { [System.IO.Path]::ChangeExtension($resolvedOutputPath, '.gpresult.html') } else { $null }
	$groupPolicyDiscovery = if ($NoGpresult.IsPresent) {
		Write-CheckResult 'Skipped' '-NoGpresult specified'
		$null
	} elseif (-not [bool]$joinDiscovery.PartOfDomain) {
		Write-CheckResult 'Skipped' 'machine is not Active Directory joined'
		[PSCustomObject]@{
			Succeeded      = $false
			Note           = 'Skipped because machine is not Active Directory joined'
			HtmlReportPath = $null
			Error          = $null
		}
	} else {
		$_gp = Get-GroupPolicyDiscovery -OutputPath $gpResultHtmlPath
		if ($_gp.Succeeded) {
			Write-CheckResult 'Success' "HTML report: $(Split-Path $gpResultHtmlPath -Leaf)"
		} else {
				Write-CheckResult 'Skipped' $(if ($_gp.Error) { $_gp.Error } else { 'gpresult returned no data' })
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
		ReportType           = 'AzureSessionHostAudit'
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
		HtmlGeneration       = [PSCustomObject]@{
			Requested       = -not $NoHtml.IsPresent
			Status          = if ($NoHtml.IsPresent) { 'Skipped' } else { 'Pending' }
			Message         = if ($NoHtml.IsPresent) { '-NoHtml specified.' } else { 'Awaiting shared HTML generation.' }
			HtmlPath        = $null
			GeneratorScript = $null
			GeneratedAt     = $null
		}
	}

	$resolvedHtmlPath = [System.IO.Path]::ChangeExtension($resolvedOutputPath, '.html')
	$stagingJsonPath = $resolvedOutputPath
	$shouldStageJson = -not $NoHtml.IsPresent
	if ($shouldStageJson) {
		$stagingJsonPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ([System.IO.Path]::GetRandomFileName() + '.json')
	}

	try {
		$exportObject | ConvertTo-Json -Depth 10 |
			ForEach-Object { [regex]::Replace($_, '(?m)^(    )+', { param($m) '  ' * ($m.Value.Length / 4) }) } |
			ForEach-Object { $_ -replace ':  ', ': ' } |
			Set-Content -Path $stagingJsonPath -Encoding UTF8

		if (-not $NoHtml.IsPresent) {
			$exportObject.HtmlGeneration = Invoke-OptionalHtmlReportGeneration -JsonPath $stagingJsonPath -ReportType $exportObject.ReportType -OutputPath $resolvedHtmlPath
			if ($exportObject.HtmlGeneration.Status -eq 'Generated' -and -not [string]::IsNullOrWhiteSpace($exportObject.HtmlGeneration.HtmlPath)) {
				Add-SessionHostAuditArtifact -Path $exportObject.HtmlGeneration.HtmlPath
			}
		}

		$exportObject | ConvertTo-Json -Depth 10 |
			ForEach-Object { [regex]::Replace($_, '(?m)^(    )+', { param($m) '  ' * ($m.Value.Length / 4) }) } |
			ForEach-Object { $_ -replace ':  ', ': ' } |
			Set-Content -Path $resolvedOutputPath -Encoding UTF8
	}
	finally {
		if ($stagingJsonPath -ne $resolvedOutputPath -and (Test-Path -Path $stagingJsonPath)) {
			Remove-Item -Path $stagingJsonPath -Force
		}
	}

	$_elapsed = $scriptStopwatch.Elapsed
	$_elapsedStr = if ($_elapsed.TotalMinutes -ge 1) {
		"$([Math]::Floor($_elapsed.TotalMinutes))m $($_elapsed.Seconds)s"
	} else { "$([Math]::Round($_elapsed.TotalSeconds, 1))s" }

	Write-Rule
	Write-Host (Format-Ansi "  `e[92mDiscovery complete in $_elapsedStr`e[0m")
	if ($exportObject.HtmlGeneration.Status -eq 'Generated') {
		Write-Host "  HTML report   :  $($exportObject.HtmlGeneration.HtmlPath)" -ForegroundColor Cyan
	}
	if ($null -ne $groupPolicyDiscovery -and $groupPolicyDiscovery.Succeeded) {
		Write-Host "  GP report     :  $gpResultHtmlPath" -ForegroundColor Cyan
		Add-SessionHostAuditArtifact -Path $gpResultHtmlPath
	}
	Write-Host ''
}
catch {
	try { Clear-SpinnerLine } catch { }
	$errLocation = if ($_.InvocationInfo) { " [line $($_.InvocationInfo.ScriptLineNumber)]" } else { '' }
	$failureLogPath = $null
	try {
		$failureLogPath = Write-SessionHostAuditFailureLog -ErrorRecord $_ -PreferredPath $resolvedOutputPath
		Add-SessionHostAuditArtifact -Path $failureLogPath
		if (-not [string]::IsNullOrWhiteSpace($script:AuditTranscriptPath) -and (Test-Path -Path $script:AuditTranscriptPath)) {
			Add-SessionHostAuditArtifact -Path $script:AuditTranscriptPath
		}
	}
	catch {
		$failureLogPath = $null
	}

	$failureMessage = "Failed to discover applications or write JSON output.${errLocation} $($_.Exception.Message)"
	if (-not [string]::IsNullOrWhiteSpace($failureLogPath)) {
		$failureMessage += "`nFailure log: $failureLogPath"
	}
	Write-Error $failureMessage
	Wait-ForInteractiveErrorAcknowledgement -Message 'The script failed. Review the error above, then press Enter to close this window.'
	$script:AuditExitCode = 1
}
finally {
	try {
		Stop-Transcript | Out-Null
	}
	catch {
	}

	try {
		if ($script:AuditExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($script:AuditTranscriptPath) -and (Test-Path -Path $script:AuditTranscriptPath)) {
			Remove-Item -Path $script:AuditTranscriptPath -Force
		}

		$script:AuditArchivePath = Compress-PortableAuditArtifacts -SourceDirectory $resolvedOutputDirectory -ArchiveBaseName $script:AuditArchiveBaseName
		if (-not [string]::IsNullOrWhiteSpace($script:AuditArchivePath)) {
			Write-Host "  Portable ZIP :  $script:AuditArchivePath" -ForegroundColor Cyan
			Remove-PortableAuditArtifacts -ArchivePath $script:AuditArchivePath -PreservePaths @($script:AuditTranscriptPath)
		}
	}
	catch {
		Write-Warning "Portable ZIP creation failed: $($_.Exception.Message)"
	}
}

if ($script:AuditExitCode -ne 0) {
	exit $script:AuditExitCode
}

