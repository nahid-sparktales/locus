import type { QuartersIslandID } from './islandQuarters.ts';
import { SHIP_ASSET_TYPES } from './theme.ts';
import type { ShipAssetType } from './theme.ts';
import { isSailingArea } from './sailingArea.ts';
import type { SailingArea } from './sailingArea.ts';

export const AGENT_STATUSES = ['idle', 'working', 'needs_attention', 'completed', 'failed', 'queued'] as const;
export type AgentStatus = typeof AGENT_STATUSES[number];
export type Agent = { id: string; name: string; role: string; status: AgentStatus; detail?: string };
export const RESIDENT_STYLES = ['mixed', 'explorers', 'pandas'] as const;
export type ResidentStyle = typeof RESIDENT_STYLES[number];
export const isResidentStyle = (value: unknown): value is ResidentStyle => RESIDENT_STYLES.includes(value as ResidentStyle);
export type AttentionRequest = { id: string; agentID: string; kind: 'approval' | 'input'; title: string };
export type AgentTransfer = { id: string; fromAgentID: string; toAgentID: string; kind: 'handoff' | 'artifact'; title: string; occurredAt: number };
export type ShipStyles = Record<string, ShipAssetType>;
export type Snapshot = { version: 1; type: 'snapshot'; agents: Agent[]; selectedAgentID?: string; theme: string; projectName: string; residentStyle?: ResidentStyle; sailingArea?: SailingArea; shipStyles?: ShipStyles; canCreateAgent?: boolean; activityCenterRequest?: number; focusRequest?: number; nativeChrome?: boolean; islandQuartersEnabled?: boolean; attentionRequests?: AttentionRequest[]; transfers?: AgentTransfer[] };
export type Visibility = { version: 1; type: 'visibility'; visible: boolean };
export type HostMessage = Snapshot | Visibility;
export type WorldMessage = { version: 1; type: 'openIslandQuarters'; islandID: QuartersIslandID } | { version: 1; type: 'openActivityCenter' } | { version: 1; type: 'clearSelection' } | { version: 1; type: 'setShipStyle'; agentID: string; shipStyle: ShipAssetType | null } | { version: 1; type: 'residentPlacements'; placements: { agentID: string; ship: string; home: string }[] } | { version: 1; type: 'openAttention'; requestID: string } | { version: 1; type: 'openTransfer'; transferID: string } | { version: 1; type: 'openSharedChat' } | { version: 1; type: 'openAgentControls'; agentID?: string } | { version: 1; type: 'createAgent' } | { version: 1; type: 'ready' } | { version: 1; type: 'selectAgent'; agentID: string } | { version: 1; type: 'preferences'; preferences: { theme: string } | { residentStyle: ResidentStyle } | { sailingArea: SailingArea } | { islandQuartersEnabled: boolean } };
export type Point = { x: number; z: number };
export type ScreenPoint = { x: number; y: number };
export type ScreenRect = { left: number; top: number; right: number; bottom: number };
export const SECTOR_SIZE = 12;
export const STATUS_META: Record<AgentStatus, { label: string; color: string }> = {
  idle: { label: 'Available', color: '#83b9bb' },
  working: { label: 'Working', color: '#72e7cd' },
  needs_attention: { label: 'Needs you', color: '#f9c783' },
  completed: { label: 'Completed', color: '#a4cfff' },
  failed: { label: 'Needs attention', color: '#f79292' },
  queued: { label: 'Queued', color: '#c9b9f4' },
};

function record(value: unknown): value is Record<string, unknown> { return !!value && typeof value === 'object' && !Array.isArray(value); }
function boundedString(value: unknown, maximum: number): value is string { return typeof value === 'string' && value.length <= maximum; }
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const safeThemeID = (value: unknown): value is string => typeof value === 'string' && /^[a-z0-9][a-z0-9-]{0,63}$/.test(value);

/** Normalize UUID casing while rejecting stale identities and unshipped model choices. */
export function parseShipStyles(value: unknown, agentIDs: readonly string[]): ShipStyles | null {
  if (!record(value)) return null;
  const entries = Object.entries(value);
  if (entries.length > 4096) return null;
  const known = new Map(agentIDs.map(id => [id.toLowerCase(), id]));
  const seen = new Set<string>();
  const normalized: ShipStyles = {};
  for (const [id, style] of entries) {
    const canonical = known.get(id.toLowerCase());
    if (!uuid.test(id) || !canonical || seen.has(id.toLowerCase()) || !(SHIP_ASSET_TYPES as readonly unknown[]).includes(style)) return null;
    seen.add(id.toLowerCase()); normalized[canonical] = style as ShipAssetType;
  }
  return normalized;
}

/** Reject the whole message on malformed agents so a partial update cannot misroute selection. */
export function parseHostMessage(value: unknown): HostMessage | null {
  if (!record(value) || value.version !== 1) return null;
  if (value.type === 'visibility') return typeof value.visible === 'boolean' ? { version: 1, type: 'visibility', visible: value.visible } : null;
  if (value.type !== 'snapshot' || !Array.isArray(value.agents) || value.agents.length > 4096 || !safeThemeID(value.theme) || !boundedString(value.projectName, 1024)) return null;
  if (value.residentStyle !== undefined && !isResidentStyle(value.residentStyle)) return null;
  if (value.sailingArea !== undefined && !isSailingArea(value.sailingArea)) return null;
  if (value.canCreateAgent !== undefined && typeof value.canCreateAgent !== 'boolean') return null;
  if (value.activityCenterRequest !== undefined && (typeof value.activityCenterRequest !== 'number' || !Number.isSafeInteger(value.activityCenterRequest) || value.activityCenterRequest < 0)) return null;
  if (value.islandQuartersEnabled !== undefined && typeof value.islandQuartersEnabled !== 'boolean') return null;
  if (value.nativeChrome !== undefined && typeof value.nativeChrome !== 'boolean') return null;
  const ids = new Set<string>();
  for (const item of value.agents) {
    if (!record(item) || typeof item.id !== 'string' || !uuid.test(item.id) || ids.has(item.id.toLowerCase()) || !boundedString(item.name, 256) || !boundedString(item.role, 4096) || !AGENT_STATUSES.includes(item.status as AgentStatus) || (item.detail !== undefined && !boundedString(item.detail, 16384))) return null;
    ids.add(item.id.toLowerCase());
  }
  if (value.selectedAgentID !== undefined && (typeof value.selectedAgentID !== 'string' || !ids.has(value.selectedAgentID.toLowerCase()))) return null;
  if (value.focusRequest !== undefined && (typeof value.focusRequest !== 'number' || !Number.isSafeInteger(value.focusRequest) || value.focusRequest < 0)) return null;
  const shipStyles = value.shipStyles === undefined ? undefined : parseShipStyles(value.shipStyles, (value.agents as Agent[]).map(agent => agent.id));
  if (shipStyles === null) return null;
  const activityIDs = new Set<string>();
  if (value.attentionRequests !== undefined) {
    if (!Array.isArray(value.attentionRequests) || value.attentionRequests.length > 256) return null;
    for (const item of value.attentionRequests) {
      if (!record(item) || typeof item.id !== 'string' || !uuid.test(item.id) || activityIDs.has(item.id.toLowerCase()) || typeof item.agentID !== 'string' || !ids.has(item.agentID.toLowerCase()) || !['approval', 'input'].includes(item.kind as string) || !boundedString(item.title, 256)) return null;
      activityIDs.add(item.id.toLowerCase());
    }
  }
  activityIDs.clear();
  if (value.transfers !== undefined) {
    if (!Array.isArray(value.transfers) || value.transfers.length > 128) return null;
    for (const item of value.transfers) {
      if (!record(item) || typeof item.id !== 'string' || !uuid.test(item.id) || activityIDs.has(item.id.toLowerCase()) || typeof item.fromAgentID !== 'string' || !ids.has(item.fromAgentID.toLowerCase()) || typeof item.toAgentID !== 'string' || !ids.has(item.toAgentID.toLowerCase()) || item.fromAgentID.toLowerCase() === item.toAgentID.toLowerCase() || !['handoff', 'artifact'].includes(item.kind as string) || !boundedString(item.title, 256) || typeof item.occurredAt !== 'number' || !Number.isFinite(item.occurredAt) || item.occurredAt < 0 || item.occurredAt > 253402300799) return null;
      activityIDs.add(item.id.toLowerCase());
    }
  }
  return (shipStyles === undefined ? value : { ...value, shipStyles }) as Snapshot;
}

export function agentSector(agents: readonly Agent[], agentID: string, size = SECTOR_SIZE): number {
  const index = agents.findIndex(agent => agent.id === agentID);
  return index < 0 ? 0 : Math.floor(index / size);
}
export function clampSector(sector: number, agentCount: number, size = SECTOR_SIZE): number { return Math.max(0, Math.min(Math.floor(sector), Math.max(0, Math.ceil(agentCount / size) - 1))); }
export function sectorAgents(agents: readonly Agent[], sector: number, size = SECTOR_SIZE): Agent[] { const index = clampSector(sector, agents.length, size) * size; return agents.slice(index, index + size); }
export function searchAgents(agents: readonly Agent[], query: string): Agent[] {
  const q = query.trim().toLocaleLowerCase();
  return agents.filter(agent => !q || `${agent.name} ${agent.role}`.toLocaleLowerCase().includes(q));
}
export function residentPosition(slot: number, count: number): Point {
  const angle = count === 1 ? 0 : -2.32 + (Math.max(0, Math.min(slot, count - 1)) / (count - 1)) * 4.64;
  return { x: Math.sin(angle) * 9.8, z: -Math.cos(angle) * 9.8 };
}
export function isClickGesture(start: ScreenPoint, end: ScreenPoint): boolean {
  return Math.hypot(end.x - start.x, end.y - start.y) <= 6;
}

/** Test the whole label, not only its projected anchor, against HUD and viewport edges. */
export function labelIsUnobscured(label: ScreenRect, width: number, height: number, overlays: readonly ScreenRect[], margin = 14): boolean {
  if (label.left < margin || label.top < margin || label.right > width - margin || label.bottom > height - margin) return false;
  return overlays.every(overlay => label.right + 5 <= overlay.left || label.left - 5 >= overlay.right || label.bottom + 5 <= overlay.top || label.top - 5 >= overlay.bottom);
}
