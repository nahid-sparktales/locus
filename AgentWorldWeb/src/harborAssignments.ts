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
