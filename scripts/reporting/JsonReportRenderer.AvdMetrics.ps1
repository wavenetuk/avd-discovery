function Invoke-AvdMetricsHtmlReportRenderer {
	param(
		[Parameter(Mandatory = $true)]
		$Data,

		[Parameter(Mandatory = $true)]
		[string]$OutputPath,

		[Parameter(Mandatory = $false)]
		[string]$SourceJsonFileName
	)

	$customerCode = if ([string]::IsNullOrWhiteSpace($Data.CustomerAbbreviation)) {
		$null
	} else {
		$Data.CustomerAbbreviation.ToString().Trim().ToUpperInvariant()
	}
	$resolvedTitle = if ([string]::IsNullOrWhiteSpace($customerCode)) { 'AVD Metrics Report' } else { "AVD Metrics Report - $customerCode" }
	$clientScriptPath = Join-Path $PSScriptRoot 'JsonReportRenderer.AvdMetrics.Client.js'

	Invoke-AvdDefaultHtmlReportRenderer `
		-Data $Data `
		-OutputPath $OutputPath `
		-ResolvedTitle $resolvedTitle `
		-ClientScriptPath $clientScriptPath `
		-SourceJsonFileName $SourceJsonFileName
}

Register-AvdReportRenderer -ReportType 'AvdMetrics' -RenderScript (Get-Command Invoke-AvdMetricsHtmlReportRenderer -CommandType Function).ScriptBlock -ModuleName 'AvdMetrics'
