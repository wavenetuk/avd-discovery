Set-StrictMode -Version Latest

$script:DiscoveryWorkloads = @{}

function Register-DiscoveryWorkload {
	param(
		[Parameter(Mandatory = $true)]
		[ValidatePattern('^[A-Za-z][A-Za-z0-9]*$')]
		[string]$Name,

		[Parameter(Mandatory = $true)]
		[string]$DisplayName,

		[Parameter(Mandatory = $true)]
		[ValidateSet('Cloud', 'Host', 'Both')]
		[string]$CollectionMode,

		[Parameter(Mandatory = $false)]
		[string]$CloudEntryScript,

		[Parameter(Mandatory = $false)]
		[string]$HostEntryScript,

		[Parameter(Mandatory = $false)]
		[string[]]$Capabilities = @(),

		[Parameter(Mandatory = $false)]
		[string[]]$RequiredModules = @()
	)

	if ($CollectionMode -in 'Cloud', 'Both' -and [string]::IsNullOrWhiteSpace($CloudEntryScript)) {
		throw "Workload '$Name' requires a cloud entry script."
	}
	if ($CollectionMode -in 'Host', 'Both' -and [string]::IsNullOrWhiteSpace($HostEntryScript)) {
		throw "Workload '$Name' requires a host entry script."
	}
	if ($script:DiscoveryWorkloads.ContainsKey($Name)) {
		throw "A workload named '$Name' is already registered."
	}

	$script:DiscoveryWorkloads[$Name] = [PSCustomObject]@{
		Name            = $Name
		DisplayName     = $DisplayName
		CollectionMode  = $CollectionMode
		CloudEntryScript = $CloudEntryScript
		HostEntryScript  = $HostEntryScript
		Capabilities    = @($Capabilities)
		RequiredModules = @($RequiredModules)
	}
}

function Import-DiscoveryWorkloadDefinitions {
	param(
		[Parameter(Mandatory = $true)]
		[string]$DefinitionDirectory
	)

	if (-not (Test-Path -Path $DefinitionDirectory -PathType Container)) {
		throw "Workload definition directory not found: $DefinitionDirectory"
	}

	Get-ChildItem -Path $DefinitionDirectory -Filter '*.Workload.ps1' -File -Recurse |
		Sort-Object -Property Name |
		ForEach-Object {
			. $_.FullName
		}
}

function Get-DiscoveryWorkload {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Name
	)

	return $script:DiscoveryWorkloads[$Name]
}

function Get-DiscoveryWorkloads {
	return @($script:DiscoveryWorkloads.Values | Sort-Object -Property Name)
}

function Test-DiscoveryWorkloads {
	$errors = [System.Collections.Generic.List[string]]::new()
	foreach ($workload in Get-DiscoveryWorkloads) {
		foreach ($entryPoint in @($workload.CloudEntryScript, $workload.HostEntryScript)) {
			if (-not [string]::IsNullOrWhiteSpace($entryPoint) -and -not (Test-Path -Path $entryPoint -PathType Leaf)) {
				$errors.Add("Workload '$($workload.Name)' entry script was not found: $entryPoint")
			}
		}
	}

	return $errors.ToArray()
}

Export-ModuleMember -Function @(
	'Register-DiscoveryWorkload',
	'Import-DiscoveryWorkloadDefinitions',
	'Get-DiscoveryWorkload',
	'Get-DiscoveryWorkloads',
	'Test-DiscoveryWorkloads'
)