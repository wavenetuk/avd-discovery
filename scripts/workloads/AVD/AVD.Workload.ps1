Register-DiscoveryWorkload `
	-Name 'Avd' `
	-DisplayName 'Azure Virtual Desktop' `
	-CollectionMode 'Both' `
	-CloudEntryScript (Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-AvdMetricsCollection.ps1') `
	-HostEntryScript (Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-AvdSessionHostAudit.ps1') `
	-Capabilities @('ManagementPlane', 'HostDiscovery', 'UsageMetrics', 'HtmlReport') `
	-RequiredModules @('Az.Accounts', 'Az.DesktopVirtualization')