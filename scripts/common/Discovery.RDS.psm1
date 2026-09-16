Set-StrictMode -Version Latest

$hostBaselineModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Discovery.HostBaseline.psm1'
Import-Module -Name $hostBaselineModulePath -ErrorAction Stop

function Get-DiscoveryRdsRoleState {
	param([object[]]$FeatureObjects, [object[]]$ServiceObjects, [string]$ConnectionBroker, $Topology)
	if (-not $PSBoundParameters.ContainsKey('FeatureObjects') -and $null -ne (Get-Command -Name Get-WindowsFeature -ErrorAction SilentlyContinue)) { try { $FeatureObjects = @(Get-WindowsFeature -ErrorAction Stop) } catch { $FeatureObjects = @() } }
	if (-not $PSBoundParameters.ContainsKey('ServiceObjects')) { try { $ServiceObjects = @(Get-CimInstance -ClassName Win32_Service -Property Name,DisplayName,State,StartMode,StartName -ErrorAction Stop | Where-Object { $_.Name -in @('TermService', 'SessionEnv', 'Tssdis', 'RDMS', 'TSGateway', 'TermServLicensing') }) } catch { $ServiceObjects = @() } }
	$knownRoles = @('RDS-RD-Server', 'RDS-Connection-Broker', 'RDS-Web-Access', 'RDS-Gateway', 'RDS-Licensing', 'RDS-Virtualization')
	$installedRoles = @($FeatureObjects | Where-Object { (Get-DiscoveryOptionalPropertyValue -Object $_ -PropertyName 'Installed') -eq $true -and (Get-DiscoveryOptionalPropertyValue -Object $_ -PropertyName 'Name') -in $knownRoles } | ForEach-Object { [PSCustomObject]@{ Name = [string](Get-DiscoveryOptionalPropertyValue -Object $_ -PropertyName 'Name'); DisplayName = ConvertTo-DiscoveryNormalizedText -Value (Get-DiscoveryOptionalPropertyValue -Object $_ -PropertyName 'DisplayName') } })
	$services = @($ServiceObjects | ForEach-Object { [PSCustomObject]@{ Name = [string]$_.Name; DisplayName = ConvertTo-DiscoveryNormalizedText -Value $_.DisplayName; Status = [string]$_.State; StartType = [string]$_.StartMode; Account = ConvertTo-DiscoveryNormalizedText -Value $_.StartName } })
	if (-not $PSBoundParameters.ContainsKey('Topology')) {
		$brokerRoleInstalled = @($installedRoles | Where-Object Name -eq 'RDS-Connection-Broker').Count -gt 0
		if ([string]::IsNullOrWhiteSpace($ConnectionBroker) -and $brokerRoleInstalled) { $ConnectionBroker = $env:COMPUTERNAME }
		if ([string]::IsNullOrWhiteSpace($ConnectionBroker)) { $Topology = [PSCustomObject]@{ Status = 'Skipped'; Message = 'Specify -ConnectionBroker to collect RDS deployment topology.' } }
		elseif ($null -eq (Get-Module -ListAvailable -Name RemoteDesktop -ErrorAction SilentlyContinue)) { $Topology = [PSCustomObject]@{ Status = 'Unavailable'; Message = 'The RemoteDesktop PowerShell module is not installed.' } }
		else {
			try {
				Import-Module RemoteDesktop -ErrorAction Stop
				$collections = @(Get-RDSessionCollection -ConnectionBroker $ConnectionBroker -ErrorAction Stop)
				$Topology = [PSCustomObject]@{ Status = 'Collected'; ConnectionBroker = $ConnectionBroker; Servers = @(Get-RDServer -ConnectionBroker $ConnectionBroker -ErrorAction Stop | ForEach-Object { [PSCustomObject]@{ Server = [string]$_.Server; Roles = @($_.Roles) } }); Collections = @($collections | ForEach-Object { [PSCustomObject]@{ CollectionName = [string]$_.CollectionName; CollectionType = [string]$_.CollectionType; SessionHosts = @(Get-RDSessionHost -ConnectionBroker $ConnectionBroker -CollectionName $_.CollectionName -ErrorAction Stop | ForEach-Object { [PSCustomObject]@{ SessionHost = [string]$_.SessionHost; NewConnectionAllowed = [string]$_.NewConnectionAllowed } }); RemoteApps = @(Get-RDRemoteApp -ConnectionBroker $ConnectionBroker -CollectionName $_.CollectionName -ErrorAction SilentlyContinue | ForEach-Object { [PSCustomObject]@{ DisplayName = [string]$_.DisplayName; Alias = [string]$_.Alias; FilePath = [string]$_.FilePath } }) } }); Licensing = @(Get-RDLicenseConfiguration -ConnectionBroker $ConnectionBroker -ErrorAction SilentlyContinue | ForEach-Object { [PSCustomObject]@{ Mode = [string]$_.Mode; LicenseServer = @($_.LicenseServer) } }) }
			}
			catch { $Topology = [PSCustomObject]@{ Status = 'Failed'; ConnectionBroker = $ConnectionBroker; Message = $_.Exception.Message } }
		}
	}
	return [PSCustomObject]@{ RdsRoleDetected = $installedRoles.Count -gt 0 -or $services.Count -gt 0; InstalledRoleCount = $installedRoles.Count; InstalledRoles = $installedRoles; ServiceCount = $services.Count; Services = $services; DeploymentInventory = $Topology }
}

Export-ModuleMember -Function 'Get-DiscoveryRdsRoleState'