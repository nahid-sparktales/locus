import { ISLAND_QUARTERS, canOpenIslandQuarters } from './islandQuarters';
import type { QuartersIslandID } from './islandQuarters';
import { isSailingArea, sailingHarbors, SAILING_AREA_NAMES } from './sailingArea';
import type { SailingArea } from './sailingArea';
import { createCaptainsQuarters } from './captainsQuarters';
import { GRAND_LINE_LANDMARKS, GRAND_LINE_MAP_RADIUS, GRAND_LINE_CALM_BELT, MARY_GEOISE } from './grandLineGeography';
import { OutpostWorld } from './world';
import { SnailAlert } from './snailAlert';
import { centerEntries } from './snailAlertState';
import type { ActivityTab, CenterEntry } from './snailAlertState';
import { unseenRecentTransfers } from './fleetActivity';
import { DEFAULT_THEME, SHIP_ASSET_TYPES, SHIP_NAMES, parseTheme, parseCatalog } from './theme';
import type { ShipAssetType, ThemeChoice } from './theme';
import { STATUS_META, SECTOR_SIZE, agentSector, clampSector, isResidentStyle, parseHostMessage, parseShipStyles, searchAgents, sectorAgents } from './state';
import type { Agent, ResidentStyle, Snapshot, WorldMessage } from './state';

declare global {
  interface Window {
    webkit?: { messageHandlers?: { locusScreen?: { postMessage: (message: WorldMessage) => void } } };
    locusAgentWorld: { receive: (message: unknown) => void; toggleActivityCenter: () => void };
  }
}

const el = <T extends HTMLElement = HTMLElement>(id: string): T => document.getElementById(id) as T;
const bridge = window.webkit?.messageHandlers?.locusScreen;
const demo = !bridge;
document.body.dataset.demo = String(demo);
document.body.dataset.nativeChrome = String(!demo);
el('theme-button').hidden = !demo;
const seenTransfers = new Set<string>();
const activityButtons = new Map<string, HTMLButtonElement>();
const rosterCards = new Map<string, { element: HTMLDivElement; button: HTMLButtonElement; picker: HTMLSelectElement }>();
const ISLAND_QUARTERS_PREFERENCE = 'locus.agentWorld.islandQuartersEnabled.v1';
const SHIP_STYLE_PREFERENCE = 'locus.agentWorld.demoShipStyles.v1';
let pendingFocusAgentID: string | undefined;
let snapshot: Snapshot = { version: 1, type: 'snapshot', agents: [], theme: 'outpost', projectName: '' };
let world: OutpostWorld | undefined;
let sector = 0;
let nativeVisible = true;
let themeChoices: ThemeChoice[] = [{ id: 'outpost', name: 'Orbital Locus Outpost' }];
let loadedTheme: string | undefined;
let ocean = false;
let sailingArea: SailingArea = 'whole';
const fleetSize = () => snapshot.theme === 'grand-line' ? Math.min(SECTOR_SIZE, sailingHarbors(sailingArea).length) : SECTOR_SIZE;
let residentStyle: ResidentStyle = 'mixed';
let navigationMode: 'orbit' | 'pan' = 'orbit';
let loadingTheme: string | undefined;
let themeGeneration = 0;
let noteTimer: ReturnType<typeof setTimeout> | undefined;
let disposed = false;
let activityTab: ActivityTab = 'attention';
let standaloneResidentsOpen = false;
let lastPlacements = '';
const knownPlacements = new Map<string, { agentID: string; ship: string; home: string }>();
const snailAlert = new SnailAlert(el('snail-alert'), toggleActivityCenter);
const quarters = createCaptainsQuarters(() => snapshot.agents, id => world?.getAgentHome(id), selectAgent);

const send = (message: WorldMessage): void => { try { bridge?.postMessage(message); } catch { el('live-label').textContent = 'Connection unavailable'; } };
const announce = (message: string): void => { el('screen-reader-status').textContent = message; };
function updatePreviewURL(): void {
  if (!demo) return;
  const url = new URL(window.location.href);
  url.searchParams.set('theme', loadedTheme ?? snapshot.theme);
  url.searchParams.set('residentStyle', residentStyle);
  url.searchParams.set('sailingArea', sailingArea);
  history.replaceState(null, '', url);
}
function showNote(message: string): void {
  const note = el('selection-note'); note.textContent = message; note.hidden = false;
  if (noteTimer) clearTimeout(noteTimer);
  noteTimer = setTimeout(() => { note.hidden = true; }, 5000);
}

function applyActivity(): void {
  if (!world) return;
  const fresh = ocean && loadedTheme === snapshot.theme ? unseenRecentTransfers(snapshot.transfers ?? [], seenTransfers, Date.now() / 1000) : [];
  world.setActivity(snapshot.attentionRequests ?? [], fresh);
}
function openAttention(requestID: string): void {
  const request = snapshot.attentionRequests?.find(item => item.id === requestID);
  if (!request) return;
  if (demo) { showNote(`Demo request. In Locus, this opens the exact approval or input request in the agent workspace. No request was sent.`); return; }
  send({ version: 1, type: 'openAttention', requestID });
}
function openTransfer(transferID: string): void {
  const transfer = snapshot.transfers?.find(item => item.id === transferID);
  if (!transfer) return;
  if (demo) { showNote('This courier illustrates a sample handoff. In Locus, it opens the actual handoff or artifact details. No task is running.'); return; }
  send({ version: 1, type: 'openTransfer', transferID });
}
function setActivityCenterOpen(open: boolean, focus = true): void {
  if (open && snapshot.nativeChrome) { send({ version: 1, type: 'openActivityCenter' }); return; }
  if (open && ocean && standaloneResidentsOpen) {
    standaloneResidentsOpen = false;
    el('resident-preview-panel').hidden = true;
    el('residents-button').setAttribute('aria-expanded', 'false');
  }
  el('fleet-activity').hidden = !open;
  document.body.dataset.activityCenter = String(open);
  snailAlert.setExpanded(open);
  if (focus) {
    if (open) el(activityTab === 'attention' ? 'attention-tab' : 'activity-tab').focus();
    else snailAlert.focus();
  }
}
function toggleActivityCenter(): void { setActivityCenterOpen(el('fleet-activity').hidden); }
function selectActivityTab(tab: ActivityTab, focus = false): void {
  activityTab = tab;
  renderActivity();
  if (focus) el(tab === 'attention' ? 'attention-tab' : 'activity-tab').focus();
}
function openCenterEntry(entry: CenterEntry): void {
  if (entry.target.kind === 'request') openAttention(entry.target.id);
  else if (entry.target.kind === 'transfer') openTransfer(entry.target.id);
  else selectAgent(entry.target.id);
}
function renderActivity(): void {
  const requests = snapshot.attentionRequests ?? [], transfers = snapshot.transfers ?? [];
  const attention = centerEntries(snapshot.agents, requests, transfers, 'attention', ocean);
  const activity = centerEntries(snapshot.agents, requests, transfers, 'activity', ocean);
  const working = snapshot.agents.filter(agent => agent.status === 'working').length;
  snailAlert.update(attention.length, working, demo);
  el<HTMLButtonElement>('new-agent').disabled = !demo && snapshot.canCreateAgent !== true;
  el('new-agent').title = demo ? 'Agent creation is available in Locus' : snapshot.canCreateAgent ? 'Create an agent in this world' : 'Agent creation is unavailable in this world';
  el('shared-chat').textContent = ocean ? 'Crew Chat' : 'Shared chat';
  el('agent-controls-title').textContent = ocean ? 'Captain’s Quarters' : 'Agent workspace';
  el('quarters-open').hidden = !demo || !ocean;
  renderIslandSettings();
  const selected = snapshot.agents.find(agent => agent.id === snapshot.selectedAgentID);
  el('agent-controls-name').textContent = selected?.name ?? (ocean ? 'Choose a captain or manage your fleet' : 'Manage your agents');
  el('attention-count').textContent = String(attention.length);
  el('activity-count').textContent = String(activity.length);
  el('activity-working').textContent = String(working);
  el('activity-waiting').textContent = String(snapshot.agents.filter(agent => agent.status === 'idle').length);
  el('activity-connection').textContent = demo ? 'Demo' : 'Live';
  const centerTitle = ocean ? 'Activity Center' : 'Mission Control';
  el('activity-title').textContent = centerTitle;
  el('activity-close').setAttribute('aria-label', `Close ${centerTitle}`);
  el('activity-eyebrow').textContent = ocean ? 'THE CREW’S COMMUNICATIONS' : 'OUTPOST COMMUNICATIONS';
  el('activity-working-label').textContent = 'working';
  el('activity-waiting-label').textContent = 'available';
  el('activity-sound-label').textContent = ocean ? 'Pururururu…' : 'Signal online';
  document.querySelector('.activity-overview')!.setAttribute('aria-label', ocean ? 'Crew status' : 'Agent status');
  document.querySelector('.activity-tabs')!.setAttribute('aria-label', `${centerTitle} view`);
  el('activity-caption').textContent = demo ? `Sample ${ocean ? 'crew' : 'agent'} activity. No tasks are running.` : ocean ? 'Your crew, on the same wavelength.' : 'Your agents, connected and in view.';
  el('activity-footer-label').textContent = demo ? 'DEMO FREQUENCY' : ocean ? 'DEN DEN NETWORK' : 'LOCUS COMMUNICATIONS';
  for (const tab of ['attention', 'activity'] as const) {
    el(`${tab}-tab`).setAttribute('aria-selected', String(tab === activityTab));
    el(`${tab}-tab`).tabIndex = tab === activityTab ? 0 : -1;
  }
  el('activity-content').setAttribute('aria-labelledby', `${activityTab}-tab`);
  const entries = activityTab === 'attention' ? attention : activity;
  const list = el('activity-list');
  const entryIDs = new Set(entries.map(entry => entry.id));
  for (const [id, button] of activityButtons) if (!entryIDs.has(id)) { button.remove(); activityButtons.delete(id); }
  const icons: Record<CenterEntry['kind'], string> = { approval: '!', input: '?', handoff: '⇄', artifact: '◇', idle: '⚓', working: '≈', queued: '◷', completed: '✓', failed: '!', needs_attention: '!' };
  entries.forEach((entry, index) => {
    let button = activityButtons.get(entry.id);
    if (!button) {
      button = document.createElement('button'); button.type = 'button'; button.className = 'activity-item';
      const icon = document.createElement('span'); icon.className = 'activity-item-icon'; icon.setAttribute('aria-hidden', 'true');
      const content = document.createElement('span'); content.className = 'activity-item-content';
      const meta = document.createElement('span'); meta.className = 'activity-item-meta';
      const label = document.createElement('span'); label.className = 'activity-item-label';
      const time = document.createElement('time'); time.className = 'activity-item-time';
      meta.append(label, time);
      const title = document.createElement('strong'); title.className = 'activity-item-title';
      const detail = document.createElement('span'); detail.className = 'activity-item-detail';
      content.append(meta, title, detail);
      const arrow = document.createElement('span'); arrow.className = 'activity-item-arrow'; arrow.textContent = '↗'; arrow.setAttribute('aria-hidden', 'true');
      button.append(icon, content, arrow);
      button.addEventListener('click', () => openCenterEntry(entry)); activityButtons.set(entry.id, button);
    }
    button.dataset.kind = entry.kind;
    button.dataset.targetKind = entry.target.kind;
    button.dataset.targetId = entry.target.id;
    button.querySelector('.activity-item-icon')!.textContent = icons[entry.kind];
    button.querySelector('.activity-item-label')!.textContent = entry.label;
    button.querySelector('.activity-item-title')!.textContent = entry.title;
    button.querySelector('.activity-item-detail')!.textContent = entry.detail;
    const time = button.querySelector('time')!;
    time.hidden = entry.occurredAt === undefined;
    if (entry.occurredAt !== undefined) {
      const date = new Date(entry.occurredAt * 1000);
      time.dateTime = date.toISOString();
      time.textContent = date.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
      time.title = date.toLocaleString();
    }
    button.setAttribute('aria-label', `${entry.label}. ${entry.title}. ${entry.detail}. Open ${entry.target.kind === 'agent' ? 'agent workspace' : entry.target.kind === 'request' ? 'request' : 'delivery'}.`);
    if (list.children[index] !== button) list.insertBefore(button, list.children[index] ?? null);
  });
  el('activity-empty').hidden = entries.length > 0;
  el('activity-empty-mark').textContent = activityTab === 'attention' ? '✓' : '≈';
  el('activity-empty-title').textContent = activityTab === 'attention' ? 'Nothing needs attention' : ocean ? 'A quiet moment at sea' : 'All systems calm';
  el('activity-empty-copy').textContent = activityTab === 'attention' ? ocean ? 'Your crew has the helm. We’ll ring when they need you.' : 'Your agents are all set. We’ll signal when they need you.' : ocean ? 'Work in progress, completed voyages, and crew deliveries appear here.' : 'Work in progress, completed tasks, handoffs, and artifacts appear here.';
}

function publishResidentPlacements(): void {
  if (demo || !world || loadedTheme !== snapshot.theme) return;
  const validIDs = new Set(snapshot.agents.map(agent => agent.id));
  for (const id of knownPlacements.keys()) if (!validIDs.has(id) || !ocean) knownPlacements.delete(id);
  if (ocean) for (const agent of snapshot.agents) {
    const appearance = world?.getAgentAppearance(agent.id);
    const ship = appearance && (SHIP_ASSET_TYPES as readonly string[]).includes(appearance) ? SHIP_NAMES[appearance as ShipAssetType] : undefined;
    const home = world?.getAgentHome(agent.id);
    if (ship && home) knownPlacements.set(agent.id, { agentID: agent.id, ship, home });
  }
  const visibleIDs = new Set(sectorAgents(snapshot.agents, sector, fleetSize()).map(agent => agent.id));
  const placements = [...knownPlacements.values()].sort((a, b) => Number(visibleIDs.has(b.agentID)) - Number(visibleIDs.has(a.agentID))).slice(0, 500);
  const fingerprint = JSON.stringify(placements);
  if (fingerprint === lastPlacements) return;
  lastPlacements = fingerprint;
  send({ version: 1, type: 'residentPlacements', placements });
}

function selectAgent(id: string): void {
  const agent = snapshot.agents.find(item => item.id === id);
  if (!agent) return;
  const nextSector = agentSector(snapshot.agents, id, fleetSize());
  sector = nextSector;
  snapshot = { ...snapshot, selectedAgentID: id };
  updateWorldAgents();
  world?.focusResident(id);
  applyActivity();
  renderRoster();
  send({ version: 1, type: 'selectAgent', agentID: id });
  announce(`${agent.name} selected. ${STATUS_META[agent.status].label}.`);
  if (demo) showNote(`${agent.name} is a demo ${ocean ? 'captain' : 'resident'}. The camera follows their ship. In Locus, Captain’s Quarters also has chats and tools.`);
}

function selectAdjacentAgent(direction: -1 | 1): void {
  if (!snapshot.agents.length) return;
  const current = snapshot.agents.findIndex(agent => agent.id === snapshot.selectedAgentID);
  const index = current < 0 ? (direction > 0 ? 0 : snapshot.agents.length - 1) : (current + direction + snapshot.agents.length) % snapshot.agents.length;
  selectAgent(snapshot.agents[index].id);
}

function clearAgentSelection(): void {
  if (!snapshot.selectedAgentID) return;
  snapshot = { ...snapshot, selectedAgentID: undefined };
  pendingFocusAgentID = undefined;
  updateWorldAgents(); renderRoster(); world?.resetView();
  if (!demo) send({ version: 1, type: 'clearSelection' });
  announce('Ship selection cleared. Camera returned to the world overview.');
}

function openIslandQuarters(id: QuartersIslandID): void {
  if (!canOpenIslandQuarters(id, snapshot.islandQuartersEnabled !== false, loadedTheme ?? snapshot.theme)) return;
  el<HTMLDetailsElement>('world-settings').open = false;
  if (demo) quarters.open(id);
  else send({ version: 1, type: 'openIslandQuarters', islandID: id });
  announce(`Captain’s Quarters · ${ISLAND_QUARTERS[id].name}`);
}

function renderIslandSettings(): void {
  const enabled = snapshot.islandQuartersEnabled !== false;
  el('world-settings').hidden = !demo || !ocean;
  el<HTMLInputElement>('island-quarters-enabled').checked = enabled;
  el('island-destinations').hidden = !enabled;
  world?.setIslandQuartersEnabled(enabled);
  renderNavigation();
}

function updateWorldAgents(): void {
  world?.setIslandQuartersEnabled(snapshot.islandQuartersEnabled !== false);
  world?.setSailingArea(sailingArea);
  world?.setShipStyles(snapshot.shipStyles ?? {});
  world?.setAgents(sectorAgents(snapshot.agents, sector, fleetSize()), snapshot.selectedAgentID);
}

function setAgentShipStyle(agentID: string, style: string): void {
  const agent = snapshot.agents.find(item => item.id === agentID);
  if (!agent || (style && !(SHIP_ASSET_TYPES as readonly string[]).includes(style))) return;
  if (!demo) {
    send({ version: 1, type: 'setShipStyle', agentID, shipStyle: style ? style as ShipAssetType : null });
    renderRoster();
    return;
  }
  const shipStyles = { ...snapshot.shipStyles };
  if (style) shipStyles[agentID] = style as ShipAssetType;
  else delete shipStyles[agentID];
  snapshot = { ...snapshot, shipStyles };
  updateWorldAgents();
  renderRoster();
  try { localStorage.setItem(SHIP_STYLE_PREFERENCE, JSON.stringify(shipStyles)); } catch { /* Preview preferences are optional. */ }
  announce(`${agent.name} ${style ? `now sails aboard ${SHIP_NAMES[style as ShipAssetType]}` : 'now uses their automatically assigned boat'}.`);
}

function renderRoster(): void {
  el('resident-count').textContent = String(snapshot.agents.length);
  el('project-name').textContent = snapshot.projectName || (demo ? 'A preview of your next workspace' : 'Select a project in Locus');
  el('project-name').title = snapshot.projectName;
  el('live-label').textContent = demo ? `Demo ${ocean ? 'fleet' : 'residents'} · no model calls` : 'Connected to Locus';
  const totalSectors = Math.max(1, Math.ceil(snapshot.agents.length / fleetSize()));
  el('sector-label').textContent = `${String(sector + 1).padStart(2, '0')} / ${String(totalSectors).padStart(2, '0')}`;
  el('coordinate-sector').textContent = String(sector + 1).padStart(2, '0');
  const working = snapshot.agents.filter(agent => agent.status === 'working').length;
  const attention = snapshot.agents.filter(agent => agent.status === 'needs_attention' || agent.status === 'failed').length;
  el('agent-navigation').hidden = !snapshot.selectedAgentID;
  el('working-count').textContent = working ? `${working} agent${working === 1 ? '' : 's'} at work` : attention ? `${attention} need${attention === 1 ? 's' : ''} your attention` : ocean ? 'Calm seas' : 'All systems calm';
  const list = el('resident-list');
  const filtered = searchAgents(snapshot.agents, el<HTMLInputElement>('resident-search').value);
  const displayed = new Set(filtered.map(agent => agent.id));
  for (const [id, card] of rosterCards) if (!displayed.has(id)) { card.element.remove(); rosterCards.delete(id); }
  const oldEmpty = list.querySelector('.search-empty'); oldEmpty?.remove();
  filtered.forEach((agent, index) => {
    let card = rosterCards.get(agent.id);
    if (!card) {
      const element = document.createElement('div'); element.className = 'resident-card';
      const button = document.createElement('button'); button.className = 'resident-row'; button.type = 'button'; button.dataset.agentId = agent.id;
      const avatar = document.createElement('span'); avatar.className = `resident-avatar variant-${snapshot.agents.indexOf(agent) % 4}`; avatar.setAttribute('aria-hidden', 'true');
      const text = document.createElement('span'); text.className = 'resident-text';
      const name = document.createElement('span'); name.className = 'resident-name';
      const role = document.createElement('span'); role.className = 'resident-role';
      const state = document.createElement('span'); state.className = 'resident-state'; state.setAttribute('aria-hidden', 'true');
      text.append(name, role); button.append(avatar, text, state);
      button.addEventListener('click', () => selectAgent(agent.id));
      const shipControl = document.createElement('label'); shipControl.className = 'resident-ship-picker';
      const pickerLabel = document.createElement('span'); pickerLabel.textContent = 'Boat';
      const picker = document.createElement('select'); picker.setAttribute('aria-label', `Boat style for ${agent.name}`);
      const automatic = document.createElement('option'); automatic.value = ''; automatic.textContent = 'Automatic assignment'; picker.append(automatic);
      for (const style of SHIP_ASSET_TYPES) { const option = document.createElement('option'); option.value = style; option.textContent = SHIP_NAMES[style]; picker.append(option); }
      picker.addEventListener('change', () => setAgentShipStyle(agent.id, picker.value));
      shipControl.append(pickerLabel, picker); element.append(button, shipControl);
      card = { element, button, picker }; rosterCards.set(agent.id, card);
    }
    const { button, picker } = card;
    picker.parentElement!.hidden = !ocean || !demo;
    picker.setAttribute('aria-label', `Boat style for ${agent.name}`);
    picker.value = snapshot.shipStyles?.[agent.id] ?? '';
    const avatar = button.querySelector<HTMLElement>('.resident-avatar')!;
    const appearance = ocean ? world?.getAgentAppearance(agent.id) : undefined;
    const ship = appearance && (SHIP_ASSET_TYPES as readonly string[]).includes(appearance) ? appearance as ShipAssetType : undefined;
    avatar.dataset.vessel = String(ship ? SHIP_ASSET_TYPES.indexOf(ship) : snapshot.agents.indexOf(agent) % 12);
    const kind = world?.getAgentKind(agent.id);
    if (kind) { avatar.dataset.residentKind = kind; button.dataset.residentKind = kind; }
    else { delete avatar.dataset.residentKind; delete button.dataset.residentKind; }
    button.querySelector('.resident-name')!.textContent = agent.name;
    const home = ship ? world?.getAgentHome(agent.id) : undefined;
    button.querySelector('.resident-role')!.textContent = ship ? `${SHIP_NAMES[ship]}${home ? ` · ${home}` : ''}` : agent.role || 'Agent';
    button.classList.toggle('selected', agent.id === snapshot.selectedAgentID);
    button.style.setProperty('--status', STATUS_META[agent.status].color);
    button.dataset.status = agent.status;
    button.setAttribute('aria-pressed', String(agent.id === snapshot.selectedAgentID));
    button.setAttribute('aria-label', `${agent.name}${ship ? ` aboard ${SHIP_NAMES[ship]}` : ''}${home ? `, home island ${home}` : ''}, ${agent.role || 'Agent'}, ${STATUS_META[agent.status].label}${agent.detail ? `. ${agent.detail}` : ''}`);
    button.title = `${agent.role || 'Agent'} · ${STATUS_META[agent.status].label}${agent.detail ? ` · ${agent.detail}` : ''}`;
    if (list.children[index] !== card.element) list.insertBefore(card.element, list.children[index] || null);
  });
  if (!filtered.length && snapshot.agents.length) { const empty = document.createElement('p'); empty.className = 'search-empty'; empty.textContent = `No ${ocean ? 'captains' : 'residents'} match your search.`; list.append(empty); }
  el('empty-state').hidden = snapshot.agents.length > 0;
  renderActivity();
  publishResidentPlacements();
}

function renderNavigation(): void {
  document.body.dataset.navigation = navigationMode;
  el('mode-orbit').setAttribute('aria-pressed', String(navigationMode === 'orbit'));
  el('mode-pan').setAttribute('aria-pressed', String(navigationMode === 'pan'));
  el('drag-hint').textContent = navigationMode === 'pan' ? 'Drag to move map' : 'Drag to rotate';
  el('world').setAttribute('aria-label', `3D ${ocean ? 'Local Line ocean world. Each agent has their own ship' : 'outpost overview'}. Click ${ocean ? 'a ship' : 'an agent'} to interact.${ocean && snapshot.islandQuartersEnabled !== false ? ' Click Elbaf, Marineford, Water 7, Wano or Drum Island to visit Captain’s Quarters. Island visits are also available in Settings.' : ''} Drag to ${navigationMode === 'pan' ? 'move the map' : 'rotate the view'}, and scroll to zoom. Use arrow keys or W A S D to move the map. Use the Residents tab to select agents with the keyboard.`);
}

function setNavigationMode(mode: 'orbit' | 'pan'): void {
  navigationMode = mode;
  world?.setNavigationMode(mode);
  renderNavigation();
  announce(mode === 'pan' ? 'Move map mode. Drag to move across the map. Arrow keys or W A S D also move the map.' : 'Rotate mode. Drag to rotate the view. Arrow keys or W A S D move the map.');
}


function renderSailingArea(): void {
  el('sailing-area-control').hidden = !ocean;
  el<HTMLSelectElement>('sailing-area').value = sailingArea;
  const overview = sailingArea === 'whole' ? 'whole map' : SAILING_AREA_NAMES[sailingArea].toLowerCase();
  el('view-reset').setAttribute('aria-label', `Reset camera to the ${overview}`);
  el('view-reset').title = `Return to the ${overview}`;
}

function setSailingArea(area: SailingArea): void {
  if (sailingArea === area) return;
  sailingArea = area;
  snapshot = { ...snapshot, sailingArea: area };
  knownPlacements.clear(); lastPlacements = '';
  sector = snapshot.selectedAgentID ? agentSector(snapshot.agents, snapshot.selectedAgentID, fleetSize()) : 0;
  pendingFocusAgentID = undefined;
  updateWorldAgents(); applyActivity(); renderSailingArea(); renderRoster();
  world?.resetView();
  send({ version: 1, type: 'preferences', preferences: { sailingArea: area } });
  if (demo) {
    try { localStorage.setItem('locus.agentWorld.sailingArea.v1', area); } catch { /* The selection works without storage. */ }
    updatePreviewURL();
  }
  announce(`Ships now stay in the ${SAILING_AREA_NAMES[area].toLowerCase()}. Camera adjusted to match.`);
}

function renderResidentStyle(): void {
  document.body.dataset.residentStyle = residentStyle;
  el('resident-appearance').hidden = ocean;
  el('appearance-mixed').setAttribute('aria-pressed', String(residentStyle === 'mixed'));
  el('appearance-pandas').setAttribute('aria-pressed', String(residentStyle === 'pandas'));
  el('appearance-explorers').setAttribute('aria-pressed', String(residentStyle === 'explorers'));
}

function setResidentStyle(style: ResidentStyle): void {
  residentStyle = style;
  snapshot = { ...snapshot, residentStyle: style };
  world?.setResidentStyle(style);
  renderResidentStyle();
  renderRoster();
  send({ version: 1, type: 'preferences', preferences: { residentStyle: style } });
  if (demo) {
    try { localStorage.setItem('locus.agentWorld.residentStyle.v1', style); } catch { /* The switch still works when storage is unavailable. */ }
    updatePreviewURL();
  }
  announce(style === 'mixed' ? 'Your crew now includes pandas, people, and robots.' : style === 'pandas' ? 'Your agents now appear as pandas.' : 'Your agents now appear as explorers.');
}

function applyThemePresentation(isOcean: boolean): void {
  ocean = isOcean;
  snailAlert.setTheme(isOcean);
  document.body.dataset.environment = isOcean ? 'ocean' : 'campus';
  renderSailingArea();
  renderResidentStyle();
  el('world-subtitle').hidden = !isOcean;
  el('voyage-chart').hidden = !isOcean;
  document.querySelector<HTMLElement>('.roster-panel')!.hidden = isOcean && !standaloneResidentsOpen;
  el('residents-button').hidden = !demo || !isOcean;
  el('theme-button').hidden = !demo;
  if (!demo) { el('theme-popover').hidden = true; el('theme-button').setAttribute('aria-expanded', 'false'); }
  el('roster-title').textContent = 'Residents';
  document.querySelector('.roster-panel')!.setAttribute('aria-label', isOcean ? 'Fleet manifest' : 'Residents');
  const rosterHidden = el('roster-body').hidden;
  el('roster-toggle').setAttribute('aria-label', `${rosterHidden ? 'Expand' : 'Collapse'} ${isOcean ? 'fleet' : 'residents'}`);
  el('resident-search').setAttribute('aria-label', isOcean ? 'Search fleet' : 'Search residents');
  el<HTMLInputElement>('resident-search').placeholder = isOcean ? 'Find your captain' : 'Find an agent';
  el('empty-title').textContent = isOcean ? 'Your adventure begins here' : 'No residents yet';
  el('empty-description').textContent = isOcean ? 'Open Residents to welcome a captain and launch their ship.' : 'Choose New Agent to give your first agent a home here.';
  el('coordinate-region').textContent = isOcean ? 'THE AGE OF LOCAL MINDS' : 'LYRA SYSTEM';
  el('coordinate-unit').textContent = isOcean ? 'FLEET' : 'SECTOR';
  el('coordinate-detail').textContent = isOcean ? ' · LOCAL LINE' : ' · 04.28 N / 78.16 E';
  el('select-hint').textContent = isOcean ? 'Choose a ship to open its agent' : 'Click an agent to interact';
  el('world-version').textContent = isOcean ? 'SET SAIL' : 'OUTPOST 01';
  el('loading-label').textContent = isOcean ? 'Setting sail for the Local Line' : 'Arriving at your outpost';
  el('asset-notice').textContent = isOcean ? 'Some artwork is unavailable. Your fleet is using built-in ships.' : 'Some artwork is unavailable. The outpost is using built-in models.';
  el('fallback-reason').textContent = `3D graphics are unavailable on this device. Select ${isOcean ? 'a captain in the Residents tab' : 'a resident'} to open their conversation.`;
  renderNavigation();
  renderRoster();
  renderThemes();
}

function renderVoyageChart(): void {
  const chart = document.querySelector<SVGSVGElement>('#voyage-chart svg');
  if (!chart) return;
  const ns = 'http://www.w3.org/2000/svg';
  chart.setAttribute('aria-label', 'Island positions and relative sizes across the Local Line archipelago.');
  chart.replaceChildren();
  const span = GRAND_LINE_MAP_RADIUS * 2;
  const chartX = (x: number) => (GRAND_LINE_MAP_RADIUS - x) / span * 192;
  const chartZ = (z: number) => (z + GRAND_LINE_MAP_RADIUS) / span * 94;
  for (const sign of [-1, 1]) {
    const belt = document.createElementNS(ns, 'rect'); belt.setAttribute('class', 'chart-belt');
    belt.setAttribute('x', '0'); belt.setAttribute('width', '192');
    belt.setAttribute('y', String(chartZ(sign < 0 ? -GRAND_LINE_CALM_BELT.outer : GRAND_LINE_CALM_BELT.inner)));
    belt.setAttribute('height', String((GRAND_LINE_CALM_BELT.outer - GRAND_LINE_CALM_BELT.inner) / span * 94));
    chart.append(belt);
  }
  const cliffs = document.createElementNS(ns, 'path');
  cliffs.setAttribute('class', 'chart-land'); cliffs.setAttribute('d', `M${chartX(-27)} 0h${4 / span * 192}v${chartZ(-4)}h${-4 / span * 192}zM${chartX(-27)} ${chartZ(4)}h${4 / span * 192}V94h${-4 / span * 192}z`); chart.append(cliffs);
  for (const island of [...GRAND_LINE_LANDMARKS, MARY_GEOISE]) {
    const port = document.createElementNS(ns, 'ellipse'); port.setAttribute('class', 'chart-port');
    port.setAttribute('cx', String(chartX(island.x))); port.setAttribute('cy', String(chartZ(island.z)));
    port.setAttribute('rx', String(island.radius / span * 192)); port.setAttribute('ry', String(island.radius / span * 94));
    const title = document.createElementNS(ns, 'title'); title.textContent = island.name; port.append(title); chart.append(port);
  }
}
renderVoyageChart();

function assetProgress(completed: number, total: number): void {
  el('asset-loading').hidden = completed >= total;
  el('asset-loading').textContent = `Preparing ${ocean ? 'the fleet' : 'world artwork'} · ${completed} / ${total}`;
}

function fallback(reason?: string): void {
  el('loading-indicator').hidden = true;
  el('asset-loading').hidden = true;
  el('graphics-fallback').hidden = false;
  if (reason) el('fallback-reason').textContent = reason;
  document.querySelector('.controls')?.setAttribute('hidden', '');
  document.querySelector('.coordinate-label')?.setAttribute('hidden', '');
  el('agent-labels').hidden = true;
}

async function loadTheme(id: string): Promise<void> {
  const allowed = themeChoices.find(choice => choice.id === id);
  if (!allowed || loadingTheme === id || disposed) return;
  if (loadedTheme === id && world) {
    // Choosing the current world cancels another manifest still in flight.
    themeGeneration += 1;
    loadingTheme = undefined;
    return;
  }
  loadingTheme = id;
  const generation = ++themeGeneration;
  try {
    const response = await fetch(new URL(`./themes/${id}/theme.json`, document.baseURI), { credentials: 'omit', cache: 'no-store' });
    if (!response.ok) throw new Error('Theme unavailable');
    const theme = parseTheme(await response.json());
    if (generation !== themeGeneration || disposed) return;
    if (theme.id !== id) throw new Error('Theme identity does not match its catalog entry');
    knownPlacements.clear(); lastPlacements = '';
    world?.dispose(); world = undefined;
    loadedTheme = id;
    applyThemePresentation(theme.environment === 'ocean');
    document.querySelector('.controls')?.removeAttribute('hidden');
    document.querySelector('.coordinate-label')?.removeAttribute('hidden');
    el('asset-notice').hidden = true;
    el('graphics-fallback').hidden = true;
    el('agent-labels').hidden = false;
    const heading = document.querySelector('.brand h1')!;
    heading.firstChild!.textContent = theme.name;
    document.title = `${theme.name} · Agent World · Locus`;
    el('theme-button').children[1].textContent = allowed.name.replace(/^Orbital /, '');
    world = new OutpostWorld(el<HTMLCanvasElement>('world'), theme, { onIsland: openIslandQuarters, onSelect: selectAgent, onClearSelection: clearAgentSelection, onAttention: openAttention, onTransfer: openTransfer, onAssetFailure: () => { el('asset-notice').hidden = false; }, onAssetProgress: assetProgress, onGraphicsFailure: () => fallback('The graphics connection was interrupted. Reopen this window to restore the world, or select an agent to keep talking.') }, residentStyle);
    world.setNavigationMode(navigationMode);
    updateWorldAgents();
    applyActivity();
    renderRoster();
    renderThemes();
    world.setVisible(nativeVisible && !document.hidden);
    updatePreviewURL();
    el('loading-indicator').hidden = true;
  } catch (error) {
    if (generation !== themeGeneration || disposed) return;
    console.warn('Agent World could not load the selected world.', error instanceof Error ? error.message : 'Unknown error');
    // Missing manifest can still show a functional built-in outpost without network access.
    if (!world && id === 'outpost') {
      try {
        world = new OutpostWorld(el<HTMLCanvasElement>('world'), DEFAULT_THEME, { onIsland: openIslandQuarters, onSelect: selectAgent, onClearSelection: clearAgentSelection, onAttention: openAttention, onTransfer: openTransfer, onAssetFailure: () => { el('asset-notice').hidden = false; }, onAssetProgress: assetProgress, onGraphicsFailure: () => fallback() }, residentStyle);
        world.setNavigationMode(navigationMode);
        updateWorldAgents();
        applyActivity();
        world.setVisible(nativeVisible && !document.hidden);
        loadedTheme = id;
        applyThemePresentation(false);
        el('asset-notice').hidden = false;
        el('loading-indicator').hidden = true;
      } catch { fallback(); }
    } else if (!world) fallback();
    else showNote('That theme could not be loaded. Your current world is still open.');
  } finally {
    if (generation === themeGeneration) { loadingTheme = undefined; applyPendingFocus(); }
  }
}

function applyPendingFocus(): void {
  if (pendingFocusAgentID && world && !loadingTheme && loadedTheme === snapshot.theme) {
    if (snapshot.selectedAgentID === pendingFocusAgentID) world.focusResident(pendingFocusAgentID);
    pendingFocusAgentID = undefined;
  }
}

function receive(message: unknown): void {
  const parsed = parseHostMessage(message);
  if (!parsed || disposed) return;
  if (parsed.type === 'visibility') { nativeVisible = parsed.visible; world?.setVisible(nativeVisible && !document.hidden); snailAlert.setVisible(nativeVisible && !document.hidden); return; }
  const projectChanged = parsed.projectName !== snapshot.projectName;
  const selectionChanged = parsed.selectedAgentID !== snapshot.selectedAgentID;
  const focusRequested = selectionChanged || parsed.focusRequest !== snapshot.focusRequest;
  const activityRequested = (parsed.activityCenterRequest ?? 0) > 0 && parsed.activityCenterRequest !== snapshot.activityCenterRequest;
  const areaChanged = sailingArea !== (parsed.sailingArea ?? 'whole');
  snapshot = parsed;
  if (areaChanged) {
    sailingArea = parsed.sailingArea ?? 'whole';
    knownPlacements.clear(); lastPlacements = '';
    renderSailingArea();
  }
  if (projectChanged) { setActivityCenterOpen(false, false); knownPlacements.clear(); lastPlacements = ''; }
  if (activityRequested && !parsed.nativeChrome) toggleActivityCenter();
  if (parsed.residentStyle && residentStyle !== parsed.residentStyle) {
    residentStyle = parsed.residentStyle;
    world?.setResidentStyle(residentStyle);
    renderResidentStyle();
  }
  sector = (focusRequested || areaChanged) && parsed.selectedAgentID ? agentSector(parsed.agents, parsed.selectedAgentID, fleetSize()) : clampSector(projectChanged ? 0 : sector, parsed.agents.length, fleetSize());
  updateWorldAgents();
  applyActivity();
  renderRoster();
  if (focusRequested) pendingFocusAgentID = parsed.selectedAgentID;
  void loadTheme(snapshot.theme).then(applyPendingFocus);
}
window.locusAgentWorld = { receive, toggleActivityCenter };

el('sailing-area').addEventListener('change', () => {
  const value = el<HTMLSelectElement>('sailing-area').value;
  if (isSailingArea(value)) setSailingArea(value);
});
el('new-agent').addEventListener('click', () => {
  if (demo) showNote('Open Agent World in Locus to create an agent. This preview does not save agent profiles.');
  else if (snapshot.canCreateAgent) send({ version: 1, type: 'createAgent' });
});
el('shared-chat').addEventListener('click', () => {
  if (demo) showNote('Crew Chat connects your agents in Locus. This preview does not open a real chat or send messages.');
  else send({ version: 1, type: 'openSharedChat' });
});
el('island-quarters-enabled').addEventListener('change', event => {
  const enabled = (event.target as HTMLInputElement).checked;
  if (!demo) { send({ version: 1, type: 'preferences', preferences: { islandQuartersEnabled: enabled } }); return; }
  snapshot = { ...snapshot, islandQuartersEnabled: enabled };
  try { localStorage.setItem(ISLAND_QUARTERS_PREFERENCE, String(enabled)); } catch { /* Storage is optional in previews. */ }
  renderIslandSettings();
});
for (const id of Object.keys(ISLAND_QUARTERS) as QuartersIslandID[]) {
  const button = document.createElement('button'); button.type = 'button';
  button.textContent = ISLAND_QUARTERS[id].name; button.dataset.islandId = id;
  button.addEventListener('click', () => openIslandQuarters(id));
  el('island-destinations').append(button);
}
el('quarters-settings').addEventListener('click', () => {
  el<HTMLDialogElement>('captains-quarters').close();
  el<HTMLDetailsElement>('world-settings').open = true;
  el('island-quarters-enabled').focus();
});
el('quarters-open').addEventListener('click', () => quarters.open());
el('agent-controls').addEventListener('click', () => {
  if (demo && ocean) quarters.open();
  else if (demo) showNote(`In Locus, the agent workspace contains the selected agent’s conversation, tools and controls.`);
  else send({ version: 1, type: 'openAgentControls', ...(snapshot.selectedAgentID ? { agentID: snapshot.selectedAgentID } : {}) });
});
el('activity-close').addEventListener('click', () => setActivityCenterOpen(false));
el('attention-tab').addEventListener('click', () => selectActivityTab('attention'));
el('activity-tab').addEventListener('click', () => selectActivityTab('activity'));
for (const tab of ['attention-tab', 'activity-tab']) el(tab).addEventListener('keydown', event => {
  if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
  event.preventDefault();
  selectActivityTab(event.key === 'Home' ? 'attention' : event.key === 'End' ? 'activity' : activityTab === 'attention' ? 'activity' : 'attention', true);
});

el<HTMLInputElement>('resident-search').addEventListener('input', renderRoster);
el('residents-button').addEventListener('click', () => {
  standaloneResidentsOpen = !standaloneResidentsOpen;
  if (standaloneResidentsOpen) setActivityCenterOpen(false, false);
  el('resident-preview-panel').hidden = !standaloneResidentsOpen;
  el('residents-button').setAttribute('aria-expanded', String(standaloneResidentsOpen));
  if (standaloneResidentsOpen) el('resident-search').focus();
});
el('appearance-mixed').addEventListener('click', () => setResidentStyle('mixed'));
el('appearance-pandas').addEventListener('click', () => setResidentStyle('pandas'));
el('appearance-explorers').addEventListener('click', () => setResidentStyle('explorers'));
el('mode-orbit').addEventListener('click', () => setNavigationMode('orbit'));
el('mode-pan').addEventListener('click', () => setNavigationMode('pan'));
el('previous-agent').addEventListener('click', () => selectAdjacentAgent(-1));
el('next-agent').addEventListener('click', () => selectAdjacentAgent(1));
el('clear-agent').addEventListener('click', clearAgentSelection);
el('view-reset').addEventListener('click', () => { world?.resetView(); announce(`Camera returned to the ${SAILING_AREA_NAMES[sailingArea].toLowerCase()}.`); });
el('roster-toggle').addEventListener('click', () => {
  const body = el('roster-body'), button = el('roster-toggle'); body.hidden = !body.hidden;
  button.textContent = body.hidden ? '+' : '−';
  button.setAttribute('aria-expanded', String(!body.hidden));
  button.setAttribute('aria-label', `${body.hidden ? 'Expand' : 'Collapse'} ${ocean ? 'fleet' : 'residents'}`);
  document.querySelector('.roster-panel')!.classList.toggle('collapsed', body.hidden);
});
const themePopover = el('theme-popover');
el('theme-button').addEventListener('click', () => { themePopover.hidden = !themePopover.hidden; el('theme-button').setAttribute('aria-expanded', String(!themePopover.hidden)); });
document.addEventListener('pointerdown', event => {
  if (event.target instanceof Element && !event.target.closest('#world-settings')) el<HTMLDetailsElement>('world-settings').open = false;
  if (!(event.target instanceof Element) || event.target.closest('#theme-button, #theme-popover')) return; themePopover.hidden = true; el('theme-button').setAttribute('aria-expanded', 'false'); });
document.addEventListener('keydown', event => {
  if (event.key !== 'Escape' || event.defaultPrevented || event.target instanceof HTMLSelectElement) return;
  if (el<HTMLDetailsElement>('world-settings').open) { el<HTMLDetailsElement>('world-settings').open = false; el('world-settings').querySelector('summary')!.focus(); return; }
  if (world?.handleCreatureKey(event.key, event.repeat)) { event.preventDefault(); return; }
  if (!themePopover.hidden) { themePopover.hidden = true; el('theme-button').setAttribute('aria-expanded', 'false'); el('theme-button').focus(); }
  else if (!el('fleet-activity').hidden) setActivityCenterOpen(false);
  else if (ocean && standaloneResidentsOpen) { standaloneResidentsOpen = false; el('resident-preview-panel').hidden = true; el('residents-button').setAttribute('aria-expanded', 'false'); el('residents-button').focus(); }
});
document.addEventListener('keydown', event => {
  if (event.defaultPrevented || event.altKey || event.ctrlKey || event.metaKey || !world || disposed || document.hidden || !themePopover.hidden) return;
  const target = event.target;
  if (target instanceof Element && target.closest('button, a[href], input, textarea, select, [contenteditable], [role="button"], [role="textbox"], #resident-list, #theme-popover, #fleet-activity, #snail-alert, .world-actions')) return;
  if (world.handleCreatureKey(event.key, event.repeat)) { event.preventDefault(); return; }
  const directions: Record<string, 'left' | 'right' | 'up' | 'down'> = { arrowleft: 'left', a: 'left', arrowright: 'right', d: 'right', arrowup: 'up', w: 'up', arrowdown: 'down', s: 'down' };
  const direction = directions[event.key.toLowerCase()];
  if (!direction) return;
  event.preventDefault();
  world.panMap(direction);
});
document.addEventListener('visibilitychange', () => { world?.setVisible(nativeVisible && !document.hidden); snailAlert.setVisible(nativeVisible && !document.hidden); });
window.addEventListener('pagehide', () => { disposed = true; world?.dispose(); snailAlert.dispose(); if (noteTimer) clearTimeout(noteTimer); });

function renderThemes(): void {
  themePopover.querySelectorAll('.theme-choice').forEach(item => item.remove());
  for (const choice of themeChoices) {
    const button = document.createElement('button'); button.className = 'theme-choice'; button.type = 'button';
    const planet = document.createElement('span'); planet.className = 'planet-dot'; planet.dataset.world = choice.id; planet.setAttribute('aria-hidden', 'true');
    button.setAttribute('aria-pressed', String(choice.id === loadedTheme));
    const label = document.createElement('span'); label.textContent = choice.name;
    button.append(planet, label);
    button.addEventListener('click', () => {
      themePopover.hidden = true; el('theme-button').setAttribute('aria-expanded', 'false');
      el('theme-button').focus();
      send({ version: 1, type: 'preferences', preferences: { theme: choice.id } });
      if (demo) { snapshot = { ...snapshot, theme: choice.id }; void loadTheme(choice.id); }
    });
    themePopover.insertBefore(button, themePopover.querySelector('p'));
  }
}

async function start(): Promise<void> {
  try {
    const response = await fetch(new URL('./themes/catalog.json', document.baseURI), { credentials: 'omit', cache: 'no-store' });
    if (response.ok) { const catalog = parseCatalog(await response.json()); if (catalog.length) themeChoices = catalog; }
  } catch { /* The shipped outpost remains accessible if its catalog is missing. */ }
  if (demo) {
    const requestedTheme = new URLSearchParams(window.location.search).get('theme');
    if (requestedTheme && themeChoices.some(choice => choice.id === requestedTheme)) snapshot.theme = requestedTheme;
    let savedStyle: unknown;
    try { savedStyle = localStorage.getItem('locus.agentWorld.residentStyle.v1'); } catch { /* Private browser storage is optional. */ }
    const requestedStyle = new URLSearchParams(window.location.search).get('residentStyle');
    residentStyle = isResidentStyle(requestedStyle) ? requestedStyle : isResidentStyle(savedStyle) ? savedStyle : 'mixed';
    snapshot.residentStyle = residentStyle;
    let savedArea: unknown;
    try { savedArea = localStorage.getItem('locus.agentWorld.sailingArea.v1'); } catch { /* Storage is optional. */ }
    const requestedArea = new URLSearchParams(window.location.search).get('sailingArea');
    sailingArea = isSailingArea(requestedArea) ? requestedArea : isSailingArea(savedArea) ? savedArea : 'whole';
    snapshot.sailingArea = sailingArea;
    try {
      const savedStyles = localStorage.getItem(SHIP_STYLE_PREFERENCE);
      if (savedStyles) snapshot.shipStyles = parseShipStyles(JSON.parse(savedStyles), snapshot.agents.map(agent => agent.id)) ?? {};
    } catch { /* Ignore invalid or unavailable preview preferences. */ }
  }
  renderThemes();
  renderRoster();
  await loadTheme(themeChoices.some(theme => theme.id === snapshot.theme) ? snapshot.theme : themeChoices[0].id);
}

if (demo) {
  el('demo-badge').hidden = false;
  const demoAgents: Agent[] = [
    { id: '10000000-0000-4000-8000-000000000001', name: 'Atlas', role: 'Research & discovery', status: 'working', detail: 'Example status · no task is running' },
    { id: '10000000-0000-4000-8000-000000000002', name: 'Nova', role: 'Design & experience', status: 'idle' },
    { id: '10000000-0000-4000-8000-000000000003', name: 'Orion', role: 'Engineering', status: 'idle' },
    { id: '10000000-0000-4000-8000-000000000004', name: 'Echo', role: 'Writing & storytelling', status: 'needs_attention', detail: 'Example attention state' },
    { id: '10000000-0000-4000-8000-000000000005', name: 'Sage', role: 'Planning & strategy', status: 'completed' },
    { id: '10000000-0000-4000-8000-000000000006', name: 'Pip', role: 'Quality & testing', status: 'idle' },
    { id: '10000000-0000-4000-8000-000000000007', name: 'Lyra', role: 'Ideas & exploration', status: 'idle' },
    { id: '10000000-0000-4000-8000-000000000008', name: 'Finn', role: 'Data & insights', status: 'idle' },
    { id: '10000000-0000-4000-8000-000000000009', name: 'Cleo', role: 'Product & direction', status: 'queued', detail: 'Example queued state' },
    { id: '10000000-0000-4000-8000-000000000010', name: 'Sol', role: 'Code & craft', status: 'idle' },
    { id: '10000000-0000-4000-8000-000000000011', name: 'Mika', role: 'Words & stories', status: 'completed' },
    { id: '10000000-0000-4000-8000-000000000012', name: 'Rune', role: 'Systems & operations', status: 'idle' },
  ];
  snapshot = { version: 1, type: 'snapshot', agents: demoAgents, projectName: 'Demo workspace', theme: 'grand-line',
    attentionRequests: [{ id: '20000000-0000-4000-8000-000000000001', agentID: demoAgents[3].id, kind: 'approval', title: 'Sample approval · no real request is pending' }],
    transfers: [
      { id: '30000000-0000-4000-8000-000000000001', fromAgentID: demoAgents[0].id, toAgentID: demoAgents[1].id, kind: 'handoff', title: 'Sample research handoff', occurredAt: Date.now() / 1000 },
      { id: '30000000-0000-4000-8000-000000000002', fromAgentID: demoAgents[2].id, toAgentID: demoAgents[5].id, kind: 'artifact', title: 'Sample build artifact', occurredAt: Date.now() / 1000 },
    ],
  };
  try { snapshot.islandQuartersEnabled = localStorage.getItem(ISLAND_QUARTERS_PREFERENCE) !== 'false'; } catch { /* Keep the enabled default. */ }
} else {
  el('empty-state').hidden = true;
  send({ version: 1, type: 'ready' });
}
void start();
