function Invoke-AzureSessionHostAuditReportRenderer {
	param(
		[Parameter(Mandatory = $true)]
		$Data,

		[Parameter(Mandatory = $true)]
		[string]$OutputPath,

		[Parameter(Mandatory = $false)]
		[string]$SourceJsonFileName
	)

	$resolvedTitle = if ($Data.Machine -and -not [string]::IsNullOrWhiteSpace($Data.Machine.Hostname)) {
		"AVD Host Audit Report - $($Data.Machine.Hostname)"
	}
	else {
		'AVD Host Audit Report'
	}

	$clientScriptPath = Join-Path $PSScriptRoot 'JsonReportRenderer.AzureSessionHostAudit.Client.js'
	$additionalCss = @'
		.card.join-type .metric {
			font-size: clamp(24px, 2.5vw, 32px);
			white-space: normal;
			overflow-wrap: break-word;
			word-break: normal;
		}
'@

	Invoke-AvdDefaultHtmlReportRenderer `
		-Data $Data `
		-OutputPath $OutputPath `
		-ResolvedTitle $resolvedTitle `
		-ClientScriptPath $clientScriptPath `
		-SourceJsonFileName $SourceJsonFileName `
		-AdditionalCss $additionalCss
}

Register-AvdReportRenderer -ReportType 'AzureSessionHostAudit' -RenderScript (Get-Command Invoke-AzureSessionHostAuditReportRenderer -CommandType Function).ScriptBlock -ModuleName 'AzureSessionHostAudit'
