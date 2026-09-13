import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { parseHostMessage } from '../src/state.ts';
import type { AgentTransfer } from '../src/state.ts';
import { unseenRecentTransfers, courierPose, courierRouteLength } from '../src/fleetActivity.ts';
import { createNavigation, findResidentPath, segmentIsWalkable } from '../src/residentMotion.ts';
import { parseTheme } from '../src/theme.ts';

const one = '10000000-0000-4000-8000-000000000001', two = '10000000-0000-4000-8000-000000000002';
const request = { id: '20000000-0000-4000-8000-000000000001', agentID: one, kind: 'approval', title: 'Approval needed' };
const transfer: AgentTransfer = { id: '30000000-0000-4000-8000-000000000001', fromAgentID: one, toAgentID: two, kind: 'handoff', title: 'Research handoff', occurredAt: 1000 };
const snapshot = { version: 1, type: 'snapshot', theme: 'grand-line', projectName: 'Test', agents: [one, two].map(id => ({ id, name: id, role: 'Agent', status: 'idle' })) };

test('native attention and transfer IDs are bounded and must resolve to actual snapshot agents', () => {
  assert.ok(parseHostMessage({ ...snapshot, attentionRequests: [request], transfers: [transfer] }));
  assert.ok(parseHostMessage({ ...snapshot, attentionRequests: [{ ...request, kind: 'input' }], transfers: [{ ...transfer, kind: 'artifact' }] }));
  for (const bad of [null, {}, [request, request], [{ ...request, id: 'not-an-id' }], [{ ...request, agentID: 'missing' }], [{ ...request, kind: 'failed' }], [{ ...request, title: 'x'.repeat(257) }], Array(257).fill(request)]) {
    assert.equal(parseHostMessage({ ...snapshot, attentionRequests: bad }), null);
  }
  for (const bad of [null, {}, [transfer, transfer], [{ ...transfer, id: 'not-an-id' }], [{ ...transfer, toAgentID: one }], [{ ...transfer, fromAgentID: 'missing' }], [{ ...transfer, kind: 'chat' }], [{ ...transfer, title: 'x'.repeat(257) }], [{ ...transfer, occurredAt: NaN }], [{ ...transfer, occurredAt: Infinity }], [{ ...transfer, occurredAt: -1 }], Array(129).fill(transfer)]) {
    assert.equal(parseHostMessage({ ...snapshot, transfers: bad }), null);
  }
  // A generic error/attention status is not a request to approve anything.
  const statusOnly = parseHostMessage({ ...snapshot, agents: snapshot.agents.map(agent => ({ ...agent, status: 'needs_attention' })) });
  assert.ok(statusOnly?.type === 'snapshot' && statusOnly.attentionRequests === undefined);
});

test('couriers animate a recent event once and never replay duplicate snapshots or old history', () => {
  const seen = new Set<string>();
  assert.deepEqual(unseenRecentTransfers([transfer], seen, 1001), [transfer]);
  assert.deepEqual(unseenRecentTransfers([transfer], seen, 1002), []);
  assert.deepEqual(unseenRecentTransfers([{ ...transfer, id: transfer.id.toUpperCase() }], seen, 1003), []);
  const old = { ...transfer, id: '30000000-0000-4000-8000-000000000002', occurredAt: 800 };
  const future = { ...transfer, id: '30000000-0000-4000-8000-000000000003', occurredAt: 1020 };
  assert.deepEqual(unseenRecentTransfers([old, future], seen, 1001), []);
  assert.deepEqual(unseenRecentTransfers([old, future], seen, 1021), [], 'Previously observed snapshots do not become new events later');
});

test('courier poses follow the water route without mutating their home island points', () => {
  const route = [{ x: 0, z: 0 }, { x: 0, z: 3 }, { x: 4, z: 3 }];
  const original = structuredClone(route);
  assert.equal(courierRouteLength(route), 7);
  assert.deepEqual(courierPose(route, 0), { x: 0, z: 0, heading: 0 });
  assert.deepEqual(courierPose(route, 1), { x: 4, z: 3, heading: Math.PI / 2 });
  assert.deepEqual(courierPose(route, 0.5), { x: 0.5, z: 3, heading: Math.PI / 2 });
  assert.deepEqual(courierPose(route, 3), courierPose(route, 1));
  assert.deepEqual(route, original);
});

test('couriers can travel between every pair of home islands without crossing the land obstacles', () => {
  const theme = parseTheme(JSON.parse(readFileSync(new URL('../../plugins/agent-world/ui/themes/grand-line/theme.json', import.meta.url), 'utf8')));
  const map = createNavigation({ radius: theme.layout.radius, bodyRadius: 0.48, obstacles: theme.layout.obstacles });
  for (const from of theme.layout.stations) for (const to of theme.layout.stations) {
    if (from === to) continue;
    const path = findResidentPath(from, to, map);
    assert.ok(path?.length, `Disconnected courier ports: ${JSON.stringify({ from, to })}`);
    const route = [from, ...path];
    for (let index = 1; index < route.length; index++) assert.ok(segmentIsWalkable(route[index - 1], route[index], map));
  }
});
