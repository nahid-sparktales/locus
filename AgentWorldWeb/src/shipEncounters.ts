import type { Agent, AgentTransfer, Point } from './state.ts';
import type { Placement } from './theme.ts';
import { courierRouteLength } from './fleetActivity.ts';
import { findResidentPath, pointIsWalkable, residentSeed, segmentIsWalkable } from './residentMotion.ts';
import type { NavigationMap } from './residentMotion.ts';
import { shipBerthHeading } from './islandBerths.ts';

export type EncounterShip = { id: string; agent: Agent; position: Point; home: Placement; heading: number; walking: boolean; speed: number };
export type Alliance = { id: string; fromID: string; toID: string; visitorBerth: Placement; hostBerth: Placement; expiresAt: number };
export type WorkingPair = { id: string; from: EncounterShip; to: EncounterShip };
export type IdleEncounterKind = 'cannon' | 'chill';
export type IdleEncounter = { id: string; pairID: string; kind: IdleEncounterKind; fromID: string; toID: string; fromBerth: Placement; toBerth: Placement; startedAt: number; expiresAt: number; duration: number; settledAt?: number };
export const MAX_ALLIANCES = 2;
export const MAX_CANNON_PAIRS = 2;
export const MAX_IDLE_ENCOUNTERS = 2;
export const IDLE_ENCOUNTER_RADIUS = 9;
export const IDLE_ENCOUNTER_RESET_RADIUS = 12;
export const IDLE_ENCOUNTER_COOLDOWN = 70;
const key = (id: string) => id.toLowerCase();
const gap = (a: Point, b: Point) => Math.hypot(a.x - b.x, a.z - b.z);
const awaitingCaptain = (ship: EncounterShip) => ['needs_attention', 'failed', 'queued'].includes(ship.agent.status);
const idle = (ship: EncounterShip) => ship.agent.status === 'idle';
const pairKey = (a: string, b: string) => [key(a), key(b)].sort().join(':');
const unit = (id: string, sequence: number, salt: string) => residentSeed(`${id}|${sequence}|${salt}`) / 4294967296;

/** Independent deterministic draws happen once when two idle ships meet.
 * Of eligible meetings 75% interact; of interactions 55% play-fight. */
export function idleEncounterChoice(a: string, b: string, sequence: number): IdleEncounterKind | undefined {
  const id = pairKey(a, b);
  if (unit(id, sequence, 'idle-meeting-chance') >= 0.75) return undefined;
  return unit(id, sequence, 'idle-meeting-kind') < 0.55 ? 'cannon' : 'chill';
}

export function shipAtEncounterBerth(ship: EncounterShip, berth: Placement): boolean {
  return gap(ship.position, berth) < 0.08 && !ship.walking
    && Math.abs(Math.atan2(Math.sin(ship.heading - shipBerthHeading(berth)), Math.cos(ship.heading - shipBerthHeading(berth)))) < 0.06;
}

/** Meet in nearby navigable water rather than commandeering an island home. */
export function findIdleEncounterBerths(from: EncounterShip, to: EncounterShip, ships: readonly EncounterShip[], navigation: NavigationMap, kind: IdleEncounterKind): { fromBerth: Placement; toBerth: Placement } | undefined {
  const distance = gap(from.position, to.position);
  if (distance < 3 || distance > IDLE_ENCOUNTER_RADIUS || !segmentIsWalkable(from.position, to.position, navigation)) return undefined;
  const dx = (to.position.x - from.position.x) / distance, dz = (to.position.z - from.position.z) / distance;
  const clearance = Math.max(kind === 'cannon' ? 5.2 : 3.35, navigation.bodyRadius * 2 + 0.3);
  const center = { x: (from.position.x + to.position.x) / 2, z: (from.position.z + to.position.z) / 2 };
  const rotation = Math.atan2(-dz, dx) - Math.PI / 2;
  // Small shifts along the sailing direction avoid a third hull or its berth.
  for (const offset of [0, 1.4, -1.4]) {
    const fromBerth = { x: center.x - dx * clearance / 2 - dz * offset, z: center.z - dz * clearance / 2 + dx * offset, rotation };
    const toBerth = { x: center.x + dx * clearance / 2 - dz * offset, z: center.z + dz * clearance / 2 + dx * offset, rotation };
    if (![fromBerth, toBerth].every(berth => pointIsWalkable(berth, navigation)) || !segmentIsWalkable(fromBerth, toBerth, navigation)) continue;
    if (ships.some(ship => key(ship.id) !== key(from.id) && key(ship.id) !== key(to.id)
      && [fromBerth, toBerth].some(berth => gap(ship.position, berth) < 3.35 || gap(ship.home, berth) < 3.35))) continue;
    if (findResidentPath(from.position, fromBerth, navigation) === null || findResidentPath(to.position, toBerth, navigation) === null) continue;
    return { fromBerth, toBerth };
  }
  return undefined;
}

/** A real transfer may bring hulls alongside. The berth has the same heading
 * as its host, with room for both hulls and a short retractable gangplank. */
export function findAllianceBerth(visitor: EncounterShip, host: EncounterShip, ships: readonly EncounterShip[], navigation: NavigationMap): Placement | undefined {
  const heading = shipBerthHeading(host.home);
  const clearance = Math.max(3.35, navigation.bodyRadius * 2 + 0.3);
  for (const side of [1, -1]) {
    const berth = { x: host.home.x + Math.cos(heading) * clearance * side, z: host.home.z - Math.sin(heading) * clearance * side, rotation: host.home.rotation };
    if (!pointIsWalkable(berth, navigation) || !segmentIsWalkable(host.home, berth, navigation)) continue;
    if (ships.some(ship => key(ship.id) !== key(visitor.id) && key(ship.id) !== key(host.id) && (gap(ship.position, berth) < clearance || gap(ship.home, berth) < clearance))) continue;
    if (findResidentPath(visitor.position, berth, navigation) === null || findResidentPath(host.position, host.home, navigation) === null) continue;
    return berth;
  }
  return undefined;
}

/** Cannon practice is ambient animation for concurrent work, never a task
 * conflict, combat event, agent message, or evidence of collaboration. */
export function workingShipPairs(ships: readonly EncounterShip[], excluded: ReadonlySet<string> = new Set()): WorkingPair[] {
  const candidates = ships.filter(ship => ship.agent.status === 'working' && !ship.walking && !excluded.has(key(ship.id))).sort((a, b) => key(a.id).localeCompare(key(b.id)));
  const possible: (WorkingPair & { distance: number })[] = [];
  for (let a = 0; a < candidates.length; a++) for (let b = a + 1; b < candidates.length; b++) {
    const distance = gap(candidates[a].position, candidates[b].position);
    if (distance >= 3 && distance <= 42) possible.push({ id: `${key(candidates[a].id)}:${key(candidates[b].id)}`, from: candidates[a], to: candidates[b], distance });
  }
  possible.sort((a, b) => a.distance - b.distance || a.id.localeCompare(b.id));
  const used = new Set<string>(), result: WorkingPair[] = [];
  for (const pair of possible) {
    if (used.has(key(pair.from.id)) || used.has(key(pair.to.id))) continue;
    result.push(pair); used.add(key(pair.from.id)); used.add(key(pair.to.id));
    if (result.length === MAX_CANNON_PAIRS) break;
  }
  return result;
}

/** Water landing stops short of the other hull. No hit/damage state exists. */
export function cannonArc(from: Point, to: Point, progress: number): { x: number; y: number; z: number } {
  const t = Math.max(0, Math.min(1, progress)), length = gap(from, to);
  const dx = length ? (to.x - from.x) / length : 0, dz = length ? (to.z - from.z) / length : 1;
  const start = { x: from.x + dx * 1.05, z: from.z + dz * 1.05 };
  const landing = { x: to.x - dx * 1.65, z: to.z - dz * 1.65 };
  return { x: start.x + (landing.x - start.x) * t, y: 0.95 * (1 - t) + 0.08 * t + 4 * t * (1 - t) * Math.min(6, 1.3 + length * 0.13), z: start.z + (landing.z - start.z) * t };
}

export class ShipEncounterState {
  readonly alliances = new Map<string, Alliance>();
  readonly idleEncounters = new Map<string, IdleEncounter>();
  private seen = new Set<string>();
  private meetings = new Map<string, { fromID: string; toID: string; sequence: number; attempted: boolean }>();
  private idleCooldowns = new Map<string, number>();

  private endIdle(id: string, time: number): void {
    const encounter = this.idleEncounters.get(id);
    if (!encounter) return;
    this.idleEncounters.delete(id);
    for (const shipID of [encounter.fromID, encounter.toID]) this.idleCooldowns.set(shipID, time + IDLE_ENCOUNTER_COOLDOWN);
  }

  updateIdle(ships: readonly EncounterShip[], navigation: NavigationMap, time: number, reducedMotion: boolean, held: ReadonlySet<string> = new Set()): void {
    if (!Number.isFinite(time)) return;
    const byID = new Map(ships.map(ship => [key(ship.id), ship]));
    const unavailable = new Set([...held].map(key));
    for (const alliance of this.alliances.values()) { unavailable.add(alliance.fromID); unavailable.add(alliance.toID); }
    for (const [id, encounter] of this.idleEncounters) {
      const from = byID.get(encounter.fromID), to = byID.get(encounter.toID);
      if (reducedMotion || time >= encounter.expiresAt || !from || !to || !idle(from) || !idle(to) || unavailable.has(encounter.fromID) || unavailable.has(encounter.toID)) {
        this.endIdle(id, time); continue;
      }
      if (encounter.settledAt === undefined && shipAtEncounterBerth(from, encounter.fromBerth) && shipAtEncounterBerth(to, encounter.toBerth)) {
        encounter.settledAt = time;
        encounter.expiresAt = Math.min(encounter.expiresAt, time + encounter.duration);
      }
      unavailable.add(encounter.fromID); unavailable.add(encounter.toID);
    }
    for (const meeting of this.meetings.values()) {
      const from = byID.get(meeting.fromID), to = byID.get(meeting.toID);
      if (!from || !to || gap(from.position, to.position) >= IDLE_ENCOUNTER_RESET_RADIUS) meeting.attempted = false;
    }
    if (reducedMotion || this.idleEncounters.size >= MAX_IDLE_ENCOUNTERS) return;
    const candidates = ships.filter(ship => idle(ship) && !unavailable.has(key(ship.id)) && time >= (this.idleCooldowns.get(key(ship.id)) ?? -Infinity)).sort((a, b) => key(a.id).localeCompare(key(b.id)));
    const pairs: { from: EncounterShip; to: EncounterShip; distance: number; id: string }[] = [];
    for (let a = 0; a < candidates.length; a++) for (let b = a + 1; b < candidates.length; b++) {
      const distance = gap(candidates[a].position, candidates[b].position);
      if (distance >= 3 && distance <= IDLE_ENCOUNTER_RADIUS) pairs.push({ from: candidates[a], to: candidates[b], distance, id: pairKey(candidates[a].id, candidates[b].id) });
    }
    pairs.sort((a, b) => a.distance - b.distance || a.id.localeCompare(b.id));
    for (const pair of pairs) {
      if (this.idleEncounters.size >= MAX_IDLE_ENCOUNTERS) break;
      const fromID = key(pair.from.id), toID = key(pair.to.id);
      if (unavailable.has(fromID) || unavailable.has(toID)) continue;
      const meeting = this.meetings.get(pair.id) ?? { fromID, toID, sequence: 0, attempted: false };
      if (meeting.attempted || !segmentIsWalkable(pair.from.position, pair.to.position, navigation)) continue;
      // Validate both outcomes before drawing once. This also avoids biasing
      // the 55/45 split toward whichever activity happens to fit a narrow gap.
      const chillBerths = findIdleEncounterBerths(pair.from, pair.to, ships, navigation, 'chill');
      const cannonBerths = findIdleEncounterBerths(pair.from, pair.to, ships, navigation, 'cannon');
      if (!chillBerths || !cannonBerths) continue;
      const sequence = meeting.sequence++;
      const choice = idleEncounterChoice(fromID, toID, sequence);
      meeting.attempted = true; this.meetings.set(pair.id, meeting);
      unavailable.add(fromID); unavailable.add(toID);
      for (const id of [fromID, toID]) this.idleCooldowns.set(id, time + IDLE_ENCOUNTER_COOLDOWN);
      if (!choice) continue;
      const berths = choice === 'cannon' ? cannonBerths : chillBerths;
      const duration = (choice === 'cannon' ? 18 : 22) + unit(pair.id, sequence, 'idle-meeting-duration') * 8;
      this.idleEncounters.set(pair.id, { id: `idle:${pair.id}:${sequence}`, pairID: pair.id, kind: choice, fromID, toID, ...berths, startedAt: time, expiresAt: time + 28 + duration, duration });
    }
    while (this.meetings.size > 4096) this.meetings.delete(this.meetings.keys().next().value!);
    while (this.idleCooldowns.size > 4096) this.idleCooldowns.delete(this.idleCooldowns.keys().next().value!);
  }

  addTransfers(transfers: readonly AgentTransfer[], ships: readonly EncounterShip[], navigation: NavigationMap, time: number, wallTime: number, reducedMotion: boolean): void {
    const byID = new Map(ships.map(ship => [key(ship.id), ship]));
    for (const transfer of transfers) {
      const id = key(transfer.id);
      if (this.seen.has(id)) continue;
      this.seen.add(id);
      const age = wallTime - transfer.occurredAt;
      if (reducedMotion || age < -5 || age > 120 || this.alliances.size >= MAX_ALLIANCES) continue;
      const from = byID.get(key(transfer.fromAgentID)), to = byID.get(key(transfer.toAgentID));
      if (!from || !to || from === to || awaitingCaptain(from) || awaitingCaptain(to)) continue;
      if ([...this.alliances.values()].some(alliance => [alliance.fromID, alliance.toID].some(id => id === key(from.id) || id === key(to.id)))) continue;
      const visitorBerth = findAllianceBerth(from, to, ships, navigation);
      if (!visitorBerth) continue;
      for (const [idleID, encounter] of this.idleEncounters) if ([encounter.fromID, encounter.toID].some(id => id === key(from.id) || id === key(to.id))) this.endIdle(idleID, time);
      const path = findResidentPath(from.position, visitorBerth, navigation)!;
      const travel = courierRouteLength([from.position, ...path]) / Math.max(0.1, from.speed);
      // Real activity can last in the view long enough for ordinary ship speed;
      // the ceiling also prevents a blocked rendezvous from persisting forever.
      this.alliances.set(id, { id: transfer.id, fromID: key(from.id), toID: key(to.id), visitorBerth, hostBerth: { ...to.home }, expiresAt: time + Math.min(180, travel + 32) });
    }
    while (this.seen.size > 4096) this.seen.delete(this.seen.values().next().value!);
  }

  destinations(ships: readonly EncounterShip[], time: number, reducedMotion: boolean, held: ReadonlySet<string> = new Set()): Map<string, Placement> {
    const byID = new Map(ships.map(ship => [key(ship.id), ship])), result = new Map<string, Placement>();
    const heldKeys = new Set([...held].map(key));
    for (const [id, alliance] of this.alliances) {
      const from = byID.get(alliance.fromID), to = byID.get(alliance.toID);
      if (reducedMotion || time >= alliance.expiresAt || !from || !to || awaitingCaptain(from) || awaitingCaptain(to) || heldKeys.has(alliance.fromID) || heldKeys.has(alliance.toID)) {
        this.alliances.delete(id); continue;
      }
      result.set(from.id, alliance.visitorBerth); result.set(to.id, alliance.hostBerth);
    }
    for (const [id, encounter] of this.idleEncounters) {
      const from = byID.get(encounter.fromID), to = byID.get(encounter.toID);
      if (reducedMotion || time >= encounter.expiresAt || !from || !to || !idle(from) || !idle(to) || heldKeys.has(encounter.fromID) || heldKeys.has(encounter.toID) || result.has(from.id) || result.has(to.id)) {
        this.endIdle(id, time); continue;
      }
      result.set(from.id, encounter.fromBerth); result.set(to.id, encounter.toBerth);
    }
    return result;
  }

  clear(): void { this.alliances.clear(); this.idleEncounters.clear(); }
}
