import type { Agent, AttentionRequest, AgentTransfer, AgentStatus } from './state.ts';

export type ActivityTab = 'attention' | 'activity';
export type CenterEntry = {
  id: string;
  target: { kind: 'request' | 'transfer' | 'agent'; id: string };
  kind: 'approval' | 'input' | 'handoff' | 'artifact' | AgentStatus;
  title: string;
  detail: string;
  label: string;
  occurredAt?: number;
};

/** The center is a view of native events and statuses, never an invented task history. */
export function centerEntries(agents: readonly Agent[], requests: readonly AttentionRequest[], transfers: readonly AgentTransfer[], tab: ActivityTab, ocean = true): CenterEntry[] {
  const nameFor = (id: string): string => agents.find(agent => agent.id.toLowerCase() === id.toLowerCase())?.name ?? 'Agent';
  const workspace = ocean ? 'captain’s quarters' : 'agent workspace';
  if (tab === 'attention') {
    const requestAgents = new Set(requests.map(request => request.agentID.toLowerCase()));
    return [
      ...requests.map(request => ({ id: `request:${request.id}`, target: { kind: 'request' as const, id: request.id }, kind: request.kind, title: request.title, detail: nameFor(request.agentID), label: request.kind === 'approval' ? 'Approval needed' : 'Input needed' })),
      ...agents.filter(agent => (agent.status === 'needs_attention' || agent.status === 'failed') && !requestAgents.has(agent.id.toLowerCase())).map(agent => ({ id: `agent:${agent.id}`, target: { kind: 'agent' as const, id: agent.id }, kind: agent.status, title: agent.name, detail: agent.detail || `Open this ${workspace} to ${agent.status === 'failed' ? 'review what happened' : 'check their status'}.`, label: agent.status === 'failed' ? 'Needs a hand' : 'Needs attention' })),
    ];
  }
  return [
    ...agents.filter(agent => agent.status === 'working' || agent.status === 'queued').map(agent => ({ id: `agent:${agent.id}`, target: { kind: 'agent' as const, id: agent.id }, kind: agent.status, title: agent.name, detail: agent.detail || agent.role || 'Agent', label: agent.status === 'working' ? ocean ? 'Under way' : 'Working' : ocean ? 'Ready to sail' : 'Queued' })),
    ...[...transfers].sort((a, b) => b.occurredAt - a.occurredAt).map(transfer => ({ id: `transfer:${transfer.id}`, target: { kind: 'transfer' as const, id: transfer.id }, kind: transfer.kind, title: transfer.title, detail: `${nameFor(transfer.fromAgentID)} → ${nameFor(transfer.toAgentID)}`, label: transfer.kind === 'artifact' ? 'Artifact delivered' : ocean ? 'Crew handoff' : 'Agent handoff', occurredAt: transfer.occurredAt })),
    ...agents.filter(agent => agent.status === 'completed').map(agent => ({ id: `agent:${agent.id}`, target: { kind: 'agent' as const, id: agent.id }, kind: agent.status, title: agent.name, detail: agent.detail || agent.role || 'Agent', label: ocean ? 'Voyage complete' : 'Completed' })),
  ];
}

/** Keep the chosen native request across reorders; never manufacture an alert from status. */
export function selectAttentionRequest(requests: readonly AttentionRequest[], currentID?: string, offset = 0): AttentionRequest | undefined {
  if (!requests.length) return undefined;
  const retained = currentID ? requests.findIndex(request => request.id.toLowerCase() === currentID.toLowerCase()) : -1;
  const start = retained < 0 ? 0 : retained;
  const step = Number.isFinite(offset) ? Math.trunc(offset) : 0;
  return requests[((start + step) % requests.length + requests.length) % requests.length];
}
