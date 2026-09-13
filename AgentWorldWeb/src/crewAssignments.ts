import { residentSeed } from './residentMotion.ts';

const CREW_KINDS = ['panda', 'person', 'robot'] as const;
export type ResidentKind = typeof CREW_KINDS[number];

const isCrewKind = (value: unknown): value is ResidentKind => CREW_KINDS.includes(value as ResidentKind);
const compareIDs = (a: string, b: string): number => a < b ? -1 : a > b ? 1 : 0;

/** Return assignments for the active roster only. The caller may merge these
 * entries into a persistent map to remember crew members across sectors.
 * Existing identities are never changed just to make the counts more even. */
export function assignCrewKinds(ids: readonly string[], previous: ReadonlyMap<string, ResidentKind>): Map<string, ResidentKind> {
  const activeIDs = [...new Set(ids)].sort(compareIDs);
  const result = new Map<string, ResidentKind>();
  const counts: Record<ResidentKind, number> = { panda: 0, person: 0, robot: 0 };
  for (const id of activeIDs) {
    const kind = previous.get(id);
    if (!isCrewKind(kind)) continue;
    result.set(id, kind); counts[kind]++;
  }
  for (const id of activeIDs) {
    if (result.has(id)) continue;
    const leastUsed = Math.min(...CREW_KINDS.map(kind => counts[kind]));
    const candidates = CREW_KINDS.filter(kind => counts[kind] === leastUsed);
    const selected = candidates.reduce((winner, candidate) =>
      residentSeed(`${id}:crew:${candidate}`) > residentSeed(`${id}:crew:${winner}`) ? candidate : winner,
    candidates[0]);
    result.set(id, selected); counts[selected]++;
  }
  return result;
}
