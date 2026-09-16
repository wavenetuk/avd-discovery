function Invoke-HostDiscoveryHtmlReportRenderer {
	param(
		[Parameter(Mandatory = $true)]$Data,
		[Parameter(Mandatory = $true)][string]$OutputPath,
		[string]$SourceJsonFileName
	)

	$customerCode = if ([string]::IsNullOrWhiteSpace($Data.CustomerAbbreviation)) { $null } else { $Data.CustomerAbbreviation.ToString().Trim().ToUpperInvariant() }
	$workloadName = if ($Data.Collection -and -not [string]::IsNullOrWhiteSpace($Data.Collection.Workload)) { [string]$Data.Collection.Workload } else { 'Host Discovery' }
	$resolvedTitle = if ($null -eq $customerCode) { "$workloadName Host Discovery" } else { "$workloadName Host Discovery - $customerCode" }

	Invoke-DiscoveryDefaultHtmlReportRenderer -Data $Data -OutputPath $OutputPath -ResolvedTitle $resolvedTitle -ClientScriptPath (Join-Path $PSScriptRoot 'JsonReportRenderer.AzureSessionHostAudit.Client.js') -SourceJsonFileName $SourceJsonFileName
}

foreach ($reportType in @('ADDSHostDiscovery', 'FilePrintHostDiscovery', 'SQLHostDiscovery', 'RDSHostDiscovery')) {
	Register-DiscoveryReportRenderer -ReportType $reportType -RenderScript (Get-Command Invoke-HostDiscoveryHtmlReportRenderer -CommandType Function).ScriptBlock -ModuleName 'HostDiscovery'
}