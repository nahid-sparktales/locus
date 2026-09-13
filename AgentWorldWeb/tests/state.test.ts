import test from 'node:test';
import assert from 'node:assert/strict';
import { parseHostMessage, parseShipStyles, agentSector, clampSector, sectorAgents, searchAgents, isClickGesture, labelIsUnobscured, STATUS_META } from '../src/state.ts';
import { safeAssetPath, parseTheme, parseCatalog, DEFAULT_THEME, SHIP_ASSET_TYPES } from '../src/theme.ts';

const agents = Array.from({ length: 27 }, (_, index) => ({ id: `00000000-0000-4000-8000-${String(index).padStart(12, '0')}`, name: `Agent ${index}`, role: index === 24 ? 'Design researcher' : 'Engineer', status: 'idle' as const }));
const snapshot = { version: 1, type: 'snapshot', agents, theme: 'outpost', projectName: 'Project' };
test('accepts a full native snapshot and visibility; rejects malformed and ambiguous identity', () => {
  assert.ok(parseHostMessage(snapshot));
  assert.deepEqual(parseHostMessage({ version: 1, type: 'visibility', visible: false }), { version: 1, type: 'visibility', visible: false });
  for (const bad of [null, {}, { ...snapshot, version: 2 }, { ...snapshot, theme: '../remote' }, { ...snapshot, selectedAgentID: 'missing' }, { ...snapshot, agents: [...agents, agents[0]] }, { ...snapshot, agents: [{ ...agents[0], status: 'pretend-working' }] }, { ...snapshot, agents: [{ ...agents[0], id: '<script>' }] }]) assert.equal(parseHostMessage(bad), null);
});
test('the resident list can find and navigate to agents beyond the first sector', () => {
  const found = searchAgents(agents, ' DESIGN ');
  assert.equal(found.length, 1);
  assert.equal(agentSector(agents, found[0].id), 2);
  assert.equal(sectorAgents(agents, 2).length, 3);
  assert.equal(sectorAgents(agents, 2)[0].id, agents[24].id);
  assert.equal(clampSector(2, 3), 0);
  assert.equal(clampSector(1, 0), 0);
});
test('agent creation availability is supplied explicitly by the native host', () => {
  for (const canCreateAgent of [true, false]) {
    const parsed = parseHostMessage({ ...snapshot, canCreateAgent });
    assert.ok(parsed && parsed.type === 'snapshot');
    assert.equal(parsed.canCreateAgent, canCreateAgent);
  }
  assert.ok(parseHostMessage(snapshot), 'Older snapshots remain compatible without exposing creation');
  for (const canCreateAgent of ['true', 1, null, [], {}]) {
    assert.equal(parseHostMessage({ ...snapshot, canCreateAgent }), null);
  }
});
test('native chrome and Activity Center nonce remain optional and reject invalid host control values', () => {
  assert.ok(parseHostMessage(snapshot));
  for (const activityCenterRequest of [0, 1, 42, Number.MAX_SAFE_INTEGER]) {
    const parsed = parseHostMessage({ ...snapshot, activityCenterRequest, nativeChrome: true });
    assert.ok(parsed && parsed.type === 'snapshot');
    assert.equal(parsed.activityCenterRequest, activityCenterRequest);
    assert.equal(parsed.nativeChrome, true);
  }
  for (const activityCenterRequest of [-1, 0.5, NaN, Infinity, '1', null, Number.MAX_SAFE_INTEGER + 1]) assert.equal(parseHostMessage({ ...snapshot, activityCenterRequest }), null);
  for (const nativeChrome of [1, 'true', null]) assert.equal(parseHostMessage({ ...snapshot, nativeChrome }), null);
});
test('per-agent ship choices accept all 15 supported boats and retain exact native agent identity', () => {
  assert.equal(SHIP_ASSET_TYPES.length, 15);
  const agent = { ...agents[0], id: 'aabbccdd-0000-4000-8000-000000000001' };
  for (const style of SHIP_ASSET_TYPES) {
    const parsed = parseHostMessage({ ...snapshot, agents: [agent], shipStyles: { [agent.id.toUpperCase()]: style } });
    assert.ok(parsed && parsed.type === 'snapshot');
    assert.deepEqual(parsed.shipStyles, { [agent.id]: style });
  }
  assert.deepEqual(parseShipStyles({}, [agent.id]), {}, 'Automatic assignment is represented by an omitted override');
  assert.ok(parseHostMessage(snapshot), 'Older hosts can omit ship styles');
});
test('ship preferences cannot reference stale agents, ambiguous IDs, or unsupported models', () => {
  const agent = { ...agents[0], id: 'aabbccdd-0000-4000-8000-000000000001' };
  const base = { ...snapshot, agents: [agent] };
  const invalidMaps = [
    null, [], 'ship_mihawk_coffin',
    { [agent.id]: 'unknown-boat' }, { [agent.id]: '../assets/ship.glb' }, { [agent.id]: 1 }, { [agent.id]: null },
    { 'aabbccdd-0000-4000-8000-000000000099': 'ship_garp_battleship' },
    { [agent.id]: 'ship_marine_patrol', [agent.id.toUpperCase()]: 'ship_garp_battleship' },
    JSON.parse('{"__proto__":"ship_mihawk_coffin"}'),
  ];
  for (const shipStyles of invalidMaps) assert.equal(parseHostMessage({ ...base, shipStyles }), null);
  const removed = parseHostMessage({ ...base, agents: [], shipStyles: { [agent.id]: 'ship_mihawk_coffin' } });
  assert.equal(removed, null);
});
test('appearance snapshots accept mixed crews, pandas and explorers while keeping older hosts compatible', () => {
  assert.ok(parseHostMessage(snapshot));
  for (const residentStyle of ['mixed', 'pandas', 'explorers']) {
    const parsed = parseHostMessage({ ...snapshot, residentStyle });
    assert.ok(parsed && parsed.type === 'snapshot');
    assert.equal(parsed.residentStyle, residentStyle);
  }
  for (const residentStyle of [null, '', 'Pandas', 'ships', '../pandas', 1, [], {}]) {
    assert.equal(parseHostMessage({ ...snapshot, residentStyle }), null);
  }
});
test('small pointer movement still selects while an orbit drag does not count as a click', () => {
  assert.equal(isClickGesture({ x: 400, y: 300 }, { x: 403, y: 303 }), true);
  assert.equal(isClickGesture({ x: 400, y: 300 }, { x: 445, y: 300 }), false);
  assert.equal(isClickGesture({ x: 400, y: 300 }, { x: 400, y: 315 }), false);
});
test('all real execution states have visible labels', () => {
  assert.equal(STATUS_META.working.label, 'Working');
  assert.equal(STATUS_META.needs_attention.label, 'Needs you');
  assert.equal(STATUS_META.queued.label, 'Queued');
  assert.equal(STATUS_META.failed.label, 'Needs attention');
});
test('floating labels hide over the roster and when any part clips the viewport', () => {
  const roster = { left: 29, top: 115, right: 260, bottom: 590 };
  const header = { left: 29, top: 27, right: 1252, bottom: 75 };
  assert.equal(labelIsUnobscured({ left: 150, top: 160, right: 230, bottom: 205 }, 1280, 720, [roster, header]), false);
  assert.equal(labelIsUnobscured({ left: 1230, top: 300, right: 1310, bottom: 345 }, 1280, 720, []), false);
  assert.equal(labelIsUnobscured({ left: -15, top: 300, right: 65, bottom: 345 }, 1280, 720, []), false);
  assert.equal(labelIsUnobscured({ left: 610, top: 5, right: 690, bottom: 50 }, 1280, 720, []), false);
  assert.equal(labelIsUnobscured({ left: 610, top: 300, right: 690, bottom: 345 }, 1280, 720, [roster, header]), true);
});
test('themes cannot introduce remote URLs or traversal and invalid settings retain safe defaults', () => {
  assert.ok(safeAssetPath('assets/resident.glb'));
  for (const bad of ['https://host/a.glb', 'assets/../secret.glb', 'assets//x.glb', 'assets/./x.glb', '/etc/file.glb', 'assets/foo.glb?remote=true']) assert.equal(safeAssetPath(bad), false);
  const theme = parseTheme({ version: 1, id: 'outpost', assets: { resident: 'assets/resident.glb', station: 'https://host/s.glb', player: 'assets/player.glb' }, heights: { resident: 1.9, station: Infinity }, palette: { sky: 'url(evil)' } });
  assert.deepEqual(theme.assets, { resident: 'assets/resident.glb' });
  assert.equal(theme.heights.resident, 1.9);
  assert.equal(theme.heights.station, DEFAULT_THEME.heights.station);
  assert.equal(theme.palette.sky, DEFAULT_THEME.palette.sky);
});
test('a catalog can add another packaged theme without accepting unsafe IDs or duplicate entries', () => {
  const catalog = parseCatalog({ version: 1, themes: [{ id: 'outpost', name: 'Outpost' }, { id: 'forest-retreat', name: 'Forest Retreat' }, { id: '../remote', name: 'Remote' }, { id: 'outpost', name: 'Duplicate' }] });
  assert.deepEqual(catalog.map(item => item.id), ['outpost', 'forest-retreat']);
  const forest = parseTheme({ version: 1, id: 'forest-retreat', name: 'Forest Retreat', layout: { radius: 18, stations: [{ x: 1, z: 4, rotation: 1 }], props: [{ asset: 'habitat', x: 10, z: 10 }] } });
  assert.equal(forest.id, 'forest-retreat');
  assert.equal(forest.layout.radius, 18);
  assert.deepEqual(forest.layout.stations, [{ x: 1, z: 4, rotation: 1 }]);
  assert.deepEqual(forest.layout.props[0], { asset: 'habitat', x: 10, z: 10 });
  const invalid = parseTheme({ version: 1, id: 'outpost', layout: { radius: NaN, stations: [{ x: 0, z: Infinity }], props: [{ asset: 'untrusted', x: 0, z: 0 }] } });
  assert.deepEqual(invalid.layout, DEFAULT_THEME.layout);
});
