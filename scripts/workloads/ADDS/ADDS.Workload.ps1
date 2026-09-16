Register-DiscoveryWorkload `
	-Name 'ADDS' `
	-DisplayName 'Active Directory Domain Services' `
	-CollectionMode 'Host' `
	-HostEntryScript (Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-ADDSHostDiscovery.ps1') `
	-Capabilities @('HostDiscovery', 'ActiveDirectoryDependencies', 'DomainControllerDiscovery', 'HtmlReport') `
	-RequiredModules @()