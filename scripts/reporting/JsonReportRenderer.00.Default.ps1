Set-StrictMode -Version Latest

$script:AvdDefaultReportShellPrefix = $null
$script:AvdDefaultReportShellTemplatePath = Join-Path $PSScriptRoot 'DefaultReportShell.html'
$script:AvdSharedClientScriptPath = Join-Path $PSScriptRoot 'JsonReportRenderer.Shared.Client.js'

function script:Get-AvdDefaultReportShellPrefix {
	if ($null -ne $script:AvdDefaultReportShellPrefix) {
		return $script:AvdDefaultReportShellPrefix
	}

	if (-not (Test-Path -Path $script:AvdDefaultReportShellTemplatePath)) {
		throw "Default renderer template not found: $script:AvdDefaultReportShellTemplatePath"
	}

	$script:AvdDefaultReportShellPrefix = Get-Content -Path $script:AvdDefaultReportShellTemplatePath -Raw -Encoding UTF8
	return $script:AvdDefaultReportShellPrefix
}

function script:Invoke-AvdDefaultHtmlReportRenderer {
	param(
		[Parameter(Mandatory = $true)]
		$Data,

		[Parameter(Mandatory = $true)]
		[string]$OutputPath,

		[Parameter(Mandatory = $true)]
		[string]$ResolvedTitle,

		[Parameter(Mandatory = $true)]
		[string]$ClientScriptPath,

		[Parameter(Mandatory = $false)]
		[string]$SourceJsonFileName,

		[Parameter(Mandatory = $false)]
		[string]$AdditionalCss
	)

	if (-not (Test-Path -Path $ClientScriptPath)) {
		throw "Renderer client script not found: $ClientScriptPath"
	}

	$jsonPayload = $Data | ConvertTo-Json -Depth 12 -Compress
	$payloadB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($jsonPayload))
	$titleJson = $ResolvedTitle | ConvertTo-Json -Compress
	$titleHtml = [System.Net.WebUtility]::HtmlEncode($ResolvedTitle)
	$sourceJson = $SourceJsonFileName | ConvertTo-Json -Compress
	$generatedAtJson = (Get-Date).ToString('s') | ConvertTo-Json -Compress
	$sharedClientScript = if (Test-Path -Path $script:AvdSharedClientScriptPath) {
		Get-Content -Path $script:AvdSharedClientScriptPath -Raw -Encoding UTF8
	} else {
		''
	}
	$clientScript = Get-Content -Path $ClientScriptPath -Raw -Encoding UTF8

	$htmlPrefix = Get-AvdDefaultReportShellPrefix
	if (-not [string]::IsNullOrWhiteSpace($AdditionalCss)) {
		$htmlPrefix = $htmlPrefix.Replace('</style>', "$AdditionalCss`r`n	</style>")
	}

	$htmlContent = @(
		$htmlPrefix
		'<script>'
		$sharedClientScript.Trim()
		$clientScript.Trim()
		'</script>'
		'</body>'
		'</html>'
	) -join [Environment]::NewLine

	$htmlContent = $htmlContent.Replace('__REPORT_TITLE__', $titleJson)
	$htmlContent = $htmlContent.Replace('__REPORT_TITLE_HTML__', $titleHtml)
	$htmlContent = $htmlContent.Replace('__SOURCE_JSON__', $sourceJson)
	$htmlContent = $htmlContent.Replace('__GENERATED_AT__', $generatedAtJson)
	$htmlContent = $htmlContent.Replace('__REPORT_PAYLOAD__', ($payloadB64 | ConvertTo-Json -Compress))

	Set-Content -Path $OutputPath -Value $htmlContent -Encoding UTF8
	return $OutputPath
}
