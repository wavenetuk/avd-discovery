function wireInteractiveSurfaces() {
	document.querySelectorAll('.card, .chip, .badge, .data-card, .section, details, .table-wrap, .toolbar input, .section-button').forEach((node) => {
		if (node.dataset.interactiveBound === '1') { return; }
		node.dataset.interactiveBound = '1';
		node.classList.add('interactive-surface');
	});
}

function escapeHtml(value) {
	return String(value || '')
		.replace(/&/g, '&amp;')
		.replace(/</g, '&lt;')
		.replace(/>/g, '&gt;');
}

function formatJsonSyntax(value) {
	return escapeHtml(value).replace(/("(\\u[a-fA-F0-9]{4}|\\[^u]|[^\\"])*"(\s*:)?|\btrue\b|\bfalse\b|\bnull\b|-?\d+(?:\.\d+)?(?:[eE][+\-]?\d+)?)/g, function (token) {
		var className = 'json-token-number';
		if (/^"/.test(token)) {
			className = /:$/.test(token) ? 'json-token-key' : 'json-token-string';
		} else if (/true|false/.test(token)) {
			className = 'json-token-boolean';
		} else if (/null/.test(token)) {
			className = 'json-token-null';
		}
		return '<span class="' + className + '">' + token + '</span>';
	});
}

function wireJsonViewModal() {
	const trigger = document.getElementById('json-view-trigger');
	const modal = document.getElementById('json-view-modal');
	const backdrop = document.getElementById('json-view-backdrop');
	const closeButton = document.getElementById('json-view-close');
	const copyButton = document.getElementById('json-view-copy');
	const rawJson = document.getElementById('raw-json');
	const meta = document.getElementById('json-view-meta');
	if (!trigger || !modal || !backdrop || !closeButton || !copyButton || !rawJson || trigger.dataset.modalBound === '1') { return; }
	trigger.dataset.modalBound = '1';
	let lastFocusedElement = null;
	let copyResetTimer = null;

	const syncJsonContent = function () {
		if (rawJson.dataset.rendering === '1') { return; }
		const sourceText = rawJson.textContent || rawJson.dataset.sourceText || '';
		if (!sourceText) {
			rawJson.dataset.sourceText = '';
			rawJson.dataset.renderedText = '';
			rawJson.innerHTML = '';
			if (meta) {
				meta.textContent = '';
			}
			return;
		}
		if (sourceText === rawJson.dataset.renderedText) {
			if (meta) {
				meta.textContent = '';
			}
			return;
		}
		rawJson.dataset.sourceText = sourceText;
		rawJson.dataset.renderedText = sourceText;
		rawJson.dataset.rendering = '1';
		rawJson.innerHTML = formatJsonSyntax(sourceText);
		rawJson.dataset.rendering = '0';
		if (meta) {
			meta.textContent = '';
		}
	};

	const setCopyLabel = function (label) {
		copyButton.textContent = label;
		if (copyResetTimer) {
			clearTimeout(copyResetTimer);
		}
		if (label !== 'Copy') {
			copyResetTimer = setTimeout(function () {
				copyButton.textContent = 'Copy';
				copyResetTimer = null;
			}, 1800);
		}
	};

	const copyJson = function () {
		const sourceText = rawJson.dataset.sourceText || rawJson.textContent || '';
		if (!sourceText) {
			setCopyLabel('No Data');
			return;
		}
		if (navigator.clipboard && typeof navigator.clipboard.writeText === 'function') {
			navigator.clipboard.writeText(sourceText).then(function () {
				setCopyLabel('Copied');
			}).catch(function () {
				setCopyLabel('Failed');
			});
			return;
		}
		const helper = document.createElement('textarea');
		helper.value = sourceText;
		helper.setAttribute('readonly', 'readonly');
		helper.style.position = 'fixed';
		helper.style.opacity = '0';
		document.body.appendChild(helper);
		helper.focus();
		helper.select();
		try {
			document.execCommand('copy');
			setCopyLabel('Copied');
		} catch (error) {
			setCopyLabel('Failed');
		}
		document.body.removeChild(helper);
	};

	const openModal = function () {
		syncJsonContent();
		lastFocusedElement = document.activeElement;
		modal.hidden = false;
		modal.setAttribute('aria-hidden', 'false');
		document.body.classList.add('json-view-open');
		closeButton.focus();
	};

	const closeModal = function () {
		modal.hidden = true;
		modal.setAttribute('aria-hidden', 'true');
		document.body.classList.remove('json-view-open');
		if (lastFocusedElement && typeof lastFocusedElement.focus === 'function') {
			lastFocusedElement.focus();
		} else {
			trigger.focus();
		}
	};

	const observer = new MutationObserver(function () {
		if (rawJson.dataset.rendering === '1') { return; }
		syncJsonContent();
	});
	observer.observe(rawJson, { childList: true, characterData: true, subtree: true });

	trigger.addEventListener('click', openModal);
	copyButton.addEventListener('click', copyJson);
	closeButton.addEventListener('click', closeModal);
	backdrop.addEventListener('click', closeModal);
	modal.addEventListener('click', function (event) {
		if (event.target === modal) {
			closeModal();
		}
	});
	document.addEventListener('keydown', function (event) {
		if (event.key === 'Escape' && !modal.hidden) {
			closeModal();
		}
	});
	syncJsonContent();
}

function tidyReportToolbar() {
	const toolbar = document.querySelector('.toolbar');
	if (!toolbar) { return; }
	const hasVisibleContent = Array.from(toolbar.children).some(function (node) {
		return !!(node.textContent && node.textContent.trim());
	});
	toolbar.classList.toggle('hidden', !hasVisibleContent);
}

function wireThemeToggle() {
	const toggle = document.getElementById('theme-toggle');
	if (!toggle || toggle.dataset.themeBound === '1') { return; }
	toggle.dataset.themeBound = '1';
	const root = document.documentElement;
	const media = window.matchMedia ? window.matchMedia('(prefers-color-scheme: dark)') : null;

	const getStoredTheme = function () {
		try {
			const value = localStorage.getItem('avd-report-theme');
			return value === 'light' || value === 'dark' ? value : null;
		} catch (error) {
			return null;
		}
	};

	const setStoredTheme = function (value) {
		try {
			if (!value) {
				localStorage.removeItem('avd-report-theme');
				return;
			}
			localStorage.setItem('avd-report-theme', value);
		} catch (error) {
			// Ignore storage failures and continue with in-memory theme state.
		}
	};

	const resolveAutoTheme = function () {
		return media && media.matches ? 'dark' : 'light';
	};

	const syncToggleState = function () {
		const currentTheme = root.dataset.theme === 'dark' ? 'dark' : 'light';
		const nextTheme = currentTheme === 'dark' ? 'light' : 'dark';
		toggle.textContent = nextTheme === 'dark' ? 'Dark Mode' : 'Light Mode';
		toggle.setAttribute('aria-label', 'Switch to ' + nextTheme + ' mode');
		toggle.setAttribute('aria-pressed', currentTheme === 'dark' ? 'true' : 'false');
	};

	const applyTheme = function (theme, animate) {
		root.dataset.theme = theme === 'dark' ? 'dark' : 'light';
		syncToggleState();
	};

	const applyPreferredTheme = function () {
		const storedTheme = getStoredTheme();
		applyTheme(storedTheme || resolveAutoTheme(), false);
	};

	toggle.addEventListener('click', function () {
		const currentTheme = root.dataset.theme === 'dark' ? 'dark' : 'light';
		const nextTheme = currentTheme === 'dark' ? 'light' : 'dark';
		setStoredTheme(nextTheme);
		applyTheme(nextTheme, true);
	});

	if (media) {
		const syncWithSystemTheme = function () {
			if (getStoredTheme()) { return; }
			applyTheme(resolveAutoTheme(), true);
		};
		if (typeof media.addEventListener === 'function') {
			media.addEventListener('change', syncWithSystemTheme);
		} else if (typeof media.addListener === 'function') {
			media.addListener(syncWithSystemTheme);
		}
	}

	applyPreferredTheme();
}

function primeReportMotion() {
	if (document.body.classList.contains('report-ready')) { return; }
	requestAnimationFrame(() => {
		const toolbar = document.querySelector('.toolbar');
		if (toolbar) {
			toolbar.style.setProperty('--report-enter-delay', '40ms');
		}
		document.querySelectorAll('.kpi-grid > *').forEach((node, index) => {
			node.style.setProperty('--report-enter-delay', (80 + (index * 40)) + 'ms');
		});
		let sectionDelay = 180;
		document.querySelectorAll('.page > .section:not(.hidden), #data-grid > .editorial-section, #data-grid > .host-structured-section, #host-pool-stack > .pool-panel').forEach((node) => {
			node.style.setProperty('--report-enter-delay', sectionDelay + 'ms');
			sectionDelay += 60;
		});
		document.body.classList.add('report-ready');
	});
}

function updateReportStickyOffset() {
	const nav = document.querySelector('.report-nav');
	const root = document.documentElement;
	if (!root) { return; }
	if (!nav) {
		root.style.setProperty('--report-sticky-offset', '92px');
		return;
	}
	const navRect = nav.getBoundingClientRect();
	const topOffset = Math.max(navRect.top, 10);
	const offset = Math.ceil(topOffset + navRect.height + 10);
	root.style.setProperty('--report-sticky-offset', offset + 'px');
}

function wireDynamicStickyOffset() {
	if (document.documentElement.dataset.reportStickyOffsetBound === '1') { return; }
	document.documentElement.dataset.reportStickyOffsetBound = '1';
	updateReportStickyOffset();
	window.addEventListener('resize', updateReportStickyOffset);
	if (typeof ResizeObserver === 'function') {
		const nav = document.querySelector('.report-nav');
		if (nav) {
			const observer = new ResizeObserver(() => updateReportStickyOffset());
			observer.observe(nav);
		}
	}
	requestAnimationFrame(() => updateReportStickyOffset());
}

function wireReportNavigationRail(navLinks) {
	const navShell = document.getElementById('report-nav-links-shell');
	const navRail = document.getElementById('report-nav-rail');
	const prevButton = document.getElementById('report-nav-scroll-prev');
	const nextButton = document.getElementById('report-nav-scroll-next');
	if (!navLinks || !navShell || !navRail || !prevButton || !nextButton || navLinks.dataset.overflowBound === '1') { return; }
	navLinks.dataset.overflowBound = '1';
	const scrollStep = () => Math.max(Math.round(navShell.clientWidth * 0.72), 140);

	const syncOverflowState = () => {
		const maxScrollLeft = Math.max(navShell.scrollWidth - navShell.clientWidth, 0);
		const hasOverflow = maxScrollLeft > 8;
		const hasLeftOverflow = navShell.scrollLeft > 8;
		const hasRightOverflow = (maxScrollLeft - navShell.scrollLeft) > 8;
		navShell.dataset.overflow = hasOverflow ? '1' : '0';
		navShell.dataset.leftOverflow = hasLeftOverflow ? '1' : '0';
		navShell.dataset.rightOverflow = hasRightOverflow ? '1' : '0';
		navRail.dataset.overflow = hasOverflow ? '1' : '0';
		navRail.dataset.leftOverflow = hasLeftOverflow ? '1' : '0';
		navRail.dataset.rightOverflow = hasRightOverflow ? '1' : '0';
		prevButton.disabled = !hasLeftOverflow;
		nextButton.disabled = !hasRightOverflow;
	};

	const handleWheel = (event) => {
		if (navShell.scrollWidth <= navShell.clientWidth) { return; }
		const intendsHorizontalScroll = event.shiftKey || Math.abs(event.deltaX) > Math.abs(event.deltaY);
		if (!intendsHorizontalScroll) { return; }
		event.preventDefault();
		navShell.scrollLeft += event.shiftKey && Math.abs(event.deltaY) > Math.abs(event.deltaX)
			? event.deltaY
			: event.deltaX;
	};

	const scrollRail = (direction) => {
		navShell.scrollBy({ left: scrollStep() * direction, behavior: 'smooth' });
	};

	navShell.addEventListener('scroll', syncOverflowState, { passive: true });
	navShell.addEventListener('wheel', handleWheel, { passive: false });
	prevButton.addEventListener('click', () => scrollRail(-1));
	nextButton.addEventListener('click', () => scrollRail(1));
	window.addEventListener('resize', syncOverflowState);
	if (typeof ResizeObserver === 'function') {
		const observer = new ResizeObserver(() => syncOverflowState());
		observer.observe(navShell);
		observer.observe(navLinks);
		observer.observe(navRail);
	}
	syncOverflowState();
	requestAnimationFrame(syncOverflowState);
}

function revealActiveNavigationLink(navLinks, activeId, force) {
	if (!navLinks || !activeId) { return; }
	const activeLink = navLinks.querySelector('.report-nav-link[data-target="' + activeId + '"]') || navLinks.querySelector('.report-nav-flyout-link[data-target="' + activeId + '"]');
	if (!activeLink) { return; }
	const owner = activeLink.classList.contains('report-nav-flyout-link')
		? activeLink.closest('.report-nav-item') && activeLink.closest('.report-nav-item').querySelector('.report-nav-link')
		: activeLink;
	const targetLink = owner || activeLink;
	if (!targetLink || typeof targetLink.scrollIntoView !== 'function') { return; }
	if (!force && window.innerWidth > 1100) { return; }
	targetLink.scrollIntoView({ behavior: force ? 'auto' : 'smooth', block: 'nearest', inline: 'center' });
}

function slugifyNavLabel(value) {
	return String(value || '')
		.toLowerCase()
		.replace(/[^a-z0-9]+/g, '-')
		.replace(/^-+|-+$/g, '');
}

function ensureSectionAnchor(section, fallbackId) {
	if (!section) { return null; }
	if (section.id) { return section.id; }
	section.id = fallbackId;
	return section.id;
}

function createNavigationEntry(id, label, node, children) {
	return {
		id,
		label,
		node,
		children: Array.isArray(children) ? children : []
	};
}

function getHostPoolNavigationChildren(section) {
	if (!section || section.classList.contains('hidden')) { return []; }
	return Array.from(section.querySelectorAll('#host-pool-stack > .pool-panel'))
		.filter((node) => !node.classList.contains('hidden'))
		.map((node, childIndex) => {
			const heading = node.querySelector('.pool-header h3, h3');
			const label = heading && heading.textContent && heading.textContent.trim()
				? heading.textContent.trim()
				: 'Host Pool ' + (childIndex + 1);
			const anchorId = node.dataset.anchorId || ensureSectionAnchor(node, 'report-host-pool-' + slugifyNavLabel(label || childIndex));
			return createNavigationEntry(anchorId, label, node);
		});
}

function getStorageAccountNavigationChildren(section) {
	if (!section || section.classList.contains('hidden')) { return []; }
	return Array.from(section.querySelectorAll('#storage-account-stack > .pool-panel'))
		.filter((node) => !node.classList.contains('hidden'))
		.map((node, childIndex) => {
			const heading = node.querySelector('.pool-header h3, h3');
			const label = heading && heading.textContent && heading.textContent.trim()
				? heading.textContent.trim()
				: 'Storage Account ' + (childIndex + 1);
			const anchorId = node.dataset.anchorId || ensureSectionAnchor(node, 'report-storage-account-' + slugifyNavLabel(label || childIndex));
			return createNavigationEntry(anchorId, label, node);
		});
}

function getSectionNavigationEntries(section, index) {
	if (!section || section.classList.contains('hidden')) { return []; }
	if (section.id === 'host-pool-section') {
		return [];
	}
	if (section.id === 'storage-account-section') {
		return [];
	}
	if (section.id === 'data-sections') {
		const groupedSections = Array.from(section.querySelectorAll('#data-grid > .editorial-section, #data-grid > .host-structured-section')).filter((node) => !node.classList.contains('hidden'));
		if (groupedSections.length) {
			return groupedSections.map((node, childIndex) => {
				const heading = node.querySelector('.editorial-section-head h3, .content-sheet-head h3');
				const label = heading && heading.textContent && heading.textContent.trim()
					? heading.textContent.trim()
					: 'Details ' + (childIndex + 1);
				return createNavigationEntry(ensureSectionAnchor(node, 'report-structured-' + slugifyNavLabel(label || childIndex)), label, node);
			});
		}
	}
	const heading = section.querySelector('h2');
	if (!heading) { return []; }
	if (heading.classList.contains('hidden')) { return []; }
	const label = heading.textContent && heading.textContent.trim()
		? heading.textContent.trim()
		: 'Section ' + (index + 1);
	return [createNavigationEntry(ensureSectionAnchor(section, 'report-section-' + slugifyNavLabel(label || index)), label, section)];
}

function navigateToReportTarget(id) {
	const target = document.getElementById(id);
	if (!target) { return; }
	const stickyOffset = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--report-sticky-offset')) || 92;
	smoothScrollReportTo(target, stickyOffset);
	if (window.location.hash !== '#' + id) {
		history.replaceState(null, '', '#' + id);
	}
}

let reportScrollAnimationFrame = null;
let reportScrollSettleHandler = null;

function smoothScrollReportTo(target, stickyOffset) {
	if (!target) { return; }
	const resolveTargetTop = () => Math.max(0, target.getBoundingClientRect().top + (window.scrollY || window.pageYOffset || 0) - stickyOffset);
	const startTop = window.scrollY || window.pageYOffset || 0;
	const targetTop = resolveTargetTop();
	const distance = targetTop - startTop;
	const absoluteDistance = Math.abs(distance);
	if (absoluteDistance < 1) {
		window.scrollTo(0, targetTop);
		if (typeof reportScrollSettleHandler === 'function') {
			reportScrollSettleHandler();
		}
		return;
	}
	if (window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
		window.scrollTo(0, targetTop);
		if (typeof reportScrollSettleHandler === 'function') {
			reportScrollSettleHandler();
		}
		return;
	}
	if (reportScrollAnimationFrame !== null) {
		cancelAnimationFrame(reportScrollAnimationFrame);
		reportScrollAnimationFrame = null;
	}
	if (absoluteDistance <= 80) {
		window.scrollTo(0, targetTop);
		if (typeof reportScrollSettleHandler === 'function') {
			reportScrollSettleHandler();
		}
		return;
	}
	const isLongScroll = absoluteDistance > 240;
	const duration = !isLongScroll
		? Math.max(110, Math.min(180, absoluteDistance * 0.55))
		: Math.max(360, Math.min(900, absoluteDistance * 0.06));
	const startTime = performance.now();
	const easeOutCubic = (value) => 1 - Math.pow(1 - value, 3);
	const easeInOutCubic = (value) => (value < 0.5)
		? 4 * value * value * value
		: 1 - Math.pow(-2 * value + 2, 3) / 2;
	const step = (now) => {
		const progress = Math.min(1, (now - startTime) / duration);
		const easedProgress = isLongScroll ? easeInOutCubic(progress) : easeOutCubic(progress);
		const liveTargetTop = isLongScroll ? resolveTargetTop() : targetTop;
		const nextTop = startTop + ((liveTargetTop - startTop) * easedProgress);
		window.scrollTo(0, nextTop);
		if (progress < 1) {
			reportScrollAnimationFrame = requestAnimationFrame(step);
			return;
		}
		window.scrollTo(0, resolveTargetTop());
		reportScrollAnimationFrame = null;
		if (typeof reportScrollSettleHandler === 'function') {
			reportScrollSettleHandler();
		}
	};
	reportScrollAnimationFrame = requestAnimationFrame(step);
}

function collectNavigationEntries(entries) {
	const flat = [];
	entries.forEach((entry) => {
		flat.push(entry);
		(entry.children || []).forEach((child) => flat.push(child));
	});
	return flat;
}

function buildReportNavigation() {
	const navLinks = document.getElementById('report-nav-links');
	if (!navLinks) { return; }
	tidyReportToolbar();
	wireThemeToggle();
	wireDynamicStickyOffset();
	wireReportNavigationRail(navLinks);
	wireJsonViewModal();

	const sections = [];
	const hero = document.querySelector('.page > .hero');
	if (hero) {
		sections.push(createNavigationEntry(ensureSectionAnchor(hero, 'report-overview'), 'Overview', hero));
	}

	Array.from(document.querySelectorAll('.page > section'))
		.forEach((section, index) => {
			sections.push.apply(sections, getSectionNavigationEntries(section, index));
		});

	const hostPoolSection = document.getElementById('host-pool-section');
	const hostPoolChildren = getHostPoolNavigationChildren(hostPoolSection);
	if (hostPoolChildren.length) {
		const hostPoolEntry = sections.find((entry) => entry.id === 'primary-table-section' || entry.label === 'Host Pools');
		if (hostPoolEntry) {
			hostPoolEntry.id = hostPoolSection.id;
			hostPoolEntry.node = hostPoolSection;
			hostPoolEntry.children = hostPoolChildren;
		}
	}

	const storageAccountSection = document.getElementById('storage-account-section');
	const storageAccountChildren = getStorageAccountNavigationChildren(storageAccountSection);
	if (storageAccountChildren.length) {
		const storageAccountEntry = sections.find((entry) => entry.id === 'secondary-table-section' || entry.label === 'Storage Accounts');
		if (storageAccountEntry) {
			storageAccountEntry.id = storageAccountSection.id;
			storageAccountEntry.node = storageAccountSection;
			storageAccountEntry.children = storageAccountChildren;
		}
	}

	navLinks.innerHTML = '';
	sections.forEach((section) => {
		const item = document.createElement('div');
		item.className = 'report-nav-item' + ((section.children || []).length ? ' has-flyout' : '');
		const link = document.createElement('a');
		link.className = 'report-nav-link';
		link.href = '#' + section.id;
		link.dataset.target = section.id;
		link.textContent = section.label;
		link.addEventListener('click', (event) => {
			event.preventDefault();
			navigateToReportTarget(section.id);
		});
		item.appendChild(link);
		if ((section.children || []).length) {
			const flyout = document.createElement('div');
			flyout.className = 'report-nav-flyout';
			section.children.forEach((child) => {
				const childLink = document.createElement('a');
				childLink.className = 'report-nav-flyout-link';
				childLink.href = '#' + child.id;
				childLink.dataset.target = child.id;
				childLink.textContent = child.label;
				childLink.addEventListener('click', (event) => {
					event.preventDefault();
					navigateToReportTarget(child.id);
				});
				flyout.appendChild(childLink);
			});
			item.appendChild(flyout);
		}
		navLinks.appendChild(item);
	});

	const flattenedSections = collectNavigationEntries(sections);
	let lastActiveId = null;
	let activeSyncFrame = null;

	const syncActive = () => {
		const threshold = 140;
		let active = flattenedSections[0] || null;
		flattenedSections.forEach((section) => {
			const rect = section.node.getBoundingClientRect();
			if (rect.top <= threshold) {
				active = section;
			}
		});
		navLinks.querySelectorAll('.report-nav-link').forEach((link) => {
			const owner = sections.find((entry) => entry.id === link.dataset.target);
			const childMatch = owner && (owner.children || []).some((child) => child.id === (active && active.id));
			link.classList.toggle('active', !!active && (link.dataset.target === active.id || childMatch));
		});
		navLinks.querySelectorAll('.report-nav-flyout-link').forEach((link) => {
			link.classList.toggle('active', !!active && link.dataset.target === active.id);
		});
		if (active && active.id !== lastActiveId) {
			revealActiveNavigationLink(navLinks, active.id, lastActiveId === null);
			lastActiveId = active.id;
		}
	};
	const scheduleSyncActive = () => {
		if (reportScrollAnimationFrame !== null) { return; }
		if (activeSyncFrame !== null) { return; }
		activeSyncFrame = requestAnimationFrame(() => {
			activeSyncFrame = null;
			syncActive();
		});
	};
	reportScrollSettleHandler = syncActive;

	syncActive();
	window.addEventListener('scroll', scheduleSyncActive, { passive: true });
	window.addEventListener('resize', scheduleSyncActive);
}
