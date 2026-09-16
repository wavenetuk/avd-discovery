Register-DiscoveryWorkload `
	-Name 'ADDS' `
	-DisplayName 'Active Directory Domain Services' `
	-CollectionMode 'Host' `
	-HostEntryScript (Join-Path -Path $PSScriptRoot -ChildPath 'ADDS\Invoke-ADDSHostDiscovery.ps1') `
	-Capabilities @('HostDiscovery', 'ActiveDirectoryDependencies', 'HtmlReport') `
	-RequiredModules @()