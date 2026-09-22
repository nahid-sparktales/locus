import type { AgentStatus, Point } from './state.ts';
import type { Placement } from './theme.ts';

export type HarborShip = { id: string; status: AgentStatus; position: Point };
export const reservesWorkHarbor = (status: AgentStatus): boolean => ['working', 'queued', 'needs_attention', 'failed'].includes(status);

/** Reserve the shortest reachable voyage when work begins. Existing work keeps
 * its berth through queue/approval changes; completion releases it immediately.
 * Ties use stable IDs, never the incoming roster order. */
export function reserveNearestHarbors(
  ships: readonly HarborShip[], previous: ReadonlyMap<string, number>, harbors: readonly Placement[],
  routeDistance: (from: Point, to: Point) => number, clearance: number,
): Map<string, number> {
  const reserved = new Map<string, number>();
  const used = new Set<number>();
  const workers = ships.filter(ship => reservesWorkHarbor(ship.status)).sort((a, b) => a.id.localeCompare(b.id));
  for (const ship of workers) {
    const slot = previous.get(ship.id);
    if (slot !== undefined && Number.isInteger(slot) && slot >= 0 && slot < harbors.length && !used.has(slot)) {
      reserved.set(ship.id, slot); used.add(slot);
    }
  }
  for (const ship of workers) {
    if (reserved.has(ship.id)) continue;
    let nearest: number | undefined, distance = Infinity;
    for (const [slot, harbor] of harbors.entries()) {
      if (used.has(slot) || ships.some(other => other.id !== ship.id && Math.hypot(other.position.x - harbor.x, other.position.z - harbor.z) < clearance)) continue;
      const voyage = routeDistance(ship.position, harbor);
      if (Number.isFinite(voyage) && voyage >= 0 && voyage < distance) { nearest = slot; distance = voyage; }
    }
    if (nearest !== undefined) { reserved.set(ship.id, nearest); used.add(nearest); }
  }
  return reserved;
}

/** Keep each visible agent at its own island when profiles are added or removed.
 * Hidden sectors can reuse the same islands; retained visible assignments win. */
export function assignHarbors(ids: readonly string[], previous: ReadonlyMap<string, number>, capacity: number): Map<string, number> {
  const assigned = new Map<string, number>();
  const used = new Set<number>();
  const sorted = [...new Set(ids)].sort();
  for (const id of sorted) {
    const slot = previous.get(id);
    if (slot !== undefined && Number.isInteger(slot) && slot >= 0 && slot < capacity && !used.has(slot)) {
      assigned.set(id, slot);
      used.add(slot);
    }
  }
  for (const id of sorted) {
    if (assigned.has(id)) continue;
    for (let slot = 0; slot < capacity; slot++) {
      if (used.has(slot)) continue;
      assigned.set(id, slot);
      used.add(slot);
      break;
    }
  }
  return assigned;
}
