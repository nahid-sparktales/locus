import { OutpostWorld } from './world';
import { DEFAULT_THEME, parseTheme, parseCatalog } from './theme';
import type { ThemeChoice } from './theme';
import { STATUS_META, SECTOR_SIZE, agentSector, clampSector, parseHostMessage, searchAgents, sectorAgents } from './state';
import type { Agent, Snapshot, WorldMessage } from './state';

declare global {
  interface Window {
    webkit?: { messageHandlers?: { locusScreen?: { postMessage: (message: WorldMessage) => void } } };
    locusAgentWorld: { receive: (message: unknown) => void };
  }
}

const el = <T extends HTMLElement = HTMLElement>(id: string): T => document.getElementById(id) as T;
const bridge = window.webkit?.messageHandlers?.locusScreen;
const demo = !bridge;
const rosterButtons = new Map<string, HTMLButtonElement>();
let snapshot: Snapshot = { version: 1, type: 'snapshot', agents: [], theme: 'outpost', projectName: '' };
let world: OutpostWorld | undefined;
let sector = 0;
let nativeVisible = true;
let themeChoices: ThemeChoice[] = [{ id: 'outpost', name: 'Orbital Outpost' }];
let loadedTheme: string | undefined;
let loadingTheme: string | undefined;
let themeGeneration = 0;
let noteTimer: ReturnType<typeof setTimeout> | undefined;
let disposed = false;

const send = (message: WorldMessage): void => { try { bridge?.postMessage(message); } catch { el('live-label').textContent = 'Connection unavailable'; } };
const announce = (message: string): void => { el('screen-reader-status').textContent = message; };
function showNote(message: string): void {
  const note = el('selection-note'); note.textContent = message; note.hidden = false;
  if (noteTimer) clearTimeout(noteTimer);
  noteTimer = setTimeout(() => { note.hidden = true; }, 5000);
}

function selectAgent(id: string): void {
  const agent = snapshot.agents.find(item => item.id === id);
  if (!agent) return;
  const nextSector = agentSector(snapshot.agents, id);
  sector = nextSector;
  snapshot = { ...snapshot, selectedAgentID: id };
  world?.setAgents(sectorAgents(snapshot.agents, sector), id);
  world?.focusResident(id);
  renderRoster();
  send({ version: 1, type: 'selectAgent', agentID: id });
  announce(`${agent.name} selected. ${STATUS_META[agent.status].label}.`);
  if (demo) showNote(`${agent.name} is a demo resident. In Locus, this opens their real conversation beside the world.`);
}

function renderRoster(): void {
  el('resident-count').textContent = String(snapshot.agents.length);
  el('project-name').textContent = snapshot.projectName || (demo ? 'A preview of your next workspace' : 'Select a project in Locus');
  el('project-name').title = snapshot.projectName;
  el('live-label').textContent = demo ? 'Demo residents · no model calls' : 'Connected to Locus';
  const totalSectors = Math.max(1, Math.ceil(snapshot.agents.length / SECTOR_SIZE));
  el('sector-label').textContent = `${String(sector + 1).padStart(2, '0')} / ${String(totalSectors).padStart(2, '0')}`;
  el('coordinate-sector').textContent = String(sector + 1).padStart(2, '0');
  const working = snapshot.agents.filter(agent => agent.status === 'working').length;
  const attention = snapshot.agents.filter(agent => agent.status === 'needs_attention' || agent.status === 'failed').length;
  el('working-count').textContent = working ? `${working} agent${working === 1 ? '' : 's'} at work` : attention ? `${attention} need${attention === 1 ? 's' : ''} your attention` : 'All systems calm';
  const list = el('resident-list');
  const filtered = searchAgents(snapshot.agents, el<HTMLInputElement>('resident-search').value);
  const displayed = new Set(filtered.map(agent => agent.id));
  for (const [id, button] of rosterButtons) if (!displayed.has(id)) { button.remove(); rosterButtons.delete(id); }
  const oldEmpty = list.querySelector('.search-empty'); oldEmpty?.remove();
  filtered.forEach((agent, index) => {
    let button = rosterButtons.get(agent.id);
    if (!button) {
      button = document.createElement('button'); button.className = 'resident-row'; button.type = 'button'; button.dataset.agentId = agent.id;
      const avatar = document.createElement('span'); avatar.className = `resident-avatar variant-${snapshot.agents.indexOf(agent) % 4}`; avatar.setAttribute('aria-hidden', 'true');
      const text = document.createElement('span'); text.className = 'resident-text';
      const name = document.createElement('span'); name.className = 'resident-name';
      const role = document.createElement('span'); role.className = 'resident-role';
      const state = document.createElement('span'); state.className = 'resident-state'; state.setAttribute('aria-hidden', 'true');
      text.append(name, role); button.append(avatar, text, state);
      button.addEventListener('click', () => selectAgent(agent.id));
      rosterButtons.set(agent.id, button);
    }
    button.querySelector('.resident-name')!.textContent = agent.name;
    button.querySelector('.resident-role')!.textContent = agent.role || 'Agent';
    button.classList.toggle('selected', agent.id === snapshot.selectedAgentID);
    button.style.setProperty('--status', STATUS_META[agent.status].color);
    button.dataset.status = agent.status;
    button.setAttribute('aria-pressed', String(agent.id === snapshot.selectedAgentID));
    button.setAttribute('aria-label', `${agent.name}, ${agent.role || 'Agent'}, ${STATUS_META[agent.status].label}${agent.detail ? `. ${agent.detail}` : ''}`);
    button.title = `${STATUS_META[agent.status].label}${agent.detail ? ` · ${agent.detail}` : ''}`;
    if (list.children[index] !== button) list.insertBefore(button, list.children[index] || null);
  });
  if (!filtered.length && snapshot.agents.length) { const empty = document.createElement('p'); empty.className = 'search-empty'; empty.textContent = 'No residents match your search.'; list.append(empty); }
  el('empty-state').hidden = snapshot.agents.length > 0;
}

function assetProgress(completed: number, total: number): void {
  el('asset-loading').hidden = completed >= total;
  el('asset-loading').textContent = `Preparing world artwork · ${completed} / ${total}`;
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
  if (!allowed || loadedTheme === id || loadingTheme === id || disposed) return;
  loadingTheme = id;
  const generation = ++themeGeneration;
  try {
    const response = await fetch(new URL(`./themes/${id}/theme.json`, document.baseURI), { credentials: 'omit' });
    if (!response.ok) throw new Error('Theme unavailable');
    const theme = parseTheme(await response.json());
    if (generation !== themeGeneration || disposed) return;
    if (theme.id !== id) throw new Error('Theme identity does not match its catalog entry');
    world?.dispose(); world = undefined;
    loadedTheme = id;
    el('asset-notice').hidden = true;
    el('graphics-fallback').hidden = true;
    el('agent-labels').hidden = false;
    const heading = document.querySelector('.brand h1')!;
    heading.firstChild!.textContent = theme.name;
    el('theme-button').children[1].textContent = allowed.name.replace(/^Orbital /, '');
    world = new OutpostWorld(el<HTMLCanvasElement>('world'), theme, { onSelect: selectAgent, onAssetFailure: () => { el('asset-notice').hidden = false; }, onAssetProgress: assetProgress, onGraphicsFailure: () => fallback('The graphics connection was interrupted. Reopen this window to restore the world, or select a resident to keep talking.') });
    world.setAgents(sectorAgents(snapshot.agents, sector), snapshot.selectedAgentID);
    world.setVisible(nativeVisible && !document.hidden);
    el('loading-indicator').hidden = true;
  } catch (error) {
    if (generation !== themeGeneration || disposed) return;
    console.warn('Agent World could not load the selected world.', error instanceof Error ? error.message : 'Unknown error');
    // Missing manifest can still show a functional built-in outpost without network access.
    if (!world && id === 'outpost') {
      try {
        world = new OutpostWorld(el<HTMLCanvasElement>('world'), DEFAULT_THEME, { onSelect: selectAgent, onAssetFailure: () => { el('asset-notice').hidden = false; }, onAssetProgress: assetProgress, onGraphicsFailure: () => fallback() });
        world.setAgents(sectorAgents(snapshot.agents, sector), snapshot.selectedAgentID);
        world.setVisible(nativeVisible && !document.hidden);
        loadedTheme = id;
        el('asset-notice').hidden = false;
        el('loading-indicator').hidden = true;
      } catch { fallback(); }
    } else if (!world) fallback();
    else showNote('That theme could not be loaded. Your current world is still open.');
  } finally {
    if (generation === themeGeneration) loadingTheme = undefined;
  }
}

function receive(message: unknown): void {
  const parsed = parseHostMessage(message);
  if (!parsed || disposed) return;
  if (parsed.type === 'visibility') { nativeVisible = parsed.visible; world?.setVisible(nativeVisible && !document.hidden); return; }
  const projectChanged = parsed.projectName !== snapshot.projectName;
  const selectionChanged = parsed.selectedAgentID !== snapshot.selectedAgentID;
  snapshot = parsed;
  sector = selectionChanged && parsed.selectedAgentID ? agentSector(parsed.agents, parsed.selectedAgentID) : clampSector(projectChanged ? 0 : sector, parsed.agents.length);
  renderRoster();
  world?.setAgents(sectorAgents(snapshot.agents, sector), snapshot.selectedAgentID);
  void loadTheme(snapshot.theme);
}
window.locusAgentWorld = { receive };

el<HTMLInputElement>('resident-search').addEventListener('input', renderRoster);
el('roster-toggle').addEventListener('click', () => {
  const body = el('roster-body'), button = el('roster-toggle'); body.hidden = !body.hidden;
  button.textContent = body.hidden ? '+' : '−';
  button.setAttribute('aria-expanded', String(!body.hidden));
  button.setAttribute('aria-label', body.hidden ? 'Expand residents' : 'Collapse residents');
  document.querySelector('.roster-panel')!.classList.toggle('collapsed', body.hidden);
});
const themePopover = el('theme-popover');
el('theme-button').addEventListener('click', () => { themePopover.hidden = !themePopover.hidden; el('theme-button').setAttribute('aria-expanded', String(!themePopover.hidden)); });
document.addEventListener('pointerdown', event => { if (!(event.target instanceof Element) || event.target.closest('#theme-button, #theme-popover')) return; themePopover.hidden = true; el('theme-button').setAttribute('aria-expanded', 'false'); });
document.addEventListener('keydown', event => { if (event.key === 'Escape') { themePopover.hidden = true; el('theme-button').setAttribute('aria-expanded', 'false'); } });
document.addEventListener('visibilitychange', () => world?.setVisible(nativeVisible && !document.hidden));
window.addEventListener('pagehide', () => { disposed = true; world?.dispose(); if (noteTimer) clearTimeout(noteTimer); });

function renderThemes(): void {
  themePopover.querySelectorAll('.theme-choice').forEach(item => item.remove());
  for (const choice of themeChoices) {
    const button = document.createElement('button'); button.className = 'theme-choice'; button.type = 'button';
    const planet = document.createElement('span'); planet.className = 'planet-dot'; planet.setAttribute('aria-hidden', 'true');
    const label = document.createElement('span'); label.textContent = choice.name;
    button.append(planet, label);
    button.addEventListener('click', () => {
      themePopover.hidden = true; el('theme-button').setAttribute('aria-expanded', 'false');
      send({ version: 1, type: 'preferences', preferences: { theme: choice.id } });
      if (demo) { snapshot = { ...snapshot, theme: choice.id }; void loadTheme(choice.id); }
    });
    themePopover.insertBefore(button, themePopover.querySelector('p'));
  }
}

async function start(): Promise<void> {
  try {
    const response = await fetch(new URL('./themes/catalog.json', document.baseURI), { credentials: 'omit' });
    if (response.ok) { const catalog = parseCatalog(await response.json()); if (catalog.length) themeChoices = catalog; }
  } catch { /* The shipped outpost remains accessible if its catalog is missing. */ }
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
  ];
  snapshot = { version: 1, type: 'snapshot', agents: demoAgents, projectName: 'Mission control · Demo workspace', theme: 'outpost' };
} else {
  el('empty-state').hidden = true;
  send({ version: 1, type: 'ready' });
}
void start();
