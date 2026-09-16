[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)][string]$CustomerAbbreviation,
	[string]$OutputDirectory = (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\output\rds'),
	[string]$ConnectionBroker,
	[switch]$NoHtml
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\common\Discovery.Common.psm1') -Force -ErrorAction Stop
Assert-DiscoveryHostCollectorReadOnly -ScriptPath $PSCommandPath
Import-Module (Join-Path $PSScriptRoot '..\..\common\Discovery.HostBaseline.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot '..\..\common\Discovery.RDS.psm1') -Force -ErrorAction Stop
$resolvedOutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory); New-Item -Path $resolvedOutputDirectory -ItemType Directory -Force | Out-Null
$jsonPath = Join-Path $resolvedOutputDirectory ("{0}-rds-host-{1}.json" -f $CustomerAbbreviation, (Get-Date -Format 'yyyyMMdd-HHmmss'))
$applications = @(Get-DiscoveryInstalledApplications)
$report = [PSCustomObject]@{ ReportType = 'RDSHostDiscovery'; CustomerAbbreviation = $CustomerAbbreviation; CollectedAt = (Get-Date).ToString('s'); Collection = New-DiscoveryCollectionMetadata -Workload 'RDS' -ScannerMode 'Host' -Capabilities @('HostDiscovery', 'RdsRoleDiscovery', 'BrokerTopology', 'HtmlReport'); Machine = Get-DiscoveryMachineDetails; Applications = $applications; RemoteDesktopServices = Get-DiscoveryRdsRoleState -ConnectionBroker $ConnectionBroker; HtmlGeneration = [PSCustomObject]@{ Requested = -not $NoHtml; Status = if ($NoHtml) { 'Skipped' } else { 'Pending' }; HtmlPath = $null } }
$report | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonPath -Encoding UTF8
if (-not $NoHtml) { $report.HtmlGeneration = Invoke-OptionalHtmlReportGeneration -JsonPath $jsonPath -ReportType $report.ReportType -OutputPath ([System.IO.Path]::ChangeExtension($jsonPath, '.html')) -ScriptRoot $PSScriptRoot; $report | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonPath -Encoding UTF8 }
Write-Output $jsonPath