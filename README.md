# AVD Discovery Toolset

A pair of PowerShell scripts for assessing Azure Virtual Desktop environments during migration and optimisation engagements. Together they collect infrastructure detail, usage metrics, performance data, licence assignments, and on-host configuration from AVD host pools — all read-only, with no Azure resources modified.

---

## Scripts at a Glance

| Script | Where It Runs | Output |
|---|---|---|
| `scripts/Invoke-AvdMetricsCollection.ps1` | Your local machine | `output/avd-metrics/<customer>-avd-metrics-<timestamp>.json` |
| `scripts/Invoke-AvdSessionHostAudit.ps1` | On an AVD session host | `output/vm-discovery/<customer>-<hostname>-avd-discovery-<timestamp>.json` |

`Invoke-AvdMetricsCollection.ps1` can optionally invoke `Invoke-AvdSessionHostAudit.ps1` automatically on a running session host via Azure VM Run Command (`-RunLocalDiscovery`), eliminating the need to run it separately.

---

## Invoke-AvdMetricsCollection.ps1

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
- Host pool RDP properties (`customRdpProperty`) — the AVD-enforced redirection settings sent to connecting clients, parsed into a structured object covering drive, clipboard, printer, smart card, audio, camera, USB, and location redirection

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
| `-RunLocalDiscovery` | switch | off | Execute `Invoke-AvdSessionHostAudit.ps1` on a running VM in each pool via Azure VM Run Command (downloads from GitHub) |
| `-InlineLocalScript` | switch | off | Embed `Invoke-AvdSessionHostAudit.ps1` and `config/appExclusions.config.json` directly into the Run Command payload instead of downloading from GitHub on the VM. Use when VMs lack outbound HTTPS to `raw.githubusercontent.com` (AV/firewall restrictions). Requires the files to be present alongside `Invoke-AvdMetricsCollection.ps1` |
| `-LocalDiscoveryTimeout` | int | `300` | Maximum seconds to wait for the on-VM script to complete when using `-RunLocalDiscovery`. Valid range: 60–3600 |
| `-RunAsUser` | switch | off | Prompt for domain credentials before running local discovery and execute the Run Command as that user instead of SYSTEM. Shows a security warning before prompting. Useful when per-user checks (shell folders, mapped drives, Outlook settings) are needed |
| `-GitHubBranch` | string | `main` | GitHub branch to download `Invoke-AvdSessionHostAudit.ps1` and `config/appExclusions.config.json` from when using `-RunLocalDiscovery` |
| `-SkipLicenceCheck` | switch | off | Skip Microsoft Graph licence collection |

### Prerequisites

- PowerShell 5.1 or 7+
- `Az.Accounts` and `Az.DesktopVirtualization` modules installed
- Authenticated via `Connect-AzAccount`
- **For usage metrics**: Diagnostic Settings on each host pool forwarding `Connection`, `Error`, `Checkpoint`, and `HostRegistration` log categories to a Log Analytics workspace
- **For licence data**: the authenticated account requires Microsoft Graph `User.Read.All` and `Group.Read.All` (or equivalent)
- **For `-RunLocalDiscovery`**: session host VMs must have outbound HTTPS access to `raw.githubusercontent.com` so they can download the scripts at runtime (or use `-InlineLocalScript` to bypass this requirement)
- **For `-RunAsUser`**: a low-privilege domain account with interactive logon rights on the session host; credentials are collected once before discovery begins, transmitted in plaintext in the ARM request body, and may appear in Azure ARM activity logs — see the [Run-As Mode](#run-as-mode--runasuser) section for full security implications

### Usage Examples

```powershell
# Interactive — prompts for customer abbreviation, queries all subscriptions
.\scripts\Invoke-AvdMetricsCollection.ps1

# Specific subscription, 14-day window, exclude weekends
.\scripts\Invoke-AvdMetricsCollection.ps1 -CustomerAbbreviation contoso -SubscriptionId '00000000-0000-0000-0000-000000000000' -LookbackDays 14 -ExcludeWeekends

# Peak hours only (09:00–18:00 BST), weekdays only
.\scripts\Invoke-AvdMetricsCollection.ps1 -CustomerAbbreviation contoso -PeakHoursOnly -ExcludeWeekends -UtcOffsetHours 1

# Single host pool, skip licence check
.\scripts\Invoke-AvdMetricsCollection.ps1 -CustomerAbbreviation contoso -HostPoolName hp-prod-avd-01 -SkipLicenceCheck

# Run Invoke-AvdSessionHostAudit.ps1 automatically — fetches latest from GitHub main branch
.\scripts\Invoke-AvdMetricsCollection.ps1 -CustomerAbbreviation contoso -RunLocalDiscovery

# Run Invoke-AvdSessionHostAudit.ps1 from a specific branch (e.g. for testing)
.\scripts\Invoke-AvdMetricsCollection.ps1 -CustomerAbbreviation contoso -RunLocalDiscovery -GitHubBranch feature/my-branch

# Run Invoke-AvdSessionHostAudit.ps1 with inline mode (no outbound GitHub access needed on VMs)
.\scripts\Invoke-AvdMetricsCollection.ps1 -CustomerAbbreviation contoso -RunLocalDiscovery -InlineLocalScript -NoGpresult
# Extend the per-VM timeout to 10 minutes (default is 300s)
.\scripts\Invoke-AvdMetricsCollection.ps1 -CustomerAbbreviation contoso -RunLocalDiscovery -LocalDiscoveryTimeout 600

# Run as a domain user to enable per-user checks (shell folders, mapped drives, Outlook)
.\scripts\Invoke-AvdMetricsCollection.ps1 -CustomerAbbreviation contoso -RunLocalDiscovery -RunAsUser

# Inline mode + run-as (blocked GitHub AND need per-user data)
.\scripts\Invoke-AvdMetricsCollection.ps1 -CustomerAbbreviation contoso -RunLocalDiscovery -InlineLocalScript -RunAsUser
# Custom output directory
.\scripts\Invoke-AvdMetricsCollection.ps1 -CustomerAbbreviation contoso -OutputDirectory C:\exports
```

### Output File

Written to `output/avd-metrics/` as `<customer>-avd-metrics-<yyyyMMdd-HHmmss>.json`.

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
  "RdpProperties": {
    "RawPropertyString": "drivestoredirect:s:;redirectclipboard:i:0;redirectprinters:i:0;audiomode:i:0;audiocapturemode:i:1",
    "AllSettings": { "drivestoredirect": "", "redirectclipboard": 0, "redirectprinters": 0, "audiomode": 0, "audiocapturemode": 1 },
    "DriveRedirection": { "Enabled": false, "Value": "" },
    "ClipboardRedirection": { "Enabled": false, "RawValue": 0 },
    "PrinterRedirection": { "Enabled": false, "RawValue": 0 },
    "SmartCardRedirection": null,
    "AudioPlayback": { "Display": "PlayOnClient", "RawValue": 0 },
    "AudioCapture": { "Enabled": true, "RawValue": 1 },
    "CameraRedirection": null,
    "UsbRedirection": null,
    "LocationRedirection": null
  },
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
- **Stale Run Command cleanup requires confirmation** — when `-RunLocalDiscovery` finds existing `runCommands` resources on a VM from a previous run, it lists them and prompts before issuing any DELETE. Declining skips the deletion (the VM may get stuck at Pending, but no write is performed without consent).

## How `-RunLocalDiscovery` Works

When `-RunLocalDiscovery` is passed, `Invoke-AvdMetricsCollection.ps1` enumerates all powered-on session hosts in each pool, then attempts to run a bootstrap script on them in sequence via the **Azure VM Run Command v2** API until one succeeds. The bootstrap runs entirely on the VM and:

1. Downloads `Invoke-AvdSessionHostAudit.ps1` and `config/appExclusions.config.json` from the GitHub repository (`raw.githubusercontent.com/wavenetuk/avd-discovery/<branch>`) using `Invoke-WebRequest` — or decodes them from the embedded payload in inline mode
2. Executes `Invoke-AvdSessionHostAudit.ps1` in a temporary directory
3. GZip-compresses and base64-encodes the resulting JSON, writing it to a staging file on the VM
4. Returns the staging file path via stdout; `Invoke-AvdMetricsCollection.ps1` reads it back in chunks, decodes the payload, and saves the JSON to the `output/vm-discovery/` folder

The files are always fetched fresh from GitHub, so the VM always runs the latest committed version of the script. Use `-GitHubBranch` to target a different branch during testing.

### VM Selection and Rotation

All powered-on session hosts in the pool are collected upfront. Discovery is attempted on the first one; if it fails or its agent appears unresponsive, the script automatically moves to the next powered-on host and tries again. This continues until one VM succeeds or all candidates are exhausted.

If all VMs fail, a warning is printed listing how many hosts were tried.

### Pre-flight Cleanup of Stale Run Command Resources

The Azure VM agent can only process one `runCommands` resource at a time. A resource left in `Creating` or `Deleting` state from a previous timed-out run will block every subsequent attempt indefinitely.

Before submitting a new Run Command, the script lists any existing `runCommands` resources on the target VM. If any are found, it:

1. Prints a warning listing each resource name and its provisioning state
2. Prompts for explicit confirmation before issuing any DELETE
3. If confirmed, deletes them and polls until they are gone (up to 120 seconds)
4. If declined, proceeds anyway — the VM may then get stuck at `Pending`, triggering the stuck-detection logic

This is the only write operation in the script and requires user consent each time.

### Stuck-at-Pending Detection

Every third polling cycle, the script queries the Run Command **instance view** directly and logs the current `executionState` (e.g. `Running`, `Pending`). If the state remains `Pending` with `provisioningState: Creating` for 90 or more seconds, the script concludes that the VM agent is not processing commands and aborts the attempt early — rather than waiting the full timeout.

On the first stuck VM in a pool, a yellow advisory box is printed explaining likely causes (endpoint security blocking execution, the Azure wireserver being unreachable, or a stuck agent goal-state queue) and recommending that the user cancel and run `Invoke-AvdSessionHostAudit.ps1` directly on the host. Access methods are listed one per line (RDP, Azure Bastion, RMM/LogicMonitor), and the exact command to run — including the customer abbreviation and any flags that were passed to the original invocation — is printed ready to copy.

### Timeout Diagnostics

If a Run Command reaches the polling deadline without completing, the script fetches a final instance view snapshot before cleanup and logs:

- `executionState` and `exitCode` from the VM agent
- `provisioningState` of the Run Command resource
- A snippet of `stdout` and `stderr` if any output was captured

This information pinpoints whether the command was never delivered (stuck at `Pending/Creating`) or started but ran over time.

### Controlling the Execution Timeout (`-LocalDiscoveryTimeout`)

By default `Invoke-AvdMetricsCollection.ps1` waits up to **300 seconds** for the on-VM script to finish. If your session hosts are slow to start, heavily loaded, or the discovery scope is large, you can raise this:

```powershell
.\scripts\Invoke-AvdMetricsCollection.ps1 -CustomerAbbreviation contoso -RunLocalDiscovery -LocalDiscoveryTimeout 600
```

Valid range is 60–3600 seconds. The value is passed directly to the Azure Run Command `timeoutInSeconds` field as well as the local polling deadline, so both the VM-side execution limit and the client-side wait are extended together.

During polling, every third check also queries the Run Command **instance view** and logs the current execution state (e.g. `Running`, `Failed`) so you can confirm progress rather than watching silent poll lines.

### Run-As Mode (`-RunAsUser`)

Azure VM Run Command normally executes as `NT AUTHORITY\SYSTEM`. This means per-user registry hives, shell folder redirections, mapped drives, and Outlook cached-mode settings are not visible to `Invoke-AvdSessionHostAudit.ps1` — the output will be marked `"CollectionMode": "SystemAccount"` and those checks are skipped.

Add `-RunAsUser` to run as a domain account instead:

```powershell
.\scripts\Invoke-AvdMetricsCollection.ps1 -CustomerAbbreviation contoso -RunLocalDiscovery -RunAsUser
```

Before discovery begins you will see a prominent warning and be prompted for a username and password. The script runs once per host pool, targeting a single powered-on session host, so you only need to enter credentials once per execution.

> **⚠ Security implications — read before using:**
>
> - **Credentials are transmitted in plaintext.** The username and password are sent as plain text in the Azure ARM API request body. They are not encrypted beyond the HTTPS transport layer.
> - **Temporarily stored in Azure.** The credentials are held inside the `runCommands` ARM resource for the duration of the run. The script deletes this resource on completion, but it exists in Azure for several minutes.
> - **Username is visible in ARM activity logs; password is not.** Azure ARM activity logs record the response body returned by the API, not the request body sent to it. Since Azure never echoes `runAsPassword` back in its response, the password does not appear in standard activity logs. However, the username (`runAsUser`) is present in the logged response body and will be visible to anyone with `Reader` access on the subscription for up to 90 days. If your organisation exports activity logs to a Log Analytics workspace or storage account, the same applies to those copies.
> - **ARM activity log entries cannot be deleted.** Azure platform activity logs are immutable — individual entries cannot be removed. The entries age out automatically after the configured retention period (90 days by default). If your organisation exports to Log Analytics or a storage account via a Diagnostic Setting, those copies can be purged separately (delete the relevant rows in Log Analytics, or delete the blob in the storage account).
> - **Use a low-privilege domain account only.** The account must be able to log on to the session host interactively, but should have no other elevated rights. Do not use admin accounts, service accounts with broad permissions, or shared credentials.
> - **Local accounts are not suitable.** The Azure VM Run Command `runAsUser` feature requires a domain account (format: `DOMAIN\user` or `user@domain.com`). Local administrator accounts should not be used — they are specifically the type of privileged account this feature warns against.

### Inline Mode (`-InlineLocalScript`)

If VMs cannot reach `raw.githubusercontent.com` (blocked by antivirus, firewall, proxy, or network policy), add `-InlineLocalScript` to embed the script files directly in the Run Command payload:

```powershell
.\scripts\Invoke-AvdMetricsCollection.ps1 -CustomerAbbreviation contoso -RunLocalDiscovery -InlineLocalScript
```

In this mode, `Invoke-AvdSessionHostAudit.ps1` and `config/appExclusions.config.json` are read from the local repository directory (alongside `Invoke-AvdMetricsCollection.ps1`), base64-encoded, and carried inside the wrapper script sent to the VM. On the VM, the embedded content is decoded to temp files before execution — no outbound internet access is required.

The combined payload (~98 KB) fits well within the Azure Run Command v2 limit of 256 KB.

> **Note:** Inline mode uses whatever version of the files is on your local disk. If you need the latest from GitHub, `git pull` first or omit `-InlineLocalScript` to use the default download behaviour.

**Requirements:**
- `gpresult` is run with `/scope computer` only (user RSoP is unavailable under a machine account)
- Per-user shell folder and mapped drive checks are skipped
- Per-user Outlook cached mode registry settings are skipped
- The output includes `"CollectionMode": "SystemAccount"` and `"RunningAsAccount"` so consumers can distinguish system-mode runs from interactive ones

When run interactively on a host as a real user account, all of the above checks are performed in full and `"CollectionMode"` is `"Interactive"`.

**Requirements:**
- The session host must have outbound HTTPS access to `raw.githubusercontent.com` (unless `-InlineLocalScript` is used)
- The calling account needs `Virtual Machine Contributor` or `Virtual Machine Run Command Contributor` on the session host VMs

**System account mode:** Azure VM Run Command executes as `NT AUTHORITY\SYSTEM` (or the machine account `HOSTNAME$`). `Invoke-AvdSessionHostAudit.ps1` automatically detects this context and adjusts its behaviour:

---

Runs directly on an AVD session host (or via `-RunLocalDiscovery` in `Invoke-AvdMetricsCollection.ps1`) to collect on-VM configuration that is not visible from the Azure management plane.

### What It Collects

#### Installed Applications
- All machine-wide and per-user installed applications from the Windows registry uninstall keys
- Default filter removes hidden system components, child installer entries, and Windows Update records
- `-PrimaryApplicationsOnly` applies a stricter filter (configurable in `config/appExclusions.config.json`) to suppress common runtimes, redistributables, helper components, add-ins, and support packages — leaving only primary business applications

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
- Actual per-user redirected folders (Desktop, Documents, Pictures) — skipped when running as a system/machine account

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
- When running as a system/machine account (e.g. via Azure VM Run Command), the report is automatically scoped to computer policy only (`/scope computer`); user RSoP requires an interactive run

#### Active Directory Dependency Assessment
- Services running as domain accounts (excludes LocalSystem, NT AUTHORITY\\*, NT SERVICE\\*)
- Scheduled tasks with a domain account principal
- ODBC system DSNs (32-bit and 64-bit) where the server field is a FQDN/UNC path, or the UID contains a `domain\\user` credential
- Active established TCP connections to AD ports: 88 (Kerberos), 135 (RPC), 389 (LDAP), 445 (SMB), 464 (Kpasswd), 636 (LDAPS), 3268/3269 (Global Catalog) — with reverse DNS lookup of the remote address
- `HasDomainDependencies` summary flag set if any of the above are found

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-CustomerAbbreviation` | string | *(prompted)* | Short code used in the output filename |
| `-OutputDirectory` | string | script folder | Directory for the JSON and HTML exports |
| `-PrimaryApplicationsOnly` | switch | off | Apply stricter application filter (see `config/appExclusions.config.json`) |
| `-NoGpresult` | switch | off | Skip the `gpresult /h` HTML report |

### Prerequisites

- Must be run on a Windows machine (intended for AVD session hosts)
- PowerShell 5.1 or 7+
- Administrator rights recommended (required for some registry paths and FSLogix profile size enumeration)
- `config/appExclusions.config.json` must be present in the repository root (one level above the `scripts/` folder)

### Usage Examples

```powershell
# Basic collection with prompts
.\scripts\Invoke-AvdSessionHostAudit.ps1

# Primary applications only, custom output directory
.\scripts\Invoke-AvdSessionHostAudit.ps1 -CustomerAbbreviation contoso -PrimaryApplicationsOnly -OutputDirectory C:\exports

# Skip Group Policy report
.\scripts\Invoke-AvdSessionHostAudit.ps1 -CustomerAbbreviation contoso -NoGpresult
```

### Output File

Written to `output/vm-discovery/` as `<customer>-<hostname>-avd-discovery-<yyyyMMdd-HHmmss>.json`.

Top-level structure:

```json
{
  "CustomerAbbreviation": "contoso",
  "CollectedAt": "2026-05-11T10:00:00",
  "CollectionMode": "SystemAccount",
  "RunningAsAccount": "WORKGROUP\\avd-host-01$",
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

## config/appExclusions.config.json

Controls the `-PrimaryApplicationsOnly` filter in `Invoke-AvdSessionHostAudit.ps1`. Edit this file to adjust what gets suppressed without modifying any PowerShell code.

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
├── scripts/
│   ├── Invoke-AvdMetricsCollection.ps1   # Azure management plane collector
│   └── Invoke-AvdSessionHostAudit.ps1    # On-host discovery script
├── config/
│   ├── appExclusions.config.json         # Application filter configuration
│   └── ms-service-plan-ids.csv           # Microsoft licence SKU reference data
├── output/
│   ├── avd-metrics/                      # Output from Invoke-AvdMetricsCollection.ps1
│   │   └── <customer>-avd-metrics-<timestamp>.json
│   └── vm-discovery/                     # Output from Invoke-AvdSessionHostAudit.ps1
│       ├── <customer>-<host>-avd-discovery-<timestamp>.json
│       └── <customer>-<host>-gpresult-<timestamp>.html
├── docs/
└── README.md
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

### Invoke-AvdMetricsCollection.ps1

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
| Host pool RDP properties (parsed `customRdpProperty`) | 🔴 |

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
| Downloads and executes `Invoke-AvdSessionHostAudit.ps1` via VM Run Command | 🟢 |
| Returns output and saves to `output/vm-discovery/` | 🟢 |
| `-GitHubBranch` targeting | 🔴 |

---

### Invoke-AvdSessionHostAudit.ps1

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

#### Active Directory Dependency Assessment
| Feature | Status |
|---|---|
| Services running as domain accounts | 🔴 |
| Scheduled tasks running as domain accounts | 🔴 |
| ODBC system DSNs with domain server or domain credentials | 🔴 |
| Active TCP connections to AD ports (88/135/389/445/464/636/3268/3269) | 🔴 |
