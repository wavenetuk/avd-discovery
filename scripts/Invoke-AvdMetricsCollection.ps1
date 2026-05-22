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
     Approved cmdlets: Get-AzContext, Get-AzSubscription, Set-AzContext,
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
  - Authenticated via Connect-AzAccount
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
			position: relative;
			overflow: hidden;
		}
		.chip strong,
		.chip span {
			min-width: 0;
			overflow-wrap: anywhere;
		}
		.chip > * {
			position: relative;
			z-index: 1;
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
		.interactive-surface {
			transition: border-color 180ms ease;
		}
		.interactive-surface:hover {
			border-color: rgba(0, 109, 203, 0.24);
		}
		.card.interactive-surface:hover {
			border-color: rgba(84, 161, 246, 0.30);
		}
		.chip.interactive-surface:hover {
			border-color: rgba(84, 161, 246, 0.34);
		}
		.badge.interactive-surface {
			border: 1px solid transparent;
			transition: border-color 180ms ease, box-shadow 180ms ease, background-color 180ms ease;
		}
		.badge.interactive-surface:hover {
			border-color: rgba(84, 161, 246, 0.34);
			box-shadow: 0 0 0 1px rgba(84, 161, 246, 0.18);
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
			opacity: 0.86;
			transition: opacity 180ms ease;
		}
		.card.interactive-surface:hover::after {
			opacity: 1;
		}
		.card > * {
			position: relative;
			z-index: 1;
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
			overflow-wrap: anywhere;
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
			display: grid;
			grid-template-columns: minmax(170px, 220px) minmax(0, 1fr);
			align-items: flex-start;
			gap: 12px;
			padding-bottom: 8px;
			border-bottom: 1px solid var(--line);
			font-size: 14px;
		}
		.stat-row:last-child { border-bottom: 0; padding-bottom: 0; }
		.stat-row strong {
			min-width: 0;
			overflow-wrap: anywhere;
			word-break: break-word;
		}
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
		.host-pool-jump {
			color: var(--ink);
			font-weight: 600;
			text-decoration: none;
			border-bottom: 1px solid rgba(22, 55, 92, 0.18);
			transition: color 140ms ease, border-color 140ms ease;
		}
		.host-pool-jump:hover,
		.host-pool-jump:focus-visible {
			color: var(--accent);
			border-bottom-color: rgba(22, 55, 92, 0.44);
			outline: none;
		}
		tr.detail-row:hover {
			background: transparent;
		}
		tr.detail-row > td {
			white-space: normal;
			padding-top: 0;
			padding-bottom: 16px;
			border-bottom: 1px solid var(--line);
		}
		.table-detail {
			margin-top: 2px;
		}
		.table-detail > summary {
			font-size: 12px;
			font-weight: 700;
			color: var(--muted);
		}
		.table-detail[open] > summary {
			margin-bottom: 10px;
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
		.badge.tier-gold {
			background: rgba(191, 145, 0, 0.18);
			color: #8a6400;
		}
		.badge.tier-red {
			background: rgba(181, 39, 45, 0.16);
			color: #a1232a;
		}
		.badge.tier-blue {
			background: rgba(0, 92, 168, 0.16);
			color: #0058a8;
		}
		.badge.tier-slate {
			background: rgba(66, 84, 102, 0.15);
			color: #425466;
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
		td details.inline-detail {
			margin: 0;
			padding: 8px 10px;
			background: rgba(244, 247, 250, 0.98);
		}
		td details.inline-detail > summary {
			font-size: 12px;
			font-weight: 600;
			color: var(--muted);
		}
		td details.inline-detail[open] > summary {
			margin-bottom: 8px;
		}
		td details.inline-detail > .table-wrap,
		td details.inline-detail > .key-value,
		td details.inline-detail > details,
		td details.inline-detail > div {
			margin-top: 8px;
		}
		.detail-summary {
			display: inline-flex;
			align-items: center;
			max-width: min(320px, 100%);
			padding: 5px 10px;
			border-radius: 999px;
			background: rgba(0, 109, 203, 0.09);
			color: #0058a8;
			font-size: 12px;
			font-weight: 700;
			line-height: 1.35;
			white-space: normal;
			overflow-wrap: anywhere;
		}
		.detail-stack {
			display: grid;
			gap: 10px;
		}
		.structured-detail {
			margin-top: 4px;
		}
		.structured-detail-grid {
			display: grid;
			gap: 10px;
			margin-top: 10px;
		}
		.structured-detail-grid > details {
			background: rgba(252, 253, 254, 0.82);
		}
		.share-list {
			display: grid;
			gap: 10px;
		}
		.share-item {
			padding: 12px;
			border-radius: 14px;
			background: rgba(247, 249, 251, 0.98);
			border: 1px solid rgba(29, 37, 44, 0.10);
		}
		.share-title {
			display: flex;
			align-items: center;
			justify-content: space-between;
			gap: 10px;
			margin-bottom: 8px;
		}
		.share-title strong {
			word-break: break-word;
			color: #000000;
		}
		.share-meta {
			display: flex;
			flex-wrap: wrap;
			gap: 6px;
		}
		.share-meta .badge {
			font-size: 0.72rem;
		}
		.pool-stack {
			display: grid;
			gap: 16px;
		}
		.pool-panel {
			padding: 18px;
			border-radius: 18px;
			border: 1px solid rgba(29, 37, 44, 0.10);
			background: linear-gradient(180deg, rgba(255, 255, 255, 0.98), rgba(246, 248, 250, 0.96));
			box-shadow: 0 16px 34px rgba(29, 37, 44, 0.07), inset 0 1px 0 rgba(255, 255, 255, 0.64);
			backdrop-filter: blur(12px) saturate(108%);
			-webkit-backdrop-filter: blur(12px) saturate(108%);
			position: relative;
			overflow: visible;
		}
		.pool-panel::after {
			content: "";
			position: absolute;
			inset: 0;
			background:
				linear-gradient(180deg, rgba(0, 109, 203, 0.02), transparent 32%),
				radial-gradient(circle at top left, rgba(0, 109, 203, 0.025), transparent 32%);
			pointer-events: none;
		}
		.pool-panel h3 {
			margin: 0;
			font-size: 22px;
			letter-spacing: -0.03em;
			color: #000000;
		}
		.pool-header {
			display: flex;
			align-items: center;
			justify-content: space-between;
			gap: 14px;
			margin: 0 0 6px;
		}
		.pool-title-wrap {
			display: inline-flex;
			align-items: center;
			gap: 10px;
			min-width: 0;
		}
		.pool-warning {
			display: inline-flex;
			align-items: center;
			justify-content: center;
			position: relative;
			flex: 0 0 auto;
			width: 18px;
			height: 18px;
			z-index: 8;
			cursor: help;
		}
		.pool-warning-icon {
			position: relative;
			z-index: 1;
			width: 100%;
			height: 100%;
			background-repeat: no-repeat;
			background-position: center;
			background-size: contain;
			background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E%3Cdefs%3E%3ClinearGradient id='g' x1='0' y1='0' x2='0' y2='1'%3E%3Cstop offset='0' stop-color='%23ffe58a'/%3E%3Cstop offset='0.56' stop-color='%23ffd23d'/%3E%3Cstop offset='1' stop-color='%23ffbf1f'/%3E%3C/linearGradient%3E%3C/defs%3E%3Cpath d='M32 7 58 55a4 4 0 0 1-3.5 6H9.5A4 4 0 0 1 6 55L32 7Z' fill='url(%23g)' stroke='%2316171c' stroke-width='4.5' stroke-linejoin='round'/%3E%3Cpath d='M32 22c2.1 0 3.3 1.3 3.2 3.4l-1.4 15.1a1.8 1.8 0 0 1-3.6 0l-1.4-15.1c-.1-2.1 1.1-3.4 3.2-3.4Z' fill='%2316171c'/%3E%3Ccircle cx='32' cy='47.5' r='3.9' fill='%2316171c'/%3E%3Cpath d='M18 28c3.5-5.8 8.8-11.6 15.2-16.4' stroke='%23fff8d6' stroke-opacity='.55' stroke-width='3' stroke-linecap='round'/%3E%3C/svg%3E");
			filter: drop-shadow(0 1px 0 rgba(255, 255, 255, 0.35));
		}
		.pool-warning::after {
			content: attr(data-tooltip);
			position: absolute;
			top: calc(100% + 8px);
			left: -10px;
			right: auto;
			width: var(--warning-tooltip-width, 220px);
			max-width: calc(100vw - 40px);
			padding: 8px 10px;
			border-radius: 8px;
			border: 1px solid rgba(15, 23, 32, 0.28);
			background: rgba(24, 32, 42, 0.96);
			color: #ffffff;
			font-size: 12px;
			line-height: 1.45;
			text-align: left;
			text-shadow: none;
			box-shadow: 0 18px 36px rgba(0, 0, 0, 0.34);
			z-index: 40;
			opacity: 0;
			pointer-events: none;
			transform: translateY(-4px);
			transition: opacity 140ms ease, transform 140ms ease;
		}
		.pool-warning::before {
			content: '';
			position: absolute;
			top: calc(100% + 1px);
			left: 14px;
			width: 0;
			height: 0;
			border-left: 6px solid transparent;
			border-right: 6px solid transparent;
			border-bottom: 7px solid rgba(24, 32, 42, 0.96);
			z-index: 39;
			opacity: 0;
			pointer-events: none;
			transform: translateY(-4px);
			transition: opacity 140ms ease, transform 140ms ease;
		}
		.pool-warning.tooltip-flip::after {
			left: auto;
			right: -10px;
		}
		.pool-warning.tooltip-flip::before {
			left: auto;
			right: 14px;
		}
		.pool-warning:hover::after,
		.pool-warning:focus-visible::after {
			opacity: 1;
			transform: translateY(0);
		}
		.pool-warning:hover::before,
		.pool-warning:focus-visible::before {
			opacity: 1;
			transform: translateY(0);
		}
		.pool-panel > p {
			margin: 0 0 14px;
			color: var(--muted);
		}
		.pool-highlights {
			display: flex;
			flex-wrap: wrap;
			gap: 10px;
			margin: 0;
			justify-content: flex-end;
		}
		.pool-highlights .chip {
			padding: 9px 14px;
			background: linear-gradient(180deg, rgba(233, 244, 255, 0.98), rgba(219, 237, 252, 0.94));
			border: 1px solid rgba(0, 109, 203, 0.16);
			box-shadow: 0 10px 22px rgba(0, 109, 203, 0.08), inset 0 1px 0 rgba(255, 255, 255, 0.72);
		}
		.pool-highlights .chip strong {
			color: #0b4f8a;
		}
		.pool-highlights .chip span {
			color: #0f1720;
		}
		.pool-highlights .chip[data-chip-label="subscription"] {
			background: linear-gradient(180deg, rgba(233, 249, 240, 0.98), rgba(214, 241, 226, 0.94));
			border-color: rgba(28, 132, 86, 0.18);
			box-shadow: 0 10px 22px rgba(28, 132, 86, 0.10), inset 0 1px 0 rgba(255, 255, 255, 0.72);
		}
		.pool-highlights .chip[data-chip-label="subscription"] strong {
			color: #116946;
		}
		.pool-highlights .chip[data-chip-label="resource-group"] {
			background: linear-gradient(180deg, rgba(255, 244, 227, 0.98), rgba(251, 233, 202, 0.94));
			border-color: rgba(181, 118, 28, 0.20);
			box-shadow: 0 10px 22px rgba(181, 118, 28, 0.10), inset 0 1px 0 rgba(255, 255, 255, 0.72);
		}
		.pool-highlights .chip[data-chip-label="resource-group"] strong {
			color: #9a5d10;
		}
		.pool-grid {
			display: grid;
			grid-template-columns: repeat(3, minmax(0, 1fr));
			gap: 12px;
		}
		.pool-grid.featured {
			grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
			margin-bottom: 12px;
		}
		.pool-divider {
			height: 1px;
			margin: 4px 0 14px;
			background: linear-gradient(90deg, rgba(0, 109, 203, 0.02), rgba(0, 109, 203, 0.28), rgba(0, 109, 203, 0.02));
			box-shadow: none;
		}
		.card.accent-cpu {
			background: linear-gradient(180deg, rgba(109, 146, 214, 0.94), rgba(74, 108, 167, 0.90));
		}
		.card.accent-memory {
			background: linear-gradient(180deg, rgba(104, 165, 186, 0.94), rgba(65, 113, 133, 0.90));
		}
		.card.accent-usage {
			background: linear-gradient(180deg, rgba(132, 123, 213, 0.94), rgba(88, 80, 157, 0.90));
		}
		.card[class*="accent-"] {
			color: #f8fbff;
			border-color: rgba(29, 37, 44, 0.16);
			box-shadow: none;
			filter: drop-shadow(0 0 14px rgba(16, 24, 40, 0.18)) drop-shadow(0 0 30px rgba(16, 24, 40, 0.12));
			backdrop-filter: none;
			-webkit-backdrop-filter: none;
		}
		.card[class*="accent-"]::after {
			background: linear-gradient(180deg, rgba(255, 255, 255, 0.16), rgba(255, 255, 255, 0.05) 38%, transparent 74%);
			opacity: 0.24;
			transition: opacity 220ms ease;
		}
		.card[class*="accent-"].interactive-surface:hover {
			border-color: rgba(210, 228, 255, 0.42);
		}
		.card[class*="accent-"].interactive-surface:hover::after {
			opacity: 0.44;
		}
		.card[class*="accent-"] .eyebrow {
			color: rgba(244, 248, 255, 0.92);
		}
		.card[class*="accent-"] .metric {
			color: #ffffff;
			text-shadow: 0 1px 1px rgba(16, 24, 40, 0.18);
		}
		.card[class*="accent-"] .subtle {
			color: rgba(239, 245, 252, 0.90);
		}
		.pool-details {
			margin-top: 14px;
			display: grid;
			gap: 10px;
		}
		.pool-meta {
			display: grid;
			grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
			align-items: stretch;
			gap: 10px;
			margin: 0 0 14px;
		}
		.pool-meta .chip {
			display: flex;
			flex-direction: column;
			align-items: flex-start;
			justify-content: center;
			gap: 4px;
			min-height: 58px;
			padding: 10px 12px;
			border-radius: 16px;
			font-size: 12px;
			background: rgba(255, 255, 255, 0.72);
			box-shadow: 0 8px 18px rgba(29, 37, 44, 0.04), inset 0 0 14px rgba(29, 37, 44, 0.02), inset 0 1px 0 rgba(255, 255, 255, 0.66);
		}
		.pool-meta .chip span {
			display: block;
			width: 100%;
			line-height: 1.35;
			white-space: nowrap;
			overflow: hidden;
			text-overflow: ellipsis;
		}
		.pool-meta .chip strong {
			color: #101828;
		}
		.pool-details > details {
			padding: 12px 14px;
		}
		.pool-details > details[open] > summary {
			margin-bottom: 10px;
		}
		.pool-details > details > .table-wrap,
		.pool-details > details > .key-value,
		.pool-details > details > details,
		.pool-details > details > div {
			margin-top: 10px;
		}
		.pool-details .platform-detail {
			margin-top: 6px;
			padding: 14px 16px 16px;
		}
		.pool-details .platform-detail[open] > summary {
			margin-bottom: 14px;
		}
		.pool-details .platform-detail > details + details {
			margin-top: 14px;
		}
		.pool-details .platform-detail details {
			background: #f8f9fb;
		}
		.pool-details .platform-detail details[open] > summary {
			margin-bottom: 10px;
		}
		.pool-details .platform-detail details > .table-wrap,
		.pool-details .platform-detail details > .key-value,
		.pool-details .platform-detail details > details,
		.pool-details .platform-detail details > div {
			margin-top: 10px;
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
			.stat-row { grid-template-columns: 1fr; gap: 4px; }
			.toolbar { align-items: stretch; }
			.toolbar input { width: 100%; }
			.section-grid { grid-template-columns: 1fr; }
			.pool-header { flex-direction: column; align-items: flex-start; }
			.pool-title-wrap { width: 100%; }
			.pool-highlights { justify-content: flex-start; width: 100%; }
			.pool-grid.featured { grid-template-columns: 1fr; }
			.pool-grid { grid-template-columns: 1fr; }
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
		<section class="section hidden" id="host-pool-section">
			<h2>Host Pool Detail</h2>
			<p>Operational, performance, and usage groupings for each pool in this export.</p>
			<div class="pool-stack" id="host-pool-stack"></div>
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
		data.HostPools = normalizeCollection(data.HostPools).map(({ BackupInfo, BackupInfoStatus, ...pool }) => pool);

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

		function formatValue(value) {
			if (value === null || value === undefined || value === '') { return 'None'; }
			if (typeof value === 'boolean') { return value ? 'Yes' : 'No'; }
			if (typeof value === 'number') {
				if (Math.abs(value) >= 1000) { return value.toLocaleString(); }
				return Number.isInteger(value) ? String(value) : value.toFixed(2).replace(/\.00$/, '');
			}
			if (Array.isArray(value)) { return value.length ? value.join(', ') : 'None'; }
			if (isPlainObject(value)) { return Object.keys(value).length + ' field(s)'; }
			return String(value);
		}

		function formatPercentValue(value) {
			const numeric = toNumber(value);
			if (numeric === null) { return 'n/a'; }
			return formatValue(numeric) + '%';
		}

		function formatFieldValue(key, value) {
			const compactKey = key ? String(key).replace(/[^A-Za-z0-9]/g, '').toLowerCase() : '';
			if (compactKey === 'maxsessionlimit') {
				const numeric = toNumber(value);
				if (numeric !== null && numeric >= 999999) { return 'No Limit Set'; }
			}
			if (new Set(['avgcpupercent', 'avgmemusedpercent', 'p95cpupercent', 'p95memusedpercent']).has(compactKey)) {
				return formatPercentValue(value);
			}
			return formatValue(value);
		}

		function resolveUnavailableMetricText(key, value, context) {
			if (!(value === null || value === undefined || value === '')) { return null; }
			if (!context || typeof context !== 'object') { return null; }
			const compactKey = key ? String(key).replace(/[^A-Za-z0-9]/g, '').toLowerCase() : '';
			const statusGroups = [
				{
					statusKey: 'SessionsStatus',
					columns: new Set(['peakconcurrentsessions', 'dailypeakbreakdown'])
				},
				{
					statusKey: 'MetricStatus',
					columns: new Set(['dailyaverageusers', 'datapointcount', 'dailybreakdown'])
				},
				{
					statusKey: context.QueryStatus !== undefined ? 'QueryStatus' : 'DiagnosticsStatus',
					columns: new Set(['lastsuccessfulconnection', 'totalerrors', 'totalfailedconnections', 'shortpatherrors', 'shortpathupgradeevents', 'hostregistrationevents', 'hostregistrationhealthsummary', 'toperrors', 'transporttypebreakdown', 'hostregistrationbreakdown'])
				}
			];
			const match = statusGroups.find((group) => group.columns.has(compactKey));
			if (!match) { return null; }
			const status = context[match.statusKey];
			if (!status) { return null; }
			if (/^NoDiagnosticSettings$/i.test(status)) { return 'Logging disabled'; }
			if (/^NoUserActivity$/i.test(status)) { return 'No activity in period'; }
			if (/^NoData$/i.test(status)) { return 'Unavailable - no data'; }
			if (/^Error:/i.test(status)) { return 'Unavailable - query error'; }
			return null;
		}

		function hasStructuredTableValue(value) {
			if (value === null || value === undefined) { return false; }
			if (Array.isArray(value)) {
				return value.some((item) => item !== null && typeof item === 'object');
			}
			return typeof value === 'object';
		}

		function summarizeStructuredValue(column, value) {
			if (Array.isArray(value)) {
				if (!value.length) { return 'No details'; }
				if (value.every((item) => item === null || ['string', 'number', 'boolean'].includes(typeof item))) {
					return formatFieldValue(column, value);
				}
				return value.length + (value.length === 1 ? ' item' : ' items');
			}
			if (isPlainObject(value)) {
				const parts = [];
				if (value.Name) {
					parts.push(String(value.Name));
				}
				if (Array.isArray(value.Routes)) {
					parts.push(value.Routes.length + (value.Routes.length === 1 ? ' route' : ' routes'));
				}
				if (Array.isArray(value.CustomRules)) {
					parts.push(value.CustomRules.length + (value.CustomRules.length === 1 ? ' custom rule' : ' custom rules'));
				}
				if (!parts.length) {
					parts.push(Object.keys(value).length + ' field(s)');
				}
				return parts.join(' • ');
			}
			return formatFieldValue(column, value);
		}

		function createStructuredSummary(column, value) {
			const summary = document.createElement('span');
			summary.className = 'detail-summary';
			summary.textContent = summarizeStructuredValue(column, value);
			return summary;
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
				authorizedusercount: 'Authorised User Count',
				authorizeduserstatus: 'Authorised User Status',
				authorizeduseridcount: 'Authorised User ID Count',
				licensesummarystatus: 'Licence Summary Status',
				licensesummaryusercount: 'Licence Summary User Count',
				licensesummary: 'Licence Summary',
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
				vnet: 'VNET',
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
			if (kind === 'metrics' && new Set(['__ExecutionContext', '__Licensing', 'ArmCallStats']).has(key)) { return true; }
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

		function positionWarningTooltip(node) {
			if (!node) { return; }
			const viewportWidth = window.innerWidth || document.documentElement.clientWidth || 0;
			const tooltipWidth = Math.min(220, Math.max(170, viewportWidth - 40));
			node.style.setProperty('--warning-tooltip-width', tooltipWidth + 'px');
			node.classList.remove('tooltip-flip');
			const rect = node.getBoundingClientRect();
			const overflowsRight = rect.left - 10 + tooltipWidth > viewportWidth - 16;
			if (overflowsRight) {
				node.classList.add('tooltip-flip');
			}
		}

		function orderedSectionEntries(kind, source) {
			const order = kind === 'metrics'
				? ['__ExecutionContext', 'HostPools', '__Licensing', 'ArmCallStats']
				: ['__ExecutionContext', 'Machine', 'JoinState', 'EntraSso', 'FSLogix', 'UserProfileExperience', 'RdpShortpath', 'RdpRedirection', 'ActiveDirectoryDependencies', 'AvdConnectivity', 'GroupPolicy', 'Antivirus', 'IntuneEnrollment', 'Laps', 'TeamsMediaOptimization', 'UniversalPrint', 'TimeSource', 'Printers'];
			const rank = new Map(order.map((key, index) => [key, index]));
			const entries = Object.entries(source);
			if (kind === 'metrics') {
				entries.push(['__ExecutionContext', {
					CustomerAbbreviation: data.CustomerAbbreviation,
					CollectedAt: data.CollectedAt,
					MetricPeriodStart: data.MetricPeriodStart,
					MetricPeriodEnd: data.MetricPeriodEnd,
					LookbackDays: data.LookbackDays,
					ExcludeWeekends: data.ExcludeWeekends,
					PeakHoursOnly: data.PeakHoursOnly,
					UtcOffsetHours: data.UtcOffsetHours,
					GeneratedBy: data.GeneratedBy,
					ProjectCode: data.ProjectCode,
					CommandOptions: data.CommandOptions ? {
						SubscriptionId: data.CommandOptions.SubscriptionId,
						HostPoolName: data.CommandOptions.HostPoolName,
						RunLocalDiscovery: data.CommandOptions.RunLocalDiscovery,
						InlineLocalScript: data.CommandOptions.InlineLocalScript,
						NoGpresult: data.CommandOptions.NoGpresult,
						SkipLicenceCheck: data.CommandOptions.SkipLicenceCheck,
						RunAsUser: data.CommandOptions.RunAsUser,
						GitHubBranch: data.CommandOptions.GitHubBranch,
						LocalDiscoveryTimeout: data.CommandOptions.LocalDiscoveryTimeout,
						OutputDirectory: data.CommandOptions.OutputDirectory,
						ScanStorageAccounts: data.CommandOptions.ScanStorageAccounts
					} : null
				}]);
				entries.push(['__Licensing', {
					LicenseSummaryStatus: data.LicenseSummaryStatus,
					LicenseSummaryUserCount: data.LicenseSummaryUserCount,
					UnlicensedUserCount: data.UnlicensedUserCount,
					LicenseSummary: data.LicenseSummary,
					UnlicensedUsers: data.UnlicensedUsers
				}]);
			}
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
			const eyebrow = document.createElement('p');
			eyebrow.className = 'eyebrow';
			eyebrow.textContent = label;
			const metric = document.createElement('p');
			metric.className = 'metric';
			metric.textContent = typeof value === 'string' ? value : formatValue(value);
			const subtle = document.createElement('p');
			subtle.className = 'subtle';
			subtle.textContent = detail || '';
			article.append(eyebrow, metric, subtle);
			return article;
		}

		function createMetricCard(label, value, detail, variant, valueKey, context) {
			const resolvedValue = valueKey ? (resolveUnavailableMetricText(valueKey, value, context) || value) : value;
			const card = createCard(label, resolvedValue, detail);
			if (variant) { card.classList.add(variant); }
			return card;
		}

		function wireInteractiveSurfaces() {
			document.querySelectorAll('.card, .chip, .badge, .data-card, .section, details, .table-wrap, .toolbar input, .section-button').forEach((node) => {
				if (node.dataset.interactiveBound === '1') { return; }
				node.dataset.interactiveBound = '1';
				node.classList.add('interactive-surface');
			});
		}

		function formatStorageTierLabel(tier) {
			if (!tier) { return null; }
			const normalized = String(tier).trim().toLowerCase();
			if (normalized === 'premium') { return 'Premium'; }
			if (normalized === 'hot') { return 'Standard - Hot'; }
			if (normalized === 'cool' || normalized === 'cold') { return 'Standard - Cold'; }
			if (normalized === 'transactionoptimized' || normalized === 'transaction optimized') { return 'Standard - Transaction Optimized'; }
			return String(tier);
		}

		function slugifyFragment(value) {
			return String(value || '')
				.toLowerCase()
				.replace(/[^a-z0-9]+/g, '-')
				.replace(/^-+|-+$/g, '');
		}

		function hostPoolAnchorId(pool, fallbackIndex) {
			const namePart = slugifyFragment(pool && (pool.Name || pool.FriendlyName));
			const subscriptionPart = slugifyFragment(pool && (pool.SubscriptionName || pool.SubscriptionId));
			const suffix = namePart || ('pool-' + ((fallbackIndex || 0) + 1));
			return 'host-pool-' + (subscriptionPart ? (subscriptionPart + '-') : '') + suffix;
		}

		function storageTierBadgeVariant(tier) {
			const normalized = tier ? String(tier).trim().toLowerCase() : '';
			if (normalized === 'premium') { return 'tier-gold'; }
			if (normalized === 'hot') { return 'tier-red'; }
			if (normalized === 'cool' || normalized === 'cold') { return 'tier-blue'; }
			if (normalized === 'transactionoptimized' || normalized === 'transaction optimized') { return 'tier-slate'; }
			return 'neutral';
		}

		function createStorageShareList(shares) {
			const wrapper = document.createElement('div');
			wrapper.className = 'share-list';
			shares.forEach((share, index) => {
				const item = document.createElement('div');
				item.className = 'share-item';
				const title = document.createElement('div');
				title.className = 'share-title';
				const name = document.createElement('strong');
				name.textContent = share && share.Name ? share.Name : ('Share ' + (index + 1));
				title.appendChild(name);
				const meta = document.createElement('div');
				meta.className = 'share-meta';
				if (share && share.Tier) {
					meta.appendChild(createBadge(formatStorageTierLabel(share.Tier), storageTierBadgeVariant(share.Tier)));
				}
				const provisioned = share && share.ProvisionedSizeGb != null ? (share.ProvisionedSizeGb + ' GB Provisioned') : 'Provisioned Size N/A';
				meta.appendChild(createBadge(provisioned, 'neutral'));
				let used = 'Usage N/A';
				if (share && share.UsedSizeGb != null) {
					used = share.UsedSizeGb + ' GB Used';
					if (share.UsedPercent != null) {
						used += ' (' + share.UsedPercent + '%)';
					}
				} else if (share && share.UsageStatsAvailable === false) {
					used = 'Usage N/A (Premium Tier)';
				}
				meta.appendChild(createBadge(used, 'neutral'));
				if (share && share.ProvisionedIops != null) {
					meta.appendChild(createBadge(share.ProvisionedIops + ' IOPS', 'neutral'));
				}
				if (share && share.ProvisionedBandwidthMiBps != null) {
					meta.appendChild(createBadge(share.ProvisionedBandwidthMiBps + ' MiB/s', 'neutral'));
				}
				meta.appendChild(createBadge(share && share.BackupEnabled ? 'Backup Enabled' : 'Backup Not Enabled', share && share.BackupEnabled ? '' : 'neutral'));
				item.append(title, meta);
				wrapper.appendChild(item);
			});
			return wrapper;
		}

		function createTableCellValue(column, value, rowContext) {
			if (column === 'Name' && rowContext && (rowContext.HostPoolType || rowContext.SessionHostDetails || rowContext.AuthorizedUserCount != null)) {
				const link = document.createElement('a');
				link.className = 'host-pool-jump';
				link.href = '#' + hostPoolAnchorId(rowContext);
				link.textContent = resolveUnavailableMetricText(column, value, rowContext) || formatFieldValue(column, value);
				return link;
			}
			if (column === 'FileShares' && Array.isArray(value) && value.every((item) => isPlainObject(item))) {
				const details = document.createElement('details');
				details.className = 'inline-detail';
				const summary = document.createElement('summary');
				summary.textContent = value.length ? (value.length + (value.length === 1 ? ' share' : ' shares')) : 'No shares';
				details.append(summary, createStorageShareList(value));
				return details;
			}
			if (hasStructuredTableValue(value)) {
				return createStructuredSummary(column, value);
			}
			if (value !== null && typeof value === 'object') {
				const span = document.createElement('span');
				span.textContent = formatFieldValue(column, value);
				return span;
			}
			const span = document.createElement('span');
			span.textContent = resolveUnavailableMetricText(column, value, rowContext) || formatFieldValue(column, value);
			return span;
		}

		function createDetailStack(contents) {
			const wrapper = document.createElement('div');
			wrapper.className = 'detail-stack';
			contents.forEach((content) => {
				if (content) {
					wrapper.appendChild(content);
				}
			});
			return wrapper;
		}

		function createStructuredRowDetails(row, columns) {
			const entries = columns
				.map((column) => [column, row ? row[column] : null])
				.filter(([, value]) => hasStructuredTableValue(value));
			if (!entries.length) { return null; }
			const details = document.createElement('details');
			details.className = 'table-detail structured-detail';
			const summary = document.createElement('summary');
			const labels = entries.map(([column]) => formatLabel(column));
			const preview = labels.slice(0, 3).join(', ');
			summary.textContent = labels.length <= 3
				? 'View details (' + preview + ')'
				: 'View details (' + preview + ' +' + (labels.length - 3) + ')';
			const grid = document.createElement('div');
			grid.className = 'structured-detail-grid';
			entries.forEach(([column, value]) => {
				const section = document.createElement('details');
				const sectionSummary = document.createElement('summary');
				sectionSummary.textContent = formatLabel(column) + ' • ' + summarizeStructuredValue(column, value);
				section.append(sectionSummary, renderStructuredValue(value, 1));
				grid.appendChild(section);
			});
			details.append(summary, grid);
			return details;
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

		function createChipList(items, className) {
			const wrapper = document.createElement('div');
			wrapper.className = className || 'chips';
			items.forEach((item) => {
				const fullValue = String(formatValue(item.value));
				const displayValue = fullValue.length > 34 ? fullValue.slice(0, 31).trimEnd() + '...' : fullValue;
				const chip = document.createElement('div');
				chip.className = 'chip';
				chip.dataset.chipLabel = String(item.label || '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
				if (displayValue !== fullValue) { chip.title = fullValue; }
				chip.innerHTML = '<strong>' + String(item.label).replace(/</g, '&lt;') + ':</strong> <span>' + displayValue.replace(/</g, '&lt;') + '</span>';
				wrapper.appendChild(chip);
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

		function createDetailTableRow(content, columnCount, searchText) {
			const tr = document.createElement('tr');
			tr.className = 'detail-row';
			if (searchText) {
				tr.dataset.search = searchText;
			}
			const td = document.createElement('td');
			td.colSpan = Math.max(columnCount, 1);
			td.appendChild(content);
			tr.appendChild(td);
			return tr;
		}

		function createStorageShareDetails(row) {
			const shares = row && Array.isArray(row.FileShares) ? row.FileShares.filter((item) => isPlainObject(item)) : [];
			const details = document.createElement('details');
			details.className = 'table-detail';
			const summary = document.createElement('summary');
			summary.textContent = shares.length ? ('Share details (' + shares.length + (shares.length === 1 ? ' share' : ' shares') + ')') : 'Share details';
			details.appendChild(summary);
			if (shares.length) {
				details.appendChild(createStorageShareList(shares));
			} else {
				const empty = document.createElement('span');
				empty.className = 'muted';
				empty.textContent = 'No shares recorded for this storage account.';
				details.appendChild(empty);
			}
			return details;
		}

		function createStorageNetworkDetails(row) {
			if (!row) { return null; }
			const details = document.createElement('details');
			details.className = 'table-detail';
			const summary = document.createElement('summary');
			const privateEndpointCount = toNumber(row.PrivateEndpointCount);
			summary.textContent = privateEndpointCount && privateEndpointCount > 0
				? 'Network Details (' + privateEndpointCount + (privateEndpointCount === 1 ? ' private endpoint' : ' private endpoints') + ')'
				: 'Network Details';
			details.appendChild(summary);

			const sections = [];
			sections.push(createStatList([
				{ label: 'Public Network Access', value: row.PublicNetworkAccess },
				{ label: 'Default Action', value: row.NetworkDefaultAction },
				{ label: 'Bypass', value: row.NetworkBypass },
				{ label: 'HTTPS Only', value: row.HttpsOnly },
				{ label: 'Minimum TLS Version', value: row.MinimumTlsVersion },
				{ label: 'Private Endpoint Count', value: row.PrivateEndpointCount }
			]));

			const privateEndpoints = row && Array.isArray(row.PrivateEndpoints) ? row.PrivateEndpoints.filter((item) => isPlainObject(item)) : [];
			if (privateEndpoints.length) {
				const endpointDetails = document.createElement('details');
				const endpointSummary = document.createElement('summary');
				endpointSummary.textContent = 'Private Endpoints • ' + privateEndpoints.length + (privateEndpoints.length === 1 ? ' item' : ' items');
				endpointDetails.append(endpointSummary, wrapTable(createObjectTable(privateEndpoints, ['Name', 'ConnectionStatus', 'ProvisioningState', 'PrivateEndpointId'], { structuredDetailRows: false })));
				sections.push(endpointDetails);
			}

			details.appendChild(createDetailStack(sections));
			return details;
		}

		function createPoolAccessDetails(pool) {
			const details = document.createElement('div');

			const workspaceNames = Array.isArray(pool.WorkspaceNames) && pool.WorkspaceNames.length ? pool.WorkspaceNames.join(', ') : 'None';
			const appGroupNames = Array.isArray(pool.AppGroupNames) && pool.AppGroupNames.length ? pool.AppGroupNames.join(', ') : 'None';
			const sections = [createStatList([
				{ label: 'Authorised User Count', value: pool.AuthorizedUserCount },
				{ label: 'Status', value: pool.AuthorizedUserStatus },
				{ label: 'Workspaces', value: workspaceNames },
				{ label: 'App Groups', value: appGroupNames }
			])];

			const accessAssignments = Array.isArray(pool.AccessAssignments)
				? pool.AccessAssignments.filter((item) => isPlainObject(item))
				: [];
			if (accessAssignments.length) {
				const assignmentBlock = document.createElement('details');
				const assignmentSummary = document.createElement('summary');
				assignmentSummary.textContent = 'Users and Groups • ' + accessAssignments.length + (accessAssignments.length === 1 ? ' assignment' : ' assignments');
				assignmentBlock.append(assignmentSummary, wrapTable(createObjectTable(accessAssignments, ['Type', 'DisplayName', 'UPN'], { structuredDetailRows: false })));
				sections.push(assignmentBlock);
			} else {
				const empty = document.createElement('span');
				empty.className = 'muted';
				empty.textContent = 'No authorised users or groups were recorded for this pool in the export.';
				sections.push(empty);
			}

			details.appendChild(createDetailStack(sections));
			return details;
		}

		function createPoolUsageDetails(pool) {
			const details = document.createElement('div');

			const sections = [createStatList([
				{ label: 'Daily Active Users', value: pool.DailyAverageUsers },
				{ label: 'Usage Status', value: pool.MetricStatus },
				{ label: 'Peak User Count', value: pool.PeakConcurrentSessions },
				{ label: 'Peak Status', value: pool.SessionsStatus },
				{ label: 'Sampled Days', value: pool.DataPointCount }
			])];

			const dailyBreakdown = Array.isArray(pool.DailyBreakdown) ? pool.DailyBreakdown.filter((item) => isPlainObject(item)) : [];
			if (dailyBreakdown.length) {
				const dailyBlock = document.createElement('details');
				const dailySummary = document.createElement('summary');
				dailySummary.textContent = 'Daily Active User Breakdown • ' + dailyBreakdown.length + (dailyBreakdown.length === 1 ? ' day' : ' days');
				dailyBlock.append(dailySummary, wrapTable(createObjectTable(dailyBreakdown, ['Day', 'UniqueUsers'], { structuredDetailRows: false })));
				sections.push(dailyBlock);
			}

			const peakBreakdown = Array.isArray(pool.DailyPeakBreakdown) ? pool.DailyPeakBreakdown.filter((item) => isPlainObject(item)) : [];
			if (peakBreakdown.length) {
				const peakBlock = document.createElement('details');
				const peakSummary = document.createElement('summary');
				peakSummary.textContent = 'Daily Peak User Breakdown • ' + peakBreakdown.length + (peakBreakdown.length === 1 ? ' day' : ' days');
				peakBlock.append(peakSummary, wrapTable(createObjectTable(peakBreakdown, ['Day', 'PeakConcurrentSessions'], { structuredDetailRows: false })));
				sections.push(peakBlock);
			}

			const insights = isPlainObject(pool.InsightsDiagnostics) ? pool.InsightsDiagnostics : null;
			if (insights) {
				const insightsSections = [createStatList([
					{ label: 'Status', value: insights.QueryStatus },
					{ label: 'Workspace', value: insights.LogAnalyticsWorkspace },
					{ label: 'Diagnostic Categories', value: insights.DiagnosticCategories },
					{ label: 'Window Start', value: insights.QueryWindowStart },
					{ label: 'Window End', value: insights.QueryWindowEnd },
					{ label: 'Last Successful Connection', value: insights.LastSuccessfulConnection },
					{ label: 'Total Errors', value: insights.TotalErrors },
					{ label: 'Failed Connections', value: insights.TotalFailedConnections },
					{ label: 'Shortpath Errors', value: insights.ShortpathErrors },
					{ label: 'Shortpath Upgrades', value: insights.ShortpathUpgradeEvents },
					{ label: 'Host Registration Events', value: insights.HostRegistrationEvents },
					{ label: 'Registration Health', value: insights.HostRegistrationHealthSummary }
				])];

				const topErrors = Array.isArray(insights.TopErrors) ? insights.TopErrors.filter((item) => isPlainObject(item)) : [];
				if (topErrors.length) {
					const errorsBlock = document.createElement('details');
					const errorsSummary = document.createElement('summary');
					errorsSummary.textContent = 'Top Errors • ' + topErrors.length + (topErrors.length === 1 ? ' item' : ' items');
					errorsBlock.append(errorsSummary, wrapTable(createObjectTable(topErrors, ['Code', 'Message', 'Count', 'Service'], { structuredDetailRows: false })));
					insightsSections.push(errorsBlock);
				}

				const transportBreakdown = Array.isArray(insights.TransportTypeBreakdown) ? insights.TransportTypeBreakdown.filter((item) => isPlainObject(item)) : [];
				if (transportBreakdown.length) {
					const transportBlock = document.createElement('details');
					const transportSummary = document.createElement('summary');
					transportSummary.textContent = 'Transport Breakdown • ' + transportBreakdown.length + (transportBreakdown.length === 1 ? ' item' : ' items');
					transportBlock.append(transportSummary, wrapTable(createObjectTable(transportBreakdown, ['TransportType', 'Count'], { structuredDetailRows: false })));
					insightsSections.push(transportBlock);
				}

				const registrationBreakdown = Array.isArray(insights.HostRegistrationBreakdown) ? insights.HostRegistrationBreakdown.filter((item) => isPlainObject(item)) : [];
				if (registrationBreakdown.length) {
					const registrationBlock = document.createElement('details');
					const registrationSummary = document.createElement('summary');
					registrationSummary.textContent = 'Host Registration Breakdown • ' + registrationBreakdown.length + (registrationBreakdown.length === 1 ? ' host' : ' hosts');
					registrationBlock.append(registrationSummary, wrapTable(createObjectTable(registrationBreakdown, ['SessionHostName', 'RegistrationCount', 'LastRegistrationTime'], { structuredDetailRows: false })));
					insightsSections.push(registrationBlock);
				}

				const insightsBlock = document.createElement('details');
				const insightsSummary = document.createElement('summary');
				insightsSummary.textContent = 'Diagnostic Insights';
				insightsBlock.append(insightsSummary, createDetailStack(insightsSections));
				sections.push(insightsBlock);
			}

			details.appendChild(createDetailStack(sections));
			return details;
		}

		function createObjectTable(rows, preferredKeys, options) {
			if (!rows.length) {
				const empty = document.createElement('p');
				empty.className = 'muted';
				empty.textContent = 'No rows available.';
				return empty;
			}
			const tableOptions = options || {};
			const table = document.createElement('table');
			const columns = objectArrayColumns(rows, preferredKeys).filter((column) => !(tableOptions.hiddenColumns || []).includes(column));
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
				const searchText = JSON.stringify(row).toLowerCase();
				const tr = document.createElement('tr');
				tr.dataset.search = searchText;
				columns.forEach((column) => {
					const td = document.createElement('td');
					td.appendChild(createTableCellValue(column, row ? row[column] : null, row));
					tr.appendChild(td);
				});
				tbody.appendChild(tr);
				const detailContents = [];
				if (tableOptions.detailRowFactory) {
					detailContents.push(tableOptions.detailRowFactory(row));
				}
				if (tableOptions.structuredDetailRows !== false) {
					detailContents.push(createStructuredRowDetails(row, columns));
				}
				const detailContent = detailContents.filter(Boolean);
				if (detailContent.length) {
					tbody.appendChild(createDetailTableRow(detailContent.length === 1 ? detailContent[0] : createDetailStack(detailContent), columns.length, searchText));
				}
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

		function renderStructuredValue(value, depth, parentContext) {
			const level = depth || 0;
			if (value === null || value === undefined || value === '') {
				const empty = document.createElement('span');
				empty.className = 'muted';
				empty.textContent = resolveUnavailableMetricText('', value, parentContext) || 'None';
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
					details.append(summary, renderStructuredValue(item, level + 1, item));
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
						dd.textContent = resolveUnavailableMetricText(key, child, value) || formatFieldValue(key, child);
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
				details.append(summary, renderStructuredValue(child, level + 1, child));
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
			return [
				{ label: 'Host Pools', value: data.HostPoolCount || hostPools.length, detail: 'AVD pools covered in this export' },
				{ label: 'Subscriptions', value: data.SubscriptionCount, detail: 'Azure subscriptions scanned' }
			];
		}

		function hostSummary() {
			const fsLogix = data.FSLogix || {};
			const sso = data.EntraSso || {};
			const adDeps = data.ActiveDirectoryDependencies || {};
			return [
				{ label: 'Applications', value: data.ApplicationCount || normalizeCollection(data.Applications).length, detail: 'Installed apps included in the export' },
				{ label: 'Join Type', value: data.JoinState && data.JoinState.JoinType ? data.JoinState.JoinType : 'n/a', detail: 'Detected device join state' },
				{ label: 'FSLogix', value: fsLogix.Installed ? 'Installed' : 'Not installed', detail: 'Profile container platform status' },
				{ label: 'Containers', value: fsLogix.ProfileContainerCount == null ? 'n/a' : fsLogix.ProfileContainerCount, detail: 'Detected profile containers' },
				{ label: 'Entra SSO', value: sso.SsoCapable ? 'Capable' : 'Review', detail: 'Host-side SSO readiness summary' },
				{ label: 'AD Dependencies', value: adDeps.HasDomainDependencies ? 'Present' : 'None', detail: 'Services, tasks, ODBC, and live port usage' },
				{ label: 'Group Policy', value: data.GroupPolicy && data.GroupPolicy.Succeeded ? 'Captured' : 'Not captured', detail: 'gpresult HTML export status' },
				{ label: 'Connectivity', value: data.ConnectivityChecksSkipped ? 'Skipped' : 'Executed', detail: 'AVD endpoint connectivity checks' }
			];
		}

		function buildHostPoolSections() {
			const pools = normalizeCollection(data.HostPools);
			if (!pools.length) { return; }
			document.getElementById('host-pool-section').classList.remove('hidden');
			const stack = document.getElementById('host-pool-stack');
			stack.innerHTML = '';
			pools.forEach((pool, index) => {
				const panel = document.createElement('article');
				panel.className = 'pool-panel';
				panel.id = hostPoolAnchorId(pool, index);
				panel.style.scrollMarginTop = '24px';
				const diagnosticsStatus = pool.InsightsDiagnostics && pool.InsightsDiagnostics.QueryStatus
					? pool.InsightsDiagnostics.QueryStatus
					: (pool.MetricStatus || pool.SessionsStatus || '');
				const titleWrap = document.createElement('div');
				titleWrap.className = 'pool-title-wrap';
				let warning = null;
				if (/^NoDiagnosticSettings$/i.test(diagnosticsStatus)) {
					panel.classList.add('has-warning');
					warning = document.createElement('span');
					warning.className = 'pool-warning';
					warning.setAttribute('role', 'img');
					warning.setAttribute('aria-label', 'Warning: Log Analytics diagnostic settings are not enabled for this host pool.');
					warning.setAttribute('tabindex', '0');
					warning.dataset.tooltip = 'Log Analytics diagnostic settings are not enabled for this host pool. Usage metrics and Insights data are unavailable until diagnostic logging is configured.';
					const warningIcon = document.createElement('span');
					warningIcon.className = 'pool-warning-icon';
					warningIcon.setAttribute('aria-hidden', 'true');
					warning.append(warningIcon);
					const updateWarningTooltip = () => positionWarningTooltip(warning);
					warning.addEventListener('mouseenter', updateWarningTooltip);
					warning.addEventListener('focus', updateWarningTooltip);
					window.addEventListener('resize', updateWarningTooltip);
				}
				const titleText = pool.FriendlyName || pool.Name || ('Host Pool ' + (index + 1));
				const header = document.createElement('div');
				header.className = 'pool-header';
				const title = document.createElement('h3');
				title.textContent = titleText;
				titleWrap.append(title);
				if (warning) {
					titleWrap.append(warning);
				}
				const subtitle = document.createElement('p');
				subtitle.textContent = (pool.FriendlyName && pool.Name && pool.FriendlyName !== pool.Name) ? pool.Name : '';
				const poolHighlights = createChipList([
					{ label: 'Location', value: pool.Location },
					{ label: 'Subscription', value: pool.SubscriptionName },
					{ label: 'Resource Group', value: pool.ResourceGroup }
				], 'pool-highlights');
				header.append(titleWrap, poolHighlights);
				const poolMeta = createChipList([
					{ label: 'Load Balancer', value: pool.LoadBalancerType },
					{ label: 'Pool Type', value: pool.HostPoolType },
					{ label: 'Max Sessions', value: formatFieldValue('MaxSessionLimit', pool.MaxSessionLimit) },
					{ label: 'Domain Join', value: pool.DomainJoinType },
					{ label: 'VM SKUs', value: pool.VmSkus },
					{ label: 'Agent Versions', value: pool.AgentVersions }
				], 'pool-meta');
				const featuredGrid = document.createElement('div');
				featuredGrid.className = 'pool-grid featured';
				const featuredCards = [
					createMetricCard('CPU Average', formatPercentValue(pool.AvgCpuPercent), 'Mean CPU usage across sampled hosts', 'accent-cpu'),
					createMetricCard('Memory Average', formatPercentValue(pool.AvgMemUsedPercent), 'Mean memory usage across sampled hosts', 'accent-memory'),
					createMetricCard('Authorised Users', pool.AuthorizedUserCount, 'Distinct authorised users resolved for this pool', 'accent-usage', 'AuthorizedUserCount', pool)
				];
				if (!/^NoDiagnosticSettings$/i.test(pool.SessionsStatus || '')) {
					featuredCards.push(createMetricCard('Peak User Count', /^NoUserActivity$/i.test(pool.SessionsStatus || '') ? 0 : pool.PeakConcurrentSessions, 'Highest concurrent sessions observed', 'accent-usage', 'PeakConcurrentSessions', pool));
				}
				if (!/^NoDiagnosticSettings$/i.test(pool.MetricStatus || '')) {
					featuredCards.push(createMetricCard('Daily Active Users', /^NoUserActivity$/i.test(pool.MetricStatus || '') ? 0 : pool.DailyAverageUsers, 'Average distinct users per sampled day', 'accent-usage', 'DailyAverageUsers', pool));
				}
				featuredCards.forEach((card) => featuredGrid.appendChild(card));
				const divider = document.createElement('div');
				divider.className = 'pool-divider';
				const grid = document.createElement('div');
				grid.className = 'pool-grid';
				[
					createMetricCard('Host Count', pool.HostCount, 'Registered hosts in this pool'),
					createMetricCard('Hosts Running', pool.HostsRunning, 'Session hosts currently powered on'),
					createMetricCard('Hosts Available', pool.HostsAvailable, 'Hosts available for new sessions'),
					createMetricCard('Hosts Shutdown', pool.HostsShutdown, 'Hosts currently powered off'),
					createMetricCard('Hosts Unavailable', pool.HostsUnavailable, 'Hosts unavailable for broker placement'),
					createMetricCard('Hosts Draining', pool.HostsDraining, 'Hosts set to stop taking new sessions')
				].forEach((card) => grid.appendChild(card));
				const details = document.createElement('div');
				details.className = 'pool-details';
				[
					['Session Hosts', pool.SessionHostDetails || []],
					['Authorised Access', createPoolAccessDetails(pool)],
					['User Activity', createPoolUsageDetails(pool)],
					['Platform Detail', {
						StartVMOnConnect: pool.StartVMOnConnect,
						NetworkInfo: pool.NetworkInfo,
						RdpProperties: pool.RdpProperties,
						SsoConfig: pool.SsoConfig,
						AppGroupDetails: pool.AppGroupDetails,
						ImageReferences: pool.ImageReferences
					}]
				].forEach(([label, value]) => {
					const block = document.createElement('details');
					if (label === 'Platform Detail') { block.classList.add('platform-detail'); }
					const summary = document.createElement('summary');
					summary.textContent = label;
					block.appendChild(summary);
					if (value && typeof value === 'object' && typeof value.nodeType === 'number') {
						block.appendChild(value);
					} else if (label === 'Session Hosts' && Array.isArray(value)) {
						block.appendChild(wrapTable(createObjectTable(value, [], { hiddenColumns: ['PublicIpAddress', 'OutboundPublicIpAddress'] })));
					} else {
						block.appendChild(renderStructuredValue(value, 0));
					}
					details.appendChild(block);
				});
				panel.append(header);
				if (subtitle.textContent) {
					panel.append(subtitle);
				}
				panel.append(poolMeta, featuredGrid, divider, grid, details);
				stack.appendChild(panel);
			});
		}

		function buildTable(sectionIdPrefix, title, copy, rows, preferredKeys, options) {
			if (!rows.length) { return; }
			document.getElementById(sectionIdPrefix + '-section').classList.remove('hidden');
			document.getElementById(sectionIdPrefix + '-title').textContent = title;
			document.getElementById(sectionIdPrefix + '-copy').textContent = copy;
			const wrap = document.getElementById(sectionIdPrefix + '-wrap');
			wrap.innerHTML = '';
			wrap.appendChild(createObjectTable(rows, preferredKeys, options));
		}

		function buildStructuredSections(kind) {
			const dataGrid = document.getElementById('data-grid');
			const skip = kind === 'metrics'
				? new Set(['CustomerAbbreviation', 'GeneratedBy', 'ProjectCode', 'CollectedAt', 'MetricPeriodStart', 'MetricPeriodEnd', 'LookbackDays', 'ExcludeWeekends', 'PeakHoursOnly', 'UtcOffsetHours', 'HostPools', 'StorageAccountScan', 'CommandOptions', 'LicenseSummaryStatus', 'LicenseSummary', 'LicenseSummaryUserCount', 'UnlicensedUserCount', 'UnlicensedUsers'])
				: new Set(['Applications', 'CustomerAbbreviation', 'GeneratedBy', 'ProjectCode', 'CollectedAt', 'CollectionMode', 'RunningAsAccount', 'DiscoveryType', 'PrimaryApplicationsOnly', 'ApplicationCount']);
			orderedSectionEntries(kind, data).forEach(([key, value]) => {
				if (skip.has(key)) { return; }
				const panel = document.createElement('article');
				panel.className = 'data-card ' + (kind === 'host' ? 'compact' : (isWideSection(key, value, kind) ? 'wide' : 'compact'));
				panel.dataset.search = (key + ' ' + JSON.stringify(value)).toLowerCase();
				const head = document.createElement('div');
				head.className = 'data-card-head';
				const heading = document.createElement('h3');
				heading.textContent = key === '__ExecutionContext' ? 'Execution Context' : key === '__Licensing' ? 'Licensing' : formatLabel(key);
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
			kpis.forEach((item) => kpiGrid.appendChild(createCard(item.label, item.value, item.detail)));
			if (kind === 'metrics') {
				buildTable('primary-table', 'Host Pools', 'Per-pool operational, usage, and access summary.', normalizeCollection(data.HostPools), ['Name', 'SubscriptionName', 'Location', 'HostPoolType', 'HostCount', 'AuthorizedUserCount', 'DailyAverageUsers', 'PeakConcurrentSessions', 'AvgCpuPercent', 'AvgMemUsedPercent']);
				buildTable('secondary-table', 'Storage Accounts', 'FSLogix storage scan results included in the export, with share and network details available per storage account.', normalizeCollection(data.StorageAccountScan), ['Name', 'ResourceGroup', 'Location', 'Kind', 'Sku', 'PublicNetworkAccess', 'NetworkDefaultAction', 'PrivateEndpointCount', 'FileShareCount'], { detailRowFactory: (row) => createDetailStack([createStorageShareDetails(row), createStorageNetworkDetails(row)]) });
				buildHostPoolSections();
			} else if (kind === 'host') {
				buildTable('primary-table', 'Applications', 'Installed application inventory from the host export.', normalizeCollection(data.Applications), ['DisplayName', 'DisplayVersion', 'Publisher', 'InstallDate', 'InstallLocation']);
			}
			buildStructuredSections(kind);
			wireInteractiveSurfaces();
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
				$hostsRunning   = 0
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

						# Power state from instanceView
						if ($vmProp.PSObject.Properties['instanceView'] -and $vmProp.instanceView -and
						    $vmProp.instanceView.PSObject.Properties['statuses']) {
							$pwrStatus = @($vmProp.instanceView.statuses | Where-Object { $_.code -like 'PowerState/*' }) | Select-Object -First 1
							if ($pwrStatus -and $pwrStatus.code -eq 'PowerState/running') {
								$hostsRunning++
							}
						}

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
				$result.HostsRunning    = $hostsRunning
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
						$cpuSamples.Add($pt.average)
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
			CpuStatus     = 'NoData'
		}
	}

	$sortedCpu = @($cpuSamples | Sort-Object)
	$p95IdxCpu = [Math]::Max(0, [Math]::Ceiling($sortedCpu.Count * 0.95) - 1)
	$p99IdxCpu = [Math]::Max(0, [Math]::Ceiling($sortedCpu.Count * 0.99) - 1)

	return [PSCustomObject]@{
		AvgCpuPercent = [Math]::Round(($cpuSamples | Measure-Object -Average).Average, 2)
		P95CpuPercent = [Math]::Round($sortedCpu[$p95IdxCpu], 2)
		P99CpuPercent = [Math]::Round($sortedCpu[$p99IdxCpu], 2)
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
								if ($usedPct -ge 0) { $pctSamples.Add($usedPct) }
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
		return [PSCustomObject]@{
			AvgMemUsedPercent = [Math]::Round(($pctSamples | Measure-Object -Average).Average, 2)
			P95MemUsedPercent = [Math]::Round($sortedMem[$p95IdxMem], 2)
			P99MemUsedPercent = [Math]::Round($sortedMem[$p99IdxMem], 2)
			MemoryStatus      = 'OK'
		}
	}

	# Distinguish: metric returned data but SKU RAM unknown vs metric itself had no data
	$status = if ($metricHasData) { 'NoSkuData' } else { 'NoData' }
	return [PSCustomObject]@{
		AvgMemUsedPercent = $null
		P95MemUsedPercent = $null
		P99MemUsedPercent = $null
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
			("    & `$scrPath -CustomerAbbreviation `$cCode -OutputDirectory `$outDir -PrimaryApplicationsOnly$(if ($NoGpresult.IsPresent) { ' -NoGpresult' }) -ErrorAction Stop *>&1 | Out-Null"),
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
			("    & `$scrPath -CustomerAbbreviation `$cCode -OutputDirectory `$outDir -PrimaryApplicationsOnly$(if ($NoGpresult.IsPresent) { ' -NoGpresult' }) -ErrorAction Stop *>&1 | Out-Null"),
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
			$_cmd = ".\scripts\Invoke-AvdSessionHostAudit.ps1 -CustomerAbbreviation $CustomerCode$(if ($NoGpresult.IsPresent) { ' -NoGpresult' })"
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
		$localHtmlPath = [System.IO.Path]::ChangeExtension($outputFile, '.html')
		Write-AvdHtmlReport -Data $parsedLocalDiscovery -OutputPath $localHtmlPath -Title "AVD Host Audit Report - $vmName" -SourceJsonFileName (Split-Path $outputFile -Leaf) | Out-Null
		Write-Host "    [LocalDiscovery | $vmName] Saved HTML: $localHtmlPath"
	}
	catch {
		Write-Warning "[LocalDiscovery | $vmName] Failed to generate HTML report: $($_.Exception.Message)"
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
	if (-not $originalContext -or -not $originalContext.Account) {
		throw "Not authenticated. Run Connect-AzAccount before executing this script."
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
			CpuStatus                = $cpuMetrics.CpuStatus
			AverageHostsOnPerDay     = $hostsOnMetrics.AverageHostsOnPerDay
			DailyHostsOnStatus       = $hostsOnMetrics.DailyHostsOnStatus
			AvgMemUsedPercent        = $memMetrics.AvgMemUsedPercent
			P95MemUsedPercent        = $memMetrics.P95MemUsedPercent
			P99MemUsedPercent        = $memMetrics.P99MemUsedPercent
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
	}

	$exportObject | ConvertTo-Json -Depth 8 | Set-Content -Path $resolvedOutputPath -Encoding UTF8
	$resolvedHtmlPath = [System.IO.Path]::ChangeExtension($resolvedOutputPath, '.html')
	Write-AvdHtmlReport -Data $exportObject -OutputPath $resolvedHtmlPath -Title "AVD Metrics Report - $customerCode" -SourceJsonFileName (Split-Path $resolvedOutputPath -Leaf) | Out-Null

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
	Write-Host "  HTML report :  $resolvedHtmlPath" -ForegroundColor Cyan
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
