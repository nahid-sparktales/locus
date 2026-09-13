import test from 'node:test';
import assert from 'node:assert/strict';
import { assignCrewKinds } from '../src/crewAssignments.ts';
import type { ResidentKind } from '../src/crewAssignments.ts';

const ids = Array.from({ length: 12 }, (_, index) => `crew-${String(index).padStart(2, '0')}`);
const counts = (assignments: ReadonlyMap<string, ResidentKind>): Record<ResidentKind, number> => {
  const result = { panda: 0, person: 0, robot: 0 };
  for (const kind of assignments.values()) result[kind]++;
  return result;
};

test('a fresh mixed crew is balanced for a full sector and includes every kind in a three-person roster', () => {
  assert.deepEqual(counts(assignCrewKinds(ids, new Map())), { panda: 4, person: 4, robot: 4 });
  assert.deepEqual(counts(assignCrewKinds(ids.slice(0, 3), new Map())), { panda: 1, person: 1, robot: 1 });
  for (let size = 1; size <= 12; size++) {
    const totals = Object.values(counts(assignCrewKinds(ids.slice(0, size), new Map())));
    assert.ok(Math.max(...totals) - Math.min(...totals) <= 1);
  }
});

test('initial mixed-crew identities and retained assignments do not depend on roster ordering', () => {
  const initial = assignCrewKinds(ids, new Map());
  const shuffled = [ids[8], ids[1], ids[10], ids[3], ids[0], ids[5], ids[11], ids[4], ids[7], ids[2], ids[9], ids[6]];
  assert.deepEqual(assignCrewKinds(shuffled, new Map()), initial);
  assert.deepEqual(assignCrewKinds([...ids].reverse(), initial), initial);
});

test('removing or adding profiles preserves every surviving crew identity even when the roster is unbalanced', () => {
  const previous = new Map<string, ResidentKind>([
    ['old-panda-a', 'panda'], ['old-panda-b', 'panda'], ['old-panda-c', 'panda'], ['old-person', 'person'], ['old-robot', 'robot'],
  ]);
  const survivors = ['old-panda-c', 'old-panda-a', 'old-panda-b'];
  const reduced = assignCrewKinds(survivors, previous);
  assert.deepEqual(counts(reduced), { panda: 3, person: 0, robot: 0 }, 'Existing residents must not change species to rebalance');
  const expanded = assignCrewKinds([...survivors, 'new-a', 'new-b'], previous);
  for (const id of survivors) assert.equal(expanded.get(id), previous.get(id));
  assert.notEqual(expanded.get('new-a'), 'panda');
  assert.notEqual(expanded.get('new-b'), 'panda');
  assert.notEqual(expanded.get('new-a'), expanded.get('new-b'), 'New arrivals should fill both underrepresented kinds');
  assert.equal(expanded.has('old-person'), false, 'The returned map contains active IDs only');
  assert.equal(previous.size, 5, 'Assignment must not mutate the caller’s persistent history');
});

test('inactive history does not skew a new sector and returning profiles retain their saved kind', () => {
  const history = new Map<string, ResidentKind>(Array.from({ length: 30 }, (_, index) => [`inactive-${index}`, 'panda']));
  const fresh = assignCrewKinds(ids.slice(0, 3), history);
  assert.deepEqual(counts(fresh), { panda: 1, person: 1, robot: 1 });
  for (const entry of fresh) history.set(...entry);
  history.set('returning-robot', 'robot');
  const returning = assignCrewKinds(['returning-robot', 'newcomer-a', 'newcomer-b'], history);
  assert.equal(returning.get('returning-robot'), 'robot');
  assert.deepEqual(counts(returning), { panda: 1, person: 1, robot: 1 });
});

test('duplicate IDs are handled deterministically and malformed saved kinds are replaced', () => {
  assert.equal(assignCrewKinds([], new Map()).size, 0);
  const duplicates = assignCrewKinds(['a', 'b', 'a', 'c', 'b'], new Map());
  assert.equal(duplicates.size, 3);
  assert.deepEqual(counts(duplicates), { panda: 1, person: 1, robot: 1 });
  const malformed = new Map<string, ResidentKind>([['a', 'dragon' as ResidentKind], ['b', undefined as unknown as ResidentKind]]);
  const repaired = assignCrewKinds(['a', 'b', 'c'], malformed);
  assert.deepEqual(counts(repaired), { panda: 1, person: 1, robot: 1 });
  assert.ok([...repaired.values()].every(kind => ['panda', 'person', 'robot'].includes(kind)));
});
