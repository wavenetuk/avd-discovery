const REPORT_TITLE = __REPORT_TITLE__;
		const SOURCE_JSON = __SOURCE_JSON__;
		const GENERATED_AT = __GENERATED_AT__;
		const PAYLOAD_B64 = __REPORT_PAYLOAD__;

		function decodeUtf8Base64(input) {
			const binary = atob(input);
			const bytes = new Uint8Array(binary.length);
			for (let i = 0; i < binary.length; i += 1) {
				bytes[i] = binary.charCodeAt(i);
			}
			return new TextDecoder().decode(bytes);
		}

		const data = JSON.parse(decodeUtf8Base64(PAYLOAD_B64));
		data.HostPools = normalizeCollection(data.HostPools).map(({ BackupInfo, BackupInfoStatus, ...pool }) => pool);

		function isPlainObject(value) {
			return value !== null && typeof value === 'object' && !Array.isArray(value);
		}

		function normalizeCollection(value) {
			if (Array.isArray(value)) { return value; }
			if (isPlainObject(value)) {
				const values = Object.values(value);
				if (!values.length) { return []; }
				if (values.every((item) => isPlainObject(item))) { return values; }
				return [value];
			}
			return [];
		}

		function toNumber(value) {
			return typeof value === 'number' && Number.isFinite(value) ? value : null;
		}

		function average(values) {
			const clean = values.filter((value) => typeof value === 'number' && Number.isFinite(value));
			if (!clean.length) { return null; }
			return clean.reduce((sum, value) => sum + value, 0) / clean.length;
		}

		function formatDisplayText(value) {
			if (value === null || value === undefined || value === '') { return 'None'; }
			const source = String(value);
			const compact = source.replace(/[^A-Za-z0-9]/g, '').toLowerCase();
			const directOverrides = {
				azureadjoined: 'Entra ID Joined',
				hybridazureadjoined: 'Hybrid Entra ID Joined',
				activedirectoryjoined: 'Active Directory Joined',
				workplacejoined: 'Workplace Joined'
			};
			if (directOverrides[compact]) { return directOverrides[compact]; }
			const formatted = source
				.replace(/[_-]+/g, ' ')
				.replace(/([A-Z]+)([A-Z][a-z])/g, '$1 $2')
				.replace(/([a-z0-9])([A-Z])/g, '$1 $2')
				.split(/\s+/)
				.filter(Boolean)
				.map((part) => part.charAt(0).toUpperCase() + part.slice(1))
				.join(' ');
			return formatted.replace(/\bOne Drive\b/g, 'OneDrive').replace(/\bV Net\b/g, 'VNET');
		}

		function formatValue(value) {
			if (value === null || value === undefined || value === '') { return 'None'; }
			if (typeof value === 'boolean') { return value ? 'Yes' : 'No'; }
			if (typeof value === 'number') {
				if (Math.abs(value) >= 1000) { return value.toLocaleString(); }
				return Number.isInteger(value) ? String(value) : value.toFixed(2).replace(/\.00$/, '');
			}
			if (Array.isArray(value)) { return value.length ? value.map((item) => formatValue(item)).join(', ') : 'None'; }
			if (isPlainObject(value)) { return Object.keys(value).length + ' field(s)'; }
			return String(value);
		}

		function formatPercentValue(value) {
			const numeric = toNumber(value);
			if (numeric === null) { return 'n/a'; }
			return formatValue(numeric) + '%';
		}

		function formatFieldValue(key, value) {
			const compactKey = key ? String(key).replace(/[^A-Za-z0-9]/g, '').toLowerCase() : '';
			if (compactKey === 'maxsessionlimit') {
				const numeric = toNumber(value);
				if (numeric !== null && numeric >= 999999) { return 'No Limit Set'; }
			}
			if (new Set(['avgcpupercent', 'avgmemusedpercent', 'p95cpupercent', 'p95memusedpercent']).has(compactKey)) {
				return formatPercentValue(value);
			}
			return formatValue(value);
		}

		function resolveUnavailableMetricText(key, value, context) {
			if (!(value === null || value === undefined || value === '')) { return null; }
			if (!context || typeof context !== 'object') { return null; }
			const compactKey = key ? String(key).replace(/[^A-Za-z0-9]/g, '').toLowerCase() : '';
			const statusGroups = [
				{
					statusKey: 'SessionsStatus',
					columns: new Set(['peakconcurrentsessions', 'dailypeakbreakdown'])
				},
				{
					statusKey: 'MetricStatus',
					columns: new Set(['dailyaverageusers', 'datapointcount', 'dailybreakdown'])
				},
				{
					statusKey: context.QueryStatus !== undefined ? 'QueryStatus' : 'DiagnosticsStatus',
					columns: new Set(['lastsuccessfulconnection', 'totalerrors', 'totalfailedconnections', 'shortpatherrors', 'shortpathupgradeevents', 'hostregistrationevents', 'hostregistrationhealthsummary', 'toperrors', 'transporttypebreakdown', 'hostregistrationbreakdown'])
				}
			];
			const match = statusGroups.find((group) => group.columns.has(compactKey));
			if (!match) { return null; }
			const status = context[match.statusKey];
			if (!status) { return null; }
			if (/^NoDiagnosticSettings$/i.test(status)) { return 'Logging disabled'; }
			if (/^NoUserActivity$/i.test(status)) { return 'No activity in period'; }
			if (/^NoData$/i.test(status)) { return 'Unavailable - no data'; }
			if (/^Error:/i.test(status)) { return 'Unavailable - query error'; }
			return null;
		}

		function hasStructuredTableValue(value) {
			if (value === null || value === undefined) { return false; }
			if (Array.isArray(value)) {
				return value.some((item) => item !== null && typeof item === 'object');
			}
			return typeof value === 'object';
		}

		function summarizeStructuredValue(column, value) {
			if (Array.isArray(value)) {
				if (!value.length) { return 'No details'; }
				if (value.every((item) => item === null || ['string', 'number', 'boolean'].includes(typeof item))) {
					return formatFieldValue(column, value);
				}
				return value.length + (value.length === 1 ? ' item' : ' items');
			}
			if (isPlainObject(value)) {
				const parts = [];
				if (value.Name) {
					parts.push(String(value.Name));
				}
				if (Array.isArray(value.Routes)) {
					parts.push(value.Routes.length + (value.Routes.length === 1 ? ' route' : ' routes'));
				}
				if (Array.isArray(value.CustomRules)) {
					parts.push(value.CustomRules.length + (value.CustomRules.length === 1 ? ' custom rule' : ' custom rules'));
				}
				if (!parts.length) {
					parts.push(Object.keys(value).length + ' field(s)');
				}
				return parts.join(' • ');
			}
			return formatFieldValue(column, value);
		}

		function createStructuredSummary(column, value) {
			const summary = document.createElement('span');
			summary.className = 'detail-summary';
			summary.textContent = summarizeStructuredValue(column, value);
			return summary;
		}

		function formatLabel(value) {
			if (value === null || value === undefined || value === '') { return 'Unnamed'; }
			const source = String(value);
			const compact = source.replace(/[^A-Za-z0-9]/g, '').toLowerCase();
			const directOverrides = {
				fslogix: 'FSLogix',
				entrasso: 'Entra SSO',
				onedrive: 'OneDrive',
				ad: 'AD',
				avd: 'AVD',
				authorizedusercount: 'Authorised User Count',
				authorizeduserstatus: 'Authorised User Status',
				authorizeduseridcount: 'Authorised User ID Count',
				licensesummarystatus: 'Licence Summary Status',
				licensesummaryusercount: 'Licence Summary User Count',
				licensesummary: 'Licence Summary',
				vnet: 'VNET',
				vnetname: 'VNET Name',
				vnetresourcegroup: 'VNET Resource Group',
				vnetaddressprefixes: 'VNET Address Prefixes',
				vnetcustomdnsservers: 'VNET Custom DNS Servers',
				laps: 'LAPS',
				teamsmediaoptimization: 'Teams Media Optimisations',
				teamsmediaoptimisation: 'Teams Media Optimisations',
				activedirectorydependencies: 'Active Directory Dependencies',
				avdconnectivity: 'AVD Connectivity',
				rdpshortpath: 'RDP Shortpath',
				rdpredirection: 'RDP Redirection',
				usershellfoldersavailable: 'User Shell Folders Available'
			};
			if (directOverrides[compact]) { return directOverrides[compact]; }
			const wordOverrides = {
				ad: 'AD',
				api: 'API',
				app: 'App',
				apps: 'Apps',
				arm: 'ARM',
				avd: 'AVD',
				cpu: 'CPU',
				fs: 'FS',
				gp: 'GP',
				html: 'HTML',
				id: 'ID',
				ip: 'IP',
				ips: 'IPs',
				intune: 'Intune',
				json: 'JSON',
				kfm: 'KFM',
				laps: 'LAPS',
				nic: 'NIC',
				nsg: 'NSG',
				os: 'OS',
				rdp: 'RDP',
				sku: 'SKU',
				sso: 'SSO',
				upn: 'UPN',
				url: 'URL',
				vnet: 'VNET',
				vm: 'VM'
			};
			const formatted = source
				.replace(/[_-]+/g, ' ')
				.replace(/([A-Z]+)([A-Z][a-z])/g, '$1 $2')
				.replace(/([a-z0-9])([A-Z])/g, '$1 $2')
				.split(/\s+/)
				.filter(Boolean)
				.map((part) => {
					const lower = part.toLowerCase();
					if (wordOverrides[lower]) { return wordOverrides[lower]; }
					return /^[A-Z0-9]{2,}$/.test(part) ? part : part.charAt(0).toUpperCase() + part.slice(1);
				})
				.join(' ');
			return formatted.replace(/\bOne Drive\b/g, 'OneDrive').replace(/\bV Net\b/g, 'VNET');
		}

		function summarizeItemLabel(item, index) {
			if (isPlainObject(item)) {
				const preferredKeys = ['DisplayName', 'Name', 'Hostname', 'UPN', 'UserPrincipalName', 'Path', 'ComponentName', 'TransportType', 'SkuName'];
				for (const key of preferredKeys) {
					if (item[key]) { return String(item[key]); }
				}
			}
			return 'Item ' + (index + 1);
		}

		function summarizeNestedValue(value) {
			if (Array.isArray(value)) {
				return value.length + (value.length === 1 ? ' item' : ' items');
			}
			if (isPlainObject(value)) {
				const count = Object.keys(value).length;
				return count + (count === 1 ? ' field' : ' fields');
			}
			return formatValue(value);
		}

		function isWideSection(key, value, kind) {
			if (kind === 'host') {
				if (new Set(['Machine', 'ActiveDirectoryDependencies', 'AvdConnectivity', 'GroupPolicy', 'UserProfileExperience']).has(key)) { return true; }
				if (new Set(['JoinState', 'EntraSso', 'FSLogix', 'RdpShortpath', 'RdpRedirection', 'Antivirus', 'IntuneEnrollment', 'Laps', 'TeamsMediaOptimization', 'UniversalPrint', 'TimeSource', 'Printers']).has(key)) { return false; }
			}
			if (kind === 'metrics' && new Set(['__ExecutionContext', '__Licensing', 'ArmCallStats']).has(key)) { return true; }
			if (Array.isArray(value)) { return true; }
			if (!isPlainObject(value)) { return false; }
			const keys = Object.keys(value);
			if (keys.length > (kind === 'host' ? 7 : 5)) { return true; }
			return keys.some((childKey) => {
				const child = value[childKey];
				return Array.isArray(child) || isPlainObject(child);
			});
		}

		function setDetailsState(root, open) {
			root.querySelectorAll('details').forEach((node) => {
				node.open = open;
			});
		}

		function createSectionActions(body) {
			const detailNodes = Array.from(body.querySelectorAll('details'));
			if (!detailNodes.length) { return null; }
			const actions = document.createElement('div');
			actions.className = 'section-actions';
			const button = document.createElement('button');
			button.type = 'button';
			button.className = 'section-button';
			const syncLabel = () => {
				button.textContent = detailNodes.every((node) => node.open) ? 'Collapse All' : 'Expand All';
			};
			button.addEventListener('click', () => {
				const shouldOpen = !detailNodes.every((node) => node.open);
				setDetailsState(body, shouldOpen);
				syncLabel();
			});
			detailNodes.forEach((node) => node.addEventListener('toggle', syncLabel));
			syncLabel();
			actions.appendChild(button);
			return actions;
		}

		function positionWarningTooltip(node) {
			if (!node) { return; }
			const viewportWidth = window.innerWidth || document.documentElement.clientWidth || 0;
			const viewportHeight = window.innerHeight || document.documentElement.clientHeight || 0;
			const tooltipWidth = Math.min(220, Math.max(170, viewportWidth - 40));
			const estimatedTooltipHeight = 92;
			const stickyNav = document.querySelector('.report-nav');
			node.style.setProperty('--warning-tooltip-width', tooltipWidth + 'px');
			node.classList.remove('tooltip-flip', 'tooltip-above');
			const rect = node.getBoundingClientRect();
			const navRect = stickyNav ? stickyNav.getBoundingClientRect() : null;
			const overflowsRight = rect.left - 10 + tooltipWidth > viewportWidth - 16;
			if (overflowsRight) {
				node.classList.add('tooltip-flip');
			}
			const overflowsBottom = rect.bottom + 8 + estimatedTooltipHeight > viewportHeight - 12;
			if (overflowsBottom) {
				node.classList.add('tooltip-above');
			} else if (navRect && rect.top < navRect.bottom + 6) {
				node.classList.add('tooltip-below-nav');
			} else {
				node.classList.remove('tooltip-below-nav');
			}
		}

		function positionTitleFlagTooltip(flag, tooltipNode) {
			if (!flag || !tooltipNode) { return; }
			const viewportWidth = window.innerWidth || document.documentElement.clientWidth || 0;
			const viewportHeight = window.innerHeight || document.documentElement.clientHeight || 0;
			const nav = document.querySelector('.report-nav');
			const navRect = nav ? nav.getBoundingClientRect() : null;
			const flagRect = flag.getBoundingClientRect();
			const tooltipWidth = Math.min(320, Math.max(220, viewportWidth - 32));
			const gap = 10;
			const estimatedHeight = Math.max(96, tooltipNode.offsetHeight || 0);
			const centerX = flagRect.left + (flagRect.width / 2);
			const minCenterX = 16 + (tooltipWidth / 2);
			const maxCenterX = Math.max(minCenterX, viewportWidth - 16 - (tooltipWidth / 2));
			const resolvedCenterX = Math.min(maxCenterX, Math.max(minCenterX, centerX));
			const navBottom = navRect ? navRect.bottom + 8 : 8;
			let top = flagRect.bottom + gap;
			let placement = 'below';
			if (flagRect.top - gap - estimatedHeight >= navBottom) {
				top = flagRect.top - gap - estimatedHeight;
				placement = 'above';
			} else if (top + estimatedHeight > viewportHeight - 12) {
				top = Math.max(navBottom, viewportHeight - 12 - estimatedHeight);
			}
			tooltipNode.style.position = 'fixed';
			tooltipNode.style.left = resolvedCenterX + 'px';
			tooltipNode.style.top = top + 'px';
			tooltipNode.style.width = tooltipWidth + 'px';
			tooltipNode.style.zIndex = '40';
			tooltipNode.style.transform = 'translateX(-50%)';
			tooltipNode.style.opacity = '1';
			tooltipNode.style.visibility = 'visible';
			tooltipNode.dataset.placement = placement;
		}

		function orderedSectionEntries(kind, source) {
			const order = kind === 'metrics'
				? ['__ExecutionContext', '__Authentication', 'HostPools', '__Licensing', 'ArmCallStats']
				: ['__ExecutionContext', 'Machine', 'JoinState', 'EntraSso', 'FSLogix', 'UserProfileExperience', 'RdpShortpath', 'RdpRedirection', 'ActiveDirectoryDependencies', 'AvdConnectivity', 'GroupPolicy', 'Antivirus', 'IntuneEnrollment', 'Laps', 'TeamsMediaOptimization', 'UniversalPrint', 'TimeSource', 'Printers'];
			const rank = new Map(order.map((key, index) => [key, index]));
			const entries = Object.entries(source);
			if (kind === 'metrics') {
				entries.push(['__ExecutionContext', {
					CustomerAbbreviation: data.CustomerAbbreviation,
					CollectedAt: data.CollectedAt,
					MetricPeriodStart: data.MetricPeriodStart,
					MetricPeriodEnd: data.MetricPeriodEnd,
					LookbackDays: data.LookbackDays,
					ExcludeWeekends: data.ExcludeWeekends,
					PeakHoursOnly: data.PeakHoursOnly,
					UtcOffsetHours: data.UtcOffsetHours,
					GeneratedBy: data.GeneratedBy,
					ProjectCode: data.ProjectCode,
					CommandOptions: data.CommandOptions ? {
						SubscriptionId: data.CommandOptions.SubscriptionId,
						HostPoolName: data.CommandOptions.HostPoolName,
						RunLocalDiscovery: data.CommandOptions.RunLocalDiscovery,
						InlineLocalScript: data.CommandOptions.InlineLocalScript,
						NoGpresult: data.CommandOptions.NoGpresult,
						SkipLicenceCheck: data.CommandOptions.SkipLicenceCheck,
						RunAsUser: data.CommandOptions.RunAsUser,
						GitHubBranch: data.CommandOptions.GitHubBranch,
						LocalDiscoveryTimeout: data.CommandOptions.LocalDiscoveryTimeout,
						OutputDirectory: data.CommandOptions.OutputDirectory,
						ScanStorageAccounts: data.CommandOptions.ScanStorageAccounts
					} : null
				}]);
				if (data.AuthenticatedIdentity) {
					entries.push(['__Authentication', {
						DisplayName: data.AuthenticatedIdentity.DisplayName,
						AccountId: data.AuthenticatedIdentity.AccountId,
						PrincipalType: data.AuthenticatedIdentity.PrincipalType,
						UserPrincipalName: data.AuthenticatedIdentity.UserPrincipalName,
						UserType: data.AuthenticatedIdentity.UserType,
						PrincipalObjectId: data.AuthenticatedIdentity.PrincipalObjectId,
						TenantId: data.AuthenticatedIdentity.TenantId,
						Environment: data.AuthenticatedIdentity.Environment,
						DefaultSubscriptionName: data.AuthenticatedIdentity.DefaultSubscriptionName,
						DefaultSubscriptionId: data.AuthenticatedIdentity.DefaultSubscriptionId,
						GraphStatus: data.AuthenticatedIdentity.GraphStatus,
						DirectoryRoleStatus: data.AuthenticatedIdentity.DirectoryRoleStatus,
						DirectoryRoles: data.AuthenticatedIdentity.DirectoryRoles,
						IsGlobalAdministrator: data.AuthenticatedIdentity.IsGlobalAdministrator,
						SubscriptionAccessStatus: data.AuthenticatedIdentity.SubscriptionAccessStatus,
						SubscriptionAccess: data.AuthenticatedIdentity.SubscriptionAccess
					}]);
				}
				entries.push(['__Licensing', {
					LicenseSummaryStatus: data.LicenseSummaryStatus,
					LicenseSummaryUserCount: data.LicenseSummaryUserCount,
					UnlicensedUserCount: data.UnlicensedUserCount,
					LicenseSummary: data.LicenseSummary,
					UnlicensedUsers: data.UnlicensedUsers
				}]);
			}
			if (kind === 'host') {
				entries.push(['__ExecutionContext', {
					CustomerAbbreviation: data.CustomerAbbreviation,
					CollectedAt: data.CollectedAt,
					CollectionMode: data.CollectionMode,
					RunningAsAccount: data.RunningAsAccount,
					DiscoveryType: data.DiscoveryType,
					GeneratedBy: data.GeneratedBy,
					ProjectCode: data.ProjectCode,
					PrimaryApplicationsOnly: data.PrimaryApplicationsOnly
				}]);
			}
			return entries.sort(([leftKey], [rightKey]) => {
				const leftRank = rank.has(leftKey) ? rank.get(leftKey) : 999;
				const rightRank = rank.has(rightKey) ? rank.get(rightKey) : 999;
				if (leftRank !== rightRank) { return leftRank - rightRank; }
				return leftKey.localeCompare(rightKey);
			});
		}

		function createBadge(text, variant) {
			const badge = document.createElement('span');
			badge.className = 'badge' + (variant ? ' ' + variant : '');
			badge.textContent = text;
			return badge;
		}

		function createTitleFlag(glyph, label, tone, tooltip, order) {
			const flag = document.createElement('span');
			flag.className = 'report-title-flag' + (tone ? ' ' + tone : '');
			const labelNode = document.createElement('span');
			labelNode.className = 'report-title-flag-label';
			labelNode.textContent = label;
			if (glyph) {
				flag.dataset.flagCode = glyph;
			}
			if (order !== undefined && order !== null) {
				flag.style.order = String(order);
			}
			if (tooltip) {
				const tooltipText = String(tooltip);
				const tooltipNode = document.createElement('span');
				tooltipNode.className = 'report-title-flag-tooltip';
				tooltipNode.textContent = tooltipText;
				if (document.body) {
					document.body.appendChild(tooltipNode);
				}
				flag.classList.add('has-tooltip');
				flag.setAttribute('tabindex', '0');
				flag.setAttribute('aria-label', label + '. ' + tooltipText);
				flag.append(labelNode);
				const syncTooltipPosition = () => {
					if (flag.matches(':hover') || document.activeElement === flag) {
						positionTitleFlagTooltip(flag, tooltipNode);
					}
				};
				const showTooltip = () => positionTitleFlagTooltip(flag, tooltipNode);
				const hideTooltip = () => {
					tooltipNode.style.opacity = '0';
					tooltipNode.style.visibility = 'hidden';
					tooltipNode.style.position = '';
					tooltipNode.style.left = '';
					tooltipNode.style.top = '';
					tooltipNode.style.width = '';
					tooltipNode.style.zIndex = '';
					tooltipNode.style.transform = '';
					delete tooltipNode.dataset.placement;
				};
				flag.addEventListener('mouseenter', showTooltip);
				flag.addEventListener('pointerenter', showTooltip);
				flag.addEventListener('focus', showTooltip);
				flag.addEventListener('mousemove', syncTooltipPosition);
				flag.addEventListener('pointermove', syncTooltipPosition);
				flag.addEventListener('mouseleave', hideTooltip);
				flag.addEventListener('pointerleave', hideTooltip);
				flag.addEventListener('blur', hideTooltip);
				window.addEventListener('resize', syncTooltipPosition);
				window.addEventListener('scroll', syncTooltipPosition, { passive: true });
				return flag;
			}
			flag.append(labelNode);
			return flag;
		}

		function poolHasLogAnalyticsGraphData(pool) {
			if (!isPlainObject(pool)) { return false; }
			return ['CpuDailyBreakdown', 'MemoryDailyBreakdown'].some((key) => normalizeCollection(pool[key]).length > 0);
		}

		function poolHasCollectedLogAnalyticsSeries(pool) {
			if (!isPlainObject(pool)) { return false; }
			if (poolHasLogAnalyticsGraphData(pool)) { return true; }
			return ['DailyBreakdown', 'DailyPeakBreakdown'].some((key) => normalizeCollection(pool[key]).length > 0);
		}

		function poolHasUsageData(pool) {
			if (!isPlainObject(pool)) { return false; }
			if (normalizeCollection(pool.DailyBreakdown).length || normalizeCollection(pool.DailyPeakBreakdown).length) { return true; }
			if (['DailyAverageUsers', 'PeakConcurrentSessions', 'DataPointCount'].some((key) => toNumber(pool[key]) !== null)) { return true; }
			const statuses = [pool.MetricStatus, pool.SessionsStatus]
				.map((value) => String(value || '').trim())
				.filter(Boolean);
			return statuses.some((status) => !/^NoDiagnosticSettings$/i.test(status) && !/^Error:/i.test(status));
		}

		function poolHasPerformanceData(pool) {
			if (!isPlainObject(pool)) { return false; }
			if (poolHasLogAnalyticsGraphData(pool)) { return true; }
			return ['AvgCpuPercent', 'P95CpuPercent', 'P99CpuPercent', 'AvgMemUsedPercent', 'P95MemUsedPercent', 'P99MemUsedPercent']
				.some((key) => toNumber(pool[key]) !== null);
		}

		function poolHasDiagnosticInsightsData(pool) {
			if (!isPlainObject(pool) || !isPlainObject(pool.InsightsDiagnostics)) { return false; }
			const status = String(pool.InsightsDiagnostics.QueryStatus || '').trim();
			if (!status || /^NoDiagnosticSettings$/i.test(status)) { return false; }
			return true;
		}

		function metricsReportType() {
			const hostPools = normalizeCollection(data.HostPools);
			const isEnhanced = hostPools.some((pool) => poolHasCollectedLogAnalyticsSeries(pool));
			if (isEnhanced) {
				return {
					key: 'enhanced',
					glyph: 'ER',
					label: 'Enhanced Report',
					tone: 'report-tier-enhanced',
					tooltip: 'Includes Log Analytics-backed usage or diagnostics data for at least one host pool. Usage and performance visuals are shown where that data was collected.'
				};
			}
			return {
				key: 'basic',
				glyph: 'BR',
				label: 'Basic Report',
				tone: 'report-tier-basic',
				tooltip: 'No host pools returned Log Analytics-backed usage graph data for this report, so usage and performance KPIs are omitted.'
			};
		}

		function reportTitleFlags(kind) {
			if (kind !== 'metrics') { return []; }
			const flags = [];
			if (data.ExcludeWeekends) {
				flags.push({ glyph: 'EW', label: 'Exclude Weekends' });
			}
			if (data.PeakHoursOnly) {
				flags.push({ glyph: 'PH', label: 'Peak Hours Only' });
			}
			if (data.CommandOptions && data.CommandOptions.SkipLicenceCheck) {
				flags.push({ glyph: 'LC', label: 'Licence Check Skipped', tone: 'warning' });
			}
			flags.push({ ...metricsReportType(), order: 20 });
			return flags;
		}

		function setReportTitle(kind) {
			const title = document.getElementById('report-title');
			if (!title) { return; }
			title.innerHTML = '';
			const text = document.createElement('span');
			text.className = 'report-title-text';
			text.textContent = REPORT_TITLE;
			title.appendChild(text);
			const flags = reportTitleFlags(kind);
			if (!flags.length) { return; }
			const wrap = document.createElement('span');
			wrap.className = 'report-title-flags';
			flags.forEach((flag) => wrap.appendChild(createTitleFlag(flag.glyph, flag.label, flag.tone, flag.tooltip, flag.order)));
			title.appendChild(wrap);
		}

		function createCard(label, value, detail) {
			const article = document.createElement('article');
			article.className = 'card';
			const eyebrow = document.createElement('p');
			eyebrow.className = 'eyebrow';
			eyebrow.textContent = label;
			const metric = document.createElement('p');
			metric.className = 'metric';
			metric.textContent = typeof value === 'string' ? value : formatValue(value);
			const subtle = document.createElement('p');
			subtle.className = 'subtle';
			subtle.textContent = detail || '';
			article.append(eyebrow, metric, subtle);
			return article;
		}

		function createMetricCard(label, value, detail, variant, valueKey, context) {
			const resolvedValue = valueKey ? (resolveUnavailableMetricText(valueKey, value, context) || value) : value;
			const card = createCard(label, resolvedValue, detail);
			if (variant) { card.classList.add(variant); }
			return card;
		}

		function prefersReducedMotion() {
			return !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);
		}

		function createTickerValueNode(text, stateClass) {
			const valueNode = document.createElement('span');
			valueNode.className = 'metric-ticker-value' + (stateClass ? (' ' + stateClass) : '');
			valueNode.textContent = text;
			return valueNode;
		}

		function parseMetricTickerValue(value) {
			if (typeof value === 'number' && Number.isFinite(value)) { return value; }
			const normalized = String(value || '').replace(/,/g, '').replace(/%$/, '').trim();
			if (!normalized) { return null; }
			const parsed = Number(normalized);
			return Number.isFinite(parsed) ? parsed : null;
		}

		function ensureMetricTicker(metric) {
			let track = metric.querySelector('.metric-ticker-track');
			if (track) { return track; }
			const initialText = metric.textContent || '';
			metric.textContent = '';
			metric.classList.add('has-ticker');
			track = document.createElement('span');
			track.className = 'metric-ticker-track';
			track.appendChild(createTickerValueNode(initialText, 'is-current'));
			metric.appendChild(track);
			return track;
		}

		function commitMetricTicker(metric, nextText) {
			const track = ensureMetricTicker(metric);
			track.innerHTML = '';
			track.appendChild(createTickerValueNode(nextText, 'is-current'));
			metric.classList.remove('is-ticker-animating');
			metric.classList.remove('is-ticker-up', 'is-ticker-down');
			metric.__tickerNumeric = parseMetricTickerValue(nextText);
			if (metric.__tickerFrame) {
				cancelAnimationFrame(metric.__tickerFrame);
				metric.__tickerFrame = null;
			}
			if (metric.__tickerTimer) {
				clearTimeout(metric.__tickerTimer);
				metric.__tickerTimer = null;
			}
		}

		function animateMetricTicker(metric, nextText) {
			const resolvedText = String(nextText || '');
			const track = ensureMetricTicker(metric);
			const current = track.querySelector('.metric-ticker-value.is-current') || track.lastElementChild;
			const currentText = current ? current.textContent : '';
			const currentNumeric = metric.__tickerNumeric !== undefined ? metric.__tickerNumeric : parseMetricTickerValue(currentText);
			const nextNumeric = parseMetricTickerValue(resolvedText);
			const direction = nextNumeric !== null && currentNumeric !== null && nextNumeric !== currentNumeric
				? (nextNumeric > currentNumeric ? 'up' : 'down')
				: 'up';
			if (currentText === resolvedText) { return; }
			if (prefersReducedMotion() || !metric.isConnected) {
				commitMetricTicker(metric, resolvedText);
				return;
			}
			const token = (metric.__tickerToken || 0) + 1;
			metric.__tickerToken = token;
			if (metric.__tickerFrame) {
				cancelAnimationFrame(metric.__tickerFrame);
				metric.__tickerFrame = null;
			}
			if (metric.__tickerTimer) {
				clearTimeout(metric.__tickerTimer);
				metric.__tickerTimer = null;
			}
			track.replaceChildren();
			metric.classList.remove('is-ticker-up', 'is-ticker-down');
			metric.classList.add(direction === 'down' ? 'is-ticker-down' : 'is-ticker-up');
			const outgoing = current || createTickerValueNode(currentText, 'is-current');
			outgoing.classList.remove('is-current');
			outgoing.classList.remove('is-next', 'is-ticker-in');
			outgoing.classList.add('is-previous');
			const incoming = createTickerValueNode(resolvedText, 'is-next');
			track.append(outgoing, incoming);
			track.getBoundingClientRect();
			metric.classList.add('is-ticker-animating');
			outgoing.classList.add('is-ticker-out');
			incoming.classList.add('is-ticker-in');
			const finalize = () => {
				if (metric.__tickerToken !== token) { return; }
				commitMetricTicker(metric, resolvedText);
			};
			incoming.addEventListener('transitionend', finalize, { once: true });
			metric.__tickerTimer = setTimeout(finalize, 420);
		}

		function createUpdatableMetricCard(label, value, detail, variant, valueKey, context) {
			const card = createMetricCard(label, value, detail, variant, valueKey, context);
			const metric = card.querySelector('.metric');
			const subtle = card.querySelector('.subtle');
			ensureMetricTicker(metric);
			return {
				element: card,
				set(nextValue, nextDetail) {
					const resolvedValue = valueKey ? (resolveUnavailableMetricText(valueKey, nextValue, context) || nextValue) : nextValue;
					animateMetricTicker(metric, typeof resolvedValue === 'string' ? resolvedValue : formatValue(resolvedValue));
					if (typeof nextDetail === 'string') {
						subtle.textContent = nextDetail;
					}
				}
			};
		}

		function parseDailyMetricSeries(rows, valueKey, dayKey) {
			const resolvedDayKey = dayKey || 'Day';
			return normalizeCollection(rows)
				.filter((item) => isPlainObject(item) && item[resolvedDayKey])
				.map((item) => ({ day: String(item[resolvedDayKey]), value: toNumber(item[valueKey]) }))
				.filter((item) => item.day && item.value !== null)
				.sort((left, right) => left.day.localeCompare(right.day));
		}

		function quantile(values, percentile) {
			const clean = values.filter((value) => typeof value === 'number' && Number.isFinite(value)).slice().sort((left, right) => left - right);
			if (!clean.length) { return null; }
			if (clean.length === 1) { return clean[0]; }
			const rank = Math.max(0, Math.min(clean.length - 1, (clean.length - 1) * percentile));
			const lowerIndex = Math.floor(rank);
			const upperIndex = Math.ceil(rank);
			if (lowerIndex === upperIndex) { return clean[lowerIndex]; }
			const weight = rank - lowerIndex;
			return clean[lowerIndex] + ((clean[upperIndex] - clean[lowerIndex]) * weight);
		}

		function formatTrendShortDate(value) {
			const date = parseIsoDate(value);
			if (!date) { return String(value || ''); }
			return date.toLocaleDateString(undefined, { month: 'short', day: 'numeric', timeZone: 'UTC' });
		}

		function formatTrendRangeLabel(startDay, endDay) {
			if (!startDay || !endDay) { return 'No date range selected'; }
			if (startDay === endDay) { return formatTrendShortDate(startDay); }
			return formatTrendShortDate(startDay) + ' - ' + formatTrendShortDate(endDay);
		}

		function buildPoolTrendModel(pool) {
			const cpuSeries = parseDailyMetricSeries(pool && pool.CpuDailyBreakdown, 'AvgCpuPercent');
			const memorySeries = parseDailyMetricSeries(pool && pool.MemoryDailyBreakdown, 'AvgMemUsedPercent');
			const userSeries = parseDailyMetricSeries(pool && pool.DailyBreakdown, 'UniqueUsers', 'Date');
			const peakSeries = parseDailyMetricSeries(pool && pool.DailyPeakBreakdown, 'PeakConcurrentSessions', 'Date');
			const averageHostsOnPerDay = toNumber(pool && pool.AverageHostsOnPerDay);
			const daySet = new Set();
			[cpuSeries, memorySeries, userSeries, peakSeries].forEach((series) => {
				series.forEach((item) => daySet.add(item.day));
			});
			const days = expandTrendDays(Array.from(daySet).sort((left, right) => left.localeCompare(right)));
			if (!days.length) { return null; }
			const createSeriesMap = (series) => new Map(series.map((item) => [item.day, item.value]));
			const cpuMap = createSeriesMap(cpuSeries);
			const memoryMap = createSeriesMap(memorySeries);
			const userMap = createSeriesMap(userSeries);
			const peakMap = createSeriesMap(peakSeries);
			const rows = days.map((day) => ({
				day,
				cpu: cpuMap.has(day) ? cpuMap.get(day) : null,
				memory: memoryMap.has(day) ? memoryMap.get(day) : null,
				users: userMap.has(day) ? userMap.get(day) : null,
				peak: peakMap.has(day) ? peakMap.get(day) : null
			}));
			return {
				rows,
				cpuSeries,
				memorySeries,
				userSeries,
				peakSeries,
				averageHostsOnPerDay
			};
		}

		function summarizePoolTrendSelection(model, startIndex, endIndex) {
			if (!model || !Array.isArray(model.rows) || !model.rows.length) { return null; }
			const safeStart = Math.max(0, Math.min(startIndex, model.rows.length - 1));
			const safeEnd = Math.max(safeStart, Math.min(endIndex, model.rows.length - 1));
			const selectedRows = model.rows.slice(safeStart, safeEnd + 1);
			const cpuValues = selectedRows.map((row) => row.cpu).filter((value) => value !== null);
			const memoryValues = selectedRows.map((row) => row.memory).filter((value) => value !== null);
			const userValues = selectedRows.map((row) => row.users).filter((value) => value !== null);
			const peakValues = selectedRows.map((row) => row.peak).filter((value) => value !== null);
			const startDay = selectedRows.length ? selectedRows[0].day : null;
			const endDay = selectedRows.length ? selectedRows[selectedRows.length - 1].day : null;
			return {
				startIndex: safeStart,
				endIndex: safeEnd,
				startDay,
				endDay,
				dayCount: selectedRows.length,
				label: formatTrendRangeLabel(startDay, endDay),
				cpuAverage: average(cpuValues),
				cpuP95: quantile(cpuValues, 0.95),
				cpuP99: quantile(cpuValues, 0.99),
				memoryAverage: average(memoryValues),
				memoryP95: quantile(memoryValues, 0.95),
				memoryP99: quantile(memoryValues, 0.99),
				dailyUsersAverage: average(userValues),
				peakUsers: peakValues.length ? Math.max.apply(null, peakValues) : null,
				isFullRange: safeStart === 0 && safeEnd === (model.rows.length - 1)
			};
		}

		function parseIsoDate(value) {
			const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(value || ''));
			if (!match) { return null; }
			const year = Number(match[1]);
			const month = Number(match[2]) - 1;
			const day = Number(match[3]);
			return new Date(Date.UTC(year, month, day));
		}

		function formatIsoDate(date) {
			return date.toISOString().slice(0, 10);
		}

		function expandTrendDays(days) {
			if (!Array.isArray(days) || !days.length) { return []; }
			const parsedDays = days.map(parseIsoDate).filter(Boolean).sort((left, right) => left - right);
			if (!parsedDays.length) { return []; }
			const expanded = [];
			const cursor = new Date(parsedDays[0].getTime());
			const end = parsedDays[parsedDays.length - 1];
			while (cursor <= end) {
				expanded.push(formatIsoDate(cursor));
				cursor.setUTCDate(cursor.getUTCDate() + 1);
			}
			return expanded;
		}

		function roundTrendMaximum(value) {
			const numeric = toNumber(value);
			if (numeric === null || numeric <= 0) { return 10; }
			return Math.min(100, Math.max(10, Math.ceil(numeric / 10) * 10));
		}

		function createSvgNode(name, attributes) {
			const node = document.createElementNS('http://www.w3.org/2000/svg', name);
			Object.entries(attributes || {}).forEach(([key, value]) => {
				if (value !== null && value !== undefined) {
					node.setAttribute(key, String(value));
				}
			});
			return node;
		}

		function buildTrendPath(rows, valueKey, xForIndex, yForValue) {
			let path = '';
			let segmentOpen = false;
			rows.forEach((row, index) => {
				const value = toNumber(row[valueKey]);
				if (value === null) {
					segmentOpen = false;
					return;
				}
				const x = xForIndex(index).toFixed(2);
				const y = yForValue(value).toFixed(2);
				path += (segmentOpen ? ' L ' : 'M ') + x + ' ' + y;
				segmentOpen = true;
			});
			return path.trim();
		}

		function buildMissingTrendSegments(rows, valueKey, xForIndex, yForValue) {
			const segments = [];
			let previousIndex = -1;
			let previousValue = null;
			rows.forEach((row, index) => {
				const value = toNumber(row[valueKey]);
				if (value === null) { return; }
				if (previousIndex >= 0 && index - previousIndex > 1 && previousValue !== null) {
					segments.push({
						d: 'M ' + xForIndex(previousIndex).toFixed(2) + ' ' + yForValue(previousValue).toFixed(2) +
							' L ' + xForIndex(index).toFixed(2) + ' ' + yForValue(value).toFixed(2)
					});
				}
				previousIndex = index;
				previousValue = value;
			});
			return segments;
		}

		function getTrendCoverageBounds(rows) {
			let startIndex = -1;
			let endIndex = -1;
			rows.forEach((row, index) => {
				if (toNumber(row.cpu) === null && toNumber(row.memory) === null) { return; }
				if (startIndex === -1) {
					startIndex = index;
				}
				endIndex = index;
			});
			return { startIndex, endIndex };
		}

		function formatTrendTooltipValue(value) {
			const numeric = toNumber(value);
			return numeric === null ? 'Omitted' : (formatValue(numeric) + '%');
		}

		let poolTrendRevealObserver = null;
		function wirePoolTrendReveal(card) {
			if (!card) { return; }
			if (window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
				card.classList.add('is-trend-visible');
				return;
			}
			if (typeof IntersectionObserver !== 'function') {
				card.classList.add('is-trend-visible');
				return;
			}
			if (!poolTrendRevealObserver) {
				poolTrendRevealObserver = new IntersectionObserver((entries, observer) => {
					entries.forEach((entry) => {
						if (!entry.isIntersecting) { return; }
						requestAnimationFrame(() => {
							entry.target.classList.add('is-trend-visible');
						});
						observer.unobserve(entry.target);
					});
				}, {
					threshold: 0.35,
					rootMargin: '0px 0px -10% 0px'
				});
			}
			poolTrendRevealObserver.observe(card);
		}

		function createPoolPerformanceTrend(model, onSelectionChange) {
			if (!model || !model.rows.length) { return null; }
			const rows = model.rows;
			const cpuSeries = model.cpuSeries;
			const memorySeries = model.memorySeries;
			const averageHostsOnPerDay = model.averageHostsOnPerDay;
			const trendCoverage = getTrendCoverageBounds(rows);
			const allValues = rows.flatMap((row) => [row.cpu, row.memory]).filter((value) => value !== null);
			if (!allValues.length) { return null; }
			const yMax = roundTrendMaximum(Math.max.apply(null, allValues));
			const width = 720;
			const height = 132;
			const margin = { top: 10, right: 18, bottom: 26, left: 42 };
			const plotWidth = width - margin.left - margin.right;
			const plotHeight = height - margin.top - margin.bottom;
			const xForIndex = (index) => margin.left + (rows.length <= 1 ? plotWidth / 2 : (index * plotWidth) / (rows.length - 1));
			const yForValue = (value) => margin.top + plotHeight - ((value / yMax) * plotHeight);

			const card = document.createElement('section');
			card.className = 'pool-trend-card';
			const head = document.createElement('div');
			head.className = 'pool-trend-head';
			const headText = document.createElement('div');
			headText.className = 'pool-trend-head-text';
			const title = document.createElement('h4');
			title.className = 'pool-trend-title';
			title.textContent = 'Daily CPU and Memory Trend';
			const copy = document.createElement('p');
			copy.className = 'pool-trend-copy';
			copy.textContent = 'Drag the range handles or tap points on the chart to focus the surrounding KPIs on a specific window.';
			headText.append(title, copy);
			head.append(headText);
			const selectionPill = document.createElement('div');
			selectionPill.className = 'pool-trend-selection-pill';
			const selectionWindow = document.createElement('strong');
			selectionWindow.className = 'pool-trend-selection-window';
			const selectionMeta = document.createElement('span');
			selectionMeta.className = 'pool-trend-selection-meta';
			selectionPill.append(selectionWindow, selectionMeta);
			head.appendChild(selectionPill);
			if (averageHostsOnPerDay !== null) {
				const hostBadge = document.createElement('span');
				hostBadge.className = 'badge neutral pool-trend-badge';
				hostBadge.textContent = 'Average Hosts/Day: ' + formatValue(averageHostsOnPerDay);
				head.appendChild(hostBadge);
			}

			const legend = document.createElement('div');
			legend.className = 'pool-trend-legend';
			[
				cpuSeries.length ? { label: 'CPU', color: '#5ea2ff' } : null,
				memorySeries.length ? { label: 'Memory', color: '#65c5d8' } : null,
				{ label: 'Omitted Data', color: '#d74c4c', dashed: true }
			].filter(Boolean).forEach((item) => {
				const legendItem = document.createElement('span');
				legendItem.className = 'pool-trend-legend-item';
				const dot = document.createElement('span');
				dot.className = 'pool-trend-legend-dot';
				if (item.dashed) {
					dot.classList.add('is-missing');
					dot.style.borderColor = item.color;
				} else {
					dot.style.background = item.color;
				}
				const text = document.createElement('span');
				text.textContent = item.label;
				legendItem.append(dot, text);
				legend.appendChild(legendItem);
			});

			const svg = createSvgNode('svg', {
				class: 'pool-trend-chart',
				viewBox: '0 0 ' + width + ' ' + height,
				role: 'img',
				'aria-label': 'Daily CPU and memory trend chart'
			});
			const plot = document.createElement('div');
			plot.className = 'pool-trend-plot';
			const yAxis = document.createElement('div');
			yAxis.className = 'pool-trend-y-axis';
			const xAxis = document.createElement('div');
			xAxis.className = 'pool-trend-x-axis';
			const tooltip = document.createElement('div');
			tooltip.className = 'pool-trend-tooltip';
			tooltip.setAttribute('aria-hidden', 'true');
			const selectionShadeLeft = createSvgNode('rect', {
				x: margin.left,
				y: margin.top,
				width: 0,
				height: plotHeight,
				class: 'pool-trend-selection-shade'
			});
			const selectionShadeRight = createSvgNode('rect', {
				x: width - margin.right,
				y: margin.top,
				width: 0,
				height: plotHeight,
				class: 'pool-trend-selection-shade'
			});
			const gapStartBand = createSvgNode('rect', {
				x: margin.left,
				y: margin.top,
				width: 0,
				height: plotHeight,
				class: 'pool-trend-gap-band'
			});
			const gapStartBoundary = createSvgNode('line', {
				x1: margin.left,
				y1: margin.top,
				x2: margin.left,
				y2: margin.top + plotHeight,
				class: 'pool-trend-gap-boundary'
			});
			const gapStartLabel = createSvgNode('text', {
				x: margin.left + 10,
				y: margin.top + 16,
				class: 'pool-trend-gap-label'
			});
			gapStartLabel.textContent = 'MISSING DATA';
			const selectionFrameLeft = createSvgNode('line', {
				x1: margin.left,
				y1: margin.top,
				x2: margin.left,
				y2: margin.top + plotHeight,
				class: 'pool-trend-selection-frame pool-trend-selection-frame-left',
				'aria-hidden': 'true'
			});
			const selectionFrameRight = createSvgNode('line', {
				x1: width - margin.right,
				y1: margin.top,
				x2: width - margin.right,
				y2: margin.top + plotHeight,
				class: 'pool-trend-selection-frame pool-trend-selection-frame-right',
				'aria-hidden': 'true'
			});
			const selectionClipId = 'pool-trend-selection-clip-' + Math.random().toString(36).slice(2, 10);
			const selectionClip = createSvgNode('clipPath', {
				id: selectionClipId,
				clipPathUnits: 'userSpaceOnUse'
			});
			const selectionClipRect = createSvgNode('rect', {
				x: margin.left,
				y: margin.top,
				width: plotWidth,
				height: plotHeight
			});
			selectionClip.appendChild(selectionClipRect);
			svg.appendChild(createSvgNode('defs', {})).appendChild(selectionClip);
			const baseSeriesLayer = createSvgNode('g', { class: 'pool-trend-series-layer pool-trend-series-layer-base' });
			baseSeriesLayer.style.color = 'var(--trend-muted-line)';
			const selectedSeriesLayer = createSvgNode('g', {
				class: 'pool-trend-series-layer pool-trend-series-layer-selected',
				'clip-path': 'url(#' + selectionClipId + ')'
			});
			const missingTrendNodes = [];
			const guide = createSvgNode('line', {
				x1: margin.left,
				y1: margin.top,
				x2: margin.left,
				y2: margin.top + plotHeight,
				class: 'pool-trend-guide hidden'
			});

			for (let tick = 0; tick <= 4; tick += 1) {
				const value = (yMax / 4) * tick;
				const y = yForValue(value);
				svg.appendChild(createSvgNode('line', {
					x1: margin.left,
					y1: y,
					x2: width - margin.right,
					y2: y,
					class: 'pool-trend-grid-line'
				}));
				const label = document.createElement('span');
				label.className = 'pool-trend-axis-label pool-trend-axis-label-y';
				label.textContent = Math.round(value) + '%';
				label.style.left = ((margin.left - 8) / width * 100).toFixed(2) + '%';
				label.style.top = ((y / height) * 100).toFixed(2) + '%';
				yAxis.appendChild(label);
			}
			if (trendCoverage.startIndex > 0) {
				const gapRightX = xForIndex(trendCoverage.startIndex);
				const gapWidth = Math.max(0, gapRightX - margin.left);
				gapStartBand.setAttribute('width', String(gapWidth));
				gapStartBoundary.setAttribute('x1', String(gapRightX));
				gapStartBoundary.setAttribute('x2', String(gapRightX));
				gapStartLabel.setAttribute('x', String(margin.left + (gapWidth / 2)));
				gapStartLabel.setAttribute('y', String(margin.top + (plotHeight / 2)));
				gapStartLabel.setAttribute('text-anchor', 'middle');
				gapStartLabel.setAttribute('dominant-baseline', 'middle');
				if (gapWidth < 96) {
					gapStartLabel.setAttribute('opacity', '0');
				}
			} else {
				gapStartLabel.setAttribute('opacity', '0');
			}
			svg.appendChild(selectionShadeLeft);
			svg.appendChild(selectionShadeRight);
			svg.appendChild(gapStartBand);
			svg.appendChild(gapStartBoundary);
			svg.appendChild(gapStartLabel);
			svg.appendChild(selectionFrameLeft);
			svg.appendChild(selectionFrameRight);
			svg.appendChild(guide);

			const xLabelIndexes = rows.length <= 6
				? rows.map((_, index) => index)
				: Array.from(new Set([0, Math.floor((rows.length - 1) / 2), rows.length - 1]));
			xLabelIndexes.forEach((index) => {
				const x = xForIndex(index);
				const label = document.createElement('span');
				label.className = 'pool-trend-axis-label pool-trend-axis-label-x';
				label.textContent = rows[index].day.slice(5);
				label.style.left = ((x / width) * 100).toFixed(2) + '%';
				xAxis.appendChild(label);
			});

			[
				{ key: 'cpu', color: '#5ea2ff' },
				{ key: 'memory', color: '#65c5d8' }
			].forEach((series) => {
				buildMissingTrendSegments(rows, series.key, xForIndex, yForValue).forEach((segment) => {
					missingTrendNodes.push(createSvgNode('path', {
						d: segment.d,
						fill: 'none',
						stroke: '#d74c4c',
						'stroke-width': 2.5,
						'stroke-linecap': 'round',
						'stroke-dasharray': '6 6',
						class: 'pool-trend-gap-series'
					}));
				});
				const path = buildTrendPath(rows, series.key, xForIndex, yForValue);
				if (!path) { return; }
				baseSeriesLayer.appendChild(createSvgNode('path', {
					d: path,
					fill: 'none',
					stroke: 'currentColor',
					'stroke-width': 3,
					'stroke-linecap': 'round',
					'stroke-linejoin': 'round',
					class: 'pool-trend-series pool-trend-series-base'
				}));
				selectedSeriesLayer.appendChild(createSvgNode('path', {
					d: path,
					fill: 'none',
					stroke: series.color,
					'stroke-width': 3,
					'stroke-linecap': 'round',
					'stroke-linejoin': 'round',
					class: 'pool-trend-series pool-trend-series-selected'
				}));
				rows.forEach((row, index) => {
					const value = toNumber(row[series.key]);
					if (value === null) { return; }
					baseSeriesLayer.appendChild(createSvgNode('circle', {
						cx: xForIndex(index),
						cy: yForValue(value),
						r: 3.5,
						fill: 'currentColor',
						class: 'pool-trend-point pool-trend-point-base'
					}));
					selectedSeriesLayer.appendChild(createSvgNode('circle', {
						cx: xForIndex(index),
						cy: yForValue(value),
						r: 3.5,
						fill: series.color,
						class: 'pool-trend-point pool-trend-point-selected'
					}));
				});
			});
			svg.appendChild(baseSeriesLayer);
			svg.appendChild(selectedSeriesLayer);
			missingTrendNodes.forEach((node) => svg.appendChild(node));

			const sliderShell = document.createElement('div');
			sliderShell.className = 'pool-trend-slider-shell';
			const sliderSummary = document.createElement('div');
			sliderSummary.className = 'pool-trend-slider-summary';
			const sliderLabel = document.createElement('span');
			sliderLabel.className = 'pool-trend-slider-label';
			sliderLabel.textContent = 'Selected window';
			const sliderWindow = document.createElement('strong');
			sliderWindow.className = 'pool-trend-slider-window';
			sliderSummary.append(sliderLabel, sliderWindow);
			const sliderRail = document.createElement('div');
			sliderRail.className = 'pool-trend-slider-rail';
			const sliderTrack = document.createElement('div');
			sliderTrack.className = 'pool-trend-slider-track';
			const sliderRange = document.createElement('div');
			sliderRange.className = 'pool-trend-slider-range';
			const sliderMinIndex = trendCoverage.startIndex >= 0 ? trendCoverage.startIndex : 0;
			const sliderMaxIndex = trendCoverage.endIndex >= 0 ? trendCoverage.endIndex : (rows.length - 1);
			const startInput = document.createElement('input');
			startInput.type = 'range';
			startInput.className = 'pool-trend-slider pool-trend-slider-start';
			startInput.min = '0';
			startInput.max = String(rows.length - 1);
			startInput.step = '1';
			startInput.value = String(sliderMinIndex);
			startInput.setAttribute('aria-label', 'Start of selected trend window');
			const endInput = document.createElement('input');
			endInput.type = 'range';
			endInput.className = 'pool-trend-slider pool-trend-slider-end';
			endInput.min = '0';
			endInput.max = String(rows.length - 1);
			endInput.step = '1';
			endInput.value = String(sliderMaxIndex);
			endInput.setAttribute('aria-label', 'End of selected trend window');
			sliderRail.append(sliderTrack, sliderRange, startInput, endInput);
			const sliderEndpoints = document.createElement('div');
			sliderEndpoints.className = 'pool-trend-slider-endpoints';
			const startLabel = document.createElement('span');
			startLabel.textContent = formatTrendShortDate(rows[sliderMinIndex].day);
			const endLabel = document.createElement('span');
			endLabel.textContent = formatTrendShortDate(rows[sliderMaxIndex].day);
			sliderEndpoints.append(startLabel, endLabel);
			sliderShell.append(sliderSummary, sliderRail, sliderEndpoints);

			const stepWidth = rows.length <= 1 ? plotWidth : (plotWidth / (rows.length - 1));
			let pendingSelection = null;
			let selectionFrame = null;
			const showTooltip = (row, index) => {
				tooltip.innerHTML = '<strong>' + row.day + '</strong>' +
					'<span>CPU: ' + formatTrendTooltipValue(row.cpu) + '</span>' +
					'<span>Memory: ' + formatTrendTooltipValue(row.memory) + '</span>' +
					'<span class="pool-trend-tooltip-note">Click to move the nearest range handle</span>';
				tooltip.classList.add('is-visible');
				tooltip.setAttribute('aria-hidden', 'false');
				tooltip.classList.remove('is-edge-left', 'is-edge-right');
				const x = xForIndex(index);
				guide.setAttribute('x1', String(x));
				guide.setAttribute('x2', String(x));
				guide.classList.remove('hidden');
				const cardRect = card.getBoundingClientRect();
				const tooltipRect = tooltip.getBoundingClientRect();
				const xPercent = x / width;
				const targetLeftPx = cardRect.width * xPercent;
				const halfTooltip = tooltipRect.width / 2;
				const minLeftPx = 12 + halfTooltip;
				const maxLeftPx = Math.max(minLeftPx, cardRect.width - 12 - halfTooltip);
				const clampedLeftPx = Math.max(minLeftPx, Math.min(maxLeftPx, targetLeftPx));
				if (clampedLeftPx === minLeftPx) {
					tooltip.classList.add('is-edge-left');
				} else if (clampedLeftPx === maxLeftPx) {
					tooltip.classList.add('is-edge-right');
				}
				tooltip.style.left = clampedLeftPx.toFixed(2) + 'px';
			};
			const hideTooltip = () => {
				tooltip.classList.remove('is-visible');
				tooltip.setAttribute('aria-hidden', 'true');
				guide.classList.add('hidden');
			};
			const syncSelectionVisuals = (startIndex, endIndex) => {
				const left = xForIndex(startIndex);
				const right = xForIndex(endIndex);
				selectionShadeLeft.setAttribute('width', Math.max(0, left - margin.left));
				selectionShadeRight.setAttribute('x', String(right));
				selectionShadeRight.setAttribute('width', Math.max(0, (width - margin.right) - right));
				selectionFrameLeft.setAttribute('x1', String(left));
				selectionFrameLeft.setAttribute('x2', String(left));
				selectionFrameRight.setAttribute('x1', String(right));
				selectionFrameRight.setAttribute('x2', String(right));
				selectionClipRect.setAttribute('x', String(left));
				selectionClipRect.setAttribute('width', String(Math.max(6, right - left)));
				const selectionSpan = Math.max(1, rows.length - 1);
				const startPercent = (startIndex / selectionSpan) * 100;
				const endPercent = (endIndex / selectionSpan) * 100;
				sliderRange.style.left = startPercent.toFixed(2) + '%';
				sliderRange.style.width = Math.max(0, endPercent - startPercent).toFixed(2) + '%';
			};
			const emitSelection = (startIndex, endIndex) => {
				const summary = summarizePoolTrendSelection(model, startIndex, endIndex);
				if (!summary) { return; }
				const suffix = summary.dayCount === 1 ? '1 day selected' : (summary.dayCount + ' days selected');
				selectionWindow.textContent = summary.label;
				selectionMeta.textContent = summary.isFullRange ? 'Entire Window' : suffix;
				sliderWindow.textContent = summary.label;
				syncSelectionVisuals(summary.startIndex, summary.endIndex);
				if (typeof onSelectionChange === 'function') {
					onSelectionChange(summary);
				}
			};
			const applySelection = (startIndex, endIndex) => {
				emitSelection(startIndex, endIndex);
			};
			const setSelection = (nextStart, nextEnd) => {
				const startIndex = Math.max(sliderMinIndex, Math.min(nextStart, sliderMaxIndex));
				const endIndex = Math.max(startIndex, Math.min(nextEnd, sliderMaxIndex));
				startInput.value = String(startIndex);
				endInput.value = String(endIndex);
				pendingSelection = { startIndex, endIndex };
				if (selectionFrame !== null) { return; }
				selectionFrame = requestAnimationFrame(() => {
					selectionFrame = null;
					if (!pendingSelection) { return; }
					const selection = pendingSelection;
					pendingSelection = null;
					applySelection(selection.startIndex, selection.endIndex);
				});
			};
			const handleStartInput = () => {
				const nextStart = Math.max(sliderMinIndex, Math.min(Number(startInput.value), Number(endInput.value)));
				setSelection(nextStart, Number(endInput.value));
			};
			const handleEndInput = () => {
				const nextEnd = Math.min(sliderMaxIndex, Math.max(Number(endInput.value), Number(startInput.value)));
				setSelection(Number(startInput.value), nextEnd);
			};
			startInput.addEventListener('input', handleStartInput);
			endInput.addEventListener('input', handleEndInput);
			rows.forEach((row, index) => {
				const centerX = xForIndex(index);
				const left = index === 0 ? margin.left : (centerX - (stepWidth / 2));
				const right = index === rows.length - 1 ? (width - margin.right) : (centerX + (stepWidth / 2));
				const hit = createSvgNode('rect', {
					x: left,
					y: margin.top,
					width: Math.max(8, right - left),
					height: plotHeight,
					class: 'pool-trend-hitbox'
				});
				hit.addEventListener('mouseenter', () => showTooltip(row, index));
				hit.addEventListener('mousemove', () => showTooltip(row, index));
				hit.addEventListener('focus', () => showTooltip(row, index));
				hit.addEventListener('click', () => {
					const currentStart = Number(startInput.value);
					const currentEnd = Number(endInput.value);
					if (Math.abs(index - currentStart) <= Math.abs(index - currentEnd)) {
						setSelection(Math.min(index, currentEnd), currentEnd);
						return;
					}
					setSelection(currentStart, Math.max(index, currentStart));
				});
				hit.addEventListener('mouseleave', hideTooltip);
				hit.addEventListener('blur', hideTooltip);
				hit.setAttribute('tabindex', '0');
				hit.setAttribute('role', 'button');
				hit.setAttribute('aria-label', row.day + ' CPU ' + formatTrendTooltipValue(row.cpu) + ', Memory ' + formatTrendTooltipValue(row.memory));
				svg.appendChild(hit);
			});

			plot.append(svg, yAxis, xAxis);
			card.append(head, legend, plot, tooltip, sliderShell);
			const initialStartIndex = trendCoverage.startIndex > 0 ? trendCoverage.startIndex : 0;
			setSelection(initialStartIndex, rows.length - 1);
			wirePoolTrendReveal(card);
			return card;
		}

		function formatStorageTierLabel(tier) {
			if (!tier) { return null; }
			const normalized = String(tier).trim().toLowerCase();
			if (normalized === 'premium') { return 'Premium'; }
			if (normalized === 'hot') { return 'Standard - Hot'; }
			if (normalized === 'cool' || normalized === 'cold') { return 'Standard - Cold'; }
			if (normalized === 'transactionoptimized' || normalized === 'transaction optimized') { return 'Standard - Transaction Optimized'; }
			return String(tier);
		}

		function slugifyFragment(value) {
			return String(value || '')
				.toLowerCase()
				.replace(/[^a-z0-9]+/g, '-')
				.replace(/^-+|-+$/g, '');
		}

		function hostPoolAnchorId(pool, fallbackIndex) {
			const namePart = slugifyFragment(pool && (pool.Name || pool.FriendlyName));
			const subscriptionPart = slugifyFragment(pool && (pool.SubscriptionName || pool.SubscriptionId));
			const suffix = namePart || ('pool-' + ((fallbackIndex || 0) + 1));
			return 'host-pool-' + (subscriptionPart ? (subscriptionPart + '-') : '') + suffix;
		}

		function storageAccountAnchorId(account, fallbackIndex) {
			const namePart = slugifyFragment(account && account.Name);
			const subscriptionPart = slugifyFragment(account && (account.SubscriptionName || account.SubscriptionId));
			const suffix = namePart || ('storage-account-' + ((fallbackIndex || 0) + 1));
			return 'storage-account-' + (subscriptionPart ? (subscriptionPart + '-') : '') + suffix;
		}

		function storageTierBadgeVariant(tier) {
			const normalized = tier ? String(tier).trim().toLowerCase() : '';
			if (normalized === 'premium') { return 'tier-gold'; }
			if (normalized === 'hot') { return 'tier-red'; }
			if (normalized === 'cool' || normalized === 'cold') { return 'tier-blue'; }
			if (normalized === 'transactionoptimized' || normalized === 'transaction optimized') { return 'tier-slate'; }
			return 'neutral';
		}

		function createStorageShareList(shares) {
			const wrapper = document.createElement('div');
			wrapper.className = 'share-list';
			shares.forEach((share, index) => {
				const item = document.createElement('div');
				item.className = 'share-item';
				const title = document.createElement('div');
				title.className = 'share-title';
				const name = document.createElement('strong');
				name.textContent = share && share.Name ? share.Name : ('Share ' + (index + 1));
				title.appendChild(name);
				const meta = document.createElement('div');
				meta.className = 'share-meta';
				if (share && share.Tier) {
					meta.appendChild(createBadge(formatStorageTierLabel(share.Tier), storageTierBadgeVariant(share.Tier)));
				}
				const provisioned = share && share.ProvisionedSizeGb != null ? (share.ProvisionedSizeGb + ' GB Provisioned') : 'Provisioned Size N/A';
				meta.appendChild(createBadge(provisioned, 'neutral'));
				let used = null;
				if (share && share.UsedSizeGb != null) {
					used = share.UsedSizeGb + ' GB Used';
					if (share.UsedPercent != null) {
						used += ' (' + share.UsedPercent + '%)';
					}
				}
				if (used) {
					meta.appendChild(createBadge(used, 'neutral'));
				}
				if (share && share.ProvisionedIops != null) {
					meta.appendChild(createBadge(share.ProvisionedIops + ' IOPS', 'neutral'));
				}
				if (share && share.ProvisionedBandwidthMiBps != null) {
					meta.appendChild(createBadge(share.ProvisionedBandwidthMiBps + ' MiB/s', 'neutral'));
				}
				meta.appendChild(createBadge(share && share.BackupEnabled ? 'Backup Enabled' : 'Backup Not Enabled', share && share.BackupEnabled ? '' : 'neutral'));
				item.append(title, meta);
				wrapper.appendChild(item);
			});
			return wrapper;
		}

		function createTableCellValue(column, value, rowContext) {
			if (column === 'Name' && rowContext && (rowContext.HostPoolType || rowContext.SessionHostDetails || rowContext.AuthorizedUserCount != null)) {
				const link = document.createElement('a');
				link.className = 'host-pool-jump';
				link.href = '#' + hostPoolAnchorId(rowContext);
				link.textContent = resolveUnavailableMetricText(column, value, rowContext) || formatFieldValue(column, value);
				return link;
			}
			if (column === 'FileShares' && Array.isArray(value) && value.every((item) => isPlainObject(item))) {
				const details = document.createElement('details');
				details.className = 'inline-detail';
				const summary = document.createElement('summary');
				summary.textContent = value.length ? (value.length + (value.length === 1 ? ' share' : ' shares')) : 'No shares';
				details.append(summary, createStorageShareList(value));
				return details;
			}
			if (hasStructuredTableValue(value)) {
				return createStructuredSummary(column, value);
			}
			if (value !== null && typeof value === 'object') {
				const span = document.createElement('span');
				span.textContent = formatFieldValue(column, value);
				return span;
			}
			const span = document.createElement('span');
			span.textContent = resolveUnavailableMetricText(column, value, rowContext) || formatFieldValue(column, value);
			return span;
		}

		function createDetailStack(contents) {
			const wrapper = document.createElement('div');
			wrapper.className = 'detail-stack';
			contents.forEach((content) => {
				if (content) {
					wrapper.appendChild(content);
				}
			});
			return wrapper;
		}

		function createStructuredRowDetails(row, columns) {
			const entries = columns
				.map((column) => [column, row ? row[column] : null])
				.filter(([, value]) => hasStructuredTableValue(value));
			if (!entries.length) { return null; }
			const details = document.createElement('details');
			details.className = 'table-detail structured-detail';
			const summary = document.createElement('summary');
			const labels = entries.map(([column]) => formatLabel(column));
			const preview = labels.slice(0, 3).join(', ');
			summary.textContent = labels.length <= 3
				? 'View details (' + preview + ')'
				: 'View details (' + preview + ' +' + (labels.length - 3) + ')';
			const grid = document.createElement('div');
			grid.className = 'structured-detail-grid';
			entries.forEach(([column, value]) => {
				const section = document.createElement('details');
				const sectionSummary = document.createElement('summary');
				sectionSummary.textContent = formatLabel(column) + ' • ' + summarizeStructuredValue(column, value);
				section.append(sectionSummary, renderStructuredValue(value, 1));
				grid.appendChild(section);
			});
			details.append(summary, grid);
			return details;
		}

		function createStatList(items) {
			const wrapper = document.createElement('div');
			wrapper.className = 'stat-list';
			items.forEach((item) => {
				const row = document.createElement('div');
				row.className = 'stat-row';
				const label = document.createElement('span');
				label.className = 'muted';
				label.textContent = item.label;
				const value = document.createElement('strong');
				value.textContent = formatValue(item.value);
				row.append(label, value);
				wrapper.appendChild(row);
			});
			return wrapper;
		}

		function createChipList(items, className) {
			const wrapper = document.createElement('div');
			wrapper.className = className || 'chips';
			items.forEach((item) => {
				const fullValue = String(item.rawValue !== undefined ? item.rawValue : formatValue(item.value));
				const displayValue = fullValue.length > 34 ? fullValue.slice(0, 31).trimEnd() + '...' : fullValue;
				const chip = document.createElement('div');
				chip.className = 'chip';
				chip.dataset.chipLabel = String(item.label || '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
				if (displayValue !== fullValue) { chip.title = fullValue; }
				chip.innerHTML = '<strong>' + String(item.label).replace(/</g, '&lt;') + ':</strong> <span>' + displayValue.replace(/</g, '&lt;') + '</span>';
				wrapper.appendChild(chip);
			});
			return wrapper;
		}

		function createBarList(items) {
			const wrapper = document.createElement('div');
			wrapper.className = 'bar-list';
			const max = Math.max(...items.map((item) => item.value), 0);
			items.forEach((item) => {
				const node = document.createElement('div');
				node.className = 'bar-item';
				const label = document.createElement('div');
				label.className = 'bar-label';
				const left = document.createElement('span');
				left.textContent = item.label;
				const right = document.createElement('strong');
				right.textContent = formatValue(item.value);
				label.append(left, right);
				const track = document.createElement('div');
				track.className = 'bar-track';
				const fill = document.createElement('div');
				fill.className = 'bar-fill';
				fill.style.width = max > 0 ? ((item.value / max) * 100).toFixed(1) + '%' : '0%';
				track.appendChild(fill);
				node.append(label, track);
				wrapper.appendChild(node);
			});
			return wrapper;
		}

		function objectArrayColumns(rows, preferredKeys) {
			const discovered = [];
			rows.slice(0, 20).forEach((row) => {
				Object.keys(row || {}).forEach((key) => {
					if (!discovered.includes(key)) { discovered.push(key); }
				});
			});
			const preferred = (preferredKeys || []).filter((key) => discovered.includes(key));
			const remainder = discovered.filter((key) => !preferred.includes(key));
			return preferred.concat(remainder).slice(0, 10);
		}

		function createDetailTableRow(content, columnCount, searchText) {
			const tr = document.createElement('tr');
			tr.className = 'detail-row';
			if (searchText) {
				tr.dataset.search = searchText;
			}
			const td = document.createElement('td');
			td.colSpan = Math.max(columnCount, 1);
			td.appendChild(content);
			tr.appendChild(td);
			return tr;
		}

		function createStorageShareDetails(row) {
			const shares = row && Array.isArray(row.FileShares) ? row.FileShares.filter((item) => isPlainObject(item)) : [];
			const shareMetadata = [];
			if (row && row.ReplicationType) {
				shareMetadata.push({ label: 'Replication Type', value: row.ReplicationType });
			}
			const details = document.createElement('div');
			details.className = 'storage-detail-section';
			const summary = document.createElement('h4');
			summary.className = 'storage-detail-title';
			summary.textContent = shares.length ? ('Shares (' + shares.length + (shares.length === 1 ? ' share' : ' shares') + ')') : 'Shares';
			details.appendChild(summary);
			if (shareMetadata.length) {
				details.appendChild(createStatList(shareMetadata));
			}
			if (shares.length) {
				details.appendChild(createStorageShareList(shares));
			} else {
				const empty = document.createElement('span');
				empty.className = 'muted';
				empty.textContent = 'No shares recorded for this storage account.';
				details.appendChild(empty);
			}
			return details;
		}

		function createStorageNetworkDetails(row) {
			if (!row) { return null; }
			const details = document.createElement('div');
			details.className = 'storage-detail-section';
			const summary = document.createElement('h4');
			summary.className = 'storage-detail-title';
			const privateEndpointCount = toNumber(row.PrivateEndpointCount);
			summary.textContent = privateEndpointCount && privateEndpointCount > 0
				? 'Network (' + privateEndpointCount + (privateEndpointCount === 1 ? ' private endpoint' : ' private endpoints') + ')'
				: 'Network';
			details.appendChild(summary);

			const sections = [];
			sections.push(createStatList([
				{ label: 'Public Network Access', value: row.PublicNetworkAccess },
				{ label: 'Default Action', value: row.NetworkDefaultAction },
				{ label: 'Bypass', value: row.NetworkBypass },
				{ label: 'HTTPS Only', value: row.HttpsOnly },
				{ label: 'Minimum TLS Version', value: row.MinimumTlsVersion },
				{ label: 'Private Endpoint Count', value: row.PrivateEndpointCount }
			]));

			const privateEndpoints = row && Array.isArray(row.PrivateEndpoints) ? row.PrivateEndpoints.filter((item) => isPlainObject(item)) : [];
			if (privateEndpoints.length) {
				const endpointRows = privateEndpoints.map((item) => ({
					Name: item.Name,
					ConnectionStatus: item.ConnectionStatus,
					ProvisioningState: item.ProvisioningState
				}));
				const endpointDetails = document.createElement('div');
				endpointDetails.className = 'storage-detail-subsection';
				const endpointSummary = document.createElement('h5');
				endpointSummary.className = 'storage-detail-subtitle';
				endpointSummary.textContent = 'Private Endpoints • ' + privateEndpoints.length + (privateEndpoints.length === 1 ? ' item' : ' items');
				endpointDetails.append(endpointSummary, wrapTable(createObjectTable(endpointRows, ['Name', 'ConnectionStatus', 'ProvisioningState'], { structuredDetailRows: false })));
				sections.push(endpointDetails);
			}

			details.appendChild(createDetailStack(sections));
			return details;
		}

		function createStorageAccountDetails(row) {
			const wrapper = document.createElement('div');
			wrapper.className = 'storage-account-detail';
			const sections = [createStorageShareDetails(row), createStorageNetworkDetails(row)].filter(Boolean);
			sections.forEach((section, index) => {
				if (index > 0) {
					const divider = document.createElement('div');
					divider.className = 'storage-detail-divider';
					wrapper.appendChild(divider);
				}
				wrapper.appendChild(section);
			});
			return wrapper;
		}

		function createPoolAccessDetails(pool) {
			const details = document.createElement('div');

			const workspaceNames = Array.isArray(pool.WorkspaceNames) && pool.WorkspaceNames.length ? pool.WorkspaceNames.join(', ') : 'None';
			const appGroupNames = Array.isArray(pool.AppGroupNames) && pool.AppGroupNames.length ? pool.AppGroupNames.join(', ') : 'None';
			const sections = [createStatList([
				{ label: 'Authorised User Count', value: pool.AuthorizedUserCount },
				{ label: 'Status', value: pool.AuthorizedUserStatus },
				{ label: 'Workspaces', value: workspaceNames },
				{ label: 'App Groups', value: appGroupNames }
			])];

			const accessAssignments = Array.isArray(pool.AccessAssignments)
				? pool.AccessAssignments.filter((item) => isPlainObject(item))
				: [];
			if (accessAssignments.length) {
				const assignmentBlock = document.createElement('details');
				const assignmentSummary = document.createElement('summary');
				assignmentSummary.textContent = 'Users and Groups • ' + accessAssignments.length + (accessAssignments.length === 1 ? ' assignment' : ' assignments');
				assignmentBlock.append(assignmentSummary, wrapTable(createObjectTable(accessAssignments, ['Type', 'DisplayName', 'UPN'], { structuredDetailRows: false })));
				sections.push(assignmentBlock);
			} else {
				const empty = document.createElement('span');
				empty.className = 'muted';
				empty.textContent = 'No authorised users or groups were recorded for this pool in the export.';
				sections.push(empty);
			}

			details.appendChild(createDetailStack(sections));
			return details;
		}

		function createPoolTagsDetails(pool) {
			const tagEntries = isPlainObject(pool.Tags)
				? Object.entries(pool.Tags).filter(([, value]) => value !== null && value !== undefined && value !== '')
				: [];
			if (!tagEntries.length) { return null; }
			const details = document.createElement('details');
			const summary = document.createElement('summary');
			summary.textContent = 'Host Pool Tags • ' + tagEntries.length + (tagEntries.length === 1 ? ' item' : ' items');
			details.append(summary, wrapTable(createObjectTable(tagEntries.map(([key, value]) => ({ Key: key, Value: value })), ['Key', 'Value'], { structuredDetailRows: false })));
			return details;
		}

		function createPoolDiagnosticInsightsDetails(pool) {
			const insights = isPlainObject(pool && pool.InsightsDiagnostics) ? pool.InsightsDiagnostics : null;
			if (!insights) { return null; }
			const details = document.createElement('div');
			const sections = [createStatList([
				{ label: 'Status', value: insights.QueryStatus },
				{ label: 'Workspace', value: insights.LogAnalyticsWorkspace },
				{ label: 'Diagnostic Categories', value: insights.DiagnosticCategories },
				{ label: 'Last Successful Connection', value: insights.LastSuccessfulConnection },
				{ label: 'Total Errors', value: insights.TotalErrors },
				{ label: 'Failed Connections', value: insights.TotalFailedConnections },
				{ label: 'Shortpath Errors', value: insights.ShortpathErrors },
				{ label: 'Shortpath Upgrades', value: insights.ShortpathUpgradeEvents },
				{ label: 'Host Registration Events', value: insights.HostRegistrationEvents },
				{ label: 'Registration Health', value: insights.HostRegistrationHealthSummary }
			])];

			const topErrors = Array.isArray(insights.TopErrors) ? insights.TopErrors.filter((item) => isPlainObject(item)) : [];
			if (topErrors.length) {
				const errorsBlock = document.createElement('details');
				const errorsSummary = document.createElement('summary');
				errorsSummary.textContent = 'Top Errors • ' + topErrors.length + (topErrors.length === 1 ? ' item' : ' items');
				errorsBlock.append(errorsSummary, wrapTable(createObjectTable(topErrors, ['Message', 'Count', 'Source'], { structuredDetailRows: false })));
				sections.push(errorsBlock);
			}

			const transportBreakdown = Array.isArray(insights.TransportTypeBreakdown) ? insights.TransportTypeBreakdown.filter((item) => isPlainObject(item)) : [];
			if (transportBreakdown.length) {
				const transportBlock = document.createElement('details');
				const transportSummary = document.createElement('summary');
				transportSummary.textContent = 'Transport Breakdown • ' + transportBreakdown.length + (transportBreakdown.length === 1 ? ' item' : ' items');
				transportBlock.append(transportSummary, wrapTable(createObjectTable(transportBreakdown, ['TransportType', 'Count', 'Method', 'Description'], { structuredDetailRows: false })));
				sections.push(transportBlock);
			}

			const registrationBreakdown = Array.isArray(insights.HostRegistrationBreakdown) ? insights.HostRegistrationBreakdown.filter((item) => isPlainObject(item)) : [];
			if (registrationBreakdown.length) {
				const registrationBlock = document.createElement('details');
				const registrationSummary = document.createElement('summary');
				registrationSummary.textContent = 'Host Registration Breakdown • ' + registrationBreakdown.length + (registrationBreakdown.length === 1 ? ' host' : ' hosts');
				registrationBlock.append(registrationSummary, wrapTable(createObjectTable(registrationBreakdown, ['SessionHostName', 'RegistrationCount', 'LastRegistrationTime'], { structuredDetailRows: false })));
				sections.push(registrationBlock);
			}

			details.appendChild(createDetailStack(sections));
			return details;
		}

		function createSimplePropertyTable(rows, preferredKeys) {
			const cleanRows = Array.isArray(rows) ? rows.filter((row) => isPlainObject(row)) : [];
			if (!cleanRows.length) {
				const empty = document.createElement('span');
				empty.className = 'muted';
				empty.textContent = 'None';
				return empty;
			}
			return wrapTable(createObjectTable(cleanRows, preferredKeys || [], { structuredDetailRows: false }));
		}

		function createPlatformSection(title, content) {
			if (!content) { return null; }
			const section = document.createElement('div');
			section.className = 'platform-section';
			const heading = document.createElement('h4');
			heading.className = 'platform-section-title';
			heading.textContent = title;
			const body = document.createElement('div');
			body.className = 'platform-section-body';
			body.appendChild(content);
			section.appendChild(heading);
			section.appendChild(body);
			return section;
		}

		function createPlatformMessageList(items, className) {
			const values = Array.isArray(items) ? items.filter((item) => item) : [];
			if (!values.length) { return null; }
			const list = document.createElement('ul');
			list.className = className || 'platform-note-list';
			values.forEach((item) => {
				const li = document.createElement('li');
				li.textContent = String(item);
				list.appendChild(li);
			});
			return list;
		}

		function normalizeToggleState(value, fallbackValue) {
			if (value && typeof value === 'object') {
				if (value.Display) { return formatLabel(value.Display); }
				if (value.Enabled === true) { return fallbackValue || 'Enabled'; }
				if (value.Enabled === false) { return 'Disabled'; }
				if (value.Value !== undefined && value.Value !== null && value.Value !== '') {
					return fallbackValue || 'Enabled';
				}
				if (value.RawValue !== undefined && value.RawValue !== null) {
					return Number(value.RawValue) === 1 ? (fallbackValue || 'Enabled') : 'Disabled';
				}
			}
			if (typeof value === 'boolean') { return value ? (fallbackValue || 'Enabled') : 'Disabled'; }
			return 'Disabled';
		}

		function createPoolRdpPropertiesDetails(pool) {
			const rdp = isPlainObject(pool && pool.RdpProperties) ? pool.RdpProperties : null;
			if (!rdp) { return null; }
			const audioParts = [];
			if (rdp.AudioPlayback && rdp.AudioPlayback.Display) {
				audioParts.push('Playback: ' + formatLabel(rdp.AudioPlayback.Display));
			}
			audioParts.push('Capture: ' + normalizeToggleState(rdp.AudioCapture));
			return createPlatformSection('RDP Properties', createSimplePropertyTable([
				{ Feature: 'Drive Redirection', Setting: normalizeToggleState(rdp.DriveRedirection) },
				{ Feature: 'Clipboard', Setting: normalizeToggleState(rdp.ClipboardRedirection) },
				{ Feature: 'Printer', Setting: normalizeToggleState(rdp.PrinterRedirection) },
				{ Feature: 'Smart Card', Setting: normalizeToggleState(rdp.SmartCardRedirection) },
				{ Feature: 'USB', Setting: normalizeToggleState(rdp.UsbRedirection) },
				{ Feature: 'Camera', Setting: normalizeToggleState(rdp.CameraRedirection) },
				{ Feature: 'Audio', Setting: audioParts.join(' / ') }
			], ['Feature', 'Setting']));
		}

		function createPoolSsoDetails(pool) {
			const sso = isPlainObject(pool && pool.SsoConfig) ? pool.SsoConfig : null;
			if (!sso) { return null; }
			const content = document.createElement('div');
			content.className = 'detail-stack';
			content.appendChild(createStatList([
				{ label: 'SSO Enabled', value: sso.SsoEnabled },
				{ label: 'Join Type', value: sso.DetectedJoinType }
			]));
			const blockers = createPlatformMessageList(sso.Blockers, 'platform-note-list blockers');
			if (blockers) {
				content.appendChild(createPlatformSection('Blockers', blockers));
			}
			return createPlatformSection('SSO Config', content);
		}

		function createPoolNetworkDetails(pool) {
			const networks = Array.isArray(pool && pool.NetworkInfo) ? pool.NetworkInfo.filter((item) => isPlainObject(item)) : [];
			if (!networks.length) { return null; }
			const wrapper = document.createElement('div');
			wrapper.className = 'detail-stack';
			networks.forEach((network, index) => {
				const sectionContent = document.createElement('div');
				sectionContent.className = 'detail-stack';
				sectionContent.appendChild(createStatList([
					{ label: 'VNET Name', value: network.VNetName },
					{ label: 'VNET Address Prefixes', value: network.VNetAddressPrefixes },
					{ label: 'VNET Custom DNS Servers', value: network.VNetCustomDnsServers },
					{ label: 'Subnet Name', value: network.SubnetName },
					{ label: 'Subnet Address Prefix', value: network.SubnetAddressPrefix },
					{ label: 'Subnet NSG', value: network.SubnetNsg },
					{ label: 'NIC NSG', value: network.NicNsg },
					{ label: 'Route Table', value: network.SubnetRouteTable && network.SubnetRouteTable.Name ? network.SubnetRouteTable.Name : null }
				]));
				const routes = network.SubnetRouteTable && Array.isArray(network.SubnetRouteTable.Routes)
					? network.SubnetRouteTable.Routes.filter((item) => isPlainObject(item))
					: [];
				if (routes.length) {
					const routesTitle = document.createElement('h5');
					routesTitle.className = 'platform-section-subtitle';
					routesTitle.textContent = 'Routes';
					sectionContent.append(routesTitle, createSimplePropertyTable(routes, ['Name', 'AddressPrefix', 'NextHopType', 'NextHopIpAddress']));
				}
				wrapper.appendChild(createPlatformSection(network.SubnetName || ('Network ' + (index + 1)), sectionContent));
			});
			return createPlatformSection('Network Info', wrapper);
		}

		function createPoolPlatformDetails(pool) {
			const content = document.createElement('div');
			content.className = 'detail-stack';
			content.appendChild(createPlatformSection('Host Pool Settings', createStatList([
				{ label: 'Start VM On Connect', value: pool.StartVMOnConnect },
				{ label: 'App Groups', value: Array.isArray(pool.AppGroupDetails) ? pool.AppGroupDetails.length : 0 },
				{ label: 'Image References', value: Array.isArray(pool.ImageReferences) ? pool.ImageReferences.length : 0 }
			])));
			[createPoolNetworkDetails(pool), createPoolRdpPropertiesDetails(pool), createPoolSsoDetails(pool)].filter(Boolean).forEach((section) => content.appendChild(section));
			const appGroups = Array.isArray(pool.AppGroupDetails) ? pool.AppGroupDetails.filter((item) => isPlainObject(item)) : [];
			if (appGroups.length) {
				content.appendChild(createPlatformSection('Application Groups', createSimplePropertyTable(appGroups.map((item) => ({
					Name: item.Name,
					Type: item.Type
				})), ['Name', 'Type'])));
			}
			const imageReferences = Array.isArray(pool.ImageReferences) ? pool.ImageReferences.filter((item) => isPlainObject(item)) : [];
			if (imageReferences.length) {
				content.appendChild(createPlatformSection('Image References', createSimplePropertyTable(imageReferences, ['Type', 'GalleryName', 'ImageDefinition', 'VersionInUse', 'TotalVersionsInGallery'])));
			}
			return content;
		}

		function createObjectTable(rows, preferredKeys, options) {
			if (!rows.length) {
				const empty = document.createElement('div');
				empty.className = 'table-empty-state';
				const title = document.createElement('strong');
				title.textContent = 'No rows available';
				const detail = document.createElement('span');
				detail.textContent = 'This section does not contain any records.';
				empty.append(title, detail);
				return empty;
			}
			const tableOptions = options || {};
			const table = document.createElement('table');
			const columns = objectArrayColumns(rows, preferredKeys).filter((column) => !(tableOptions.hiddenColumns || []).includes(column));
			const thead = document.createElement('thead');
			const headRow = document.createElement('tr');
			columns.forEach((column) => {
				const th = document.createElement('th');
				th.textContent = formatLabel(column);
				headRow.appendChild(th);
			});
			thead.appendChild(headRow);
			const tbody = document.createElement('tbody');
			rows.slice(0, 250).forEach((row) => {
				const searchText = JSON.stringify(row).toLowerCase();
				const tr = document.createElement('tr');
				tr.dataset.search = searchText;
				columns.forEach((column) => {
					const td = document.createElement('td');
					td.appendChild(createTableCellValue(column, row ? row[column] : null, row, tableOptions));
					tr.appendChild(td);
				});
				tbody.appendChild(tr);
				const detailContents = [];
				if (tableOptions.detailRowFactory) {
					detailContents.push(tableOptions.detailRowFactory(row));
				}
				if (tableOptions.structuredDetailRows !== false) {
					detailContents.push(createStructuredRowDetails(row, columns));
				}
				const detailContent = detailContents.filter(Boolean);
				if (detailContent.length) {
					tbody.appendChild(createDetailTableRow(detailContent.length === 1 ? detailContent[0] : createDetailStack(detailContent), columns.length, searchText));
				}
			});
			table.append(thead, tbody);
			return table;
		}

		function wrapTable(table) {
			const wrap = document.createElement('div');
			wrap.className = 'table-wrap';
			wrap.appendChild(table);
			return wrap;
		}

		function renderPrimitiveList(values) {
			const wrapper = document.createElement('div');
			wrapper.className = 'chips';
			values.forEach((value) => wrapper.appendChild(createBadge(formatValue(value), 'neutral')));
			return wrapper;
		}

		function renderStructuredValue(value, depth, parentContext) {
			const level = depth || 0;
			if (value === null || value === undefined || value === '') {
				const empty = document.createElement('span');
				empty.className = 'muted';
				empty.textContent = resolveUnavailableMetricText('', value, parentContext) || 'None';
				return empty;
			}
			if (typeof value !== 'object') {
				const span = document.createElement('span');
				span.textContent = formatValue(value);
				return span;
			}
			if (Array.isArray(value)) {
				if (!value.length) {
					const emptyArray = document.createElement('span');
					emptyArray.className = 'muted';
					emptyArray.textContent = 'Empty list';
					return emptyArray;
				}
				if (value.every((item) => item === null || ['string', 'number', 'boolean'].includes(typeof item))) {
					return renderPrimitiveList(value);
				}
				if (value.every((item) => isPlainObject(item))) {
					return wrapTable(createObjectTable(value, []));
				}
				const container = document.createElement('div');
				container.className = 'nested-sheet-stack';
				value.forEach((item, index) => {
					const details = document.createElement('details');
					details.className = 'nested-sheet nested-sheet-depth-' + Math.min(level + 1, 3);
					const summary = document.createElement('summary');
					const title = document.createElement('span');
					title.className = 'nested-sheet-title';
					title.textContent = summarizeItemLabel(item, index);
					const meta = document.createElement('span');
					meta.className = 'nested-sheet-meta';
					meta.textContent = summarizeNestedValue(item);
					summary.append(title, meta);
					const body = document.createElement('div');
					body.className = 'nested-sheet-body';
					body.appendChild(renderStructuredValue(item, level + 1, item));
					details.append(summary, body);
					container.appendChild(details);
				});
				return container;
			}
			const wrapper = document.createElement('div');
			wrapper.className = 'structured-stack';
			const primitiveEntries = [];
			const complexEntries = [];
			Object.entries(value).forEach(([key, child]) => {
				const primitiveArray = Array.isArray(child) && child.every((item) => item === null || ['string', 'number', 'boolean'].includes(typeof item)) && child.length <= 12;
				if (child === null || child === undefined || typeof child !== 'object' || primitiveArray) {
					primitiveEntries.push([key, child]);
				} else {
					complexEntries.push([key, child]);
				}
			});
			if (primitiveEntries.length) {
				const dl = document.createElement('dl');
				dl.className = 'key-value';
				primitiveEntries.forEach(([key, child]) => {
					const row = document.createElement('div');
					row.className = 'kv-row';
					const dt = document.createElement('dt');
					dt.textContent = formatLabel(key);
					const dd = document.createElement('dd');
					if (Array.isArray(child)) {
						dd.appendChild(renderPrimitiveList(child));
					} else if (typeof child === 'boolean') {
						dd.appendChild(createBadge(child ? 'Yes' : 'No', child ? '' : 'neutral'));
					} else {
						dd.textContent = resolveUnavailableMetricText(key, child, value) || formatFieldValue(key, child);
					}
					row.append(dt, dd);
					dl.appendChild(row);
				});
				wrapper.appendChild(dl);
			}
			complexEntries.forEach(([key, child]) => {
				const details = document.createElement('details');
				details.className = 'nested-sheet nested-sheet-depth-' + Math.min(level + 1, 3);
				const summary = document.createElement('summary');
				const title = document.createElement('span');
				title.className = 'nested-sheet-title';
				title.textContent = formatLabel(key);
				const meta = document.createElement('span');
				meta.className = 'nested-sheet-meta';
				meta.textContent = summarizeNestedValue(child);
				summary.append(title, meta);
				const body = document.createElement('div');
				body.className = 'nested-sheet-body';
				body.appendChild(renderStructuredValue(child, level + 1, child));
				details.append(summary, body);
				wrapper.appendChild(details);
			});
			return wrapper;
		}

		function reportKind() {
			if (Array.isArray(data.HostPools) || isPlainObject(data.HostPools)) { return 'metrics'; }
			if (Array.isArray(data.Applications) || data.DiscoveryType === 'LocalAvdHost') { return 'host'; }
			return 'generic';
		}

		function heroMetaEntries(kind) {
			const entries = [
				['Generated', data.CollectedAt || GENERATED_AT],
				['Customer', data.CustomerAbbreviation || 'n/a'],
				['Generated By', data.GeneratedBy || 'n/a'],
				['Project Code', data.ProjectCode || 'n/a']
			];
			if (kind === 'metrics') { entries.push(['Window', (data.LookbackDays || 'n/a') + ' day(s)']); }
			if (kind === 'host') { entries.push(['Host', data.Machine && data.Machine.Hostname ? data.Machine.Hostname : 'n/a']); }
			return entries;
		}

		function metricsSummary() {
			const hostPools = normalizeCollection(data.HostPools);
			const storageAccounts = normalizeCollection(data.StorageAccountScan);
			return [
				{ label: 'Host Pools', value: data.HostPoolCount || hostPools.length, detail: 'AVD pools covered in this export' },
				{ label: 'Storage Accounts', value: storageAccounts.length, detail: 'Storage accounts scanned for FSLogix coverage' },
				{ label: 'Eligible Users', value: data.LicenseSummaryUserCount, detail: 'User accounts included in the licensing scope' },
				{ label: 'Subscriptions', value: data.SubscriptionCount, detail: 'Azure subscriptions scanned' }
			];
		}

		function hostSummary() {
			const fsLogix = data.FSLogix || {};
			const sso = data.EntraSso || {};
			const adDeps = data.ActiveDirectoryDependencies || {};
			return [
				{ label: 'Applications', value: data.ApplicationCount || normalizeCollection(data.Applications).length, detail: 'Installed apps included in the export' },
				{ label: 'Join Type', value: data.JoinState && data.JoinState.JoinType ? data.JoinState.JoinType : 'n/a', detail: 'Detected device join state' },
				{ label: 'FSLogix', value: fsLogix.Installed ? 'Installed' : 'Not installed', detail: 'Profile container platform status' },
				{ label: 'Containers', value: fsLogix.ProfileContainerCount == null ? 'n/a' : fsLogix.ProfileContainerCount, detail: 'Detected profile containers' },
				{ label: 'Entra SSO', value: sso.SsoCapable ? 'Capable' : 'Review', detail: 'Host-side SSO readiness summary' },
				{ label: 'AD Dependencies', value: adDeps.HasDomainDependencies ? 'Present' : 'None', detail: 'Services, tasks, ODBC, and live port usage' },
				{ label: 'Group Policy', value: data.GroupPolicy && data.GroupPolicy.Succeeded ? 'Captured' : 'Not captured', detail: 'gpresult HTML export status' },
				{ label: 'Connectivity', value: data.ConnectivityChecksSkipped ? 'Skipped' : 'Executed', detail: 'AVD endpoint connectivity checks' }
			];
		}

		function buildHostPoolSections() {
			const pools = normalizeCollection(data.HostPools);
			if (!pools.length) { return; }
			const isBasicReport = metricsReportType().key === 'basic';
			document.getElementById('host-pool-section').classList.remove('hidden');
			const stack = document.getElementById('host-pool-stack');
			stack.innerHTML = '';
			pools.forEach((pool, index) => {
				const hasUsageData = !isBasicReport && poolHasUsageData(pool);
				const hasPerformanceData = !isBasicReport && poolHasPerformanceData(pool);
				const hasDiagnosticData = !isBasicReport && poolHasDiagnosticInsightsData(pool);
				const trendModel = (hasUsageData || hasPerformanceData) ? buildPoolTrendModel(pool) : null;
				const panel = document.createElement('article');
				panel.className = 'pool-panel';
				const anchor = document.createElement('span');
				anchor.id = hostPoolAnchorId(pool, index);
				anchor.className = 'pool-panel-anchor';
				panel.dataset.anchorId = anchor.id;
				const diagnosticsStatus = pool.InsightsDiagnostics && pool.InsightsDiagnostics.QueryStatus
					? pool.InsightsDiagnostics.QueryStatus
					: (pool.MetricStatus || pool.SessionsStatus || '');
				const titleWrap = document.createElement('div');
				titleWrap.className = 'pool-title-wrap';
				let warning = null;
				if (/^NoDiagnosticSettings$/i.test(diagnosticsStatus)) {
					panel.classList.add('has-warning');
					warning = document.createElement('span');
					warning.className = 'pool-warning';
					warning.setAttribute('role', 'img');
					warning.setAttribute('aria-label', 'Warning: Log Analytics diagnostic settings are not enabled for this host pool.');
					warning.setAttribute('tabindex', '0');
					warning.dataset.tooltip = 'Log Analytics diagnostic settings are not enabled for this host pool. Usage metrics and Insights data are unavailable until diagnostic logging is configured.';
					const warningIcon = document.createElement('span');
					warningIcon.className = 'pool-warning-icon';
					warningIcon.setAttribute('aria-hidden', 'true');
					const warningTooltip = document.createElement('span');
					warningTooltip.className = 'pool-warning-tooltip';
					warningTooltip.textContent = warning.dataset.tooltip;
					warning.append(warningIcon, warningTooltip);
					const updateWarningTooltip = () => positionWarningTooltip(warning);
					const applyWarningTooltipVisibility = () => {
						toggleWarningLayer(true);
						warning.classList.add('is-visible');
					};
					const syncWarningTooltip = () => {
						if (warning.classList.contains('is-visible') || warning.matches(':hover') || document.activeElement === warning) {
							applyWarningTooltipVisibility();
							updateWarningTooltip();
						}
					};
					const toggleWarningLayer = (active) => {
						panel.classList.toggle('show-warning-tooltip', !!active);
					};
					const showWarningTooltip = () => {
						updateWarningTooltip();
						applyWarningTooltipVisibility();
					};
					const hideWarningTooltip = () => {
						warning.classList.remove('is-visible');
						warning.classList.remove('tooltip-below-nav');
						toggleWarningLayer(false);
					};
					const handleWarningOver = (event) => {
						if (event.relatedTarget && warning.contains(event.relatedTarget)) { return; }
						showWarningTooltip();
					};
					const handleWarningOut = (event) => {
						if (event.relatedTarget && warning.contains(event.relatedTarget)) { return; }
						hideWarningTooltip();
					};
					warning.addEventListener('mouseover', handleWarningOver);
					warning.addEventListener('pointerover', handleWarningOver);
					warning.addEventListener('mousemove', syncWarningTooltip);
					warning.addEventListener('pointermove', syncWarningTooltip);
					warning.addEventListener('focus', showWarningTooltip);
					warning.addEventListener('mouseout', handleWarningOut);
					warning.addEventListener('pointerout', handleWarningOut);
					warning.addEventListener('blur', hideWarningTooltip);
					window.addEventListener('resize', updateWarningTooltip);
					window.addEventListener('scroll', syncWarningTooltip, { passive: true });
				}
				const titleText = pool.FriendlyName || pool.Name || ('Host Pool ' + (index + 1));
				const header = document.createElement('div');
				header.className = 'pool-header';
				const title = document.createElement('h3');
				title.textContent = titleText;
				titleWrap.append(title);
				if (warning) {
					titleWrap.append(warning);
				}
				const subtitle = document.createElement('p');
				subtitle.textContent = (pool.FriendlyName && pool.Name && pool.FriendlyName !== pool.Name) ? pool.Name : '';
				const poolHighlights = createChipList([
					{ label: 'Location', value: pool.Location, rawValue: pool.Location },
					{ label: 'Subscription', value: pool.SubscriptionName, rawValue: pool.SubscriptionName },
					{ label: 'Resource Group', value: pool.ResourceGroup, rawValue: pool.ResourceGroup }
				], 'pool-highlights');
				header.append(titleWrap, poolHighlights);
				const poolMeta = createChipList([
					{ label: 'Pool Type', value: pool.HostPoolType },
					{ label: 'Load Balancer', value: pool.LoadBalancerType },
					{ label: 'Domain Join', value: pool.DomainJoinType },
					{ label: 'VM SKUs', value: pool.VmSkus },
					{ label: 'Max Sessions', value: formatFieldValue('MaxSessionLimit', pool.MaxSessionLimit) },
					{ label: 'Agent Versions', value: pool.AgentVersions },
					{ label: 'Validation Environment', value: pool.ValidationEnvironment },
					{ label: 'Reservation Match Status', value: pool.ReservationMatchStatus }
				], 'pool-meta');
				let performanceEnvelope = null;
				const performanceKpis = {};
				if (hasPerformanceData) {
					performanceEnvelope = document.createElement('section');
					performanceEnvelope.className = 'pool-summary-block performance-envelope';
					const performanceEnvelopeTitle = document.createElement('h4');
					performanceEnvelopeTitle.className = 'pool-summary-title';
					performanceEnvelopeTitle.textContent = 'Performance Envelope';
					const performanceCpuRow = document.createElement('div');
					performanceCpuRow.className = 'performance-envelope-row';
					const performanceCpuGrid = document.createElement('div');
					performanceCpuGrid.className = 'pool-grid performance-envelope-grid';
					performanceKpis.cpuAverage = createUpdatableMetricCard('CPU Average', formatPercentValue(pool.AvgCpuPercent), 'Mean CPU usage across sampled hosts', 'accent-cpu');
					performanceKpis.cpuP95 = createUpdatableMetricCard('CPU P95', formatPercentValue(pool.P95CpuPercent), '95th percentile CPU usage across sampled hosts', 'accent-cpu', 'P95CpuPercent', pool);
					performanceKpis.cpuP99 = createUpdatableMetricCard('CPU P99', formatPercentValue(pool.P99CpuPercent), '99th percentile CPU usage across sampled hosts', 'accent-cpu', 'P99CpuPercent', pool);
					[
						performanceKpis.cpuAverage,
						performanceKpis.cpuP95,
						performanceKpis.cpuP99
					].forEach((card) => performanceCpuGrid.appendChild(card.element));
					performanceCpuRow.append(performanceCpuGrid);
					const performanceMemoryRow = document.createElement('div');
					performanceMemoryRow.className = 'performance-envelope-row';
					const performanceMemoryGrid = document.createElement('div');
					performanceMemoryGrid.className = 'pool-grid performance-envelope-grid';
					performanceKpis.memoryAverage = createUpdatableMetricCard('Memory Average', formatPercentValue(pool.AvgMemUsedPercent), 'Mean memory usage across sampled hosts', 'accent-memory');
					performanceKpis.memoryP95 = createUpdatableMetricCard('Memory P95', formatPercentValue(pool.P95MemUsedPercent), '95th percentile memory usage across sampled hosts', 'accent-memory', 'P95MemUsedPercent', pool);
					performanceKpis.memoryP99 = createUpdatableMetricCard('Memory P99', formatPercentValue(pool.P99MemUsedPercent), '99th percentile memory usage across sampled hosts', 'accent-memory', 'P99MemUsedPercent', pool);
					[
						performanceKpis.memoryAverage,
						performanceKpis.memoryP95,
						performanceKpis.memoryP99
					].forEach((card) => performanceMemoryGrid.appendChild(card.element));
					performanceMemoryRow.append(performanceMemoryGrid);
					performanceEnvelope.append(performanceEnvelopeTitle, performanceCpuRow, performanceMemoryRow);
				}
				let usageSummary = null;
				const usageKpis = {};
				if (hasUsageData) {
					usageSummary = document.createElement('section');
					usageSummary.className = 'pool-summary-block usage-summary';
					const usageSummaryTitle = document.createElement('h4');
					usageSummaryTitle.className = 'pool-summary-title';
					usageSummaryTitle.textContent = 'Usage Summary';
					const peakBreakdown = Array.isArray(pool.DailyPeakBreakdown) ? pool.DailyPeakBreakdown.filter((item) => isPlainObject(item)) : [];
					const usageGrid = document.createElement('div');
					usageGrid.className = 'pool-grid usage-summary-grid';
					const usageCards = [];
					usageKpis.authorizedUsers = createUpdatableMetricCard('Authorised Users', pool.AuthorizedUserCount, 'Distinct authorised users resolved for this pool', null, 'AuthorizedUserCount', pool);
					usageCards.push(usageKpis.authorizedUsers);
					if (!/^NoDiagnosticSettings$/i.test(pool.MetricStatus || '')) {
						usageKpis.dailyUsers = createUpdatableMetricCard('Daily Active Users', /^NoUserActivity$/i.test(pool.MetricStatus || '') ? 0 : pool.DailyAverageUsers, 'Average distinct users per sampled day', null, 'DailyAverageUsers', pool);
						usageCards.push(usageKpis.dailyUsers);
					}
					if (peakBreakdown.length) {
						usageKpis.peakUsers = createUpdatableMetricCard('Peak Daily Users', pool.PeakConcurrentSessions, 'Highest sampled user concurrency across the reporting period', null, 'PeakConcurrentSessions', pool);
						usageCards.push(usageKpis.peakUsers);
					}
					usageCards.forEach((card) => usageGrid.appendChild(card.element));
					usageSummary.append(usageSummaryTitle, usageGrid);
				}
				const applyTrendSelection = (summary) => {
					const periodLabel = summary.isFullRange ? 'the full reporting window' : (summary.dayCount === 1 ? summary.label : summary.label);
					if (performanceKpis.cpuAverage) {
						performanceKpis.cpuAverage.set(formatPercentValue(summary.cpuAverage), 'Average CPU during ' + periodLabel);
						performanceKpis.cpuP95.set(formatPercentValue(summary.cpuP95), '95th percentile CPU within the selected window');
						performanceKpis.cpuP99.set(formatPercentValue(summary.cpuP99), '99th percentile CPU within the selected window');
						performanceKpis.memoryAverage.set(formatPercentValue(summary.memoryAverage), 'Average memory during ' + periodLabel);
						performanceKpis.memoryP95.set(formatPercentValue(summary.memoryP95), '95th percentile memory within the selected window');
						performanceKpis.memoryP99.set(formatPercentValue(summary.memoryP99), '99th percentile memory within the selected window');
					}
					if (usageKpis.authorizedUsers) {
						usageKpis.authorizedUsers.set(pool.AuthorizedUserCount, 'Authorised scope remains fixed for this host pool');
					}
					if (usageKpis.dailyUsers) {
						usageKpis.dailyUsers.set(summary.dailyUsersAverage === null ? null : formatValue(summary.dailyUsersAverage), summary.isFullRange ? 'Average distinct users per sampled day' : ('Average distinct users during ' + summary.label));
					}
					if (usageKpis.peakUsers) {
						usageKpis.peakUsers.set(summary.peakUsers, summary.isFullRange ? 'Highest sampled user concurrency across the reporting period' : ('Highest sampled user concurrency during ' + summary.label));
					}
				};
				const performanceTrend = (hasPerformanceData && trendModel) ? createPoolPerformanceTrend(trendModel, applyTrendSelection) : null;
				const hostSummary = document.createElement('section');
				hostSummary.className = 'pool-summary-block host-summary';
				const hostSummaryTitle = document.createElement('h4');
				hostSummaryTitle.className = 'pool-summary-title';
				hostSummaryTitle.textContent = 'Host Summary';
				const divider = document.createElement('div');
				const grid = document.createElement('div');
				grid.className = 'pool-grid host-summary-grid';
				[
					createMetricCard('Host Count', pool.HostCount, 'Registered hosts in this pool'),
					createMetricCard('Hosts Running', pool.HostsRunning, 'Session hosts currently powered on'),
					createMetricCard('Hosts Available', pool.HostsAvailable, 'Hosts available for new sessions'),
					createMetricCard('Hosts Shutdown', pool.HostsShutdown, 'Hosts currently powered off'),
					createMetricCard('Hosts Unavailable', pool.HostsUnavailable, 'Hosts unavailable for broker placement'),
					createMetricCard('Hosts Draining', pool.HostsDraining, 'Hosts set to stop taking new sessions')
				].forEach((card) => grid.appendChild(card));
				hostSummary.append(hostSummaryTitle, grid);
				const details = document.createElement('div');
				details.className = 'pool-details';
				const createStaticPoolSection = (label, content, className) => {
					if (content === null || content === undefined) { return null; }
					const block = document.createElement('section');
					block.className = 'pool-detail-static' + (className ? (' ' + className) : '');
					const heading = document.createElement('h4');
					heading.className = 'pool-detail-static-title';
					heading.textContent = label;
					block.appendChild(heading);
					if (content && typeof content === 'object' && typeof content.nodeType === 'number') {
						block.appendChild(content);
					} else {
						block.appendChild(renderStructuredValue(content, 0));
					}
					return block;
				};
				const sessionHostsSection = createStaticPoolSection(
					'Session Hosts',
					wrapTable(createObjectTable(normalizeCollection(pool.SessionHostDetails), ['Name', 'IpAddress', 'Status', 'Sessions', 'AgentVersion', 'LastHeartBeat', 'AllowNewSession', 'AssignedUser', 'Backup'], { hiddenColumns: ['PublicIpAddress', 'OutboundPublicIpAddress'] })),
					'session-hosts-detail'
				);
				if (sessionHostsSection) {
					details.appendChild(sessionHostsSection);
				}
				const platformDetailSection = createStaticPoolSection('Platform Detail', createPoolPlatformDetails(pool), 'platform-detail-static');
				if (platformDetailSection) {
					details.appendChild(platformDetailSection);
				}
				const tagsSection = createPoolTagsDetails(pool);
				if (tagsSection) {
					details.appendChild(tagsSection);
				}
				[
					['Authorised Access', createPoolAccessDetails(pool)],
					['Diagnostic Insights', hasDiagnosticData ? createPoolDiagnosticInsightsDetails(pool) : null],
				].forEach(([label, value]) => {
					if (value === null || value === undefined) { return; }
					const block = document.createElement('details');
					const summary = document.createElement('summary');
					summary.textContent = label;
					block.appendChild(summary);
					if (value && typeof value === 'object' && typeof value.nodeType === 'number') {
						block.appendChild(value);
					} else {
						block.appendChild(renderStructuredValue(value, 0));
					}
					details.appendChild(block);
				});
				panel.append(header);
				if (subtitle.textContent) {
					panel.append(subtitle);
				}
				panel.append(poolMeta);
				if (usageSummary) {
					panel.append(usageSummary);
				}
				if (performanceEnvelope) {
					panel.append(performanceEnvelope);
				}
				panel.append(hostSummary);
				if (performanceTrend) {
					performanceEnvelope.appendChild(performanceTrend);
				}
				panel.append(divider, details);
				stack.append(anchor, panel);
			});
		}

		function buildStorageAccountSections() {
			const accounts = normalizeCollection(data.StorageAccountScan);
			if (!accounts.length) { return; }
			const section = document.getElementById('storage-account-section');
			const stack = document.getElementById('storage-account-stack');
			if (!section || !stack) { return; }
			section.classList.remove('hidden');
			stack.innerHTML = '';
			accounts.forEach((account, index) => {
				const panel = document.createElement('article');
				panel.className = 'pool-panel storage-account-panel';
				const anchor = document.createElement('span');
				anchor.id = storageAccountAnchorId(account, index);
				anchor.className = 'pool-panel-anchor';
				panel.dataset.anchorId = anchor.id;

				const titleWrap = document.createElement('div');
				titleWrap.className = 'pool-title-wrap';
				const header = document.createElement('div');
				header.className = 'pool-header';
				const title = document.createElement('h3');
				title.textContent = account && account.Name ? account.Name : ('Storage Account ' + (index + 1));
				const subtitle = document.createElement('p');
				subtitle.textContent = (account && account.SubscriptionName && account.ResourceGroup) ? account.ResourceGroup : '';
				titleWrap.append(title);

				const highlights = createChipList([
					{ label: 'Location', value: account.Location, rawValue: account.Location },
					{ label: 'Subscription', value: account.SubscriptionName, rawValue: account.SubscriptionName },
					{ label: 'Resource Group', value: account.ResourceGroup, rawValue: account.ResourceGroup }
				], 'pool-highlights');
				header.append(titleWrap, highlights);

				const meta = createChipList([
					{ label: 'Kind', value: account.Kind },
					{ label: 'SKU', value: account.Sku },
					{ label: 'Replication', value: account.ReplicationType },
					{ label: 'File Shares', value: account.FileShareCount },
					{ label: 'Private Endpoints', value: account.PrivateEndpointCount }
				], 'pool-meta');

				const summary = document.createElement('section');
				summary.className = 'pool-summary-block usage-summary';
				const summaryTitle = document.createElement('h4');
				summaryTitle.className = 'pool-summary-title';
				summaryTitle.textContent = 'Storage Summary';
				const summaryGrid = document.createElement('div');
				summaryGrid.className = 'pool-grid usage storage-summary-grid';
				[
					createMetricCard('Access Keys', account.AccessKeysEnabled ? 'Enabled' : 'Disabled', 'Storage account key access'),
					createMetricCard('Encryption', account.EncryptionType || 'n/a', 'At-rest encryption mode'),
					createMetricCard('Public Network Access', (account.PublicNetworkAccess || 'n/a') + ' (Default Action: ' + (account.NetworkDefaultAction || 'n/a') + ')', 'Public network access mode and default action')
				].forEach((card) => summaryGrid.appendChild(card));
				summary.append(summaryTitle, summaryGrid);

				const details = document.createElement('div');
				details.className = 'pool-details';
				const createStaticStorageSection = (label, content, className) => {
					if (content === null || content === undefined) { return null; }
					const block = document.createElement('section');
					block.className = 'pool-detail-static' + (className ? (' ' + className) : '');
					const heading = document.createElement('h4');
					heading.className = 'pool-detail-static-title';
					heading.textContent = label;
					block.appendChild(heading);
					if (content && typeof content === 'object' && typeof content.nodeType === 'number') {
						block.appendChild(content);
					} else {
						block.appendChild(renderStructuredValue(content, 0));
					}
					return block;
				};
				const storageDetails = createStaticStorageSection('Storage Account Details', createStorageAccountDetails(account), 'storage-account-detail');
				if (storageDetails) {
					details.appendChild(storageDetails);
				}

				panel.append(header);
				if (subtitle.textContent) {
					panel.append(subtitle);
				}
				panel.append(meta, summary, details);
				stack.append(anchor, panel);
			});
		}

		function buildTable(sectionIdPrefix, title, copy, rows, preferredKeys, options) {
			if (!rows.length) { return; }
			document.getElementById(sectionIdPrefix + '-section').classList.remove('hidden');
			document.getElementById(sectionIdPrefix + '-title').textContent = title;
			document.getElementById(sectionIdPrefix + '-copy').textContent = copy;
			const wrap = document.getElementById(sectionIdPrefix + '-wrap');
			wrap.innerHTML = '';
			wrap.appendChild(createObjectTable(rows, preferredKeys, options));
		}

		function buildLicensingSection() {
			const hasLicensingData = data.LicenseSummaryStatus || data.LicenseSummaryUserCount != null || data.UnlicensedUserCount != null || (Array.isArray(data.LicenseSummary) && data.LicenseSummary.length) || (Array.isArray(data.UnlicensedUsers) && data.UnlicensedUsers.length);
			if (!hasLicensingData) { return; }
			const section = document.getElementById('licensing-section');
			const wrap = document.getElementById('licensing-wrap');
			if (!section || !wrap) { return; }
			section.classList.remove('hidden');
			wrap.innerHTML = '';

			const card = document.createElement('article');
			card.className = 'content-sheet wide';
			const body = document.createElement('div');
			body.className = 'content-sheet-body';

			const skipLicenceCheck = !!(data.CommandOptions && data.CommandOptions.SkipLicenceCheck);
			const skippedStatus = /^Skipped$/i.test(String(data.LicenseSummaryStatus || ''));
			const licenceCheckSkipped = skipLicenceCheck || skippedStatus;
			if (skipLicenceCheck || skippedStatus) {
				const alert = document.createElement('div');
				alert.className = 'licensing-alert licensing-alert-skipped';
				alert.textContent = 'Licence check was skipped for this run. Licence summary figures were not collected.';
				body.appendChild(alert);
			}

			if (!licenceCheckSkipped) {
				body.appendChild(createStatList([
					{ label: 'Status', value: data.LicenseSummaryStatus },
					{ label: 'Users Scanned', value: data.LicenseSummaryUserCount },
					{ label: 'Unlicensed Users', value: data.UnlicensedUserCount }
				]));

				const licenceSummaryRows = Array.isArray(data.LicenseSummary) ? data.LicenseSummary.filter((item) => isPlainObject(item)) : [];
				if (licenceSummaryRows.length) {
					const summaryBlock = document.createElement('details');
					summaryBlock.open = true;
					const summaryHeading = document.createElement('summary');
					summaryHeading.textContent = 'Licence Summary • ' + licenceSummaryRows.length + (licenceSummaryRows.length === 1 ? ' item' : ' items');
					summaryBlock.append(summaryHeading, wrapTable(createObjectTable(licenceSummaryRows, ['SkuName', 'Assigned', 'Consumed', 'Available', 'Warning'], { structuredDetailRows: false })));
					body.appendChild(summaryBlock);
				}

				const unlicensedUsers = Array.isArray(data.UnlicensedUsers) ? data.UnlicensedUsers.filter((item) => isPlainObject(item)) : [];
				if (unlicensedUsers.length) {
					const unlicensedBlock = document.createElement('details');
					unlicensedBlock.open = true;
					const unlicensedHeading = document.createElement('summary');
					unlicensedHeading.textContent = 'Unlicensed Users • ' + unlicensedUsers.length + (unlicensedUsers.length === 1 ? ' user' : ' users');
					unlicensedBlock.append(unlicensedHeading, wrapTable(createObjectTable(unlicensedUsers, ['DisplayName', 'UserPrincipalName', 'Status'], { structuredDetailRows: false })));
					body.appendChild(unlicensedBlock);
				}
			}

			card.appendChild(body);
			wrap.appendChild(card);
		}

		function buildStructuredSections(kind) {
			const dataGrid = document.getElementById('data-grid');
			const dataSection = document.getElementById('data-sections');
			if (dataGrid) {
				dataGrid.innerHTML = '';
			}
			const skip = kind === 'metrics'
				? new Set(['CustomerAbbreviation', 'GeneratedBy', 'ProjectCode', 'CollectedAt', 'MetricPeriodStart', 'MetricPeriodEnd', 'LookbackDays', 'ExcludeWeekends', 'PeakHoursOnly', 'UtcOffsetHours', 'HostPools', 'StorageAccountScan', 'CommandOptions', 'AuthenticatedIdentity', 'LicenseSummaryStatus', 'LicenseSummary', 'LicenseSummaryUserCount', 'UnlicensedUserCount', 'UnlicensedUsers', '__ExecutionContext', '__Authentication', '__Licensing', 'ArmCallStats', 'HostPoolCount', 'HtmlGeneration', 'ReportType', 'SubscriptionCount'])
				: new Set(['Applications', 'CustomerAbbreviation', 'GeneratedBy', 'ProjectCode', 'CollectedAt', 'CollectionMode', 'RunningAsAccount', 'DiscoveryType', 'PrimaryApplicationsOnly', 'ApplicationCount']);
			orderedSectionEntries(kind, data).forEach(([key, value]) => {
				if (skip.has(key)) { return; }
				const panel = document.createElement('article');
				panel.className = 'content-sheet' + (isWideSection(key, value, kind) ? ' wide' : '');
				panel.dataset.search = (key + ' ' + JSON.stringify(value)).toLowerCase();
				const head = document.createElement('div');
				head.className = 'content-sheet-head';
				const headingWrap = document.createElement('div');
				headingWrap.className = 'content-sheet-heading';
				const heading = document.createElement('h3');
				heading.textContent = key === '__ExecutionContext' ? 'Execution Context' : key === '__Authentication' ? 'Authenticated Identity' : key === '__Licensing' ? 'Licensing' : formatLabel(key);
				headingWrap.appendChild(heading);
				head.appendChild(headingWrap);
				const body = document.createElement('div');
				body.className = 'content-sheet-body';
				body.appendChild(renderStructuredValue(value, 0));
				const actions = createSectionActions(body);
				if (actions) { head.appendChild(actions); }
				panel.append(head, body);
				dataGrid.appendChild(panel);
			});
			if (dataSection) {
				dataSection.classList.toggle('hidden', !dataGrid || !dataGrid.children.length);
			}
		}

		function init() {
			const kind = reportKind();
			if (typeof primeReportMotion === 'function') { primeReportMotion(); }
			setReportTitle(kind);
			const heroMeta = document.getElementById('hero-meta');
			heroMetaEntries(kind).forEach(([label, value]) => {
				const chip = document.createElement('div');
				chip.className = 'chip';
				chip.innerHTML = '<strong>' + label + ':</strong> <span>' + String(formatValue(value)).replace(/</g, '&lt;') + '</span>';
				heroMeta.appendChild(chip);
			});
			document.getElementById('source-note').textContent = '';
			document.getElementById('raw-json').textContent = JSON.stringify(data, null, 2);
			const kpis = kind === 'metrics' ? metricsSummary() : kind === 'host' ? hostSummary() : Object.keys(data).slice(0, 8).map((key) => ({ label: key, value: data[key], detail: 'Top-level field' }));
			const kpiGrid = document.getElementById('kpi-grid');
			kpis.forEach((item) => kpiGrid.appendChild(createCard(item.label, item.value, item.detail)));
			if (kind === 'metrics') {
				const reportType = metricsReportType();
				const hostPoolColumns = reportType.key === 'basic'
					? ['Name', 'SubscriptionName', 'Location', 'HostPoolType', 'HostCount', 'AuthorizedUserCount']
					: ['Name', 'SubscriptionName', 'Location', 'HostPoolType', 'HostCount', 'AuthorizedUserCount', 'DailyAverageUsers', 'PeakConcurrentSessions', 'AvgCpuPercent', 'AvgMemUsedPercent'];
				buildTable('primary-table', 'Host Pools', 'Per-pool operational, usage, and access summary.', normalizeCollection(data.HostPools), hostPoolColumns);
				buildTable('secondary-table', 'Storage Accounts', 'Per-account storage overview; detailed share and network panels are shown below.', normalizeCollection(data.StorageAccountScan), ['Name', 'SubscriptionName', 'ResourceGroup', 'Location', 'Kind', 'FileShareCount', 'PrivateEndpointCount'], { structuredDetailRows: false, hiddenColumns: ['Sku', 'SkuTier', 'ReplicationType', 'AccessKeysEnabled', 'EncryptionType', 'CmkKeyVaultUri', 'PublicNetworkAccess', 'NetworkDefaultAction', 'NetworkBypass', 'HttpsOnly', 'MinimumTlsVersion', 'PrivateEndpoints', 'IdentityBasedAuth', 'FileService', 'FileShares'] });
				buildHostPoolSections();
				buildStorageAccountSections();
				buildLicensingSection();
			} else if (kind === 'host') {
				buildTable('primary-table', 'Applications', 'Installed application inventory from the host export.', normalizeCollection(data.Applications), ['DisplayName', 'DisplayVersion', 'Publisher', 'InstallDate', 'InstallLocation']);
			}
			buildStructuredSections(kind);
			if (kind === 'metrics') {
				const structuredDataSection = document.getElementById('data-sections');
				const structuredDataHeading = document.querySelector('#data-sections > h2');
				if (structuredDataSection && !structuredDataSection.classList.contains('hidden') && structuredDataHeading) {
					structuredDataHeading.classList.add('hidden');
				}
			}
			if (typeof buildReportNavigation === 'function') { buildReportNavigation(); }
			if (typeof wireInteractiveSurfaces === 'function') { wireInteractiveSurfaces(); }
		}

		init();
