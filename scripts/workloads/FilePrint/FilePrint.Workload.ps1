Register-DiscoveryWorkload `
	-Name 'FilePrint' `
	-DisplayName 'File and Print Services' `
	-CollectionMode 'Host' `
	-HostEntryScript (Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-FilePrintHostDiscovery.ps1') `
	-Capabilities @('HostDiscovery', 'FileServices', 'PrintServices', 'HtmlReport') `
	-RequiredModules @()