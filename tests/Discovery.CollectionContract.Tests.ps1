$commonModulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\scripts\common\Discovery.Common.psm1'
$fixtureDirectory = Join-Path -Path $PSScriptRoot -ChildPath 'fixtures'

Import-Module -Name $commonModulePath -Force -ErrorAction Stop

Describe 'Discovery collection report contract' {
	It 'validates the AVD cloud collection fixture' {
		$fixturePath = Join-Path -Path $fixtureDirectory -ChildPath 'avd-metrics.contract.json'
		$payload = Get-Content -Path $fixturePath -Raw -Encoding UTF8 | ConvertFrom-Json

		@(Test-DiscoveryReportContract -Data $payload -RequireCollectionMetadata).Count | Should Be 0
		$payload.Collection.ScannerMode | Should Be 'Cloud'
	}

	It 'validates the AVD host collection fixture' {
		$fixturePath = Join-Path -Path $fixtureDirectory -ChildPath 'avd-host-audit.contract.json'
		$payload = Get-Content -Path $fixturePath -Raw -Encoding UTF8 | ConvertFrom-Json

		@(Test-DiscoveryReportContract -Data $payload -RequireCollectionMetadata).Count | Should Be 0
		$payload.Collection.ScannerMode | Should Be 'Host'
	}

	It 'accepts a legacy report without collection metadata' {
		$payload = [PSCustomObject]@{
			ReportType           = 'AvdMetrics'
			CustomerAbbreviation = 'contoso'
			CollectedAt          = '2026-09-15T12:00:00'
		}

		@(Test-DiscoveryReportContract -Data $payload).Count | Should Be 0
		@(Test-DiscoveryReportContract -Data $payload -RequireCollectionMetadata).Count | Should Be 1
	}
}