[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)][string]$CustomerAbbreviation,
	[string]$OutputDirectory = (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\output\file-print'),
	[switch]$NoHtml
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonModulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\common\Discovery.Common.psm1'
$hostBaselineModulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\common\Discovery.HostBaseline.psm1'
$filePrintModulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\common\Discovery.FilePrint.psm1'
Import-Module -Name $commonModulePath -Force -ErrorAction Stop
Assert-DiscoveryHostCollectorReadOnly -ScriptPath $PSCommandPath
Import-Module -Name $hostBaselineModulePath -Force -ErrorAction Stop
Import-Module -Name $filePrintModulePath -Force -ErrorAction Stop

$resolvedOutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -Path $resolvedOutputDirectory -ItemType Directory -Force | Out-Null
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$jsonPath = Join-Path -Path $resolvedOutputDirectory -ChildPath ("{0}-file-print-host-{1}.json" -f $CustomerAbbreviation, $timestamp)

$loadedUsers = @(Get-DiscoveryLoadedUserProfiles)
$mappedDriveStates = @($loadedUsers | ForEach-Object { Get-DiscoveryUserMappedDriveState -Sid $_.Sid -AccountName $_.AccountName })
$mappedDrives = @($mappedDriveStates | ForEach-Object { @($_.MappedDrives) })
$applications = @(Get-DiscoveryInstalledApplications)
$report = [PSCustomObject]@{
	ReportType = 'FilePrintHostDiscovery'
	CustomerAbbreviation = $CustomerAbbreviation
	CollectedAt = (Get-Date).ToString('s')
	Collection = New-DiscoveryCollectionMetadata -Workload 'FilePrint' -ScannerMode 'Host' -Capabilities @('HostDiscovery', 'FileServices', 'PrintServices', 'HtmlReport')
	Machine = Get-DiscoveryMachineDetails
	Applications = $applications
	Antivirus = Get-DiscoveryAntivirus -InstalledApplications $applications
	LanguagePacks = Get-DiscoveryLanguagePacks
	TimeSource = Get-DiscoveryTimeSource
	Printers = Get-DiscoveryPrinterInventory
	UniversalPrint = Get-DiscoveryUniversalPrint
	FilePrintRoleState = Get-DiscoveryFilePrintRoleState
	LoadedUsers = $loadedUsers
	MappedDriveCount = $mappedDrives.Count
	MappedDrives = $mappedDrives
	HtmlGeneration = [PSCustomObject]@{ Requested = -not $NoHtml.IsPresent; Status = if ($NoHtml) { 'Skipped' } else { 'Pending' }; HtmlPath = $null }
}

$report | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonPath -Encoding UTF8
if (-not $NoHtml) { $report.HtmlGeneration = Invoke-OptionalHtmlReportGeneration -JsonPath $jsonPath -ReportType $report.ReportType -OutputPath ([System.IO.Path]::ChangeExtension($jsonPath, '.html')) -ScriptRoot $PSScriptRoot; $report | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonPath -Encoding UTF8 }
Write-Output $jsonPath