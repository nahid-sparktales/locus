import test from 'node:test';
import assert from 'node:assert/strict';
import { centerEntries, selectAttentionRequest } from '../src/snailAlertState.ts';
import type { Agent, AttentionRequest, AgentTransfer } from '../src/state.ts';
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

test('attention preserves every real request and avoids a duplicate status alert for the same captain', () => {
  const agents: Agent[] = [
    { id: 'ONE', name: 'Robin', role: 'Research', status: 'needs_attention' },
    { id: 'two', name: 'Franky', role: 'Engineering', status: 'failed', detail: 'Build failed' },
    { id: 'three', name: 'Brook', role: 'Writing', status: 'idle' },
  ];
  const entries = centerEntries(agents, [requests[0], requests[2]], [], 'attention');
  assert.deepEqual(entries.map(entry => entry.target), [{ kind: 'request', id: 'ABC' }, { kind: 'request', id: 'GHI' }, { kind: 'agent', id: 'two' }]);
  assert.equal(entries[0].detail, 'Robin');
  assert.equal(entries[2].detail, 'Build failed');
  assert.equal(entries[2].kind, 'failed');
  assert.equal(entries[2].label, 'Needs a hand', 'An execution error is not labeled a pending approval');
  const resolved = centerEntries(agents.map(agent => ({ ...agent, status: 'idle' })), [], [], 'attention');
  assert.deepEqual(resolved, [], 'Resolved native states clear the attention center');
});

test('activity uses live work states and ordered native deliveries without modifying native snapshots', () => {
  const agents: Agent[] = [
    { id: 'one', name: 'Luffy', role: 'Generalist', status: 'working', detail: 'Making a plan' },
    { id: 'two', name: 'Jinbei', role: 'Navigator', status: 'queued' },
    { id: 'three', name: 'Nami', role: 'Cartographer', status: 'completed' },
    { id: 'four', name: 'Zoro', role: 'Swordsman', status: 'idle' },
  ];
  const transfers: AgentTransfer[] = [
    { id: 'older', fromAgentID: 'ONE', toAgentID: 'two', kind: 'handoff', title: 'Chart the route', occurredAt: 10 },
    { id: 'newer', fromAgentID: 'two', toAgentID: 'three', kind: 'artifact', title: 'Route chart', occurredAt: 20 },
  ];
  const entries = centerEntries(agents, [], transfers, 'activity');
  assert.deepEqual(entries.map(entry => entry.id), ['agent:one', 'agent:two', 'transfer:newer', 'transfer:older', 'agent:three']);
  assert.deepEqual(entries[2].target, { kind: 'transfer', id: 'newer' });
  assert.equal(entries[3].detail, 'Luffy → Jinbei');
  assert.equal(entries[0].detail, 'Making a plan');
  assert.deepEqual(transfers.map(transfer => transfer.id), ['older', 'newer']);
  assert.deepEqual(centerEntries(agents.filter(agent => agent.status === 'idle'), [], [], 'activity'), []);
});
test('outpost activity keeps the same native targets with workspace language', () => {
  const agents: Agent[] = [
    { id: 'one', name: 'Atlas', role: 'Research', status: 'working' },
    { id: 'two', name: 'Nova', role: 'Design', status: 'completed' },
    { id: 'three', name: 'Pip', role: 'Testing', status: 'failed' },
  ];
  const activity = centerEntries(agents, [], [], 'activity', false);
  assert.deepEqual(activity.map(entry => entry.label), ['Working', 'Completed']);
  const attention = centerEntries(agents, [], [], 'attention', false);
  assert.equal(attention[0].detail, 'Open this agent workspace to review what happened.');
  assert.deepEqual(attention[0].target, { kind: 'agent', id: 'three' });
});
