Set-StrictMode -Version Latest

function Connect-RequestedAzAccount {
	param(
		[Parameter(Mandatory = $false)]
		$CurrentContext,

		[Parameter(Mandatory = $false)]
		[string]$SignInMessage = 'Sign in to the Azure account to use for this collection.',

		[Parameter(Mandatory = $false)]
		[switch]$PromptForAccountId,

		[Parameter(Mandatory = $false)]
		[switch]$ShowSignInWindowHint
	)

	Write-Host ''
	if ($CurrentContext -and $CurrentContext.Account -and -not [string]::IsNullOrWhiteSpace([string]$CurrentContext.Account.Id)) {
		Write-Host "  Current Azure context: $($CurrentContext.Account.Id)" -ForegroundColor DarkGray
	}
	Write-Host "  $SignInMessage" -ForegroundColor Cyan
	if ($ShowSignInWindowHint.IsPresent) {
		Write-Host '  Use the Azure sign-in window that opens next.' -ForegroundColor DarkGray
	}

	$accountId = $null
	if ($PromptForAccountId.IsPresent) {
		$accountId = (Read-Host '  Azure account UPN/email (press Enter for the standard Azure sign-in prompt)').Trim()
	}
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

function New-DiscoveryArmCallTracker {
	return [PSCustomObject]@{
		Read  = 0
		Write = 0
	}
}

function Invoke-DiscoveryArmRequest {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$Path,

		[Parameter(Mandatory = $false)]
		[string]$Method = 'GET',

		[Parameter(Mandatory = $false)]
		[string]$Payload,

		[Parameter(Mandatory = $false)]
		$CallTracker
	)

	if ($null -ne $CallTracker) {
		if ($Method.ToUpperInvariant() -in 'PUT', 'POST', 'DELETE', 'PATCH') {
			$CallTracker.Write++
		}
		else {
			$CallTracker.Read++
		}
	}

	$callParams = @{ Path = $Path; Method = $Method; ErrorAction = $ErrorActionPreference }
	if ($PSBoundParameters.ContainsKey('Payload')) {
		$callParams['Payload'] = $Payload
	}

	Invoke-AzRestMethod @callParams
}

function Assert-DiscoveryCommandPolicy {
	param(
		[Parameter(Mandatory = $true)]
		[string]$ScriptPath,

		[Parameter(Mandatory = $false)]
		[string[]]$AllowedAzCmdlets = @(),

		[Parameter(Mandatory = $false)]
		[string[]]$DeniedCmdlets = @()
	)

	$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile(
		$ScriptPath,
		[ref]$null,
		[ref]$null
	)
	$commandNodes = $scriptAst.FindAll(
		{ param($node) $node -is [System.Management.Automation.Language.CommandAst] },
		$true
	)

	$violations = foreach ($node in $commandNodes) {
		$name = $node.GetCommandName()
		if (-not $name) {
			continue
		}

		if ($name -in $DeniedCmdlets) {
			$name
		}
		elseif ($AllowedAzCmdlets.Count -gt 0 -and $name -match '-Az' -and $name -notin $AllowedAzCmdlets) {
			$name
		}
	}

	if ($violations) {
		throw "Read-only assertion failed. The following command(s) must be reviewed before this script can run: $(($violations | Sort-Object -Unique) -join ', ')"
	}
}

function Assert-DiscoveryHostCollectorReadOnly {
	param(
		[Parameter(Mandatory = $true)]
		[string]$ScriptPath
	)

	$deniedCmdlets = @(
		'Set-ItemProperty', 'Remove-ItemProperty', 'Clear-ItemProperty', 'Set-Item',
		'New-ItemProperty', 'Rename-Item', 'Copy-Item', 'Move-Item', 'Remove-Item',
		'Invoke-Expression', 'Set-Service', 'Stop-Service', 'Start-Service',
		'Restart-Service', 'Suspend-Service', 'Resume-Service', 'Set-ExecutionPolicy',
		'Register-ScheduledTask', 'Unregister-ScheduledTask', 'Start-Process',
		'Restart-Computer', 'Stop-Computer', 'Add-WindowsFeature', 'Install-WindowsFeature',
		'Uninstall-WindowsFeature', 'Enable-WindowsOptionalFeature', 'Disable-WindowsOptionalFeature'
	)

	Assert-DiscoveryCommandPolicy -ScriptPath $ScriptPath -DeniedCmdlets $deniedCmdlets
}

function Resolve-DiscoveryConfigPath {
	param(
		[Parameter(Mandatory = $true)]
		[string]$ScriptRoot,

		[Parameter(Mandatory = $true)]
		[string]$FileName
	)

	$candidates = @(
		(Join-Path -Path $ScriptRoot -ChildPath $FileName),
		(Join-Path -Path (Split-Path -Path $ScriptRoot -Parent) -ChildPath "config\$FileName"),
		(Join-Path -Path (Split-Path -Path (Split-Path -Path (Split-Path -Path $ScriptRoot -Parent) -Parent) -Parent) -ChildPath "config\$FileName")
	)

	foreach ($path in $candidates) {
		if (Test-Path -Path $path) {
			return $path
		}
	}

	return $candidates[0]
}

function Read-DiscoveryJsonConfig {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Path
	)

	if (-not (Test-Path -Path $Path)) {
		return $null
	}

	try {
		return (Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
	}
	catch {
		throw "Could not read JSON configuration '$Path': $($_.Exception.Message)"
	}
}

function New-DiscoveryCollectionMetadata {
	param(
		[Parameter(Mandatory = $true)]
		[ValidatePattern('^[A-Za-z][A-Za-z0-9]*$')]
		[string]$Workload,

		[Parameter(Mandatory = $true)]
		[ValidateSet('Cloud', 'Host')]
		[string]$ScannerMode,

		[Parameter(Mandatory = $false)]
		[ValidateSet('Completed', 'CompletedWithWarnings', 'Failed')]
		[string]$Status = 'Completed',

		[Parameter(Mandatory = $false)]
		[string[]]$Capabilities = @(),

		[Parameter(Mandatory = $false)]
		[string[]]$Warnings = @(),

		[Parameter(Mandatory = $false)]
		[string[]]$Errors = @()
	)

	return [PSCustomObject]@{
		SchemaVersion = '1.0'
		Workload      = $Workload
		ScannerMode   = $ScannerMode
		Status        = $Status
		Capabilities  = @($Capabilities)
		Warnings      = @($Warnings)
		Errors        = @($Errors)
	}
}

function Test-DiscoveryReportContract {
	param(
		[Parameter(Mandatory = $true)]
		$Data,

		[Parameter(Mandatory = $false)]
		[switch]$RequireCollectionMetadata
	)

	$violations = [System.Collections.Generic.List[string]]::new()
	foreach ($propertyName in @('ReportType', 'CustomerAbbreviation', 'CollectedAt')) {
		$property = $Data.PSObject.Properties[$propertyName]
		if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
			$violations.Add("Required report property '$propertyName' is missing or empty.")
		}
	}

	$collection = $Data.PSObject.Properties['Collection']
	if ($null -eq $collection) {
		if ($RequireCollectionMetadata.IsPresent) {
			$violations.Add("Required report property 'Collection' is missing.")
		}
		return $violations.ToArray()
	}

	foreach ($propertyName in @('SchemaVersion', 'Workload', 'ScannerMode', 'Status')) {
		$property = $collection.Value.PSObject.Properties[$propertyName]
		if ($null -eq $property -or $null -eq $property.Value -or ([string]$property.Value).Length -eq 0) {
			$violations.Add("Collection property '$propertyName' is missing or empty.")
		}
	}
	foreach ($propertyName in @('Capabilities', 'Warnings', 'Errors')) {
		$property = $collection.Value.PSObject.Properties[$propertyName]
		if ($null -eq $property -or $null -eq $property.Value) {
			$violations.Add("Collection property '$propertyName' is missing.")
		}
	}

	return $violations.ToArray()
}

function Resolve-ReportGeneratorScriptPath {
	param(
		[Parameter(Mandatory = $true)]
		[string]$ScriptRoot
	)

	$candidatePaths = @(
		(Join-Path -Path $ScriptRoot -ChildPath 'Invoke-HtmlReportGenerator.ps1'),
		(Join-Path -Path $ScriptRoot -ChildPath '..\..\reporting\Invoke-HtmlReportGenerator.ps1')
	)
	foreach ($candidatePath in $candidatePaths) {
		if (Test-Path -Path $candidatePath) { return $candidatePath }
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
		[string]$OutputPath,

		[Parameter(Mandatory = $true)]
		[string]$ScriptRoot
	)

	$generatorPath = Resolve-ReportGeneratorScriptPath -ScriptRoot $ScriptRoot
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

Export-ModuleMember -Function @(
	'Connect-RequestedAzAccount',
	'New-DiscoveryArmCallTracker',
	'Invoke-DiscoveryArmRequest',
	'Assert-DiscoveryCommandPolicy',
	'Assert-DiscoveryHostCollectorReadOnly',
	'Resolve-DiscoveryConfigPath',
	'Read-DiscoveryJsonConfig',
	'New-DiscoveryCollectionMetadata',
	'Test-DiscoveryReportContract',
	'Resolve-ReportGeneratorScriptPath',
	'Invoke-OptionalHtmlReportGeneration'
)