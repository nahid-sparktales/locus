import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { GRAND_LINE_LANDMARKS, GRAND_LINE_HARBORS, GRAND_LINE_STATIONS, GRAND_LINE_HOME_NAMES, GRAND_LINE_OBSTACLES, GRAND_LINE_WANDER_POINTS, GRAND_LINE_LABOON_POSITION, GRAND_LINE_SEA_KING_POSITIONS } from '../src/grandLineGeography.ts';
import { parseTheme } from '../src/theme.ts';
import { themeNavigation, findResidentPath, pointIsWalkable, segmentIsWalkable } from '../src/residentMotion.ts';

const manifest = JSON.parse(readFileSync(new URL('../../plugins/agent-world/ui/themes/grand-line/theme.json', import.meta.url), 'utf8'));
const theme = parseTheme(manifest), sea = themeNavigation(theme);
const gap = (a: { x: number; z: number }, b: { x: number; z: number }) => Math.hypot(a.x - b.x, a.z - b.z);

test('fourteen irregular islands retain twelve stable captain homes and two visitable destinations', () => {
  assert.deepEqual(GRAND_LINE_LANDMARKS.slice(0, 12).map(island => island.id), ['twin-cape', 'little-garden', 'drum', 'alabasta', 'water-seven', 'enies-lobby', 'sabaody', 'marineford', 'wano', 'whole-cake', 'laugh-tale', 'jaya']);
  assert.deepEqual(GRAND_LINE_LANDMARKS.slice(12).map(island => island.id), ['elbaf', 'egghead']);
  assert.equal(GRAND_LINE_STATIONS.length, 12); assert.equal(GRAND_LINE_HOME_NAMES.length, 12);
  assert.deepEqual(theme.layout.stations, GRAND_LINE_STATIONS);
  assert.deepEqual(theme.layout.obstacles, GRAND_LINE_OBSTACLES);
  assert.deepEqual(theme.layout.wanderPoints, GRAND_LINE_WANDER_POINTS);
  assert.equal(GRAND_LINE_HARBORS.length, 14);
  for (const visitorHarbor of GRAND_LINE_HARBORS.slice(12)) assert.ok(sea.wanderPoints.some(point => gap(point, visitorHarbor) < 0.00001), `${visitorHarbor.id} must be a real route destination`);
  const jaya = GRAND_LINE_LANDMARKS[11]; assert.equal(jaya.x, -6.6); assert.equal(jaya.z, -21.5);
});

test('varied island footprints leave broad shipping passages and all harbors have full clearance', () => {
  const radii = GRAND_LINE_LANDMARKS.map(island => island.radius);
  assert.ok(Math.max(...radii) / Math.min(...radii) > 2.5, 'Signature destinations should have visibly different sizes');
  assert.ok(new Set(GRAND_LINE_LANDMARKS.map(island => island.z)).size >= 12, 'Avoid restoring the old two rows');
  assert.ok(pointIsWalkable({ x: 0, z: 0 }, sea), 'The center stays open water');
  for (const [index, island] of GRAND_LINE_LANDMARKS.entries()) {
    const harbor = GRAND_LINE_HARBORS[index];
    assert.ok(pointIsWalkable(harbor, sea), `${island.id} harbor clips land or map bounds`);
    assert.ok(Math.abs(gap(island, harbor) - island.radius - 2.35) < 0.00001);
    assert.ok(Math.hypot(island.x, island.z) + island.radius + 0.1 < 34, `${island.id} footprint reaches outside the map`);
    // The model is clamped to radius + .10. Ships need bodyRadius + .06,
    // leaving a visible water gap before the tangent docking maneuver.
    assert.ok(gap(island, harbor) - (island.radius + 0.10) - sea.bodyRadius > 0.8);
    for (const other of GRAND_LINE_LANDMARKS.slice(index + 1)) assert.ok(gap(island, other) - island.radius - other.radius >= 4, `${island.id}/${other.id} need an open passage`);
    for (const other of GRAND_LINE_HARBORS.slice(index + 1)) assert.ok(gap(harbor, other) >= sea.bodyRadius * 2 + 0.08);
  }
});

test('every captain can visit the new islands and pass safely around both sea kings and Laboon', () => {
  assert.equal(GRAND_LINE_LABOON_POSITION.x, GRAND_LINE_LANDMARKS[0].x - 1.38);
  assert.equal(GRAND_LINE_LABOON_POSITION.z, GRAND_LINE_LANDMARKS[0].z - 4.96);
  for (const creature of [GRAND_LINE_LABOON_POSITION, ...GRAND_LINE_SEA_KING_POSITIONS]) assert.equal(pointIsWalkable(creature, sea), false);
  assert.ok(GRAND_LINE_OBSTACLES.length <= 64);
  for (const harbor of GRAND_LINE_HARBORS) for (const target of GRAND_LINE_HARBORS) {
    const route = findResidentPath(harbor, target, sea);
    assert.ok(route, `${harbor.id} cannot reach ${target.id}`);
    let from = { x: harbor.x, z: harbor.z };
    for (const step of route) { assert.ok(segmentIsWalkable(from, step, sea)); from = step; }
    assert.ok(gap(from, target) < 0.00001);
  }
});
