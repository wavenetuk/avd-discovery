Set-StrictMode -Version Latest

$hostBaselineModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Discovery.HostBaseline.psm1'
Import-Module -Name $hostBaselineModulePath -ErrorAction Stop

function Get-DiscoverySqlInstanceState {
	param([object[]]$InstanceEntries, [object[]]$ServiceObjects, [hashtable]$InstanceDetails)
	if (-not $PSBoundParameters.ContainsKey('InstanceEntries')) {
		$instanceRoot = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
		if (Test-Path -Path $instanceRoot) {
			$instanceRegistryValues = Get-ItemProperty -Path $instanceRoot -ErrorAction Stop
			$InstanceEntries = @($instanceRegistryValues.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; InstanceId = [string]$_.Value } })
		}
		else { $InstanceEntries = @() }
	}
	if (-not $PSBoundParameters.ContainsKey('ServiceObjects')) { try { $ServiceObjects = @(Get-CimInstance -ClassName Win32_Service -Property Name,DisplayName,State,StartMode,StartName -ErrorAction Stop | Where-Object { $_.Name -like 'MSSQL*' -or $_.Name -like 'SQLAgent*' -or $_.Name -like 'SQLBrowser' -or $_.Name -like 'SQLWriter' }) } catch { $ServiceObjects = @() } }
	if (-not $PSBoundParameters.ContainsKey('InstanceDetails')) {
		$InstanceDetails = @{}
		foreach ($entry in $InstanceEntries) {
			$basePath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$($entry.InstanceId)"
			$setup = Get-DiscoveryRegistryKeyValues -Path (Join-Path $basePath 'Setup')
			$version = Get-DiscoveryRegistryKeyValues -Path (Join-Path $basePath 'MSSQLServer\CurrentVersion')
			$tcp = Get-DiscoveryRegistryKeyValues -Path (Join-Path $basePath 'MSSQLServer\SuperSocketNetLib\Tcp\IPAll')
			$InstanceDetails[$entry.Name] = [PSCustomObject]@{ Setup = $setup; Version = $version; Tcp = $tcp }
		}
	}
	$instances = @($InstanceEntries | ForEach-Object {
		$instanceName = [string]$_.Name; $detail = $InstanceDetails[$instanceName]
		$serviceName = if ($instanceName -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { "MSSQL`$$instanceName" }
		$service = @($ServiceObjects | Where-Object { $_.Name -eq $serviceName } | Select-Object -First 1)[0]
		[PSCustomObject]@{
			InstanceName = $instanceName
			InstanceId = [string]$_.InstanceId
			ServiceName = $serviceName
			ServiceStatus = if ($null -eq $service) { 'NotFound' } else { [string]$service.State }
			ServiceStartType = if ($null -eq $service) { $null } else { [string]$service.StartMode }
			ServiceAccount = if ($null -eq $service) { $null } else { ConvertTo-DiscoveryNormalizedText -Value $service.StartName }
			Version = ConvertTo-DiscoveryNormalizedText -Value (Get-DiscoveryOptionalPropertyValue -Object (Get-DiscoveryOptionalPropertyValue -Object $detail -PropertyName 'Version') -PropertyName 'CurrentVersion')
			Edition = ConvertTo-DiscoveryNormalizedText -Value (Get-DiscoveryOptionalPropertyValue -Object (Get-DiscoveryOptionalPropertyValue -Object $detail -PropertyName 'Setup') -PropertyName 'Edition')
			InstallPath = ConvertTo-DiscoveryNormalizedText -Value (Get-DiscoveryOptionalPropertyValue -Object (Get-DiscoveryOptionalPropertyValue -Object $detail -PropertyName 'Setup') -PropertyName 'SQLPath')
			TcpPort = ConvertTo-DiscoveryNormalizedText -Value (Get-DiscoveryOptionalPropertyValue -Object (Get-DiscoveryOptionalPropertyValue -Object $detail -PropertyName 'Tcp') -PropertyName 'TcpPort')
			TcpDynamicPorts = ConvertTo-DiscoveryNormalizedText -Value (Get-DiscoveryOptionalPropertyValue -Object (Get-DiscoveryOptionalPropertyValue -Object $detail -PropertyName 'Tcp') -PropertyName 'TcpDynamicPorts')
		}
	})
	$services = @($ServiceObjects | ForEach-Object { [PSCustomObject]@{ Name = [string]$_.Name; DisplayName = ConvertTo-DiscoveryNormalizedText -Value $_.DisplayName; Status = [string]$_.State; StartType = [string]$_.StartMode; Account = ConvertTo-DiscoveryNormalizedText -Value $_.StartName } })
	return [PSCustomObject]@{ SqlServerDetected = $instances.Count -gt 0 -or $services.Count -gt 0; InstanceCount = $instances.Count; Instances = $instances; ServiceCount = $services.Count; Services = $services; DatabaseInventory = [PSCustomObject]@{ Status = 'NotCollected'; Message = 'Database inventory requires an explicit SQL connection and is not collected by the host scan.' } }
}

Export-ModuleMember -Function 'Get-DiscoverySqlInstanceState'