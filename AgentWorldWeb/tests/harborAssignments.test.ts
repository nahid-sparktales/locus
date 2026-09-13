import test from 'node:test';
import assert from 'node:assert/strict';
import { assignHarbors } from '../src/harborAssignments.ts';

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
