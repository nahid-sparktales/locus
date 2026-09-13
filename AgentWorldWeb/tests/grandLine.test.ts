import { shipBerthHeading } from '../src/islandBerths.ts';
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DEFAULT_THEME, SHIP_ASSET_TYPES, SHIP_NAMES, parseTheme, safeAssetPath } from '../src/theme.ts';
import {
  MAX_MOTION_DT, RESIDENT_RADIUS, createResidentMotion, findResidentArrival, findResidentPath,
  pointIsWalkable, resolveResidentSpacing, segmentIsWalkable, stationObstacle,
  stepResidentMotion, themeNavigation,
} from '../src/residentMotion.ts';
import type { Point } from '../src/state.ts';

const manifestURL = new URL('../../plugins/agent-world/ui/themes/grand-line/theme.json', import.meta.url);
const loadGrandLine = () => parseTheme(JSON.parse(readFileSync(manifestURL, 'utf8')));
const distance = (a: Point, b: Point) => Math.hypot(a.x - b.x, a.z - b.z);
const near = (a: Point, b: Point) => distance(a, b) < 0.00001;

test('only the explicit ocean environment enables ships; old and malformed themes retain campus behavior', () => {
  assert.equal(parseTheme({ version: 1, id: 'grand-line', environment: 'ocean' }).environment, 'ocean');
  for (const environment of [undefined, null, true, 1, 'Ocean', 'space', 'ocean/../campus', {}, ['ocean']]) {
    const theme = parseTheme({ version: 1, id: 'outpost', environment });
    assert.equal(theme.environment, 'campus');
    assert.equal(themeNavigation(theme).bodyRadius, RESIDENT_RADIUS);
  }
  assert.equal(parseTheme({ version: 2, id: 'grand-line', environment: 'ocean' }), DEFAULT_THEME);
  assert.equal(parseTheme({ version: 1, id: '../grand-line', environment: 'ocean' }), DEFAULT_THEME);
});

test('ocean berths remain open water while campus homes retain their console obstacles', () => {
  const layout = { radius: 18, stations: [{ x: -5, z: 0, rotation: 0 }, { x: 5, z: 0, rotation: Math.PI }], props: [], obstacles: [], wanderPoints: [{ x: 0, z: 7 }] };
  const ocean = parseTheme({ version: 1, id: 'grand-line', environment: 'ocean', layout });
  const campus = parseTheme({ version: 1, id: 'outpost', environment: 'campus', layout });
  const sea = themeNavigation(ocean), land = themeNavigation(campus);
  assert.equal(sea.bodyRadius, 1.35);
  assert.equal(land.bodyRadius, RESIDENT_RADIUS);
  assert.equal(sea.obstacles.length, 0, 'Invisible outpost desks must never block an ocean berth');
  assert.equal(land.obstacles.length, layout.stations.length * 3);
  for (const home of layout.stations) {
    const consolePosition = stationObstacle(home);
    assert.ok(pointIsWalkable(home, sea));
    assert.ok(pointIsWalkable(home, land));
    assert.ok(segmentIsWalkable(home, consolePosition, sea));
    assert.equal(pointIsWalkable(consolePosition, land), false);
  }
});

test('the shipped Local Line manifest packages twelve distinct named ships with usable local models', () => {
  const theme = loadGrandLine();
  assert.equal(theme.id, 'grand-line', 'Display renames must preserve the saved theme identity');
  assert.equal(theme.name, 'The Local Line');
  assert.equal(SHIP_NAMES.ship_going_merry, 'Going Sherry');
  assert.equal(SHIP_NAMES.ship_thousand_sunny, 'Thousand Funny');
  assert.equal(theme.environment, 'ocean');
  assert.equal(SHIP_ASSET_TYPES.length, 12);
  assert.equal(theme.layout.stations.length, 12, 'Every ship in a full sector needs its own berth');
  assert.equal(new Set(SHIP_ASSET_TYPES.map(ship => theme.assets[ship])).size, 12);
  assert.equal(new Set(SHIP_ASSET_TYPES.map(ship => SHIP_NAMES[ship])).size, 12);
  for (const ship of SHIP_ASSET_TYPES) {
    const asset = theme.assets[ship];
    assert.ok(asset && safeAssetPath(asset), `${SHIP_NAMES[ship]} needs a packaged local model`);
    assert.ok(theme.heights[ship] > 0 && Number.isFinite(theme.heights[ship]));
    assert.equal(theme.rotations[ship], -Math.PI / 2, `${SHIP_NAMES[ship]} must align its verified +X bow with forward +Z`);
    const model = readFileSync(new URL(asset, manifestURL));
    assert.equal(model.toString('ascii', 0, 4), 'glTF', `${SHIP_NAMES[ship]} must be a GLB, not a download error`);
    assert.equal(model.readUInt32LE(4), 2);
    assert.equal(model.readUInt32LE(8), model.length, `${SHIP_NAMES[ship]} model must be complete`);
  }
});

test('every shipped berth and sea route waypoint is reachable with full ship clearance', () => {
  const theme = loadGrandLine(), sea = themeNavigation(theme);
  assert.equal(sea.bodyRadius, 1.35);
  assert.ok(theme.layout.wanderPoints.length >= 12, 'A full fleet needs enough distinct route destinations');
  assert.equal(sea.wanderPoints.length, theme.layout.wanderPoints.length, 'Navigation must not silently discard waypoints inside an island');
  const points = [...theme.layout.stations, ...theme.layout.wanderPoints];
  for (const [index, point] of points.entries()) assert.ok(pointIsWalkable(point, sea), `Ship location ${index} clips a shoreline or the map boundary`);
  for (let index = 0; index < theme.layout.stations.length; index++) {
    const berth = theme.layout.stations[index];
    for (const other of theme.layout.stations.slice(index + 1)) {
      assert.ok(distance(berth, other) >= sea.bodyRadius * 2 + 0.08, 'Two ships must not begin in overlapping berths');
    }
    for (const target of points) {
      const path = findResidentPath(berth, target, sea);
      assert.ok(path, `Berth ${index} has no sea route to ${JSON.stringify(target)}`);
      let from = berth;
      for (const step of path) {
        assert.ok(segmentIsWalkable(from, step, sea), 'A route segment clips land or the map edge');
        from = step;
      }
      assert.ok(near(from, target), 'A route must reach its requested destination');
    }
  }
});

test('a full fleet sails without collisions and returns to its own berths when work begins', () => {
  const theme = loadGrandLine(), sea = themeNavigation(theme);
  const homes = theme.layout.stations;
  const ids = homes.map((_, index) => `fleet-${String(index).padStart(2, '0')}`);
  let states = homes.map((home, index) => ({ ...createResidentMotion(ids[index], home), speed: 0.52 }));
  const travel = states.map(() => 0);
  const minimumSeparation = sea.bodyRadius * 2 + 0.08;
  // Three minutes of ambient sailing, then three minutes of returning to work.
  for (let tick = 0; tick < 7200; tick++) {
    const status = tick < 3600 ? 'idle' : 'working';
    const proposed = states.map((state, index) => stepResidentMotion(state, { home: homes[index], status, dt: MAX_MOTION_DT, rosterIDs: ids }, sea));
    const next = resolveResidentSpacing(proposed, states, sea);
    for (let i = 0; i < next.length; i++) {
      const moved = distance(states[i], next[i]);
      travel[i] += moved;
      if (moved > 0.00001) {
        const course = Math.atan2(next[i].x - states[i].x, next[i].z - states[i].z);
        assert.ok(Math.abs(Math.atan2(Math.sin(course - next[i].heading), Math.cos(course - next[i].heading))) < 0.002, `Ship ${i} sailed sideways at tick ${tick}`);
      }
      assert.ok(moved <= next[i].speed * MAX_MOTION_DT + 0.00001, 'A ship must never teleport to recover from traffic');
      assert.ok(segmentIsWalkable(states[i], next[i], sea), `Ship ${i} crossed land at tick ${tick}`);
      for (let j = i + 1; j < next.length; j++) assert.ok(distance(next[i], next[j]) >= minimumSeparation - 0.00001, `Ships ${i} and ${j} overlap at tick ${tick}`);
    }
    states = next;
  }
  for (let index = 0; index < states.length; index++) {
    assert.ok(travel[index] > 12, `Ship ${index} remained stuck instead of exploring the sea`);
    assert.ok(near(states[index], homes[index]), `Ship ${index} could not return to its berth`);
  }
});

test('every ship has a distinct island harbor with an approach bearing toward the landing', () => {
  const theme = loadGrandLine(), sea = themeNavigation(theme);
  const assignedIslands = new Set<string>();
  for (const berth of theme.layout.stations) {
    const island = theme.layout.obstacles.reduce((closest, obstacle) => distance(berth, obstacle) < distance(berth, closest) ? obstacle : closest);
    const islandKey = `${island.x}:${island.z}`;
    assert.equal(assignedIslands.has(islandKey), false, 'Two agents must not share the same home island');
    assignedIslands.add(islandKey);
    assert.ok(distance(berth, island) > island.radius + sea.bodyRadius + 0.4, 'The entire ship must clear the island landing');
    assert.ok(distance(berth, island) < island.radius + sea.bodyRadius + 1.8, 'The berth must sit beside its own island');
    const towardsIsland = Math.atan2(island.x - berth.x, island.z - berth.z);
    assert.ok(Math.abs(Math.atan2(Math.sin(towardsIsland - (berth.rotation ?? 0)), Math.cos(towardsIsland - (berth.rotation ?? 0)))) < 0.00001, 'The approach bearing must face its own landing without rotating patrol lanes');
  }
  assert.equal(assignedIslands.size, 12);
});

test('idle ships leave promptly and explore beyond their home islands with fleet clearance', () => {
  const theme = loadGrandLine(), sea = themeNavigation(theme), homes = theme.layout.stations;
  const ids = homes.map((_, index) => `free-roaming-${index}`);
  let states = homes.map((home, index) => ({ ...createResidentMotion(ids[index], home), speed: 0.52 }));
  const furthest = homes.map(() => 0), departureTicks = homes.map(() => -1);
  // Allow time for busy sea lanes to change a ship's destination along the way.
  for (let tick = 0; tick < 3600; tick++) {
    const proposed = states.map((state, index) => stepResidentMotion(state, { home: homes[index], status: 'idle', dt: MAX_MOTION_DT, rosterIDs: ids }, sea));
    const next = resolveResidentSpacing(proposed, states, sea);
    for (let index = 0; index < next.length; index++) {
      const fromHarbor = distance(next[index], homes[index]);
      furthest[index] = Math.max(furthest[index], fromHarbor);
      if (departureTicks[index] < 0 && fromHarbor > 0.1) departureTicks[index] = tick;
      assert.ok(segmentIsWalkable(states[index], next[index], sea));
      for (let other = index + 1; other < next.length; other++) assert.ok(distance(next[index], next[other]) >= sea.bodyRadius * 2 + 0.08 - 0.00001, 'Freely roaming ships must keep their clearance');
    }
    states = next;
  }
  for (let index = 0; index < homes.length; index++) {
    assert.ok(furthest[index] > 8, `Ship ${index} remained tethered to its own island`);
    assert.ok(departureTicks[index] >= 0 && departureTicks[index] < 200, `Ship ${index} waited too long to start exploring`);
  }
});

test('adding a captain while a ship crosses its harbor keeps both moving without overlap', () => {
  const theme = loadGrandLine(), sea = themeNavigation(theme), homes = theme.layout.stations;
  let survivor = { ...createResidentMotion('captain-0', homes[0]), speed: 0.52 };
  for (let tick = 0; tick <= 3528; tick++) survivor = stepResidentMotion(survivor, { home: homes[0], status: 'idle', dt: MAX_MOTION_DT, rosterIDs: [survivor.id] }, sea);
  const clearance = sea.bodyRadius * 2 + 0.08;
  assert.ok(distance(survivor, homes[1]) < clearance, 'The regression needs a ship crossing the new captain’s berth');
  const arrival = findResidentArrival(homes[1], sea, [survivor]);
  assert.ok(arrival && distance(arrival, survivor) > clearance);
  let states = [survivor, { ...createResidentMotion('new-agent', homes[1]), ...arrival, speed: 0.52 }];
  const travel = [0, 0];
  for (let tick = 0; tick < 4800; tick++) {
    const proposed = states.map(state => stepResidentMotion(state, { home: state.home, status: tick < 2400 ? 'idle' : 'working', dt: MAX_MOTION_DT, rosterIDs: states.map(item => item.id) }, sea));
    const next = resolveResidentSpacing(proposed, states, sea);
    for (let index = 0; index < next.length; index++) {
      const moved = distance(states[index], next[index]);
      travel[index] += moved;
      assert.ok(moved <= next[index].speed * MAX_MOTION_DT + 0.00001);
      assert.ok(segmentIsWalkable(states[index], next[index], sea));
    }
    assert.ok(distance(next[0], next[1]) >= clearance - 0.00001);
    states = next;
  }
  assert.ok(travel.every(length => length > 10), 'Both the survivor and newcomer must keep sailing');
  assert.ok(near(states[0], homes[0]) && near(states[1], homes[1]), 'Both captains must still return to their own islands');
});

test('a freely roaming fleet keeps sailing instead of waiting indefinitely at occupied destinations', () => {
  const theme = loadGrandLine(), sea = themeNavigation(theme), homes = theme.layout.stations;
  const ids = homes.map((_, index) => `c-${index}`);
  let states = homes.map((home, index) => ({ ...createResidentMotion(ids[index], home), speed: 0.52 }));
  const lastMove = states.map(() => 0);
  // These identities previously formed a permanent cluster after their first
  // few destinations. Cover enough rounds for their travel timings to diverge.
  for (let tick = 0; tick < 12000; tick++) {
    const proposed = states.map(state => stepResidentMotion(state, { home: state.home, status: 'idle', dt: MAX_MOTION_DT, rosterIDs: ids }, sea));
    const next = resolveResidentSpacing(proposed, states, sea);
    for (let index = 0; index < next.length; index++) {
      if (distance(states[index], next[index]) > 0.00001) lastMove[index] = tick;
      assert.ok((tick - lastMove[index]) * MAX_MOTION_DT < 15, `Ship ${index} stopped exploring because another ship occupied its destination`);
    }
    states = next;
  }
});

test('work, queued work, attention and failures return ships to their own islands and keep them parked', () => {
  const theme = loadGrandLine(), sea = themeNavigation(theme);
  for (const status of ['working', 'queued', 'needs_attention', 'failed'] as const) {
    for (const [index, home] of theme.layout.stations.entries()) {
      const away = sea.wanderPoints.find(point => distance(point, home) > 2 && distance(point, home) < 5 && segmentIsWalkable(home, point, sea));
      assert.ok(away, `Island ${index} needs a usable local patrol point`);
      let state = { ...createResidentMotion(`working-harbor-${index}`, home), ...away, intent: 'wander' as const, speed: 0.52 };
      let parked = false;
      for (let tick = 0; tick < 1200; tick++) {
        const next = stepResidentMotion(state, { home, status, dt: MAX_MOTION_DT, paused: true }, sea);
        const moved = distance(state, next);
        assert.ok(moved <= next.speed * MAX_MOTION_DT + 0.00001);
        assert.ok(segmentIsWalkable(state, next, sea));
        if (moved > 0.00001) {
          const course = Math.atan2(next.x - state.x, next.z - state.z);
          assert.ok(Math.abs(Math.atan2(Math.sin(course - next.heading), Math.cos(course - next.heading))) < 0.002, 'Returning ships must sail bow-first');
        }
        if (parked) assert.ok(near(next, home), `${status} must keep the ship at its assigned island`);
        parked ||= near(next, home);
        state = next;
      }
      assert.ok(parked, `Ship ${index} did not dock when status changed to ${status}`);
      assert.equal(state.walking, false);
      assert.equal(state.phase, 'at_station');
      assert.ok(Math.abs(Math.atan2(Math.sin(state.heading - shipBerthHeading(home)), Math.cos(state.heading - shipBerthHeading(home)))) < 0.00001);
    }
  }
});
