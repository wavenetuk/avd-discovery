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
	const source = String(value);
	const compact = source.replace(/[^A-Za-z0-9]/g, '').toLowerCase();
	const directOverrides = {
		azureadjoined: 'Entra ID Joined',
		hybridazureadjoined: 'Hybrid Entra ID Joined',
		activedirectoryjoined: 'Active Directory Joined',
		workplacejoined: 'Workplace Joined'
	};
	return directOverrides[compact] || source;
}

function formatValue(value) {
	if (value === null || value === undefined || value === '') { return 'None'; }
	if (typeof value === 'boolean') { return value ? 'Yes' : 'No'; }
	if (typeof value === 'number') {
		if (Math.abs(value) >= 1000) { return value.toLocaleString(); }
		return Number.isInteger(value) ? String(value) : value.toFixed(2).replace(/\.00$/, '');
	}
	if (Array.isArray(value)) { return value.length ? value.map((item) => formatDisplayText(item)).join(', ') : 'None'; }
	if (isPlainObject(value)) { return Object.keys(value).length + ' field(s)'; }
	return formatDisplayText(value);
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
		com: 'COM',
		cpu: 'CPU',
		fs: 'FS',
		gp: 'GP',
		html: 'HTML',
		id: 'ID',
		intune: 'Intune',
		json: 'JSON',
		kfm: 'KFM',
		laps: 'LAPS',
		lpt: 'LPT',
		pnp: 'PnP',
		rdp: 'RDP',
		rtc: 'RTC',
		sku: 'SKU',
		sso: 'SSO',
		usb: 'USB',
		upn: 'UPN',
		url: 'URL',
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
	if (kind === 'metrics' && new Set(['CommandOptions', 'ArmCallStats', 'LicenseSummary', 'UnlicensedUsers']).has(key)) { return true; }
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

function orderedSectionEntries(kind, source) {
	const order = kind === 'metrics'
		? ['CustomerAbbreviation', 'CollectedAt', 'MetricPeriodStart', 'MetricPeriodEnd', 'HostPools', 'CommandOptions', 'LicenseSummaryStatus', 'LicenseSummary', 'UnlicensedUsers', 'ArmCallStats']
		: ['__ExecutionContext', 'Machine', 'JoinState', 'EntraSso', 'FSLogix', 'UserProfileExperience', 'RdpShortpath', 'RdpRedirection', 'ActiveDirectoryDependencies', 'AvdConnectivity', 'GroupPolicy', 'Antivirus', 'IntuneEnrollment', 'Laps', 'TeamsMediaOptimization', 'UniversalPrint', 'TimeSource', 'Printers'];
	const rank = new Map(order.map((key, index) => [key, index]));
	const entries = Object.entries(source);
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

function createCard(label, value, detail) {
	const article = document.createElement('article');
	article.className = 'card';
	article.dataset.card = String(label || '').toLowerCase().replace(/[^a-z0-9]+/g, '-');
	const eyebrow = document.createElement('p');
	eyebrow.className = 'eyebrow';
	eyebrow.textContent = label;
	const metric = document.createElement('p');
	metric.className = 'metric';
	metric.textContent = formatValue(value);
	const subtle = document.createElement('p');
	subtle.className = 'subtle';
	subtle.textContent = detail || '';
	article.append(eyebrow, metric, subtle);
	return article;
}

function createSummaryCard(label, value, detail, variant) {
	const card = createCard(label, value, detail);
	if (variant) { card.classList.add(variant); }
	return card;
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

function toBooleanState(value) {
	if (value === null || value === undefined || value === '') { return null; }
	if (typeof value === 'boolean') { return value; }
	if (typeof value === 'number') { return value !== 0; }
	if (typeof value === 'string') {
		const trimmed = value.trim().toLowerCase();
		if (!trimmed) { return null; }
		if (['0', 'false', 'no', 'n', 'not configured', 'notinstalled'].includes(trimmed)) { return false; }
		if (['1', 'true', 'yes', 'y'].includes(trimmed)) { return true; }
		return true;
	}
	return !!value;
}

function yesNoValue(value) {
	const state = toBooleanState(value);
	if (state === null) { return 'None'; }
	return state ? 'Yes' : 'No';
}

function createHostSection(title) {
	const section = document.createElement('section');
	section.className = 'section host-report-section interactive-surface';
	const heading = document.createElement('h2');
	heading.textContent = title;
	const body = document.createElement('div');
	body.className = 'host-report-section-body';
	section.append(heading, body);
	return { section, body };
}

function createHostBlock(title) {
	const block = document.createElement('div');
	block.className = 'host-section-block';
	if (title) {
		const heading = document.createElement('h3');
		heading.className = 'host-section-block-title';
		heading.textContent = title;
		block.appendChild(heading);
	}
	return block;
}

function appendHostStatBlock(body, title, items) {
	const block = createHostBlock(title);
	block.appendChild(createStatList(items));
	body.appendChild(block);
	return block;
}

function appendHostTableBlock(body, title, rows, preferredKeys) {
	const block = createHostBlock(title);
	block.appendChild(wrapTable(createObjectTable(rows, preferredKeys)));
	body.appendChild(block);
	return block;
}

function projectRows(rows, keys) {
	return (rows || []).map((row) => {
		const projected = {};
		(keys || []).forEach((key) => {
			if (!row || !Object.prototype.hasOwnProperty.call(row, key)) { return; }
			projected[key] = row[key];
		});
		return projected;
	});
}

function objectEntriesRows(source) {
	return Object.entries(source || {}).map(([key, value]) => ({ Setting: formatLabel(key), Value: value }));
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

function createObjectTable(rows, preferredKeys) {
	if (!rows.length) {
		const empty = document.createElement('p');
		empty.className = 'muted';
		empty.textContent = 'No rows available.';
		return empty;
	}
	const table = document.createElement('table');
	const columns = objectArrayColumns(rows, preferredKeys);
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
		const tr = document.createElement('tr');
		tr.dataset.search = JSON.stringify(row).toLowerCase();
		columns.forEach((column) => {
			const td = document.createElement('td');
			td.textContent = formatValue(row ? row[column] : null);
			tr.appendChild(td);
		});
		tbody.appendChild(tr);
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

function renderStructuredValue(value, depth) {
	const level = depth || 0;
	if (value && typeof value === 'object' && typeof value.nodeType === 'number') {
		return value;
	}
	if (value === null || value === undefined || value === '') {
		const empty = document.createElement('span');
		empty.className = 'muted';
		empty.textContent = 'None';
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
			body.appendChild(renderStructuredValue(item, level + 1));
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
				dd.textContent = formatValue(child);
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
		body.appendChild(renderStructuredValue(child, level + 1));
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

function hostSummary() {
	const fsLogix = data.FSLogix || {};
	const adDeps = data.ActiveDirectoryDependencies || {};
	const joinType = formatDisplayText(data.JoinState && data.JoinState.JoinType ? data.JoinState.JoinType : 'n/a');
	const isActiveDirectoryJoined = /active directory joined/i.test(joinType);
	const fsLogixDiscovered = !!(
		fsLogix.Installed ||
		fsLogix.ConfigDetected ||
		(fsLogix.ServiceStatus && fsLogix.ServiceStatus !== 'NotInstalled') ||
		toNumber(fsLogix.ProfileContainerCount) > 0 ||
		normalizeCollection(fsLogix.ProfileLocationInventory).length
	);
	const heroCards = [
		{ label: 'Applications', value: data.ApplicationCount || normalizeCollection(data.Applications).length, detail: 'Installed apps included in the export' },
		{ label: 'FSLogix', value: fsLogixDiscovered ? 'Found' : 'Missing', detail: 'Profile container platform status' },
		{ label: 'Join Type', value: joinType, detail: 'Detected device join state', variant: 'join-type' }
	];
	if (isActiveDirectoryJoined) {
		heroCards.push({ label: 'AD Dependencies', value: adDeps.HasDomainDependencies ? 'Present' : 'None', detail: 'Services, tasks, ODBC, and live port usage' });
	}
	return heroCards;
}

function createTitleFlag(glyph, label, tone) {
	const flag = document.createElement('span');
	flag.className = 'report-title-flag' + (tone ? ' ' + tone : '');
	const labelNode = document.createElement('span');
	labelNode.className = 'report-title-flag-label';
	labelNode.textContent = label;
	if (glyph) {
		flag.dataset.flagCode = glyph;
	}
	flag.append(labelNode);
	return flag;
}

function hostTitleFlags() {
	const flags = [];
	if (data.ConnectivityChecksSkipped) {
		flags.push({ glyph: 'CC', label: 'Connectivity Checks Skipped', tone: 'warning' });
	}
	if (data.PrimaryApplicationsOnly) {
		flags.push({ glyph: 'PA', label: 'Primary Applications Only' });
	}
	return flags;
}

function setReportTitle(flags) {
	const title = document.getElementById('report-title');
	if (!title) { return; }
	title.innerHTML = '';
	const text = document.createElement('span');
	text.className = 'report-title-text';
	text.textContent = REPORT_TITLE;
	title.appendChild(text);
	if (!flags.length) { return; }
	const wrap = document.createElement('span');
	wrap.className = 'report-title-flags';
	flags.forEach((flag) => wrap.appendChild(createTitleFlag(flag.glyph, flag.label, flag.tone)));
	title.appendChild(wrap);
}

function buildTable(sectionIdPrefix, title, copy, rows, preferredKeys) {
	if (!rows.length) { return; }
	document.getElementById(sectionIdPrefix + '-section').classList.remove('hidden');
	document.getElementById(sectionIdPrefix + '-title').textContent = title;
	document.getElementById(sectionIdPrefix + '-copy').textContent = copy;
	const wrap = document.getElementById(sectionIdPrefix + '-wrap');
	wrap.innerHTML = '';
	wrap.appendChild(createObjectTable(rows, preferredKeys));
}

function hasRenderableValue(value) {
	if (value === null || value === undefined || value === '') { return false; }
	if (Array.isArray(value)) { return value.length > 0; }
	if (isPlainObject(value)) { return Object.keys(value).length > 0; }
	return true;
}

function pickObjectFields(source, keys) {
	const result = {};
	(keys || []).forEach((key) => {
		if (!source || !Object.prototype.hasOwnProperty.call(source, key)) { return; }
		const value = source[key];
		if (!hasRenderableValue(value)) { return; }
		result[key] = value;
	});
	return result;
}

function createGroupedSection(title, entries) {
	if (!entries.length) { return null; }
	const panel = document.createElement('section');
	panel.className = 'section host-report-section';
	panel.dataset.search = entries.map((entry) => {
		const key = Array.isArray(entry) ? entry[0] : entry.key;
		const value = Array.isArray(entry) ? entry[1] : entry.value;
		return key + ' ' + JSON.stringify(value);
	}).join(' ').toLowerCase();
	const heading = document.createElement('h2');
	heading.textContent = title;
	const body = document.createElement('div');
	body.className = 'host-report-section-body';
	entries.forEach((entry) => {
		const key = Array.isArray(entry) ? entry[0] : entry.key;
		const value = Array.isArray(entry) ? entry[1] : entry.value;
		const titleText = Array.isArray(entry) ? (key === '__ExecutionContext' ? 'Execution Context' : formatLabel(key)) : (entry.title || (key === '__ExecutionContext' ? 'Execution Context' : formatLabel(key)));
		const block = document.createElement('section');
		block.className = 'host-section-block';
		block.dataset.search = (key + ' ' + JSON.stringify(value)).toLowerCase();
		if (entries.length > 1 || titleText !== title) {
			const blockHeading = document.createElement('h4');
			blockHeading.className = 'host-section-block-title';
			blockHeading.textContent = titleText;
			block.appendChild(blockHeading);
		}
		block.appendChild(renderStructuredValue(value, 0));
		body.appendChild(block);
	});
	panel.append(heading, body);
	return panel;
}

function createHostApplicationsSection() {
	const applications = normalizeCollection(data.Applications);
	if (!applications.length) { return null; }
	const section = createHostSection('Applications');
	section.body.appendChild(wrapTable(createObjectTable(applications, ['Name', 'Publisher', 'InstallDate', 'Version', 'InstallLocation'])));
	return section.section;
}

function createSystemDetailsSection() {
	const section = createHostSection('System Details');
	const machine = data.Machine || {};
	appendHostStatBlock(section.body, 'Machine', [
 		{ label: 'Hostname', value: machine.Hostname },
 		{ label: 'Manufacturer', value: machine.Manufacturer },
 		{ label: 'Model', value: machine.Model }
 	]);
	const joinState = data.JoinState || {};
	const dsReg = joinState.DsRegStatus || {};
	const joinType = formatDisplayText(joinState.JoinType || 'None');
	const joinRows = [{ label: 'Join Type', value: joinType }];
	if (/active directory joined/i.test(joinType)) {
		joinRows.push({ label: 'Domain', value: joinState.Domain || machine.Domain });
	} else if (/entra id joined/i.test(joinType) || /azure ad joined/i.test(joinType)) {
		joinRows.push({ label: 'Tenant Name', value: dsReg.TenantName });
		joinRows.push({ label: 'Tenant ID', value: dsReg.TenantId });
	}
	appendHostStatBlock(section.body, 'Directory Join Type', joinRows);

	const intune = data.IntuneEnrollment || {};
	appendHostStatBlock(section.body, 'Intune Enrolled', [
		{ label: 'Intune Enrolled', value: yesNoValue(intune.Enrolled) }
	]);
	if (toBooleanState(intune.Enrolled)) {
		const records = normalizeCollection(intune.IntuneEnrollmentRecords);
		if (records.length) {
			appendHostTableBlock(section.body, 'Intune Enrollment Records', projectRows(records, ['EnrollmentId', 'ProviderID', 'UPN', 'AADTenantId', 'EnrollmentType', 'EnrollmentState']), ['EnrollmentId', 'ProviderID', 'UPN', 'AADTenantId', 'EnrollmentType', 'EnrollmentState']);
		}
	}
	return section.section;
}

function createAntivirusSection() {
	const antivirus = data.Antivirus || {};
	const section = createHostSection('Antivirus');
	const securityCenterProducts = normalizeCollection(antivirus.InstalledApplicationMatches);
	appendHostTableBlock(section.body, 'Security Center Products', projectRows(securityCenterProducts, ['Publisher', 'Version']), ['Publisher', 'Version']);
	return section.section;
}

function createLapsSection() {
	const laps = data.Laps || {};
	const section = createHostSection('LAPS');
	const inUse = toBooleanState(laps.InUse);
	const typeLabel = laps.WindowsLapsConfigured ? 'Windows LAPS' : (laps.LegacyLapsConfigured ? 'Legacy LAPS' : 'Not in use');
	appendHostStatBlock(section.body, 'In Use', [
		{ label: 'In Use', value: inUse ? typeLabel : 'No' }
	]);
	if (inUse && laps.WindowsLapsPolicy) {
		appendHostStatBlock(section.body, 'Windows LAPS Policy', [
			{ label: 'Administrator Account Name', value: laps.WindowsLapsPolicy.AdministratorAccountName },
			{ label: 'Password Age Days', value: laps.WindowsLapsPolicy.PasswordAgeDays },
			{ label: 'Password Length', value: laps.WindowsLapsPolicy.PasswordLength },
			{ label: 'Password Complexity', value: yesNoValue(toBooleanState(laps.WindowsLapsPolicy.PasswordComplexity)) }
		]);
	}
	return section.section;
}

function createTimeSourceSection() {
	const timeSource = data.TimeSource || {};
	const section = createHostSection('Time Source');
	appendHostStatBlock(section.body, 'Time Source', [
		{ label: 'Configured Source', value: timeSource.ConfiguredSource },
		{ label: 'Configured Type', value: timeSource.ConfiguredType }
	]);
	return section.section;
}

function createFsLogixSection() {
	const fs = data.FSLogix || {};
	const section = createHostSection('FSLogix');
	const glyphs = document.createElement('div');
	glyphs.className = 'fslogix-glyph-grid';
	glyphs.append(
		createSummaryCard('Profile Container Count', fs.ProfileContainerCount == null ? 'n/a' : fs.ProfileContainerCount, 'Detected profile containers'),
		createSummaryCard('Profile Count Total GB', fs.ProfileContainerTotalGB == null ? 'n/a' : fs.ProfileContainerTotalGB, 'Total profile container size')
	);
	section.body.appendChild(glyphs);
	appendHostStatBlock(section.body, 'Configuration and Components', [
		{ label: 'Installed', value: yesNoValue(fs.Installed) },
		{ label: 'Config Detected', value: yesNoValue(fs.ConfigDetected) },
		{ label: 'Cloud Cache in Use', value: yesNoValue(fs.CloudCacheInUse) }
	]);
	const appMasking = fs.AppMasking || {};
	appendHostStatBlock(section.body, 'App Masking', [
		{ label: 'Configured', value: yesNoValue(appMasking.Configured) },
		{ label: 'Rule File Count', value: normalizeCollection(appMasking.RuleDirectories).length }
	]);
	appendHostTableBlock(section.body, 'Rule Directories', projectRows(normalizeCollection(appMasking.RuleDirectories), ['Path', 'TypeHint', 'Exists', 'IsDirectory', 'IsFile', 'SizeGB', 'LastWriteTime']), ['Path', 'TypeHint', 'Exists', 'IsDirectory', 'IsFile', 'SizeGB', 'LastWriteTime']);
	appendHostTableBlock(section.body, 'Redirections', projectRows(normalizeCollection(fs.RedirectionsXml), ['ComponentName', 'Configured', 'RedirectionsXmlInUse', 'SourceFolders', 'RedirectionsXmlFiles']), ['ComponentName', 'Configured', 'RedirectionsXmlInUse', 'SourceFolders', 'RedirectionsXmlFiles']);
	return section.section;
}

function createUserProfileExperienceSection() {
	const upe = data.UserProfileExperience || {};
	const section = createHostSection('User Profile Experience');
	appendHostStatBlock(section.body, 'Profile Usage', [
		{ label: 'Known Folder Move', value: yesNoValue((upe.UsersWithKnownFolderMove || 0) > 0) },
		{ label: 'Folder Redirection', value: yesNoValue((upe.UsersWithFolderRedirection || 0) > 0) },
		{ label: 'Redirected Folders', value: yesNoValue((upe.RedirectedFolderCount || 0) > 0) },
		{ label: 'Mapped Drives', value: yesNoValue((upe.UsersWithMappedDrives || 0) > 0) },
		{ label: 'Current Session Mapped Drives', value: yesNoValue((upe.CurrentSessionMappedDriveCount || 0) > 0) }
	]);
	const policies = upe.OneDrivePolicies || {};
	appendHostStatBlock(section.body, 'OneDrive Policies', [
		{ label: 'Policy Detected', value: yesNoValue(policies.PolicyDetected) },
		{ label: 'KFM Silent Opt in Tenant ID', value: policies.KFMSilentOptInTenantId },
		{ label: 'KFM Silent Opt In With Notify', value: yesNoValue(policies.KFMSilentOptInWithNotify) },
		{ label: 'KFM Block Opt In', value: yesNoValue(policies.KFMBlockOptIn) },
		{ label: 'KFM Block Opt Out', value: yesNoValue(policies.KFMBlockOptOut) },
		{ label: 'Silent Move Desktop Enabled', value: yesNoValue(policies.SilentMoveDesktopEnabled) },
		{ label: 'Silent Move Documents Enabled', value: yesNoValue(policies.SilentMoveDocumentsEnabled) },
		{ label: 'Silent Move Pictures Enabled', value: yesNoValue(policies.SilentMovePicturesEnabled) }
	]);
	appendHostTableBlock(section.body, 'OneDrive Policy Locations', projectRows(normalizeCollection(policies.PolicyLocations), ['RegistryPath', 'Source']), ['RegistryPath', 'Source']);
	const groupPolicyRows = objectEntriesRows(data.GroupPolicyRawValues || {});
	if (groupPolicyRows.length) {
		appendHostTableBlock(section.body, 'Group Policy', groupPolicyRows, ['Setting', 'Value']);
	}
	const defaultFileAssociations = data.DefaultFileAssociations || {};
	appendHostStatBlock(section.body, 'Default File Associations', [
		{ label: 'Configured', value: yesNoValue(defaultFileAssociations.Configured) },
		{ label: 'Effective XML Path', value: defaultFileAssociations.EffectiveXmlPath },
		{ label: 'Effective XML File', value: defaultFileAssociations.EffectiveXmlFile }
	]);
	appendHostTableBlock(section.body, 'Policy Locations', projectRows(normalizeCollection(defaultFileAssociations.PolicyLocations), ['RegistryPath', 'Source']), ['RegistryPath', 'Source']);
	const languagePacks = data.LanguagePacks || {};
	appendHostStatBlock(section.body, 'Language Packs', [
		{ label: 'Query Succeeded', value: yesNoValue(languagePacks.CapabilityQuerySucceeded) },
		{ label: 'System Locale', value: languagePacks.SystemLocale }
	]);
	appendHostTableBlock(section.body, 'Current User Languages', projectRows(normalizeCollection(languagePacks.CurrentUserLanguages), ['LanguageTag', 'Autonym', 'EnglishName']), ['LanguageTag', 'Autonym', 'EnglishName']);
	appendHostTableBlock(section.body, 'Loaded User Mapped Drive States', projectRows(normalizeCollection(upe.LoadedUserMappedDriveStates), ['AccountName', 'MappedDrivesPresent', 'MappedDriveCount']), ['AccountName', 'MappedDrivesPresent', 'MappedDriveCount']);
	appendHostTableBlock(section.body, 'Loaded User Folder States', projectRows(normalizeCollection(upe.LoadedUserFolderStates), ['AccountName', 'ProfilePath', 'UserShellFoldersAvailable', 'LikelyOneDriveKnownFolderMove', 'LikelyFolderRedirection', 'RedirectedFolderCount']), ['AccountName', 'ProfilePath', 'UserShellFoldersAvailable', 'LikelyOneDriveKnownFolderMove', 'LikelyFolderRedirection', 'RedirectedFolderCount']);
	return section.section;
}

function createOfficeDetailsSection() {
	const office = data.OutlookCachedMode || {};
	const teams = data.TeamsMediaOptimization || {};
	const section = createHostSection('Office Details');
	appendHostStatBlock(section.body, 'Outlook Cached Mode', [
		{ label: 'Policy Configured', value: yesNoValue(office.PolicyConfigured) }
	]);
	if (toBooleanState(office.PolicyConfigured)) {
		appendHostTableBlock(section.body, 'Machine Policy Settings', projectRows(normalizeCollection(office.MachinePolicySettings), ['Setting', 'Value', 'Source']), ['Setting', 'Value', 'Source']);
		appendHostTableBlock(section.body, 'User Settings', projectRows(normalizeCollection(office.UserSettings), ['Setting', 'Value', 'Source']), ['Setting', 'Value', 'Source']);
	}
	appendHostStatBlock(section.body, 'Teams Media Optimisations', [
		{ label: 'Classic Teams Optimisations', value: yesNoValue(teams.OptimizationReadyClassicTeams) },
		{ label: 'New Teams Optimisations', value: yesNoValue(teams.OptimizationReadyNewTeams) },
		{ label: 'Web RTC Redirector Installed', value: yesNoValue(teams.WebRtcRedirectorInstalled) },
		{ label: 'AVD Environment Flag Set', value: yesNoValue(teams.IsWvdEnvironmentFlagSet) }
	]);
	return section.section;
}

function createRdpRedirectionRows(rdp) {
	const rows = [];
	const addRow = (property, sourceObject, valueKey) => {
		if (!sourceObject) { return; }
		rows.push({
			Property: property,
			Enabled: yesNoValue(sourceObject[valueKey || 'Enabled'] ?? sourceObject.Value),
			Source: sourceObject.Source || 'None'
		});
	};
	addRow('RDP Connections Allowed', rdp.RdpConnectionsAllowed, 'Enabled');
	addRow('Network Level Auth Required', rdp.NetworkLevelAuthRequired, 'Enabled');
	addRow('Clipboard Redirection', rdp.ClipboardRedirection);
	addRow('Drive Redirection', rdp.DriveRedirection);
	addRow('Printer Redirection', rdp.PrinterRedirection);
	addRow('COM Port Redirection', rdp.ComPortRedirection);
	addRow('LPT Port Redirection', rdp.LptPortRedirection);
	addRow('Smart Card Redirection', rdp.SmartCardRedirection);
	addRow('Audio Playback Redirection', rdp.AudioPlaybackRedirection);
	addRow('Audio Capture Redirection', rdp.AudioCaptureRedirection);
	addRow('Video Capture Redirection', rdp.VideoCaptureRedirection);
	addRow('USB Redirection', rdp.UsbRedirection);
	addRow('PnP Device Redirection', rdp.PnpDeviceRedirection);
	return rows;
}

function createAccessAndConnectivitySection() {
	const adDeps = data.ActiveDirectoryDependencies || {};
	const avdConnectivity = data.AvdConnectivity || {};
	const rdpShortpath = data.RdpShortpath || {};
	const rdpRedirection = data.RdpRedirection || {};
	const section = createHostSection('Access and Connectivity');
	appendHostStatBlock(section.body, 'Active Directory Dependencies', [
		{ label: 'Domain Dependencies', value: yesNoValue(adDeps.HasDomainDependencies) },
		{ label: 'Domain Service Count', value: adDeps.DomainServiceCount },
		{ label: 'Domain Scheduled Task Count', value: adDeps.DomainScheduledTaskCount },
		{ label: 'Domain ODBC Source Count', value: adDeps.DomainOdbcSourceCount },
		{ label: 'Config File Reference Count', value: adDeps.ConfigFileReferenceCount },
		{ label: 'AD Port Connections', value: normalizeCollection(adDeps.AdPortConnections).length }
	]);
	appendHostTableBlock(section.body, 'AD Port Connections', normalizeCollection(adDeps.AdPortConnections), ['Name', 'Source', 'Target', 'Port', 'Protocol']);
	if (avdConnectivity && Object.keys(avdConnectivity).length) {
		appendHostStatBlock(section.body, 'AVD Connectivity', objectEntriesRows(avdConnectivity));
	}
	appendHostStatBlock(section.body, 'RDP Shortpath', [
		{ label: 'Shortpath in Use', value: yesNoValue(rdpShortpath.ShortpathUsedRecently || toBooleanState(rdpShortpath.ManagedNetworkShortpath && rdpShortpath.ManagedNetworkShortpath.Enabled) || toBooleanState(rdpShortpath.PublicNetworkShortpath && rdpShortpath.PublicNetworkShortpath.Enabled)) },
	]);
	appendHostTableBlock(section.body, 'Recent Shortpath Events', normalizeCollection(rdpShortpath.RecentShortpathEvents), objectArrayColumns(normalizeCollection(rdpShortpath.RecentShortpathEvents), []));
	appendHostStatBlock(section.body, 'Managed Network Shortpath', [
		{ label: 'Enabled', value: yesNoValue(rdpShortpath.ManagedNetworkShortpath && rdpShortpath.ManagedNetworkShortpath.Enabled) },
		{ label: 'Source', value: rdpShortpath.ManagedNetworkShortpath && rdpShortpath.ManagedNetworkShortpath.Source },
		{ label: 'UDP Port', value: rdpShortpath.ManagedNetworkShortpath && rdpShortpath.ManagedNetworkShortpath.UdpPort }
	]);
	appendHostStatBlock(section.body, 'Public Network Shortpath', [
		{ label: 'Enabled', value: yesNoValue(rdpShortpath.PublicNetworkShortpath && rdpShortpath.PublicNetworkShortpath.Enabled) },
		{ label: 'ICE Control Value (STUN)', value: rdpShortpath.PublicNetworkShortpath && (rdpShortpath.PublicNetworkShortpath.ICEControlDisplay || rdpShortpath.PublicNetworkShortpath.ICEControlValue) }
	]);
	appendHostTableBlock(section.body, 'RDP Redirection', createRdpRedirectionRows(rdpRedirection), ['Property', 'Enabled', 'Source']);
	return section.section;
}

function createPrintingSection() {
	const universalPrint = data.UniversalPrint || {};
	const printers = data.Printers || {};
	const section = createHostSection('Printing');
	appendHostStatBlock(section.body, 'Universal Print', [
		{ label: 'In Use', value: yesNoValue(universalPrint.InUse) },
		{ label: 'Connector Installed', value: yesNoValue(universalPrint.ConnectorInstalled) },
		{ label: 'Connector Config', value: universalPrint.ConnectorConfig ? formatValue(universalPrint.ConnectorConfig) : 'None' }
	]);
	appendHostTableBlock(section.body, 'Cloud Printers', normalizeCollection(universalPrint.CloudPrinters), ['Name', 'ShareName', 'DriverName', 'PrinterStatus']);
	appendHostTableBlock(section.body, 'Printers', normalizeCollection(printers.Printers), ['Name', 'DriverName', 'DriverVersion', 'DriverProvider', 'PortName', 'Shared', 'ShareName', 'PrinterStatus', 'Type']);
	return section.section;
}

function buildHostStructuredSections() {
	const page = document.querySelector('.page');
	const dataSection = document.getElementById('data-sections');
	const primaryTableSection = document.getElementById('primary-table-section');
	const secondaryTableSection = document.getElementById('secondary-table-section');
	const licensingSection = document.getElementById('licensing-section');
	Array.from(document.querySelectorAll('.page > .host-report-section')).forEach((node) => node.remove());
	if (primaryTableSection) { primaryTableSection.classList.add('hidden'); }
	if (secondaryTableSection) { secondaryTableSection.classList.add('hidden'); }
	if (licensingSection) { licensingSection.classList.add('hidden'); }
	if (!page || !dataSection) { return; }
	dataSection.classList.add('hidden');
	const sections = [
		createSystemDetailsSection(),
		createAntivirusSection(),
		createLapsSection(),
		createTimeSourceSection(),
		createHostApplicationsSection(),
		createFsLogixSection(),
		createUserProfileExperienceSection(),
		createOfficeDetailsSection(),
		createAccessAndConnectivitySection(),
		createPrintingSection()
	].filter(Boolean);
	sections.forEach((section) => {
		page.insertBefore(section, dataSection);
	});
}

function init() {
	const kind = reportKind();
	if (typeof primeReportMotion === 'function') { primeReportMotion(); }
	setReportTitle(hostTitleFlags());
	const heroMeta = document.getElementById('hero-meta');
	heroMetaEntries(kind).forEach(([label, value]) => {
		const chip = document.createElement('div');
		chip.className = 'chip';
		chip.innerHTML = '<strong>' + label + ':</strong> <span>' + String(formatValue(value)).replace(/</g, '&lt;') + '</span>';
		heroMeta.appendChild(chip);
	});
	document.getElementById('source-note').textContent = '';
	document.getElementById('raw-json').textContent = JSON.stringify(data, null, 2);
	const kpis = kind === 'host' ? hostSummary() : Object.keys(data).slice(0, 8).map((key) => ({ label: key, value: data[key], detail: 'Top-level field' }));
	const kpiGrid = document.getElementById('kpi-grid');
	kpis.forEach((item) => kpiGrid.appendChild(createSummaryCard(item.label, item.value, item.detail, item.variant)));
	buildHostStructuredSections();
	if (typeof buildReportNavigation === 'function') { buildReportNavigation(); }
	if (typeof wireInteractiveSurfaces === 'function') { wireInteractiveSurfaces(); }
}

init();
