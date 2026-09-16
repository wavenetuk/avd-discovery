Set-StrictMode -Version Latest

$hostBaselineModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Discovery.HostBaseline.psm1'
Import-Module -Name $hostBaselineModulePath -ErrorAction Stop

function Get-DiscoveryFilePrintRoleState {
	param(
		[object[]]$ShareObjects,
		$SmbServerConfiguration,
		$SpoolerService,
		[object[]]$FeatureObjects
	)

	$shareQueryError = $null
	if (-not $PSBoundParameters.ContainsKey('ShareObjects')) {
		try { $ShareObjects = @(Get-SmbShare -ErrorAction Stop) } catch { $shareQueryError = $_.Exception.Message; $ShareObjects = @() }
	}
	if (-not $PSBoundParameters.ContainsKey('SmbServerConfiguration')) {
		try { $SmbServerConfiguration = Get-SmbServerConfiguration -ErrorAction Stop } catch { $SmbServerConfiguration = $null }
	}
	if (-not $PSBoundParameters.ContainsKey('SpoolerService')) { $SpoolerService = Get-Service -Name Spooler -ErrorAction SilentlyContinue }
	if (-not $PSBoundParameters.ContainsKey('FeatureObjects') -and $null -ne (Get-Command -Name Get-WindowsFeature -ErrorAction SilentlyContinue)) {
		try { $FeatureObjects = @(Get-WindowsFeature -ErrorAction Stop) } catch { $FeatureObjects = @() }
	}

	$administrativeNames = @('ADMIN$', 'C$', 'IPC$', 'PRINT$', 'SYSVOL', 'NETLOGON')
	$shares = @($ShareObjects | Where-Object { $_.Name -notin $administrativeNames -and -not $_.Special } | ForEach-Object {
		[PSCustomObject]@{
			Name = ConvertTo-DiscoveryNormalizedText -Value $_.Name
			Path = ConvertTo-DiscoveryNormalizedText -Value $_.Path
			Description = ConvertTo-DiscoveryNormalizedText -Value $_.Description
			ShareState = [string](Get-DiscoveryOptionalPropertyValue -Object $_ -PropertyName 'ShareState')
			ConcurrentUserLimit = Get-DiscoveryOptionalPropertyValue -Object $_ -PropertyName 'ConcurrentUserLimit'
			EncryptData = Get-DiscoveryOptionalPropertyValue -Object $_ -PropertyName 'EncryptData'
		}
	})
	$featureNames = @($FeatureObjects | Where-Object { (Get-DiscoveryOptionalPropertyValue -Object $_ -PropertyName 'Installed') -eq $true -and (Get-DiscoveryOptionalPropertyValue -Object $_ -PropertyName 'Name') -in @('FS-FileServer', 'Print-Server') } | Select-Object -ExpandProperty Name)
	return [PSCustomObject]@{
		FileServerRoleInstalled = 'FS-FileServer' -in $featureNames
		PrintServerRoleInstalled = 'Print-Server' -in $featureNames
		InstalledServerRoles = $featureNames
		ShareCount = $shares.Count
		Shares = $shares
		ShareQueryError = $shareQueryError
		SmbServer = [PSCustomObject]@{
			Enabled = $null -ne $SmbServerConfiguration
			EnableSMB1Protocol = Get-DiscoveryOptionalPropertyValue -Object $SmbServerConfiguration -PropertyName 'EnableSMB1Protocol'
			EnableSMB2Protocol = Get-DiscoveryOptionalPropertyValue -Object $SmbServerConfiguration -PropertyName 'EnableSMB2Protocol'
			EncryptData = Get-DiscoveryOptionalPropertyValue -Object $SmbServerConfiguration -PropertyName 'EncryptData'
			RequireSecuritySignature = Get-DiscoveryOptionalPropertyValue -Object $SmbServerConfiguration -PropertyName 'RequireSecuritySignature'
			EnableSecuritySignature = Get-DiscoveryOptionalPropertyValue -Object $SmbServerConfiguration -PropertyName 'EnableSecuritySignature'
		}
		PrintSpooler = [PSCustomObject]@{
			Installed = $null -ne $SpoolerService
			Status = if ($null -eq $SpoolerService) { 'NotInstalled' } else { [string]$SpoolerService.Status }
			StartType = if ($null -eq $SpoolerService) { $null } else { [string](Get-DiscoveryOptionalPropertyValue -Object $SpoolerService -PropertyName 'StartType') }
		}
	}
}

Export-ModuleMember -Function 'Get-DiscoveryFilePrintRoleState'