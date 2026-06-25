# AVD Discovery Toolset

Two read-only PowerShell collectors plus a shared HTML report generator for assessing AVD environments.
| Script | Runs on | Output |
|---|---|---|
| `scripts/Invoke-AvdMetricsCollection.ps1` | Local machine | `output/avd-metrics/<customer>-avd-metrics-<timestamp>.json` plus a sibling `.html` report rendered by the shared HTML generator |
| `scripts/Invoke-AvdSessionHostAudit.ps1` | AVD session host | ZIP archive beside the script when run portably; the generated JSON, logs, and optional `.html` report are cleaned up after archiving, while the transcript is kept only when the run fails |

## Shared HTML Reporting

`scripts/Invoke-HtmlReportGenerator.ps1` is the shared HTML report generator used by both collectors. It resolves the report type from the JSON payload or an explicit `-ReportType`, then dispatches to the matching renderer module under `scripts/reporting`.

The renderer bundle is portable: if `scripts/reporting` is present beside the generator it uses those local files, and if the bundle is missing it downloads and caches the renderer assets from this repository's raw GitHub URLs before generating HTML. When run portably without `-OutputPath`, it writes the HTML into the same `scripts/<customer>-audit-results/` folder.

The current renderer packs are `AvdMetrics` and `AzureSessionHostAudit`, each backed by a shared shell plus report-specific client script.

`Invoke-AvdMetricsCollection.ps1` can attempt to run `Invoke-AvdSessionHostAudit.ps1` automatically on a live session host via Azure VM Run Command (`-RunLocalDiscovery`).

---

## Invoke-AvdMetricsCollection.ps1

Enumerates all AVD host pools across one or more subscriptions.

### What It Collects

**Infrastructure**
- Host pool type, load balancer, max session limit
- Session host count, VM SKU(s), OS image (marketplace / custom / SIG)
- OS disk size and SKU, domain join type and domain name
- VM extensions, VNet, subnet, DNS, NSG, UDR
- Scaling plan name and schedule count
- RDP properties (`customRdpProperty`) parsed into structured object (drive, clipboard, printer, smart card, audio, camera, USB, location)

**Reservations**
- Reserved VM Instance matches by SKU and region

**Backup**
- Azure Backup status for session host VMs (Personal or Entra ID Joined pools only)

**Access & Authorisation**
- App group and workspace names
- Role assignments (Entra ID groups and direct users), authorised user count resolved transitively via Microsoft Graph

**Usage Metrics** *(requires Log Analytics: Connection, Error, Checkpoint, HostRegistration categories)*
- Daily average users, peak concurrent sessions (with per-day breakdowns)
- CPU and memory: average, P95, P99 across all session hosts

**Diagnostic Insights** *(requires Log Analytics as above)*
- Top 20 error types from `WVDErrors`; failed connection count
- Transport type breakdown (Shortpath / TURN / Websocket)
- Shortpath upgrade events; host registration events per session host

**Entra SSO Assessment**
- Detects join type (cloud-native Entra ID, Hybrid, or AD) via VM extensions and Microsoft Graph
- Checks `enablerdsaadauth:i:1` in RDP properties
- For Hybrid pools: verifies Cloud Kerberos Trust via Graph Beta, flags absence as a blocker
- Reports SSO status as `Configured`, `NotConfigured`, `PossiblyConfigured`, or `Unknown` with blockers and advisories

**Registration Token**
- Checks for an active (non-expired) registration token; reports expiry time if present

**FSLogix Storage Account Scan** *(`-ScanStorageAccounts`)*
- By default, scans all accessible storage accounts and keeps only those that contain Azure Files shares
- Use `-ScanStorageAccounts` to limit the scan to specific named storage accounts
- Use `-SkipStorageAccounts` to disable storage scanning entirely
- Collects: SKU, replication, kind, encryption, public access, private endpoints, network rules, SMB multichannel, soft-delete, identity-based auth (directory service, default share permission, domain name)
- Per-file-share: provisioned size, used size/%, IOPS, bandwidth, tier, Azure Backup status

**Licence Assignments** *(Microsoft Graph)*
- AVD-relevant SKUs per user (Windows 365, M365/O365 suites, Visio, Project, Power BI, Intune/EMS, Defender, AVD Store)
- Users with role assignments but no qualifying licence

Both scripts also emit a self-contained HTML companion report next to the JSON export for easier review, filtering, and drill-down.

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-CustomerAbbreviation` | string | *(prompted)* | Short code used in the output filename |
| `-SubscriptionId` | string[] | *(all)* | Limit to specific subscription(s) |
| `-HostPoolName` | string[] | *(all)* | Limit to specific host pool name(s) |
| `-LookbackDays` | int | `30` | Metric window in days (max 90) |
| `-ExcludeWeekends` | switch | off | Omit Saturday and Sunday from all averages |
| `-PeakHoursOnly` | switch | off | Restrict averages to 09:00-18:00 |
| `-UtcOffsetHours` | int | `0` | UTC offset for peak hours (e.g. `1` for BST) |
| `-OutputDirectory` | string | script folder | Output directory |
| `-SkipLicenceCheck` | switch | off | Skip Microsoft Graph licence collection |
| `-ScanStorageAccounts` | string[] | *(none)* | Storage account names to scan instead of the default all-account search |
| `-SkipStorageAccounts` | switch | off | Disable all storage account scanning |
| `-RunLocalDiscovery` | switch | off | Run `Invoke-AvdSessionHostAudit.ps1` on a live VM per pool via VM Run Command |
| `-InlineLocalScript` | switch | off | Embed the audit script in the payload instead of downloading from GitHub (use when VMs block outbound access to `raw.githubusercontent.com`) |
| `-LocalDiscoveryTimeout` | int | `300` | Seconds to wait for on-VM script (60-3600) |
| `-RunAsUser` | switch | off | Run VM Run Command as a domain user instead of SYSTEM (enables per-user checks; see security note below) |
| `-GitHubBranch` | string | `main` | Branch to download from when using `-RunLocalDiscovery` |
| `-GeneratedBy` | string | *(none)* | Name of the person running the collection; stored in the output JSON |
| `-ProjectCode` | string | *(none)* | Engagement or project code; stored in the output JSON |

### Prerequisites

- PowerShell 5.1 or 7+
- `Az.Accounts` and `Az.DesktopVirtualization` modules; authenticated via `Connect-AzAccount`
- Log Analytics `Reader` and the four AVD diagnostic log categories for usage metrics
- Microsoft Graph `User.Read.All` + `Group.Read.All` for licence data
- `Virtual Machine Contributor` or `Virtual Machine Run Command Contributor` for `-RunLocalDiscovery`
- For `-RunAsUser`: a low-privilege domain account with interactive logon rights on the session host. **The username and password are sent in the ARM request body over HTTPS and held in the `runCommands` ARM resource for the duration of the run. The username (not the password) is visible in ARM activity logs to anyone with Reader access on the subscription.**

### Usage Examples

```powershell
# All subscriptions, interactive prompts
.\scripts\Invoke-AvdMetricsCollection.ps1

# Specific subscription, 14-day window, weekdays only
.\scripts\Invoke-AvdMetricsCollection.ps1 -CustomerAbbreviation contoso -SubscriptionId '00000000-...' -LookbackDays 14 -ExcludeWeekends

# Peak hours only (BST)
.\scripts\Invoke-AvdMetricsCollection.ps1 -CustomerAbbreviation contoso -PeakHoursOnly -ExcludeWeekends -UtcOffsetHours 1

# Run on-host audit automatically (downloads from GitHub)
.\scripts\Invoke-AvdMetricsCollection.ps1 -CustomerAbbreviation contoso -RunLocalDiscovery

# Run on-host audit - inline (no outbound internet on VMs)
.\scripts\Invoke-AvdMetricsCollection.ps1 -CustomerAbbreviation contoso -RunLocalDiscovery -InlineLocalScript

# Run on-host audit as a domain user (per-user checks)
.\scripts\Invoke-AvdMetricsCollection.ps1 -CustomerAbbreviation contoso -RunLocalDiscovery -RunAsUser

# Scan storage accounts for FSLogix configuration
.\scripts\Invoke-AvdMetricsCollection.ps1 -CustomerAbbreviation contoso -ScanStorageAccounts storageaccount1,storageaccount2

# Skip storage scanning entirely
.\scripts\Invoke-AvdMetricsCollection.ps1 -CustomerAbbreviation contoso -SkipStorageAccounts
```

---

## Invoke-AvdSessionHostAudit.ps1

Runs directly on an AVD session host (or via `-RunLocalDiscovery`).

### What It Collects

**Installed Applications**
- All machine-wide and per-user applications from registry uninstall keys
- `-PrimaryApplicationsOnly` applies the filter defined in `config/appExclusions.config.json` to remove runtimes, redistributables, and helper components

**Machine Identity**
- Hostname, domain membership, join type (AD / Azure AD / Hybrid / Workgroup), collection timestamp

**FSLogix**
- Profile Container: enabled state, VHD locations, size limit, exclusion list, key policy settings
- Office Container: enabled state and paths
- Profile container sizes on disk (per-user VHD/VHDX file sizes from configured storage paths)
- App Masking configuration; Redirections XML detection

**OneDrive Known Folder Move**
- KFM policy settings (`KFMSilentOptIn`, `KFMBlockOptOut`, tenant ID)
- Per-user redirected folders (skipped when running as SYSTEM)

**Antivirus**
- Registered antivirus products from WMI; Defender status

**RDP Shortpath**
- Managed-network Shortpath: enabled state and UDP port
- Public-network Shortpath (ICE): enabled state
- UDP listener active state
- Recent Shortpath events (Event IDs 131 / 70, last 7 days)
- AVD agent (`RDAgentBootLoader`) state and version

**RDP Redirection Settings**
Effective value, source (Group Policy / local WinStation / local RdServer / not configured), and raw registry value for: clipboard, drive, printer, COM, LPT, smart card, audio playback, audio capture, video/camera, USB, PnP, NLA, password-on-connect, security layer, encryption level, colour depth, and session time limits.

**Group Policy Report**
- `gpresult /h` HTML saved alongside the JSON (skip with `-NoGpresult`)
- Automatically scoped to `/scope computer` when running as SYSTEM

**Active Directory Dependency Assessment**
- Services running as domain accounts
- Scheduled tasks with a domain account principal
- ODBC system DSNs (32-bit and 64-bit) pointing to domain resources
- Active established TCP connections to AD ports: 88, 135, 389, 445, 464, 636, 3268, 3269
- `HasDomainDependencies` summary flag; summary line shows counts for Services, Tasks, ODBC, AD Port Connections, and Config Files

**Other**
- LAPS: Windows LAPS and legacy LAPS detection
- Intune: enrolment state and IME version
- Teams: WebRTC Redirector and New Teams presence
- Language packs and system locale; installed printers; NTP time source

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-CustomerAbbreviation` | string | *(prompted)* | Short code used in the output filename |
| `-OutputDirectory` | string | script folder | Directory for JSON and HTML exports |
| `-PrimaryApplicationsOnly` | switch | off | Apply stricter application filter |
| `-NoGpresult` | switch | off | Skip `gpresult /h` HTML report |
| `-SkipConnectivityChecks` | switch | off | Skip the AVD endpoint connectivity tests |
| `-NoHtml` | switch | off | Skip HTML report generation even when the shared JSON report generator script is available |
| `-GeneratedBy` | string | *(none)* | Name of the person running the collection; stored in the output JSON |
| `-ProjectCode` | string | *(none)* | Engagement or project code; stored in the output JSON |

### Prerequisites

- Windows; PowerShell 5.1 or 7+
- Administrator rights recommended (some registry paths and FSLogix profile size enumeration require it)
- `config/appExclusions.config.json` is optional — the script looks for it alongside itself first, then in `<parent>\config\`. If absent, all applications are included and `-PrimaryApplicationsOnly` has no effect.

### Usage Examples

```powershell
# Basic - prompts for customer abbreviation
.\scripts\Invoke-AvdSessionHostAudit.ps1

# If the context-menu run closes too quickly, use the launcher wrapper instead
scripts\Run-AvdSessionHostAudit.cmd

# Primary applications only, custom output directory
.\scripts\Invoke-AvdSessionHostAudit.ps1 -CustomerAbbreviation contoso -PrimaryApplicationsOnly -OutputDirectory C:\Temp

# Skip Group Policy report
.\scripts\Invoke-AvdSessionHostAudit.ps1 -CustomerAbbreviation contoso -NoGpresult
```

---

## How `-RunLocalDiscovery` Works

`Invoke-AvdMetricsCollection.ps1` iterates powered-on session hosts per pool and submits `Invoke-AvdSessionHostAudit.ps1` via Azure VM Run Command v2. It tries each host in turn until one succeeds.

The bootstrap script on the VM:
1. Downloads (or decodes from the inline payload) `Invoke-AvdSessionHostAudit.ps1` and `config/appExclusions.config.json`
2. Executes the audit in a temp directory
3. GZip-compresses and base64-encodes the JSON output and writes it to a staging file
4. Returns the staging file path; the caller reads it back in chunks, decodes it, and saves it to `output/vm-discovery/`

**Stuck VM detection:** if the Run Command stays `Pending` for 90+ seconds the script aborts that host and moves on.

**Stale resource cleanup:** if a prior timed-out run left a `runCommands` resource on the VM (blocking a new submission), the script lists them and prompts before deleting. This is the only write operation in the script.

---

## config/appExclusions.config.json

Controls the `-PrimaryApplicationsOnly` filter.

| Section | Purpose |
|---|---|
| `NamePatterns` | Regex patterns matched against application display names - any match causes exclusion |
| `PublisherPatterns` | Publisher names (Microsoft, Citrix, Apple, etc.) used with `SupportingPublisherNamePattern` |
| `SupportingPublisherNamePattern` | Secondary name filter: excluded only when publisher matches `PublisherPatterns` AND name matches this pattern |

All patterns are case-insensitive.

---

## Required Azure Permissions

| Scope | Role / Permission | Required For |
|---|---|---|
| Subscription(s) | `Reader` | All management plane collection |
| Host pool app groups | `Desktop Virtualization Reader` | Access assignment enumeration |
| Log Analytics workspace | `Log Analytics Reader` | Usage metrics and diagnostic insights |
| Entra ID | `User.Read.All`, `Group.Read.All` (Graph) | Licence check and group membership resolution |
| Session host VMs | `Virtual Machine Contributor` or `Virtual Machine Run Command Contributor` | `-RunLocalDiscovery` |

---

## Diagnostic Settings Requirements

Each host pool must forward these log categories to a Log Analytics workspace:

| Log Category | Used For |
|---|---|
| `Connection` (`WVDConnections`) | Daily average users, peak sessions, transport type breakdown, failed connections |
| `Error` (`WVDErrors`) | Error summary, Shortpath error count |
| `Checkpoint` (`WVDCheckpoints`) | Shortpath upgrade events |
| `HostRegistration` (`WVDHostRegistrations`) | Host registration events per session host |

---

## Output Folder Structure

```
avd-discovery/
├── scripts/
│   ├── Invoke-AvdMetricsCollection.ps1
│   └── Invoke-AvdSessionHostAudit.ps1
├── config/
│   ├── appExclusions.config.json
│   └── ms-service-plan-ids.csv
├── output/
│   ├── avd-metrics/
│   │   ├── <customer>-avd-metrics-<timestamp>.json
│   │   └── <customer>-avd-metrics-<timestamp>.html
│   └── vm-discovery/
│       ├── <customer>-<host>-avd-discovery-<timestamp>.json
│       ├── <customer>-<host>-avd-discovery-<timestamp>.html
│       └── <customer>-<host>-gpresult-<timestamp>.html
└── README.md
```
