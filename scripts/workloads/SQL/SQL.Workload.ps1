Register-DiscoveryWorkload `
	-Name 'SQL' `
	-DisplayName 'Microsoft SQL Server' `
	-CollectionMode 'Host' `
	-HostEntryScript (Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-SqlHostDiscovery.ps1') `
	-Capabilities @('HostDiscovery', 'SqlInstanceDiscovery', 'HtmlReport') `
	-RequiredModules @()