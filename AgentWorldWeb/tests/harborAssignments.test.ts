import test from 'node:test';
import assert from 'node:assert/strict';
import { assignHarbors, reserveNearestHarbors } from '../src/harborAssignments.ts';
import type { HarborShip } from '../src/harborAssignments.ts';
import { createNavigation, createResidentMotion, stepResidentMotion, findResidentPath, segmentIsWalkable } from '../src/residentMotion.ts';
import { activeWorkIslands } from '../src/islandWorkSignals.ts';

const harbors = [{ x: 0, z: 0 }, { x: 10, z: 0 }, { x: 20, z: 0 }];
const distance = (a: { x: number; z: number }, b: { x: number; z: number }) => Math.hypot(a.x - b.x, a.z - b.z);
const working = (id: string, x: number): HarborShip => ({ id, status: 'working', position: { x, z: 1 } });

test('starting work chooses the nearest unoccupied reachable berth, including new destinations', () => {
  const a = working('a', 18);
  assert.equal(reserveNearestHarbors([a], new Map(), harbors, distance, 2).get('a'), 2);
  assert.equal(reserveNearestHarbors([a, { ...working('idle', 20), status: 'idle' }], new Map(), harbors, distance, 2).get('a'), 1);
  assert.equal(reserveNearestHarbors([a], new Map(), harbors, (from, to) => to.x === 20 ? Infinity : distance(from, to), 2).get('a'), 1);
  assert.equal(reserveNearestHarbors([a], new Map(), harbors, () => Infinity, 2).size, 0);
});

test('simultaneous starts reserve distinct islands, survive reorders and waiting, and release on completion', () => {
  const ships = [working('b', 18), working('a', 18)];
  const initial = reserveNearestHarbors(ships, new Map(), harbors, distance, 2);
  assert.equal(new Set(initial.values()).size, 2);
  assert.deepEqual(reserveNearestHarbors([...ships].reverse(), new Map(), harbors, distance, 2), initial);
  const waiting: HarborShip[] = ships.map(ship => ({ ...ship, status: 'needs_attention', position: { x: 0, z: 8 } }));
  assert.deepEqual(reserveNearestHarbors(waiting, initial, harbors, distance, 2), initial);
  const completed: HarborShip[] = [{ ...ships[1], status: 'completed' }, working('c', 19)];
  const next = reserveNearestHarbors(completed, initial, harbors, distance, 0.1);
  assert.equal(next.has('a'), false); assert.equal(next.has('b'), false); assert.equal(next.get('c'), 2);
});

test('closest is measured along navigable water rather than through an island', () => {
  const sea = createNavigation({ radius: 30, bodyRadius: 1.3, obstacles: [{ x: 0, z: 0, radius: 4 }] });
  const ship: HarborShip = { id: 'a', status: 'working', position: { x: -6, z: 0 } };
  const ports = [{ x: 6, z: 0 }, { x: -6, z: 13 }];
  const chosen = reserveNearestHarbors([ship], new Map(), ports, (from, to) => {
    const path = findResidentPath(from, to, sea);
    if (!path) return Infinity;
    let length = 0, previous = from;
    for (const step of path) { assert.ok(segmentIsWalkable(previous, step, sea)); length += distance(previous, step); previous = step; }
    return length;
  }, 2.7);
  assert.equal(chosen.get('a'), 1, 'The clear 13-unit voyage beats the detour around land');
});

test('an already sailing ship changes course to its reserved island and lights it only after docking', () => {
  const sea = createNavigation({ radius: 30, bodyRadius: 1.35 });
  let motion = { ...createResidentMotion('a', harbors[0]), x: 16, z: 5, intent: 'wander' as const, speed: 3 } as ReturnType<typeof createResidentMotion>;
  const chosen = reserveNearestHarbors([{ id: 'a', status: 'working', position: motion }], new Map(), harbors, distance, 2.8).get('a')!;
  assert.equal(chosen, 2);
  let lit = false;
  for (let frame = 0; frame < 600; frame++) {
    const next = stepResidentMotion(motion, { status: 'working', home: harbors[chosen], dt: 0.05 }, sea);
    assert.ok(distance(motion, next) <= 0.15 + 0.00001, 'Changing berth never teleports the ship');
    const lights = activeWorkIslands([{ id: 'a', status: 'working', motion: next, home: harbors[chosen], harbor: chosen }], 3);
    if (next.walking) assert.equal(lights.size, 0);
    lit ||= lights.has('a'); motion = next;
  }
  assert.ok(lit); assert.ok(distance(motion, harbors[chosen]) < 0.0001);
  assert.equal(activeWorkIslands([{ id: 'a', status: 'completed', motion, home: harbors[chosen], harbor: chosen }], 3).size, 0);
});

test('new and removed profiles leave the other ships at their existing islands', () => {
  const original = assignHarbors(['b', 'c', 'd'], new Map(), 12);
  const added = assignHarbors(['a', 'd', 'c', 'b'], original, 12);
  for (const id of ['b', 'c', 'd']) assert.equal(added.get(id), original.get(id));
  assert.equal(added.get('a'), 3);
  const removed = assignHarbors(['d', 'a', 'c'], added, 12);
  for (const id of ['a', 'c', 'd']) assert.equal(removed.get(id), added.get(id));
  const replaced = assignHarbors(['e', 'd', 'c', 'a'], removed, 12);
  assert.equal(replaced.get('e'), 0, 'New ships take an empty berth');
});

test('a full sector has twelve unique homes even after previously visited sectors overlap', () => {
  const ids = Array.from({ length: 12 }, (_, i) => `agent-${i}`);
  const assigned = assignHarbors(ids, new Map(ids.map(id => [id, 0])), 12);
  assert.equal(assigned.size, 12);
  assert.equal(new Set(assigned.values()).size, 12);
  const reordered = assignHarbors([...ids].reverse(), assigned, 12);
  for (const id of ids) assert.equal(reordered.get(id), assigned.get(id));
  assert.equal(assignHarbors([], assigned, 12).size, 0);
});
