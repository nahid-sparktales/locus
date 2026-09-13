import test from 'node:test';
import assert from 'node:assert/strict';
import { NullEngine } from '@babylonjs/core/Engines/nullEngine.js';
import { Scene } from '@babylonjs/core/scene.js';
import { TransformNode } from '@babylonjs/core/Meshes/transformNode.js';
import { cannonArc, findAllianceBerth, findIdleEncounterBerths, idleEncounterChoice, IDLE_ENCOUNTER_COOLDOWN, MAX_ALLIANCES, MAX_CANNON_PAIRS, MAX_IDLE_ENCOUNTERS, ShipEncounterState, workingShipPairs } from '../src/shipEncounters.ts';
import type { EncounterShip, IdleEncounterKind } from '../src/shipEncounters.ts';
import { createShipEncounterVisuals } from '../src/shipEncounterVisuals.ts';
import { createNavigation, createResidentMotion, pointIsWalkable, resolveResidentSpacing, stepResidentMotion } from '../src/residentMotion.ts';
import { shipBerthHeading } from '../src/islandBerths.ts';
import type { AgentStatus, AgentTransfer } from '../src/state.ts';

const ship = (id: string, x: number, z = 0, status: AgentStatus = 'working'): EncounterShip => ({
  id, agent: { id, name: id, role: 'Generalist', status }, position: { x, z }, home: { x, z, rotation: 0 }, heading: Math.PI / 2, walking: false, speed: 0.7,
});
const transfer = (from = 'a', to = 'b', id = 'event-1', occurredAt = 1000): AgentTransfer => ({ id, fromAgentID: from, toAgentID: to, kind: 'handoff', title: 'Shared work', occurredAt });
const navigation = () => createNavigation({ radius: 50, bodyRadius: 1.35 });

test('cannon partners require stationary working states, remain disjoint and stable under roster reorder', () => {
  const ships = [ship('a', 0), ship('b', 7), ship('c', 13), ship('d', 19), ship('e', 30), ship('f', 37), ship('idle', 1, 0, 'idle'), ship('attention', 2, 0, 'needs_attention')];
  const pairs = workingShipPairs(ships);
  assert.equal(pairs.length, MAX_CANNON_PAIRS);
  assert.deepEqual(workingShipPairs([...ships].reverse()).map(pair => pair.id), pairs.map(pair => pair.id));
  const members = pairs.flatMap(pair => [pair.from.id, pair.to.id]);
  assert.equal(new Set(members).size, members.length);
  assert.ok(!members.includes('idle') && !members.includes('attention'));
  assert.ok(workingShipPairs(ships, new Set(['a', 'b'])).every(pair => ![pair.from.id, pair.to.id].some(id => ['a', 'b'].includes(id))));
  assert.equal(workingShipPairs([ship('a', 0), { ...ship('b', 6), walking: true }]).length, 0);
  assert.equal(workingShipPairs([ship('a', -24), ship('b', 24)]).length, 0);
});

test('cannonball arc clears the sea and lands before the other hull', () => {
  const start = cannonArc({ x: 0, z: 0 }, { x: 20, z: 0 }, -1);
  const midpoint = cannonArc({ x: 0, z: 0 }, { x: 20, z: 0 }, 0.5);
  const landing = cannonArc({ x: 0, z: 0 }, { x: 20, z: 0 }, 5);
  assert.equal(start.x, 1.05); assert.equal(start.y, 0.95);
  assert.equal(landing.x, 18.35); assert.equal(landing.y, 0.08);
  assert.ok(midpoint.y > 3 && midpoint.y < 7);
  assert.ok(Object.values(cannonArc({ x: 1, z: 1 }, { x: 1, z: 1 }, 0.5)).every(Number.isFinite));
});

test('alliance berths clear islands, other ships and their reserved homes', () => {
  const visitor = ship('a', -12), host = ship('b', 8);
  const map = createNavigation({ radius: 50, bodyRadius: 1.35, obstacles: [{ x: 8, z: -5, radius: 1 }] });
  const berth = findAllianceBerth(visitor, host, [visitor, host], map)!;
  assert.ok(berth); assert.ok(berth.z > 0, 'Use open water when shore blocks the first side');
  assert.ok(pointIsWalkable(berth, map)); assert.equal(berth.rotation, host.home.rotation);
  const blocker = ship('c', berth.x, berth.z);
  assert.equal(findAllianceBerth(visitor, host, [visitor, host, blocker], map), undefined);
});

test('only fresh real transfers create bounded, deduplicated rendezvous, and captain attention cancels them', () => {
  const ships = [ship('A', -12), ship('B', 8), ship('c', -12, 15), ship('d', 8, 15), ship('e', -12, -15), ship('f', 8, -15)];
  const state = new ShipEncounterState();
  state.addTransfers([transfer('a', 'b', 'old', 600)], ships, navigation(), 0, 1000, false);
  assert.equal(state.alliances.size, 0);
  state.addTransfers([transfer('a', 'b'), transfer('a', 'c', 'competing'), transfer('c', 'd', 'event-2'), transfer('e', 'f', 'event-3')], ships, navigation(), 0, 1000, false);
  assert.equal(state.alliances.size, MAX_ALLIANCES);
  const destinations = state.destinations(ships, 1, false);
  assert.ok(destinations.has('A') && destinations.has('B'), 'Preserve exact resident IDs after case-insensitive event lookup');
  assert.equal(destinations.size, 4);
  const attention = ships.map(item => item.id === 'A' ? { ...item, agent: { ...item.agent, status: 'needs_attention' as const } } : item);
  assert.equal(state.destinations(attention, 2, false).size, 2);
  state.clear(); state.addTransfers([transfer('a', 'b')], ships, navigation(), 3, 1000, false);
  assert.equal(state.alliances.size, 0, 'An already shown transfer is not replayed after sector changes');
});

test('reduced motion, expired events and selected captains stop encounters', () => {
  const ships = [ship('a', -7), ship('b', 7)], state = new ShipEncounterState(), map = navigation();
  state.addTransfers([transfer('a', 'b', 'reduced')], ships, map, 0, 1000, true);
  assert.equal(state.alliances.size, 0);
  state.addTransfers([transfer()], ships, map, 0, 1000, false);
  assert.equal(state.destinations(ships, 1, false, new Set(['a'])).size, 0);
  state.addTransfers([transfer('a', 'b', 'expiry')], ships, map, 0, 1000, false);
  assert.equal(state.destinations(ships, 181, false).size, 0);
  state.addTransfers([transfer('a', 'b', 'toggle')], ships, map, 0, 1000, false);
  assert.equal(state.destinations(ships, 1, true).size, 0);
});

test('rendezvous uses existing movement and traffic clearance, then returns home', () => {
  const ships = [ship('a', -4), ship('b', 4)], map = navigation(), state = new ShipEncounterState();
  state.addTransfers([transfer()], ships, map, 0, 1000, false);
  const goals = state.destinations(ships, 0, false);
  let motions = ships.map(item => ({ ...createResidentMotion(item.id, item.home), speed: item.speed, heading: item.heading }));
  const step = (targets: typeof goals) => {
    const before = motions;
    motions = resolveResidentSpacing(motions.map((motion, index) => stepResidentMotion(motion, { status: 'working', home: targets.get(ships[index].id) ?? ships[index].home, dt: 0.05 }, map)), before, map);
    motions.forEach((motion, index) => {
      assert.ok(pointIsWalkable(motion, map));
      assert.ok(Math.hypot(motion.x - before[index].x, motion.z - before[index].z) <= motion.speed * 0.05 + 0.000001);
    });
    assert.ok(Math.hypot(motions[0].x - motions[1].x, motions[0].z - motions[1].z) >= map.bodyRadius * 2 + 0.0799);
  };
  for (let i = 0; i < 1000; i++) step(goals);
  assert.ok(Math.hypot(motions[0].x - goals.get('a')!.x, motions[0].z - goals.get('a')!.z) < 0.01);
  assert.ok(Math.abs(motions[0].heading - shipBerthHeading(goals.get('a')!)) < 0.01);
  for (let i = 0; i < 1000; i++) step(new Map());
  assert.ok(Math.hypot(motions[0].x - ships[0].home.x, motions[0].z - ships[0].home.z) < 0.01);
});

test('visual pools never grow, show a real transfer bridge, respect reduced motion and clean up', () => {
  const engine = new NullEngine(), scene = new Scene(engine), parent = new TransformNode('world', scene);
  try {
    const visuals = createShipEncounterVisuals(scene, parent), ships = [ship('a', -8), ship('b', 8)];
    const counts = [scene.meshes.length, scene.geometries.length, scene.materials.length];
    for (let i = 0; i < 1000; i++) visuals.update(ships, [], i / 30, false);
    assert.deepEqual([scene.meshes.length, scene.geometries.length, scene.materials.length], counts);
    assert.ok(scene.meshes.every(mesh => !mesh.isPickable));
    const state = new ShipEncounterState(); state.addTransfers([transfer()], ships, navigation(), 0, 1000, false);
    const alliance = [...state.alliances.values()][0];
    const alongside = [{ ...ships[0], position: alliance.visitorBerth, heading: shipBerthHeading(alliance.visitorBerth) }, ships[1]];
    const labels = visuals.update(alongside, [alliance], 1, false);
    assert.equal(labels.get('a'), 'Alliance · ships connected');
    const bridge = scene.getTransformNodeByName('alliance-gangplank-0')!;
    assert.ok(bridge.isEnabled()); assert.equal(bridge.metadata.transferID, 'event-1');
    visuals.update(alongside, [alliance], 2, true); assert.equal(visuals.root.isEnabled(), false);
    visuals.dispose(); visuals.dispose(); visuals.update(ships, [], 20, false);
    assert.equal(scene.meshes.length, 0); assert.equal(scene.geometries.length, 0);
    assert.equal(scene.materials.filter(item => item.name.startsWith('encounter-')).length, 0);
  } finally { scene.dispose(); engine.dispose(); }
});

function idlePair(kind: IdleEncounterKind | undefined, nextInteracts = false, z = 0): EncounterShip[] {
  for (let i = 0; i < 1000; i++) {
    const from = `idle-a-${kind ?? 'none'}-${i}`, to = `idle-b-${kind ?? 'none'}-${i}`;
    if (idleEncounterChoice(from, to, 0) === kind && (!nextInteracts || idleEncounterChoice(from, to, 1))) return [ship(from, 0, z, 'idle'), ship(to, 6, z, 'idle')];
  }
  throw new Error('Could not find deterministic fixture');
}

test('idle chance is 75%, conditional play-fighting is 55%, and seed draws ignore roster order/case', () => {
  let interactions = 0, cannon = 0;
  for (let sequence = 0; sequence < 20000; sequence++) {
    const choice = idleEncounterChoice('captain-a', 'captain-b', sequence);
    assert.equal(idleEncounterChoice('CAPTAIN-B', 'CAPTAIN-A', sequence), choice);
    if (choice) interactions++;
    if (choice === 'cannon') cannon++;
  }
  assert.ok(Math.abs(interactions / 20000 - 0.75) < 0.012);
  assert.ok(Math.abs(cannon / interactions - 0.55) < 0.012);
});

test('close idle ships draw once per meeting, not per frame or after waiting in proximity', () => {
  const ships = idlePair(undefined, true), state = new ShipEncounterState(), map = navigation();
  state.updateIdle(ships, map, 0, false);
  for (let frame = 1; frame <= 12000; frame++) state.updateIdle(ships, map, frame / 30, false);
  assert.equal(state.idleEncounters.size, 0, 'A declined meeting is not rerolled while the ships stay near');
  state.updateIdle([ships[0], { ...ships[1], position: { x: 13, z: 0 } }], map, 401, false);
  state.updateIdle([...ships].reverse(), map, 402, false);
  assert.equal(state.idleEncounters.size, 1, 'Separating and meeting again consumes the next seeded encounter draw');
  const before = structuredClone([...state.idleEncounters.values()]);
  for (let frame = 1; frame <= 300; frame++) state.updateIdle(ships, map, 402 + frame / 30, false);
  assert.deepEqual([...state.idleEncounters.values()], before, 'Frames do not change the selected kind, duration, ID, or berths');
});

test('idle meetings require two real idle states, reachable water, space and at least two ships', () => {
  const ships = idlePair('chill'), map = navigation();
  for (const status of ['working', 'queued', 'needs_attention', 'failed', 'completed'] as AgentStatus[]) {
    const state = new ShipEncounterState();
    state.updateIdle([ships[0], { ...ships[1], agent: { ...ships[1].agent, status } }], map, 0, false);
    assert.equal(state.idleEncounters.size, 0);
  }
  for (const residents of [[], [ships[0]], [ships[0], { ...ships[1], position: { x: 9.01, z: 0 } }]]) {
    const state = new ShipEncounterState(); state.updateIdle(residents, map, 0, false); assert.equal(state.idleEncounters.size, 0);
  }
  const blocked = createNavigation({ radius: 50, bodyRadius: 1.35, obstacles: [{ x: 3, z: 0, radius: 1 }] });
  assert.equal(findIdleEncounterBerths(ships[0], ships[1], ships, blocked, 'chill'), undefined);
  assert.equal(findIdleEncounterBerths(ships[0], ships[1], [...ships, ship('crowded', 3)], map, 'chill'), undefined);
  const state = new ShipEncounterState(); state.updateIdle(ships, blocked, 0, false); assert.equal(state.idleEncounters.size, 0);
});

test('idle encounters pause after expiry and give way immediately to work, attention, selection, reduction or removal', () => {
  const ships = idlePair('cannon', true), map = navigation();
  const make = () => { const state = new ShipEncounterState(); state.updateIdle(ships, map, 0, false); assert.equal(state.idleEncounters.size, 1); return state; };
  for (const status of ['working', 'queued', 'needs_attention', 'failed', 'completed'] as AgentStatus[]) {
    const state = make(), changed = [ships[0], { ...ships[1], agent: { ...ships[1].agent, status } }];
    assert.equal(state.destinations(changed, 1, false).size, 0, 'Even before the idle updater runs, real state wins');
    assert.equal(state.idleEncounters.size, 0);
  }
  const selected = make(); assert.equal(selected.destinations(ships, 1, false, new Set([ships[0].id.toUpperCase()])).size, 0);
  const reduced = make(); reduced.updateIdle(ships, map, 1, true); assert.equal(reduced.idleEncounters.size, 0);
  const removed = make(); removed.updateIdle([ships[0]], map, 1, false); assert.equal(removed.idleEncounters.size, 0);
  const expired = make();
  const end = [...expired.idleEncounters.values()][0].expiresAt;
  expired.updateIdle([ships[0], { ...ships[1], position: { x: 13, z: 0 } }], map, end, false);
  expired.updateIdle(ships, map, end + IDLE_ENCOUNTER_COOLDOWN - 1, false); assert.equal(expired.idleEncounters.size, 0);
  expired.updateIdle(ships, map, end + IDLE_ENCOUNTER_COOLDOWN + 1, false); assert.equal(expired.idleEncounters.size, 1);
});

test('real transfers preempt idle play and retain their actual transfer identities', () => {
  const ships = idlePair('chill'), state = new ShipEncounterState(), map = navigation();
  state.updateIdle(ships, map, 0, false); assert.equal(state.idleEncounters.size, 1);
  state.addTransfers([transfer(ships[0].id, ships[1].id, 'genuine-handoff')], ships, map, 1, 1000, false);
  assert.equal(state.idleEncounters.size, 0); assert.equal(state.alliances.size, 1);
  state.updateIdle(ships, map, 2, false); assert.equal(state.idleEncounters.size, 0);
  assert.equal([...state.alliances.values()][0].id, 'genuine-handoff');
  assert.equal(state.destinations(ships, 2, false).size, 2);
});

test('idle hulls sail and turn into a safe meetup, then immediately route home when work begins', () => {
  const ships = idlePair('chill'), state = new ShipEncounterState(), map = navigation();
  let motions = ships.map(item => ({ ...createResidentMotion(item.id, item.home), speed: item.speed, heading: item.heading }));
  let settled = false;
  for (let frame = 0; frame < 560; frame++) {
    const current = ships.map((item, index) => ({ ...item, position: motions[index], heading: motions[index].heading, walking: motions[index].walking }));
    state.updateIdle(current, map, frame * 0.05, false);
    const goals = state.destinations(current, frame * 0.05, false), previous = motions;
    assert.equal(goals.size, 2);
    motions = resolveResidentSpacing(motions.map((motion, index) => stepResidentMotion(motion, { status: 'working', home: goals.get(ships[index].id)!, dt: 0.05 }, map)), previous, map);
    assert.ok(Math.hypot(motions[0].x - motions[1].x, motions[0].z - motions[1].z) >= map.bodyRadius * 2 + 0.0799);
    if ([...state.idleEncounters.values()][0]?.settledAt !== undefined) { settled = true; break; }
  }
  assert.ok(settled, 'Both ships reach the nearby berths before the arrival deadline');
  const working = ships.map((item, index) => ({ ...item, agent: { ...item.agent, status: 'working' as const }, position: motions[index], heading: motions[index].heading, walking: motions[index].walking }));
  state.updateIdle(working, map, 28, false);
  assert.equal(state.destinations(working, 28, false).size, 0);
  for (let frame = 0; frame < 300; frame++) motions = resolveResidentSpacing(motions.map((motion, index) => stepResidentMotion(motion, { status: 'working', home: ships[index].home, dt: 0.05 }, map)), motions, map);
  assert.ok(motions.every((motion, index) => Math.hypot(motion.x - ships[index].home.x, motion.z - ships[index].home.z) < 0.01));
});

test('many resident counts stay disjoint and bounded, and pair history cannot grow indefinitely', () => {
  const ships: EncounterShip[] = [];
  for (let i = 0; i < 30; i++) ships.push(ship(`a-${i}`, 0, i * 14, 'idle'), ship(`b-${i}`, 6, i * 14, 'idle'));
  const map = createNavigation({ radius: 500, bodyRadius: 1.35 }), state = new ShipEncounterState();
  state.updateIdle(ships, map, 0, false);
  assert.equal(state.idleEncounters.size, MAX_IDLE_ENCOUNTERS);
  const members = [...state.idleEncounters.values()].flatMap(value => [value.fromID, value.toID]);
  assert.equal(new Set(members).size, members.length);
  for (let i = 0; i < 4200; i++) state.updateIdle([ship(`long-a-${i}`, 0, 0, 'idle'), ship(`long-b-${i}`, 6, 0, 'idle')], map, i * 100 + 100, false);
  assert.ok(Reflect.get(state, 'meetings').size <= 4096);
  assert.ok(Reflect.get(state, 'idleCooldowns').size <= 4096);
});

test('idle visuals use fixed pools, wait for settled hulls and never masquerade as real transfers or work', () => {
  const engine = new NullEngine(), scene = new Scene(engine), parent = new TransformNode('world', scene);
  try {
    const ships = [...idlePair('chill'), ...idlePair('cannon', false, 16)], state = new ShipEncounterState(), map = navigation();
    state.updateIdle(ships, map, 0, false);
    assert.equal(state.idleEncounters.size, 2);
    const encounters = [...state.idleEncounters.values()], visuals = createShipEncounterVisuals(scene, parent);
    const before = JSON.stringify(ships.map(item => item.agent)), counts = [scene.meshes.length, scene.geometries.length, scene.materials.length];
    const goals = state.destinations(ships, 0, false);
    const settled = ships.map(item => ({ ...item, position: goals.get(item.id)!, heading: shipBerthHeading(goals.get(item.id)!) }));
    const pending = visuals.update(ships, [], 0, false, new Set(), encounters);
    assert.ok([...pending.values()].every(value => value.startsWith('Meeting')));
    for (let frame = 0; frame < 300; frame++) visuals.update(settled, [], frame / 30, false, new Set(), encounters);
    assert.deepEqual([scene.meshes.length, scene.geometries.length, scene.materials.length], counts);
    const labels = visuals.update(settled, [], 1, false, new Set(), encounters);
    assert.ok([...labels.values()].some(value => value === 'Chilling · ships connected'));
    assert.ok([...labels.values()].some(value => value === 'Play fight · cannon practice'));
    const bridge = scene.getTransformNodeByName('alliance-gangplank-0')!;
    assert.equal(bridge.metadata.kind, 'ambient-idle-meetup'); assert.equal(bridge.metadata.transferID, undefined);
    const working = settled.map(item => ({ ...item, agent: { ...item.agent, status: 'working' as const } }));
    assert.ok([...visuals.update(working, [], 2, false, new Set(), encounters).values()].every(value => !value.startsWith('Chilling') && !value.startsWith('Play fight')));
    assert.equal(JSON.stringify(ships.map(item => item.agent)), before);
    visuals.update(settled, [], 2, true, new Set(), encounters); assert.equal(visuals.root.isEnabled(), false);
    visuals.dispose(); assert.equal(scene.meshes.length, 0);
  } finally { scene.dispose(); engine.dispose(); }
});
