[CmdletBinding()]
<#
.SYNOPSIS
Gathers metrics and infrastructure details for Azure Virtual Desktop (AVD) Host Pools and
exports the results to JSON. This script is strictly read-only and cannot modify or delete
any Azure resources.

.DESCRIPTION
This script enumerates all AVD Host Pools across one or more Azure subscriptions and collects
the following information for each pool:

  INFRASTRUCTURE
    - Host pool type (Pooled / Personal) and load balancer type
    - Number of session hosts (VMs) registered to the pool
    - VM SKU(s) in use — reports all distinct sizes to handle mixed-SKU pools
    - Scaling plan name, enabled state, and schedule count (if a plan is associated)

  USAGE METRICS
    - Daily Average Users: mean of daily unique user connection counts over the lookback window
    - Per-day breakdown of unique users and total data points collected
    - Data sourced from the WVDConnections table in the Log Analytics workspace linked to
      each host pool's diagnostic settings

  RIGHT-SIZING METRICS
    - Average CPU %: mean of daily average Percentage CPU across all session host VMs over
      the lookback window. Sourced from Azure Monitor platform metrics — available for all
      Azure VMs without any monitoring agent.
    - Average Memory % Used: mean of (totalRAM - availableRAM) / totalRAM * 100 across all
      session host VMs. Available Memory Bytes sourced from Azure Monitor platform metrics
      (no agent required); total RAM per VM resolved from the Compute SKUs API.
      MemoryStatus 'NoData' means Azure Monitor has no data points for the VM(s).
      MemoryStatus 'NoSkuData' means the SKU memory lookup failed.

  AUTHORIZATION
    - Authorized User Count: number of unique users holding the 'Desktop Virtualization User'
      RBAC role on the host pool's app group(s). This is the maximum number of distinct users
      permitted to connect to the pool.
    - Entra ID group assignments are resolved transitively via Microsoft Graph, so a user
      appearing in multiple applicable groups is counted only once.
    - Workspace name(s) and app group name(s) associated with the host pool are also reported.
    - AuthorizedUserStatus 'GroupsFoundButNoGraphToken' means group assignments were found but
      the Graph token could not be acquired; the count reflects direct user assignments only.
    - Requires the authenticated account to have read access to Entra ID group membership.

  OUTPUT
    - Results are written to a timestamped JSON file. No Azure resources are modified.
    - The export includes an ExcludeWeekends flag so the filtering context is preserved
      alongside the averaged figures.

  WEEKEND EXCLUSION
    - Pass -ExcludeWeekends to omit Saturday and Sunday data points from all averages
      (CPU %, memory %, and daily average users). Useful where weekend usage is unrepresentative
      of normal business-hours load. The flag is recorded in the JSON export.

  PEAK HOURS FILTER (9:00–18:00)
    - Pass -PeakHoursOnly to restrict all metric averages to the 09:00–18:00 window only.
      For CPU and memory this switches Azure Monitor from daily to hourly granularity and
      discards data points outside the window. For daily average users the WVDConnections
      KQL query is filtered to only count connections that started within the window.
    - All filtering is applied in UTC. Use -UtcOffsetHours to shift the window to local time
      (e.g. -UtcOffsetHours 1 for BST, -UtcOffsetHours 0 for GMT/UTC).
    - The window, offset, and resulting UTC hours are recorded in the JSON export.
    - Can be combined freely with -ExcludeWeekends.

SAFETY FEATURES
	1. AST allowlist assertion — the script parses its own source code at startup and throws
		 before making any Azure API calls if a cmdlet outside the approved read-only set is
		 detected. This prevents accidental write operations from being introduced by future edits.
		 Approved cmdlets: Connect-AzAccount, Get-AzContext, Get-AzSubscription, Set-AzContext,
		 Disable-AzContextAutosave, Get-AzWvdHostPool, Invoke-AzRestMethod, Get-AzAccessToken.

  2. Context autosave disabled (process-scoped) — Disable-AzContextAutosave is called at
     startup so that none of the subscription context switches made during execution are
     persisted to disk. This has no effect on the user's saved contexts.

  3. Original context restored on exit — the caller's active Az context is captured before
     execution begins and restored in a finally block, ensuring the terminal is not left
     pointing at a different subscription regardless of whether the script succeeds or fails.

  4. All Azure calls are GET, POST, PUT, or DELETE (query-only for reads; PUT/DELETE scoped to
     transient runCommands child resources created and immediately removed by -RunLocalDiscovery).
     The only file written is the local JSON export.

PREREQUISITES
	- Az.Accounts and Az.DesktopVirtualization modules installed
	- Ability to authenticate with Connect-AzAccount when prompted at startup
	- For usage metrics: each host pool must have Diagnostic Settings configured to forward
		the 'Connection' log category to a Log Analytics workspace

.PARAMETER SubscriptionId
One or more Azure Subscription IDs to query. If omitted, all enabled subscriptions accessible
to the authenticated account are queried.

.PARAMETER LookbackDays
Number of calendar days to include when calculating usage metrics. Defaults to 30. Maximum 90.

.PARAMETER OutputDirectory
Directory where the JSON export file will be written. Defaults to the directory containing
this script.

.PARAMETER CustomerAbbreviation
Short customer code used in the export filename. If omitted, the script prompts for it.

.PARAMETER ExcludeWeekends
When specified, Saturday and Sunday data points are omitted from all metric averages
(CPU %, memory %, daily average users). Useful when weekend activity is not representative
of typical business-hours load. The flag is recorded in the JSON export.

.PARAMETER PeakHoursOnly
When specified, restricts all metric averages to the 09:00-18:00 local time window.
For CPU and memory, Azure Monitor is queried at hourly granularity and hours outside
the window are discarded. For daily average users, only WVDConnections events within
the window are counted. Use -UtcOffsetHours to align the window to local time.

.PARAMETER UtcOffsetHours
UTC offset in hours used to shift the 09:00-18:00 peak hours window to local time.
Defaults to 0 (UTC). Use 1 for BST (British Summer Time), 0 for GMT. Only applies
when -PeakHoursOnly is specified.

.PARAMETER SkipLicenceCheck
When specified, skips the Microsoft 365 licence assignment collection step entirely.
This suppresses the Graph API calls used to identify which SKUs each authorised user
holds and to detect users with no AVD-eligible licence. Useful when the authenticated
account lacks Graph permission, when the tenant has a large number of authorised users
and the additional collection time is not wanted, or when licence data is not required
for the current engagement. When skipped, LicenseSummaryStatus is set to 'Skipped'
and all related fields are empty in the export.

.PARAMETER NoGpresult
When specified alongside -RunLocalDiscovery, passes -NoGpresult to Invoke-AvdSessionHostAudit.ps1
so that the gpresult HTML report is not generated on the session host. Useful when
Group Policy data is not required or when gpresult is known to fail in the target
environment.

.PARAMETER NoHtml
Skips HTML report generation for the metrics export and any locally saved session host audit
JSON retrieved during -RunLocalDiscovery.

.PARAMETER InlineLocalScript
When specified alongside -RunLocalDiscovery, embeds Invoke-AvdSessionHostAudit.ps1 and
config/appExclusions.config.json directly into the Run Command payload instead of
downloading them from GitHub on the VM. This avoids the requirement for VMs
to have outbound HTTPS access to raw.githubusercontent.com, which may be
blocked by antivirus software, firewalls, or proxy configurations.
The files are read from the local repository directory (alongside this script)
and base64-encoded into the wrapper script. The combined payload (~98 KB) fits
within the Azure Run Command v2 limit of 256 KB.

.PARAMETER LocalDiscoveryTimeout
Maximum seconds to wait for the Run Command script to complete on each session
host VM when using -RunLocalDiscovery. Defaults to 300 (5 minutes). Increase
this value if your VMs are slow to execute the script (e.g. many installed
applications or slow storage). Reduce it if you want faster failure detection
when the VM agent is unresponsive. Valid range: 60–3600.
During execution, the ARM instanceView is also checked every 3 polls for early
failure states (Failed, TimedOut, Canceled) to abort without waiting for the
full timeout when the VM agent reports back promptly.

.PARAMETER RunAsUser
When specified alongside -RunLocalDiscovery, prompts for a username and password
that are passed to the Azure VM Run Command API as 'runAsUser' and 'runAsPassword'.
The script then executes as that user instead of NT AUTHORITY\SYSTEM, which gives
access to per-user registry hives (HKCU), user-scoped Group Policy, OneDrive KFM
status, per-user application installs, and mapped drives.

*** SECURITY WARNING ***
The entered password is transmitted in plaintext in the ARM API request body over
HTTPS and is briefly stored in the Azure runCommands child resource until it is
deleted. The script always deletes the resource in a finally block, but the
credentials are transiently visible in ARM activity logs and to anyone with
read access to the runCommands resource. Do not use privileged or shared service
account credentials. Prefer a standard non-admin domain user account.

.PARAMETER GitHubBranch
The branch name used when downloading Invoke-AvdSessionHostAudit.ps1 and config/appExclusions.config.json
from the GitHub repository (https://github.com/wavenetuk/avd-discovery) during
-RunLocalDiscovery execution. Defaults to 'main'. Use a feature branch name when
testing changes that have not yet been merged.

.PARAMETER GeneratedBy
Engineer name recorded in the export and HTML report. If omitted, the script prompts
for a non-empty value before collection starts.

.PARAMETER ProjectCode
Project code recorded in the export and HTML report. If omitted, the script prompts
for a non-empty value before collection starts.

.EXAMPLE
.\Invoke-AvdMetricsCollection.ps1

.EXAMPLE
.\Invoke-AvdMetricsCollection.ps1 -CustomerAbbreviation kcr -LookbackDays 14 -ExcludeWeekends

.EXAMPLE
.\Invoke-AvdMetricsCollection.ps1 -CustomerAbbreviation kcr -LookbackDays 14 -PeakHoursOnly -UtcOffsetHours 1

.EXAMPLE
.\Invoke-AvdMetricsCollection.ps1 -CustomerAbbreviation kcr -LookbackDays 14 -PeakHoursOnly -ExcludeWeekends -UtcOffsetHours 1

.EXAMPLE
.\Invoke-AvdMetricsCollection.ps1 -CustomerAbbreviation kcr -SubscriptionId '00000000-0000-0000-0000-000000000000' -OutputDirectory .\exports

.EXAMPLE
.\Invoke-AvdMetricsCollection.ps1 -CustomerAbbreviation kcr -RunLocalDiscovery -InlineLocalScript -NoGpresult
Runs local discovery with the script files embedded directly in the Run Command payload,
bypassing the need for VMs to reach raw.githubusercontent.com. Useful when AV or
firewalls block outbound HTTPS from session hosts.
#>

param(
	[Parameter(Mandatory = $false)]
	[string[]]$SubscriptionId,

	[Parameter(Mandatory = $false)]
	[ValidateRange(1, 90)]
	[int]$LookbackDays = 30,

	[Parameter(Mandatory = $false)]
	[string]$OutputDirectory = "",

	[Parameter(Mandatory = $false)]
	[string]$CustomerAbbreviation,

	[Parameter(Mandatory = $false)]
	[switch]$ExcludeWeekends,

	[Parameter(Mandatory = $false)]
	[switch]$PeakHoursOnly,

	[Parameter(Mandatory = $false)]
	[ValidateRange(-12, 14)]
	[int]$UtcOffsetHours = 0,

	[Parameter(Mandatory = $false)]
	[string[]]$HostPoolName,

	[Parameter(Mandatory = $false)]
	[switch]$RunLocalDiscovery,

	[Parameter(Mandatory = $false)]
	[string]$GitHubBranch = 'main',

	[Parameter(Mandatory = $false)]
	[switch]$SkipLicenceCheck,

	[Parameter(Mandatory = $false)]
	[switch]$NoGpresult,

	[Parameter(Mandatory = $false)]
	[switch]$NoHtml,

	[Parameter(Mandatory = $false)]
	[switch]$InlineLocalScript,

	[Parameter(Mandatory = $false)]
	[switch]$RunAsUser,

	[Parameter(Mandatory = $false)]
	[ValidateRange(60, 3600)]
	[int]$LocalDiscoveryTimeout = 300,

	[Parameter(Mandatory = $false)]
	[string]$GeneratedBy,

	[Parameter(Mandatory = $false)]
	[string]$ProjectCode,

	[Parameter(Mandatory = $false)]
	[AllowEmptyCollection()]
	[string[]]$ScanStorageAccounts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------------

function Get-RunAsCredential {
	<#
	.SYNOPSIS
	Displays a prominent security warning and prompts for a username and password
	to use with the Azure VM Run Command runAsUser/runAsPassword feature.
	#>
	Write-Host ''
	Write-Host '  ╔══════════════════════════════════════════════════════════════════════╗' -ForegroundColor Yellow
	Write-Host '  ║  Security notice — Run-As credentials                                ║' -ForegroundColor Yellow
	Write-Host '  ║                                                                      ║' -ForegroundColor Yellow
	Write-Host '  ║  The password travels in the ARM request body (HTTPS only) and is    ║' -ForegroundColor Yellow
	Write-Host '  ║  held briefly in the runCommands resource until deleted. It is not   ║' -ForegroundColor Yellow
	Write-Host '  ║  logged by ARM. The username IS visible in ARM activity logs.        ║' -ForegroundColor Yellow
	Write-Host '  ║                                                                      ║' -ForegroundColor Yellow
	Write-Host '  ║  Use a standard non-admin domain account — not a service account,    ║' -ForegroundColor Yellow
	Write-Host '  ║  shared account, or anything with elevated privileges.               ║' -ForegroundColor Yellow
	Write-Host '  ╚══════════════════════════════════════════════════════════════════════╝' -ForegroundColor Yellow
	Write-Host ''

	$username = $null
	while ([string]::IsNullOrWhiteSpace($username)) {
		$username = (Read-Host '  Run-as username (e.g. DOMAIN\user or user@domain.com)').Trim()
	}

	$securePassword = $null
	while ($null -eq $securePassword -or $securePassword.Length -eq 0) {
		$securePassword = Read-Host '  Run-as password' -AsSecureString
	}

	Write-Host ''

	$bstr     = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
	$plainPwd = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
	[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

	return [PSCustomObject]@{ Username = $username; Password = $plainPwd }
}

function Get-CustomerAbbreviation {
	param(
		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[string]$Value
	)

	$abbreviation = if (-not [string]::IsNullOrWhiteSpace($Value)) { $Value.Trim() } else { $null }
	while ([string]::IsNullOrWhiteSpace($abbreviation)) {
		$abbreviation = (Read-Host 'Enter customer abbreviation for the export filename').Trim()
	}

	return $abbreviation.ToLowerInvariant()
}

function Get-RequiredTextValue {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Prompt,

		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[string]$Value
	)

	$resolvedValue = if (-not [string]::IsNullOrWhiteSpace($Value)) { $Value.Trim() } else { $null }
	while ([string]::IsNullOrWhiteSpace($resolvedValue)) {
		$resolvedValue = (Read-Host $Prompt).Trim()
	}

	return $resolvedValue
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
	Write-Host '  Sign in to the Azure account to use for this collection.' -ForegroundColor Cyan
	$accountId = (Read-Host '  Azure account UPN/email (press Enter for the standard Azure sign-in prompt)').Trim()
	Write-Host ''

	if ([string]::IsNullOrWhiteSpace($accountId)) {
		Connect-AzAccount -ErrorAction Stop | Out-Null
	}
	else {
		Connect-AzAccount -AccountId $accountId -ErrorAction Stop | Out-Null
	}

	$connectedContext = Get-AzContext
	if (-not $connectedContext -or -not $connectedContext.Account) {
		throw 'Azure authentication completed without an active context.'
	}

	Write-Host "  Signed in as: $($connectedContext.Account.Id)" -ForegroundColor DarkGray
	Write-Host ''

	return $connectedContext
}

function New-ExportFilePath {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Directory,

		[Parameter(Mandatory = $true)]
		[string]$CustomerCode
	)

	$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
	$fileName = '{0}-avd-metrics-{1}.json' -f $CustomerCode, $timestamp
	return Join-Path -Path $Directory -ChildPath $fileName
}

# ------------------------------------------------------------------
# Console output helpers
# ------------------------------------------------------------------

$script:_checkLabel = ''

function Write-Banner {
	param([string[]]$Lines)
	$maxLen = ($Lines | Measure-Object -Property Length -Maximum).Maximum
	$width  = [Math]::Max(64, $maxLen + 4)
	$border = '═' * $width
	Write-Host ''
	Write-Host "  `e[1m`e[96m╔$border╗`e[0m"
	foreach ($line in $Lines) {
		$padded = ' ' + $line.PadRight($width - 1)
		Write-Host "  `e[96m║`e[0m`e[97m$padded`e[0m`e[96m║`e[0m"
	}
	Write-Host "  `e[1m`e[96m╚$border╝`e[0m"
	Write-Host ''
}

function Write-Rule {
	param([string]$Title = '', [int]$Width = 66)
	if (-not [string]::IsNullOrEmpty($Title)) {
		Write-Host ''
		Write-Host "  `e[90m$('─' * $Width)`e[0m"
		Write-Host "  `e[1m`e[96m$Title`e[0m"
		Write-Host "  `e[90m$('─' * $Width)`e[0m"
	} else {
		Write-Host ''
		Write-Host "  `e[90m$('─' * $Width)`e[0m"
		Write-Host ''
	}
}

function Write-PoolHeader {
	param([int]$Index, [int]$Total, [PSCustomObject]$Pool)
	$bar = '─' * 66
	Write-Host ''
	Write-Host "  `e[90m$bar`e[0m"
	Write-Host "  `e[1m`e[97mHOST POOL [$Index/$Total]`e[0m  `e[96m$($Pool.Name)`e[0m"
	Write-Host "  `e[90mSubscription : $($Pool.SubscriptionName)  |  Region : $($Pool.Location)  |  Type : $($Pool.HostPoolType)`e[0m"
	Write-Host "  `e[90m$bar`e[0m"
}

# Shared state for the background spinner — accessed by both the main thread and the runspace.
$script:_progressActivity = 'AVD Metrics Collection'
$script:_spinnerState = [hashtable]::Synchronized(@{
	Active   = $false
	Activity = 'AVD Metrics Collection'
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
		while ($_st.Run) {
			if (-not $_st.Active) { Start-Sleep -Milliseconds 50; continue }
			$s   = $frames[$idx % 4]; $idx++
			$act = $_st.Activity; $sts = $_st.Status; $pct = $_st.Pct
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
	# Updates the displayed status without interrupting the running spinner
	param([string]$Status, [int]$Pct = -1)
	$script:_spinnerState.Status = $Status
	if ($Pct -ge 0) { $script:_spinnerState.Pct = $Pct }
}

function Clear-SpinnerLine {
	Stop-SpinnerRunspace
	[Console]::Write("`r`e[K")
}

function Write-CheckStart {
	param([string]$Name, [int]$Indent = 6)
	$script:_checkLabel = (' ' * $Indent) + $Name.PadRight(26) + '  '
	if ($script:_progressTotal -gt 0) {
		$_pct = [Math]::Min([int](($script:_progressStep / $script:_progressTotal) * 100), 100)
		$script:_spinnerState.Activity = $script:_progressActivity
		$script:_spinnerState.Status   = $Name
		$script:_spinnerState.Pct      = $_pct
		$script:_spinnerState.Active   = $true
		Start-SpinnerRunspace
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
	if ($script:_progressTotal -gt 0) {
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
		$color = switch ($Status) {
			'Success' { 'Green'   }
			'Skipped' { 'Yellow'  }
			'Failed'  { 'Red'     }
			'Info'    { 'DarkGray'}
		}
		Write-Host "$($script:_checkLabel)$Status$suffix" -ForegroundColor $color
	}
}

# ------------------------------------------------------------------
# Storage account FSLogix scanning
# ------------------------------------------------------------------

function Get-StorageAccountInput {
	<#
	.SYNOPSIS
	Prompts for storage account names interactively when -ScanStorageAccounts is
	present but -StorageAccountName was not supplied on the command line.
	Accepts a comma- or newline-separated list; blank input ends the prompt.
	#>
	Write-Host ''
	Write-Host '  Enter the storage account name(s) to scan.' -ForegroundColor Cyan
	Write-Host '  You may enter one per line, or separate multiple with commas.' -ForegroundColor DarkGray
	Write-Host '  Press Enter on a blank line when done.' -ForegroundColor DarkGray
	Write-Host ''

	$names = [System.Collections.Generic.List[string]]::new()
	while ($true) {
		$line = (Read-Host '  Storage account name').Trim()
		if ([string]::IsNullOrWhiteSpace($line)) { break }
		foreach ($part in ($line -split '[,\s]+')) {
			$part = $part.Trim()
			if (-not [string]::IsNullOrEmpty($part)) { $names.Add($part) }
		}
	}
	Write-Host ''
	return $names.ToArray()
}

function Get-StorageAccountByName {
	<#
	.SYNOPSIS
	Searches all accessible subscriptions for storage accounts matching the given names.
	Returns an array of objects with SubscriptionId, SubscriptionName, ResourceGroup, and the raw ARM resource.
	#>
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

function Get-FileShareBackupStatus {
	<#
	.SYNOPSIS
	Checks whether each file share in the given storage account is protected by
	an Azure Backup Recovery Services Vault. Returns a hashtable keyed by
	lower-case share name -> PSCustomObject with BackupEnabled + VaultName.
	#>
	param(
		[Parameter(Mandatory = $true)]
		[string]$SubscriptionId,

		[Parameter(Mandatory = $true)]
		[string]$StorageAccountId,

		[Parameter(Mandatory = $true)]
		[hashtable]$VaultCache
	)

	$result = @{}

	if (-not $VaultCache.ContainsKey($SubscriptionId)) {
		$vResp = Invoke-ArmRequest -Path "/subscriptions/$SubscriptionId/providers/Microsoft.RecoveryServices/vaults?api-version=2023-06-01" -Method GET -ErrorAction SilentlyContinue
		$VaultCache[$SubscriptionId] = if ($vResp -and $vResp.StatusCode -eq 200) { @(($vResp.Content | ConvertFrom-Json).value) } else { @() }
	}

	foreach ($vault in @($VaultCache[$SubscriptionId])) {
		$vParts  = [string[]]($vault.id -split '/')
		$rgIdx   = [Array]::IndexOf($vParts, 'resourceGroups')
		$vaultRg = if ($rgIdx -ge 0 -and ($rgIdx + 1) -lt $vParts.Count) { $vParts[$rgIdx + 1] } else { $null }
		if (-not $vaultRg) { continue }

		$itemPath = "/subscriptions/$SubscriptionId/resourceGroups/$vaultRg/providers/Microsoft.RecoveryServices/vaults/$($vault.name)/backupProtectedItems?api-version=2023-06-01&`$filter=backupManagementType eq 'AzureStorage'"
		$iResp    = Invoke-ArmRequest -Path $itemPath -Method GET -ErrorAction SilentlyContinue
		if (-not $iResp -or $iResp.StatusCode -ne 200) { continue }

		foreach ($item in @(($iResp.Content | ConvertFrom-Json).value)) {
			$p = $item.properties
			# sourceResourceId for Azure Files items points to the storage account
			$srcId = if ($p.PSObject.Properties['sourceResourceId']) { $p.sourceResourceId } else { $null }
			if (-not $srcId -or $srcId.ToLowerInvariant() -ne $StorageAccountId.ToLowerInvariant()) { continue }
			# friendlyName is the share name
			$shareName = if ($p.PSObject.Properties['friendlyName']) { $p.friendlyName.ToLowerInvariant() } else { $null }
			if (-not $shareName) { continue }
			$result[$shareName] = [PSCustomObject]@{
				BackupEnabled     = $true
				VaultName         = $vault.name
				ProtectionStatus  = if ($p.PSObject.Properties['protectionStatus']) { $p.protectionStatus } else { $null }
				LastBackupStatus  = if ($p.PSObject.Properties['lastBackupStatus'])  { $p.lastBackupStatus }  else { $null }
				LastBackupTime    = if ($p.PSObject.Properties['lastBackupTime'])    { $p.lastBackupTime }    else { $null }
				PolicyName        = if ($p.PSObject.Properties['policyName'])        { $p.policyName }        else { $null }
			}
		}
	}
	return $result
}

function Get-StorageAccountFSLogixInfo {
	<#
	.SYNOPSIS
	Collects FSLogix-relevant details from an Azure Storage Account:
	file shares, SMB settings, encryption, public/private endpoints,
	access key status, replication, IOPS, throughput, and backup status.
	#>
	param(
		[Parameter(Mandatory = $true)]
		[PSCustomObject]$StorageAccount,   # result from Get-StorageAccountByName

		[Parameter(Mandatory = $true)]
		[hashtable]$VaultCache
	)

	$sa   = $StorageAccount.Resource
	$subId = $StorageAccount.SubscriptionId
	$rg    = $StorageAccount.ResourceGroup
	$name  = $sa.name
	$props = $sa.properties

	# ── Basic properties ──────────────────────────────────────────────────────
	$skuName    = if ($sa.sku.PSObject.Properties['name']) { $sa.sku.name } else { $null }
	$skuTier    = if ($sa.sku.PSObject.Properties['tier']) { $sa.sku.tier } else { $null }
	# Replication type is the suffix of the SKU name: Standard_LRS -> LRS
	$replication = if ($skuName -match '_(.+)$') { $Matches[1] } else { $skuName }

	$publicAccess      = if ($props.PSObject.Properties['publicNetworkAccess'])  { $props.publicNetworkAccess }  else { 'Enabled' }
	$accessKeysEnabled = if ($props.PSObject.Properties['allowSharedKeyAccess']) { $props.allowSharedKeyAccess } else { $true }
	$httpsOnly         = if ($props.PSObject.Properties['supportsHttpsTrafficOnly']) { $props.supportsHttpsTrafficOnly } else { $null }
	$minTls            = if ($props.PSObject.Properties['minimumTlsVersion'])    { $props.minimumTlsVersion }    else { $null }

	# ── Identity-based authentication ─────────────────────────────────────────
	$identityAuth = $null
	if ($props.PSObject.Properties['azureFilesIdentityBasedAuthentication']) {
		$_iba    = $props.azureFilesIdentityBasedAuthentication
		$_dsOpts = if ($_iba.PSObject.Properties['directoryServiceOptions']) { $_iba.directoryServiceOptions } else { 'None' }
		$identityAuth = [PSCustomObject]@{
			DirectoryServiceOptions = $_dsOpts
			DefaultSharePermission  = if ($_iba.PSObject.Properties['defaultSharePermission'])  { $_iba.defaultSharePermission }  else { $null }
			DomainName              = if ($_dsOpts -in @('AD','AADDS') -and $_iba.PSObject.Properties['activeDirectoryProperties'] -and
			                              $_iba.activeDirectoryProperties.PSObject.Properties['domainName']) {
				$_iba.activeDirectoryProperties.domainName
			} else { $null }
		}
	}

	$encryptionType = if ($props.PSObject.Properties['encryption'] -and $props.encryption.PSObject.Properties['keySource']) {
		switch ($props.encryption.keySource) {
			'Microsoft.Keyvault' { 'CustomerManagedKey' }
			default              { 'MicrosoftManagedKey' }
		}
	} else { 'MicrosoftManagedKey' }

	$cmkKeyVaultUri = if ($encryptionType -eq 'CustomerManagedKey' -and
	                      $props.encryption.PSObject.Properties['keyVaultProperties']) {
		$props.encryption.keyVaultProperties.keyVaultUri
	} else { $null }

	$networkDefaultAction = if ($props.PSObject.Properties['networkAcls'] -and
	                            $props.networkAcls.PSObject.Properties['defaultAction']) {
		$props.networkAcls.defaultAction
	} else { 'Allow' }

	$networkBypass = if ($props.PSObject.Properties['networkAcls'] -and
	                     $props.networkAcls.PSObject.Properties['bypass']) {
		$props.networkAcls.bypass
	} else { $null }

	# ── Private endpoints ────────────────────────────────────────────────────
	$privateEndpoints = @(
		if ($props.PSObject.Properties['privateEndpointConnections']) {
			foreach ($pec in @($props.privateEndpointConnections)) {
				$pecProps = $pec.properties
				[PSCustomObject]@{
					Name              = ($pec.id -split '/')[-1]
					PrivateEndpointId = if ($pecProps.PSObject.Properties['privateEndpoint'])  { $pecProps.privateEndpoint.id }    else { $null }
					ProvisioningState = if ($pecProps.PSObject.Properties['provisioningState']) { $pecProps.provisioningState }     else { $null }
					ConnectionStatus  = if ($pecProps.PSObject.Properties['privateLinkServiceConnectionState']) { $pecProps.privateLinkServiceConnectionState.status } else { $null }
				}
			}
		}
	)

	# ── File service settings (SMB, soft-delete) ─────────────────────────────
	$smbMultichannel      = $null
	$smbVersions          = @()
	$smbAuthMethods       = @()
	$smbKerberoEncryption = @()
	$smbChannelEncryption = @()
	$softDeleteEnabled    = $null
	$softDeleteRetainDays = $null

	$fsResp = Invoke-ArmRequest -Path "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Storage/storageAccounts/$name/fileServices/default?api-version=2023-01-01" -Method GET -ErrorAction SilentlyContinue
	if ($fsResp -and $fsResp.StatusCode -eq 200) {
		$fsProps = ($fsResp.Content | ConvertFrom-Json).properties

		if ($fsProps.PSObject.Properties['shareDeleteRetentionPolicy']) {
			$softDeleteEnabled    = [bool]$fsProps.shareDeleteRetentionPolicy.enabled
			$softDeleteRetainDays = if ($fsProps.shareDeleteRetentionPolicy.PSObject.Properties['days']) { $fsProps.shareDeleteRetentionPolicy.days } else { $null }
		}

		if ($fsProps.PSObject.Properties['protocolSettings'] -and
		    $fsProps.protocolSettings.PSObject.Properties['smb']) {
			$smb = $fsProps.protocolSettings.smb
			$smbMultichannel      = if ($smb.PSObject.Properties['multichannel'])            { [bool]$smb.multichannel.enabled } else { $null }
			$smbVersions          = if ($smb.PSObject.Properties['versions'] -and -not [string]::IsNullOrEmpty($smb.versions)) { @($smb.versions -split ';') } else { @() }
			$smbAuthMethods       = if ($smb.PSObject.Properties['authenticationMethods'] -and -not [string]::IsNullOrEmpty($smb.authenticationMethods)) { @($smb.authenticationMethods -split ';') } else { @() }
			$smbKerberoEncryption = if ($smb.PSObject.Properties['kerberosTicketEncryption'] -and -not [string]::IsNullOrEmpty($smb.kerberosTicketEncryption)) { @($smb.kerberosTicketEncryption -split ';') } else { @() }
			$smbChannelEncryption = if ($smb.PSObject.Properties['channelEncryption'] -and -not [string]::IsNullOrEmpty($smb.channelEncryption)) { @($smb.channelEncryption -split ';') } else { @() }
		}
	}

	# ── File shares (with usage stats) ───────────────────────────────────────
	$shareBackupMap = Get-FileShareBackupStatus -SubscriptionId $subId -StorageAccountId $sa.id -VaultCache $VaultCache

	$shareList = @()
	# $expand=stats is not supported on Premium FileStorage accounts; fall back without it on 400
	$sharesResp   = Invoke-ArmRequest -Path "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Storage/storageAccounts/$name/fileServices/default/shares?api-version=2023-01-01&`$expand=stats" -Method GET -ErrorAction SilentlyContinue
	$statsExpanded = $sharesResp -and $sharesResp.StatusCode -eq 200
	if (-not $statsExpanded) {
		$sharesResp = Invoke-ArmRequest -Path "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Storage/storageAccounts/$name/fileServices/default/shares?api-version=2023-01-01" -Method GET -ErrorAction SilentlyContinue
	}
	if ($sharesResp -and $sharesResp.StatusCode -eq 200) {
		$shareList = @(($sharesResp.Content | ConvertFrom-Json).value | ForEach-Object {
			$sp            = $_.properties
			$shareName     = $_.name
			$provisionedGb = if ($sp.PSObject.Properties['shareQuota'])    { [int]$sp.shareQuota }    else { $null }
			$usedBytes     = if ($sp.PSObject.Properties['shareUsageBytes']) { [long]$sp.shareUsageBytes } else { $null }
			$usedGb        = if ($null -ne $usedBytes) { [Math]::Round($usedBytes / 1GB, 2) } else { $null }
			$usedPct       = if ($null -ne $usedGb -and $null -ne $provisionedGb -and $provisionedGb -gt 0) {
				[Math]::Round($usedGb / $provisionedGb * 100, 1)
			} else { $null }

			# Premium: IOPS and throughput are provisioned; Standard: scaled from quota
			$provIops       = if ($sp.PSObject.Properties['provisionedIops'])            { $sp.provisionedIops }            else { $null }
			$provBandwidthMiBps = if ($sp.PSObject.Properties['provisionedBandwidthMiBps']) { $sp.provisionedBandwidthMiBps } else { $null }

			$accessTier     = if ($sp.PSObject.Properties['accessTier'])       { $sp.accessTier }       else { $null }
			$protocol       = if ($sp.PSObject.Properties['enabledProtocols']) { $sp.enabledProtocols } else { 'SMB' }

			$backup = if ($shareBackupMap.ContainsKey($shareName.ToLowerInvariant())) {
				$shareBackupMap[$shareName.ToLowerInvariant()]
			} else {
				[PSCustomObject]@{ BackupEnabled = $false; VaultName = $null; ProtectionStatus = $null; LastBackupStatus = $null; LastBackupTime = $null; PolicyName = $null }
			}

			[PSCustomObject]@{
				Name                  = $shareName
				Tier                  = $accessTier
				Protocol              = $protocol
				UsageStatsAvailable   = $statsExpanded
				ProvisionedSizeGb     = $provisionedGb
				UsedSizeGb            = $usedGb
				UsedPercent           = $usedPct
				ProvisionedIops       = $provIops
				ProvisionedBandwidthMiBps = $provBandwidthMiBps
				SoftDeleteEnabled     = $softDeleteEnabled
				SoftDeleteRetainDays  = $softDeleteRetainDays
				BackupEnabled         = $backup.BackupEnabled
				BackupVaultName       = $backup.VaultName
				BackupProtectionStatus = $backup.ProtectionStatus
				BackupLastStatus      = $backup.LastBackupStatus
				BackupLastTime        = $backup.LastBackupTime
				BackupPolicyName      = $backup.PolicyName
			}
		})
	}

	return [PSCustomObject]@{
		Name                 = $name
		SubscriptionId       = $subId
		SubscriptionName     = $StorageAccount.SubscriptionName
		ResourceGroup        = $rg
		Location             = $sa.location
		Kind                 = $sa.kind
		Sku                  = $skuName
		SkuTier              = $skuTier
		ReplicationType      = $replication
		AccessKeysEnabled    = $accessKeysEnabled
		EncryptionType       = $encryptionType
		CmkKeyVaultUri       = $cmkKeyVaultUri
		PublicNetworkAccess  = $publicAccess
		NetworkDefaultAction = $networkDefaultAction
		NetworkBypass        = $networkBypass
		HttpsOnly            = $httpsOnly
		MinimumTlsVersion    = $minTls
		PrivateEndpoints     = $privateEndpoints
		PrivateEndpointCount = $privateEndpoints.Count
		IdentityBasedAuth    = $identityAuth
		FileService          = [PSCustomObject]@{
			SoftDeleteEnabled        = $softDeleteEnabled
			SoftDeleteRetainDays     = $softDeleteRetainDays
			SmbMultichannel          = $smbMultichannel
			SmbVersions              = $smbVersions
			SmbAuthMethods           = $smbAuthMethods
			SmbKerberosEncryption    = $smbKerberoEncryption
			SmbChannelEncryption     = $smbChannelEncryption
		}
		FileShareCount       = $shareList.Count
		FileShares           = $shareList
	}
}

# ------------------------------------------------------------------
# ARM call tracking
# ------------------------------------------------------------------

$script:armCounts = [PSCustomObject]@{ Read = 0; Write = 0 }

function Invoke-ArmRequest {
	<#
	.SYNOPSIS
	Thin wrapper around Invoke-AzRestMethod that increments per-run ARM call counters.
	Reads (GET) count against the 12,000/hour limit; writes (PUT/POST/DELETE/PATCH)
	count against the 1,200/hour limit. Counters are stored in $script:armCounts.
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$Path,

		[string]$Method = 'GET',

		[Parameter(Mandatory = $false)]
		[string]$Payload
	)

	if ($Method.ToUpperInvariant() -in 'PUT', 'POST', 'DELETE', 'PATCH') {
		$script:armCounts.Write++
	} else {
		$script:armCounts.Read++
	}

	$callParams = @{ Path = $Path; Method = $Method; ErrorAction = $ErrorActionPreference }
	if ($PSBoundParameters.ContainsKey('Payload')) { $callParams['Payload'] = $Payload }
	Invoke-AzRestMethod @callParams
}

# ------------------------------------------------------------------
# Read-only safeguards
# ------------------------------------------------------------------

function Assert-ScriptIsReadOnly {
	<#
	.SYNOPSIS
	Parses this script's AST and throws if any Azure cmdlet outside the approved
	read-only allowlist is detected. Catches accidental write operations introduced
	by future edits before any Azure API calls are made.
	#>

	$allowedAzCmdlets = @(
		'Connect-AzAccount',        # interactive sign-in at startup to choose the execution context
		'Get-AzContext',
		'Get-AzSubscription',
		'Set-AzContext',             # switches PS session context only — no Azure resource change
		'Disable-AzContextAutosave', # process-scoped session guard — no Azure resource change
		'Get-AzWvdHostPool',
		'Invoke-AzRestMethod',       # ARM REST calls — GET for reads, PUT/DELETE for Run Command v2 resource lifecycle (when -RunLocalDiscovery is used)
		'Get-AzAccessToken'          # token acquisition for Microsoft Graph (read-only)
	)

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
		if ($name -and $name -match '-Az' -and $name -notin $allowedAzCmdlets) {
			$name
		}
	}

	if ($violations) {
		throw (
			"Read-only assertion failed. The following Azure cmdlet(s) are not on the approved " +
			"read-only allowlist and must be reviewed before this script can run: " +
			($violations -join ', ')
		)
	}
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

# ------------------------------------------------------------------
# Subscription discovery
# ------------------------------------------------------------------

function Get-TargetSubscriptions {
	param(
		[Parameter(Mandatory = $false)]
		[string[]]$SubscriptionIds
	)

	if ($SubscriptionIds -and $SubscriptionIds.Count -gt 0) {
		$subscriptions = foreach ($id in $SubscriptionIds) {
			Get-AzSubscription -SubscriptionId $id
		}
	}
	else {
		Write-Host "    No filter specified — querying all accessible subscriptions." -ForegroundColor DarkGray
		$subscriptions = Get-AzSubscription | Where-Object { $_.State -eq 'Enabled' }
	}

	if (-not $subscriptions -or @($subscriptions).Count -eq 0) {
		throw "No accessible Azure subscriptions found. Ensure you are authenticated with Connect-AzAccount."
	}

	return $subscriptions
}

# ------------------------------------------------------------------
# Host pool discovery
# ------------------------------------------------------------------

function Get-AllHostPools {
	param(
		[Parameter(Mandatory = $true)]
		[object[]]$Subscriptions
	)

	$allHostPools = [System.Collections.Generic.List[PSCustomObject]]::new()

	foreach ($subscription in $Subscriptions) {
		Write-Host "      Subscription : $($subscription.Name)  ($($subscription.Id))" -ForegroundColor DarkGray
		Set-AzContext -SubscriptionId $subscription.Id -WarningAction SilentlyContinue | Out-Null

		$hostPools = Get-AzWvdHostPool -ErrorAction SilentlyContinue
		if (-not $hostPools) {
			Write-Host "      No host pools found in this subscription." -ForegroundColor DarkYellow
			continue
		}

		foreach ($pool in $hostPools) {
			# Fetch the full ARM resource for fields not exposed by the PS cmdlet object
			$poolArmData = $null
			try {
				$poolArmResp = Invoke-ArmRequest -Path "$($pool.Id)?api-version=2023-09-05" -Method GET -ErrorAction SilentlyContinue
				if ($poolArmResp -and $poolArmResp.StatusCode -eq 200) {
					$poolArmData = $poolArmResp.Content | ConvertFrom-Json
				}
			} catch { <# Non-fatal — continue with cmdlet data only #> }

			$poolTags = if ($poolArmData -and $poolArmData.PSObject.Properties['tags'] -and $poolArmData.tags) {
				$tagHash = @{}
				foreach ($prop in $poolArmData.tags.PSObject.Properties) { $tagHash[$prop.Name] = $prop.Value }
				$tagHash
			} else { @{} }

			$poolProps = if ($poolArmData) { $poolArmData.properties } else { $null }

			$allHostPools.Add([PSCustomObject]@{
				SubscriptionId                  = $subscription.Id
				SubscriptionName                = $subscription.Name
				ResourceId                      = $pool.Id
				Name                            = $pool.Name
				ResourceGroup                   = ($pool.Id -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
				Location                        = $pool.Location
				HostPoolType                    = $pool.HostPoolType.ToString()
				LoadBalancerType                = $pool.LoadBalancerType.ToString()
				MaxSessionLimit                 = $pool.MaxSessionLimit
				FriendlyName                    = $pool.FriendlyName
				CustomRdpProperty               = $pool.CustomRdpProperty
				StartVMOnConnect                = if ($poolProps -and $poolProps.PSObject.Properties['startVMOnConnect']) { $poolProps.startVMOnConnect } else { $null }
				ValidationEnvironment           = if ($poolProps -and $poolProps.PSObject.Properties['validationEnvironment']) { $poolProps.validationEnvironment } else { $null }
				PersonalDesktopAssignmentType   = if ($poolProps -and $poolProps.PSObject.Properties['personalDesktopAssignmentType']) { $poolProps.personalDesktopAssignmentType } else { $null }
				PreferredAppGroupType           = if ($poolProps -and $poolProps.PSObject.Properties['preferredAppGroupType']) { $poolProps.preferredAppGroupType } else { $null }
				Tags                            = $poolTags
			})
		}

		Write-Host "      Discovered $(@($hostPools).Count) host pool(s)." -ForegroundColor DarkGray
	}

	return $allHostPools
}

# ------------------------------------------------------------------
# Registration token status
# ------------------------------------------------------------------

function Get-HostPoolRegistrationToken {
	<#
	.SYNOPSIS
	Checks whether the host pool has an active (non-expired) registration token.
	Returns token expiration time and active status without revealing the token itself.
	Uses the retrieveRegistrationToken POST endpoint which returns the current token
	metadata (or empty if none exists). The token value itself is not stored.
	#>
	param(
		[Parameter(Mandatory = $true)]
		[PSCustomObject]$HostPool
	)

	try {
		$path = "$($HostPool.ResourceId)/retrieveRegistrationToken?api-version=2023-09-05"
		$resp = Invoke-ArmRequest -Path $path -Method POST -ErrorAction SilentlyContinue
		if ($resp -and $resp.StatusCode -eq 200) {
			$tokenData = $resp.Content | ConvertFrom-Json
			$expiry = if ($tokenData.PSObject.Properties['expirationTime'] -and
			              -not [string]::IsNullOrEmpty($tokenData.expirationTime)) {
				$tokenData.expirationTime
			} else { $null }

			if ($expiry) {
				$expiryDt = [datetime]$expiry
				if ($expiryDt -gt [datetime]::UtcNow) {
					return [PSCustomObject]@{
						HasActiveToken = $true
						ExpiresAt      = $expiry
					}
				}
			}
		}
	}
	catch { <# Non-fatal #> }

	return [PSCustomObject]@{
		HasActiveToken = $false
		ExpiresAt      = $null
	}
}

# ------------------------------------------------------------------
# RDP properties
# ------------------------------------------------------------------

function Get-ParsedRdpProperties {
	<#
	.SYNOPSIS
	Parses the AVD host pool customRdpProperty string into a structured object.
	Each entry in the string is formatted as "name:type:value" separated by semicolons,
	where type is 'i' (integer), 's' (string), or 'b' (boolean).
	Returns both a flat key-value map of every setting and a structured summary of the
	most operationally relevant redirection settings.
	#>
	param(
		[Parameter(Mandatory = $false)]
		[string]$CustomRdpProperty
	)

	$raw = @{}
	if (-not [string]::IsNullOrWhiteSpace($CustomRdpProperty)) {
		foreach ($entry in ($CustomRdpProperty -split ';')) {
			$entry = $entry.Trim()
			if ([string]::IsNullOrWhiteSpace($entry)) { continue }
			$parts = $entry -split ':', 3
			if ($parts.Count -eq 3) {
				$name  = $parts[0].Trim().ToLowerInvariant()
				$type  = $parts[1].Trim().ToLowerInvariant()
				$value = $parts[2]
				$raw[$name] = switch ($type) {
					'i' { if ($value -match '^\d+$') { [int]$value } else { $value } }
					'b' { $value -eq '1' }
					default { $value }
				}
			}
		}
	}

	# Helper: returns enabled/disabled/null for common i:0/i:1 settings
	# For drive redirection the key is 'drivestoredirect' (string) — empty = disabled
	$driveRedirect = if ($raw.ContainsKey('drivestoredirect')) {
		$v = $raw['drivestoredirect']
		[PSCustomObject]@{ Enabled = (-not [string]::IsNullOrEmpty($v)); Value = $v }
	} else { $null }

	$intFlag = {
		param($key)
		if ($raw.ContainsKey($key)) { [PSCustomObject]@{ Enabled = ($raw[$key] -eq 1); RawValue = $raw[$key] } }
		else { $null }
	}

	$audioMode = if ($raw.ContainsKey('audiomode')) {
		$display = switch ($raw['audiomode']) {
			0 { 'PlayOnClient' }
			1 { 'PlayOnServer' }
			2 { 'Disabled' }
			default { "Unknown ($($raw['audiomode']))" }
		}
		[PSCustomObject]@{ Display = $display; RawValue = $raw['audiomode'] }
	} else { $null }

	$cameraRedirect = if ($raw.ContainsKey('camerastoredirect')) {
		$v = $raw['camerastoredirect']
		[PSCustomObject]@{ Enabled = (-not [string]::IsNullOrEmpty($v)); Value = $v }
	} else { $null }

	$usbRedirect = if ($raw.ContainsKey('usbdevicestoredirect')) {
		$v = $raw['usbdevicestoredirect']
		[PSCustomObject]@{ Enabled = (-not [string]::IsNullOrEmpty($v)); Value = $v }
	} else { $null }

	return [PSCustomObject]@{
		RawPropertyString     = $CustomRdpProperty
		AllSettings           = $raw
		DriveRedirection      = $driveRedirect
		ClipboardRedirection  = (& $intFlag 'redirectclipboard')
		PrinterRedirection    = (& $intFlag 'redirectprinters')
		SmartCardRedirection  = (& $intFlag 'redirectsmartcards')
		AudioPlayback         = $audioMode
		AudioCapture          = (& $intFlag 'audiocapturemode')
		CameraRedirection     = $cameraRedirect
		UsbRedirection        = $usbRedirect
		LocationRedirection   = (& $intFlag 'redirectlocation')
	}
}

function Get-HostPoolSsoConfig {
	<#
	.SYNOPSIS
	Assesses whether Entra ID SSO is configured for a host pool.

	Join type detection strategy (in priority order):
	  1. AADLoginForWindows extension present    → cloud-native Entra ID joined
	  2. JsonADDomainExtension present + Graph confirms trustType=AzureAD or ServerAD
	     → Hybrid Entra ID joined (Graph) or pure AD joined
	  3. JsonADDomainExtension only + no Graph token → ActiveDirectory (cannot confirm hybrid)

	Graph is queried for device objects matching the VM names in the pool. A device with
	trustType = 'ServerAD' is Hybrid Entra joined; 'AzureAD' is cloud-native Entra joined.
	If Graph is unavailable the function falls back to extension-only heuristics.

	SSO prerequisites checked:
	  - enablerdsaadauth:i:1 in customRdpProperty (required for all Entra SSO)
	  - targetisaadjoined:i:1 (recommended for Entra ID joined pools)
	#>
	param(
		[Parameter(Mandatory = $true)]
		[PSCustomObject]$Infra,

		[Parameter(Mandatory = $true)]
		[PSCustomObject]$RdpProperties,

		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[string]$GraphToken,

		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[PSCustomObject]$CloudKerberosTrust
	)

	$allSettings = if ($null -ne $RdpProperties -and $null -ne $RdpProperties.AllSettings) { $RdpProperties.AllSettings } else { @{} }

	$hasAadExt = @($Infra.VmExtensions | Where-Object {
		$_.Type -in @('AADLoginForWindows', 'AADLoginForWindowsWithIntune')
	}).Count -gt 0
	$hasAdExt  = @($Infra.VmExtensions | Where-Object {
		$_.Type -eq 'JsonADDomainExtension'
	}).Count -gt 0

	# --- Graph device lookup ---
	# Sample up to 5 VM names to avoid excessive Graph calls on large pools.
	# trustType values: 'AzureAD' = Entra joined, 'ServerAD' = Hybrid Entra joined,
	# 'Workplace' = registered only (not joined).
	$graphDevices        = @()
	$graphQueried        = $false
	$graphTrustTypes     = @()
	if (-not [string]::IsNullOrEmpty($GraphToken) -and @($Infra.VmResourceIds).Count -gt 0) {
		$graphQueried = $true
		$sampleIds    = @($Infra.VmResourceIds | Select-Object -First 5)
		foreach ($vmId in $sampleIds) {
			$vmName = ($vmId -split '/')[-1]
			$_enc   = [Uri]::EscapeDataString($vmName)
			$_uri   = "https://graph.microsoft.com/v1.0/devices?`$filter=displayName eq '$_enc'&`$select=displayName,trustType,isCompliant,isManaged"
			$_resp  = Invoke-GraphGet -Uri $_uri -GraphToken $GraphToken
			if ($_resp -and $_resp.value) {
				foreach ($dev in $_resp.value) {
					$graphDevices    += $dev
					if (-not [string]::IsNullOrEmpty($dev.trustType)) {
						$graphTrustTypes += $dev.trustType
					}
				}
			}
		}
	}

	$distinctTrustTypes = @($graphTrustTypes | Select-Object -Unique)
	$hasGraphServerAD   = 'ServerAD' -in $distinctTrustTypes   # Hybrid Entra joined
	$hasGraphAzureAD    = 'AzureAD'  -in $distinctTrustTypes   # Cloud-native Entra joined

	# Determine join type — Graph results take precedence over extension heuristics
	$joinType = if ($hasAadExt) {
		# AADLoginForWindows extension is only deployed on cloud-native Entra joined VMs
		'EntraID'
	} elseif ($graphQueried -and $hasGraphServerAD) {
		'HybridEntraID'
	} elseif ($graphQueried -and $hasGraphAzureAD) {
		'EntraID'
	} elseif ($hasAdExt -and $graphQueried -and -not $hasGraphServerAD -and -not $hasGraphAzureAD) {
		# AD extension present, Graph returned devices but none were Entra joined
		'ActiveDirectory'
	} elseif ($hasAdExt -and -not $graphQueried) {
		# AD extension only, no Graph — cannot confirm whether hybrid
		'ActiveDirectoryUnconfirmed'
	} else {
		$Infra.DomainJoinType
	}

	$entraAuthEnabled = $allSettings.ContainsKey('enablerdsaadauth')  -and $allSettings['enablerdsaadauth'] -eq 1
	$targetAadJoined  = $allSettings.ContainsKey('targetisaadjoined') -and $allSettings['targetisaadjoined'] -eq 1
	$credSspEnabled   = if ($allSettings.ContainsKey('enablecredsspsupport')) { $allSettings['enablecredsspsupport'] -eq 1 } else { $null }

	$blockers   = [System.Collections.Generic.List[string]]::new()
	$advisories = [System.Collections.Generic.List[string]]::new()
	$notes      = [System.Collections.Generic.List[string]]::new()

	$ssoType = switch ($joinType) {
		'EntraID' {
			if (-not $entraAuthEnabled) {
				$blockers.Add('enablerdsaadauth:i:1 not set in RDP properties — Entra SSO will not function') | Out-Null
			}
			if (-not $targetAadJoined) {
				$advisories.Add('targetisaadjoined:i:1 not set in RDP properties — recommended for Entra ID joined hosts') | Out-Null
			}
			'EntraID'
		}
		'HybridEntraID' {
			if (-not $entraAuthEnabled) {
				$blockers.Add('enablerdsaadauth:i:1 not set in RDP properties — Entra SSO will not function') | Out-Null
			}
			# Check Cloud Kerberos Trust — required for password-less / MFA-capable Hybrid SSO
			if ($null -eq $CloudKerberosTrust -or $CloudKerberosTrust.Status -eq 'GraphCallFailed') {
				$advisories.Add('Cloud Kerberos Trust status could not be determined (Graph Beta call failed) — verify Set-AzureADKerberosServer has been run against the on-premises AD') | Out-Null
			} elseif ($CloudKerberosTrust.Configured -eq $true) {
				$notes.Add("Cloud Kerberos Trust configured$(if ($CloudKerberosTrust.ServiceAccount) { " (service account: $($CloudKerberosTrust.ServiceAccount))" })") | Out-Null
			} else {
				$blockers.Add('Cloud Kerberos Trust is not configured in this tenant — Hybrid Entra SSO requires Set-AzureADKerberosServer to be run against the on-premises AD, or certificate-based SSO configured as an alternative') | Out-Null
			}
			$notes.Add('Hybrid Entra joined (confirmed via Graph trustType=ServerAD)') | Out-Null
			'HybridEntraID'
		}
		'ActiveDirectory' {
			if ($entraAuthEnabled) {
				$advisories.Add('enablerdsaadauth:i:1 is set but Graph confirms hosts are pure AD joined — this property has no effect') | Out-Null
			}
			$notes.Add('Pure Active Directory joined (confirmed via Graph) — Entra ID SSO is not available; users authenticate via Kerberos') | Out-Null
			'LegacyKerberos'
		}
		'ActiveDirectoryUnconfirmed' {
			if ($entraAuthEnabled) {
				$notes.Add('enablerdsaadauth:i:1 is set and AD extension is present — hosts may be Hybrid Entra joined but Graph token was unavailable to confirm') | Out-Null
			} else {
				$notes.Add('AD extension present, no Graph token available — cannot confirm whether Hybrid Entra joined') | Out-Null
			}
			'ActiveDirectoryUnconfirmed'
		}
		default {
			$notes.Add('VM join type could not be determined — SSO configuration could not be fully assessed') | Out-Null
			'Unknown'
		}
	}

	[PSCustomObject]@{
		SsoEnabled            = ($blockers.Count -eq 0) -and ($ssoType -notin @('LegacyKerberos', 'ActiveDirectoryUnconfirmed', 'Unknown'))
		SsoType               = $ssoType
		DetectedJoinType      = $joinType
		GraphQueried          = $graphQueried
		GraphDevicesFound     = @($graphDevices).Count
		GraphTrustTypes       = $distinctTrustTypes
		CloudKerberosTrust    = $CloudKerberosTrust
		EntraAuthRdpEnabled   = $entraAuthEnabled
		TargetIsAadJoined     = $targetAadJoined
		CredSspSupportEnabled = $credSspEnabled
		Blockers              = @($blockers)
		Advisories            = @($advisories)
		Notes                 = @($notes)
	}
}

# ------------------------------------------------------------------
# Infrastructure info
# ------------------------------------------------------------------

function Get-HostPoolInfraInfo {
	<#
	.SYNOPSIS
	Returns host count, VM SKU, and scaling plan details for a host pool.
	#>
	param(
		[Parameter(Mandatory = $true)]
		[PSCustomObject]$HostPool
	)

	$result = [PSCustomObject]@{
		HostCount          = $null
		HostsRunning       = $null
		VmNamePrefix       = $null
		VmSkus             = $null
		VmSkusStatus       = $null
		VmPriorities       = $null
		VmSecurityTypes    = $null
		AvailabilityZones  = $null
		EphemeralOsDisk    = $null
		AcceleratedNetworking = $null
		VmResourceIds      = @()
		VmSizeMap          = @{}
		DomainJoinType     = $null
		DomainName         = $null
		VmExtensions       = @()
		ImageReferences    = @()
		OsDiskSizeGb       = @()
		OsDiskSkus         = @()
		NetworkInfo        = @()
		ScalingPlan        = $null
		SessionHostDetails = @()
	}

	# --- Host count and VM SKUs via direct ARM queries ---
	try {
		$shPath     = "$($HostPool.ResourceId)/sessionHosts?api-version=2023-09-05"
		$shResponse = Invoke-ArmRequest -Path $shPath -Method GET -ErrorAction Stop

		if ($shResponse.StatusCode -eq 200) {
			$sessionHosts     = ($shResponse.Content | ConvertFrom-Json).value
			$result.HostCount = @($sessionHosts).Count

			$vmIds = @($sessionHosts | ForEach-Object {
				$rid = $_.properties.resourceId
				if (-not [string]::IsNullOrEmpty($rid)) { $rid }
			})

			$result.VmResourceIds = @($vmIds)

			# Compute the common VM name prefix from all host resource IDs
			$vmNames = @($vmIds | ForEach-Object { ($_ -split '/')[-1] })
			if ($vmNames.Count -gt 0) {
				$pfx = $vmNames[0]
				foreach ($vn in $vmNames) {
					while ($vn.Length -lt $pfx.Length -or -not $vn.StartsWith($pfx, [System.StringComparison]::OrdinalIgnoreCase)) {
						if ($pfx.Length -le 1) { $pfx = ''; break }
						$pfx = $pfx.Substring(0, $pfx.Length - 1)
					}
					if ($pfx.Length -eq 0) { break }
				}
				$result.VmNamePrefix = if ($pfx.Length -gt 0) { $pfx.TrimEnd('-', '_', ' ', '.') } else { $null }
			}

			# Extract per-session-host operational details
			$result.SessionHostDetails = @($sessionHosts | ForEach-Object {
				$shProps = $_.properties
				$shName  = ($_.name -split '/')[-1]  # e.g. "hp-name/host.domain.com" → "host.domain.com"
				[PSCustomObject]@{
					Name             = $shName
					Status           = if ($shProps.PSObject.Properties['status'])          { $shProps.status }          else { $null }
					Sessions         = if ($shProps.PSObject.Properties['sessions'])         { $shProps.sessions }         else { $null }
					AgentVersion     = if ($shProps.PSObject.Properties['agentVersion'])     { $shProps.agentVersion }     else { $null }
					LastHeartBeat    = if ($shProps.PSObject.Properties['lastHeartBeat'])    { $shProps.lastHeartBeat }    else { $null }
					AllowNewSession  = if ($shProps.PSObject.Properties['allowNewSession'])  { $shProps.allowNewSession }  else { $null }
					AssignedUser     = if ($shProps.PSObject.Properties['assignedUser'])     { $shProps.assignedUser }     else { $null }
					UpdateState      = if ($shProps.PSObject.Properties['updateState'])      { $shProps.updateState }      else { $null }
					OsVersion        = if ($shProps.PSObject.Properties['osVersion'])        { $shProps.osVersion }        else { $null }
				}
			})

			if ($vmIds.Count -eq 0) {
				$result.VmSkusStatus = 'NoVmResourceIds'
			}
			else {
				$vmSizeMap      = @{}
				$vmPriorities   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
				$vmSecurityTypes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
				$vmZones        = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
				$hasEphemeral   = $false
				$accelNetValues = [System.Collections.Generic.HashSet[bool]]::new()
				$imgRefKeys          = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
				$imgRefList          = [System.Collections.Generic.List[PSCustomObject]]::new()
				$galVerCountCache    = @{}  # imageDefinitionResourceId -> version count
				$osDiskSizes    = [System.Collections.Generic.HashSet[int]]::new()
				$osDiskSkus     = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
				$extKeys        = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
				$extList        = [System.Collections.Generic.List[PSCustomObject]]::new()
				$adDomainExt    = $false
				$entraExt       = $false
				$adDomainNames  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
				$vmIpMap        = @{}  # vmName (lower) -> private IP address
				$vmPublicIpMap  = @{}  # vmName (lower) -> public IP address (null if no PIP associated)
				$vmSubnetIdMap  = @{}  # vmName (lower) -> subnetResourceId
				$natGwCache     = @{}  # natGwResourceId (lower) -> @(public IPs)
				$firewallCache  = $null  # lazy-loaded list of Azure Firewalls in the subscription
				$subnetOutboundCache = @{}  # subnetId (lower) -> @(outbound public IPs)

				# Helper: given an NSG resource ID, return {Name, CustomRules} — default Azure rules excluded
				$nsgCache = @{}
				$getNsgInfo = {
					param([string]$NsgId)
					if ([string]::IsNullOrEmpty($NsgId)) { return $null }
					$nsgKey = $NsgId.ToLower()
					if ($nsgCache.ContainsKey($nsgKey)) { return $nsgCache[$nsgKey] }
					$info = $null
					try {
						$nsgResp = Invoke-ArmRequest -Path "$NsgId`?api-version=2023-09-01" -Method GET -ErrorAction SilentlyContinue
						if ($nsgResp -and $nsgResp.StatusCode -eq 200) {
							$nsgProps = ($nsgResp.Content | ConvertFrom-Json).properties
							# securityRules = custom only; defaultSecurityRules = Azure built-ins (excluded)
							$customRules = @($nsgProps.securityRules | ForEach-Object {
								$rp = $_.properties
								[PSCustomObject]@{
									Name                     = $_.name
									Priority                 = [int]$rp.priority
									Direction                = $rp.direction
									Access                   = $rp.access
									Protocol                 = $rp.protocol
									SourceAddressPrefix      = $rp.sourceAddressPrefix
									SourcePortRange          = $rp.sourcePortRange
									DestinationAddressPrefix = $rp.destinationAddressPrefix
									DestinationPortRange     = $rp.destinationPortRange
								}
							} | Sort-Object Direction, Priority)
							$info = [PSCustomObject]@{
								Name        = ($NsgId -split '/')[-1]
								CustomRules = $customRules
							}
						}
					} catch {}
					$nsgCache[$nsgKey] = $info
					return $info
				}
				$vnetCache      = @{}
				$netInfoKeys    = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
				$netInfoList    = [System.Collections.Generic.List[PSCustomObject]]::new()

				$allSkus = foreach ($vmId in $vmIds) {
					$vmPath = "${vmId}?`$expand=instanceView&api-version=2024-03-01"
					$vmResp = Invoke-ArmRequest -Path $vmPath -Method GET -ErrorAction SilentlyContinue
					if ($vmResp -and $vmResp.StatusCode -eq 200) {
						$vmData = $vmResp.Content | ConvertFrom-Json
						$vmProp = $vmData.properties

						# VM priority (Regular / Spot)
						$priority = if ($vmProp.PSObject.Properties['priority'] -and -not [string]::IsNullOrEmpty($vmProp.priority)) { $vmProp.priority } else { 'Regular' }
						$vmPriorities.Add($priority) | Out-Null

						# VM security type (Standard / TrustedLaunch / ConfidentialVM)
						$secType = if ($vmProp.PSObject.Properties['securityProfile'] -and $vmProp.securityProfile -and
						               $vmProp.securityProfile.PSObject.Properties['securityType'] -and
						               -not [string]::IsNullOrEmpty($vmProp.securityProfile.securityType)) {
							$vmProp.securityProfile.securityType
						} else { 'Standard' }
						$vmSecurityTypes.Add($secType) | Out-Null

						# Availability zones
						if ($vmData.PSObject.Properties['zones'] -and $vmData.zones) {
							foreach ($z in @($vmData.zones)) { $vmZones.Add([string]$z) | Out-Null }
						}

						# VM size
						$size = $vmProp.hardwareProfile.vmSize
						if (-not [string]::IsNullOrEmpty($size)) {
							$vmSizeMap[$vmId.ToLowerInvariant()] = $size
						}

						# Extensions — separate sub-resource call; $expand=extensions is not supported
						# on the Compute VM GET endpoint (only instanceView/userData are valid expand values)
						$extResp = Invoke-ArmRequest -Path "${vmId}/extensions?api-version=2024-03-01" -Method GET -ErrorAction SilentlyContinue
						if ($extResp -and $extResp.StatusCode -eq 200) {
							$extItems = ($extResp.Content | ConvertFrom-Json).value
							foreach ($ext in $extItems) {
								# ARM extension list items have the actual type/publisher under .properties,
								# not at the top level (.type is always "Microsoft.Compute/virtualMachines/extensions")
								$extProps = if ($ext.PSObject.Properties['properties']) { $ext.properties } else { $null }
								if (-not $extProps) { continue }
								$extType = if ($extProps.PSObject.Properties['type'] -and -not [string]::IsNullOrEmpty($extProps.type)) { $extProps.type } else { $null }
								if (-not $extType) { continue }
								$extPub = if ($extProps.PSObject.Properties['publisher']) { $extProps.publisher } else { $null }
								$extKey = "$extType|$extPub"
								if ($extKeys.Add($extKey)) {
									$extList.Add([PSCustomObject]@{ Type = $extType; Publisher = $extPub })
								}
								# JsonADDomainExtension → AD join; domain name is in properties.settings.Name
								if ($extType -eq 'JsonADDomainExtension') {
									$adDomainExt = $true
									$extSettings = if ($extProps.PSObject.Properties['settings']) { $extProps.settings } else { $null }
									if ($extSettings -and $extSettings.PSObject.Properties['Name'] -and
									    -not [string]::IsNullOrEmpty($extSettings.Name)) {
										$adDomainNames.Add($extSettings.Name) | Out-Null
									}
								}
								# AADLoginForWindows / AADLoginForWindowsWithIntune → Entra ID join
								if ($extType -in @('AADLoginForWindows', 'AADLoginForWindowsWithIntune')) {
									$entraExt = $true
								}
							}
						}

						# Source image reference
						if ($vmProp.PSObject.Properties['storageProfile'] -and
						    $vmProp.storageProfile.PSObject.Properties['imageReference']) {
							$ir   = $vmProp.storageProfile.imageReference
							$irId = if ($ir.PSObject.Properties['id'] -and -not [string]::IsNullOrEmpty($ir.id)) { $ir.id } else { $null }
							if ($irId) {
								# Shared / community image gallery
								$parts  = $irId -split '/'
								$galIdx = [Array]::IndexOf([string[]]$parts, 'galleries')
								$imgIdx = [Array]::IndexOf([string[]]$parts, 'images')
								$verIdx = [Array]::IndexOf([string[]]$parts, 'versions')

								# Count all versions of this image definition in the gallery (cached per definition)
								$galVerCount = $null
								if ($verIdx -ge 2) {
									$versionsPath = ($parts[0..($verIdx - 1)] -join '/') + '/versions?api-version=2023-07-03'
									$imgDefId     = ($parts[0..($verIdx - 1)] -join '/').ToLower()
									if ($galVerCountCache.ContainsKey($imgDefId)) {
										$galVerCount = $galVerCountCache[$imgDefId]
									} else {
										try {
											$verListResp = Invoke-ArmRequest -Path $versionsPath -Method GET -ErrorAction SilentlyContinue
											if ($verListResp -and $verListResp.StatusCode -eq 200) {
												$galVerCount = @(($verListResp.Content | ConvertFrom-Json).value).Count
											}
										} catch {}
										$galVerCountCache[$imgDefId] = $galVerCount
									}
								}

								$irObj  = [PSCustomObject]@{
									Type                   = 'SharedImageGallery'
									GalleryName            = if ($galIdx -ge 0 -and ($galIdx + 1) -lt $parts.Count) { $parts[$galIdx + 1] } else { $null }
									ImageDefinition        = if ($imgIdx -ge 0 -and ($imgIdx + 1) -lt $parts.Count) { $parts[$imgIdx + 1] } else { $null }
									VersionInUse           = if ($verIdx -ge 0 -and ($verIdx + 1) -lt $parts.Count) { $parts[$verIdx + 1] } else { $null }
									TotalVersionsInGallery = $galVerCount
								}
							}
							else {
								$irObj = [PSCustomObject]@{
									Type         = 'Marketplace'
									Publisher    = if ($ir.PSObject.Properties['publisher'])    { $ir.publisher }    else { $null }
									Offer        = if ($ir.PSObject.Properties['offer'])        { $ir.offer }        else { $null }
									Sku          = if ($ir.PSObject.Properties['sku'])          { $ir.sku }          else { $null }
									ExactVersion = if ($ir.PSObject.Properties['exactVersion'] -and -not [string]::IsNullOrEmpty($ir.exactVersion)) {
									                   $ir.exactVersion
									               } elseif ($ir.PSObject.Properties['version']) { $ir.version } else { $null }
								}
							}
							$irKey = $irObj | ConvertTo-Json -Compress -Depth 2
							if ($imgRefKeys.Add($irKey)) { $imgRefList.Add($irObj) }
						}

						# OS disk
						if ($vmProp.PSObject.Properties['storageProfile'] -and
						    $vmProp.storageProfile.PSObject.Properties['osDisk']) {
							$od = $vmProp.storageProfile.osDisk
							if ($od.PSObject.Properties['diskSizeGB'] -and $null -ne $od.diskSizeGB) {
								$osDiskSizes.Add([int]$od.diskSizeGB) | Out-Null
							}
							if ($od.PSObject.Properties['managedDisk'] -and $od.managedDisk -and
							    $od.managedDisk.PSObject.Properties['storageAccountType'] -and
							    -not [string]::IsNullOrEmpty($od.managedDisk.storageAccountType)) {
								$osDiskSkus.Add($od.managedDisk.storageAccountType) | Out-Null
							}
							# Ephemeral OS disk
							if ($od.PSObject.Properties['diffDiskSettings'] -and $od.diffDiskSettings -and
							    $od.diffDiskSettings.PSObject.Properties['option'] -and
							    -not [string]::IsNullOrEmpty($od.diffDiskSettings.option)) {
								$hasEphemeral = $true
							}
						}

						# Network — primary NIC → subnet → VNet
						if ($vmProp.PSObject.Properties['networkProfile'] -and
						    $vmProp.networkProfile.PSObject.Properties['networkInterfaces']) {
							$nicRef = @($vmProp.networkProfile.networkInterfaces) | Select-Object -First 1
							if ($nicRef -and $nicRef.PSObject.Properties['id'] -and -not [string]::IsNullOrEmpty($nicRef.id)) {
								$nicResp = Invoke-ArmRequest -Path "$($nicRef.id)?api-version=2023-11-01" -Method GET -ErrorAction SilentlyContinue
								if ($nicResp -and $nicResp.StatusCode -eq 200) {
									$nicProps = ($nicResp.Content | ConvertFrom-Json).properties
									# NIC-level NSG
									$nicNsg = if ($nicProps.PSObject.Properties['networkSecurityGroup'] -and $nicProps.networkSecurityGroup -and
									              $nicProps.networkSecurityGroup.PSObject.Properties['id']) {
										& $getNsgInfo -NsgId $nicProps.networkSecurityGroup.id
									} else { $null }
									# Accelerated networking
									if ($nicProps.PSObject.Properties['enableAcceleratedNetworking']) {
										$accelNetValues.Add([bool]$nicProps.enableAcceleratedNetworking) | Out-Null
									}
									# Subnet from first IP config
									$subnetId = $null
									if ($nicProps.PSObject.Properties['ipConfigurations'] -and @($nicProps.ipConfigurations).Count -gt 0) {
										$ipCfg = @($nicProps.ipConfigurations) | Select-Object -First 1
										if ($ipCfg.PSObject.Properties['properties'] -and
										    $ipCfg.properties.PSObject.Properties['subnet'] -and
										    $ipCfg.properties.subnet.PSObject.Properties['id']) {
											$subnetId = $ipCfg.properties.subnet.id
										# Map vm -> subnetId for outbound IP lookup in SessionHostDetails
										$vmName = ($vmId -split '/')[-1]
										$vmSubnetIdMap[$vmName.ToLower()] = $subnetId.ToLower()
										}
										# Capture private IP and map to VM name for SessionHostDetails enrichment
										if ($ipCfg.PSObject.Properties['properties'] -and
										    $ipCfg.properties.PSObject.Properties['privateIPAddress'] -and
										    -not [string]::IsNullOrEmpty($ipCfg.properties.privateIPAddress)) {
											$vmName = ($vmId -split '/')[-1]
											$vmIpMap[$vmName.ToLower()] = $ipCfg.properties.privateIPAddress
										}
									}
									if (-not [string]::IsNullOrEmpty($subnetId)) {
										# Parse names from the subnet resource ID
										$sparts     = [string[]]($subnetId -split '/')
										$rgIdx2     = [Array]::IndexOf($sparts, 'resourceGroups')
										$vnetIdx    = [Array]::IndexOf($sparts, 'virtualNetworks')
										$snIdx      = [Array]::IndexOf($sparts, 'subnets')
										$vnetRg2    = if ($rgIdx2 -ge 0 -and ($rgIdx2 + 1) -lt $sparts.Count)  { $sparts[$rgIdx2 + 1]  } else { $null }
										$vnetName   = if ($vnetIdx -ge 0 -and ($vnetIdx + 1) -lt $sparts.Count) { $sparts[$vnetIdx + 1] } else { $null }
										$subnetName = if ($snIdx   -ge 0 -and ($snIdx   + 1) -lt $sparts.Count) { $sparts[$snIdx   + 1] } else { $null }
										$vnetId     = $subnetId -replace '/subnets/[^/]+$', ''
										# VNet lookup (cached per run)
										$vnetKey = $vnetId.ToLowerInvariant()
										if (-not $vnetCache.ContainsKey($vnetKey)) {
											$vnetResp = Invoke-ArmRequest -Path "${vnetId}?api-version=2023-11-01" -Method GET -ErrorAction SilentlyContinue
											$vnetCache[$vnetKey] = if ($vnetResp -and $vnetResp.StatusCode -eq 200) { $vnetResp.Content | ConvertFrom-Json } else { $null }
										}
										$vnetData         = $vnetCache[$vnetKey]
										$dnsServers       = @()
										$vnetPrefixes     = @()
										$subnetPrefix     = $null
										$subnetNsg        = $null
										$subnetRouteTable = $null
										if ($vnetData) {
											$vp = $vnetData.properties
											if ($vp.PSObject.Properties['dhcpOptions'] -and $vp.dhcpOptions.PSObject.Properties['dnsServers']) {
												$dnsServers = @($vp.dhcpOptions.dnsServers)
											}
											if ($vp.PSObject.Properties['addressSpace'] -and $vp.addressSpace.PSObject.Properties['addressPrefixes']) {
												$vnetPrefixes = @($vp.addressSpace.addressPrefixes)
											}
											if ($vp.PSObject.Properties['subnets']) {
												$sn = $vp.subnets | Where-Object { $_.name -ieq $subnetName } | Select-Object -First 1
												if ($sn) {
													$sp = $sn.properties
													$subnetPrefix = if ($sp.PSObject.Properties['addressPrefix']) { $sp.addressPrefix } else { $null }
													$subnetNsg    = if ($sp.PSObject.Properties['networkSecurityGroup'] -and $sp.networkSecurityGroup -and
													                     $sp.networkSecurityGroup.PSObject.Properties['id']) {
														& $getNsgInfo -NsgId $sp.networkSecurityGroup.id } else { $null }
													if ($sp.PSObject.Properties['routeTable'] -and $sp.routeTable -and
													    $sp.routeTable.PSObject.Properties['id']) {
														$rtId   = $sp.routeTable.id
														$rtName = ($rtId -split '/')[-1]
														$rtRoutes = $null
														try {
															$rtResp = Invoke-ArmRequest -Path "$rtId`?api-version=2023-09-01" -Method GET -ErrorAction SilentlyContinue
															if ($rtResp -and $rtResp.StatusCode -eq 200) {
																$rtProps = ($rtResp.Content | ConvertFrom-Json).properties
																$rtRoutes = @($rtProps.routes | ForEach-Object {
																	$rp = $_.properties
																	[PSCustomObject]@{
																		Name             = $_.name
																		AddressPrefix    = $rp.addressPrefix
																		NextHopType      = $rp.nextHopType
																		NextHopIpAddress = if ($rp.PSObject.Properties['nextHopIpAddress']) { $rp.nextHopIpAddress } else { $null }
																	}
																} | Sort-Object AddressPrefix)
															}
														} catch {}
														$subnetRouteTable = [PSCustomObject]@{
															Name   = $rtName
															Routes = $rtRoutes
														}
													}
												}
											}

											# Resolve outbound public IP: NAT Gateway takes priority, then Azure Firewall via default route
											$outboundPublicIps = @()
											$snCacheKey = $subnetId.ToLower()
											if ($subnetOutboundCache.ContainsKey($snCacheKey)) {
												$outboundPublicIps = $subnetOutboundCache[$snCacheKey]
											} else {
												# 1. NAT Gateway on the subnet
												if ($sp.PSObject.Properties['natGateway'] -and $sp.natGateway -and
												    $sp.natGateway.PSObject.Properties['id']) {
													$ngId  = $sp.natGateway.id
													$ngKey = $ngId.ToLower()
													if (-not $natGwCache.ContainsKey($ngKey)) {
														try {
															$ngResp = Invoke-ArmRequest -Path "$ngId`?api-version=2023-09-01" -Method GET -ErrorAction SilentlyContinue
															if ($ngResp -and $ngResp.StatusCode -eq 200) {
																$ngProps = ($ngResp.Content | ConvertFrom-Json).properties
																$natGwCache[$ngKey] = @($ngProps.publicIpAddresses | ForEach-Object {
																	try {
																		$pR = Invoke-ArmRequest -Path "$($_.id)?api-version=2023-09-01" -Method GET -ErrorAction SilentlyContinue
																		if ($pR -and $pR.StatusCode -eq 200) { ($pR.Content | ConvertFrom-Json).properties.ipAddress }
																	} catch {}
																} | Where-Object { -not [string]::IsNullOrEmpty($_) })
															} else { $natGwCache[$ngKey] = @() }
														} catch { $natGwCache[$ngKey] = @() }
													}
													$outboundPublicIps = $natGwCache[$ngKey]
												}
												# 2. Azure Firewall — match by default route next-hop IP
												if ($outboundPublicIps.Count -eq 0 -and $subnetRouteTable -and $subnetRouteTable.Routes) {
													$defRoute = $subnetRouteTable.Routes | Where-Object {
														$_.AddressPrefix -eq '0.0.0.0/0' -and $_.NextHopType -eq 'VirtualAppliance' -and
														-not [string]::IsNullOrEmpty($_.NextHopIpAddress)
													} | Select-Object -First 1
													if ($defRoute) {
														# Lazy-load firewall list for this subscription
														if ($null -eq $firewallCache) {
															try {
																$fwListR = Invoke-ArmRequest -Path "/subscriptions/$($pool.SubscriptionId)/providers/Microsoft.Network/azureFirewalls?api-version=2023-09-01" -Method GET -ErrorAction SilentlyContinue
																$firewallCache = if ($fwListR -and $fwListR.StatusCode -eq 200) { @(($fwListR.Content | ConvertFrom-Json).value) } else { @() }
															} catch { $firewallCache = @() }
														}
														$matchedFw = $firewallCache | Where-Object {
															$fwP = $_.properties
															$fwP.PSObject.Properties['ipConfigurations'] -and
															(@($fwP.ipConfigurations) | Where-Object {
																$_.PSObject.Properties['properties'] -and
																$_.properties.PSObject.Properties['privateIPAddress'] -and
																$_.properties.privateIPAddress -eq $defRoute.NextHopIpAddress
															}).Count -gt 0
														} | Select-Object -First 1
														if ($matchedFw) {
															$outboundPublicIps = @($matchedFw.properties.ipConfigurations | Where-Object {
																$_.PSObject.Properties['properties'] -and
																$_.properties.PSObject.Properties['publicIPAddress'] -and
																$_.properties.publicIPAddress
															} | ForEach-Object {
																try {
																	$pR = Invoke-ArmRequest -Path "$($_.properties.publicIPAddress.id)?api-version=2023-09-01" -Method GET -ErrorAction SilentlyContinue
																	if ($pR -and $pR.StatusCode -eq 200) { ($pR.Content | ConvertFrom-Json).properties.ipAddress }
																} catch {}
															} | Where-Object { -not [string]::IsNullOrEmpty($_) })
														}
													}
												}
												$subnetOutboundCache[$snCacheKey] = $outboundPublicIps
											}
										}
										$netKey = "$vnetName|$subnetName"
										if ($netInfoKeys.Add($netKey)) {
											$netInfoList.Add([PSCustomObject]@{
												VNetName              = $vnetName
												VNetResourceGroup     = $vnetRg2
												VNetAddressPrefixes   = $vnetPrefixes
												VNetCustomDnsServers  = $dnsServers
												SubnetName            = $subnetName
												SubnetAddressPrefix   = $subnetPrefix
												SubnetNsg             = $subnetNsg
												SubnetRouteTable      = $subnetRouteTable
												OutboundPublicIps     = $outboundPublicIps
												NicNsg                = $nicNsg
											})
										}
									}
								}
							}
						}

						$size
					}
				}

				$result.VmSizeMap       = $vmSizeMap
				$result.HostsRunning    = @($result.SessionHostDetails | Where-Object { $_.Status -and $_.Status -ne 'Shutdown' }).Count
				$result.VmPriorities    = @($vmPriorities)
				$result.VmSecurityTypes = @($vmSecurityTypes)
				$result.AvailabilityZones = if ($vmZones.Count -gt 0) { @($vmZones | Sort-Object) } else { $null }
				$result.EphemeralOsDisk = $hasEphemeral
				$result.AcceleratedNetworking = if ($accelNetValues.Count -gt 0) {
					# All true → true, all false → false, mixed → 'Mixed'
					$distinct = @($accelNetValues | Select-Object -Unique)
					if ($distinct.Count -eq 1) { $distinct[0] } else { 'Mixed' }
				} else { $null }
				$result.VmExtensions    = @($extList | Sort-Object Type)
				$result.ImageReferences = @($imgRefList)
				$result.OsDiskSizeGb    = @($osDiskSizes | Sort-Object)
				$result.OsDiskSkus      = @($osDiskSkus)
				$result.NetworkInfo     = @($netInfoList)

				# Enrich SessionHostDetails with private/public IPs — match by short hostname (first segment of FQDN)
				$result.SessionHostDetails = @($result.SessionHostDetails | ForEach-Object {
					$shortName   = ($_.Name -split '\.')[0].ToLower()
					$ip          = $vmIpMap[$shortName]
					$publicIp    = $vmPublicIpMap[$shortName]
					$snId        = $vmSubnetIdMap[$shortName]
					$outboundIps = if ($snId) { $subnetOutboundCache[$snId.ToLower()] } else { $null }
					$outboundIp  = if ($outboundIps -and @($outboundIps).Count -gt 0) { (@($outboundIps))[0] } else { $null }
					$_ | Select-Object -Property @(
						@{ Name = 'Name';                   Expression = { $_.Name } }
						@{ Name = 'IpAddress';              Expression = { $ip } }
						@{ Name = 'PublicIpAddress';        Expression = { $publicIp } }
						@{ Name = 'OutboundPublicIpAddress'; Expression = { $outboundIp } }
						@{ Name = 'Status';                 Expression = { $_.Status } }
						@{ Name = 'Sessions';               Expression = { $_.Sessions } }
						@{ Name = 'AgentVersion';           Expression = { $_.AgentVersion } }
						@{ Name = 'LastHeartBeat';          Expression = { $_.LastHeartBeat } }
						@{ Name = 'AllowNewSession';        Expression = { $_.AllowNewSession } }
						@{ Name = 'AssignedUser';           Expression = { $_.AssignedUser } }
						@{ Name = 'UpdateState';            Expression = { $_.UpdateState } }
						@{ Name = 'OsVersion';              Expression = { $_.OsVersion } }
					)
				})

				# Domain join type derived from VM extensions — more reliable than session host domainName property
				$result.DomainJoinType = if     ($adDomainExt) { 'ActiveDirectory' }
				                          elseif ($entraExt)    { 'EntraID' }
				                          else                  { 'Unknown' }
				$result.DomainName     = if ($adDomainNames.Count -gt 0) { ($adDomainNames | Sort-Object) -join ', ' } else { $null }

				$distinctSkus = @($allSkus | Where-Object { -not [string]::IsNullOrEmpty($_) } | Select-Object -Unique)

				if ($distinctSkus.Count -gt 0) {
					$result.VmSkus       = $distinctSkus
					$result.VmSkusStatus = 'OK'
				}
				else {
					$result.VmSkusStatus = 'NoSkuDataReturned'
				}
			}
		}
		else {
			$result.VmSkusStatus = "SessionHostsError: HTTP $($shResponse.StatusCode)"
		}
	}
	catch {
		$result.VmSkusStatus = "Error: $($_.Exception.Message)"
	}

	# --- Scaling plan association ---
	try {
		$spPath     = "/subscriptions/$($HostPool.SubscriptionId)/providers/Microsoft.DesktopVirtualization/scalingPlans?api-version=2023-09-05"
		$spResponse = Invoke-ArmRequest -Path $spPath -Method GET -ErrorAction Stop

		if ($spResponse.StatusCode -eq 200) {
			$allPlans    = ($spResponse.Content | ConvertFrom-Json).value
			$matchedPlan = $allPlans | Where-Object {
				$_.properties.hostPoolAssociations | Where-Object {
					$_.hostPoolArmPath -eq $HostPool.ResourceId
				}
			} | Select-Object -First 1

			if ($matchedPlan) {
				$assoc = $matchedPlan.properties.hostPoolAssociations | Where-Object {
					$_.hostPoolArmPath -eq $HostPool.ResourceId
				} | Select-Object -First 1

				$result.ScalingPlan = [PSCustomObject]@{
					Name              = $matchedPlan.name
					ResourceId        = $matchedPlan.id
					Enabled           = $assoc.scalingPlanEnabled
					ScheduleCount     = @($matchedPlan.properties.schedules).Count
				}
			}
		}
	}
	catch { <# Non-fatal — leave field null #> }

	return $result
}

# ------------------------------------------------------------------
# Reservation matching (best-effort / heuristic)
# ------------------------------------------------------------------

function Get-ReservationMatches {
	<#
	.SYNOPSIS
	Returns reservations whose SKU and region match the host pool's VM sizes.
	This is a heuristic match only — Azure does not expose a direct VM-to-reservation
	binding. A match means "there is a reservation that could be covering these VMs",
	not that it definitely is.
	#>
	param(
		[Parameter(Mandatory = $true)]
		[string[]]$VmSkus,

		[Parameter(Mandatory = $true)]
		[string]$Location,

		# Pre-fetched reservation list (tenant-scoped, shared across all pools)
		[Parameter(Mandatory = $true)]
		[AllowNull()]
		[AllowEmptyCollection()]
		[object[]]$AllReservations
	)

	if ($null -eq $AllReservations) {
		return [PSCustomObject]@{
			MatchedReservations     = @()
			ReservationMatchStatus  = 'Unavailable'
		}
	}

	# Normalise location — ARM uses compact form e.g. "uksouth", reservations use same
	$locNorm = $Location.ToLowerInvariant() -replace '\s', ''

	$matches_ = foreach ($res in $AllReservations) {
		$rp = $res.properties
		# Only Virtual Machine reservations
		if ($rp.PSObject.Properties['reservedResourceType'] -and
		    $rp.reservedResourceType -ne 'VirtualMachines') { continue }

		# Location filter (reservation location is in properties.location)
		$resLoc = if ($rp.PSObject.Properties['location']) { $rp.location.ToLowerInvariant() -replace '\s', '' }
		          elseif ($res.PSObject.Properties['location']) { $res.location.ToLowerInvariant() -replace '\s', '' }
		          else { $null }
		if ($resLoc -and $resLoc -ne $locNorm) { continue }

		# SKU filter
		$resSku = if ($rp.PSObject.Properties['sku'] -and $rp.sku.PSObject.Properties['name']) { $rp.sku.name }
		          elseif ($res.PSObject.Properties['sku'] -and $res.sku.PSObject.Properties['name']) { $res.sku.name }
		          else { $null }
		if ([string]::IsNullOrEmpty($resSku)) { continue }

		# ARM reservation SKUs omit the "Standard_" prefix — normalise both sides for comparison
		$resSkuNorm = $resSku -replace '^Standard_', ''
		$isMatch = $VmSkus | Where-Object { ($_ -replace '^Standard_', '') -ieq $resSkuNorm }
		if (-not $isMatch) { continue }

		$expiryOn  = if ($rp.PSObject.Properties['expiryDate'])  { $rp.expiryDate  } else { $null }
		$scope     = if ($rp.PSObject.Properties['appliedScopes']) { @($rp.appliedScopes) -join ', ' } else { 'Shared' }
		$flex      = if ($rp.PSObject.Properties['instanceFlexibility']) { $rp.instanceFlexibility } else { $null }
		$term      = if ($rp.PSObject.Properties['term']) { $rp.term } else { $null }
		$qty       = if ($rp.PSObject.Properties['quantity']) { $rp.quantity } else { $null }

		[PSCustomObject]@{
			ReservationName        = $res.name
			ReservationId          = $res.id
			MatchedSku             = $resSku
			Scope                  = $scope
			QuantityReserved       = $qty
			Term                   = $term
			ExpiryDate             = $expiryOn
			InstanceFlexibility    = $flex
		}
	}

	$matchList = @($matches_ | Where-Object { $_ -ne $null })

	return [PSCustomObject]@{
		MatchedReservations    = $matchList
		ReservationMatchStatus = if ($matchList.Count -gt 0) { 'SkuAndRegionMatch' } else { 'NoMatch' }
	}
}

# ------------------------------------------------------------------
# Backup coverage (Personal pools only)
# ------------------------------------------------------------------

function Get-HostPoolBackupInfo {
	<#
	.SYNOPSIS
	For each VM in a Personal host pool, checks whether it is protected by an
	Azure Backup Recovery Services Vault in the same subscription.
	#>
	param(
		[Parameter(Mandatory = $true)]
		[string]$SubscriptionId,

		[Parameter(Mandatory = $true)]
		[AllowEmptyCollection()]
		[string[]]$VmResourceIds,

		# Vault list cache — keyed by subscriptionId, populated on first call
		[Parameter(Mandatory = $true)]
		[hashtable]$VaultCache
	)

	if (@($VmResourceIds).Count -eq 0) {
		return [PSCustomObject]@{ BackupInfo = @(); BackupInfoStatus = 'NoHosts' }
	}

	# Build fast-lookup of VM resource ID -> VM name (case-insensitive)
	$vmLookup = @{}
	foreach ($rid in $VmResourceIds) { $vmLookup[$rid.ToLowerInvariant()] = ($rid -split '/')[-1] }

	# Fetch and cache vault list once per subscription
	if (-not $VaultCache.ContainsKey($SubscriptionId)) {
		$vResp = Invoke-ArmRequest -Path "/subscriptions/$SubscriptionId/providers/Microsoft.RecoveryServices/vaults?api-version=2023-06-01" -Method GET -ErrorAction SilentlyContinue
		$VaultCache[$SubscriptionId] = if ($vResp -and $vResp.StatusCode -eq 200) { @(($vResp.Content | ConvertFrom-Json).value) } else { @() }
	}
	$vaults = $VaultCache[$SubscriptionId]

	$results    = [System.Collections.Generic.List[PSCustomObject]]::new()
	$matchedIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

	foreach ($vault in $vaults) {
		$vParts = [string[]]($vault.id -split '/')
		$rgIdx  = [Array]::IndexOf($vParts, 'resourceGroups')
		$vaultRg = if ($rgIdx -ge 0 -and ($rgIdx + 1) -lt $vParts.Count) { $vParts[$rgIdx + 1] } else { $null }
		if (-not $vaultRg) { continue }

		$itemPath = "/subscriptions/$SubscriptionId/resourceGroups/$vaultRg/providers/Microsoft.RecoveryServices/vaults/$($vault.name)/backupProtectedItems?api-version=2023-06-01&`$filter=backupManagementType eq 'AzureIaasVM'"
		$iResp    = Invoke-ArmRequest -Path $itemPath -Method GET -ErrorAction SilentlyContinue
		if (-not $iResp -or $iResp.StatusCode -ne 200) { continue }

		foreach ($item in @(($iResp.Content | ConvertFrom-Json).value)) {
			$p     = $item.properties
			$srcId = if ($p.PSObject.Properties['sourceResourceId']) { $p.sourceResourceId } else { $null }
			if ([string]::IsNullOrEmpty($srcId)) { continue }
			if (-not $vmLookup.ContainsKey($srcId.ToLowerInvariant())) { continue }

			$matchedIds.Add($srcId.ToLowerInvariant()) | Out-Null
			$results.Add([PSCustomObject]@{
				VmName           = ($srcId -split '/')[-1]
				IsBackedUp       = $true
				VaultName        = $vault.name
				PolicyName       = if ($p.PSObject.Properties['policyName'])       { $p.policyName }       else { $null }
				LastBackupStatus = if ($p.PSObject.Properties['lastBackupStatus']) { $p.lastBackupStatus } else { $null }
				LastBackupTime   = if ($p.PSObject.Properties['lastBackupTime'])   { $p.lastBackupTime }   else { $null }
				ProtectionState  = if ($p.PSObject.Properties['protectionState'])  { $p.protectionState }  else { $null }
			})
		}
	}

	# VMs with no matching protected item are not backed up
	foreach ($rid in $VmResourceIds) {
		if (-not $matchedIds.Contains($rid.ToLowerInvariant())) {
			$results.Add([PSCustomObject]@{
				VmName           = ($rid -split '/')[-1]
				IsBackedUp       = $false
				VaultName        = $null
				PolicyName       = $null
				LastBackupStatus = $null
				LastBackupTime   = $null
				ProtectionState  = $null
			})
		}
	}

	$backedUp = @($results | Where-Object { $_.IsBackedUp }).Count
	$total    = @($results).Count
	$status   = if     ($total -eq 0)          { 'NoHosts' }
	             elseif ($backedUp -eq $total)  { 'AllBackedUp' }
	             elseif ($backedUp -eq 0)       { 'NoneBackedUp' }
	             else                           { "PartiallyBackedUp ($backedUp/$total)" }

	return [PSCustomObject]@{
		BackupInfo       = @($results)
		BackupInfoStatus = $status
	}
}

# ------------------------------------------------------------------
# Metrics collection
# ------------------------------------------------------------------

function Get-HostPoolLogAnalyticsWorkspace {
	<#
	.SYNOPSIS
	Returns the ARM resource ID of the first Log Analytics workspace found in the
	diagnostic settings for a host pool, along with the enabled log category names.
	Returns $null workspace if none is configured.
	#>
	param(
		[Parameter(Mandatory = $true)]
		[PSCustomObject]$HostPool
	)

	$path     = "$($HostPool.ResourceId)/providers/microsoft.insights/diagnosticSettings?api-version=2021-05-01-preview"
	$response = Invoke-ArmRequest -Path $path -Method GET -ErrorAction Stop

	if ($response.StatusCode -ne 200) {
		return [PSCustomObject]@{ WorkspaceResourceId = $null; DiagnosticCategories = @() }
	}

	$settings    = ($response.Content | ConvertFrom-Json).value
	$workspaceId = $null
	$categories  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

	foreach ($setting in $settings) {
		$wid = $setting.properties.workspaceId
		if (-not [string]::IsNullOrEmpty($wid) -and $null -eq $workspaceId) {
			$workspaceId = $wid
		}
		# Collect enabled log categories from all diagnostic settings
		if ($setting.properties.PSObject.Properties['logs']) {
			foreach ($log in @($setting.properties.logs)) {
				$enabled = if ($log.PSObject.Properties['enabled']) { $log.enabled } else { $false }
				if ($enabled) {
					$catName = if ($log.PSObject.Properties['category'] -and -not [string]::IsNullOrEmpty($log.category)) {
						$log.category
					} elseif ($log.PSObject.Properties['categoryGroup'] -and -not [string]::IsNullOrEmpty($log.categoryGroup)) {
						$log.categoryGroup
					} else { $null }
					if ($catName) { $categories.Add($catName) | Out-Null }
				}
			}
		}
	}

	return [PSCustomObject]@{
		WorkspaceResourceId = $workspaceId
		DiagnosticCategories = @($categories | Sort-Object)
	}
}

function Get-HostPoolDailyAverageUsers {
	<#
	.SYNOPSIS
	Returns per-day and overall average unique user connections for a host pool.

	.DESCRIPTION
	Queries the WVDConnections table via the ARM-based Log Analytics query endpoint
	(api-version 2017-10-01). The workspace is discovered from the host pool's diagnostic
	settings. For each calendar day in the lookback window, counts the number of distinct
	users who established a session (State == 'Connected'). The overall DailyAverageUsers
	figure is the mean of all per-day unique user counts.

	Prerequisites: the host pool must have Diagnostic Settings configured to forward logs
	to a Log Analytics workspace with the 'Connection' (WVDConnections) category enabled.

	MetricStatus values:
	  OK                 - usage figures calculated successfully
	  NoDiagnosticSettings - no Log Analytics workspace linked to this host pool
	  NoUserActivity     - diagnostics are enabled, but no user connections matched the window
	#>
	param(
		[Parameter(Mandatory = $true)]
		[PSCustomObject]$HostPool,

		[Parameter(Mandatory = $true)]
		[datetime]$StartTime,

		[Parameter(Mandatory = $true)]
		[datetime]$EndTime,

		[Parameter(Mandatory = $false)]
		[switch]$ExcludeWeekends,

		[Parameter(Mandatory = $false)]
		[switch]$PeakHoursOnly,

		[Parameter(Mandatory = $false)]
		[int]$UtcOffsetHours = 0
	)

	try {
		$diagInfo = Get-HostPoolLogAnalyticsWorkspace -HostPool $HostPool
		$workspaceResourceId = $diagInfo.WorkspaceResourceId

		if ([string]::IsNullOrEmpty($workspaceResourceId)) {
			return [PSCustomObject]@{
				DailyAverageUsers = $null
				DailyBreakdown    = @()
				DataPointCount    = 0
				MetricStatus      = 'NoDiagnosticSettings'
			}
		}

		$startStr = $StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
		$endStr   = $EndTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

		# Build optional peak-hours hour filter (converted from local to UTC)
		$hourFilter = ''
		if ($PeakHoursOnly.IsPresent) {
			$utcStartHour = (9  - $UtcOffsetHours + 24) % 24
			$utcEndHour   = (18 - $UtcOffsetHours + 24) % 24
			$hourFilter   = "| where hourofday(TimeGenerated) >= $utcStartHour and hourofday(TimeGenerated) < $utcEndHour"
		}

		$kqlQuery = @"
WVDConnections
| where TimeGenerated between (datetime('$startStr') .. datetime('$endStr'))
| where _ResourceId =~ '$($HostPool.ResourceId)'
| where State == 'Connected'
$hourFilter
| summarize UniqueUsers = dcount(UserName) by Date = format_datetime(bin(TimeGenerated, 1d), 'yyyy-MM-dd')
| order by Date asc
"@

		$payload   = @{ query = $kqlQuery } | ConvertTo-Json
		$queryPath = "${workspaceResourceId}/query?api-version=2017-10-01"

		$response = Invoke-ArmRequest -Path $queryPath -Method POST -Payload $payload -ErrorAction Stop

		if ($response.StatusCode -ne 200) {
			return [PSCustomObject]@{
				DailyAverageUsers = $null
				DailyBreakdown    = @()
				DataPointCount    = 0
				MetricStatus      = "Error: HTTP $($response.StatusCode) — $($response.Content)"
			}
		}

		$rows = ($response.Content | ConvertFrom-Json).tables[0].rows

		if (-not $rows -or @($rows).Count -eq 0) {
			return [PSCustomObject]@{
				DailyAverageUsers = $null
				DailyBreakdown    = @()
				DataPointCount    = 0
				MetricStatus      = 'NoUserActivity'
			}
		}

		$dailyBreakdown = foreach ($row in $rows) {
			[PSCustomObject]@{
				Date        = $row[0]
				UniqueUsers = [int]$row[1]
			}
		}

		if ($ExcludeWeekends.IsPresent) {
			$dailyBreakdown = @($dailyBreakdown | Where-Object {
				$dow = ([datetime]$_.Date).DayOfWeek
				$dow -ne [System.DayOfWeek]::Saturday -and $dow -ne [System.DayOfWeek]::Sunday
			})
		}

		if (@($dailyBreakdown).Count -eq 0) {
			return [PSCustomObject]@{
				DailyAverageUsers = $null
				DailyBreakdown    = @()
				DataPointCount    = 0
				MetricStatus      = 'NoUserActivity'
			}
		}

		$overallAverage = ($dailyBreakdown | Measure-Object -Property UniqueUsers -Average).Average

		return [PSCustomObject]@{
			DailyAverageUsers = [Math]::Round($overallAverage, 2)
			DailyBreakdown    = @($dailyBreakdown)
			DataPointCount    = @($dailyBreakdown).Count
			MetricStatus      = 'OK'
		}
	}
	catch {
		return [PSCustomObject]@{
			DailyAverageUsers = $null
			DailyBreakdown    = @()
			DataPointCount    = 0
			MetricStatus      = "Error: $($_.Exception.Message)"
		}
	}
}

# ------------------------------------------------------------------
# Performance metrics (CPU and Memory) for right-sizing
# ------------------------------------------------------------------

function Get-HostPoolVmCpuMetrics {
	<#
	.SYNOPSIS
	Returns average CPU utilisation (%) across all session host VMs over the lookback
	window. Sources data from the Azure Monitor platform metrics API (Percentage CPU),
	which is available for all Azure VMs without requiring any monitoring agent.
	#>
	param(
		[Parameter(Mandatory = $true)]
		[AllowEmptyCollection()]
		[string[]]$VmResourceIds,

		[Parameter(Mandatory = $true)]
		[datetime]$StartTime,

		[Parameter(Mandatory = $true)]
		[datetime]$EndTime,

		[Parameter(Mandatory = $false)]
		[switch]$ExcludeWeekends,

		[Parameter(Mandatory = $false)]
		[switch]$PeakHoursOnly,

		[Parameter(Mandatory = $false)]
		[int]$UtcOffsetHours = 0
	)

	if (-not $VmResourceIds -or @($VmResourceIds).Count -eq 0) {
		return [PSCustomObject]@{
			AvgCpuPercent = $null
			P95CpuPercent = $null
			P99CpuPercent = $null
			CpuDailyBreakdown = @()
			CpuStatus     = 'NoVms'
		}
	}

	$startStr = $StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
	$endStr   = $EndTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
	$timespan = "${startStr}/${endStr}"
	$interval = if ($PeakHoursOnly.IsPresent) { 'PT1H' } else { 'P1D' }
	$utcStartHour = (9  - $UtcOffsetHours + 24) % 24
	$utcEndHour   = (18 - $UtcOffsetHours + 24) % 24

	$cpuSamples = [System.Collections.Generic.List[double]]::new()
	$dailyCpuSamples = @{}

	foreach ($vmId in $VmResourceIds) {
		try {
			$path = "${vmId}/providers/microsoft.insights/metrics" +
			        "?metricnames=Percentage%20CPU&aggregation=Average" +
			        "&timespan=${timespan}&interval=${interval}&api-version=2021-05-01"

			$resp = Invoke-ArmRequest -Path $path -Method GET -ErrorAction SilentlyContinue
			if ($resp -and $resp.StatusCode -eq 200) {
				$series = ($resp.Content | ConvertFrom-Json).value[0].timeseries
				if ($series -and @($series).Count -gt 0) {
					foreach ($pt in @($series[0].data | Where-Object { $null -ne $_.average })) {
						$ts = if ($pt.PSObject.Properties['timeStamp']) { $pt.timeStamp } elseif ($pt.PSObject.Properties['timestamp']) { $pt.timestamp } else { $null }
						$dt = $null
						if ($null -ne $ts) {
							$dt = [datetime]$ts
							if ($PeakHoursOnly.IsPresent) {
								$h = $dt.Hour
								if ($h -lt $utcStartHour -or $h -ge $utcEndHour) { continue }
							}
							if ($ExcludeWeekends.IsPresent) {
								$dow = $dt.DayOfWeek
								if ($dow -eq [System.DayOfWeek]::Saturday -or $dow -eq [System.DayOfWeek]::Sunday) { continue }
							}
						}
						$cpuSamples.Add([double]$pt.average)
						if ($null -ne $dt) {
							$dateKey = $dt.ToString('yyyy-MM-dd')
							if (-not $dailyCpuSamples.ContainsKey($dateKey)) {
								$dailyCpuSamples[$dateKey] = [System.Collections.Generic.List[double]]::new()
							}
							$dailyCpuSamples[$dateKey].Add([double]$pt.average)
						}
					}
				}
			}
		}
		catch { <# Non-fatal — skip this VM #> }
	}

	if ($cpuSamples.Count -eq 0) {
		return [PSCustomObject]@{
			AvgCpuPercent = $null
			P95CpuPercent = $null
			P99CpuPercent = $null
			CpuDailyBreakdown = @()
			CpuStatus     = 'NoData'
		}
	}

	$sortedCpu = @($cpuSamples | Sort-Object)
	$p95IdxCpu = [Math]::Max(0, [Math]::Ceiling($sortedCpu.Count * 0.95) - 1)
	$p99IdxCpu = [Math]::Max(0, [Math]::Ceiling($sortedCpu.Count * 0.99) - 1)
	$cpuDailyBreakdown = foreach ($dateKey in @($dailyCpuSamples.Keys | Sort-Object)) {
		$dailyAverage = ($dailyCpuSamples[$dateKey] | Measure-Object -Average).Average
		if ($null -eq $dailyAverage) { continue }
		[PSCustomObject]@{
			Day = $dateKey
			AvgCpuPercent = [Math]::Round($dailyAverage, 2)
		}
	}

	return [PSCustomObject]@{
		AvgCpuPercent = [Math]::Round(($cpuSamples | Measure-Object -Average).Average, 2)
		P95CpuPercent = [Math]::Round($sortedCpu[$p95IdxCpu], 2)
		P99CpuPercent = [Math]::Round($sortedCpu[$p99IdxCpu], 2)
		CpuDailyBreakdown = @($cpuDailyBreakdown)
		CpuStatus     = 'OK'
	}
}

function Get-HostPoolDailyHostsOn {
	<#
	.SYNOPSIS
	Returns the average number of session host VMs that were running per day over the
	lookback window. A VM is considered "on" for a given day if Azure Monitor reports
	at least one Percentage CPU data point for that day (daily granularity).
	#>
	param(
		[Parameter(Mandatory = $true)]
		[AllowEmptyCollection()]
		[string[]]$VmResourceIds,

		[Parameter(Mandatory = $true)]
		[datetime]$StartTime,

		[Parameter(Mandatory = $true)]
		[datetime]$EndTime,

		[Parameter(Mandatory = $false)]
		[switch]$ExcludeWeekends
	)

	if (-not $VmResourceIds -or @($VmResourceIds).Count -eq 0) {
		return [PSCustomObject]@{
			AverageHostsOnPerDay = $null
			DailyHostsOnStatus   = 'NoVms'
		}
	}

	$startStr = $StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
	$endStr   = $EndTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
	$timespan = "${startStr}/${endStr}"

	# Track which dates had data per VM: key = date string, value = count of VMs on
	$dailyCounts = @{}

	foreach ($vmId in $VmResourceIds) {
		try {
			$path = "${vmId}/providers/microsoft.insights/metrics" +
			        "?metricnames=Percentage%20CPU&aggregation=Average" +
			        "&timespan=${timespan}&interval=P1D&api-version=2021-05-01"

			$resp = Invoke-ArmRequest -Path $path -Method GET -ErrorAction SilentlyContinue
			if ($resp -and $resp.StatusCode -eq 200) {
				$series = ($resp.Content | ConvertFrom-Json).value[0].timeseries
				if ($series -and @($series).Count -gt 0) {
					foreach ($pt in @($series[0].data | Where-Object { $null -ne $_.average })) {
						$ts = if ($pt.PSObject.Properties['timeStamp']) { $pt.timeStamp } elseif ($pt.PSObject.Properties['timestamp']) { $pt.timestamp } else { $null }
						if ($null -ne $ts) {
							$dt = [datetime]$ts
							if ($ExcludeWeekends.IsPresent) {
								$dow = $dt.DayOfWeek
								if ($dow -eq [System.DayOfWeek]::Saturday -or $dow -eq [System.DayOfWeek]::Sunday) { continue }
							}
							$dateKey = $dt.ToString('yyyy-MM-dd')
							if (-not $dailyCounts.ContainsKey($dateKey)) { $dailyCounts[$dateKey] = 0 }
							$dailyCounts[$dateKey]++
						}
					}
				}
			}
		}
		catch { <# Non-fatal — skip this VM #> }
	}

	if ($dailyCounts.Count -eq 0) {
		return [PSCustomObject]@{
			AverageHostsOnPerDay = $null
			DailyHostsOnStatus   = 'NoData'
		}
	}

	$avgOn = [Math]::Round(($dailyCounts.Values | Measure-Object -Average).Average, 2)

	return [PSCustomObject]@{
		AverageHostsOnPerDay = $avgOn
		DailyHostsOnStatus   = 'OK'
	}
}

function Get-VmSizeMemoryGbMap {
	<#
	.SYNOPSIS
	Returns a hashtable mapping VM size name to memory in GB for a given subscription
	and location, using the Compute vmSizes endpoint (no filter — no URL-encoding issues).
	#>
	param(
		[Parameter(Mandatory = $true)]
		[string]$SubscriptionId,

		[Parameter(Mandatory = $true)]
		[string]$Location
	)

	$map = @{}
	try {
		$path = "/subscriptions/$SubscriptionId/providers/Microsoft.Compute/locations/$Location/vmSizes?api-version=2021-07-01"
		$resp = Invoke-ArmRequest -Path $path -Method GET -ErrorAction Stop
		if ($resp.StatusCode -eq 200) {
			foreach ($size in ($resp.Content | ConvertFrom-Json).value) {
				if (-not $map.ContainsKey($size.name)) {
					$map[$size.name] = [Math]::Round($size.memoryInMB / 1024, 2)
				}
			}
		}
	}
	catch { <# Return empty map — memory % will report NoSkuData #> }

	return $map
}

function Get-HostPoolVmMemoryMetrics {
	<#
	.SYNOPSIS
	Returns average memory utilisation (% RAM used) across all session host VMs over the
	lookback window using Azure Monitor platform metrics — no monitoring agent required.

	.DESCRIPTION
	Queries the 'Available Memory Bytes' platform metric for each session host VM (same
	source as Percentage CPU — available for all Azure VMs without any agent). Combines
	that with the VM size's total RAM from the Compute vmSizes API to calculate
	(totalRAM - availableRAM) / totalRAM * 100, averaged across all VMs.

	MemoryStatus values:
	  OK          — percentage calculated successfully
	  NoVms       — no session host VM resource IDs found
	  NoData      — Azure Monitor returned no data points for any VM
	  NoSkuData   — metric data available but VM size RAM lookup failed; percentage
	               cannot be calculated
	#>
	param(
		[Parameter(Mandatory = $true)]
		[AllowEmptyCollection()]
		[string[]]$VmResourceIds,

		[Parameter(Mandatory = $true)]
		[hashtable]$VmSizeMap,

		[Parameter(Mandatory = $true)]
		[hashtable]$VmSizeMemoryGbMap,

		[Parameter(Mandatory = $true)]
		[datetime]$StartTime,

		[Parameter(Mandatory = $true)]
		[datetime]$EndTime,

		[Parameter(Mandatory = $false)]
		[switch]$ExcludeWeekends,

		[Parameter(Mandatory = $false)]
		[switch]$PeakHoursOnly,

		[Parameter(Mandatory = $false)]
		[int]$UtcOffsetHours = 0
	)

	if (-not $VmResourceIds -or @($VmResourceIds).Count -eq 0) {
		return [PSCustomObject]@{
			AvgMemUsedPercent = $null
			P95MemUsedPercent = $null
			P99MemUsedPercent = $null
			MemoryDailyBreakdown = @()
			MemoryStatus      = 'NoVms'
		}
	}

	$startStr     = $StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
	$endStr       = $EndTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
	$timespan     = "${startStr}/${endStr}"
	$interval     = if ($PeakHoursOnly.IsPresent) { 'PT1H' } else { 'P1D' }
	$utcStartHour = (9  - $UtcOffsetHours + 24) % 24
	$utcEndHour   = (18 - $UtcOffsetHours + 24) % 24

	$pctSamples    = [System.Collections.Generic.List[double]]::new()
	$dailyMemSamples = @{}
	$metricHasData = $false

	foreach ($vmId in $VmResourceIds) {
		try {
			$vmSize     = $VmSizeMap[$vmId.ToLowerInvariant()]
			$totalMemGb = if ($vmSize -and $VmSizeMemoryGbMap.ContainsKey($vmSize)) { $VmSizeMemoryGbMap[$vmSize] } else { $null }

			# Query metric regardless of whether SKU RAM is known
			$path = "${vmId}/providers/microsoft.insights/metrics" +
			        "?metricnames=Available%20Memory%20Bytes&aggregation=Average" +
			        "&timespan=${timespan}&interval=${interval}&api-version=2021-05-01"

			$resp = Invoke-ArmRequest -Path $path -Method GET -ErrorAction SilentlyContinue
			if ($resp -and $resp.StatusCode -eq 200) {
				$series = ($resp.Content | ConvertFrom-Json).value[0].timeseries
				if ($series -and @($series).Count -gt 0) {
					$dataPoints = @($series[0].data | Where-Object { $null -ne $_.average })
					if ($PeakHoursOnly.IsPresent -or $ExcludeWeekends.IsPresent) {
						$dataPoints = @($dataPoints | Where-Object {
							$ts = if ($_.PSObject.Properties['timeStamp']) { $_.timeStamp } elseif ($_.PSObject.Properties['timestamp']) { $_.timestamp } else { $null }
							if ($null -eq $ts) { return $true }
							$dt = [datetime]$ts
							if ($PeakHoursOnly.IsPresent) {
								$h = $dt.Hour
								if ($h -lt $utcStartHour -or $h -ge $utcEndHour) { return $false }
							}
							if ($ExcludeWeekends.IsPresent) {
								$dow = $dt.DayOfWeek
								if ($dow -eq [System.DayOfWeek]::Saturday -or $dow -eq [System.DayOfWeek]::Sunday) { return $false }
							}
							return $true
						})
					}
					if ($dataPoints.Count -gt 0) {
						$metricHasData = $true
						if ($null -ne $totalMemGb -and $totalMemGb -gt 0) {
							$totalMemBytes = $totalMemGb * 1073741824
							foreach ($pt in $dataPoints) {
								$usedPct = (($totalMemBytes - $pt.average) / $totalMemBytes) * 100
								if ($usedPct -ge 0) {
									$pctSamples.Add([double]$usedPct)
									$ts = if ($pt.PSObject.Properties['timeStamp']) { $pt.timeStamp } elseif ($pt.PSObject.Properties['timestamp']) { $pt.timestamp } else { $null }
									if ($null -ne $ts) {
										$dateKey = ([datetime]$ts).ToString('yyyy-MM-dd')
										if (-not $dailyMemSamples.ContainsKey($dateKey)) {
											$dailyMemSamples[$dateKey] = [System.Collections.Generic.List[double]]::new()
										}
										$dailyMemSamples[$dateKey].Add([double]$usedPct)
									}
								}
							}
						}
					}
				}
			}
		}
		catch { <# Non-fatal — skip this VM #> }
	}

	if ($pctSamples.Count -gt 0) {
		$sortedMem = @($pctSamples | Sort-Object)
		$p95IdxMem = [Math]::Max(0, [Math]::Ceiling($sortedMem.Count * 0.95) - 1)
		$p99IdxMem = [Math]::Max(0, [Math]::Ceiling($sortedMem.Count * 0.99) - 1)
		$memoryDailyBreakdown = foreach ($dateKey in @($dailyMemSamples.Keys | Sort-Object)) {
			$dailyAverage = ($dailyMemSamples[$dateKey] | Measure-Object -Average).Average
			if ($null -eq $dailyAverage) { continue }
			[PSCustomObject]@{
				Day = $dateKey
				AvgMemUsedPercent = [Math]::Round($dailyAverage, 2)
			}
		}
		return [PSCustomObject]@{
			AvgMemUsedPercent = [Math]::Round(($pctSamples | Measure-Object -Average).Average, 2)
			P95MemUsedPercent = [Math]::Round($sortedMem[$p95IdxMem], 2)
			P99MemUsedPercent = [Math]::Round($sortedMem[$p99IdxMem], 2)
			MemoryDailyBreakdown = @($memoryDailyBreakdown)
			MemoryStatus      = 'OK'
		}
	}

	# Distinguish: metric returned data but SKU RAM unknown vs metric itself had no data
	$status = if ($metricHasData) { 'NoSkuData' } else { 'NoData' }
	return [PSCustomObject]@{
		AvgMemUsedPercent = $null
		P95MemUsedPercent = $null
		P99MemUsedPercent = $null
		MemoryDailyBreakdown = @()
		MemoryStatus      = $status
	}
}

# ------------------------------------------------------------------
# Session metrics (concurrent sessions and logon duration)
# ------------------------------------------------------------------

function Get-HostPoolConcurrentSessionMetrics {
	<#
	.SYNOPSIS
	Returns peak and per-day peak concurrent sessions for a host pool.

	.DESCRIPTION
	Queries WVDConnections for Connected/Completed events and uses row_cumsum to track
	a running session count per day, deriving the maximum (peak) concurrent sessions
	for each day and overall. Requires WVDConnections diagnostic data in Log Analytics.

	SessionsStatus values:
	  OK                   - peak figures calculated successfully
	  NoDiagnosticSettings - no Log Analytics workspace linked to this host pool
	  NoUserActivity       - diagnostics are enabled, but no session events matched the window
	#>
	param(
		[Parameter(Mandatory = $true)]
		[PSCustomObject]$HostPool,

		[Parameter(Mandatory = $true)]
		[datetime]$StartTime,

		[Parameter(Mandatory = $true)]
		[datetime]$EndTime,

		[Parameter(Mandatory = $false)]
		[switch]$ExcludeWeekends,

		[Parameter(Mandatory = $false)]
		[switch]$PeakHoursOnly,

		[Parameter(Mandatory = $false)]
		[int]$UtcOffsetHours = 0
	)

	try {
		$diagInfo = Get-HostPoolLogAnalyticsWorkspace -HostPool $HostPool
		$workspaceResourceId = $diagInfo.WorkspaceResourceId
		if ([string]::IsNullOrEmpty($workspaceResourceId)) {
			return [PSCustomObject]@{
				PeakConcurrentSessions = $null
				DailyPeakBreakdown     = @()
				SessionsStatus         = 'NoDiagnosticSettings'
			}
		}

		$startStr = $StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
		$endStr   = $EndTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

		$hourFilter = ''
		if ($PeakHoursOnly.IsPresent) {
			$utcStartHour = (9  - $UtcOffsetHours + 24) % 24
			$utcEndHour   = (18 - $UtcOffsetHours + 24) % 24
			$hourFilter   = "| where hourofday(TimeGenerated) >= $utcStartHour and hourofday(TimeGenerated) < $utcEndHour"
		}

		# row_cumsum with a per-day restart tracks concurrent sessions within each calendar day.
		# Delta +1 on Connected, -1 on Completed; max of running total = peak concurrent.
		$kqlQuery = @"
WVDConnections
| where TimeGenerated between (datetime('$startStr') .. datetime('$endStr'))
| where _ResourceId =~ '$($HostPool.ResourceId)'
| where State in ('Connected', 'Completed')
$hourFilter
| extend Delta = iff(State == 'Connected', 1, -1), Day = format_datetime(bin(TimeGenerated, 1d), 'yyyy-MM-dd')
| sort by TimeGenerated asc
| extend ConcurrentSessions = row_cumsum(Delta, Day != prev(Day))
// Floor at 0: a Completed arriving before its Connected (cross-midnight session) can produce a negative cumsum
| extend ConcurrentSessions = iff(ConcurrentSessions < 0, 0, ConcurrentSessions)
| summarize PeakConcurrentSessions = max(ConcurrentSessions) by Day
| order by Day asc
"@

		$payload   = @{ query = $kqlQuery } | ConvertTo-Json
		$queryPath = "${workspaceResourceId}/query?api-version=2017-10-01"
		$response  = Invoke-ArmRequest -Path $queryPath -Method POST -Payload $payload -ErrorAction Stop

		if ($response.StatusCode -ne 200) {
			return [PSCustomObject]@{
				PeakConcurrentSessions = $null
				DailyPeakBreakdown     = @()
				SessionsStatus         = "Error: HTTP $($response.StatusCode) — $($response.Content)"
			}
		}

		$rows = ($response.Content | ConvertFrom-Json).tables[0].rows

		if (-not $rows -or @($rows).Count -eq 0) {
			return [PSCustomObject]@{
				PeakConcurrentSessions = $null
				DailyPeakBreakdown     = @()
				SessionsStatus         = 'NoUserActivity'
			}
		}

		$dailyPeak = foreach ($row in $rows) {
			[PSCustomObject]@{
				Date                   = $row[0]
				PeakConcurrentSessions = [int]$row[1]
			}
		}

		if ($ExcludeWeekends.IsPresent) {
			$dailyPeak = @($dailyPeak | Where-Object {
				$dow = ([datetime]$_.Date).DayOfWeek
				$dow -ne [System.DayOfWeek]::Saturday -and $dow -ne [System.DayOfWeek]::Sunday
			})
		}

		if (@($dailyPeak).Count -eq 0) {
			return [PSCustomObject]@{
				PeakConcurrentSessions = $null
				DailyPeakBreakdown     = @()
				SessionsStatus         = 'NoUserActivity'
			}
		}

		$overallPeak = ($dailyPeak | Measure-Object -Property PeakConcurrentSessions -Maximum).Maximum

		return [PSCustomObject]@{
			PeakConcurrentSessions = [int]$overallPeak
			DailyPeakBreakdown     = @($dailyPeak)
			SessionsStatus         = 'OK'
		}
	}
	catch {
		return [PSCustomObject]@{
			PeakConcurrentSessions = $null
			DailyPeakBreakdown     = @()
			SessionsStatus         = "Error: $($_.Exception.Message)"
		}
	}
}

# ------------------------------------------------------------------
# Diagnostics / error insights
# ------------------------------------------------------------------

function Get-HostPoolDiagnosticInsights {
	<#
	.SYNOPSIS
	Queries Log Analytics for AVD diagnostic events over the lookback window.

	.DESCRIPTION
	Queries WVDErrors, WVDConnections, WVDCheckpoints, and WVDHostRegistrations via
	the ARM Log Analytics query endpoint. Results are stored via script-scoped
	variables to avoid PS5.1 pipeline array-unwrapping issues.
	#>
	param(
		[Parameter(Mandatory = $true)]  [PSCustomObject]$HostPool,
		[Parameter(Mandatory = $true)]  [datetime]$StartTime,
		[Parameter(Mandatory = $true)]  [datetime]$EndTime
	)

	$emptyResult = [PSCustomObject]@{
		DiagnosticsStatus         = $null
		LogAnalyticsWorkspace     = $null
		DiagnosticCategories      = @()
		LastSuccessfulConnection  = $null
		TotalErrors               = $null
		TotalFailedConnections    = $null
		ShortpathErrors           = $null
		ShortpathUpgradeEvents    = $null
		HostRegistrationEvents          = $null
		HostRegistrationHealthSummary   = $null
		TopErrors                 = @()
		TransportTypeBreakdown    = @()
		HostRegistrationBreakdown = @()
	}

	try {
		$diagInfo = Get-HostPoolLogAnalyticsWorkspace -HostPool $HostPool
		$workspaceResourceId = $diagInfo.WorkspaceResourceId
		if ([string]::IsNullOrEmpty($workspaceResourceId)) {
			$emptyResult.DiagnosticsStatus  = 'NoDiagnosticSettings'
			$emptyResult.DiagnosticCategories = $diagInfo.DiagnosticCategories
			return $emptyResult
		}

		$emptyResult.LogAnalyticsWorkspace = ($workspaceResourceId -split '/')[-1]
		$emptyResult.DiagnosticCategories  = $diagInfo.DiagnosticCategories

		$startStr    = $StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
		$endStr      = $EndTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
		$queryPath   = "${workspaceResourceId}/query?api-version=2017-10-01"
		$resourceId  = $HostPool.ResourceId
		$queryErrors = @()

		# ---- Inline helper: run KQL, return normalised row array ----
		# PS5.1 ConvertFrom-Json unwraps single-element JSON arrays, so
		# [["a","b",1]] → @("a","b",1) instead of @(@("a","b",1)).
		# Pipeline return from script blocks ALSO unwraps, so we cannot
		# rely on 'return'. Instead we store results in $script: scope
		# via ArrayList (immune to unwrapping) and the caller reads them.
		$invokeKql = {
			param([string]$Kql)
			$script:kqlRows  = $null
			$script:kqlError = $null
			$payload = @{ query = $Kql } | ConvertTo-Json
			$rsp = Invoke-ArmRequest -Path $queryPath -Method POST -Payload $payload -ErrorAction SilentlyContinue
			if ($rsp -and $rsp.StatusCode -eq 200) {
				$table    = ($rsp.Content | ConvertFrom-Json).tables[0]
				$colCount = @($table.columns).Count
				$raw      = @($table.rows)
				if ($raw.Count -eq 0) {
					$script:kqlRows = [System.Collections.ArrayList]::new()
					return
				}
				if ($raw[0] -is [System.Array] -or $raw[0] -is [System.Collections.IList]) {
					# Already correctly nested (multiple rows)
					$list = [System.Collections.ArrayList]::new()
					foreach ($r in $raw) { $list.Add($r) | Out-Null }
					$script:kqlRows = $list
				} elseif ($colCount -gt 1) {
					# Single multi-column row unwrapped to flat — re-wrap
					$list = [System.Collections.ArrayList]::new()
					$list.Add($raw) | Out-Null
					$script:kqlRows = $list
				} else {
					# Single-column single-row (| count) — wrap scalar
					$list = [System.Collections.ArrayList]::new()
					$list.Add(@($raw[0])) | Out-Null
					$script:kqlRows = $list
				}
				return
			}
			$errObj = if ($rsp) { try { ($rsp.Content | ConvertFrom-Json).error } catch { $null } } else { $null }
			$script:kqlError = if ($errObj -and $errObj.message) {
				"HTTP $($rsp.StatusCode): $($errObj.message)"
			} elseif ($rsp) {
				"HTTP $($rsp.StatusCode)"
			} else {
				'NoResponse'
			}
		}

		# ----------------------------------------------------------
		# 1. WVDErrors — columns: Source, Message, ServiceError, Code
		# ----------------------------------------------------------
		$errKql = @"
WVDErrors
| where TimeGenerated between (datetime('$startStr') .. datetime('$endStr'))
| where _ResourceId =~ '$resourceId'
| summarize Count = count() by Source, Message
| order by Count desc
| take 20
"@
		& $invokeKql -Kql $errKql
		$errRows = $script:kqlRows
		if ($null -eq $errRows) { $queryErrors += "WVDErrors($($script:kqlError))" }

		$topErrors = @()
		if ($errRows -and $errRows.Count -gt 0) {
			foreach ($row in $errRows) {
				$topErrors += [PSCustomObject]@{
					Source  = [string]$row[0]
					Message = [string]$row[1]
					Count   = [int]$row[2]
				}
			}
		}

		$totalErrors     = if ($topErrors.Count -gt 0) { ($topErrors | Measure-Object -Property Count -Sum).Sum } else { $null }
		$shortpathErrors = if ($topErrors.Count -gt 0) {
			$_sp = @($topErrors | Where-Object {
				$_.Source  -match 'UDP|Shortpath|ICE|TURN|STUN' -or
				$_.Message -match 'UDP|Shortpath|ICE|TURN|STUN'
			})
			if ($_sp.Count -gt 0) { ($_sp | Measure-Object -Property Count -Sum).Sum } else { $null }
		} else { $null }

		# ----------------------------------------------------------
		# 2a. WVDConnections — TransportType breakdown
		# ----------------------------------------------------------
		$transportKql = @"
WVDConnections
| where TimeGenerated between (datetime('$startStr') .. datetime('$endStr'))
| where _ResourceId =~ '$resourceId'
| where State == 'Connected'
| extend Transport = iif(isempty(TransportType), 'Unknown', TransportType)
| summarize Count = count() by Transport
| order by Count desc
"@
		& $invokeKql -Kql $transportKql
		$transportRows = $script:kqlRows
		if ($null -eq $transportRows) { $queryErrors += "WVDConnections(transport:$($script:kqlError))" }

		$transportTypeBreakdown = @()
		if ($transportRows -and $transportRows.Count -gt 0) {
			# Map raw Log Analytics TransportType values to human-readable descriptions
			$transportMeta = @{
				'TCP Websocket'              = @{ Method = 'TCP (Reverse Connect)';  Description = 'Standard fallback path — traffic relays through Azure gateway over TCP. Works anywhere but highest latency.' }
				'UDP Shortpath'              = @{ Method = 'UDP (Public Shortpath)';  Description = 'Direct UDP path over the public internet — lower latency than TCP. Requires UDP port open on client firewall.' }
				'Managed Network Shortpath'  = @{ Method = 'UDP (Private Shortpath)'; Description = 'Direct UDP path over private/ExpressRoute network — lowest latency. Requires network line-of-sight to session host.' }
			}
			foreach ($row in $transportRows) {
				$rawType = [string]$row[0]
				$meta    = $transportMeta[$rawType]
				$transportTypeBreakdown += [PSCustomObject]@{
					TransportType = $rawType
					Method        = if ($meta) { $meta.Method }      else { 'Unknown' }
					Description   = if ($meta) { $meta.Description } else { 'Unrecognised transport type.' }
					Count         = [int]$row[1]
				}
			}
		}

		# ----------------------------------------------------------
		# 2b. WVDConnections — failed connections
		# ----------------------------------------------------------
		$failKql = @"
WVDConnections
| where TimeGenerated between (datetime('$startStr') .. datetime('$endStr'))
| where _ResourceId =~ '$resourceId'
| where State == 'Connected'
| join kind=leftanti (
    WVDConnections
    | where TimeGenerated between (datetime('$startStr') .. datetime('$endStr'))
    | where _ResourceId =~ '$resourceId'
    | where State == 'Completed'
    | project CorrelationId
) on CorrelationId
| count
"@
		& $invokeKql -Kql $failKql
		$failRows = $script:kqlRows
		$totalFailedConnections = if ($failRows -and $failRows.Count -gt 0) { [int]$failRows[0][0] } else { $null }
		if ($null -eq $failRows) { $queryErrors += "WVDConnections(failedJoin:$($script:kqlError))" }

		# ----------------------------------------------------------
		# 3. WVDCheckpoints — Shortpath / UDP events
		# ----------------------------------------------------------
		$ckptKql = @"
WVDCheckpoints
| where TimeGenerated between (datetime('$startStr') .. datetime('$endStr'))
| where _ResourceId =~ '$resourceId'
| where Name has_any ('Shortpath', 'UDP', 'shortpath', 'udp')
| count
"@
		& $invokeKql -Kql $ckptKql
		$ckptRows = $script:kqlRows
		$shortpathUpgradeEvents = if ($ckptRows -and $ckptRows.Count -gt 0) { [int]$ckptRows[0][0] } else { $null }
		if ($null -eq $ckptRows) { $queryErrors += "WVDCheckpoints($($script:kqlError))" }

		# ----------------------------------------------------------
		# 4. WVDHostRegistrations — per-host registration events
		# ----------------------------------------------------------
		$regKql = @"
WVDHostRegistrations
| where TimeGenerated between (datetime('$startStr') .. datetime('$endStr'))
| where _ResourceId =~ '$resourceId'
| summarize RegistrationCount = count(), LastSeen = max(TimeGenerated) by SessionHostName
| order by RegistrationCount desc
"@
		& $invokeKql -Kql $regKql
		$regRows = $script:kqlRows
		if ($null -eq $regRows) { $queryErrors += "WVDHostRegistrations($($script:kqlError))" }

		$hostRegistrationBreakdown = @()
		if ($regRows -and $regRows.Count -gt 0) {
			foreach ($row in $regRows) {
				$rawLastSeen = [string]$row[2]
				[datetime]$parsedLastSeen = [datetime]::MinValue
				$isoLastSeen = if ([datetime]::TryParse($rawLastSeen, [ref]$parsedLastSeen)) {
					$parsedLastSeen.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
				} else { $rawLastSeen }
				$hostRegistrationBreakdown += [PSCustomObject]@{
					SessionHostName   = [string]$row[0]
					RegistrationCount = [int]$row[1]
					LastSeen          = $isoLastSeen
				}
			}
		}

		$hostRegistrationEvents = if ($hostRegistrationBreakdown.Count -gt 0) {
			$_regSum = 0; foreach ($_r in $hostRegistrationBreakdown) { $_regSum += $_r.RegistrationCount }; $_regSum
		} else { $null }

		# Summarise registration health in plain English.
		# Re-registrations occur on VM reboot or agent broker disconnection; elevated counts suggest instability.
		$hostRegistrationHealthSummary = if ($null -eq $regRows) {
			'NoData — WVDHostRegistrations query failed or diagnostic category not enabled.'
		} elseif ($hostRegistrationBreakdown.Count -eq 0) {
			'Healthy — no agent re-registrations recorded in the query window.'
		} else {
			$maxCount  = ($hostRegistrationBreakdown | Measure-Object -Property RegistrationCount -Maximum).Maximum
			$hostWord  = if ($hostRegistrationBreakdown.Count -eq 1) { 'host' } else { 'hosts' }
			$level     = if ($maxCount -ge 10) { 'Elevated' } elseif ($maxCount -ge 3) { 'Moderate' } else { 'Low' }
			"$level — $hostRegistrationEvents re-registration(s) across $($hostRegistrationBreakdown.Count) $hostWord (max $maxCount on a single host). Elevated counts may indicate VM instability or agent issues."
		}

		# ----------------------------------------------------------
		# 5. WVDConnections — last successful connection timestamp
		# ----------------------------------------------------------
		$lastConnKql = @"
WVDConnections
| where _ResourceId =~ '$resourceId'
| where State == 'Connected'
| summarize LastConnection = max(TimeGenerated)
"@
		& $invokeKql -Kql $lastConnKql
		$lastConnRows = $script:kqlRows
		$lastSuccessfulConnection = $null
		if ($lastConnRows -and $lastConnRows.Count -gt 0 -and $null -ne $lastConnRows[0][0]) {
			# KQL returns datetime in US locale format (M/d/yyyy H:mm:ss) — parse explicitly with en-US culture
			# then reformat as UK date (dd/MM/yyyy HH:mm:ss) UTC
			[datetime]$parsedDt = [datetime]::MinValue
			$enUS = [System.Globalization.CultureInfo]::new('en-US')
			if ([datetime]::TryParse([string]$lastConnRows[0][0], $enUS, [System.Globalization.DateTimeStyles]::None, [ref]$parsedDt)) {
				$lastSuccessfulConnection = $parsedDt.ToUniversalTime().ToString('dd/MM/yyyy HH:mm:ss')
			} else {
				$lastSuccessfulConnection = [string]$lastConnRows[0][0]
			}
		}
		if ($null -eq $lastConnRows) { $queryErrors += "WVDConnections(lastConn:$($script:kqlError))" }

		$status = if ($queryErrors.Count -eq 0) { 'OK' } else { "PartialData (failed: $($queryErrors -join '; '))" }

		return [PSCustomObject]@{
			DiagnosticsStatus         = $status
			LogAnalyticsWorkspace     = $emptyResult.LogAnalyticsWorkspace
			DiagnosticCategories      = $emptyResult.DiagnosticCategories
			LastSuccessfulConnection  = $lastSuccessfulConnection
			TotalErrors               = $totalErrors
			TotalFailedConnections    = $totalFailedConnections
			ShortpathErrors           = $shortpathErrors
			ShortpathUpgradeEvents    = $shortpathUpgradeEvents
			HostRegistrationEvents          = $hostRegistrationEvents
			HostRegistrationHealthSummary   = $hostRegistrationHealthSummary
			TopErrors                 = $topErrors
			TransportTypeBreakdown    = $transportTypeBreakdown
			HostRegistrationBreakdown = $hostRegistrationBreakdown
		}
	}
	catch {
		$emptyResult.DiagnosticsStatus = "Error: $($_.Exception.Message)"
		return $emptyResult
	}
}

# ------------------------------------------------------------------
# Authorized user discovery
# ------------------------------------------------------------------

function Get-GraphToken {
	<#
	.SYNOPSIS
	Acquires a Bearer token for Microsoft Graph. Handles both plain string and SecureString
	return types across Az.Accounts versions (SecureString introduced in 2.17.0).
	Retries once on transient failures (e.g. SSL handshake errors against the token endpoint).
	#>
	$maxAttempts = 2
	for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
		try {
			# Az.Accounts 2.17+ supports -AsPlainText
			return (Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com' -AsPlainText -ErrorAction Stop -WarningAction SilentlyContinue).Token
		}
		catch {
			try {
				$t = (Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com' -ErrorAction Stop -WarningAction SilentlyContinue).Token
				if ($t -is [System.Security.SecureString]) {
					return [System.Net.NetworkCredential]::new('', $t).Password
				}
				return $t
			}
			catch {
				if ($attempt -lt $maxAttempts) {
					Write-Verbose "Graph token attempt $attempt failed ($($_.Exception.Message)) — retrying..."
					Start-Sleep -Seconds 2
				}
			}
		}
	}
	return $null
}

function Invoke-GraphGet {
	<#
	.SYNOPSIS
	Issues a GET request to Microsoft Graph and returns the parsed response body,
	or $null on failure.
	#>
	param(
		[Parameter(Mandatory = $true)]
		[string]$Uri,

		[Parameter(Mandatory = $true)]
		[string]$GraphToken
	)
	try {
		return Invoke-RestMethod -Uri $Uri -Headers @{ Authorization = "Bearer $GraphToken" } -Method GET -ErrorAction Stop
	}
	catch { return $null }
}

function Get-GraphPagedItems {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Uri,

		[Parameter(Mandatory = $true)]
		[string]$GraphToken
	)

	$items = [System.Collections.Generic.List[object]]::new()
	$nextUri = $Uri

	do {
		$response = Invoke-GraphGet -Uri $nextUri -GraphToken $GraphToken
		if (-not $response) {
			return $null
		}

		if ($response.PSObject.Properties['value'] -and $response.value) {
			foreach ($item in @($response.value)) {
				$items.Add($item) | Out-Null
			}
		}

		$nextUri = if ($response.PSObject.Properties['@odata.nextLink'] -and $response.'@odata.nextLink') {
			[string]$response.'@odata.nextLink'
		} else {
			$null
		}
	} while (-not [string]::IsNullOrWhiteSpace($nextUri))

	return @($items)
}

function Get-PrincipalDirectoryRoleSummary {
	param(
		[Parameter(Mandatory = $true)]
		[string]$PrincipalObjectId,

		[Parameter(Mandatory = $true)]
		[ValidateSet('User', 'ServicePrincipal')]
		[string]$PrincipalType,

		[Parameter(Mandatory = $true)]
		[string]$GraphToken
	)

	$directoryRoleUri = if ($PrincipalType -eq 'ServicePrincipal') {
		"https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalObjectId/memberOf/microsoft.graph.directoryRole?`$select=id,displayName&`$top=999"
	}
	else {
		"https://graph.microsoft.com/v1.0/users/$PrincipalObjectId/memberOf/microsoft.graph.directoryRole?`$select=id,displayName&`$top=999"
	}

	$roles = Get-GraphPagedItems -Uri $directoryRoleUri -GraphToken $GraphToken
	if ($null -eq $roles) {
		return [PSCustomObject]@{
			Status = 'GraphQueryFailed'
			Roles  = @()
		}
	}

	return [PSCustomObject]@{
		Status = 'OK'
		Roles  = @($roles | ForEach-Object { [string]$_.displayName } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
	}
}

function Get-PrincipalSubscriptionAccessSummary {
	param(
		[Parameter(Mandatory = $true)]
		[object[]]$Subscriptions,

		[Parameter(Mandatory = $true)]
		[string]$PrincipalObjectId,

		[Parameter(Mandatory = $true)]
		[string]$PrincipalType
	)

	function Resolve-RoleDefinitionName {
		param(
			[Parameter(Mandatory = $true)]
			[string]$RoleDefinitionId,

			[Parameter(Mandatory = $true)]
			[hashtable]$RoleDefinitionMap
		)

		if ($RoleDefinitionMap.ContainsKey($RoleDefinitionId)) {
			return $RoleDefinitionMap[$RoleDefinitionId]
		}

		$roleDefinitionPath = $RoleDefinitionId -replace '^https://management\.azure\.com', ''
		if (-not [string]::IsNullOrWhiteSpace($roleDefinitionPath)) {
			if ($roleDefinitionPath -notmatch '\?api-version=') {
				$separator = if ($roleDefinitionPath.Contains('?')) { '&' } else { '?' }
				$roleDefinitionPath = "$roleDefinitionPath${separator}api-version=2022-04-01"
			}

			try {
				$roleDefinitionResponse = Invoke-ArmRequest -Path $roleDefinitionPath -Method GET -ErrorAction Stop
				$roleDefinitionContent = if ($roleDefinitionResponse.Content) { $roleDefinitionResponse.Content | ConvertFrom-Json } else { $null }
				$resolvedName = if ($roleDefinitionContent -and $roleDefinitionContent.properties -and $roleDefinitionContent.properties.PSObject.Properties['roleName']) {
					[string]$roleDefinitionContent.properties.roleName
				}
				elseif ($roleDefinitionContent -and $roleDefinitionContent.PSObject.Properties['name']) {
					[string]$roleDefinitionContent.name
				}
				else {
					$RoleDefinitionId
				}
				$RoleDefinitionMap[$RoleDefinitionId] = $resolvedName
				return $resolvedName
			}
			catch { }
		}

		$RoleDefinitionMap[$RoleDefinitionId] = $RoleDefinitionId
		return $RoleDefinitionId
	}

	function Get-AssignmentScopeKind {
		param(
			[Parameter(Mandatory = $false)]
			[string]$Scope,

			[Parameter(Mandatory = $true)]
			[string]$SubscriptionId
		)

		$subscriptionScope = "/subscriptions/$SubscriptionId"
		if ([string]::IsNullOrWhiteSpace($Scope)) {
			return 'Unknown'
		}
		if ($Scope -ieq $subscriptionScope) {
			return 'Subscription'
		}
		if ($Scope -match '^/providers/Microsoft\.Management/managementGroups/[^/]+$') {
			return 'ManagementGroup'
		}
		if ($Scope -match "^$([regex]::Escape($subscriptionScope))/resourceGroups/[^/]+$") {
			return 'ResourceGroup'
		}
		if ($Scope -match "^$([regex]::Escape($subscriptionScope))/resourceGroups/[^/]+/.+") {
			return 'Resource'
		}
		return 'Other'
	}

	function Get-AssignmentScopeDisplayName {
		param(
			[Parameter(Mandatory = $false)]
			[string]$Scope,

			[Parameter(Mandatory = $true)]
			[string]$ScopeKind
		)

		if ([string]::IsNullOrWhiteSpace($Scope)) {
			return 'Unknown'
		}

		switch ($ScopeKind) {
			'ManagementGroup' {
				if ($Scope -match '^/providers/Microsoft\.Management/managementGroups/([^/]+)$') {
					return $Matches[1]
				}
				break
			}
			'ResourceGroup' {
				if ($Scope -match '/resourceGroups/([^/]+)$') {
					return $Matches[1]
				}
				break
			}
			'Resource' {
				$segments = @($Scope.Trim('/') -split '/')
				if ($segments.Count -gt 0) {
					return $segments[-1]
				}
				break
			}
		}

		return $Scope
	}

	function New-AccessEntry {
		param(
			[Parameter(Mandatory = $true)]
			$Assignment,

			[Parameter(Mandatory = $true)]
			[string]$SubscriptionId,

			[Parameter(Mandatory = $true)]
			[hashtable]$RoleDefinitionMap
		)

		$scope = [string]$Assignment.properties.scope
		$scopeKind = Get-AssignmentScopeKind -Scope $scope -SubscriptionId $SubscriptionId
		$roleDefinitionId = [string]$Assignment.properties.roleDefinitionId
		$roleName = Resolve-RoleDefinitionName -RoleDefinitionId $roleDefinitionId -RoleDefinitionMap $RoleDefinitionMap
		[PSCustomObject]@{
			RoleName          = $roleName
			Scope             = $scope
			ScopeKind         = $scopeKind
			ScopeDisplayName  = Get-AssignmentScopeDisplayName -Scope $scope -ScopeKind $scopeKind
			PrincipalType     = if ($Assignment.properties.PSObject.Properties['principalType']) { [string]$Assignment.properties.principalType } else { $null }
			AssignmentId      = if ($Assignment.PSObject.Properties['id']) { [string]$Assignment.id } else { $null }
			AssignmentName    = if ($Assignment.PSObject.Properties['name']) { [string]$Assignment.name } else { $null }
			RoleDefinitionId  = $roleDefinitionId
		}
	}

	$results = [System.Collections.Generic.List[object]]::new()

	foreach ($subscription in @($Subscriptions)) {
		try {
			$roleDefinitionMap = @{}
			$roleDefinitions = Get-ArmPagedItems -Path "/subscriptions/$($subscription.Id)/providers/Microsoft.Authorization/roleDefinitions?api-version=2022-04-01"
			foreach ($roleDefinition in @($roleDefinitions)) {
				$roleName = if ($roleDefinition.properties -and $roleDefinition.properties.PSObject.Properties['roleName']) {
					[string]$roleDefinition.properties.roleName
				}
				else {
					[string]$roleDefinition.name
				}
				$roleDefinitionMap[[string]$roleDefinition.id] = $roleName
			}

			$assignmentPath = if ($PrincipalType -eq 'User') {
				"/subscriptions/$($subscription.Id)/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=assignedTo('$PrincipalObjectId')"
			}
			else {
				"/subscriptions/$($subscription.Id)/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=principalId eq '$PrincipalObjectId'"
			}

			$assignments = @()
			try {
				$assignments = @(Get-ArmPagedItems -Path $assignmentPath)
			}
			catch {
				if ($PrincipalType -eq 'User') {
					$assignments = @(Get-ArmPagedItems -Path "/subscriptions/$($subscription.Id)/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=principalId eq '$PrincipalObjectId'")
				}
				else {
					throw
				}
			}

			$accessEntries = @($assignments | ForEach-Object { New-AccessEntry -Assignment $_ -SubscriptionId ([string]$subscription.Id) -RoleDefinitionMap $roleDefinitionMap })
			$directSubscriptionAssignments = @($accessEntries | Where-Object { $_.ScopeKind -eq 'Subscription' })
			$inheritedAssignments = @($accessEntries | Where-Object { $_.ScopeKind -eq 'ManagementGroup' })
			$lowerScopeAssignments = @($accessEntries | Where-Object { $_.ScopeKind -in @('ResourceGroup', 'Resource') })
			$otherAssignments = @($accessEntries | Where-Object { $_.ScopeKind -notin @('Subscription', 'ManagementGroup', 'ResourceGroup', 'Resource') })

			$allRoleNames = @($accessEntries | ForEach-Object { $_.RoleName } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
			$directRoleNames = @($directSubscriptionAssignments | ForEach-Object { $_.RoleName } | Sort-Object -Unique)
			$inheritedRoleNames = @($inheritedAssignments | ForEach-Object { $_.RoleName } | Sort-Object -Unique)
			$lowerScopeRoleNames = @($lowerScopeAssignments | ForEach-Object { $_.RoleName } | Sort-Object -Unique)

			$results.Add([PSCustomObject]@{
				SubscriptionId                  = [string]$subscription.Id
				SubscriptionName                = [string]$subscription.Name
				EffectiveRoleNames              = $allRoleNames
				EffectiveRoleCount              = @($allRoleNames).Count
				DirectSubscriptionRoleNames     = $directRoleNames
				DirectSubscriptionRoleCount     = @($directRoleNames).Count
				InheritedRoleNames              = $inheritedRoleNames
				InheritedRoleCount              = @($inheritedRoleNames).Count
				LowerScopeRoleNames             = $lowerScopeRoleNames
				LowerScopeRoleCount             = @($lowerScopeRoleNames).Count
				DirectSubscriptionAssignments   = $directSubscriptionAssignments
				InheritedAssignments            = $inheritedAssignments
				LowerScopeAssignments           = $lowerScopeAssignments
				OtherAssignments                = $otherAssignments
				Status                          = if (@($accessEntries).Count -gt 0) { 'OK' } else { 'NoAssignmentsDetected' }
			}) | Out-Null
		}
		catch {
			$results.Add([PSCustomObject]@{
				SubscriptionId                  = [string]$subscription.Id
				SubscriptionName                = [string]$subscription.Name
				EffectiveRoleNames              = @()
				EffectiveRoleCount              = 0
				DirectSubscriptionRoleNames     = @()
				DirectSubscriptionRoleCount     = 0
				InheritedRoleNames              = @()
				InheritedRoleCount              = 0
				LowerScopeRoleNames             = @()
				LowerScopeRoleCount             = 0
				DirectSubscriptionAssignments   = @()
				InheritedAssignments            = @()
				LowerScopeAssignments           = @()
				OtherAssignments                = @()
				Status                          = "Error: $($_.Exception.Message)"
			}) | Out-Null
		}
	}

	return @($results)
}

function Get-AuthenticatedIdentitySummary {
	param(
		[Parameter(Mandatory = $true)]
		$AzContext,

		[Parameter(Mandatory = $true)]
		[object[]]$Subscriptions,

		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[string]$GraphToken
	)

	$accountId = if ($AzContext.Account) { [string]$AzContext.Account.Id } else { $null }
	$accountType = if ($AzContext.Account -and $AzContext.Account.PSObject.Properties['Type']) { [string]$AzContext.Account.Type } else { $null }
	$tenantId = if ($AzContext.Tenant) { [string]$AzContext.Tenant.Id } else { $null }
	$environmentName = if ($AzContext.Environment) { [string]$AzContext.Environment.Name } else { $null }
	$defaultSubscriptionName = if ($AzContext.Subscription) { [string]$AzContext.Subscription.Name } else { $null }
	$defaultSubscriptionId = if ($AzContext.Subscription) { [string]$AzContext.Subscription.Id } else { $null }

	$principalType = if ($accountType -match '(?i)serviceprincipal') {
		'ServicePrincipal'
	}
	elseif ($accountType -match '(?i)user') {
		'User'
	}
	else {
		$accountType
	}

	$identity = [ordered]@{
		AccountId                 = $accountId
		AccountType               = $accountType
		PrincipalType             = $principalType
		TenantId                  = $tenantId
		Environment               = $environmentName
		DefaultSubscriptionId     = $defaultSubscriptionId
		DefaultSubscriptionName   = $defaultSubscriptionName
		DisplayName               = $accountId
		UserPrincipalName         = $accountId
		UserType                  = $null
		PrincipalObjectId         = $null
		GraphStatus               = if ([string]::IsNullOrWhiteSpace($GraphToken)) { 'NoGraphToken' } else { 'Pending' }
		DirectoryRoleStatus       = 'NotRequested'
		DirectoryRoles            = @()
		IsGlobalAdministrator     = $null
		SubscriptionAccess        = @()
		SubscriptionAccessStatus  = 'NotRequested'
	}

	if (-not [string]::IsNullOrWhiteSpace($GraphToken)) {
		try {
			if ($principalType -eq 'User') {
				$me = Invoke-GraphGet -Uri "https://graph.microsoft.com/v1.0/me?`$select=id,displayName,userPrincipalName,userType" -GraphToken $GraphToken
				if ($me) {
					$identity.DisplayName = if ($me.PSObject.Properties['displayName']) { [string]$me.displayName } else { $identity.DisplayName }
					$identity.UserPrincipalName = if ($me.PSObject.Properties['userPrincipalName']) { [string]$me.userPrincipalName } else { $identity.UserPrincipalName }
					$identity.UserType = if ($me.PSObject.Properties['userType']) { [string]$me.userType } else { $null }
					$identity.PrincipalObjectId = if ($me.PSObject.Properties['id']) { [string]$me.id } else { $null }
					$identity.GraphStatus = 'OK'
				}
				else {
					$identity.GraphStatus = 'GraphQueryFailed'
				}
			}
			elseif ($principalType -eq 'ServicePrincipal' -and -not [string]::IsNullOrWhiteSpace($accountId)) {
				$spUri = "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$accountId'&`$select=id,appId,displayName,servicePrincipalType"
				$spResp = Invoke-GraphGet -Uri $spUri -GraphToken $GraphToken
				$servicePrincipal = if ($spResp -and $spResp.PSObject.Properties['value'] -and @($spResp.value).Count -gt 0) { @($spResp.value)[0] } else { $null }
				if ($servicePrincipal) {
					$identity.DisplayName = if ($servicePrincipal.PSObject.Properties['displayName']) { [string]$servicePrincipal.displayName } else { $identity.DisplayName }
					$identity.PrincipalObjectId = if ($servicePrincipal.PSObject.Properties['id']) { [string]$servicePrincipal.id } else { $null }
					$identity.GraphStatus = 'OK'
				}
				else {
					$identity.GraphStatus = 'GraphQueryFailed'
				}
			}
			else {
				$identity.GraphStatus = 'UnsupportedPrincipalType'
			}

			if (-not [string]::IsNullOrWhiteSpace($identity.PrincipalObjectId) -and $principalType -in @('User', 'ServicePrincipal')) {
				$directoryRoleSummary = Get-PrincipalDirectoryRoleSummary -PrincipalObjectId $identity.PrincipalObjectId -PrincipalType $principalType -GraphToken $GraphToken
				$identity.DirectoryRoleStatus = $directoryRoleSummary.Status
				$identity.DirectoryRoles = $directoryRoleSummary.Roles
				$identity.IsGlobalAdministrator = @($directoryRoleSummary.Roles | Where-Object { $_ -in @('Global Administrator', 'Company Administrator') }).Count -gt 0
			}
			elseif ($identity.GraphStatus -eq 'OK') {
				$identity.DirectoryRoleStatus = 'Unavailable'
			}
		}
		catch {
			$identity.GraphStatus = "Error: $($_.Exception.Message)"
			$identity.DirectoryRoleStatus = 'Unavailable'
		}
	}

	if (-not [string]::IsNullOrWhiteSpace($identity.PrincipalObjectId)) {
		$identity.SubscriptionAccess = Get-PrincipalSubscriptionAccessSummary -Subscriptions $Subscriptions -PrincipalObjectId $identity.PrincipalObjectId -PrincipalType $principalType
		$identity.SubscriptionAccessStatus = 'OK'
	}
	else {
		$identity.SubscriptionAccessStatus = 'PrincipalObjectIdUnavailable'
	}

	return [PSCustomObject]$identity
}

function Write-AuthenticatedIdentitySummary {
	param(
		[Parameter(Mandatory = $true)]
		$Identity
	)

	Write-Rule 'AUTHENTICATION CONTEXT'
	Write-Host "  Account            :  $($Identity.AccountId)" -ForegroundColor DarkGray
	Write-Host "  Display Name       :  $($Identity.DisplayName)" -ForegroundColor DarkGray
	Write-Host "  Principal Type     :  $($Identity.PrincipalType)" -ForegroundColor DarkGray
	if (-not [string]::IsNullOrWhiteSpace([string]$Identity.UserPrincipalName) -and $Identity.UserPrincipalName -ne $Identity.AccountId) {
		Write-Host "  User Principal     :  $($Identity.UserPrincipalName)" -ForegroundColor DarkGray
	}
	if (-not [string]::IsNullOrWhiteSpace([string]$Identity.UserType)) {
		Write-Host "  User Type          :  $($Identity.UserType)" -ForegroundColor DarkGray
	}
	if (-not [string]::IsNullOrWhiteSpace([string]$Identity.PrincipalObjectId)) {
		Write-Host "  Principal ObjectId :  $($Identity.PrincipalObjectId)" -ForegroundColor DarkGray
	}
	Write-Host "  Tenant             :  $($Identity.TenantId)" -ForegroundColor DarkGray
	Write-Host "  Environment        :  $($Identity.Environment)" -ForegroundColor DarkGray
	Write-Host "  Default Context    :  $($Identity.DefaultSubscriptionName) [$($Identity.DefaultSubscriptionId)]" -ForegroundColor DarkGray

	$globalAdminText = if ($null -eq $Identity.IsGlobalAdministrator) {
		"Unknown ($($Identity.DirectoryRoleStatus))"
	}
	elseif ($Identity.IsGlobalAdministrator) {
		'Yes'
	}
	else {
		'No'
	}
	Write-Host "  Global Admin       :  $globalAdminText" -ForegroundColor DarkGray

	$directoryRoleText = if (@($Identity.DirectoryRoles).Count -gt 0) {
		$Identity.DirectoryRoles -join ', '
	}
	else {
		"None detected ($($Identity.DirectoryRoleStatus))"
	}
	Write-Host "  Directory Roles    :  $directoryRoleText" -ForegroundColor DarkGray

	foreach ($subscriptionAccess in @($Identity.SubscriptionAccess)) {
		$effectiveRoleText = if (@($subscriptionAccess.EffectiveRoleNames).Count -gt 0) {
			$subscriptionAccess.EffectiveRoleNames -join ', '
		}
		elseif ($subscriptionAccess.Status -like 'Error:*') {
			$subscriptionAccess.Status
		}
		else {
			'No RBAC assignments detected at this subscription or below'
		}

		$directRoleText = if (@($subscriptionAccess.DirectSubscriptionRoleNames).Count -gt 0) {
			$subscriptionAccess.DirectSubscriptionRoleNames -join ', '
		}
		else {
			'None detected'
		}

		$inheritedRoleText = if (@($subscriptionAccess.InheritedRoleNames).Count -gt 0) {
			$subscriptionAccess.InheritedRoleNames -join ', '
		}
		else {
			'None detected'
		}

		$lowerScopeDetail = if (@($subscriptionAccess.LowerScopeAssignments).Count -gt 0) {
			$preview = @($subscriptionAccess.LowerScopeAssignments | Select-Object -First 4 | ForEach-Object {
				"$($_.RoleName) [$($_.ScopeKind): $($_.ScopeDisplayName)]"
			})
			$summary = $preview -join '; '
			if (@($subscriptionAccess.LowerScopeAssignments).Count -gt $preview.Count) {
				"$summary (+$(@($subscriptionAccess.LowerScopeAssignments).Count - $preview.Count) more)"
			}
			else {
				$summary
			}
		}
		else {
			'None detected'
		}

		Write-Host "  Subscription       :  $($subscriptionAccess.SubscriptionName) [$($subscriptionAccess.SubscriptionId)]" -ForegroundColor DarkGray
		Write-Host "    Effective Roles  :  $effectiveRoleText" -ForegroundColor DarkGray
		Write-Host "    Direct Scope     :  $directRoleText" -ForegroundColor DarkGray
		Write-Host "    Inherited        :  $inheritedRoleText" -ForegroundColor DarkGray
		Write-Host "    Lower Scopes     :  $lowerScopeDetail" -ForegroundColor DarkGray
	}
	Write-Host ''
}

function Get-CloudKerberosTrustStatus {
	<#
	.SYNOPSIS
	Queries the Graph Beta endpoint for on-premises directory sync configuration and
	returns whether Cloud Kerberos Trust (AzureADKerberos) is configured in the tenant.
	Returns a structured object with Configured (bool|null), ServiceAccount details,
	and a Status string. Null Configured means the call failed or was inconclusive.
	#>
	param(
		[Parameter(Mandatory = $true)]
		[string]$GraphToken
	)

	$uri  = 'https://graph.microsoft.com/beta/directory/onPremisesDirectorySynchronization'
	$resp = Invoke-GraphGet -Uri $uri -GraphToken $GraphToken

	if ($null -eq $resp) {
		return [PSCustomObject]@{
			Configured     = $null
			ServiceAccount = $null
			Status         = 'GraphCallFailed'
		}
	}

	# The kerberosSignOnSettings property is only present when AzureADKerberos
	# has been configured via Set-AzureADKerberosServer / Set-AADKerberosServer.
	$kerb = $null
	try {
		# Response may be a single object or a value array depending on tenant config
		$target = if ($resp.PSObject.Properties['value'] -and $resp.value) { $resp.value[0] } else { $resp }
		if ($target.PSObject.Properties['configuration'] -and
		    $target.configuration.PSObject.Properties['kerberosSignOnSettings']) {
			$kerb = $target.configuration.kerberosSignOnSettings
		}
	}
	catch { }

	if ($null -ne $kerb) {
		return [PSCustomObject]@{
			Configured     = $true
			ServiceAccount = if ($kerb.PSObject.Properties['kerberosServiceAccountName']) { $kerb.kerberosServiceAccountName } else { $null }
			Status         = 'Configured'
		}
	}

	# Sync config was returned but no kerberos block — not configured
	return [PSCustomObject]@{
		Configured     = $false
		ServiceAccount = $null
		Status         = 'NotConfigured'
	}
}

function Get-GroupTransitiveMemberUserIds {
	<#
	.SYNOPSIS
	Returns a HashSet of all transitive user member object IDs for an Entra ID group,
	handles pagination via @odata.nextLink.
	#>
	param(
		[Parameter(Mandatory = $true)]
		[string]$GroupObjectId,

		[Parameter(Mandatory = $true)]
		[string]$GraphToken
	)

	$userIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	# /transitiveMembers/microsoft.graph.user already filters to user objects only
	$uri = "https://graph.microsoft.com/v1.0/groups/$GroupObjectId/transitiveMembers/microsoft.graph.user?`$select=id&`$top=999"

	do {
		$resp = Invoke-GraphGet -Uri $uri -GraphToken $GraphToken
		if (-not $resp) { break }
		foreach ($member in $resp.value) { $userIds.Add($member.id) | Out-Null }
		$uri = if ($resp.PSObject.Properties['@odata.nextLink']) { $resp.'@odata.nextLink' } else { $null }
	} while (-not [string]::IsNullOrEmpty($uri))

	return $userIds
}

function Get-ArmPagedItems {
	<#
	.SYNOPSIS
	Fetches all items from an ARM list endpoint, following nextLink pages when present.
	#>
	param(
		[Parameter(Mandatory = $true)]
		[string]$Path
	)

	$items    = [System.Collections.Generic.List[object]]::new()
	$nextPath = $Path

	do {
		$response = Invoke-ArmRequest -Path $nextPath -Method GET -ErrorAction Stop
		$content  = if ($response.Content) { $response.Content | ConvertFrom-Json } else { $null }

		if ($content -and $content.PSObject.Properties['value'] -and $content.value) {
			foreach ($item in @($content.value)) { $items.Add($item) | Out-Null }
		}

		$nextLink = $null
		if ($content) {
			if ($content.PSObject.Properties['nextLink'] -and $content.nextLink) {
				$nextLink = [string]$content.nextLink
			}
			elseif ($content.PSObject.Properties['@odata.nextLink'] -and $content.'@odata.nextLink') {
				$nextLink = [string]$content.'@odata.nextLink'
			}
		}

		if (-not [string]::IsNullOrWhiteSpace($nextLink)) {
			$nextPath = $nextLink -replace '^https://management\.azure\.com', ''
		}
		else {
			$nextPath = $null
		}
	} while (-not [string]::IsNullOrWhiteSpace($nextPath))

	return @($items)
}

function Get-HostPoolAuthorizedUsers {
	<#
	.SYNOPSIS
	Returns the count and detail of users authorized to access a host pool via the
	'Desktop Virtualization User' RBAC role on its app group(s).

	.DESCRIPTION
	Steps:
	  1. Locates the host pool's app groups from the subscription-level cache
	     (matched by hostPoolArmPath).
	  2. Identifies the AVD workspace(s) that reference those app groups (for context).
	  3. Reads all RBAC role assignments on the app groups, keeping only those with the
	     'Desktop Virtualization User' role (GUID 1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63).
	  4. For Group principals: resolves their display name via Graph and expands transitive
	     user membership for the overall count, deduplicating users across groups.
	  5. For directly-assigned User principals: resolves their UPN via Graph.
	  6. Returns AccessAssignments (groups by display name, direct users by UPN) plus the
	     total unique authorized user count.

	AuthorizedUserStatus values:
	  OK                         — count and assignments are complete
	  NoAppGroups                — no app groups found linked to this host pool
	  NoAssignments              — app groups exist but no Desktop Virtualization User
	                               role assignments were found
	  GroupsFoundButNoGraphToken — group assignments found but Graph token unavailable;
	                               count reflects only direct user assignments
	  OKWithErrors               — some role assignment queries failed; count may be
	                               an undercount
	#>
	param(
		[Parameter(Mandatory = $true)]
		[PSCustomObject]$HostPool,

		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[AllowEmptyString()]
		[string]$GraphToken,

		[Parameter(Mandatory = $true)]
		[hashtable]$AppGroupCache,

		[Parameter(Mandatory = $true)]
		[hashtable]$WorkspaceCache
	)

	# 1. App groups for this host pool
	$appGroups = @(
		$AppGroupCache[$HostPool.SubscriptionId] | Where-Object {
			$_.properties.hostPoolArmPath -ieq $HostPool.ResourceId
		}
	)

	if ($appGroups.Count -eq 0) {
		return [PSCustomObject]@{
			AuthorizedUserCount  = $null
			AuthorizedUserIds    = @()
			WorkspaceNames       = @()
			AppGroupNames        = @()
			AppGroupDetails      = @()
			AccessAssignments    = @()
			AuthorizedUserStatus = 'NoAppGroups'
		}
	}

	$appGroupNames = @($appGroups | ForEach-Object { $_.name })
	$appGroupIds   = @($appGroups | ForEach-Object { $_.id.ToLowerInvariant() })

	# 2. Workspaces referencing these app groups (for context only)
	$workspaceNames = @(
		$WorkspaceCache[$HostPool.SubscriptionId] | Where-Object {
			$refs = @($_.properties.applicationGroupReferences | ForEach-Object { $_.ToLowerInvariant() })
			@($refs | Where-Object { $_ -in $appGroupIds }).Count -gt 0
		} | ForEach-Object { $_.name }
	)

	# 2b. App group types and published RemoteApp applications
	$appGroupDetails = @($appGroups | ForEach-Object {
		$agProps = $_.properties
		$agType  = if ($agProps.PSObject.Properties['applicationGroupType']) { $agProps.applicationGroupType } else { 'Unknown' }
		$apps    = @()
		if ($agType -eq 'RemoteApp') {
			try {
				$appsPath = "$($_.id)/applications?api-version=2023-09-05"
				$appsResp = Invoke-ArmRequest -Path $appsPath -Method GET -ErrorAction SilentlyContinue
				if ($appsResp -and $appsResp.StatusCode -eq 200) {
					$apps = @(($appsResp.Content | ConvertFrom-Json).value | ForEach-Object {
						$appProps = $_.properties
						[PSCustomObject]@{
							Name            = $_.name -replace '^.*/', ''
							FriendlyName    = if ($appProps.PSObject.Properties['friendlyName']) { $appProps.friendlyName } else { $null }
							FilePath        = if ($appProps.PSObject.Properties['filePath'])     { $appProps.filePath }     else { $null }
							CommandLineArgs = if ($appProps.PSObject.Properties['commandLineSetting'] -and $appProps.commandLineSetting -ne 'DoNotAllow' -and $appProps.PSObject.Properties['commandLineArguments']) { $appProps.commandLineArguments } else { $null }
						}
					})
				}
			} catch { <# Non-fatal — leave apps empty #> }
		}
		[PSCustomObject]@{
			Name = $_.name
			Type = $agType
			Applications = $apps
		}
	})

	# Desktop Virtualization User role definition GUID
	$dvUserRoleGuid = '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63'

	# 3. Gather role assignments across all app groups
	# Separate tracking: direct user IDs (for UPN lookup) and group IDs (for display name + expansion)
	$directUserIds  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	$directGroupIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	$hadErrors      = $false

	foreach ($ag in $appGroups) {
		try {
			$raPath = "$($ag.id)/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01"
			$assignments = Get-ArmPagedItems -Path $raPath | Where-Object {
				$roleDefinitionId = [string]$_.properties.roleDefinitionId
				-not [string]::IsNullOrWhiteSpace($roleDefinitionId) -and $roleDefinitionId.ToLowerInvariant().Contains($dvUserRoleGuid)
			}
			foreach ($ra in $assignments) {
				$principalType = [string]$ra.properties.principalType
				switch -Regex ($principalType) {
					'(?i)user$'  { $directUserIds.Add($ra.properties.principalId)  | Out-Null; break }
					'(?i)group$' { $directGroupIds.Add($ra.properties.principalId) | Out-Null; break }
				}
			}
		}
		catch { $hadErrors = $true }
	}

	# 4. Build AccessAssignments — groups by display name, direct users by UPN
	$accessAssignments = [System.Collections.Generic.List[PSCustomObject]]::new()

	# Groups: resolve display name via Graph, expand membership for count
	$uniqueUserIds     = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	$groupsWithNoGraph = $false

	foreach ($gId in $directGroupIds) {
		$displayName = $gId  # fallback to object ID if Graph unavailable
		if (-not [string]::IsNullOrEmpty($GraphToken)) {
			$grp = Invoke-GraphGet -Uri "https://graph.microsoft.com/v1.0/groups/$gId`?`$select=id,displayName" -GraphToken $GraphToken
			if ($grp -and $grp.PSObject.Properties['displayName'] -and $grp.displayName) { $displayName = $grp.displayName }

			# Expand members into the overall unique user count
			$memberIds = Get-GroupTransitiveMemberUserIds -GroupObjectId $gId -GraphToken $GraphToken
			foreach ($id in $memberIds) { $uniqueUserIds.Add($id) | Out-Null }
		}
		else {
			$groupsWithNoGraph = $true
		}
		$accessAssignments.Add([PSCustomObject]@{ Type = 'Group'; DisplayName = $displayName })
	}

	# Direct users: add to unique count and resolve UPN via Graph
	foreach ($uId in $directUserIds) {
		$uniqueUserIds.Add($uId) | Out-Null
		$upn = $uId  # fallback to object ID
		if (-not [string]::IsNullOrEmpty($GraphToken)) {
			$usr = Invoke-GraphGet -Uri "https://graph.microsoft.com/v1.0/users/$uId`?`$select=id,userPrincipalName" -GraphToken $GraphToken
			if ($usr -and $usr.PSObject.Properties['userPrincipalName'] -and $usr.userPrincipalName) { $upn = $usr.userPrincipalName }
		}
		$accessAssignments.Add([PSCustomObject]@{ Type = 'User'; UPN = $upn })
	}

	$status = if     ($hadErrors)                    { 'OKWithErrors' }
	          elseif ($groupsWithNoGraph)             { 'GroupsFoundButNoGraphToken' }
	          elseif ($uniqueUserIds.Count -eq 0 -and $accessAssignments.Count -eq 0) { 'NoAssignments' }
	          else                                    { 'OK' }

	return [PSCustomObject]@{
		AuthorizedUserCount  = $uniqueUserIds.Count
		AuthorizedUserIds    = @($uniqueUserIds)
		WorkspaceNames       = $workspaceNames
		AppGroupNames        = $appGroupNames
		AppGroupDetails      = $appGroupDetails
		AccessAssignments    = @($accessAssignments)
		AuthorizedUserStatus = $status
	}
}

# ------------------------------------------------------------------
# Licence discovery
# ------------------------------------------------------------------

function Get-UserLicenseSummary {
	<#
	.SYNOPSIS
	Returns an aggregate count of Microsoft 365 licence SKUs assigned across a set
	of Entra ID users. Queries Microsoft Graph in batches of 20 using the batch API.

	.DESCRIPTION
	For each unique user object ID supplied, queries /users/{id}/licenseDetails via
	the Graph batch endpoint and aggregates results into a list of distinct SKUs with
	a count of how many of the supplied users hold each SKU. Also identifies users
	who hold no AVD-eligible licence (no Windows 10/11 Enterprise or equivalent)
	and resolves their UPNs for individual reporting.

	LicenseSummaryStatus values:
	  OK              — at least one licence SKU found across the supplied users
	  NoLicensesFound — users were queried but no licence assignments were returned
	  NoUsers         — the supplied user list was empty
	  NoGraphToken    — no Graph token available; query skipped
	#>
	param(
		[Parameter(Mandatory = $true)]
		[AllowEmptyCollection()]
		[string[]]$UserObjectIds,

		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[AllowEmptyString()]
		[string]$GraphToken,

		# Hashtable of SkuPartNumber (String_Id) -> Product_Display_Name loaded from ms-service-plan-ids.csv
		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[hashtable]$SkuDisplayNameMap = $null
	)

	if ([string]::IsNullOrEmpty($GraphToken)) {
		return [PSCustomObject]@{
			LicenseSummary        = @()
			LicenseSummaryStatus  = 'NoGraphToken'
			UnlicensedUserCount   = $null
			UnlicensedUsers       = @()
		}
	}

	$uniqueIds = @($UserObjectIds | Select-Object -Unique)
	if ($uniqueIds.Count -eq 0) {
		return [PSCustomObject]@{
			LicenseSummary        = @()
			LicenseSummaryStatus  = 'NoUsers'
			UnlicensedUserCount   = 0
			UnlicensedUsers       = @()
		}
	}

	# SKU part numbers that grant access to Azure Virtual Desktop (Windows 10/11 Enterprise
	# or equivalent). Windows 365 (CPC_* prefix) is matched separately.
	# Source: https://learn.microsoft.com/en-us/azure/virtual-desktop/prerequisites
	$avdEligibleSkus = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	@(
		'SPE_E3',                     # Microsoft 365 E3
		'SPE_E3_RPA1',                # Microsoft 365 E3 - Unattended
		'SPE_E3_USGOV_DOD',           # Microsoft 365 E3 (GovDoD)
		'SPE_E3_USGOV_GCCHIGH',       # Microsoft 365 E3 (GCC High)
		'SPE_E5',                     # Microsoft 365 E5
		'SPE_E5_CALLINGMINUTES',       # Microsoft 365 E5 with Calling Minutes
		'SPE_E5_NOPSTNCONF',          # Microsoft 365 E5 without Audio Conferencing
		'SPE_E5_USGOV_GCCHIGH',       # Microsoft 365 E5 (GCC High)
		'SPE_F1',                     # Microsoft 365 F3
		'SPB',                        # Microsoft 365 Business Premium
		'M365EDU_A3_FACULTY',         # Microsoft 365 A3 for Faculty
		'M365EDU_A3_STUDENT',         # Microsoft 365 A3 for Students
		'M365EDU_A3_STUUSEBNFT',      # Microsoft 365 A3 (student use benefit)
		'M365EDU_A5_FACULTY',         # Microsoft 365 A5 for Faculty
		'M365EDU_A5_STUDENT',         # Microsoft 365 A5 for Students
		'M365EDU_A5_STUUSEBNFT',      # Microsoft 365 A5 (student use benefit)
		'M365EDU_A5_NOPSTNCONF_STUUSEBNFT',  # Microsoft 365 A5 without Audio Conferencing (student)
		'M365_G3_GOV',                # Microsoft 365 G3 GCC
		'M365_G3_RPA1_GOV',           # Microsoft 365 G3 Unattended (GCC)
		'M365_G5_GCC',                # Microsoft 365 G5 GCC
		'M365_G5_GOV',                # Microsoft 365 G5 (GCC w/o WDATP)
		'WIN10_VDA_E3',               # Windows 10/11 Enterprise E3
		'WIN10_VDA_E5',               # Windows 10/11 Enterprise E5
		'WIN10_PRO_ENT_SUB',          # Windows 10/11 Enterprise E3 (subscription)
		'WIN_ENT_E5',                 # Windows 10/11 Enterprise E5 (original)
		'WINE5_GCC_COMPAT',           # Windows 10/11 Enterprise E5 Commercial (GCC)
		'E3_VDA_only'                 # Windows 10/11 Enterprise E3 VDA
	) | ForEach-Object { $avdEligibleSkus.Add($_) | Out-Null }

	# SKUs reported in the licence summary — AVD access licences (above) plus standalone
	# application licences commonly deployed on AVD hosts. Windows 365 (CPC_*) is included
	# via prefix match at filter time. Broad suite SKUs (SPE_*, SPB, M365*) are already in
	# $avdEligibleSkus and therefore automatically included.
	$reportableSkus = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	# -- All AVD access entitlement SKUs (copy from above) --
	$avdEligibleSkus | ForEach-Object { $reportableSkus.Add($_) | Out-Null }
	# -- Microsoft 365 Apps / Office suites --
	@(
		'O365_BUSINESS_PREMIUM',      # Microsoft 365 Business Standard
		'SMB_BUSINESS_PREMIUM',       # Microsoft 365 Business Standard (legacy)
		'O365_BUSINESS_ESSENTIALS',   # Microsoft 365 Business Basic
		'O365_BUSINESS',              # Microsoft 365 Apps for Business
		'OFFICESUBSCRIPTION',         # Microsoft 365 Apps for Enterprise
		'OFFICE_PRO_PLUS_SUBSCRIPTION', # Office 365 ProPlus
		'ENTERPRISEPACK',             # Office 365 E3
		'ENTERPRISEPREMIUM',          # Office 365 E5
		'ENTERPRISEPACKWITHOUTPROPLUS', # Office 365 E3 without ProPlus
		'DESKLESSPACK',               # Office 365 F3
		'STANDARDPACK',               # Office 365 E1
		'STANDARDWOFFPACK',           # Office 365 E2
		# -- Visio --
		'VISIOCLIENT',                # Visio Plan 2
		'VISIOONLINE_PLAN1',          # Visio Plan 1
		'VISIO_PLAN1_DEPT',           # Visio Plan 1 (departmental)
		'VISIO_PLAN2_DEPT',           # Visio Plan 2 (departmental)
		# -- Project --
		'PROJECTPREMIUM',             # Project Plan 5
		'PROJECTPROFESSIONAL',        # Project Plan 3
		'PROJECTESSENTIALS',          # Project Plan 1
		'PROJECT_P1',                 # Project Plan 1 (new SKU)
		'PROJECT_P3_DEPT',            # Project Plan 3 (departmental)
		'PROJECT_P5_DEPT',            # Project Plan 5 (departmental)
		# -- Power BI --
		'POWER_BI_PRO',               # Power BI Pro
		'POWER_BI_PREMIUM_P1_ADDON',  # Power BI Premium P1 add-on
		'PBI_PREMIUM_P1_ADDON',       # Power BI Premium P1 (alt SKU)
		# -- Intune / endpoint management --
		'INTUNE_A',                   # Microsoft Intune
		'INTUNE_A_D',                 # Microsoft Intune (device)
		'EMS',                        # Enterprise Mobility + Security E3
		'EMSPREMIUM',                 # Enterprise Mobility + Security E5
		# -- Defender / security --
		'WIN_DEF_ATP',                # Microsoft Defender for Endpoint P2
		'MDATP_XPLAT',                # Microsoft Defender for Endpoint (cross-platform)
		'Microsoft_Defender_for_Individuals', # Defender for Individuals
		# -- Azure Virtual Desktop add-ons --
		'WVDA_ST_P1',                 # Azure Virtual Desktop Store
		'WVDA_ST_P2'                  # Azure Virtual Desktop Store P2
	) | ForEach-Object { $reportableSkus.Add($_) | Out-Null }

	$skuCounts       = @{}  # skuPartNumber -> PSCustomObject { SkuPartNumber, SkuId, ProductName, UserCount }
	$licensedUserIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	$batchSize       = 20
	$batchUri        = 'https://graph.microsoft.com/v1.0/$batch'

	for ($i = 0; $i -lt $uniqueIds.Count; $i += $batchSize) {
		$hi    = [Math]::Min($i + $batchSize - 1, $uniqueIds.Count - 1)
		$chunk = $uniqueIds[$i..$hi]

		$requests = for ($j = 0; $j -lt $chunk.Count; $j++) {
			@{
				id     = "$($j + 1)"
				method = 'GET'
				url    = "/users/$($chunk[$j])/licenseDetails?`$select=skuId,skuPartNumber"
			}
		}

		$batchBody = @{ requests = $requests } | ConvertTo-Json -Depth 4 -Compress
		try {
			$batchResp = Invoke-RestMethod -Uri $batchUri -Method POST `
				-Headers @{ Authorization = "Bearer $GraphToken"; 'Content-Type' = 'application/json' } `
				-Body $batchBody -ErrorAction Stop
			foreach ($resp in $batchResp.responses) {
				# Map response id (1-based) back to the user object ID for this chunk
				$userId = $chunk[[int]$resp.id - 1]
				if ($resp.status -eq 200 -and $resp.body.PSObject.Properties['value']) {
					foreach ($lic in $resp.body.value) {
						$skuKey = $lic.skuPartNumber
						if (-not $skuCounts.ContainsKey($skuKey)) {
							$displayName = if ($SkuDisplayNameMap -and $SkuDisplayNameMap.ContainsKey($lic.skuPartNumber)) {
								$SkuDisplayNameMap[$lic.skuPartNumber]
							} else { $null }
							$skuCounts[$skuKey] = [PSCustomObject]@{
								SkuPartNumber = $lic.skuPartNumber
								SkuId         = $lic.skuId
								ProductName   = $displayName
								UserCount     = 0
							}
						}
						$skuCounts[$skuKey].UserCount++
						# Mark user as AVD-licensed if this SKU grants entitlement
						if ($avdEligibleSkus.Contains($lic.skuPartNumber) -or
						    $lic.skuPartNumber -match '^CPC_') {
							$licensedUserIds.Add($userId) | Out-Null
						}
					}
				}
			}
		}
		catch { <# Non-fatal — skip this batch #> }
	}

	# Identify users with no AVD-eligible licence and resolve their UPNs.
	# Uses individual Invoke-GraphGet calls rather than the batch endpoint — the batch
	# endpoint returns each response body parsed by Invoke-RestMethod, which can produce
	# a Hashtable instead of a PSCustomObject in some PS versions, causing property access
	# to silently return $null. Direct GET calls are simpler and unambiguous; unlicensed
	# users are typically a small count so the extra round-trips are not a concern.
	$unlicensedIds   = @($uniqueIds | Where-Object { -not $licensedUserIds.Contains($_) })
	$unlicensedUsers = [System.Collections.Generic.List[PSCustomObject]]::new()

	foreach ($id in $unlicensedIds) {
		$userResp = Invoke-GraphGet -Uri "https://graph.microsoft.com/v1.0/users/$($id)?`$select=id,userPrincipalName" -GraphToken $GraphToken
		$upn = if ($userResp) {
			$raw = $userResp.userPrincipalName
			if (-not [string]::IsNullOrEmpty([string]$raw)) { [string]$raw } else { $null }
		} else { $null }
		$unlicensedUsers.Add([PSCustomObject]@{ ObjectId = $id; UserPrincipalName = $upn })
	}

	# Filter to only AVD-relevant SKUs — access entitlements, Office suites, and
	# application licences commonly deployed on AVD hosts. Windows 365 (CPC_*) is
	# always included as it implies AVD-equivalent entitlement.
	$filteredCounts = @($skuCounts.Values | Where-Object {
		$reportableSkus.Contains($_.SkuPartNumber) -or $_.SkuPartNumber -match '^CPC_'
	})
	$summary = @($filteredCounts | Sort-Object -Property UserCount -Descending)
	return [PSCustomObject]@{
		LicenseSummary       = $summary
		LicenseSummaryStatus = if ($summary.Count -gt 0) { 'OK' } else { 'NoLicensesFound' }
		UnlicensedUserCount  = $unlicensedUsers.Count
		UnlicensedUsers      = @($unlicensedUsers | Sort-Object -Property UserPrincipalName)
	}
}

# ------------------------------------------------------------------
# VM Run Command — local host discovery
# ------------------------------------------------------------------

function Get-VmPowerState {
	<#
	.SYNOPSIS
	Returns the power state code of an Azure VM (e.g. 'PowerState/running') by querying
	the instanceView endpoint. Returns $null if the state cannot be determined.
	#>
	param(
		[Parameter(Mandatory = $true)]
		[string]$VmResourceId
	)

	$resp = Invoke-ArmRequest -Path "${VmResourceId}/instanceView?api-version=2024-03-01" -Method GET -ErrorAction SilentlyContinue
	if (-not $resp -or $resp.StatusCode -ne 200) { return $null }

	$statuses    = ($resp.Content | ConvertFrom-Json).statuses
	$powerStatus = @($statuses | Where-Object { $_.code -like 'PowerState/*' }) | Select-Object -First 1
	return $(if ($powerStatus) { $powerStatus.code } else { $null })
}

function Invoke-VmRunCommand {
	<#
	.SYNOPSIS
	Runs a PowerShell script on an Azure VM using the Run Command v2 (resource-based) API
	and returns the stdout output as a string. Returns $null on failure or timeout.

	Unlike Run Command v1 (the /runCommand POST endpoint), the v2 API stores results in a
	persistent runCommands child resource and does not impose a 4,096-character stdout limit.
	This makes it suitable for returning large payloads such as compressed discovery data.

	Flow:
	  1. GET the VM resource to obtain its location (required for the PUT body).
	  2. PUT a uniquely-named runCommands child resource to submit the script with
	     asyncExecution:false so the ARM operation does not complete until the script
	     finishes (or times out).
	  3. Extract the Azure-AsyncOperation or Location polling header from the PUT
	     response (returned on 200, 201, or 202) and poll until Succeeded.
	  4. Once the operation shows 'Succeeded', GET the runCommands resource and read
	     properties.instanceView.output for stdout.
	  5. DELETE the runCommands resource in a finally block regardless of outcome.

	Polling URL conversion, header iteration, and Invoke-AzRestMethod usage follow the
	same patterns as the rest of this script to ensure auth and signing are consistent.
	#>
	param(
		[Parameter(Mandatory = $true)]
		[string]$VmResourceId,

		[Parameter(Mandatory = $true)]
		[string[]]$Script,

		[Parameter(Mandatory = $false)]
		[object[]]$Parameters = @(),

		[Parameter(Mandatory = $false)]
		[int]$TimeoutSeconds = 600,

		# Sets the first poll interval. Use a lower value (e.g. 3) for short-running
		# scripts such as chunk reads, where the VM finishes in a few seconds.
		[Parameter(Mandatory = $false)]
		[int]$InitialPollSeconds = 10,

		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[PSCustomObject]$RunAsCredential
	)

	$vmLabel = ($VmResourceId -split '/')[-1]

	# Retrieve the VM's Azure region — required as the 'location' field in the PUT body.
	$vmResp = Invoke-ArmRequest -Path "${VmResourceId}?api-version=2024-03-01" -Method GET -ErrorAction SilentlyContinue
	if (-not $vmResp -or $vmResp.StatusCode -ne 200) {
		$sc = if ($vmResp) { $vmResp.StatusCode } else { 'n/a' }
		Write-Host "    [LocalDiscovery | $vmLabel] Could not retrieve VM metadata (HTTP $sc)."
		return $null
	}
	$vmLocation = ($vmResp.Content | ConvertFrom-Json).location

	# --- Pre-flight cleanup: remove any stale runCommand resources ---
	# The VM agent can only process one runCommand at a time, so any leftover resource
	# in Creating/Running/Deleting state will block the new one at Pending indefinitely.
	# This catches resources from timed-out runs, manual tests, or other tooling.
	# Deletion is a write operation so the user is warned and must confirm before proceeding.
	$listPath = "${VmResourceId}/runCommands?api-version=2024-03-01"
	$listRsp  = Invoke-ArmRequest -Path $listPath -Method GET -ErrorAction SilentlyContinue
	if ($listRsp -and $listRsp.StatusCode -eq 200) {
		$listBody = $listRsp.Content | ConvertFrom-Json
		$existing = @()
		if ($listBody.PSObject.Properties['value']) { $existing = @($listBody.value) }
		if ($existing.Count -gt 0) {
			Write-Host ''
			Write-Host "    [LocalDiscovery | $vmLabel] WARNING: Found $($existing.Count) existing Run Command resource(s) on this VM:" -ForegroundColor Yellow
			foreach ($res in $existing) {
				$resState = if ($res.properties -and $res.properties.PSObject.Properties['provisioningState']) { $res.properties.provisioningState } else { 'unknown' }
				Write-Host "    [LocalDiscovery | $vmLabel]   $($res.name)  (state: $resState)" -ForegroundColor Yellow
			}
			Write-Host ''
			Write-Host "    [LocalDiscovery | $vmLabel] These will block the new Run Command from executing." -ForegroundColor Yellow
			Write-Host "    [LocalDiscovery | $vmLabel] Deletion is a write operation — all other operations are read-only." -ForegroundColor Yellow
			Write-Host ''
			$confirm = Read-Host "    Delete these resource(s) and continue? [y/N]"
			if ($confirm -notmatch '^[Yy]$') {
				Write-Host "    [LocalDiscovery | $vmLabel] Skipping deletion — Run Command may remain stuck at Pending on this VM." -ForegroundColor Yellow
			} else {
				foreach ($res in $existing) {
					$resState = if ($res.properties -and $res.properties.PSObject.Properties['provisioningState']) { $res.properties.provisioningState } else { 'unknown' }
					$delPath = "${VmResourceId}/runCommands/$($res.name)?api-version=2024-03-01"
					Write-Host "    [LocalDiscovery | $vmLabel]   Deleting '$($res.name)' (state: $resState)..."
					Invoke-ArmRequest -Path $delPath -Method DELETE -ErrorAction SilentlyContinue | Out-Null
				}
				# Wait for deletions to complete — poll until no resources remain (max 120s)
				$cleanupDeadline = (Get-Date).AddSeconds(120)
				while ((Get-Date) -lt $cleanupDeadline) {
					Start-Sleep -Seconds 5
					$checkRsp = Invoke-ArmRequest -Path $listPath -Method GET -ErrorAction SilentlyContinue
					if ($checkRsp -and $checkRsp.StatusCode -eq 200) {
						$checkBody = $checkRsp.Content | ConvertFrom-Json
						$remaining = @()
						if ($checkBody.PSObject.Properties['value']) { $remaining = @($checkBody.value) }
						if ($remaining.Count -eq 0) {
							Write-Host "    [LocalDiscovery | $vmLabel]   Stale resources cleaned up."
							break
						}
					}
				}
			}
			Write-Host ''
		}
	}

	# Build a unique runCommands child-resource path.
	$cmdName     = "avd-disc-$([Guid]::NewGuid().ToString('N').Substring(0, 12))"
	$cmdPath     = "${VmResourceId}/runCommands/${cmdName}?api-version=2024-03-01"
	$cmdPathView = "${VmResourceId}/runCommands/${cmdName}?api-version=2024-03-01&`$expand=instanceView"
	$scriptText  = $Script -join "`n"

	# asyncExecution = $false ensures the ARM async operation does not report 'Succeeded'
	# until the script on the VM has finished. This lets a single polling loop cover both
	# resource provisioning and script execution.
	$bodyProps = [ordered]@{
		source           = @{ script = $scriptText }
		asyncExecution   = $false
		timeoutInSeconds = $TimeoutSeconds
	}
	if ($Parameters.Count -gt 0) {
		$bodyProps['parameters'] = @($Parameters | ForEach-Object { @{ name = $_.name; value = $_.value } })
	}
	if ($null -ne $RunAsCredential) {
		$bodyProps['runAsUser']     = $RunAsCredential.Username
		$bodyProps['runAsPassword'] = $RunAsCredential.Password
	}
	$body = @{
		location   = $vmLocation
		properties = $bodyProps
	} | ConvertTo-Json -Depth 6

	try {
		Write-Host "    [LocalDiscovery | $vmLabel] Submitting Run Command v2 to '$cmdName'..."
		$putRsp = Invoke-ArmRequest -Path $cmdPath -Method PUT -Payload $body -ErrorAction Stop
		Write-Host "    [LocalDiscovery | $vmLabel] PUT returned HTTP $($putRsp.StatusCode)."

		if ($putRsp.StatusCode -notin @(200, 201, 202)) {
			Write-Host "    [LocalDiscovery | $vmLabel] Run Command v2 PUT returned HTTP $($putRsp.StatusCode) — expected 200, 201, or 202."
			return $null
		}

		# The PUT always returns an Azure-AsyncOperation or Location polling header,
		# regardless of whether the HTTP status is 200, 201, or 202. Extract and poll it.
		$pollFullUri = $null
		foreach ($h in $putRsp.Headers) {
			if ($h.Key -ieq 'Azure-AsyncOperation') { $pollFullUri = @($h.Value)[0]; break }
		}
		if ([string]::IsNullOrEmpty($pollFullUri)) {
			foreach ($h in $putRsp.Headers) {
				if ($h.Key -ieq 'Location') { $pollFullUri = @($h.Value)[0]; break }
			}
		}

		if ([string]::IsNullOrEmpty($pollFullUri)) {
			Write-Host "    [LocalDiscovery | $vmLabel] No Azure-AsyncOperation or Location header in Run Command v2 PUT response."
			return $null
		}

		$pollPath  = ([Uri]$pollFullUri).PathAndQuery
		$deadline  = (Get-Date).AddSeconds($TimeoutSeconds)
		$pollSleep = $InitialPollSeconds
		$pollCount = 0
		Write-Host "    [LocalDiscovery | $vmLabel] Waiting for script execution (timeout ${TimeoutSeconds}s)..."

		while ((Get-Date) -lt $deadline) {
			Start-Sleep -Seconds $pollSleep
			$pollCount++
			if ($pollSleep -lt 30) { $pollSleep = [Math]::Min(30, $pollSleep + 5) }

			$elapsed = [int]((Get-Date) - $deadline.AddSeconds(-$TimeoutSeconds)).TotalSeconds
			Write-Host "    [LocalDiscovery | $vmLabel] Polling attempt #$pollCount (${elapsed}s elapsed)..."

			# Every 3rd poll, check the instanceView directly for early failure states.
			# This detects Failed/TimedOut/Canceled from the VM agent without waiting for
			# the full timeout — useful when the script errors quickly but the ARM
			# async-operation URL stays at InProgress briefly after VM-side completion.
			# Also reports Running state so the user can see the script is progressing.
			if ($pollCount % 3 -eq 0) {
				$ivRsp = Invoke-ArmRequest -Path $cmdPathView -Method GET -ErrorAction SilentlyContinue
				if ($ivRsp -and $ivRsp.StatusCode -eq 200) {
					$ivBody  = $ivRsp.Content | ConvertFrom-Json
					$ivProps = if ($ivBody.PSObject.Properties['properties']) { $ivBody.properties } else { $null }
					$ivView  = if ($null -ne $ivProps -and $ivProps.PSObject.Properties['instanceView']) { $ivProps.instanceView } else { $null }
					if ($null -ne $ivView -and $ivView.PSObject.Properties['executionState']) {
						$execState = $ivView.executionState
						if ($execState -in @('Failed', 'TimedOut', 'Canceled')) {
							$exitCode = if ($ivView.PSObject.Properties['exitCode']) { $ivView.exitCode } else { 'n/a' }
							Write-Host "    [LocalDiscovery | $vmLabel] Instance view reports '$execState' (exit code: $exitCode) — aborting early."
							return $null
						}
						# Detect stuck-at-Pending: if the command has been Pending for 90+ seconds
						# and provisioningState is still Creating, the VM agent is not processing
						# commands (broken handler, policy block, etc). Abort early so the caller
						# can try a different VM.
						if ($execState -eq 'Pending' -and $elapsed -ge 90) {
							$provState = if ($null -ne $ivProps -and $ivProps.PSObject.Properties['provisioningState']) { $ivProps.provisioningState } else { 'unknown' }
							if ($provState -eq 'Creating') {
								Write-Host "    [LocalDiscovery | $vmLabel] Command stuck at Pending/Creating for ${elapsed}s — VM agent is not processing Run Commands. Aborting."
								return '##AVD_VM_STUCK##'
							}
						}
						Write-Host "    [LocalDiscovery | $vmLabel] Instance view: $execState"
					}
				}
			}

			$pollRsp = Invoke-ArmRequest -Path $pollPath -Method GET -ErrorAction SilentlyContinue
			if (-not $pollRsp) { continue }
			if ($pollRsp.StatusCode -eq 202) { continue }  # still in progress

			if ($pollRsp.StatusCode -eq 200) {
				$pollBody = $pollRsp.Content | ConvertFrom-Json
				if ($pollBody.PSObject.Properties['status']) {
					$opStatus = $pollBody.status
					if ($opStatus -in @('InProgress', 'Running')) { continue }
					if ($opStatus -ne 'Succeeded') {
						Write-Host "    [LocalDiscovery | $vmLabel] Run Command v2 operation ended with status '$opStatus'."
						Write-Host "    [LocalDiscovery | $vmLabel] Full poll body: $($pollRsp.Content.Substring(0, [Math]::Min(800, $pollRsp.Content.Length)))"
						return $null
					}
					Write-Host "    [LocalDiscovery | $vmLabel] Script execution completed (poll #$pollCount)."
					break  # Succeeded — script has finished; fall through to GET.
				}
				Write-Host "    [LocalDiscovery | $vmLabel] Poll response had no 'status' property (poll #$pollCount). Raw: $($pollRsp.Content.Substring(0, [Math]::Min(300, $pollRsp.Content.Length)))"
				return $null
			}

			Write-Host "    [LocalDiscovery | $vmLabel] Unexpected poll HTTP $($pollRsp.StatusCode) on attempt #$pollCount."
			return $null
		}

		if ((Get-Date) -ge $deadline) {
			Write-Host "    [LocalDiscovery | $vmLabel] Run Command v2 polling timed out after $TimeoutSeconds seconds ($pollCount poll(s))."
			# Fetch instanceView for diagnostics before returning — helps identify why the command stayed Pending.
			$diagRsp = Invoke-ArmRequest -Path $cmdPathView -Method GET -ErrorAction SilentlyContinue
			if ($diagRsp -and $diagRsp.StatusCode -eq 200) {
				$diagBody  = $diagRsp.Content | ConvertFrom-Json
				$diagProps = if ($diagBody.PSObject.Properties['properties']) { $diagBody.properties } else { $null }
				$diagView  = if ($null -ne $diagProps -and $diagProps.PSObject.Properties['instanceView']) { $diagProps.instanceView } else { $null }
				if ($null -ne $diagView) {
					$diagState = if ($diagView.PSObject.Properties['executionState']) { $diagView.executionState } else { 'unknown' }
					$diagExit  = if ($diagView.PSObject.Properties['exitCode']) { $diagView.exitCode } else { 'n/a' }
					Write-Host "    [LocalDiscovery | $vmLabel] Timeout diagnostics — state: $diagState, exitCode: $diagExit"
					if ($diagView.PSObject.Properties['error'] -and $diagView.error) {
						$errSnippet = ($diagView.error -replace '[\r\n]+', ' ').Substring(0, [Math]::Min(500, $diagView.error.Length))
						Write-Host "    [LocalDiscovery | $vmLabel] stderr: $errSnippet"
					}
					if ($diagView.PSObject.Properties['output'] -and $diagView.output) {
						$outSnippet = ($diagView.output -replace '[\r\n]+', ' ').Substring(0, [Math]::Min(500, $diagView.output.Length))
						Write-Host "    [LocalDiscovery | $vmLabel] stdout: $outSnippet"
					}
				}
				# Also check provisioning state on the resource itself
				$provState = if ($null -ne $diagProps -and $diagProps.PSObject.Properties['provisioningState']) { $diagProps.provisioningState } else { 'unknown' }
				Write-Host "    [LocalDiscovery | $vmLabel] provisioningState: $provState"
			}
			return $null
		}

		# Retrieve the result from the runCommands resource with $expand=instanceView.
		# instanceView.output holds stdout without any character-count limit.
		Write-Host "    [LocalDiscovery | $vmLabel] Retrieving script output..."
		$getResp = Invoke-ArmRequest -Path $cmdPathView -Method GET -ErrorAction SilentlyContinue
		if (-not $getResp -or $getResp.StatusCode -ne 200) {
			$sc = if ($getResp) { $getResp.StatusCode } else { 'n/a' }
			Write-Host "    [LocalDiscovery | $vmLabel] Run Command v2 result GET returned HTTP $sc."
			return $null
		}

		$parsed = $getResp.Content | ConvertFrom-Json
		$props  = $parsed.properties
		if (-not $props -or -not $props.PSObject.Properties['instanceView']) {
			Write-Host "    [LocalDiscovery | $vmLabel] Run Command v2 instanceView not found in GET response."
			return $null
		}
		$instView = $props.instanceView

		# Return stdout regardless of executionState so the caller's marker-checking logic
		# can surface the ##AVD_LOCAL_DISCOVERY_ERROR## payload if the script reported one.
		return $(if ($instView.PSObject.Properties['output']) { $instView.output } else { $null })
	}
	finally {
		# Always clean up the runCommands child resource — errors here are suppressed
		# so they do not mask any exception already in flight.
		Write-Host "    [LocalDiscovery | $vmLabel] Cleaning up Run Command resource '$cmdName'..."
		Invoke-ArmRequest -Path $cmdPath -Method DELETE -ErrorAction SilentlyContinue | Out-Null
	}
}

function Read-VmFileInChunks {
	<#
	.SYNOPSIS
	Reads a text file from an Azure VM in fixed-size chunks using Run Command v2 and
	assembles the full content on the caller.

	.DESCRIPTION
	Run Command stdout is hard-limited to the last 4,096 chars by the Azure VM Agent,
	making it impossible to return large payloads directly through stdout. This function
	reads a pre-written staging file in chunks small enough to fit within that limit,
	with each chunk Run Command completing in a few seconds thanks to a short initial
	poll interval.
	#>
	param(
		[Parameter(Mandatory = $true)]
		[string]$VmResourceId,

		[Parameter(Mandatory = $true)]
		[string]$FilePath,

		[Parameter(Mandatory = $true)]
		[int]$FileLength,

		# Characters per chunk — must stay well below 4,096 after adding marker overhead.
		[Parameter(Mandatory = $false)]
		[int]$ChunkSize = 3900,

		[Parameter(Mandatory = $false)]
		[int]$TimeoutSeconds = 90
	)

	$vmLabel    = ($VmResourceId -split '/')[-1]
	$chunkCount = [Math]::Ceiling($FileLength / $ChunkSize)
	Write-Host "    [LocalDiscovery | $vmLabel] Reading output in $chunkCount chunk(s) ($FileLength chars total)..."

	$sb = [System.Text.StringBuilder]::new($FileLength)

	for ($i = 0; $i -lt $chunkCount; $i++) {
		$offset = $i * $ChunkSize
		Write-Host "    [LocalDiscovery | $vmLabel] Chunk $($i + 1)/$chunkCount (offset $offset)..."

		$chunkScript = @(
			"`$p = '$FilePath'",
			"`$o = $offset",
			"`$l = $ChunkSize",
			'$t = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::ASCII)',
			'$c = $t.Substring($o, [Math]::Min($l, $t.Length - $o))',
			'Write-Output "##CHUNK_START##"',
			'Write-Output $c',
			'Write-Output "##CHUNK_END##"'
		)

		$chunkOut = Invoke-VmRunCommand -VmResourceId $VmResourceId -Script $chunkScript `
			-TimeoutSeconds $TimeoutSeconds -InitialPollSeconds 3

		if ([string]::IsNullOrEmpty($chunkOut)) {
			Write-Warning "[LocalDiscovery | $vmLabel] Empty response for chunk $($i + 1)/$chunkCount."
			return $null
		}

		$s = $chunkOut.IndexOf('##CHUNK_START##')
		$e = $chunkOut.IndexOf('##CHUNK_END##')
		if ($s -lt 0 -or $e -lt 0 -or $e -le $s) {
			Write-Warning "[LocalDiscovery | $vmLabel] Chunk $($i + 1) markers not found. Output: $($chunkOut.Substring(0, [Math]::Min(200, $chunkOut.Length)))"
			return $null
		}

		$mLen = '##CHUNK_START##'.Length
		$data = $chunkOut.Substring($s + $mLen, $e - $s - $mLen).Trim()
		[void]$sb.Append($data)
	}

	return $sb.ToString()
}

function Invoke-HostPoolLocalDiscovery {
	<#
	.SYNOPSIS
	Finds the first running session host VM in a host pool, executes Invoke-AvdSessionHostAudit.ps1
	on it via the Azure VM Run Command API, and saves the resulting JSON to the
	output/vm-discovery directory. Non-fatal — logs a warning and continues on failure.

	.DESCRIPTION
	A small bootstrap script is sent as the Run Command payload. By default it downloads
	Invoke-AvdSessionHostAudit.ps1 and config/appExclusions.config.json directly from the GitHub repository
	(raw.githubusercontent.com) using Invoke-WebRequest.

	When -InlineLocalScript is specified, the bootstrap instead carries both files
	embedded as base64-encoded strings and writes them to a temp directory on the VM,
	eliminating the need for outbound HTTPS access to GitHub.

	In either mode, the bootstrap executes Invoke-AvdSessionHostAudit.ps1 into a temp directory, writes
	the GZip-compressed base64-encoded JSON to a staging file, and returns just the file
	path and size via stdout. The caller then reads the staging file back in fixed-size
	chunks (Run Command stdout is limited to the last 4,096 chars by the Azure VM Agent),
	assembles the payload, decodes it, and writes it to the output/vm-discovery folder. The
	staging file is deleted after retrieval.

	Requires the authenticated account to have 'Virtual Machine Contributor' or
	'Virtual Machine Run Command Contributor' rights on the session host VMs.
	When not using -InlineLocalScript, the session host must have outbound HTTPS access
	to raw.githubusercontent.com.
	#>
	param(
		[Parameter(Mandatory = $true)]
		[PSCustomObject]$Pool,

		[Parameter(Mandatory = $true)]
		[AllowEmptyCollection()]
		[string[]]$VmResourceIds,

		[Parameter(Mandatory = $true)]
		[string]$CustomerCode,

		[Parameter(Mandatory = $true)]
		[string]$VmDiscoveryDirectory,

		[Parameter(Mandatory = $true)]
		[string]$GitHubRawBaseUrl,

		[Parameter(Mandatory = $false)]
		[int]$TimeoutSeconds = 300,

		[Parameter(Mandatory = $false)]
		[switch]$InlineLocalScript,

		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[PSCustomObject]$RunAsCredential
	)

	if (@($VmResourceIds).Count -eq 0) {
		Write-Host "    [LocalDiscovery | $($Pool.Name)] No session host VMs registered — skipping."
		return
	}

	# Collect all running VMs so we can fall back to the next one if a VM's agent is stuck.
	$_ldActivity = "Local Discovery  ─  $($Pool.Name)"
	$script:_progressActivity = $_ldActivity
	$_ldVmTotal  = @($VmResourceIds).Count
	$_ldVmIdx    = 0
	$runningVmIds = @()
	foreach ($vmId in $VmResourceIds) {
		$candidateName = ($vmId -split '/')[-1]
		$_ldVmIdx++
		Write-SpinnerLine -Status "Checking power state: $candidateName ($_ldVmIdx/$_ldVmTotal)"
		Write-Host "    [LocalDiscovery | $($Pool.Name)] Checking power state: $candidateName"
		$state = Get-VmPowerState -VmResourceId $vmId
		if ($state -eq 'PowerState/running') {
			$runningVmIds += $vmId
		}
	}

	if ($runningVmIds.Count -eq 0) {
		Write-Host "    [LocalDiscovery | $($Pool.Name)] No running hosts found — skipping."
		return
	}

	Write-Host "    [LocalDiscovery | $($Pool.Name)] Found $($runningVmIds.Count) running host(s)."

	$scriptUrl       = "$GitHubRawBaseUrl/scripts/Invoke-AvdSessionHostAudit.ps1"
	$configUrl       = "$GitHubRawBaseUrl/config/appExclusions.config.json"
	$custCodeEscaped = $CustomerCode -replace "'", "''"

	# --- Build the wrapper script (same for all VMs in this pool) ---
	$wrapperLines  = $null
	$wrapperParams = @()

	if ($InlineLocalScript.IsPresent) {
		# --- Inline mode: embed the script files directly in the Run Command payload ---
		$localScriptPath = Join-Path $PSScriptRoot 'Invoke-AvdSessionHostAudit.ps1'
		$localConfigPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'config\appExclusions.config.json'
		if (-not (Test-Path $localScriptPath)) { Write-Warning "[LocalDiscovery | $($Pool.Name)] Invoke-AvdSessionHostAudit.ps1 not found at '$localScriptPath' — cannot inline."; return }
		if (-not (Test-Path $localConfigPath)) { Write-Warning "[LocalDiscovery | $($Pool.Name)] config\appExclusions.config.json not found at '$localConfigPath' — cannot inline."; return }

		$scriptB64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($localScriptPath))
		$configB64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($localConfigPath))

		Write-Host "    [LocalDiscovery | $($Pool.Name)] Inline mode — embedding Invoke-AvdSessionHostAudit.ps1 ($([Math]::Round($scriptB64.Length / 1KB, 1)) KB b64) + config ($([Math]::Round($configB64.Length / 1KB, 1)) KB b64)"

		# Build the base64 assignment as a concatenation of small chunks rather than
		# one enormous string literal. PowerShell 5.1 is extremely slow to parse a single
		# 128 KB string token, but handles many 4 KB concatenations quickly.
		$chunkSize = 4000
		function Split-Base64ToChunkedAssignment {
			param([string]$VarName, [string]$Base64)
			if ($Base64.Length -le $chunkSize) {
				return "`$$VarName = '$Base64'"
			}
			$parts = [System.Collections.Generic.List[string]]::new()
			for ($i = 0; $i -lt $Base64.Length; $i += $chunkSize) {
				$len = [Math]::Min($chunkSize, $Base64.Length - $i)
				$parts.Add("'$($Base64.Substring($i, $len))'")
			}
			return "`$$VarName = $($parts -join ' + ')"
		}
		$scrAssignment = Split-Base64ToChunkedAssignment -VarName 'scrB64' -Base64 $scriptB64
		$cfgAssignment = Split-Base64ToChunkedAssignment -VarName 'cfgB64' -Base64 $configB64

		# The wrapper decodes the embedded base64 content to files on the VM, then
		# executes Invoke-AvdSessionHostAudit.ps1 identically to the GitHub-download path.
		$wrapperLines = @(
			$scrAssignment,
			$cfgAssignment,
			"`$cCode = '$custCodeEscaped'",
			'$ErrorActionPreference = "Stop"',
			'try {',
			'    $id      = [Guid]::NewGuid().ToString("N")',
			'    $tmp     = Join-Path ([System.IO.Path]::GetTempPath()) "avd-disc-$id"',
			'    $scrPath = Join-Path $tmp "Invoke-AvdSessionHostAudit.ps1"',
			'    $cfgPath = Join-Path $tmp "appExclusions.config.json"',
			'    $outDir  = Join-Path $tmp "output"',
			'    New-Item -ItemType Directory -Path $tmp    -Force | Out-Null',
			'    New-Item -ItemType Directory -Path $outDir -Force | Out-Null',
			'    [System.IO.File]::WriteAllBytes($scrPath, [Convert]::FromBase64String($scrB64))',
			'    [System.IO.File]::WriteAllBytes($cfgPath, [Convert]::FromBase64String($cfgB64))',
			("    & `$scrPath -CustomerAbbreviation `$cCode -OutputDirectory `$outDir -PrimaryApplicationsOnly -NoHtml$(if ($NoGpresult.IsPresent) { ' -NoGpresult' }) -ErrorAction Stop *>&1 | Out-Null"),
			'    $jf = Get-ChildItem -Path $outDir -Filter "*.json" -File | Select-Object -First 1',
			'    if (-not $jf) { throw "No JSON output produced by Invoke-AvdSessionHostAudit.ps1" }',
			'    $jb  = [System.IO.File]::ReadAllBytes($jf.FullName)',
			'    $cms = [System.IO.MemoryStream]::new()',
			'    $cgz = [System.IO.Compression.GZipStream]::new($cms, [System.IO.Compression.CompressionMode]::Compress)',
			'    $cgz.Write($jb, 0, $jb.Length)',
			'    $cgz.Close()',
			'    $b64     = [Convert]::ToBase64String($cms.ToArray())',
			'    $stgPath = Join-Path ([System.IO.Path]::GetTempPath()) ("avd-stage-$id.b64")',
			'    [System.IO.File]::WriteAllText($stgPath, $b64, [System.Text.Encoding]::ASCII)',
			'    Write-Output "##AVD_FILE##$stgPath##SIZE##$($b64.Length)##JSON##$($jb.Length)##"',
			'    $hf = Get-ChildItem -Path $outDir -Filter "*.gpresult.html" -File | Select-Object -First 1',
			'    if ($hf) {',
			'        $hb  = [System.IO.File]::ReadAllBytes($hf.FullName)',
			'        $hms = [System.IO.MemoryStream]::new()',
			'        $hgz = [System.IO.Compression.GZipStream]::new($hms, [System.IO.Compression.CompressionMode]::Compress)',
			'        $hgz.Write($hb, 0, $hb.Length)',
			'        $hgz.Close()',
			'        $hb64     = [Convert]::ToBase64String($hms.ToArray())',
			'        $hstgPath = Join-Path ([System.IO.Path]::GetTempPath()) ("avd-stage-$id-gp.b64")',
			'        [System.IO.File]::WriteAllText($hstgPath, $hb64, [System.Text.Encoding]::ASCII)',
			'        Write-Output "##AVD_GPRESULT##$hstgPath##SIZE##$($hb64.Length)##HTML##$($hb.Length)##"',
			'    }',
			'} catch {',
			'    $errMsg = ($_.Exception.Message -replace "[\r\n]+", " ").Trim()',
			'    $errLine = if ($_.InvocationInfo) { "line $($_.InvocationInfo.ScriptLineNumber) in $($_.InvocationInfo.ScriptName)" } else { "unknown location" }',
			'    Write-Output "##AVD_LOCAL_DISCOVERY_ERROR##[$errLine] $errMsg"',
			'} finally {',
			'    if ($tmp -and (Test-Path $tmp)) { Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue }',
			'}'
		)
		$wrapperParams = @()
	}
	else {
		# --- GitHub mode (default): download files on the VM at runtime ---
		Write-Host "    [LocalDiscovery | $($Pool.Name)] Fetching script from: $scriptUrl"

		# Bootstrap sent as the Run Command payload. Downloads both files from GitHub then
		# executes Invoke-AvdSessionHostAudit.ps1. JSON output is GZip-compressed and base64-encoded so it
		# travels cleanly through the Run Command stdout channel.
		$wrapperLines = @(
			"`$scriptUrl = '$scriptUrl'",
			"`$configUrl = '$configUrl'",
			"`$cCode     = '$custCodeEscaped'",
			'$ErrorActionPreference = "Stop"',
			'try {',
			'    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12',
			'    $id      = [Guid]::NewGuid().ToString("N")',
			'    $tmp     = Join-Path ([System.IO.Path]::GetTempPath()) "avd-disc-$id"',
			'    $scrPath = Join-Path $tmp "Invoke-AvdSessionHostAudit.ps1"',
			'    $cfgPath = Join-Path $tmp "appExclusions.config.json"',
			'    $outDir  = Join-Path $tmp "output"',
			'    New-Item -ItemType Directory -Path $tmp    -Force | Out-Null',
			'    New-Item -ItemType Directory -Path $outDir -Force | Out-Null',
			'    Invoke-WebRequest -Uri $scriptUrl -OutFile $scrPath -UseBasicParsing',
			'    Invoke-WebRequest -Uri $configUrl -OutFile $cfgPath -UseBasicParsing',
			("    & `$scrPath -CustomerAbbreviation `$cCode -OutputDirectory `$outDir -PrimaryApplicationsOnly -NoHtml$(if ($NoGpresult.IsPresent) { ' -NoGpresult' }) -ErrorAction Stop *>&1 | Out-Null"),
			'    $jf = Get-ChildItem -Path $outDir -Filter "*.json" -File | Select-Object -First 1',
			'    if (-not $jf) { throw "No JSON output produced by Invoke-AvdSessionHostAudit.ps1" }',
			'    $jb  = [System.IO.File]::ReadAllBytes($jf.FullName)',
			'    $cms = [System.IO.MemoryStream]::new()',
			'    $cgz = [System.IO.Compression.GZipStream]::new($cms, [System.IO.Compression.CompressionMode]::Compress)',
			'    $cgz.Write($jb, 0, $jb.Length)',
			'    $cgz.Close()',
			'    $b64     = [Convert]::ToBase64String($cms.ToArray())',
			'    $stgPath = Join-Path ([System.IO.Path]::GetTempPath()) ("avd-stage-$id.b64")',
			'    [System.IO.File]::WriteAllText($stgPath, $b64, [System.Text.Encoding]::ASCII)',
			'    Write-Output "##AVD_FILE##$stgPath##SIZE##$($b64.Length)##JSON##$($jb.Length)##"',
			'    $hf = Get-ChildItem -Path $outDir -Filter "*.gpresult.html" -File | Select-Object -First 1',
			'    if ($hf) {',
			'        $hb  = [System.IO.File]::ReadAllBytes($hf.FullName)',
			'        $hms = [System.IO.MemoryStream]::new()',
			'        $hgz = [System.IO.Compression.GZipStream]::new($hms, [System.IO.Compression.CompressionMode]::Compress)',
			'        $hgz.Write($hb, 0, $hb.Length)',
			'        $hgz.Close()',
			'        $hb64     = [Convert]::ToBase64String($hms.ToArray())',
			'        $hstgPath = Join-Path ([System.IO.Path]::GetTempPath()) ("avd-stage-$id-gp.b64")',
			'        [System.IO.File]::WriteAllText($hstgPath, $hb64, [System.Text.Encoding]::ASCII)',
			'        Write-Output "##AVD_GPRESULT##$hstgPath##SIZE##$($hb64.Length)##HTML##$($hb.Length)##"',
			'    }',
			'} catch {',
			'    $errMsg = ($_.Exception.Message -replace "[\r\n]+", " ").Trim()',
			'    $errLine = if ($_.InvocationInfo) { "line $($_.InvocationInfo.ScriptLineNumber) in $($_.InvocationInfo.ScriptName)" } else { "unknown location" }',
			'    Write-Output "##AVD_LOCAL_DISCOVERY_ERROR##[$errLine] $errMsg"',
			'} finally {',
			'    if ($tmp -and (Test-Path $tmp)) { Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue }',
			'}'
		)
		$wrapperParams = @()
	}

	# --- Try each running VM until one succeeds or all are exhausted ---
	# VMs can have broken Run Command handlers (agent stuck, policy blocked, etc).
	# If a VM returns ##AVD_VM_STUCK## (Pending/Creating for 90+ seconds), skip it
	# and try the next running host.
	$stuckCount = 0
	foreach ($targetVmId in $runningVmIds) {
		$vmName = ($targetVmId -split '/')[-1]
		Write-Host "    [LocalDiscovery | $vmName] Target VM selected$(if ($null -ne $RunAsCredential) { " — run-as: $($RunAsCredential.Username)" })"

	# Run the bootstrap wrapper. It executes Invoke-AvdSessionHostAudit.ps1 (downloaded or inlined),
	# compresses the output, and writes the base64 payload to a staging file — returning
	# just the path and size via stdout (stdout itself is limited to the last 4,096 chars).
	$stdout = $null
	Write-SpinnerLine -Status "Running discovery on $vmName  (may take 1–3 min)"
	try {
		$stdout = Invoke-VmRunCommand -VmResourceId $targetVmId -Script $wrapperLines -Parameters $wrapperParams -TimeoutSeconds $TimeoutSeconds -RunAsCredential $RunAsCredential
	}
	catch {
		Write-Warning "[LocalDiscovery | $vmName] Run Command submission failed: $($_.Exception.Message)"
		continue
	}

	# If the VM agent is stuck (not processing commands), show an advisory on the first
	# occurrence and prompt the user — then try the next VM regardless.
	if ($stdout -eq '##AVD_VM_STUCK##') {
		$stuckCount++
		if ($stuckCount -eq 1) {
			$_cmd = ".\scripts\Invoke-AvdSessionHostAudit.ps1 -CustomerAbbreviation $CustomerCode -NoHtml$(if ($NoGpresult.IsPresent) { ' -NoGpresult' })"
			$_lines = @(
				'',
				'  Run Command appears to be blocked on this host pool',
				'',
				'  The VM agent is not processing commands — likely caused by:',
				'    • Endpoint security (Defender/MDE) blocking script execution',
				'    • A network policy blocking the Azure wireserver (168.63.129.16)',
				'    • A stuck VM agent goal-state queue (restart WindowsAzureGuestAgent)',
				'',
				'  RECOMMENDED: Cancel (Ctrl+C) and run Invoke-AvdSessionHostAudit.ps1 directly',
				"  on $vmName using one of the following methods:",
				'',
				"    1. RDP to:             $vmName",
				"    2. Azure Bastion to:   $vmName",
				"    3. RMM / LogicMonitor: $vmName",
				'',
				'  Then run:',
				"    $_cmd",
				'',
				'  Continuing to try remaining hosts — press Ctrl+C to cancel.',
				''
			)
			$_w  = [Math]::Max(($_lines | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum, 60)
			$_hr = '─' * $_w
			Write-Host ''
			Write-Host "    ┌$_hr┐" -ForegroundColor Yellow
			foreach ($_s in $_lines) {
				Write-Host "    │$($_s.PadRight($_w))│" -ForegroundColor Yellow
			}
			Write-Host "    └$_hr┘" -ForegroundColor Yellow
			Write-Host ''
		}
		Write-Host "    [LocalDiscovery | $vmName] Skipping — trying next running host..."
		continue
	}

	if ([string]::IsNullOrEmpty($stdout)) {
		Write-Warning "[LocalDiscovery | $vmName] Run Command returned no output. Verify the VM agent is running and the caller has 'Virtual Machine Contributor' rights."
		continue
	}

	# Script-level error reported by the wrapper.
	if ($stdout -match '(?s)##AVD_LOCAL_DISCOVERY_ERROR##(.+)') {
		Write-Warning "[LocalDiscovery | $vmName] Invoke-AvdSessionHostAudit.ps1 reported an error: $($Matches[1].Trim())"
		continue
	}

	# Parse the staging file path and character count.
	if ($stdout -notmatch '##AVD_FILE##(.+?)##SIZE##(\d+)##') {
		$diagLen  = $stdout.Length
		$diagHead = $stdout.Substring(0, [Math]::Min(300, $diagLen))
		Write-Warning "[LocalDiscovery | $vmName] Staging file marker not found in response ($diagLen chars). Output: $diagHead"
		continue
	}
	$stagingPath = $Matches[1].Trim()
	$fileSize    = [int]$Matches[2]
	$rawJsonSize = ''
	if ($stdout -match '##JSON##(\d+)##') {
		$rawJsonBytes = [int64]$Matches[1]
		$rawJsonSize  = " (raw JSON: $([Math]::Round($rawJsonBytes / 1KB, 1)) KB)"
	}
	Write-Host "    [LocalDiscovery | $vmName] Staging file written: $stagingPath ($fileSize chars)$rawJsonSize"

	# Read the staging file back in chunks, then delete it regardless of success or failure.
	$b64Payload = $null
	$_chunkCount = [Math]::Ceiling($fileSize / 3900)
	Write-SpinnerLine -Status "Retrieving output from $vmName  ($_chunkCount chunk(s))"
	try {
		$b64Payload = Read-VmFileInChunks -VmResourceId $targetVmId -FilePath $stagingPath -FileLength $fileSize
	}
	finally {
		Write-SpinnerLine -Status "Cleaning up staging file on $vmName"
		Write-Host "    [LocalDiscovery | $vmName] Deleting staging file..."
		$cleanupLines = @("if (Test-Path '$stagingPath') { Remove-Item -Path '$stagingPath' -Force -ErrorAction SilentlyContinue }")
		Invoke-VmRunCommand -VmResourceId $targetVmId -Script $cleanupLines -TimeoutSeconds 60 -InitialPollSeconds 3 | Out-Null
	}

	if ([string]::IsNullOrEmpty($b64Payload)) {
		Write-Warning "[LocalDiscovery | $vmName] Failed to retrieve data from staging file."
		continue
	}

	try {
		$compressed  = [Convert]::FromBase64String($b64Payload)
		$inMs        = [System.IO.MemoryStream]::new($compressed)
		$outMs       = [System.IO.MemoryStream]::new()
		$gz          = [System.IO.Compression.GZipStream]::new($inMs, [System.IO.Compression.CompressionMode]::Decompress)
		$gz.CopyTo($outMs)
		$gz.Close()
		$jsonContent = [System.Text.Encoding]::UTF8.GetString($outMs.ToArray())
	}
	catch {
		Write-Warning "[LocalDiscovery | $vmName] Failed to decompress/decode output: $($_.Exception.Message)"
		continue
	}

	if (-not (Test-Path -Path $VmDiscoveryDirectory)) {
		New-Item -ItemType Directory -Path $VmDiscoveryDirectory -Force | Out-Null
	}

	$timestamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
	$outputFile = Join-Path $VmDiscoveryDirectory "$CustomerCode-$($vmName.ToLowerInvariant())-avd-discovery-$timestamp.json"
	[System.IO.File]::WriteAllText($outputFile, $jsonContent, [System.Text.Encoding]::UTF8)
	try {
		$parsedLocalDiscovery = $jsonContent | ConvertFrom-Json -Depth 12
		if (-not $parsedLocalDiscovery.PSObject.Properties['ReportType']) {
			$parsedLocalDiscovery | Add-Member -NotePropertyName ReportType -NotePropertyValue 'AzureSessionHostAudit'
		}
		$parsedLocalDiscovery.HtmlGeneration = if ($NoHtml.IsPresent) {
			[PSCustomObject]@{
				Requested       = $false
				Status          = 'Skipped'
				Message         = '-NoHtml specified.'
				HtmlPath        = $null
				GeneratorScript = $null
				GeneratedAt     = $null
			}
		} else {
			Invoke-OptionalHtmlReportGeneration -JsonPath $outputFile -ReportType 'AzureSessionHostAudit' -OutputPath ([System.IO.Path]::ChangeExtension($outputFile, '.html'))
		}
		$parsedLocalDiscovery | ConvertTo-Json -Depth 12 | Set-Content -Path $outputFile -Encoding UTF8
		if ($parsedLocalDiscovery.HtmlGeneration.Status -eq 'Generated') {
			Write-Host "    [LocalDiscovery | $vmName] Saved HTML: $($parsedLocalDiscovery.HtmlGeneration.HtmlPath)"
		}
	}
	catch {
		Write-Verbose "[LocalDiscovery | $vmName] Failed to update HTML generation status: $($_.Exception.Message)"
	}
	Write-Host "    [LocalDiscovery | $vmName] Saved: $outputFile"

	# Retrieve and save the gpresult HTML report if the VM staged one.
	if ($stdout -match '##AVD_GPRESULT##(.+?)##SIZE##(\d+)##') {
		$gpStgPath  = $Matches[1].Trim()
		$gpFileSize = [int]$Matches[2]
		$gpHtmlSize = ''
		if ($stdout -match '##HTML##(\d+)##') { $gpHtmlSize = " (HTML: $([Math]::Round([int64]$Matches[1] / 1KB, 1)) KB)" }
		$_gpChunkCount = [Math]::Ceiling($gpFileSize / 3900)
		Write-SpinnerLine -Status "Retrieving Group Policy report from $vmName  ($_gpChunkCount chunk(s))"
		Write-Host "    [LocalDiscovery | $vmName] Retrieving gpresult HTML ($gpFileSize chars)$gpHtmlSize..."
		$gpB64 = $null
		try {
			$gpB64 = Read-VmFileInChunks -VmResourceId $targetVmId -FilePath $gpStgPath -FileLength $gpFileSize
		}
		finally {
			$gpCleanup = @("if (Test-Path '$gpStgPath') { Remove-Item -Path '$gpStgPath' -Force -ErrorAction SilentlyContinue }")
			Invoke-VmRunCommand -VmResourceId $targetVmId -Script $gpCleanup -TimeoutSeconds 60 -InitialPollSeconds 3 | Out-Null
		}
		if (-not [string]::IsNullOrEmpty($gpB64)) {
			try {
				$gpCompressed = [Convert]::FromBase64String($gpB64)
				$gpInMs  = [System.IO.MemoryStream]::new($gpCompressed)
				$gpOutMs = [System.IO.MemoryStream]::new()
				$gpGz    = [System.IO.Compression.GZipStream]::new($gpInMs, [System.IO.Compression.CompressionMode]::Decompress)
				$gpGz.CopyTo($gpOutMs)
				$gpGz.Close()
				$gpHtmlPath = [System.IO.Path]::ChangeExtension($outputFile, '.gpresult.html')
				[System.IO.File]::WriteAllBytes($gpHtmlPath, $gpOutMs.ToArray())
				Write-Host "    [LocalDiscovery | $vmName] Saved gpresult: $gpHtmlPath"
			}
			catch {
				Write-Warning "[LocalDiscovery | $vmName] Failed to decode gpresult HTML: $($_.Exception.Message)"
			}
		}
	}
	# Success — this VM worked, stop trying others.
	Clear-SpinnerLine
	return
	}

	# All running VMs exhausted without success
	Clear-SpinnerLine
	Write-Warning "[LocalDiscovery | $($Pool.Name)] All $($runningVmIds.Count) running host(s) failed or had stuck agents — local discovery could not be completed."
}

# ------------------------------------------------------------------
# Entry point
# ------------------------------------------------------------------

$originalContext = $null

try {
	$requiredModules = @('Az.Accounts', 'Az.DesktopVirtualization')
	foreach ($module in $requiredModules) {
		if (-not (Get-Module -ListAvailable -Name $module)) {
			throw "Required module '$module' is not installed. Run: Install-Module $module -Scope CurrentUser"
		}
	}

	# --- Read-only safeguards ---
	# 1. Verify no write-capable Azure cmdlets are present anywhere in this script.
	Assert-ScriptIsReadOnly

	# 2. Disable context autosave for this process so none of the Set-AzContext calls
	#    below persist subscription changes to disk after the script exits.
	Disable-AzContextAutosave -Scope Process | Out-Null

	# 3. Capture the caller's current context so it can be restored in the finally block,
	#    regardless of how many subscriptions this script switches to during execution.
	$originalContext = Get-AzContext
	$authenticatedContext = Connect-RequestedAzAccount -CurrentContext $originalContext
	if (-not $authenticatedContext -or -not $authenticatedContext.Account) {
		throw 'Azure sign-in did not produce an active context.'
	}

	$customerCode  = Get-CustomerAbbreviation -Value $CustomerAbbreviation
	$GeneratedBy   = Get-RequiredTextValue -Prompt 'Enter engineer name' -Value $GeneratedBy
	$ProjectCode   = Get-RequiredTextValue -Prompt 'Enter project code' -Value $ProjectCode
	$endTime       = (Get-Date).ToUniversalTime().Date          # midnight UTC today
	$startTime     = $endTime.AddDays(-$LookbackDays)

	$resolvedOutputDirectory    = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { Join-Path (Split-Path $PSScriptRoot -Parent) 'output\avd-metrics' } else { [System.IO.Path]::GetFullPath($OutputDirectory) }
	$resolvedOutputPath         = New-ExportFilePath -Directory $resolvedOutputDirectory -CustomerCode $customerCode
	$resolvedVmDiscoveryDirectory = Join-Path (Split-Path $PSScriptRoot -Parent) 'output\vm-discovery'
	$gitHubRawBaseUrl             = "https://raw.githubusercontent.com/wavenetuk/avd-discovery/$GitHubBranch"

	if (-not [string]::IsNullOrWhiteSpace($resolvedOutputDirectory) -and -not (Test-Path -Path $resolvedOutputDirectory)) {
		New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
	}

	$scriptStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

	$_peakDesc = if ($PeakHoursOnly.IsPresent) {
		"09:00–18:00 local  (UTC$([string]::Format('{0:+0;-0}', $UtcOffsetHours)))"
	} else { 'All hours' }
	$_poolFilter = if ($HostPoolName -and @($HostPoolName).Count -gt 0) { $HostPoolName -join ', ' } else { 'All pools' }
	$_localDisc  = if ($RunLocalDiscovery.IsPresent) {
		if ($InlineLocalScript.IsPresent) { 'Yes (inline)' } else { "Yes  [$GitHubBranch / timeout ${LocalDiscoveryTimeout}s]" }
	} else { 'No' }
	$_outFile = Split-Path $resolvedOutputPath -Leaf

	Write-Banner @(
		'AVD Discovery  —  Metrics Collection',
		'',
		"Customer     :  $customerCode",
		"Engineer     :  $GeneratedBy",
		"Project Code :  $ProjectCode",
		"Period       :  $($startTime.ToString('yyyy-MM-dd'))  →  $($endTime.ToString('yyyy-MM-dd'))  ($LookbackDays days)",
		"Weekends     :  $(if ($ExcludeWeekends.IsPresent) { 'Excluded' } else { 'Included' })",
		"Peak Hours   :  $_peakDesc",
		"Host Pools   :  $_poolFilter",
		"Local Disc   :  $_localDisc",
		"Output       :  $_outFile"
	)

	$script:_progressStep  = 0
	$script:_progressTotal = 0  # Set to real value after Host Pools count is known

	Write-Rule 'DISCOVERY'

	Write-CheckStart 'Subscriptions'
	$subscriptions = Get-TargetSubscriptions -SubscriptionIds $SubscriptionId
	$_subResultDetail = if ($SubscriptionId -and @($SubscriptionId).Count -gt 0) {
		$_totalSubs = @(Get-AzSubscription -WarningAction SilentlyContinue | Where-Object { $_.State -eq 'Enabled' }).Count
		"$(@($subscriptions).Count) selected (filtered from $_totalSubs accessible)"
	} else {
		"$(@($subscriptions).Count) accessible"
	}
	Write-CheckResult 'Success' $_subResultDetail

	Write-CheckStart 'Host Pools'
	$hostPools = Get-AllHostPools -Subscriptions $subscriptions
	$_totalDiscovered = $hostPools.Count
	if ($HostPoolName -and @($HostPoolName).Count -gt 0) {
		$hostPools = @($hostPools | Where-Object { $_.Name -in $HostPoolName })
		if ($hostPools.Count -eq 0) {
			throw "No host pools matched the specified -HostPoolName filter: $($HostPoolName -join ', ')"
		}
	}
	$_poolResultDetail = if ($hostPools.Count -lt $_totalDiscovered) {
		"$($hostPools.Count) selected (filtered from $_totalDiscovered across $(@($subscriptions).Count) subscription(s))"
	} else {
		"$($hostPools.Count) found across $(@($subscriptions).Count) subscription(s)"
	}
	Write-CheckResult 'Success' $_poolResultDetail

	# Set progress total now that pool count is known.
	# Formula: 4 remaining pre-loop checks + 13 per-pool checks + 1 licence tail check.
	$script:_progressStep  = 2  # Subscriptions + Host Pools already completed
	$script:_progressTotal = 3 + (13 * $hostPools.Count) + 1

	# Collect run-as credentials after host pool discovery so the prompt
	# appears once (not per-pool) and only when there are pools to process.
	$runAsCredential = $null
	if ($RunLocalDiscovery.IsPresent -and $RunAsUser.IsPresent -and $hostPools.Count -gt 0) {
		$runAsCredential = Get-RunAsCredential
		Write-Host "      Run-as user  : $($runAsCredential.Username)" -ForegroundColor DarkGray
	}

	Write-CheckStart 'Graph Token'
	$graphToken = Get-GraphToken
	if ($graphToken) {
		Write-CheckResult 'Success' 'Group expansion enabled'
	} else {
		Write-CheckResult 'Skipped' 'Unavailable — group membership will not be expanded'
	}

	$authenticatedIdentity = Get-AuthenticatedIdentitySummary -AzContext $authenticatedContext -Subscriptions $subscriptions -GraphToken $graphToken
	Write-AuthenticatedIdentitySummary -Identity $authenticatedIdentity

	# Tenant-level Cloud Kerberos Trust check — used by Get-HostPoolSsoConfig for HAADJ pools.
	# Queried once here so it is not repeated per pool.
	$cloudKerberosTrust = $null
	if ($graphToken) {
		$cloudKerberosTrust = Get-CloudKerberosTrustStatus -GraphToken $graphToken
	}

	# Load Microsoft licence SKU display-name map from the CSV published by Microsoft.
	# Keyed by String_Id (SKU part number) -> Product_Display_Name. Each product has
	# multiple rows (one per service plan) so we take the first occurrence only.
	$skuDisplayNameMap = @{}
	$skuCsvPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'config\ms-service-plan-ids.csv'
	Write-CheckStart 'Licence SKU Map'
	if (Test-Path $skuCsvPath) {
		foreach ($row in (Import-Csv -Path $skuCsvPath)) {
			if (-not [string]::IsNullOrWhiteSpace($row.String_Id) -and
			    -not $skuDisplayNameMap.ContainsKey($row.String_Id)) {
				$skuDisplayNameMap[$row.String_Id] = $row.Product_Display_Name
			}
		}
		Write-CheckResult 'Success' "$($skuDisplayNameMap.Count) SKUs loaded"
	} else {
		Write-CheckResult 'Skipped' 'ms-service-plan-ids.csv not found — ProductName will be null'
	}
	$vmSizeMemCache  = @{}  # "subscriptionId/location" -> hashtable of size name -> memory GB
	$appGroupCache   = @{}  # subscriptionId -> all AVD app groups in that subscription
	$workspaceCache  = @{}  # subscriptionId -> all AVD workspaces in that subscription
	$vaultCache           = @{}  # subscriptionId -> Recovery Services Vaults in that subscription
	$allAuthorizedUserIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

	# Fetch all reservations once at tenant scope (best-effort — null if caller lacks access)
	$allReservations = $null
	Write-CheckStart 'Reservations'
	try {
		$resResp = Invoke-ArmRequest -Path '/providers/Microsoft.Capacity/reservations?api-version=2022-11-01&\$expand=renewProperties' -Method GET -ErrorAction SilentlyContinue
		if ($resResp -and $resResp.StatusCode -eq 200) {
			$allReservations = @(($resResp.Content | ConvertFrom-Json).value)
			Write-CheckResult 'Success' "$($allReservations.Count) reservation(s) for SKU matching"
		}
		elseif ($resResp -and $resResp.StatusCode -eq 403) {
			$allReservations = @()
			Write-CheckResult 'Skipped' 'No access to reservation orders'
		}
		else {
			Write-CheckResult 'Skipped' "HTTP $($resResp.StatusCode) — ReservationMatchStatus will be Unavailable"
		}
	}
	catch {
		Write-CheckResult 'Failed' $_.Exception.Message
	}

	$poolIndex   = 0
	$poolMetrics = foreach ($pool in $hostPools) {
		$poolIndex++
		$script:_progressActivity = "Host Pool Checks  [$poolIndex/$($hostPools.Count)]  $($pool.Name)"
		Write-PoolHeader -Index $poolIndex -Total $hostPools.Count -Pool $pool
		Set-AzContext -SubscriptionId $pool.SubscriptionId -WarningAction SilentlyContinue | Out-Null

		$vmSizeCacheKey = "$($pool.SubscriptionId)/$($pool.Location)"
		if (-not $vmSizeMemCache.ContainsKey($vmSizeCacheKey)) {
			$vmSizeMemCache[$vmSizeCacheKey] = Get-VmSizeMemoryGbMap -SubscriptionId $pool.SubscriptionId -Location $pool.Location
		}
		$vmSizeMemGbMap = $vmSizeMemCache[$vmSizeCacheKey]

		if (-not $appGroupCache.ContainsKey($pool.SubscriptionId)) {
			$agResp = Invoke-ArmRequest -Path "/subscriptions/$($pool.SubscriptionId)/providers/Microsoft.DesktopVirtualization/applicationGroups?api-version=2023-09-05" -Method GET -ErrorAction SilentlyContinue
			$appGroupCache[$pool.SubscriptionId] = if ($agResp -and $agResp.StatusCode -eq 200) { ($agResp.Content | ConvertFrom-Json).value } else { @() }

			$wsResp = Invoke-ArmRequest -Path "/subscriptions/$($pool.SubscriptionId)/providers/Microsoft.DesktopVirtualization/workspaces?api-version=2023-09-05" -Method GET -ErrorAction SilentlyContinue
			$workspaceCache[$pool.SubscriptionId] = if ($wsResp -and $wsResp.StatusCode -eq 200) { ($wsResp.Content | ConvertFrom-Json).value } else { @() }
		}

		Write-CheckStart 'Infrastructure'
		$infra = Get-HostPoolInfraInfo -HostPool $pool
		Write-CheckResult 'Success' "Hosts: $($infra.HostCount)  |  Running: $($infra.HostsRunning)  |  SKU(s): $(if ($infra.VmSkus) { $infra.VmSkus -join ', ' } else { 'N/A' })"

		Write-CheckStart 'RDP Properties'
		$rdpProperties = Get-ParsedRdpProperties -CustomRdpProperty $pool.CustomRdpProperty
		Write-CheckResult 'Success'

		Write-CheckStart 'Entra SSO'
		$ssoConfig = Get-HostPoolSsoConfig -Infra $infra -RdpProperties $rdpProperties -GraphToken $graphToken -CloudKerberosTrust $cloudKerberosTrust
		$_ssoDetail = switch ($ssoConfig.SsoType) {
			'EntraID'       { if ($ssoConfig.SsoEnabled) { "Enabled  |  Type: Entra ID" }         else { "Not configured  |  $(@($ssoConfig.Blockers).Count) blocker(s)" } }
			'HybridEntraID' { if ($ssoConfig.SsoEnabled) { "Enabled  |  Type: Hybrid Entra ID" }   else { "Not configured  |  $(@($ssoConfig.Blockers).Count) blocker(s)" } }
			'LegacyKerberos'{ "N/A  |  Pure AD joined (Kerberos only)" }
			default         { "Unknown join type — could not assess" }
		}
		$_ssoStatus = if ($ssoConfig.SsoType -eq 'LegacyKerberos') { 'Skipped' } elseif (-not $ssoConfig.SsoEnabled) { 'Failed' } else { 'Success' }
		Write-CheckResult $_ssoStatus $_ssoDetail

		Write-CheckStart 'Authorized Users'
		$authUsers = Get-HostPoolAuthorizedUsers -HostPool $pool -GraphToken $graphToken -AppGroupCache $appGroupCache -WorkspaceCache $workspaceCache
		foreach ($uid in $authUsers.AuthorizedUserIds) { $allAuthorizedUserIds.Add($uid) | Out-Null }
		Write-CheckResult 'Success' "Count: $($authUsers.AuthorizedUserCount)  |  Status: $($authUsers.AuthorizedUserStatus)"

		Write-CheckStart 'Registration Token'
		$regToken = Get-HostPoolRegistrationToken -HostPool $pool
		if ($regToken.HasActiveToken) {
			Write-CheckResult 'Success' "Active — expires $($regToken.ExpiresAt)"
		} else {
			Write-CheckResult 'Info' 'None — normal for steady-state pools'
		}

		Write-CheckStart 'Backup Info'
		$backupInfo = if ($pool.HostPoolType -eq 'Personal') {
			$_bi = Get-HostPoolBackupInfo -SubscriptionId $pool.SubscriptionId -VmResourceIds @($infra.VmResourceIds) -VaultCache $vaultCache
			Write-CheckResult 'Success' "Status: $($_bi.BackupInfoStatus)"
			$_bi
		} else {
			Write-CheckResult 'Skipped' 'Pooled host pool — not applicable'
			[PSCustomObject]@{ BackupInfo = $null; BackupInfoStatus = 'NotApplicable' }
		}

		Write-CheckStart 'Reservation Matches'
		$reservations = Get-ReservationMatches -VmSkus @(if ($infra.VmSkus) { $infra.VmSkus } else { @() }) -Location $pool.Location -AllReservations $allReservations
		Write-CheckResult 'Success' "Status: $($reservations.ReservationMatchStatus)"

		Write-CheckStart 'Usage Metrics'
		$metrics = Get-HostPoolDailyAverageUsers -HostPool $pool -StartTime $startTime -EndTime $endTime -ExcludeWeekends:$ExcludeWeekends -PeakHoursOnly:$PeakHoursOnly -UtcOffsetHours $UtcOffsetHours
		$_usageResult = if ($metrics.MetricStatus -match 'Error') { 'Failed' } elseif ($metrics.MetricStatus -match 'NoDiagnosticSettings|NoUserActivity|NoData') { 'Skipped' } else { 'Success' }
		Write-CheckResult $_usageResult "Avg Users/Day: $(if ($null -ne $metrics.DailyAverageUsers) { [Math]::Round($metrics.DailyAverageUsers, 1) } else { 'N/A' })  |  Status: $($metrics.MetricStatus)"

		Write-CheckStart 'Concurrent Sessions'
		$sessionMetrics = Get-HostPoolConcurrentSessionMetrics -HostPool $pool -StartTime $startTime -EndTime $endTime -ExcludeWeekends:$ExcludeWeekends -PeakHoursOnly:$PeakHoursOnly -UtcOffsetHours $UtcOffsetHours
		$_sessResult = if ($sessionMetrics.SessionsStatus -match 'Error') { 'Failed' } elseif ($sessionMetrics.SessionsStatus -match 'NoDiagnosticSettings|NoUserActivity|NoData') { 'Skipped' } else { 'Success' }
		Write-CheckResult $_sessResult "Peak: $(if ($null -ne $sessionMetrics.PeakConcurrentSessions) { $sessionMetrics.PeakConcurrentSessions } else { 'N/A' })  |  Status: $($sessionMetrics.SessionsStatus)"

		Write-CheckStart 'Hosts On / Off'
		$hostsOnMetrics = Get-HostPoolDailyHostsOn -VmResourceIds $infra.VmResourceIds -StartTime $startTime -EndTime $endTime -ExcludeWeekends:$ExcludeWeekends
		$_hostsOnResult = if ($hostsOnMetrics.DailyHostsOnStatus -match 'Error') { 'Failed' } elseif ($hostsOnMetrics.DailyHostsOnStatus -match 'NoVMs|NoData') { 'Skipped' } else { 'Success' }
		Write-CheckResult $_hostsOnResult "Avg Hosts On/Day: $(if ($null -ne $hostsOnMetrics.AverageHostsOnPerDay) { [Math]::Round($hostsOnMetrics.AverageHostsOnPerDay, 1) } else { 'N/A' })"

		Write-CheckStart 'CPU Metrics'
		$cpuMetrics = Get-HostPoolVmCpuMetrics -VmResourceIds $infra.VmResourceIds -StartTime $startTime -EndTime $endTime -ExcludeWeekends:$ExcludeWeekends -PeakHoursOnly:$PeakHoursOnly -UtcOffsetHours $UtcOffsetHours
		$_cpuResult = if ($cpuMetrics.CpuStatus -match 'Error') { 'Failed' } elseif ($cpuMetrics.CpuStatus -match 'NoVMs|NoData') { 'Skipped' } else { 'Success' }
		Write-CheckResult $_cpuResult "Avg: $(if ($null -ne $cpuMetrics.AvgCpuPercent) { "$($cpuMetrics.AvgCpuPercent)%" } else { 'N/A' })  |  P95: $(if ($null -ne $cpuMetrics.P95CpuPercent) { "$($cpuMetrics.P95CpuPercent)%" } else { 'N/A' })"

		Write-CheckStart 'Memory Metrics'
		$memMetrics = Get-HostPoolVmMemoryMetrics -VmResourceIds $infra.VmResourceIds -VmSizeMap $infra.VmSizeMap -VmSizeMemoryGbMap $vmSizeMemGbMap -StartTime $startTime -EndTime $endTime -ExcludeWeekends:$ExcludeWeekends -PeakHoursOnly:$PeakHoursOnly -UtcOffsetHours $UtcOffsetHours
		$_memResult = if ($memMetrics.MemoryStatus -match 'Error') { 'Failed' } elseif ($memMetrics.MemoryStatus -match 'NoVMs|NoData|NoSkuData') { 'Skipped' } else { 'Success' }
		Write-CheckResult $_memResult "Avg: $(if ($null -ne $memMetrics.AvgMemUsedPercent) { "$($memMetrics.AvgMemUsedPercent)%" } else { 'N/A' })  |  P95: $(if ($null -ne $memMetrics.P95MemUsedPercent) { "$($memMetrics.P95MemUsedPercent)%" } else { 'N/A' })"

		Write-CheckStart 'Diagnostic Insights'
		$diagInsights = Get-HostPoolDiagnosticInsights -HostPool $pool -StartTime $startTime -EndTime $endTime
		$_diagResult = if ($diagInsights.DiagnosticsStatus -match 'Error') { 'Failed' } elseif ($diagInsights.DiagnosticsStatus -match 'NoDiagnosticSettings') { 'Skipped' } else { 'Success' }
		Write-CheckResult $_diagResult "Status: $($diagInsights.DiagnosticsStatus)"

		if ($RunLocalDiscovery.IsPresent -and @($infra.VmResourceIds).Count -gt 0) {
			Write-Rule 'Local Discovery'
			Invoke-HostPoolLocalDiscovery -Pool $pool -VmResourceIds @($infra.VmResourceIds) -CustomerCode $customerCode -VmDiscoveryDirectory $resolvedVmDiscoveryDirectory -GitHubRawBaseUrl $gitHubRawBaseUrl -InlineLocalScript:$InlineLocalScript -TimeoutSeconds $LocalDiscoveryTimeout -RunAsCredential $runAsCredential
		} elseif ($RunLocalDiscovery.IsPresent) {
			Write-CheckStart 'Local Discovery'
			Write-CheckResult 'Skipped' 'No VM resource IDs found'
		}

		# Compute pool-level session host summary from the detail array
		$shDetails = @($infra.SessionHostDetails)
		$now       = [datetime]::UtcNow
		$totalCurrentSessions = [int]($shDetails | Where-Object { $null -ne $_.Sessions } | Measure-Object -Property Sessions -Sum).Sum
		$hostsAvailable   = @($shDetails | Where-Object { $_.Status -eq 'Available' }).Count
		# Keep running/shutdown counts on the same session-host status basis to avoid contradictory snapshots.
		$hostsShutdown    = @($shDetails | Where-Object { $_.Status -eq 'Shutdown' }).Count
		# Anything that is neither Available nor Shutdown (e.g. Unavailable, Disconnected, NeedsAssistance …)
		$hostsUnavailable = @($shDetails | Where-Object { $_.Status -ne 'Available' -and $_.Status -ne 'Shutdown' }).Count
		$hostsDraining    = @($shDetails | Where-Object { $_.AllowNewSession -eq $false }).Count
		# Only flag agents as stale if the host should be active (exclude Shutdown — agent is not running)
		# AVD agent heartbeats every few hours when idle; use a 24-hour threshold to avoid false positives
		$staleHeartbeatCount = @($shDetails | Where-Object {
			$_.Status -ne 'Shutdown' -and
			(-not $_.LastHeartBeat -or (($now - [datetime]$_.LastHeartBeat).TotalHours -gt 24))
		}).Count
		$agentVersions = @($shDetails | ForEach-Object { $_.AgentVersion } | Where-Object { -not [string]::IsNullOrEmpty($_) } | Select-Object -Unique | Sort-Object)

		[PSCustomObject]@{
			Name                 = $pool.Name
			FriendlyName         = $pool.FriendlyName
			SubscriptionId       = $pool.SubscriptionId
			SubscriptionName     = $pool.SubscriptionName
			ResourceGroup        = $pool.ResourceGroup
			Location             = $pool.Location
			Tags                 = $pool.Tags
			HostPoolType         = $pool.HostPoolType
			LoadBalancerType     = $pool.LoadBalancerType
			MaxSessionLimit      = $pool.MaxSessionLimit
			StartVMOnConnect     = $pool.StartVMOnConnect
			ValidationEnvironment           = $pool.ValidationEnvironment
			PersonalDesktopAssignmentType   = $pool.PersonalDesktopAssignmentType
			PreferredAppGroupType           = $pool.PreferredAppGroupType
			HostCount            = $infra.HostCount
			HostsRunning         = $infra.HostsRunning
			HostsAvailable       = $hostsAvailable
			HostsShutdown        = $hostsShutdown
			HostsUnavailable     = $hostsUnavailable
			HostsDraining        = $hostsDraining
			TotalCurrentSessions = $totalCurrentSessions
			StaleHeartbeatCount  = $staleHeartbeatCount
			AgentVersions        = $agentVersions
			VmNamePrefix         = $infra.VmNamePrefix
			VmSkus               = $infra.VmSkus
			VmSkusStatus         = $infra.VmSkusStatus
			VmPriorities         = $infra.VmPriorities
			VmSecurityTypes      = $infra.VmSecurityTypes
			AvailabilityZones    = $infra.AvailabilityZones
			EphemeralOsDisk      = $infra.EphemeralOsDisk
			AcceleratedNetworking = $infra.AcceleratedNetworking
			DomainJoinType       = $infra.DomainJoinType
			DomainName           = $infra.DomainName
			VmExtensions         = $infra.VmExtensions
			ImageReferences      = $infra.ImageReferences
			OsDiskSizeGb         = $infra.OsDiskSizeGb
			OsDiskSkus           = $infra.OsDiskSkus
			NetworkInfo          = $infra.NetworkInfo
			ReservationMatchStatus = $reservations.ReservationMatchStatus
			MatchedReservations    = $reservations.MatchedReservations
			ScalingPlan          = $infra.ScalingPlan
			RdpProperties        = $rdpProperties
			SsoConfig            = $ssoConfig
			RegistrationToken    = $regToken
			WorkspaceNames       = $authUsers.WorkspaceNames
			AppGroupNames        = $authUsers.AppGroupNames
			AppGroupDetails      = $authUsers.AppGroupDetails
			AccessAssignments    = $authUsers.AccessAssignments
			AuthorizedUserCount  = $authUsers.AuthorizedUserCount
			AuthorizedUserStatus = $authUsers.AuthorizedUserStatus
			SessionHostDetails       = if ($pool.HostPoolType -eq 'Personal' -and @($backupInfo.BackupInfo).Count -gt 0) {
				$backupLookup = @{}
				foreach ($backupEntry in @($backupInfo.BackupInfo)) {
					if (-not $backupEntry -or [string]::IsNullOrWhiteSpace([string]$backupEntry.VmName)) { continue }
					$backupLookup[(([string]$backupEntry.VmName -split '\.')[0]).ToLowerInvariant()] = $backupEntry
				}
				@($infra.SessionHostDetails | ForEach-Object {
					$backupEntry = $backupLookup[(([string]$_.Name -split '\.')[0]).ToLowerInvariant()]
					$_ | Select-Object -Property @(
						@{ Name = 'Name';                    Expression = { $_.Name } }
						@{ Name = 'Backup';                  Expression = { if ($backupEntry) { if ($backupEntry.IsBackedUp) { 'Backed Up' } else { 'Not Backed Up' } } else { $null } } }
						@{ Name = 'IpAddress';               Expression = { $_.IpAddress } }
						@{ Name = 'PublicIpAddress';         Expression = { $_.PublicIpAddress } }
						@{ Name = 'OutboundPublicIpAddress'; Expression = { $_.OutboundPublicIpAddress } }
						@{ Name = 'Status';                  Expression = { $_.Status } }
						@{ Name = 'Sessions';                Expression = { $_.Sessions } }
						@{ Name = 'AgentVersion';            Expression = { $_.AgentVersion } }
						@{ Name = 'LastHeartBeat';           Expression = { $_.LastHeartBeat } }
						@{ Name = 'AllowNewSession';         Expression = { $_.AllowNewSession } }
						@{ Name = 'AssignedUser';            Expression = { $_.AssignedUser } }
						@{ Name = 'UpdateState';             Expression = { $_.UpdateState } }
						@{ Name = 'OsVersion';               Expression = { $_.OsVersion } }
					)
				})
			} else {
				$infra.SessionHostDetails
			}
			AvgCpuPercent            = $cpuMetrics.AvgCpuPercent
			P95CpuPercent            = $cpuMetrics.P95CpuPercent
			P99CpuPercent            = $cpuMetrics.P99CpuPercent
			CpuDailyBreakdown        = $cpuMetrics.CpuDailyBreakdown
			CpuStatus                = $cpuMetrics.CpuStatus
			AverageHostsOnPerDay     = $hostsOnMetrics.AverageHostsOnPerDay
			DailyHostsOnStatus       = $hostsOnMetrics.DailyHostsOnStatus
			AvgMemUsedPercent        = $memMetrics.AvgMemUsedPercent
			P95MemUsedPercent        = $memMetrics.P95MemUsedPercent
			P99MemUsedPercent        = $memMetrics.P99MemUsedPercent
			MemoryDailyBreakdown     = $memMetrics.MemoryDailyBreakdown
			MemoryStatus             = $memMetrics.MemoryStatus
			DailyAverageUsers        = $metrics.DailyAverageUsers
			MetricStatus             = $metrics.MetricStatus
			DataPointCount           = $metrics.DataPointCount
			DailyBreakdown           = $metrics.DailyBreakdown
			PeakConcurrentSessions   = $sessionMetrics.PeakConcurrentSessions
			DailyPeakBreakdown       = $sessionMetrics.DailyPeakBreakdown
			SessionsStatus           = $sessionMetrics.SessionsStatus
			# All fields below are sourced from AVD Insights (Log Analytics / WVD* tables).
			# Counts cover the query window defined by -StartTime / -EndTime (default: last 30 days).
			InsightsDiagnostics = [PSCustomObject]@{
				# Log Analytics workspace receiving AVD diagnostic logs for this pool
				LogAnalyticsWorkspace    = $diagInsights.LogAnalyticsWorkspace
				# Diagnostic categories enabled in the pool's diagnostic settings
				DiagnosticCategories     = $diagInsights.DiagnosticCategories
				# Status of the KQL queries ('OK', 'NoDiagnosticSettings', 'PartialData …', 'Error …')
				QueryStatus              = $diagInsights.DiagnosticsStatus
				# Query window used for all counts below (ISO 8601 UTC)
				QueryWindowStart         = $startTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
				QueryWindowEnd           = $endTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
				# Timestamp of the most recent successfully established user connection (WVDConnections, State=Connected)
				LastSuccessfulConnection = $diagInsights.LastSuccessfulConnection
				# Total WVDErrors rows in the query window (includes all severity levels)
				TotalErrors              = $diagInsights.TotalErrors
				# Connections that reached State=Failed in WVDConnections
				TotalFailedConnections   = $diagInsights.TotalFailedConnections
				# Errors from the RDGateway/ShortPath source — indicates UDP shortpath problems
				ShortpathErrors          = $diagInsights.ShortpathErrors
				# WVDCheckpoints where Name='ShortpathTransportConnected' — successful UDP upgrades
				ShortpathUpgradeEvents   = $diagInsights.ShortpathUpgradeEvents
				# WVDHostRegistrations rows — agent re-registrations (elevated count may indicate instability)
				HostRegistrationEvents          = $diagInsights.HostRegistrationEvents
				# 'Healthy' = no re-registrations; 'Low/Moderate/Elevated' = re-registration count band
				HostRegistrationHealthSummary   = $diagInsights.HostRegistrationHealthSummary
				# Top distinct errors by count in the query window (max 20)
				TopErrors                = $diagInsights.TopErrors
				# RDP transport types used for connections (TCP Websocket vs UDP Shortpath)
				TransportTypeBreakdown   = $diagInsights.TransportTypeBreakdown
				# Per-host agent re-registration counts
				HostRegistrationBreakdown = $diagInsights.HostRegistrationBreakdown
			}
		}
	}

	Write-Rule 'LICENCE CHECKS'
	Write-CheckStart 'Licence Assignments'
	if ($SkipLicenceCheck.IsPresent) {
		$licSummary = [PSCustomObject]@{
			LicenseSummary       = @()
			LicenseSummaryStatus = 'Skipped'
			UnlicensedUserCount  = $null
			UnlicensedUsers      = @()
		}
		Write-CheckResult 'Skipped' '-SkipLicenceCheck specified'
	} else {
		$licSummary = Get-UserLicenseSummary -UserObjectIds @($allAuthorizedUserIds) -GraphToken $graphToken -SkuDisplayNameMap $skuDisplayNameMap
		if ($licSummary.LicenseSummaryStatus -eq 'OK') {
			$_unlicWarn = if ($licSummary.UnlicensedUserCount -gt 0) { "  ⚠ $($licSummary.UnlicensedUserCount) unlicensed" } else { '' }
			Write-CheckResult 'Success' "$(@($licSummary.LicenseSummary).Count) SKU(s) found  |  $($allAuthorizedUserIds.Count) user(s)$_unlicWarn"
		} else {
			Write-CheckResult 'Skipped' "Status: $($licSummary.LicenseSummaryStatus)"
		}
	}

	# ── Storage Account FSLogix scan ─────────────────────────────────────────
	# Stop the pool-phase spinner and reset counters — storage scan has its own checks
	# and doesn't share the pool progress total.
	Stop-SpinnerRunspace
	$script:_progressStep  = 0
	$script:_progressTotal = 0
	$storageResults = @()
	if ($PSBoundParameters.ContainsKey('ScanStorageAccounts')) {
		# Resolve the list of names: outer @() prevents pipeline unwrapping of single-element arrays
		$_saNames = @(if ($ScanStorageAccounts -and @($ScanStorageAccounts).Count -gt 0) {
			$ScanStorageAccounts
		} else {
			Get-StorageAccountInput
		})

		if ($_saNames.Count -gt 0) {
			Write-Rule 'STORAGE ACCOUNT SCAN'
			Write-CheckStart 'Locating Storage Accounts'
			$_saResources = @(Get-StorageAccountByName -Names $_saNames -Subscriptions $subscriptions)
			if ($_saResources.Count -eq 0) {
				Write-CheckResult 'Failed' "None of the specified account(s) found across $(@($subscriptions).Count) subscription(s)"
			} else {
				$_notFound = @($_saNames | Where-Object {
					$_n = $_
					-not ($_saResources | Where-Object { $_.Resource.name -eq $_n })
				})
				$_detail = "$($_saResources.Count) found"
				if ($_notFound.Count -gt 0) { $_detail += "  |  Not found: $($_notFound -join ', ')" }
				Write-CheckResult 'Success' $_detail

				$_saIdx = 0
				foreach ($_saEntry in $_saResources) {
					$_saIdx++
					$_saName = $_saEntry.Resource.name
					$_bar    = '─' * 66
					Write-Host ''
					Write-Host "  `e[90m$_bar`e[0m"
					Write-Host "  `e[1m`e[97mSTORAGE ACCOUNT [$_saIdx/$($_saResources.Count)]`e[0m  `e[96m$_saName`e[0m"
					Write-Host "  `e[90mSubscription : $($_saEntry.SubscriptionName)  |  RG : $($_saEntry.ResourceGroup)  |  Region : $($_saEntry.Resource.location)`e[0m"
					Write-Host "  `e[90m$_bar`e[0m"
					Write-CheckStart 'Storage Account Details'
					$_saInfo = Get-StorageAccountFSLogixInfo -StorageAccount $_saEntry -VaultCache $vaultCache
					$_skuStr = "$($_saInfo.Sku)  ($($_saInfo.ReplicationType))"
					Write-CheckResult 'Success' "SKU: $_skuStr  |  Kind: $($_saInfo.Kind)  |  Shares: $($_saInfo.FileShareCount)"

					Write-CheckStart 'Security'
					$_secDetail = "Access Keys: $(if ($_saInfo.AccessKeysEnabled) { 'Enabled' } else { 'Disabled' })  |  " +
					              "Encryption: $($_saInfo.EncryptionType)  |  " +
					              "Public Access: $($_saInfo.PublicNetworkAccess)"
					Write-CheckResult 'Success' $_secDetail

					Write-CheckStart 'Network'
					$_netDetail = "Default Action: $($_saInfo.NetworkDefaultAction)  |  Private Endpoints: $($_saInfo.PrivateEndpointCount)"
					Write-CheckResult 'Success' $_netDetail

					Write-CheckStart 'Identity Auth'
					if ($null -ne $_saInfo.IdentityBasedAuth -and $_saInfo.IdentityBasedAuth.DirectoryServiceOptions -ne 'None') {
						$_idType   = $_saInfo.IdentityBasedAuth.DirectoryServiceOptions
						$_idPerm   = if ($_saInfo.IdentityBasedAuth.DefaultSharePermission) { "Default Permission: $($_saInfo.IdentityBasedAuth.DefaultSharePermission)" } else { 'No default permission' }
						$_idDomain = if ($_saInfo.IdentityBasedAuth.DomainName) { "  |  Domain: $($_saInfo.IdentityBasedAuth.DomainName)" } else { '' }
						Write-CheckResult 'Success' "Type: $_idType  |  $_idPerm$_idDomain"
					} else {
						Write-CheckResult 'Skipped' 'Identity-based access not configured'
					}

					Write-CheckStart 'SMB / File Service'
					$_smbMulti   = if ($null -ne $_saInfo.FileService.SmbMultichannel) { "Multichannel: $(if ($_saInfo.FileService.SmbMultichannel) { 'Enabled' } else { 'Disabled' })" } else { 'Multichannel: N/A' }
					$_softDel    = "Soft Delete: $(if ($_saInfo.FileService.SoftDeleteEnabled) { "Yes ($($_saInfo.FileService.SoftDeleteRetainDays)d)" } else { 'No' })"
					Write-CheckResult 'Success' "$_smbMulti  |  $_softDel"

					if ($_saInfo.FileShareCount -gt 0) {
						Write-Host ''
						Write-Host '      File Shares:' -ForegroundColor DarkGray
						foreach ($_share in $_saInfo.FileShares) {
							$_tierLabel = if ($_share.Tier) { " `e[90m[$($_share.Tier)]`e[0m" } else { '' }
							Write-Host "        `e[97m$($_share.Name)`e[0m$_tierLabel"
							$_col = '          '
							$_provStr = if ($null -ne $_share.ProvisionedSizeGb) { "$($_share.ProvisionedSizeGb) GB" } else { 'N/A' }
							$_usedStr = if ($null -ne $_share.UsedSizeGb) { "$($_share.UsedSizeGb) GB ($($_share.UsedPercent)% used)" } elseif (-not $_share.UsageStatsAvailable) { 'N/A (Premium tier)' } else { 'N/A' }
							Write-Host "${_col}`e[90mProvisioned  :`e[0m  $_provStr"
							Write-Host "${_col}`e[90mUsed         :`e[0m  $_usedStr"
							if ($null -ne $_share.ProvisionedIops) {
								Write-Host "${_col}`e[90mIOPS         :`e[0m  $($_share.ProvisionedIops)"
							}
							if ($null -ne $_share.ProvisionedBandwidthMiBps) {
								Write-Host "${_col}`e[90mBandwidth    :`e[0m  $($_share.ProvisionedBandwidthMiBps) MiB/s"
							}
							$_bakStr = if ($_share.BackupEnabled) { "`e[92m✓ Enabled`e[0m" } else { "`e[90m✗ Disabled`e[0m" }
							Write-Host "${_col}`e[90mBackup       :`e[0m  $_bakStr"
						}
					}

					$storageResults += $_saInfo
				}
			}
		} else {
			Write-Rule 'STORAGE ACCOUNT SCAN'
			Write-Host '  No storage account names provided — skipping scan.' -ForegroundColor DarkYellow
		}
	}

	$exportObject = [PSCustomObject]@{
		CustomerAbbreviation    = $customerCode
		GeneratedBy             = if ([string]::IsNullOrWhiteSpace($GeneratedBy)) { $null } else { $GeneratedBy }
		ProjectCode             = if ([string]::IsNullOrWhiteSpace($ProjectCode))  { $null } else { $ProjectCode }
		CollectedAt             = (Get-Date).ToString('s')
		AuthenticatedIdentity   = $authenticatedIdentity
		MetricPeriodStart       = $startTime.ToString('s')
		MetricPeriodEnd         = $endTime.ToString('s')
		LookbackDays            = $LookbackDays
		ExcludeWeekends         = $ExcludeWeekends.IsPresent
		PeakHoursOnly           = $PeakHoursOnly.IsPresent
		UtcOffsetHours          = $UtcOffsetHours
		CommandOptions          = [PSCustomObject]@{
			SubscriptionId        = if ($SubscriptionId) { $SubscriptionId } else { $null }
			LookbackDays          = $LookbackDays
			CustomerAbbreviation  = $customerCode
			ExcludeWeekends       = $ExcludeWeekends.IsPresent
			PeakHoursOnly         = $PeakHoursOnly.IsPresent
			UtcOffsetHours        = $UtcOffsetHours
			HostPoolName          = if ($HostPoolName) { $HostPoolName } else { $null }
			RunLocalDiscovery     = $RunLocalDiscovery.IsPresent
			InlineLocalScript     = $InlineLocalScript.IsPresent
			NoGpresult            = $NoGpresult.IsPresent
			NoHtml                = $NoHtml.IsPresent
			SkipLicenceCheck      = $SkipLicenceCheck.IsPresent
			RunAsUser             = $RunAsUser.IsPresent
			GitHubBranch          = $GitHubBranch
			LocalDiscoveryTimeout = $LocalDiscoveryTimeout
			OutputDirectory       = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $null } else { $OutputDirectory }
			ScanStorageAccounts   = if ($ScanStorageAccounts -and $ScanStorageAccounts.Count -gt 0) { $ScanStorageAccounts } else { $null }
		}
		SubscriptionCount       = @($subscriptions).Count
		HostPoolCount           = $hostPools.Count
		LicenseSummaryUserCount = $allAuthorizedUserIds.Count
		LicenseSummaryStatus    = $licSummary.LicenseSummaryStatus
		LicenseSummary          = $licSummary.LicenseSummary
		UnlicensedUserCount     = $licSummary.UnlicensedUserCount
		UnlicensedUsers         = $licSummary.UnlicensedUsers
		HostPools               = $poolMetrics
		StorageAccountScan      = $storageResults
		ArmCallStats            = [PSCustomObject]@{
			ReadCount                    = $script:armCounts.Read
			WriteCount                   = $script:armCounts.Write
			ReadLimitPerHour             = 12000
			WriteLimitPerHour            = 1200
			ReadLimitUtilisationPercent  = [Math]::Round($script:armCounts.Read  / 12000 * 100, 2)
			WriteLimitUtilisationPercent = [Math]::Round($script:armCounts.Write / 1200  * 100, 2)
		}
		ReportType             = 'AvdMetrics'
		HtmlGeneration         = [PSCustomObject]@{
			Requested       = -not $NoHtml.IsPresent
			Status          = if ($NoHtml.IsPresent) { 'Skipped' } else { 'Pending' }
			Message         = if ($NoHtml.IsPresent) { '-NoHtml specified.' } else { 'Awaiting shared HTML generation.' }
			HtmlPath        = $null
			GeneratorScript = $null
			GeneratedAt     = $null
		}
	}

	$exportObject | ConvertTo-Json -Depth 8 | Set-Content -Path $resolvedOutputPath -Encoding UTF8
	$resolvedHtmlPath = [System.IO.Path]::ChangeExtension($resolvedOutputPath, '.html')
	if (-not $NoHtml.IsPresent) {
		$exportObject.HtmlGeneration = Invoke-OptionalHtmlReportGeneration -JsonPath $resolvedOutputPath -ReportType $exportObject.ReportType -OutputPath $resolvedHtmlPath
	}
	$exportObject | ConvertTo-Json -Depth 8 | Set-Content -Path $resolvedOutputPath -Encoding UTF8

	Clear-SpinnerLine
	$_elapsed = $scriptStopwatch.Elapsed
	$_elapsedStr = if ($_elapsed.TotalMinutes -ge 1) {
		"$([Math]::Floor($_elapsed.TotalMinutes))m $($_elapsed.Seconds)s"
	} else { "$([Math]::Round($_elapsed.TotalSeconds, 1))s" }

	Write-Rule
	Write-Host "  `e[92mCollection complete in $_elapsedStr`e[0m"
	Write-Host "  Host pools  :  $($hostPools.Count)" -ForegroundColor DarkGray
	$_readPct  = [Math]::Round($script:armCounts.Read  / 12000 * 100, 1)
	$_writePct = [Math]::Round($script:armCounts.Write / 1200  * 100, 1)
	$_armColor = if ($_readPct -gt 80 -or $_writePct -gt 80) { 'Yellow' } else { 'DarkGray' }
	Write-Host "  ARM calls   :  $($script:armCounts.Read) reads ($_readPct% of 12,000/hr)  |  $($script:armCounts.Write) writes ($_writePct% of 1,200/hr)" -ForegroundColor $_armColor
	Write-Host "  Output file :  $resolvedOutputPath" -ForegroundColor Cyan
	if ($exportObject.HtmlGeneration.Status -eq 'Generated') {
		Write-Host "  HTML report :  $($exportObject.HtmlGeneration.HtmlPath)" -ForegroundColor Cyan
	}
	Write-Host ''
}
catch {
	$_errLine = if ($_.InvocationInfo) { " [line $($_.InvocationInfo.ScriptLineNumber)]" } else { '' }
	Write-Error "AVD metrics collection failed.$_errLine $($_.Exception.Message)"
	exit 1
}
finally {
	# Restore the caller's original Az context so this script's subscription
	# switches do not alter the active context in the calling session.
	if ($null -ne $originalContext) {
		Set-AzContext -Context $originalContext -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null
	}
}

