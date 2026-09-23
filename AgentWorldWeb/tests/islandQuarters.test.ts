import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { ISLAND_QUARTERS, canOpenIslandQuarters } from '../src/islandQuarters.ts';
import { parseHostMessage, isClickGesture } from '../src/state.ts';
import { GRAND_LINE_LANDMARKS } from '../src/grandLineGeography.ts';

test('only the five shipped destinations open quarters, with a usable background for each', () => {
  assert.deepEqual(Object.keys(ISLAND_QUARTERS), ['elbaf', 'marineford', 'water-seven', 'wano', 'drum']);
  for (const island of GRAND_LINE_LANDMARKS) {
    const supported = Object.hasOwn(ISLAND_QUARTERS, island.id);
    assert.equal(canOpenIslandQuarters(island.id, true, 'grand-line'), supported);
    assert.equal(canOpenIslandQuarters(island.id, false, 'grand-line'), false);
    assert.equal(canOpenIslandQuarters(island.id, true, 'outpost'), false);
  }
  for (const theme of Object.values(ISLAND_QUARTERS)) {
    assert.ok(existsSync(new URL(`../assets/quarters-${theme.artwork}.webp`, import.meta.url)));
  }
  for (const invalid of ['__proto__', 'constructor', '../wano', null, 1]) assert.equal(canOpenIslandQuarters(invalid, true, 'grand-line'), false);
});

test('the shortcut preference accepts booleans and remains backward compatible', () => {
  const snapshot = { version: 1, type: 'snapshot', agents: [], theme: 'grand-line', projectName: '' };
  assert.ok(parseHostMessage(snapshot));
  for (const enabled of [true, false]) assert.ok(parseHostMessage({ ...snapshot, islandQuartersEnabled: enabled }));
  for (const invalid of ['false', 0, 1, null, {}]) assert.equal(parseHostMessage({ ...snapshot, islandQuartersEnabled: invalid }), null);
  assert.equal(isClickGesture({ x: 0, y: 0 }, { x: 20, y: 20 }), false, 'Map drags must not activate an island');
});
