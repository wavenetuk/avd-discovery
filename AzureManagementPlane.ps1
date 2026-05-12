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

.PARAMETER GitHubBranch
The branch name used when downloading LocalScript.ps1 and appExclusions.config.json
from the GitHub repository (https://github.com/wavenetuk/avd-discovery) during
-RunLocalDiscovery execution. Defaults to 'main'. Use a feature branch name when
testing changes that have not yet been merged.

.EXAMPLE
.\AzureManagementPlane.ps1

.EXAMPLE
.\AzureManagementPlane.ps1 -CustomerAbbreviation kcr -LookbackDays 14 -ExcludeWeekends

.EXAMPLE
.\AzureManagementPlane.ps1 -CustomerAbbreviation kcr -LookbackDays 14 -PeakHoursOnly -UtcOffsetHours 1

.EXAMPLE
.\AzureManagementPlane.ps1 -CustomerAbbreviation kcr -LookbackDays 14 -PeakHoursOnly -ExcludeWeekends -UtcOffsetHours 1

.EXAMPLE
.\AzureManagementPlane.ps1 -CustomerAbbreviation kcr -SubscriptionId '00000000-0000-0000-0000-000000000000' -OutputDirectory .\exports
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
	[switch]$SkipLicenceCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------------

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
		Write-Host "No subscriptions specified — querying all accessible subscriptions."
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
		Write-Host "  Scanning subscription: $($subscription.Name) ($($subscription.Id))"
		Set-AzContext -SubscriptionId $subscription.Id -WarningAction SilentlyContinue | Out-Null

		$hostPools = Get-AzWvdHostPool -ErrorAction SilentlyContinue
		if (-not $hostPools) {
			Write-Host "    No host pools found."
			continue
		}

		foreach ($pool in $hostPools) {
			$allHostPools.Add([PSCustomObject]@{
				SubscriptionId   = $subscription.Id
				SubscriptionName = $subscription.Name
				ResourceId       = $pool.Id
				Name             = $pool.Name
				ResourceGroup    = ($pool.Id -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
				Location         = $pool.Location
				HostPoolType     = $pool.HostPoolType.ToString()
				LoadBalancerType = $pool.LoadBalancerType.ToString()
				MaxSessionLimit  = $pool.MaxSessionLimit
				FriendlyName     = $pool.FriendlyName
			})
		}

		Write-Host "    Found $(@($hostPools).Count) host pool(s)."
	}

	return $allHostPools
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
		HostCount       = $null
		VmSkus          = $null
		VmSkusStatus    = $null
		VmResourceIds   = @()
		VmSizeMap       = @{}
		DomainJoinType  = $null
		DomainName      = $null
		VmExtensions    = @()
		ImageReferences = @()
		OsDiskSizeGb    = @()
		OsDiskSkus      = @()
		NetworkInfo     = @()
		ScalingPlan     = $null
	}

	# --- Host count and VM SKUs via direct ARM queries ---
	try {
		$shPath     = "$($HostPool.ResourceId)/sessionHosts?api-version=2023-09-05"
		$shResponse = Invoke-AzRestMethod -Path $shPath -Method GET -ErrorAction Stop

		if ($shResponse.StatusCode -eq 200) {
			$sessionHosts     = ($shResponse.Content | ConvertFrom-Json).value
			$result.HostCount = @($sessionHosts).Count

			$vmIds = @($sessionHosts | ForEach-Object {
				$rid = $_.properties.resourceId
				if (-not [string]::IsNullOrEmpty($rid)) { $rid }
			})

			$result.VmResourceIds = @($vmIds)

			if ($vmIds.Count -eq 0) {
				$result.VmSkusStatus = 'NoVmResourceIds'
			}
			else {
				$vmSizeMap      = @{}
				$imgRefKeys     = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
				$imgRefList     = [System.Collections.Generic.List[PSCustomObject]]::new()
				$osDiskSizes    = [System.Collections.Generic.HashSet[int]]::new()
				$osDiskSkus     = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
				$extKeys        = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
				$extList        = [System.Collections.Generic.List[PSCustomObject]]::new()
				$adDomainExt    = $false
				$entraExt       = $false
				$adDomainNames  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
				$vnetCache      = @{}
				$netInfoKeys    = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
				$netInfoList    = [System.Collections.Generic.List[PSCustomObject]]::new()

				$allSkus = foreach ($vmId in $vmIds) {
					$vmPath = "${vmId}?api-version=2024-03-01"
					$vmResp = Invoke-AzRestMethod -Path $vmPath -Method GET -ErrorAction SilentlyContinue
					if ($vmResp -and $vmResp.StatusCode -eq 200) {
						$vmData = $vmResp.Content | ConvertFrom-Json
						$vmProp = $vmData.properties

						# VM size
						$size = $vmProp.hardwareProfile.vmSize
						if (-not [string]::IsNullOrEmpty($size)) {
							$vmSizeMap[$vmId.ToLowerInvariant()] = $size
						}

						# Extensions — separate sub-resource call; $expand=extensions is not supported
						# on the Compute VM GET endpoint (only instanceView/userData are valid expand values)
						$extResp = Invoke-AzRestMethod -Path "${vmId}/extensions?api-version=2024-03-01" -Method GET -ErrorAction SilentlyContinue
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
								$irObj  = [PSCustomObject]@{
									Type            = 'SharedImageGallery'
									GalleryName     = if ($galIdx -ge 0 -and ($galIdx + 1) -lt $parts.Count) { $parts[$galIdx + 1] } else { $null }
									ImageDefinition = if ($imgIdx -ge 0 -and ($imgIdx + 1) -lt $parts.Count) { $parts[$imgIdx + 1] } else { $null }
									Version         = if ($verIdx -ge 0 -and ($verIdx + 1) -lt $parts.Count) { $parts[$verIdx + 1] } else { $null }
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
						}

						# Network — primary NIC → subnet → VNet
						if ($vmProp.PSObject.Properties['networkProfile'] -and
						    $vmProp.networkProfile.PSObject.Properties['networkInterfaces']) {
							$nicRef = @($vmProp.networkProfile.networkInterfaces) | Select-Object -First 1
							if ($nicRef -and $nicRef.PSObject.Properties['id'] -and -not [string]::IsNullOrEmpty($nicRef.id)) {
								$nicResp = Invoke-AzRestMethod -Path "$($nicRef.id)?api-version=2023-11-01" -Method GET -ErrorAction SilentlyContinue
								if ($nicResp -and $nicResp.StatusCode -eq 200) {
									$nicProps = ($nicResp.Content | ConvertFrom-Json).properties
									# NIC-level NSG
									$nicNsg = if ($nicProps.PSObject.Properties['networkSecurityGroup'] -and $nicProps.networkSecurityGroup -and
									              $nicProps.networkSecurityGroup.PSObject.Properties['id']) {
										($nicProps.networkSecurityGroup.id -split '/')[-1]
									} else { $null }
									# Subnet from first IP config
									$subnetId = $null
									if ($nicProps.PSObject.Properties['ipConfigurations'] -and @($nicProps.ipConfigurations).Count -gt 0) {
										$ipCfg = @($nicProps.ipConfigurations) | Select-Object -First 1
										if ($ipCfg.PSObject.Properties['properties'] -and
										    $ipCfg.properties.PSObject.Properties['subnet'] -and
										    $ipCfg.properties.subnet.PSObject.Properties['id']) {
											$subnetId = $ipCfg.properties.subnet.id
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
											$vnetResp = Invoke-AzRestMethod -Path "${vnetId}?api-version=2023-11-01" -Method GET -ErrorAction SilentlyContinue
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
														($sp.networkSecurityGroup.id -split '/')[-1] } else { $null }
													$subnetRouteTable = if ($sp.PSObject.Properties['routeTable'] -and $sp.routeTable -and
													                         $sp.routeTable.PSObject.Properties['id']) {
														($sp.routeTable.id -split '/')[-1] } else { $null }
												}
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
				$result.VmExtensions    = @($extList | Sort-Object Type)
				$result.ImageReferences = @($imgRefList)
				$result.OsDiskSizeGb    = @($osDiskSizes | Sort-Object)
				$result.OsDiskSkus      = @($osDiskSkus)
				$result.NetworkInfo     = @($netInfoList)

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
		$spResponse = Invoke-AzRestMethod -Path $spPath -Method GET -ErrorAction Stop

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
		$vResp = Invoke-AzRestMethod -Path "/subscriptions/$SubscriptionId/providers/Microsoft.RecoveryServices/vaults?api-version=2023-06-01" -Method GET -ErrorAction SilentlyContinue
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
		$iResp    = Invoke-AzRestMethod -Path $itemPath -Method GET -ErrorAction SilentlyContinue
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
	diagnostic settings for a host pool, or $null if none is configured.
	#>
	param(
		[Parameter(Mandatory = $true)]
		[PSCustomObject]$HostPool
	)

	$path     = "$($HostPool.ResourceId)/providers/microsoft.insights/diagnosticSettings?api-version=2021-05-01-preview"
	$response = Invoke-AzRestMethod -Path $path -Method GET -ErrorAction Stop

	if ($response.StatusCode -ne 200) { return $null }

	$settings = ($response.Content | ConvertFrom-Json).value
	foreach ($setting in $settings) {
		$wid = $setting.properties.workspaceId
		if (-not [string]::IsNullOrEmpty($wid)) {
			return $wid
		}
	}

	return $null
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
		$workspaceResourceId = Get-HostPoolLogAnalyticsWorkspace -HostPool $HostPool

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

		$response = Invoke-AzRestMethod -Path $queryPath -Method POST -Payload $payload -ErrorAction Stop

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
				MetricStatus      = 'NoData'
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
				MetricStatus      = 'NoData'
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

			$resp = Invoke-AzRestMethod -Path $path -Method GET -ErrorAction SilentlyContinue
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
		$resp = Invoke-AzRestMethod -Path $path -Method GET -ErrorAction Stop
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

			$resp = Invoke-AzRestMethod -Path $path -Method GET -ErrorAction SilentlyContinue
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
	  OK                   — peak figures calculated successfully
	  NoDiagnosticSettings — no Log Analytics workspace linked to this host pool
	  NoData               — no WVDConnections events found in the lookback window
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
		$workspaceResourceId = Get-HostPoolLogAnalyticsWorkspace -HostPool $HostPool
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
| summarize PeakConcurrentSessions = max(ConcurrentSessions) by Day
| order by Day asc
"@

		$payload   = @{ query = $kqlQuery } | ConvertTo-Json
		$queryPath = "${workspaceResourceId}/query?api-version=2017-10-01"
		$response  = Invoke-AzRestMethod -Path $queryPath -Method POST -Payload $payload -ErrorAction Stop

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
				SessionsStatus         = 'NoData'
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
				SessionsStatus         = 'NoData'
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
		TotalErrors               = $null
		TotalFailedConnections    = $null
		ShortpathErrors           = $null
		ShortpathUpgradeEvents    = $null
		HostRegistrationEvents    = $null
		TopErrors                 = @()
		TransportTypeBreakdown    = @()
		HostRegistrationBreakdown = @()
	}

	try {
		$workspaceResourceId = Get-HostPoolLogAnalyticsWorkspace -HostPool $HostPool
		if ([string]::IsNullOrEmpty($workspaceResourceId)) {
			$emptyResult.DiagnosticsStatus = 'NoDiagnosticSettings'
			return $emptyResult
		}

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
			$rsp = Invoke-AzRestMethod -Path $queryPath -Method POST -Payload $payload -ErrorAction SilentlyContinue
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
			($topErrors | Where-Object {
				$_.Source  -match 'UDP|Shortpath|ICE|TURN|STUN' -or
				$_.Message -match 'UDP|Shortpath|ICE|TURN|STUN'
			} | Measure-Object -Property Count -Sum).Sum
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
			foreach ($row in $transportRows) {
				$transportTypeBreakdown += [PSCustomObject]@{
					TransportType = [string]$row[0]
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
				$hostRegistrationBreakdown += [PSCustomObject]@{
					SessionHostName   = [string]$row[0]
					RegistrationCount = [int]$row[1]
					LastSeen          = [string]$row[2]
				}
			}
		}

		$hostRegistrationEvents = if ($hostRegistrationBreakdown.Count -gt 0) {
			($hostRegistrationBreakdown | Measure-Object -Property RegistrationCount -Sum).Sum
		} else { $null }

		$status = if ($queryErrors.Count -eq 0) { 'OK' } else { "PartialData (failed: $($queryErrors -join '; '))" }

		return [PSCustomObject]@{
			DiagnosticsStatus         = $status
			TotalErrors               = $totalErrors
			TotalFailedConnections    = $totalFailedConnections
			ShortpathErrors           = $shortpathErrors
			ShortpathUpgradeEvents    = $shortpathUpgradeEvents
			HostRegistrationEvents    = $hostRegistrationEvents
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
			$raResp = Invoke-AzRestMethod -Path $raPath -Method GET -ErrorAction Stop
			if ($raResp.StatusCode -eq 200) {
				$assignments = ($raResp.Content | ConvertFrom-Json).value |
					Where-Object { $_.properties.roleDefinitionId -match $dvUserRoleGuid }
				foreach ($ra in $assignments) {
					switch ($ra.properties.principalType) {
						'User'  { $directUserIds.Add($ra.properties.principalId)  | Out-Null }
						'Group' { $directGroupIds.Add($ra.properties.principalId) | Out-Null }
					}
				}
			}
			else { $hadErrors = $true }
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

	$resp = Invoke-AzRestMethod -Path "${VmResourceId}/instanceView?api-version=2024-03-01" -Method GET -ErrorAction SilentlyContinue
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
		[int]$InitialPollSeconds = 10
	)

	# Retrieve the VM's Azure region — required as the 'location' field in the PUT body.
	$vmResp = Invoke-AzRestMethod -Path "${VmResourceId}?api-version=2024-03-01" -Method GET -ErrorAction SilentlyContinue
	if (-not $vmResp -or $vmResp.StatusCode -ne 200) {
		$sc = if ($vmResp) { $vmResp.StatusCode } else { 'n/a' }
		Write-Host "    [LocalDiscovery] Could not retrieve VM metadata (HTTP $sc)."
		return $null
	}
	$vmLocation = ($vmResp.Content | ConvertFrom-Json).location

	# Build a unique runCommands child-resource path.
	$cmdName     = "avd-disc-$([Guid]::NewGuid().ToString('N').Substring(0, 12))"
	$cmdPath     = "${VmResourceId}/runCommands/${cmdName}?api-version=2024-03-01"
	$cmdPathView = "${VmResourceId}/runCommands/${cmdName}?api-version=2024-03-01&`$expand=instanceView"
	$scriptText  = $Script -join "`n"

	# asyncExecution = $false ensures the ARM async operation does not report 'Succeeded'
	# until the script on the VM has finished. This lets a single polling loop cover both
	# resource provisioning and script execution.
	$body = @{
		location   = $vmLocation
		properties = @{
			source           = @{ script = $scriptText }
			asyncExecution   = $false
			timeoutInSeconds = $TimeoutSeconds
		}
	} | ConvertTo-Json -Depth 5

	try {
		Write-Host "    [LocalDiscovery] Submitting Run Command v2 to '$cmdName'..."
		$putRsp = Invoke-AzRestMethod -Path $cmdPath -Method PUT -Payload $body -ErrorAction Stop
		Write-Host "    [LocalDiscovery] PUT returned HTTP $($putRsp.StatusCode)."

		if ($putRsp.StatusCode -notin @(200, 201, 202)) {
			Write-Host "    [LocalDiscovery] Run Command v2 PUT returned HTTP $($putRsp.StatusCode) — expected 200, 201, or 202."
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
			Write-Host "    [LocalDiscovery] No Azure-AsyncOperation or Location header in Run Command v2 PUT response."
			return $null
		}

		$pollPath  = ([Uri]$pollFullUri).PathAndQuery
		$deadline  = (Get-Date).AddSeconds($TimeoutSeconds)
		$pollSleep = $InitialPollSeconds
		$pollCount = 0
		Write-Host "    [LocalDiscovery] Waiting for script execution on VM (timeout ${TimeoutSeconds}s)..."

		while ((Get-Date) -lt $deadline) {
			Start-Sleep -Seconds $pollSleep
			$pollCount++
			if ($pollSleep -lt 30) { $pollSleep = [Math]::Min(30, $pollSleep + 5) }

			$elapsed = [int]((Get-Date) - $deadline.AddSeconds(-$TimeoutSeconds)).TotalSeconds
			Write-Host "    [LocalDiscovery] Polling attempt #$pollCount (${elapsed}s elapsed)..."
			$pollRsp = Invoke-AzRestMethod -Path $pollPath -Method GET -ErrorAction SilentlyContinue
			if (-not $pollRsp) { continue }
			if ($pollRsp.StatusCode -eq 202) { continue }  # still in progress

			if ($pollRsp.StatusCode -eq 200) {
				$pollBody = $pollRsp.Content | ConvertFrom-Json
				if ($pollBody.PSObject.Properties['status']) {
					$opStatus = $pollBody.status
					if ($opStatus -in @('InProgress', 'Running')) { continue }
					if ($opStatus -ne 'Succeeded') {
						Write-Host "    [LocalDiscovery] Run Command v2 operation ended with status '$opStatus'."
						Write-Host "    [LocalDiscovery] Full poll body: $($pollRsp.Content.Substring(0, [Math]::Min(800, $pollRsp.Content.Length)))"
						return $null
					}
					Write-Host "    [LocalDiscovery] Script execution completed (poll #$pollCount)."
					break  # Succeeded — script has finished; fall through to GET.
				}
				Write-Host "    [LocalDiscovery] Poll response had no 'status' property (poll #$pollCount). Raw: $($pollRsp.Content.Substring(0, [Math]::Min(300, $pollRsp.Content.Length)))"
				return $null
			}

			Write-Host "    [LocalDiscovery] Unexpected poll HTTP $($pollRsp.StatusCode) on attempt #$pollCount."
			return $null
		}

		if ((Get-Date) -ge $deadline) {
			Write-Host "    [LocalDiscovery] Run Command v2 polling timed out after $TimeoutSeconds seconds ($pollCount poll(s))."
			return $null
		}

		# Retrieve the result from the runCommands resource with $expand=instanceView.
		# instanceView.output holds stdout without any character-count limit.
		Write-Host "    [LocalDiscovery] Retrieving script output..."
		$getResp = Invoke-AzRestMethod -Path $cmdPathView -Method GET -ErrorAction SilentlyContinue
		if (-not $getResp -or $getResp.StatusCode -ne 200) {
			$sc = if ($getResp) { $getResp.StatusCode } else { 'n/a' }
			Write-Host "    [LocalDiscovery] Run Command v2 result GET returned HTTP $sc."
			return $null
		}

		$parsed = $getResp.Content | ConvertFrom-Json
		$props  = $parsed.properties
		if (-not $props -or -not $props.PSObject.Properties['instanceView']) {
			Write-Host "    [LocalDiscovery] Run Command v2 instanceView not found in GET response."
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
		Write-Host "    [LocalDiscovery] Cleaning up Run Command resource '$cmdName'..."
		Invoke-AzRestMethod -Path $cmdPath -Method DELETE -ErrorAction SilentlyContinue | Out-Null
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

	$chunkCount = [Math]::Ceiling($FileLength / $ChunkSize)
	Write-Host "    [LocalDiscovery] Reading output in $chunkCount chunk(s) ($FileLength chars total)..."

	$sb = [System.Text.StringBuilder]::new($FileLength)

	for ($i = 0; $i -lt $chunkCount; $i++) {
		$offset = $i * $ChunkSize
		Write-Host "    [LocalDiscovery] Chunk $($i + 1)/$chunkCount (offset $offset)..."

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
			Write-Warning "[LocalDiscovery] Empty response for chunk $($i + 1)/$chunkCount."
			return $null
		}

		$s = $chunkOut.IndexOf('##CHUNK_START##')
		$e = $chunkOut.IndexOf('##CHUNK_END##')
		if ($s -lt 0 -or $e -lt 0 -or $e -le $s) {
			Write-Warning "[LocalDiscovery] Chunk $($i + 1) markers not found. Output: $($chunkOut.Substring(0, [Math]::Min(200, $chunkOut.Length)))"
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
	Finds the first running session host VM in a host pool, executes LocalScript.ps1
	on it via the Azure VM Run Command API, and saves the resulting JSON to the
	vm-discovery output directory. Non-fatal — logs a warning and continues on failure.

	.DESCRIPTION
	A small bootstrap script is sent as the Run Command payload. On the VM it downloads
	LocalScript.ps1 and appExclusions.config.json directly from the GitHub repository
	(raw.githubusercontent.com) using Invoke-WebRequest, executes the script into a
	temp directory, writes the GZip-compressed base64-encoded JSON to a staging file,
	and returns just the file path and size via stdout. The caller then reads the staging
	file back in fixed-size chunks (Run Command stdout is limited to the last 4,096 chars
	by the Azure VM Agent), assembles the payload, decodes it, and writes it to the
	vm-discovery folder. The staging file is deleted after retrieval.

	Requires the authenticated account to have 'Virtual Machine Contributor' or
	'Virtual Machine Run Command Contributor' rights on the session host VMs.
	The session host must have outbound HTTPS access to raw.githubusercontent.com.
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
		[string]$GitHubRawBaseUrl
	)

	if (@($VmResourceIds).Count -eq 0) {
		Write-Host "    [LocalDiscovery] No session host VMs registered in '$($Pool.Name)' — skipping."
		return
	}

	# Find the first VM in the running power state
	$targetVmId = $null
	foreach ($vmId in $VmResourceIds) {
		Write-Host "    [LocalDiscovery] Checking power state: $(($vmId -split '/')[-1])"
		$state = Get-VmPowerState -VmResourceId $vmId
		if ($state -eq 'PowerState/running') {
			$targetVmId = $vmId
			break
		}
	}

	if ([string]::IsNullOrEmpty($targetVmId)) {
		Write-Host "    [LocalDiscovery] No running hosts found in pool '$($Pool.Name)' — skipping."
		return
	}

	$vmName          = ($targetVmId -split '/')[-1]
	$scriptUrl       = "$GitHubRawBaseUrl/LocalScript.ps1"
	$configUrl       = "$GitHubRawBaseUrl/appExclusions.config.json"
	$custCodeEscaped = $CustomerCode -replace "'", "''"

	Write-Host "    [LocalDiscovery] Target VM: $vmName"
	Write-Host "    [LocalDiscovery] Fetching script from: $scriptUrl"

	# Bootstrap sent as the Run Command payload. Downloads both files from GitHub then
	# executes LocalScript.ps1. JSON output is GZip-compressed and base64-encoded so it
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
		'    $scrPath = Join-Path $tmp "LocalScript.ps1"',
		'    $cfgPath = Join-Path $tmp "appExclusions.config.json"',
		'    $outDir  = Join-Path $tmp "output"',
		'    New-Item -ItemType Directory -Path $tmp    -Force | Out-Null',
		'    New-Item -ItemType Directory -Path $outDir -Force | Out-Null',
		'    Invoke-WebRequest -Uri $scriptUrl -OutFile $scrPath -UseBasicParsing',
		'    Invoke-WebRequest -Uri $configUrl -OutFile $cfgPath -UseBasicParsing',
		'    & $scrPath -CustomerAbbreviation $cCode -OutputDirectory $outDir -NoGpresult -PrimaryApplicationsOnly -ErrorAction Stop *>&1 | Out-Null',
		'    $jf = Get-ChildItem -Path $outDir -Filter "*.json" -File | Select-Object -First 1',
		'    if (-not $jf) { throw "No JSON output produced by LocalScript.ps1" }',
		'    $jsonObj = Get-Content -Path $jf.FullName -Raw | ConvertFrom-Json',
		'    $sectionSizes = ($jsonObj.PSObject.Properties | ForEach-Object { $v = $_.Value | ConvertTo-Json -Depth 10 -Compress; "{0}={1}" -f $_.Name,[Math]::Round($v.Length/1KB,1) }) -join ","',
		'    $jb  = [System.IO.File]::ReadAllBytes($jf.FullName)',
		'    $cms = [System.IO.MemoryStream]::new()',
		'    $cgz = [System.IO.Compression.GZipStream]::new($cms, [System.IO.Compression.CompressionMode]::Compress)',
		'    $cgz.Write($jb, 0, $jb.Length)',
		'    $cgz.Close()',
		'    $b64     = [Convert]::ToBase64String($cms.ToArray())',
		'    $stgPath = Join-Path ([System.IO.Path]::GetTempPath()) ("avd-stage-$id.b64")',
		'    [System.IO.File]::WriteAllText($stgPath, $b64, [System.Text.Encoding]::ASCII)',
		'    Write-Output "##AVD_FILE##$stgPath##SIZE##$($b64.Length)##JSON##$($jb.Length)##SECTIONS##$sectionSizes##"',
		'} catch {',
		'    $errMsg = ($_.Exception.Message -replace "[\r\n]+", " ").Trim()',
		'    Write-Output "##AVD_LOCAL_DISCOVERY_ERROR##$errMsg"',
		'} finally {',
		'    if ($tmp -and (Test-Path $tmp)) { Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue }',
		'}'
	)

	# Run the bootstrap wrapper. It downloads LocalScript.ps1, executes it, compresses
	# the output, and writes the base64 payload to a staging file — returning just the
	# path and size via stdout (stdout itself is limited to the last 4,096 chars).
	$stdout = $null
	try {
		$stdout = Invoke-VmRunCommand -VmResourceId $targetVmId -Script $wrapperLines -TimeoutSeconds 600
	}
	catch {
		Write-Warning "[LocalDiscovery] Run Command submission failed for '$vmName': $($_.Exception.Message)"
		return
	}

	if ([string]::IsNullOrEmpty($stdout)) {
		Write-Warning "[LocalDiscovery] Run Command returned no output from '$vmName'. Verify the VM agent is running and the caller has 'Virtual Machine Contributor' rights."
		return
	}

	# Script-level error reported by the wrapper.
	if ($stdout -match '(?s)##AVD_LOCAL_DISCOVERY_ERROR##(.+)') {
		Write-Warning "[LocalDiscovery] LocalScript.ps1 reported an error on '$vmName': $($Matches[1].Trim())"
		return
	}

	# Parse the staging file path and character count.
	if ($stdout -notmatch '##AVD_FILE##(.+?)##SIZE##(\d+)##') {
		$diagLen  = $stdout.Length
		$diagHead = $stdout.Substring(0, [Math]::Min(300, $diagLen))
		Write-Warning "[LocalDiscovery] Staging file marker not found in response from '$vmName' ($diagLen chars). Output: $diagHead"
		return
	}
	$stagingPath = $Matches[1].Trim()
	$fileSize    = [int]$Matches[2]
	$rawJsonSize = ''
	if ($stdout -match '##JSON##(\d+)##') {
		$rawJsonBytes = [int64]$Matches[1]
		$rawJsonSize  = " (raw JSON: $([Math]::Round($rawJsonBytes / 1KB, 1)) KB)"
	}
	Write-Host "    [LocalDiscovery] Staging file written: $stagingPath ($fileSize chars)$rawJsonSize"
	if ($stdout -match '##SECTIONS##(.+?)##') {
		$sectionData = $Matches[1]
		Write-Host "    [LocalDiscovery] Section sizes (KB): $sectionData"
	}

	# Read the staging file back in chunks, then delete it regardless of success or failure.
	$b64Payload = $null
	try {
		$b64Payload = Read-VmFileInChunks -VmResourceId $targetVmId -FilePath $stagingPath -FileLength $fileSize
	}
	finally {
		Write-Host "    [LocalDiscovery] Deleting staging file..."
		$cleanupLines = @("if (Test-Path '$stagingPath') { Remove-Item -Path '$stagingPath' -Force -ErrorAction SilentlyContinue }")
		Invoke-VmRunCommand -VmResourceId $targetVmId -Script $cleanupLines -TimeoutSeconds 60 -InitialPollSeconds 3 | Out-Null
	}

	if ([string]::IsNullOrEmpty($b64Payload)) {
		Write-Warning "[LocalDiscovery] Failed to retrieve data from staging file on '$vmName'."
		return
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
		Write-Warning "[LocalDiscovery] Failed to decompress/decode output from '$vmName': $($_.Exception.Message)"
		return
	}

	if (-not (Test-Path -Path $VmDiscoveryDirectory)) {
		New-Item -ItemType Directory -Path $VmDiscoveryDirectory -Force | Out-Null
	}

	$timestamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
	$outputFile = Join-Path $VmDiscoveryDirectory "$CustomerCode-$($vmName.ToLowerInvariant())-avd-discovery-$timestamp.json"
	[System.IO.File]::WriteAllText($outputFile, $jsonContent, [System.Text.Encoding]::UTF8)
	Write-Host "    [LocalDiscovery] Saved: $outputFile"
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
	$endTime       = (Get-Date).ToUniversalTime().Date          # midnight UTC today
	$startTime     = $endTime.AddDays(-$LookbackDays)

	$resolvedOutputDirectory    = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { Join-Path $PSScriptRoot 'avd-metrics' } else { [System.IO.Path]::GetFullPath($OutputDirectory) }
	$resolvedOutputPath         = New-ExportFilePath -Directory $resolvedOutputDirectory -CustomerCode $customerCode
	$resolvedVmDiscoveryDirectory = Join-Path $PSScriptRoot 'vm-discovery'
	$gitHubRawBaseUrl             = "https://raw.githubusercontent.com/wavenetuk/avd-discovery/$GitHubBranch"

	if (-not [string]::IsNullOrWhiteSpace($resolvedOutputDirectory) -and -not (Test-Path -Path $resolvedOutputDirectory)) {
		New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
	}

	Write-Host "AVD Metrics Collection"
	$scriptStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
	Write-Host "  Lookback period : $($startTime.ToString('yyyy-MM-dd')) — $($endTime.ToString('yyyy-MM-dd')) ($LookbackDays days)"
	Write-Host "  Exclude weekends: $($ExcludeWeekends.IsPresent)"
	Write-Host "  Peak hours only : $($PeakHoursOnly.IsPresent)$(if ($PeakHoursOnly.IsPresent) { " (09:00–18:00 local, UTC$([string]::Format('{0:+0;-0}', $UtcOffsetHours))" + ')' })"
	Write-Host "  Host pool filter: $(if ($HostPoolName -and @($HostPoolName).Count -gt 0) { $HostPoolName -join ', ' } else { '(all pools)' })"
	Write-Host "  Local discovery : $($RunLocalDiscovery.IsPresent)$(if ($RunLocalDiscovery.IsPresent) { " — $gitHubRawBaseUrl" })"
	Write-Host ""

	Write-Host "Discovering host pools..."
	$subscriptions = Get-TargetSubscriptions -SubscriptionIds $SubscriptionId
	$hostPools     = Get-AllHostPools -Subscriptions $subscriptions
	if ($HostPoolName -and @($HostPoolName).Count -gt 0) {
		$hostPools = @($hostPools | Where-Object { $_.Name -in $HostPoolName })
		if ($hostPools.Count -eq 0) {
			throw "No host pools matched the specified -HostPoolName filter: $($HostPoolName -join ', ')"
		}
	}
	Write-Host "Found $($hostPools.Count) host pool(s) across $(@($subscriptions).Count) subscription(s)."
	Write-Host ""

	# Acquire Graph token once — used to expand Entra ID group memberships
	$graphToken = Get-GraphToken
	if ($graphToken) { Write-Host "Graph token acquired for group expansion." }
	else             { Write-Warning "Graph token unavailable — group assignments will not be expanded to members." }
	Write-Host ""

	# Load Microsoft licence SKU display-name map from the CSV published by Microsoft.
	# Keyed by String_Id (SKU part number) -> Product_Display_Name. Each product has
	# multiple rows (one per service plan) so we take the first occurrence only.
	$skuDisplayNameMap = @{}
	$skuCsvPath = Join-Path $PSScriptRoot 'ms-service-plan-ids.csv'
	if (Test-Path $skuCsvPath) {
		foreach ($row in (Import-Csv -Path $skuCsvPath)) {
			if (-not [string]::IsNullOrWhiteSpace($row.String_Id) -and
			    -not $skuDisplayNameMap.ContainsKey($row.String_Id)) {
				$skuDisplayNameMap[$row.String_Id] = $row.Product_Display_Name
			}
		}
		Write-Host "Loaded $($skuDisplayNameMap.Count) licence SKU name(s) from ms-service-plan-ids.csv."
	}
	else {
		Write-Warning "ms-service-plan-ids.csv not found at '$skuCsvPath' — ProductName will be null in licence summary."
	}

	Write-Host "Collecting metrics..."
	$vmSizeMemCache  = @{}  # "subscriptionId/location" -> hashtable of size name -> memory GB
	$appGroupCache   = @{}  # subscriptionId -> all AVD app groups in that subscription
	$workspaceCache  = @{}  # subscriptionId -> all AVD workspaces in that subscription
	$vaultCache           = @{}  # subscriptionId -> Recovery Services Vaults in that subscription
	$allAuthorizedUserIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

	# Fetch all reservations once at tenant scope (best-effort — null if caller lacks access)
	$allReservations = $null
	try {
		$resResp = Invoke-AzRestMethod -Path '/providers/Microsoft.Capacity/reservations?api-version=2022-11-01&\$expand=renewProperties' -Method GET -ErrorAction SilentlyContinue
		if ($resResp -and $resResp.StatusCode -eq 200) {
			$allReservations = @(($resResp.Content | ConvertFrom-Json).value)
			Write-Host "  Loaded $($allReservations.Count) reservation(s) for SKU matching."
		}
		elseif ($resResp -and $resResp.StatusCode -eq 403) {
			# 403 is expected when the tenant has no reservations or the caller lacks Reader
			# on reservation orders — treat as empty list rather than an error
			$allReservations = @()
			Write-Host "  No reservations found (or no access to reservation orders)."
		}
		else {
			Write-Warning "Reservation lookup returned HTTP $($resResp.StatusCode) — ReservationMatchStatus will be 'Unavailable'."
		}
	}
	catch {
		Write-Warning "Could not retrieve reservations: $($_.Exception.Message)"
	}
	$poolMetrics = foreach ($pool in $hostPools) {
		Write-Host "  $($pool.Name) ($($pool.SubscriptionName))"
		Set-AzContext -SubscriptionId $pool.SubscriptionId -WarningAction SilentlyContinue | Out-Null

		$vmSizeCacheKey = "$($pool.SubscriptionId)/$($pool.Location)"
		if (-not $vmSizeMemCache.ContainsKey($vmSizeCacheKey)) {
			$vmSizeMemCache[$vmSizeCacheKey] = Get-VmSizeMemoryGbMap -SubscriptionId $pool.SubscriptionId -Location $pool.Location
		}
		$vmSizeMemGbMap = $vmSizeMemCache[$vmSizeCacheKey]

		if (-not $appGroupCache.ContainsKey($pool.SubscriptionId)) {
			$agResp = Invoke-AzRestMethod -Path "/subscriptions/$($pool.SubscriptionId)/providers/Microsoft.DesktopVirtualization/applicationGroups?api-version=2023-09-05" -Method GET -ErrorAction SilentlyContinue
			$appGroupCache[$pool.SubscriptionId] = if ($agResp -and $agResp.StatusCode -eq 200) { ($agResp.Content | ConvertFrom-Json).value } else { @() }

			$wsResp = Invoke-AzRestMethod -Path "/subscriptions/$($pool.SubscriptionId)/providers/Microsoft.DesktopVirtualization/workspaces?api-version=2023-09-05" -Method GET -ErrorAction SilentlyContinue
			$workspaceCache[$pool.SubscriptionId] = if ($wsResp -and $wsResp.StatusCode -eq 200) { ($wsResp.Content | ConvertFrom-Json).value } else { @() }
		}

		$infra         = Get-HostPoolInfraInfo -HostPool $pool
		$reservations  = Get-ReservationMatches -VmSkus @(if ($infra.VmSkus) { $infra.VmSkus } else { @() }) -Location $pool.Location -AllReservations $allReservations
		$backupInfo    = if ($pool.HostPoolType -eq 'Personal') {
			Get-HostPoolBackupInfo -SubscriptionId $pool.SubscriptionId -VmResourceIds @($infra.VmResourceIds) -VaultCache $vaultCache
		} else {
			[PSCustomObject]@{ BackupInfo = $null; BackupInfoStatus = 'NotApplicable' }
		}
		$metrics        = Get-HostPoolDailyAverageUsers -HostPool $pool -StartTime $startTime -EndTime $endTime -ExcludeWeekends:$ExcludeWeekends -PeakHoursOnly:$PeakHoursOnly -UtcOffsetHours $UtcOffsetHours
		$sessionMetrics = Get-HostPoolConcurrentSessionMetrics -HostPool $pool -StartTime $startTime -EndTime $endTime -ExcludeWeekends:$ExcludeWeekends -PeakHoursOnly:$PeakHoursOnly -UtcOffsetHours $UtcOffsetHours
		$diagInsights   = Get-HostPoolDiagnosticInsights -HostPool $pool -StartTime $startTime -EndTime $endTime
		$cpuMetrics     = Get-HostPoolVmCpuMetrics -VmResourceIds $infra.VmResourceIds -StartTime $startTime -EndTime $endTime -ExcludeWeekends:$ExcludeWeekends -PeakHoursOnly:$PeakHoursOnly -UtcOffsetHours $UtcOffsetHours
		$memMetrics     = Get-HostPoolVmMemoryMetrics -VmResourceIds $infra.VmResourceIds -VmSizeMap $infra.VmSizeMap -VmSizeMemoryGbMap $vmSizeMemGbMap -StartTime $startTime -EndTime $endTime -ExcludeWeekends:$ExcludeWeekends -PeakHoursOnly:$PeakHoursOnly -UtcOffsetHours $UtcOffsetHours
		$authUsers      = Get-HostPoolAuthorizedUsers -HostPool $pool -GraphToken $graphToken -AppGroupCache $appGroupCache -WorkspaceCache $workspaceCache
		foreach ($uid in $authUsers.AuthorizedUserIds) { $allAuthorizedUserIds.Add($uid) | Out-Null }

		if ($RunLocalDiscovery.IsPresent -and @($infra.VmResourceIds).Count -gt 0) {
			Invoke-HostPoolLocalDiscovery -Pool $pool -VmResourceIds @($infra.VmResourceIds) -CustomerCode $customerCode -VmDiscoveryDirectory $resolvedVmDiscoveryDirectory -GitHubRawBaseUrl $gitHubRawBaseUrl
		}

		[PSCustomObject]@{
			Name                 = $pool.Name
			FriendlyName         = $pool.FriendlyName
			SubscriptionId       = $pool.SubscriptionId
			SubscriptionName     = $pool.SubscriptionName
			ResourceGroup        = $pool.ResourceGroup
			Location             = $pool.Location
			HostPoolType         = $pool.HostPoolType
			LoadBalancerType     = $pool.LoadBalancerType
			MaxSessionLimit      = $pool.MaxSessionLimit
			HostCount            = $infra.HostCount
			VmSkus               = $infra.VmSkus
			VmSkusStatus         = $infra.VmSkusStatus
			DomainJoinType       = $infra.DomainJoinType
			DomainName           = $infra.DomainName
			VmExtensions         = $infra.VmExtensions
			ImageReferences      = $infra.ImageReferences
			OsDiskSizeGb         = $infra.OsDiskSizeGb
			OsDiskSkus           = $infra.OsDiskSkus
			NetworkInfo          = $infra.NetworkInfo
			ReservationMatchStatus = $reservations.ReservationMatchStatus
			MatchedReservations    = $reservations.MatchedReservations
			BackupInfoStatus       = $backupInfo.BackupInfoStatus
			BackupInfo             = $backupInfo.BackupInfo
			ScalingPlan          = $infra.ScalingPlan
			WorkspaceNames       = $authUsers.WorkspaceNames
			AppGroupNames        = $authUsers.AppGroupNames
			AccessAssignments    = $authUsers.AccessAssignments
			AuthorizedUserCount  = $authUsers.AuthorizedUserCount
			AuthorizedUserStatus = $authUsers.AuthorizedUserStatus
			AvgCpuPercent            = $cpuMetrics.AvgCpuPercent
			P95CpuPercent            = $cpuMetrics.P95CpuPercent
			P99CpuPercent            = $cpuMetrics.P99CpuPercent
			CpuStatus                = $cpuMetrics.CpuStatus
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
			DiagnosticsStatus         = $diagInsights.DiagnosticsStatus
			TotalErrors               = $diagInsights.TotalErrors
			TotalFailedConnections    = $diagInsights.TotalFailedConnections
			ShortpathErrors           = $diagInsights.ShortpathErrors
			ShortpathUpgradeEvents    = $diagInsights.ShortpathUpgradeEvents
			HostRegistrationEvents    = $diagInsights.HostRegistrationEvents
			TopErrors                 = $diagInsights.TopErrors
			TransportTypeBreakdown    = $diagInsights.TransportTypeBreakdown
			HostRegistrationBreakdown = $diagInsights.HostRegistrationBreakdown
		}
	}

	Write-Host ""
	if ($SkipLicenceCheck.IsPresent) {
		Write-Host "Skipping licence assignments (−SkipLicenceCheck specified)."
		$licSummary = [PSCustomObject]@{
			LicenseSummary       = @()
			LicenseSummaryStatus = 'Skipped'
			UnlicensedUserCount  = $null
			UnlicensedUsers      = @()
		}
	} else {
		Write-Host "Collecting licence assignments for $($allAuthorizedUserIds.Count) unique authorized user(s)..."
		$licSummary = Get-UserLicenseSummary -UserObjectIds @($allAuthorizedUserIds) -GraphToken $graphToken -SkuDisplayNameMap $skuDisplayNameMap
		if ($licSummary.LicenseSummaryStatus -eq 'OK') {
			Write-Host "  Found $(@($licSummary.LicenseSummary).Count) distinct licence SKU(s)."
		}
		if ($licSummary.UnlicensedUserCount -gt 0) {
			Write-Warning "  $($licSummary.UnlicensedUserCount) user(s) have no AVD-eligible licence."
		}
	}

	$exportObject = [PSCustomObject]@{
		CustomerAbbreviation    = $customerCode
		CollectedAt             = (Get-Date).ToString('s')
		MetricPeriodStart       = $startTime.ToString('s')
		MetricPeriodEnd         = $endTime.ToString('s')
		LookbackDays            = $LookbackDays
		ExcludeWeekends         = $ExcludeWeekends.IsPresent
		PeakHoursOnly           = $PeakHoursOnly.IsPresent
		UtcOffsetHours          = $UtcOffsetHours
		SubscriptionCount       = @($subscriptions).Count
		HostPoolCount           = $hostPools.Count
		LicenseSummaryUserCount = $allAuthorizedUserIds.Count
		LicenseSummaryStatus    = $licSummary.LicenseSummaryStatus
		LicenseSummary          = $licSummary.LicenseSummary
		UnlicensedUserCount     = $licSummary.UnlicensedUserCount
		UnlicensedUsers         = $licSummary.UnlicensedUsers
		HostPools               = $poolMetrics
	}

	$exportObject | ConvertTo-Json -Depth 6 | Set-Content -Path $resolvedOutputPath -Encoding UTF8

	Write-Host ""
	Write-Host "Metrics collection complete."
	Write-Host "Exported $($hostPools.Count) host pool(s) to: $resolvedOutputPath"
	Write-Host "Completed in $([Math]::Round($scriptStopwatch.Elapsed.TotalSeconds, 1))s"
}
catch {
	Write-Error "AVD metrics collection failed. $($_.Exception.Message)"
	exit 1
}
finally {
	# Restore the caller's original Az context so this script's subscription
	# switches do not alter the active context in the calling session.
	if ($null -ne $originalContext) {
		Set-AzContext -Context $originalContext -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null
	}
}
