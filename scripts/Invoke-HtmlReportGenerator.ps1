[CmdletBinding()]
<#
.SYNOPSIS
Generates an HTML report from a previously exported AVD JSON payload.

.DESCRIPTION
This script is the shared HTML generation entry point used by the AVD discovery
collectors after they finish writing their JSON output.

It does not collect Azure data itself. Instead, it:

1. Loads the JSON report payload from disk.
2. Resolves the report type either from -ReportType or the payload's ReportType field.
3. Imports the registered HTML renderer modules from scripts/reporting.
4. Dispatches the payload to the matching renderer.
5. Writes the rendered HTML file to either -OutputPath or next to the JSON file.

The result object returned by this script reports the resolved report type, the
HTML file path written, the source JSON path, and the renderer module used.

.PARAMETER JsonPath
Path to the JSON report payload that should be converted into HTML.

.PARAMETER OutputPath
Optional output path for the generated HTML file. If omitted, the script writes
an .html file alongside the JSON input.

.PARAMETER ReportType
Optional explicit report type override. If omitted, the script uses the ReportType
property embedded in the JSON payload.

.EXAMPLE
.\Invoke-HtmlReportGenerator.ps1 -JsonPath .\output\avd-metrics\customer-avd-metrics.json

.EXAMPLE
.\Invoke-HtmlReportGenerator.ps1 -JsonPath .\report.json -ReportType AvdMetrics -OutputPath .\report.html
#>
param(
	[Parameter(Mandatory = $true)]
	[string]$JsonPath,

	[Parameter(Mandatory = $false)]
	[string]$OutputPath,

	[Parameter(Mandatory = $false)]
	[string]$ReportType
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ReportRenderers = @{}
$script:PortableRendererBaseUrl = 'https://raw.githubusercontent.com/wavenetuk/avd-discovery/main/scripts/reporting'
$script:PortableRendererFileNames = @(
	'JsonReportRenderer.00.Default.ps1',
	'JsonReportRenderer.AvdMetrics.ps1',
	'JsonReportRenderer.AzureSessionHostAudit.ps1',
	'DefaultReportShell.html',
	'JsonReportRenderer.Shared.Client.js',
	'JsonReportRenderer.AvdMetrics.Client.js',
	'JsonReportRenderer.AzureSessionHostAudit.Client.js'
)

function ConvertTo-SafePathSegment {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Value
	)

	$segment = ($Value | ForEach-Object { $_.ToString() }).Trim()
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

function Register-AvdReportRenderer {
	param(
		[Parameter(Mandatory = $true)]
		[string]$ReportType,

		[Parameter(Mandatory = $true)]
		[scriptblock]$RenderScript,

		[Parameter(Mandatory = $false)]
		[string]$ModuleName
	)

	$script:ReportRenderers[$ReportType] = [PSCustomObject]@{
		ReportType   = $ReportType
		RenderScript = $RenderScript
		ModuleName   = if ([string]::IsNullOrWhiteSpace($ModuleName)) { $ReportType } else { $ModuleName }
	}
}

function Get-PortableRendererDirectory {
	$cacheRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'avd-discovery-html-renderers'
	$branchCacheRoot = Join-Path -Path $cacheRoot -ChildPath 'main'
	return $branchCacheRoot
}

function Ensure-PortableRendererDirectory {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Directory
	)

	if (-not (Test-Path -Path $Directory)) {
		New-Item -ItemType Directory -Path $Directory -Force | Out-Null
	}

	try {
		[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
	}
	catch {
	}

	$downloadClient = [System.Net.WebClient]::new()
	try {
		foreach ($fileName in $script:PortableRendererFileNames) {
			$targetPath = Join-Path -Path $Directory -ChildPath $fileName
			if (Test-Path -Path $targetPath) {
				continue
			}

			$sourceUri = "$($script:PortableRendererBaseUrl)/$fileName"
			$downloadClient.DownloadFile($sourceUri, $targetPath)
		}
	}
	finally {
		$downloadClient.Dispose()
	}
}

function Resolve-ReportRendererDirectory {
	$candidateDirectories = @(
		(Join-Path -Path $PSScriptRoot -ChildPath 'reporting'),
		(Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'scripts\reporting')
	)

	foreach ($candidateDirectory in $candidateDirectories) {
		if (Test-Path -Path $candidateDirectory) {
			return $candidateDirectory
		}
	}

	$portableDirectory = Get-PortableRendererDirectory
	Ensure-PortableRendererDirectory -Directory $portableDirectory
	return $portableDirectory
}

function Test-LocalReportRendererLayoutAvailable {
	$candidateDirectories = @(
		(Join-Path -Path $PSScriptRoot -ChildPath 'reporting'),
		(Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'scripts\reporting')
	)

	foreach ($candidateDirectory in $candidateDirectories) {
		if (Test-Path -Path $candidateDirectory) {
			return $true
		}
	}

	return $false
}

function Get-PortableResultsFolderName {
	param(
		[Parameter(Mandatory = $true)]
		[string]$ReportType,

		[Parameter(Mandatory = $false)]
		[string]$CustomerCode
	)

	$safeCustomerCode = ConvertTo-SafePathSegment -Value $CustomerCode
	switch ($ReportType) {
		'AzureSessionHostAudit' { return "{0}-audit-results" -f $safeCustomerCode }
		'AvdMetrics' { return "{0}-metrics-results" -f $safeCustomerCode }
		default { return "{0}-report-results" -f $safeCustomerCode }
	}
}

function Resolve-PortableOutputPath {
	param(
		[Parameter(Mandatory = $true)]
		[string]$ResolvedJsonPath,

		[Parameter(Mandatory = $true)]
		[string]$ResolvedReportType,

		[Parameter(Mandatory = $true)]
		$Data
	)

	$customerCode = $null
	if ($Data.PSObject.Properties['CustomerAbbreviation'] -and -not [string]::IsNullOrWhiteSpace([string]$Data.CustomerAbbreviation)) {
		$customerCode = [string]$Data.CustomerAbbreviation
	}

	if ([string]::IsNullOrWhiteSpace($customerCode)) {
		$fileName = [System.IO.Path]::GetFileNameWithoutExtension($ResolvedJsonPath)
		if ($fileName -match '^(?<code>[^-]+)-') {
			$customerCode = $matches.code
		}
	}

	if ([string]::IsNullOrWhiteSpace($customerCode)) {
		$customerCode = 'customer'
	}

	$resultsFolderName = Get-PortableResultsFolderName -ReportType $ResolvedReportType -CustomerCode $customerCode
	$resultsDirectory = Join-Path -Path $PSScriptRoot -ChildPath $resultsFolderName
	if (-not (Test-Path -Path $resultsDirectory)) {
		New-Item -ItemType Directory -Path $resultsDirectory -Force | Out-Null
	}

	return (Join-Path -Path $resultsDirectory -ChildPath ([System.IO.Path]::GetFileNameWithoutExtension($ResolvedJsonPath) + '.html'))
}

function Import-AvdReportRendererModules {
	$moduleDirectory = Resolve-ReportRendererDirectory

	Get-ChildItem -Path $moduleDirectory -Filter '*.ps1' -File | Sort-Object -Property Name | ForEach-Object {
		. $_.FullName
	}
}

function Get-JsonReportPayload {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Path
	)

	$rawContent = Get-Content -Path $Path -Raw -Encoding UTF8
	return ($rawContent | ConvertFrom-Json)
}

function Resolve-ReportType {
	param(
		[Parameter(Mandatory = $false)]
		[string]$ExplicitReportType,

		[Parameter(Mandatory = $true)]
		$Data
	)

	if (-not [string]::IsNullOrWhiteSpace($ExplicitReportType)) {
		return $ExplicitReportType
	}

	if ($Data.PSObject.Properties['ReportType'] -and -not [string]::IsNullOrWhiteSpace([string]$Data.ReportType)) {
		return [string]$Data.ReportType
	}

	throw 'Unable to determine report type. Specify -ReportType or include ReportType in the JSON payload.'
}

Import-AvdReportRendererModules

$resolvedJsonPath = [System.IO.Path]::GetFullPath($JsonPath)
if (-not (Test-Path -Path $resolvedJsonPath)) {
	throw "JSON report input not found: $resolvedJsonPath"
}

$data = Get-JsonReportPayload -Path $resolvedJsonPath
$resolvedReportType = Resolve-ReportType -ExplicitReportType $ReportType -Data $data
$renderer = $script:ReportRenderers[$resolvedReportType]
if ($null -eq $renderer) {
	$available = @($script:ReportRenderers.Keys | Sort-Object)
	throw "No renderer is registered for report type '$resolvedReportType'. Available report types: $($available -join ', ')"
}

$resolvedOutputPath = if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
	[System.IO.Path]::GetFullPath($OutputPath)
} elseif (Test-LocalReportRendererLayoutAvailable) {
	[System.IO.Path]::ChangeExtension($resolvedJsonPath, '.html')
} else {
	Resolve-PortableOutputPath -ResolvedJsonPath $resolvedJsonPath -ResolvedReportType $resolvedReportType -Data $data
}

$writtenPath = & $renderer.RenderScript -Data $data -OutputPath $resolvedOutputPath -SourceJsonFileName (Split-Path -Path $resolvedJsonPath -Leaf)

[PSCustomObject]@{
	ReportType = $resolvedReportType
	HtmlPath   = $writtenPath
	JsonPath   = $resolvedJsonPath
	Renderer   = $renderer.ModuleName
}