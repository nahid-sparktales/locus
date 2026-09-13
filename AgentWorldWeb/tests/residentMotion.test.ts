import test from 'node:test';
import assert from 'node:assert/strict';
import { DEFAULT_THEME, DEFAULT_STATIONS, DEFAULT_WANDER_POINTS, parseTheme } from '../src/theme.ts';
import { createNavigation, createResidentMotion, findResidentArrival, findResidentPath, MAX_MOTION_DT, pointIsWalkable, residentAssetForID, residentSeed, residentWanderTargetIndex, RESIDENT_RADIUS, resolveResidentSpacing, segmentIsWalkable, stationObstacle, stationObstacles, statusCanWander, stepResidentMotion, themeNavigation } from '../src/residentMotion.ts';
import type { ResidentMotion, MotionStep, NavigationMap } from '../src/residentMotion.ts';
import type { AgentStatus } from '../src/state.ts';

const firstID = '11111111-1111-4111-8111-111111111111';
const secondID = '22222222-2222-4222-8222-222222222222';
const thirdID = '33333333-3333-4333-8333-333333333333';
const near = (a: { x: number; z: number }, b: { x: number; z: number }, tolerance = 0.0001) => Math.hypot(a.x - b.x, a.z - b.z) < tolerance;
const map = themeNavigation(DEFAULT_THEME);
const home = DEFAULT_STATIONS[0];
function advance(state: ResidentMotion, status: AgentStatus, seconds: number, options: Partial<MotionStep> = {}, nav: NavigationMap = map): ResidentMotion {
  let next = state;
  for (let time = 0; time < seconds; time += MAX_MOTION_DT) next = stepResidentMotion(next, { status, home: next.home, dt: MAX_MOTION_DT, ...options }, nav);
  return next;
}
function awayFromHome(id = firstID): ResidentMotion {
  let state = createResidentMotion(id, home);
  for (let tick = 0; tick < 600; tick++) {
    state = stepResidentMotion(state, { home, status: 'idle', dt: MAX_MOTION_DT }, map);
    if (Math.hypot(state.x - home.x, state.z - home.z) > 2.5 && state.walking) return state;
  }
  throw new Error('Idle resident never left its workstation');
}

test('idle and completed residents explore on deterministic routes, working states do not', () => {
  assert.equal(statusCanWander('idle'), true);
  assert.equal(statusCanWander('completed'), true);
  for (const status of ['working', 'queued', 'needs_attention', 'failed'] as const) {
    assert.equal(statusCanWander(status), false);
    const state = advance(createResidentMotion(firstID, home), status, 30);
    assert.ok(near(state, home));
    assert.equal(state.phase, 'at_station');
    assert.equal(state.walking, false);
  }
  const initial = createResidentMotion(firstID, home);
  const idle = advance(initial, 'idle', 18);
  const completed = advance(initial, 'completed', 18);
  assert.deepEqual(idle, completed);
  assert.ok(!near(idle, home));
  assert.deepEqual(idle, advance(initial, 'idle', 18));
  assert.notDeepEqual(idle, advance(createResidentMotion(secondID, home), 'idle', 18));
});

test('task start mid-walk returns to the assigned station without snapping and stays there', () => {
  for (const status of ['working', 'queued', 'needs_attention', 'failed'] as const) {
    const walking = awayFromHome();
    const first = stepResidentMotion(walking, { home, status, dt: MAX_MOTION_DT }, map);
    assert.equal(first.intent, 'station');
    assert.equal(first.phase, 'returning');
    assert.ok(Math.hypot(first.x - walking.x, first.z - walking.z) <= first.speed * MAX_MOTION_DT + 0.00001);
    assert.ok(!near(first, home));
    const arrived = advance(first, status, 65);
    assert.ok(near(arrived, home));
    assert.equal(arrived.walking, false);
    assert.equal(arrived.phase, 'at_station');
    assert.ok(Math.abs(Math.atan2(Math.sin(arrived.heading - (home.rotation ?? 0)), Math.cos(arrived.heading - (home.rotation ?? 0)))) < 0.0001);
    assert.ok(near(advance(arrived, status, 20), home));
  }
});

test('task completion permits later exploration and a home change navigates rather than teleporting', () => {
  const atWork = advance(createResidentMotion(firstID, home), 'working', 4);
  const wandering = advance(atWork, 'completed', 18);
  assert.ok(!near(wandering, home));
  const newHome = DEFAULT_STATIONS[1];
  const changed = stepResidentMotion(wandering, { home: newHome, status: 'working', dt: MAX_MOTION_DT }, map);
  assert.ok(!near(changed, newHome));
  assert.ok(Math.hypot(changed.x - wandering.x, changed.z - wandering.z) <= changed.speed * MAX_MOTION_DT + 0.00001);
  assert.ok(near(advance(changed, 'working', 80), newHome));
});

test('selection and hover pause idle motion, while work assignment overrides the interaction pause', () => {
  const walking = awayFromHome();
  const paused = advance(walking, 'idle', 10, { paused: true });
  assert.ok(near(paused, walking));
  assert.equal(paused.walking, false);
  assert.equal(paused.phase, 'paused');
  assert.equal(paused.pauseRemaining, walking.pauseRemaining);
  const resumed = stepResidentMotion(paused, { home, status: 'idle', dt: MAX_MOTION_DT }, map);
  assert.equal(resumed.walking, true);
  const assigned = advance(paused, 'working', 70, { paused: true });
  assert.ok(near(assigned, home), 'Selecting an agent then assigning work must not strand it in the promenade');
  assert.equal(assigned.phase, 'at_station');
});

test('hidden time, resumed long frames and invalid delta values never jump an actor', () => {
  const walking = awayFromHome();
  const hidden = stepResidentMotion(walking, { home, status: 'idle', dt: 120, visible: false }, map);
  assert.ok(near(hidden, walking));
  assert.equal(hidden.walking, false);
  const resumed = stepResidentMotion(hidden, { home, status: 'idle', dt: 120, visible: true }, map);
  assert.ok(Math.hypot(resumed.x - hidden.x, resumed.z - hidden.z) <= resumed.speed * MAX_MOTION_DT + 0.00001);
  for (const dt of [NaN, Infinity, -1, 0]) assert.ok(near(stepResidentMotion(walking, { home, status: 'idle', dt }, map), walking));
});

test('reduced motion removes ambient walking but returns an already-wandering resident smoothly', () => {
  const waiting = advance(createResidentMotion(firstID, home), 'idle', 60, { reducedMotion: true });
  assert.ok(near(waiting, home));
  assert.equal(waiting.walking, false);
  const walking = awayFromHome();
  const next = stepResidentMotion(walking, { home, status: 'idle', dt: MAX_MOTION_DT, reducedMotion: true }, map);
  assert.ok(!near(next, home));
  const returned = advance(next, 'idle', 70, { reducedMotion: true });
  assert.ok(near(returned, home));
  assert.equal(returned.walking, false);
});

test('idle ships continue exploring from sea destinations without returning home between trips', () => {
  const shipHome = { x: -10, z: 0, rotation: Math.PI / 2 };
  const sea = createNavigation({ radius: 24, bodyRadius: 1.35, wanderPoints: [{ x: 0, z: 8 }, { x: 12, z: 0 }, { x: 0, z: -8 }] });
  for (const status of ['idle', 'completed'] as const) {
    let state = createResidentMotion(firstID, shipHome);
    const visited = new Set<number>();
    let departed = false;
    for (let tick = 0; tick < 3000; tick++) {
      const next = stepResidentMotion(state, { home: shipHome, status, dt: MAX_MOTION_DT, rosterIDs: [firstID] }, sea);
      if (next.route.length) assert.ok(!near(next.route.at(-1)!, shipHome), 'An idle route must not require a return to port');
      sea.wanderPoints.forEach((point, index) => { if (near(next, point)) visited.add(index); });
      if (departed) assert.ok(!near(next, shipHome), 'Idle ships must continue from the last destination');
      departed ||= Math.hypot(next.x - shipHome.x, next.z - shipHome.z) > 1;
      assert.ok(segmentIsWalkable(state, next, sea));
      state = next;
    }
    assert.equal(visited.size, sea.wanderPoints.length, 'Every sea destination should remain available while idle');
    const paused = advance(state, status, 10, { paused: true }, sea);
    assert.ok(near(paused, state));
    assert.equal(paused.phase, 'paused');
    const returned = advance(state, status, 90, { reducedMotion: true }, sea);
    assert.ok(near(returned, shipHome));
    assert.equal(returned.phase, 'at_station');
  }
});

test('navigation routes around the garden, desks and décor and keeps all twelve homes reachable', () => {
  assert.equal(DEFAULT_STATIONS.length, 12);
  assert.equal(DEFAULT_WANDER_POINTS.length, 16);
  for (const station of DEFAULT_STATIONS) {
    assert.ok(pointIsWalkable(station, map));
    for (const target of DEFAULT_WANDER_POINTS) {
      const path = findResidentPath(station, target, map);
      assert.ok(path?.length, `No route from ${JSON.stringify(station)} to ${JSON.stringify(target)}`);
      let from = station;
      for (const point of path) { assert.ok(segmentIsWalkable(from, point, map)); from = point; }
    }
  }
  const crossed = findResidentPath({ x: -6.7, z: 0 }, { x: 6.7, z: 0 }, map);
  assert.ok(crossed && crossed.length > 1, 'The central garden cannot be crossed directly');
  assert.equal(segmentIsWalkable({ x: -6.7, z: 0 }, { x: 6.7, z: 0 }, map), false);
  const desk = stationObstacle(home);
  assert.ok(Math.abs(Math.hypot(desk.x - home.x, desk.z - home.z) - 1.6) < 0.0001);
  assert.equal(stationObstacles(home).length, 3);
});

test('long-running idle movement remains within the island and never clips obstacles', () => {
  for (let index = 0; index < DEFAULT_STATIONS.length; index++) {
    const station = DEFAULT_STATIONS[index];
    let state = createResidentMotion(`resident-${index}`, station);
    for (let tick = 0; tick < 1800; tick++) {
      const next = stepResidentMotion(state, { home: station, status: 'idle', dt: MAX_MOTION_DT }, map);
      assert.ok(pointIsWalkable(next, map), `Resident ${index} entered an obstacle`);
      assert.ok(segmentIsWalkable(state, next, map));
      state = next;
    }
  }
});

test('unreachable goals keep residents in a safe location instead of projecting through geometry', () => {
  const sealed = createNavigation({ radius: 12, obstacles: [{ x: 0, z: 0, radius: 2 }], wanderPoints: [{ x: 6, z: 0 }] });
  assert.equal(findResidentPath({ x: 6, z: 0 }, { x: 0, z: 0 }, sealed), null);
  const initial = createResidentMotion(firstID, { x: 6, z: 0 });
  const next = stepResidentMotion(initial, { home: { x: 0, z: 0 }, status: 'working', dt: 1 }, sealed);
  assert.ok(near(initial, next));
  assert.equal(next.walking, false);
});

test('new arrivals use an empty home and reserve distinct reachable positions around occupied homes', () => {
  const sea = createNavigation({ radius: 14, bodyRadius: 1.35, obstacles: [{ x: 0, z: -3, radius: 1 }] });
  const berth = { x: 0, z: 0, rotation: Math.PI };
  const occupied = [findResidentArrival(berth, sea, [])!];
  assert.deepEqual(occupied[0], { x: berth.x, z: berth.z });
  for (let index = 0; index < 8; index++) {
    const before = structuredClone(occupied);
    const arrival = findResidentArrival(berth, sea, occupied);
    assert.deepEqual(occupied, before, 'Arrival search must not move or mutate existing residents');
    assert.ok(arrival && pointIsWalkable(arrival, sea));
    assert.ok(occupied.every(peer => Math.hypot(arrival.x - peer.x, arrival.z - peer.z) >= sea.bodyRadius * 2 + 0.08));
    assert.ok(findResidentPath(arrival, berth, sea), 'Every arrival must retain a route to its assigned home');
    occupied.push(arrival);
  }
});

test('arrival search declines a full or unreachable map without unsafe placement', () => {
  const smallSea = createNavigation({ radius: 2, bodyRadius: 1.35, wanderPoints: [] });
  assert.equal(findResidentArrival({ x: 0, z: 0 }, smallSea, [{ x: 0, z: 0 }]), null);
  const blockedSea = createNavigation({ radius: 14, bodyRadius: 1.35, obstacles: [{ x: 0, z: 0, radius: 2 }] });
  assert.equal(findResidentArrival({ x: 0, z: 0 }, blockedSea, []), null);
});

test('stable appearance uses complete identity independently of roster order and asset ordering', () => {
  const ids = [firstID, secondID, thirdID];
  const assets = ['resident', 'resident_explorer', 'resident_engineer', 'resident_botanist'] as const;
  const expected = new Map(ids.map(id => [id, residentAssetForID(id, assets)]));
  for (const id of [...ids].reverse()) {
    assert.equal(residentAssetForID(id, [...assets].reverse()), expected.get(id));
    assert.equal(residentAssetForID(id.toUpperCase(), assets), expected.get(id));
  }
  assert.equal(new Set(ids.map(id => residentSeed(id))).size, 3);
  assert.equal(new Set(expected.values()).size, 3, 'Representative native UUIDs should exercise different character appearances');
  assert.equal(residentAssetForID(firstID, []), 'resident');
});

test('opposing residents yield and pass with bounded steps without overlapping or entering obstacles', () => {
  const open = createNavigation({ radius: 10, obstacles: [{ x: 0, z: 2, radius: 0.8 }], wanderPoints: [] });
  const homes = [{ x: 4, z: 0, rotation: Math.PI / 2 }, { x: -4, z: 0, rotation: -Math.PI / 2 }];
  let states = [createResidentMotion('a', { x: -4, z: 0 }), createResidentMotion('b', { x: 4, z: 0 })];
  for (let tick = 0; tick < 800; tick++) {
    const proposals = states.map((state, i) => stepResidentMotion(state, { home: homes[i], status: 'working', dt: MAX_MOTION_DT }, open));
    const next = resolveResidentSpacing(proposals, states, open);
    assert.ok(Math.hypot(next[0].x - next[1].x, next[0].z - next[1].z) >= RESIDENT_RADIUS * 2 + 0.08 - 0.00001);
    for (let i = 0; i < next.length; i++) {
      assert.ok(pointIsWalkable(next[i], open));
      assert.ok(Math.hypot(next[i].x - states[i].x, next[i].z - states[i].z) <= next[i].speed * MAX_MOTION_DT + 0.00001);
    }
    states = next;
  }
  assert.ok(near(states[0], homes[0]) && near(states[1], homes[1]), 'Residents must pass, not deadlock head-on');
});

test('spacing results are identity-stable across roster reordering and do not displace paused residents', () => {
  const open = createNavigation({ radius: 10, wanderPoints: [] });
  const before = [createResidentMotion('a', { x: -0.45, z: 0 }), createResidentMotion('b', { x: 0.45, z: 0 })];
  const proposals = before.map((state, i) => ({ ...state, walking: true, x: state.x + (i === 0 ? 0.04 : -0.04) }));
  proposals[1] = { ...before[1], phase: 'paused', walking: false };
  const resolved = resolveResidentSpacing(proposals, before, open, new Set(['b']));
  const reordered = resolveResidentSpacing([...proposals].reverse(), [...before].reverse(), open, new Set(['b'])).reverse();
  assert.deepEqual(resolved, reordered);
  assert.ok(near(resolved[1], before[1]));
  assert.ok(segmentIsWalkable(before[0], resolved[0], open));
});

test('ships choose another idle destination after a traffic wait while preserving required work destinations', () => {
  const sea = createNavigation({ radius: 14, bodyRadius: 1.35, wanderPoints: [{ x: 0, z: 0 }, { x: -6, z: 6 }] });
  for (const status of ['idle', 'working'] as const) {
    const shipHome = status === 'idle' ? { x: -7, z: 0 } : { x: 0, z: 0 };
    let states = [
      { ...createResidentMotion('roamer', shipHome), x: -4, heading: Math.PI / 2, speed: 1,
        intent: status === 'idle' ? 'wander' as const : 'station' as const, route: [{ x: 0, z: 0 }], sequence: 1 },
      { ...createResidentMotion('selected', { x: 6, z: 0 }), x: 0 },
    ];
    for (let tick = 0; tick < 240; tick++) {
      const proposed = states.map((state, index) => stepResidentMotion(state, {
        home: state.home, status: index === 0 ? status : 'idle', dt: MAX_MOTION_DT, paused: index === 1, rosterIDs: ['roamer'],
      }, sea));
      states = resolveResidentSpacing(proposed, states, sea, new Set(['selected']));
      assert.ok(near(states[1], { x: 0, z: 0 }), 'Resolving traffic must not displace a selected ship');
    }
    if (status === 'idle') {
      assert.ok(states[0].z > 3, 'An occupied ambient destination must not strand the ship');
      assert.ok(states[0].sequence > 1);
    } else {
      assert.equal(states[0].intent, 'station');
      assert.ok(near(states[0].route.at(-1)!, shipHome), 'Traffic must not replace a required work destination');
      assert.equal(states[0].sequence, 1);
    }
  }
});

test('wander destinations stay evenly spread across rounds regardless of roster order', () => {
  const ids = ['a', 'b', 'c', 'd', 'e', 'f'];
  for (let round = 0; round < 32; round++) {
    const destinations = ids.map(id => residentWanderTargetIndex(id, round, 16, ids));
    assert.equal(new Set(destinations).size, ids.length);
    const sorted = [...destinations].sort((a, b) => a - b);
    for (let i = 0; i < sorted.length; i++) assert.ok((sorted[(i + 1) % sorted.length] - sorted[i] + 16) % 16 >= 2);
    for (const id of ids) assert.equal(residentWanderTargetIndex(id, round, 16, [...ids].reverse()), residentWanderTargetIndex(id, round, 16, ids));
  }
  assert.equal(new Set(Array.from({ length: 16 }, (_, round) => residentWanderTargetIndex('a', round, 16, ids))).size, 16);
  let walker = createResidentMotion('a', home);
  for (let tick = 0; tick < 1800; tick++) {
    walker = stepResidentMotion(walker, { home, status: 'idle', dt: MAX_MOTION_DT, rosterIDs: ids }, map);
    assert.ok(Math.hypot(walker.x, walker.z) > 6, 'Ambient routes should use the promenade rather than hugging the inner garden');
  }
});

test('a full campus walks around the promenade with clearance, then returns safely to work', () => {
  const ids = DEFAULT_STATIONS.map((_, index) => `campus-${index}`);
  let states = DEFAULT_STATIONS.map((station, index) => createResidentMotion(ids[index], station));
  const totalTravel = states.map(() => 0);
  for (let tick = 0; tick < 3600; tick++) {
    const status = tick < 1800 ? 'idle' : 'working';
    const proposals = states.map((state, index) => stepResidentMotion(state, { home: DEFAULT_STATIONS[index], status, dt: MAX_MOTION_DT, rosterIDs: ids }, map));
    const next = resolveResidentSpacing(proposals, states, map);
    for (let i = 0; i < next.length; i++) {
      const traveled = Math.hypot(next[i].x - states[i].x, next[i].z - states[i].z);
      totalTravel[i] += traveled;
      assert.ok(traveled <= next[i].speed * MAX_MOTION_DT + 0.00001);
      assert.ok(segmentIsWalkable(states[i], next[i], map));
      for (let j = i + 1; j < next.length; j++) assert.ok(Math.hypot(next[i].x - next[j].x, next[i].z - next[j].z) >= RESIDENT_RADIUS * 2 + 0.08 - 0.00001);
    }
    states = next;
  }
  for (let index = 0; index < states.length; index++) {
    assert.ok(totalTravel[index] > 20, 'Every resident should explore, not stay deadlocked near its first waypoint');
    assert.ok(near(states[index], DEFAULT_STATIONS[index]), `Resident ${index} did not return to work`);
  }
});

test('theme parsing supports diverse residents and local campus props with bounded navigation inputs', () => {
  const theme = parseTheme({ version: 1, id: 'outpost', assets: { resident_botanist: 'assets/botanist.glb', resident_engineer: 'assets/engineer.glb', resident_explorer: 'assets/explorer.glb', planter: 'assets/planter.glb', lounge: 'https://remote/lounge.glb' },
    layout: { obstacles: [{ x: 0, z: 0, radius: 3 }], wanderPoints: [{ x: 7, z: 0 }], props: [{ asset: 'planter', x: 9, z: 0, radius: 1.15 }] } });
  assert.ok(theme.assets.resident_botanist && theme.assets.resident_engineer && theme.assets.resident_explorer && theme.assets.planter);
  assert.equal(theme.assets.lounge, undefined);
  assert.deepEqual(theme.layout.obstacles, [{ x: 0, z: 0, radius: 3 }]);
  assert.deepEqual(theme.layout.wanderPoints, [{ x: 7, z: 0 }]);
  assert.equal(theme.layout.props[0].radius, 1.15);
  const bad = parseTheme({ version: 1, id: 'outpost', layout: { obstacles: [{ x: 0, z: 0, radius: Infinity }], wanderPoints: [{ x: 40, z: 0 }] } });
  assert.deepEqual(bad.layout.obstacles, DEFAULT_THEME.layout.obstacles);
  assert.deepEqual(bad.layout.wanderPoints, DEFAULT_THEME.layout.wanderPoints);
});
