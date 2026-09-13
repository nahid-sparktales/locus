import type { AgentTransfer, Point } from './state.ts';
/** A snapshot is a view of existing activity, never an instruction to replay it. */
export function unseenRecentTransfers(transfers: readonly AgentTransfer[], seen: Set<string>, now: number): AgentTransfer[] {
  const fresh: AgentTransfer[] = [];
  for (const transfer of transfers) {
    const key = transfer.id.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    const age = now - transfer.occurredAt;
    if (age >= -5 && age <= 120) fresh.push(transfer);
  }
  // Native sends only its bounded recent activity window. Older IDs cannot be
  // eligible for animation again after this conservative deduplication window.
  while (seen.size > 4096) seen.delete(seen.values().next().value!);
  return fresh;
}

export function courierRouteLength(route: readonly Point[]): number {
  return route.slice(1).reduce((length, point, index) => length + Math.hypot(point.x - route[index].x, point.z - route[index].z), 0);
}

/** Follow the water navigation route at constant speed, including curved coasts. */
export function courierPose(route: readonly Point[], progress: number): Point & { heading: number } {
  if (!route.length) return { x: 0, z: 0, heading: 0 };
  let remaining = Math.max(0, Math.min(1, progress)) * courierRouteLength(route);
  for (let index = 1; index < route.length; index++) {
    const from = route[index - 1], to = route[index];
    const length = Math.hypot(to.x - from.x, to.z - from.z);
    if (length < 0.00001) continue;
    if (remaining <= length || index === route.length - 1) {
      const fraction = Math.min(1, remaining / length);
      return { x: from.x + (to.x - from.x) * fraction, z: from.z + (to.z - from.z) * fraction, heading: Math.atan2(to.x - from.x, to.z - from.z) };
    }
    remaining -= length;
  }
  return { ...route[route.length - 1], heading: 0 };
}
