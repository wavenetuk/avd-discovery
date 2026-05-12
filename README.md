# AVD Discovery Toolset

A pair of PowerShell scripts for assessing Azure Virtual Desktop environments during migration and optimisation engagements. Together they collect infrastructure detail, usage metrics, performance data, licence assignments, and on-host configuration from AVD host pools — all read-only, with no Azure resources modified.

---

## Scripts at a Glance

| Script | Where It Runs | Output |
|---|---|---|
| `AzureManagementPlane.ps1` | Your local machine | `avd-metrics/<customer>-avd-metrics-<timestamp>.json` |
| `LocalScript.ps1` | On an AVD session host | `vm-discovery/<customer>-<hostname>-avd-discovery-<timestamp>.json` |

`AzureManagementPlane.ps1` can optionally invoke `LocalScript.ps1` automatically on a running session host via Azure VM Run Command (`-RunLocalDiscovery`), eliminating the need to run it separately.

---

## AzureManagementPlane.ps1

Enumerates all AVD host pools across one or more Azure subscriptions and collects management-plane metrics and infrastructure detail for each pool.

### What It Collects

#### Infrastructure
- Host pool type (Pooled / Personal), load-balancer type, max session limit
- Number of registered session hosts and VM SKU(s)
- Domain join type (Active Directory / Azure AD / Hybrid) and domain name
- VM extensions installed on session hosts
- OS image type — marketplace, custom image, or Shared Image Gallery (gallery name, definition, and version)
- OS disk size (GB) and storage SKU
- VNet, subnet, address prefixes, custom DNS servers, NSG, and UDR names
- Scaling plan name and schedule count (if configured)

#### Reservations
- Whether any Azure Reserved VM Instances match the pool's VM SKU and region
- Matched reservation details (name, scope, term, quantity, expiry)

#### Backup
- Whether Azure Backup is configured for session host VMs (Personal pools only)

#### Access & Authorisation
- App group and workspace names
- Role assignments on the app group — Entra ID groups (with display name) and direct user assignments (with UPN)
- Authorised user count resolved transitively through Entra ID group membership via Microsoft Graph

#### Usage Metrics (requires Log Analytics diagnostic settings)
- **Daily Average Users**: mean unique users per day connecting to the pool
- **Peak Concurrent Sessions**: highest number of simultaneous sessions in the period, with per-day breakdown

#### Performance Metrics (Azure Monitor platform metrics, no agent required)
- **CPU**: average, P95, and P99 percentage CPU across all session host VMs
- **Memory**: average, P95, and P99 memory used percentage (derived from Available Memory Bytes and VM SKU total RAM)

#### Diagnostic Insights (requires WVD log categories in Log Analytics)
- **Error summary**: top 20 error types from `WVDErrors` (source, message, count); Shortpath-related errors flagged separately
- **Failed connections**: count of `Connected` sessions with no matching `Completed` event
- **Transport type breakdown**: connection counts split by Shortpath / TURN / Websocket
- **Shortpath upgrade events**: count of checkpoint events indicating UDP transport negotiation
- **Host registration events**: per-host registration counts from `WVDHostRegistrations` (high counts may indicate agent churn)

#### Licence Assignments (Microsoft Graph)
- Assigned Microsoft 365 / Entra licence SKUs filtered to AVD-relevant products: Windows 365, Microsoft 365 / Office 365 suites, Visio, Project, Power BI, Intune / EMS, Defender, and AVD Store add-ons
- Users holding AVD-eligible role assignments but with no qualifying licence (unlicensed user list with UPN)
- Can be skipped entirely with `-SkipLicenceCheck`

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-CustomerAbbreviation` | string | *(prompted)* | Short code used in the output filename |
| `-SubscriptionId` | string[] | *(all accessible)* | Limit collection to specific subscription(s) |
| `-HostPoolName` | string[] | *(all)* | Limit collection to specific host pool name(s) |
| `-LookbackDays` | int | `30` | Metric collection window in days (max 90) |
| `-ExcludeWeekends` | switch | off | Omit Saturday and Sunday data points from all averages |
| `-PeakHoursOnly` | switch | off | Restrict metric averages to 09:00–18:00 local time only |
| `-UtcOffsetHours` | int | `0` | UTC offset for peak hours window (e.g. `1` for BST) |
| `-OutputDirectory` | string | script folder | Directory for the JSON export |
| `-RunLocalDiscovery` | switch | off | Execute `LocalScript.ps1` on a running VM in each pool via Azure VM Run Command (downloads from GitHub) |
| `-GitHubBranch` | string | `main` | GitHub branch to download `LocalScript.ps1` and `appExclusions.config.json` from when using `-RunLocalDiscovery` |
| `-SkipLicenceCheck` | switch | off | Skip Microsoft Graph licence collection |

### Prerequisites

- PowerShell 5.1 or 7+
- `Az.Accounts` and `Az.DesktopVirtualization` modules installed
- Authenticated via `Connect-AzAccount`
- **For usage metrics**: Diagnostic Settings on each host pool forwarding `Connection`, `Error`, `Checkpoint`, and `HostRegistration` log categories to a Log Analytics workspace
- **For licence data**: the authenticated account requires Microsoft Graph `User.Read.All` and `Group.Read.All` (or equivalent)
- **For `-RunLocalDiscovery`**: session host VMs must have outbound HTTPS access to `raw.githubusercontent.com` so they can download the scripts at runtime

### Usage Examples

```powershell
# Interactive — prompts for customer abbreviation, queries all subscriptions
.\AzureManagementPlane.ps1

# Specific subscription, 14-day window, exclude weekends
.\AzureManagementPlane.ps1 -CustomerAbbreviation contoso -SubscriptionId '00000000-0000-0000-0000-000000000000' -LookbackDays 14 -ExcludeWeekends

# Peak hours only (09:00–18:00 BST), weekdays only
.\AzureManagementPlane.ps1 -CustomerAbbreviation contoso -PeakHoursOnly -ExcludeWeekends -UtcOffsetHours 1

# Single host pool, skip licence check
.\AzureManagementPlane.ps1 -CustomerAbbreviation contoso -HostPoolName hp-prod-avd-01 -SkipLicenceCheck

# Run LocalScript.ps1 automatically — fetches latest from GitHub main branch
.\.AzureManagementPlane.ps1 -CustomerAbbreviation contoso -RunLocalDiscovery

# Run LocalScript.ps1 from a specific branch (e.g. for testing)
.\.AzureManagementPlane.ps1 -CustomerAbbreviation contoso -RunLocalDiscovery -GitHubBranch feature/my-branch

# Custom output directory
.\AzureManagementPlane.ps1 -CustomerAbbreviation contoso -OutputDirectory C:\exports
```

### Output File

Written to `avd-metrics/` as `<customer>-avd-metrics-<yyyyMMdd-HHmmss>.json`.

Top-level fields:

```json
{
  "CustomerAbbreviation": "contoso",
  "CollectedAt": "2026-05-11T15:00:00",
  "MetricPeriodStart": "2026-04-11T00:00:00",
  "MetricPeriodEnd": "2026-05-11T00:00:00",
  "LookbackDays": 30,
  "ExcludeWeekends": true,
  "PeakHoursOnly": true,
  "UtcOffsetHours": 1,
  "SubscriptionCount": 1,
  "HostPoolCount": 2,
  "LicenseSummaryStatus": "OK",
  "LicenseSummary": [ ... ],
  "UnlicensedUserCount": 3,
  "UnlicensedUsers": [ ... ],
  "HostPools": [ ... ]
}
```

Each object in `HostPools` contains:

```json
{
  "Name": "hp-prod-avd-01",
  "FriendlyName": "Production Desktop",
  "HostPoolType": "Pooled",
  "LoadBalancerType": "BreadthFirst",
  "MaxSessionLimit": 5,
  "HostCount": 12,
  "VmSkus": ["Standard_D4s_v3"],
  "DomainJoinType": "ActiveDirectory",
  "DomainName": "contoso.local",
  "VmExtensions": [ ... ],
  "ImageReferences": [ ... ],
  "OsDiskSizeGb": [128],
  "OsDiskSkus": ["Premium_LRS"],
  "NetworkInfo": [ ... ],
  "ScalingPlan": null,
  "ReservationMatchStatus": "Match",
  "MatchedReservations": [ ... ],
  "BackupInfoStatus": "NotApplicable",
  "WorkspaceNames": ["ws-prod"],
  "AppGroupNames": ["hp-prod-avd-01-DAG"],
  "AccessAssignments": [ ... ],
  "AuthorizedUserCount": 250,
  "AvgCpuPercent": 9.3,
  "P95CpuPercent": 31.2,
  "P99CpuPercent": 37.3,
  "AvgMemUsedPercent": 34.8,
  "P95MemUsedPercent": 45.1,
  "P99MemUsedPercent": 49.6,
  "DailyAverageUsers": 9.2,
  "DailyBreakdown": [ ... ],
  "PeakConcurrentSessions": 7,
  "DailyPeakBreakdown": [ ... ],
  "DiagnosticsStatus": "OK",
  "TotalErrors": 12,
  "TotalFailedConnections": 2,
  "ShortpathErrors": 0,
  "ShortpathUpgradeEvents": 847,
  "HostRegistrationEvents": 24,
  "TopErrors": [ ... ],
  "TransportTypeBreakdown": [
    { "TransportType": "Shortpath", "Count": 831 },
    { "TransportType": "TURN", "Count": 16 }
  ],
  "HostRegistrationBreakdown": [ ... ]
}
```

### Safety Features

- **AST allowlist assertion** — at startup the script parses its own source code and throws before any Azure API call if a cmdlet outside the approved read-only set is detected. Approved cmdlets: `Get-AzContext`, `Get-AzSubscription`, `Set-AzContext`, `Disable-AzContextAutosave`, `Get-AzWvdHostPool`, `Invoke-AzRestMethod`, `Get-AzAccessToken`.
- **Context autosave disabled** — `Disable-AzContextAutosave` is called at startup (process-scoped) so subscription context switches are not persisted to disk.
- **Original context restored** — the caller's Az context is captured before execution and restored in a `finally` block regardless of success or failure.
- **No ARM write operations** — all ARM calls are GET or POST (query-only). The only file written is the local JSON export.

## How `-RunLocalDiscovery` Works

When `-RunLocalDiscovery` is passed, `AzureManagementPlane.ps1` finds the first powered-on session host in each pool and sends a small bootstrap script to it via the **Azure VM Run Command** API. The bootstrap runs entirely on the VM and:

1. Downloads `LocalScript.ps1` and `appExclusions.config.json` from the GitHub repository (`raw.githubusercontent.com/wavenetuk/avd-discovery/<branch>`) using `Invoke-WebRequest`
2. Executes `LocalScript.ps1` in a temporary directory with `-NoGpresult` (Group Policy export is unavailable in Run Command context)
3. GZip-compresses and base64-encodes the resulting JSON and writes it between sentinel markers in stdout
4. `AzureManagementPlane.ps1` reads the stdout, decodes the payload, and saves the JSON to the `vm-discovery/` folder

The files are always fetched fresh from GitHub, so the VM always runs the latest committed version of the script. Use `-GitHubBranch` to target a different branch during testing.

**Requirements:**
- The session host must have outbound HTTPS access to `raw.githubusercontent.com`
- The calling account needs `Virtual Machine Contributor` or `Virtual Machine Run Command Contributor` on the session host VMs

---

Runs directly on an AVD session host (or via `-RunLocalDiscovery` in `AzureManagementPlane.ps1`) to collect on-VM configuration that is not visible from the Azure management plane.

### What It Collects

#### Installed Applications
- All machine-wide and per-user installed applications from the Windows registry uninstall keys
- Default filter removes hidden system components, child installer entries, and Windows Update records
- `-PrimaryApplicationsOnly` applies a stricter filter (configurable in `appExclusions.config.json`) to suppress common runtimes, redistributables, helper components, add-ins, and support packages — leaving only primary business applications

#### Machine Identity
- Hostname, domain membership, and time of collection

#### FSLogix
- Whether FSLogix Profile Container is enabled
- Profile container VHD locations (all configured paths)
- Container size limit, exclusion list, and key policy settings
- Office container enabled state and paths
- Profile container sizes on disk (per-user VHD/VHDX file sizes from the configured storage paths)

#### OneDrive Known Folder Move
- Whether KFM policies are configured (`KFMSilentOptIn`, `KFMBlockOptOut`, tenant ID)
- Actual per-user redirected folders (Desktop, Documents, Pictures)

#### Antivirus
- Registered antivirus product names from WMI/CIM (`Win32_Process`-based detection for Defender)

#### Windows Join State
- Domain join type: Active Directory, Azure AD, Hybrid Azure AD, or Workgroup

#### RDP Shortpath
- Whether managed-network Shortpath is enabled (`fUseUdpPortRedirector`) and the configured UDP port
- Whether public-network Shortpath (ICE) is enabled (`ICEControl`)
- Whether the UDP listener is currently active (`Get-NetUDPEndpoint`)
- Whether Shortpath has been used recently (Event IDs 131 and 70 from `Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Operational` in the last 7 days)
- AVD agent service state and binary version (`RDAgentBootLoader`)

#### RDP Redirection Settings
For each of the following, reports the effective value, its source (Group Policy / local WinStation / local RdServer / not configured), the raw registry value, and whether it is enabled:

- Clipboard redirection
- Drive (disk) redirection
- Printer redirection
- COM port redirection
- LPT port redirection
- Smart card redirection
- Audio playback redirection
- Audio capture redirection
- Video/camera capture redirection
- USB device redirection
- Plug-and-play device redirection
- RDP connections allowed
- Network Level Authentication (NLA) required
- Password prompt on connect
- Security layer (RDP / Negotiate / SSL)
- Encryption level
- Colour depth
- Maximum idle time, disconnection time, and connection time (formatted as hours/minutes)

#### Group Policy Report
- Runs `gpresult /h` and saves an HTML report alongside the JSON output (unless `-NoGpresult` is specified)

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-CustomerAbbreviation` | string | *(prompted)* | Short code used in the output filename |
| `-OutputDirectory` | string | script folder | Directory for the JSON and HTML exports |
| `-PrimaryApplicationsOnly` | switch | off | Apply stricter application filter (see `appExclusions.config.json`) |
| `-NoGpresult` | switch | off | Skip the `gpresult /h` HTML report |

### Prerequisites

- Must be run on a Windows machine (intended for AVD session hosts)
- PowerShell 5.1 or 7+
- Administrator rights recommended (required for some registry paths and FSLogix profile size enumeration)
- `appExclusions.config.json` must be present in the same directory as the script

### Usage Examples

```powershell
# Basic collection with prompts
.\LocalScript.ps1

# Primary applications only, custom output directory
.\LocalScript.ps1 -CustomerAbbreviation contoso -PrimaryApplicationsOnly -OutputDirectory C:\exports

# Skip Group Policy report
.\LocalScript.ps1 -CustomerAbbreviation contoso -NoGpresult
```

### Output File

Written to `vm-discovery/` as `<customer>-<hostname>-avd-discovery-<yyyyMMdd-HHmmss>.json`.

Top-level structure:

```json
{
  "CustomerAbbreviation": "contoso",
  "Hostname": "avd-host-01",
  "CollectedAt": "2026-05-11T10:00:00",
  "InstalledApps": [ ... ],
  "MachineDetails": { ... },
  "FsLogix": { ... },
  "OneDriveKfm": { ... },
  "AntivirusProducts": [ ... ],
  "RdpShortpath": {
    "ManagedNetworkShortpath": true,
    "UdpPortNumber": 3390,
    "PublicNetworkShortpath": false,
    "UdpListenerActive": true,
    "ShortpathUsedRecently": true,
    "RecentShortpathEvents": [ ... ],
    "AvdAgentService": "Running",
    "AvdAgentVersion": "1.0.9876.1600"
  },
  "RdpRedirection": {
    "ClipboardRedirection": {
      "Enabled": true,
      "Source": "GroupPolicy",
      "RawValue": 0
    },
    "DriveRedirection": { ... },
    ...
  }
}
```

---

## appExclusions.config.json

Controls the `-PrimaryApplicationsOnly` filter in `LocalScript.ps1`. Edit this file to adjust what gets suppressed without modifying any PowerShell code.

| Section | Purpose |
|---|---|
| `NamePatterns` | Regex patterns matched against application display names. Any match causes exclusion. |
| `PublisherPatterns` | Publisher names (Microsoft, Citrix, Apple, etc.) used in conjunction with the name pattern below. |
| `SupportingPublisherNamePattern` | Secondary name filter: an application is excluded only when its publisher matches `PublisherPatterns` AND its name matches this pattern. |

All patterns are case-insensitive by default.

---

## Output Folder Structure

```
avd-discovery/
├── AzureManagementPlane.ps1        # Azure management plane collector
├── LocalScript.ps1                 # On-host discovery script
├── appExclusions.config.json       # Application filter configuration
├── avd-metrics/                    # Output from AzureManagementPlane.ps1
│   └── <customer>-avd-metrics-<timestamp>.json
└── vm-discovery/                   # Output from LocalScript.ps1
    ├── <customer>-<host>-avd-discovery-<timestamp>.json
    └── <customer>-<host>-gpresult-<timestamp>.html
```

---

## Required Azure Permissions

| Scope | Role / Permission | Required For |
|---|---|---|
| Subscription(s) | `Reader` | All management plane collection |
| Host pool app groups | `Desktop Virtualization Reader` | Access assignment enumeration |
| Log Analytics workspace | `Log Analytics Reader` | Usage metrics and diagnostic insights |
| Entra ID | `User.Read.All`, `Group.Read.All` (Graph) | Licence check and group membership resolution |
| Session host VMs | `Virtual Machine Contributor` or `Virtual Machine Run Command Contributor` | `-RunLocalDiscovery` (VM Run Command) — no local copy of the script is needed |

---

## Diagnostic Settings Requirements

For `DiagnosticsStatus: OK` and populated usage metrics, each host pool's Diagnostic Settings must forward the following log categories to a Log Analytics workspace:

| Log Category | Used For |
|---|---|
| `Connection` (`WVDConnections`) | Daily average users, peak sessions, transport type breakdown, failed connections |
| `Error` (`WVDErrors`) | Error summary, Shortpath error count |
| `Checkpoint` (`WVDCheckpoints`) | Shortpath upgrade event count |
| `HostRegistration` (`WVDHostRegistrations`) | Host registration event count per session host |

---

## Feature Testing Status

> **Note:** This toolset is under active development. Features marked 🔴 have not yet been validated against a live environment and may contain bugs or incomplete logic. Do not rely on their output until they are marked 🟢.

🟢 = Tested against a live environment &nbsp;&nbsp; 🔴 = Not yet tested

### AzureManagementPlane.ps1

#### Infrastructure Collection
| Feature | Status |
|---|---|
| Host pool enumeration (type, load balancer, max session limit) | 🟢 |
| Session host count and VM SKU(s) | 🟢 |
| Domain join type and domain name | 🟢 |
| VM extensions | 🟢 |
| OS image (marketplace / custom / Shared Image Gallery) | 🟢 |
| OS disk size and storage SKU | 🟢 |
| Network info (VNet, subnet, DNS, NSG, UDR) | 🟢 |
| Scaling plan name and schedule count | 🔴 |

#### Reservations
| Feature | Status |
|---|---|
| Reserved VM Instance matching by SKU and region | 🔴 |

#### Backup
| Feature | Status |
|---|---|
| Azure Backup detection for Personal pool VMs | 🔴 |

#### Access & Authorisation
| Feature | Status |
|---|---|
| App group and workspace names | 🟢 |
| Role assignments (Entra ID groups and direct users) | 🟢 |
| Transitive group membership resolution via Microsoft Graph | 🟢 |
| Authorised user count | 🟢 |

#### Usage Metrics
| Feature | Status |
|---|---|
| Daily average users | 🟢 |
| Peak concurrent sessions | 🟢 |
| Weekend exclusion (`-ExcludeWeekends`) | 🟢 |
| Peak hours filter (`-PeakHoursOnly`) | 🟢 |

#### Performance Metrics
| Feature | Status |
|---|---|
| Average, P95, P99 CPU % | 🟢 |
| Average, P95, P99 memory used % | 🟢 |

#### Diagnostic Insights
| Feature | Status |
|---|---|
| Top 20 error types from `WVDErrors` | 🟢 |
| Failed connection count | 🟢 |
| Transport type breakdown (Shortpath / TURN / Websocket) | 🟢 |
| Shortpath upgrade events | 🟢 |
| Host registration events per session host | 🔴 |

#### Licence Assignments
| Feature | Status |
|---|---|
| Assigned licence SKUs for AVD-relevant products | 🟢 |
| Unlicensed user detection | 🟢 |
| `-SkipLicenceCheck` | 🟢 |

#### `-RunLocalDiscovery`
| Feature | Status |
|---|---|
| Finds first running session host in each pool | 🟢 |
| Downloads and executes `LocalScript.ps1` via VM Run Command | 🟢 |
| Returns output and saves to `vm-discovery/` | 🟢 |
| `-GitHubBranch` targeting | 🔴 |

---

### LocalScript.ps1

#### Machine Identity
| Feature | Status |
|---|---|
| Hostname, domain membership, collection timestamp | 🟢 |
| Join state (AD / Azure AD / Hybrid / Workgroup) | 🟢 |

#### Applications
| Feature | Status |
|---|---|
| Machine-wide and per-user installed applications | 🟢 |
| Default system/update entry filtering | 🟢 |
| `-PrimaryApplicationsOnly` stricter filter | 🟢 |

#### FSLogix
| Feature | Status |
|---|---|
| Installation and service state | 🔴 |
| Profile container enabled state and VHD locations | 🔴 |
| Office container state and paths | 🔴 |
| Container size, policy settings, exclusion list | 🔴 |
| Profile container sizes on disk | 🔴 |
| App Masking configuration | 🔴 |
| Redirections XML detection | 🔴 |

#### OneDrive Known Folder Move
| Feature | Status |
|---|---|
| KFM policy detection | 🟢 |

#### Antivirus
| Feature | Status |
|---|---|
| Security Center product detection | 🟢 |
| Windows Defender status | 🟢 |
| Third-party AV detection via application name matching | 🟢 |

#### RDP Shortpath
| Feature | Status |
|---|---|
| Managed network Shortpath enabled state and UDP port | 🟢 |
| Public network Shortpath (ICE) enabled state | 🟢 |
| UDP listener active state | 🟢 |
| Recent Shortpath event detection (Event IDs 131 / 70) | 🔴 |
| AVD agent service state and version | 🔴 |

#### RDP Redirection Settings
| Feature | Status |
|---|---|
| Clipboard, drive, printer, COM, LPT redirection | 🟢 |
| Smart card, audio, video, USB, PnP redirection | 🟢 |
| NLA, security layer, encryption level, colour depth | 🟢 |
| Session time limits (idle, disconnect, connection) | 🟢 |

#### Other Host Configuration
| Feature | Status |
|---|---|
| LAPS detection (Windows LAPS and legacy LAPS) | 🟢 |
| Intune enrollment state and IME version | 🟢 |
| Teams media optimisation (WebRTC Redirector, New Teams) | 🟢 |
| Language packs and system locale | 🟢 |
| Printers | 🟢 |
| Time source (NTP / W32tm) | 🟢 |
| Universal Print connector | 🔴 |
| Default file associations (DISM policy) | 🔴 |
| Outlook cached mode policy | 🔴 |
| AVD network connectivity tests | 🟢 |

#### Group Policy Report
| Feature | Status |
|---|---|
| `gpresult /h` HTML export | 🔴 |
| `-NoGpresult` skip flag | 🟢 |
