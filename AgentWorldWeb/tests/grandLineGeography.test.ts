import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { GRAND_LINE_MAP_RADIUS, GRAND_LINE_CALM_BELT, GRAND_LINE_SAILING_BOUNDS, GRAND_LINE_SKY_ISLAND, MARY_GEOISE, MARINEFORD_CURRENT, islandShoreDistance, islandArtworkRotation, GRAND_LINE_LANDMARKS, GRAND_LINE_HARBORS, GRAND_LINE_STATIONS, GRAND_LINE_HOME_NAMES, GRAND_LINE_OBSTACLES, GRAND_LINE_WANDER_POINTS, GRAND_LINE_LABOON_POSITION, GRAND_LINE_SEA_KING_POSITIONS } from '../src/grandLineGeography.ts';
import { parseTheme } from '../src/theme.ts';
import { themeNavigation, findResidentPath, pointIsWalkable, segmentIsWalkable } from '../src/residentMotion.ts';

const manifest = JSON.parse(readFileSync(new URL('../../plugins/agent-world/ui/themes/grand-line/theme.json', import.meta.url), 'utf8'));
const theme = parseTheme(manifest), sea = themeNavigation(theme);
const gap = (a: { x: number; z: number }, b: { x: number; z: number }) => Math.hypot(a.x - b.x, a.z - b.z);

test('every island front faces its connected dock in every cardinal direction', () => {
  for (const [index, island] of GRAND_LINE_LANDMARKS.entries()) {
    const harbor = GRAND_LINE_HARBORS[index], angle = islandArtworkRotation(island.id);
    assert.ok(Math.abs(Math.sin(angle) - harbor.direction.x) < 1e-8, island.id);
    assert.ok(Math.abs(Math.cos(angle) - harbor.direction.z) < 1e-8, island.id);
    assert.ok(islandShoreDistance(island.radius) + 0.24 - 0.80 < island.radius * 0.6,
      `${island.id} deck must overlap its front shoreline`);
    assert.ok(pointIsWalkable(harbor, sea));
  }
});

test('twenty islands retain twelve stable captain homes and eight visitable destinations', () => {
  assert.deepEqual(GRAND_LINE_LANDMARKS.slice(0, 12).map(island => island.id), ['twin-cape', 'little-garden', 'drum', 'alabasta', 'water-seven', 'enies-lobby', 'sabaody', 'marineford', 'wano', 'whole-cake', 'laugh-tale', 'jaya']);
  assert.deepEqual(GRAND_LINE_LANDMARKS.slice(12).map(island => island.id), ['elbaf', 'egghead', 'impel-down', 'amazon-lily', 'dressrosa', 'punk-hazard', 'hachinosu', 'long-ring-long-land']);
  assert.equal(GRAND_LINE_STATIONS.length, 12); assert.equal(GRAND_LINE_HOME_NAMES.length, 12);
  assert.deepEqual(theme.layout.stations, GRAND_LINE_STATIONS);
  assert.deepEqual(theme.layout.obstacles, GRAND_LINE_OBSTACLES);
  assert.deepEqual(theme.layout.wanderPoints, GRAND_LINE_WANDER_POINTS);
  assert.equal(GRAND_LINE_HARBORS.length, 20);
  for (const visitorHarbor of GRAND_LINE_HARBORS.slice(12)) assert.ok(sea.wanderPoints.some(point => gap(point, visitorHarbor) < 0.00001), `${visitorHarbor.id} must be a real route destination`);
  const jaya = GRAND_LINE_LANDMARKS[11]; assert.ok(gap(jaya, GRAND_LINE_SKY_ISLAND) < 1);
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
    assert.ok(Math.hypot(island.x, island.z) + island.radius + 0.1 < GRAND_LINE_MAP_RADIUS, `${island.id} footprint reaches outside the map`);
    // The model is clamped to radius + .10. Ships need bodyRadius + .06,
    // leaving a visible water gap before the tangent docking maneuver.
    assert.ok(gap(island, harbor) - (island.radius + 0.10) - sea.bodyRadius > 0.8);
    for (const other of GRAND_LINE_LANDMARKS.slice(index + 1)) assert.ok(gap(island, other) - island.radius - other.radius >= 4, `${island.id}/${other.id} need an open passage`);
    for (const other of GRAND_LINE_HARBORS.slice(index + 1)) assert.ok(gap(harbor, other) >= sea.bodyRadius * 2 + 0.08);
  }
});

test('every captain can visit the new islands and pass safely around both sea kings and Laboon', () => {
  assert.equal(GRAND_LINE_LABOON_POSITION.x, GRAND_LINE_LANDMARKS[0].x - 3.8);
  assert.equal(GRAND_LINE_LABOON_POSITION.z, GRAND_LINE_LANDMARKS[0].z + 1.5);
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

// Reference relationships are independent of exact coordinates; route tests
// above protect the navigable layout when individual destinations move.
test('Marineford landmarks preserve the reference triangle beside the Red Line', () => {
  const named = (id: string) => GRAND_LINE_LANDMARKS.find(island => island.id === id)!;
  const marineford = named('marineford'), impel = named('impel-down'), enies = named('enies-lobby');
  const sabaody = named('sabaody'), amazon = named('amazon-lily');
  assert.equal(MARY_GEOISE.x, -29);
  assert.ok(MARY_GEOISE.floor > 5, 'The holy land belongs on top of the continental ridge');
  assert.ok(MARY_GEOISE.x > marineford.x && MARY_GEOISE.z < marineford.z);
  assert.ok(marineford.x > impel.x && impel.x > enies.x);
  assert.ok(impel.z < marineford.z && impel.z < enies.z);
  assert.ok(sabaody.x < marineford.x && sabaody.z > marineford.z);
  assert.ok(amazon.x < impel.x && amazon.z <= impel.z);
  assert.ok(enies.z > amazon.z);
  for (const island of [marineford, impel, enies, sabaody, amazon]) {
    assert.ok(island.x + island.radius < MARY_GEOISE.x - 2.1, `${island.id} must be across the mountain ridge`);
  }
  const newWorld = ['wano', 'whole-cake', 'laugh-tale', 'elbaf', 'egghead', 'dressrosa', 'punk-hazard', 'hachinosu'];
  for (const island of GRAND_LINE_LANDMARKS) {
    assert.equal(island.x > MARY_GEOISE.x, newWorld.includes(island.id), `${island.id} must be in its correct sea`);
  }
  assert.ok(GRAND_LINE_SKY_ISLAND.x < MARY_GEOISE.x, 'Skypiea belongs in Paradise');
  assert.ok(pointIsWalkable(MARINEFORD_CURRENT, sea), 'The whirlpool is in open sea');
  for (const island of GRAND_LINE_LANDMARKS) assert.ok(gap(island, MARINEFORD_CURRENT) > island.radius + MARINEFORD_CURRENT.radius);

});


test('Calm Belts block the entire hull and every cross-sea route uses the mountain entrance', () => {
  assert.deepEqual(theme.layout.sailingBounds, GRAND_LINE_SAILING_BOUNDS);
  for (const x of [-76, -45, -29, 0, 35, 60]) for (const sign of [-1, 1]) {
    assert.equal(pointIsWalkable({ x, z: sign * 21 }, sea), false);
    assert.equal(pointIsWalkable({ x, z: sign * 45 }, sea), false);
    assert.equal(segmentIsWalkable({ x, z: 0 }, { x, z: sign * 26 }, sea), false);
  }
  for (const island of GRAND_LINE_LANDMARKS) {
    if (island.id === 'amazon-lily') assert.equal(Math.abs(island.z), GRAND_LINE_CALM_BELT.center);
    else assert.ok(Math.abs(island.z) + island.radius < GRAND_LINE_CALM_BELT.inner, `${island.id} stays between the belts`);
  }
  const west = GRAND_LINE_HARBORS.filter(h => h.x > -29), east = GRAND_LINE_HARBORS.filter(h => h.x < -29);
  for (const from of west) for (const to of east) {
    const route = findResidentPath(from, to, sea); assert.ok(route);
    let previous = from, crossings = 0;
    for (const step of route) {
      if (previous.x !== step.x && (previous.x + 29) * (step.x + 29) <= 0) {
        const t = (-29 - previous.x) / (step.x - previous.x);
        const z = previous.z + t * (step.z - previous.z);
        assert.ok(Math.abs(z) < 2.5, `${from.id} → ${to.id} crosses the mountain entrance`);
        crossings++;
      }
      assert.ok(Math.abs(step.z) + sea.bodyRadius < GRAND_LINE_CALM_BELT.inner);
      previous = { ...previous, ...step };
    }
    assert.ok(crossings > 0);
  }
});
