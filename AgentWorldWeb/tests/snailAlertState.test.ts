import test from 'node:test';
import assert from 'node:assert/strict';
import { selectAttentionRequest } from '../src/snailAlertState.ts';
import type { AttentionRequest } from '../src/state.ts';
const requests: AttentionRequest[] = [
  { id: 'ABC', agentID: 'one', kind: 'approval', title: 'Approval' },
  { id: 'DEF', agentID: 'two', kind: 'input', title: 'Question' },
  { id: 'GHI', agentID: 'one', kind: 'input', title: 'Another question' },
];
test('request navigation preserves exact native identity through reorder and resolution', () => {
  assert.equal(selectAttentionRequest([]), undefined);
  assert.equal(selectAttentionRequest(requests)?.id, 'ABC');
  assert.equal(selectAttentionRequest([requests[2], requests[0], requests[1]], 'def')?.id, 'DEF');
  assert.equal(selectAttentionRequest(requests.slice(1), 'ABC')?.id, 'DEF');
  assert.equal(selectAttentionRequest([], 'DEF'), undefined);
});
test('every pending request remains reachable without conflating requests from the same agent', () => {
  let current: string | undefined;
  const visited = new Set<string>();
  for (let n = 0; n < requests.length; n++) { current = selectAttentionRequest(requests, current, n ? 1 : 0)?.id; visited.add(current!); }
  assert.deepEqual([...visited], ['ABC', 'DEF', 'GHI']);
  assert.equal(selectAttentionRequest(requests, 'GHI', 1)?.id, 'ABC');
  assert.equal(selectAttentionRequest(requests, 'ABC', -1)?.id, 'GHI');
  assert.equal(selectAttentionRequest(requests, 'ABC', Infinity)?.id, 'ABC');
  assert.equal(selectAttentionRequest(requests, 'ABC', -100)?.id, 'GHI');
});
