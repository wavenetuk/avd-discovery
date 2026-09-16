Register-DiscoveryWorkload `
	-Name 'RDS' `
	-DisplayName 'Remote Desktop Services' `
	-CollectionMode 'Host' `
	-HostEntryScript (Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-RdsHostDiscovery.ps1') `
	-Capabilities @('HostDiscovery', 'RdsRoleDiscovery', 'BrokerTopology', 'HtmlReport') `
	-RequiredModules @()