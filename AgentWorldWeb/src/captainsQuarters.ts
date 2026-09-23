import { ISLAND_QUARTERS } from './islandQuarters';
import type { QuartersIslandID } from './islandQuarters';
import { STATUS_META } from './state';
import type { Agent } from './state';

/** Standalone deck preview. Live conversations remain in the native workspace. */
export function createCaptainsQuarters(crew: () => readonly Agent[], home: (id: string) => string | undefined, locate: (id: string) => void) {
  const dialog = document.getElementById('captains-quarters') as HTMLDialogElement;
  const list = document.getElementById('quarters-crew')!;
  const workspace = document.getElementById('quarters-workspace')!;
  const toggle = document.getElementById('quarters-toggle')!;
  const search = document.getElementById('quarters-search') as HTMLInputElement;
  const render = () => {
    list.replaceChildren();
    const members = crew().filter(agent => `${agent.name} ${agent.role}`.toLowerCase().includes(search.value.toLowerCase()));
    for (const agent of members) {
      const card = document.createElement('article'); card.className = 'quarters-card';
      const name = document.createElement('h3'); name.textContent = agent.name;
      const role = document.createElement('p'); role.textContent = agent.role;
      const status = document.createElement('span'); status.className = 'quarters-status'; status.textContent = STATUS_META[agent.status].label;
      const island = document.createElement('p'); island.textContent = home(agent.id) ?? 'At sea';
      const button = document.createElement('button'); button.type = 'button'; button.textContent = 'Find ship on map';
      button.setAttribute('aria-label', `Find ${agent.name} on map`);
      button.addEventListener('click', () => { dialog.close(); locate(agent.id); });
      card.append(name, role, status, island, button); list.append(card);
    }
    if (!members.length) { const empty = document.createElement('p'); empty.textContent = 'No captains match your search.'; list.append(empty); }
  };
  search.addEventListener('input', render);
  document.getElementById('quarters-close')!.addEventListener('click', () => dialog.close());
  toggle.addEventListener('click', () => {
    workspace.hidden = !workspace.hidden;
    toggle.textContent = workspace.hidden ? 'Show crew' : 'View deck';
    toggle.setAttribute('aria-expanded', String(!workspace.hidden));
  });
  // Keep map keyboard shortcuts from consuming Escape or arrow keys behind the modal.
  dialog.addEventListener('keydown', event => event.stopPropagation());
  return {
    open(islandID?: QuartersIslandID) {
      const theme = islandID ? ISLAND_QUARTERS[islandID] : undefined;
      dialog.dataset.island = islandID ?? '';
      for (const name of ['paper', 'panel', 'raised', 'line', 'ink', 'muted', 'accent'] as const) {
        if (theme) dialog.style.setProperty(`--quarters-${name}`, theme[name]);
        else dialog.style.removeProperty(`--quarters-${name}`);
      }
      if (theme) dialog.style.setProperty('--quarters-art', `url('${new URL(`static/quarters-${theme.artwork}.webp`, document.baseURI).href}')`);
      else dialog.style.removeProperty('--quarters-art');
      document.getElementById('quarters-location')!.textContent = theme ? `${theme.name.toUpperCase()} · ${theme.subtitle}` : 'THE LOCAL LINE · PREVIEW';
      search.value = ''; workspace.hidden = false; toggle.textContent = 'View deck'; toggle.setAttribute('aria-expanded', 'true');
      render(); if (!dialog.open) dialog.showModal();
    },
  };
}
