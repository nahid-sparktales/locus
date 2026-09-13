import { shipBerthHeading } from './islandBerths.ts';
import type { AgentStatus, Point } from './state.ts';
import { DEFAULT_THEME, PROP_OBSTACLE_RADII } from './theme.ts';
import type { CircleObstacle, Placement, ResidentAssetType, Theme } from './theme.ts';

export const RESIDENT_RADIUS = 0.38;
export const MAX_MOTION_DT = 0.05;
export const STATION_CONSOLE_OFFSET = 1.6;
const EPSILON = 0.00001;
const TAU = Math.PI * 2;
const distance = (a: Point, b: Point): number => Math.hypot(a.x - b.x, a.z - b.z);
const copyPoint = (p: Point): Point => ({ x: p.x, z: p.z });

/** FNV followed by avalanche mixing uses the full stable ID, including UUIDs
 * with repeated digits. Names, roles and roster positions never change a skin. */
export function residentSeed(id: string): number {
  let hash = 2166136261;
  for (const c of id.toLowerCase()) hash = Math.imul(hash ^ c.charCodeAt(0), 16777619);
  hash ^= hash >>> 16; hash = Math.imul(hash, 0x7feb352d);
  hash ^= hash >>> 15; hash = Math.imul(hash, 0x846ca68b);
  return (hash ^ (hash >>> 16)) >>> 0;
}
const randomUnit = (id: string, sequence: number, salt: string): number => residentSeed(`${id}:${sequence}:${salt}`) / 4294967296;

export function residentAssetForID(id: string, available: readonly ResidentAssetType[] = ['resident', 'resident_explorer', 'resident_botanist', 'resident_engineer']): ResidentAssetType {
  const choices = [...new Set(available)].sort();
  // Rendezvous hashing also keeps existing appearances stable when a theme
  // loses an unrelated variant; the winning asset does not depend on order.
  return choices.reduce<ResidentAssetType>((winner, candidate) =>
    residentSeed(`${id}|${candidate}`) > residentSeed(`${id}|${winner}`) ? candidate : winner, choices[0] ?? 'resident');
}

export function stationObstacle(home: Placement): CircleObstacle {
  const heading = home.rotation ?? 0;
  return { x: home.x + Math.sin(heading) * STATION_CONSOLE_OFFSET, z: home.z + Math.cos(heading) * STATION_CONSOLE_OFFSET, radius: 0.95 };
}

/** Three overlapping circles conservatively cover a 2.35 × 1.1 desk
 * without the oversized single circle that would engulf its resident home. */
export function stationObstacles(home: Placement): CircleObstacle[] {
  const center = stationObstacle(home), heading = home.rotation ?? 0;
  return [-0.75, 0, 0.75].map(offset => ({
    x: center.x + Math.cos(heading) * offset,
    z: center.z - Math.sin(heading) * offset,
    radius: 0.72,
  }));
}

type Edge = { to: number; distance: number };
export type NavigationMap = {
  bodyRadius: number;
  /** Traversable map radius after allowing for the resident's body. */
  radius: number;
  /** Obstacles already inflated by the resident's body clearance. */
  obstacles: readonly CircleObstacle[];
  wanderPoints: readonly Point[];
  nodes: readonly Point[];
  edges: readonly (readonly Edge[])[];
};
export type NavigationInput = { radius: number; bodyRadius?: number; obstacles?: readonly CircleObstacle[]; wanderPoints?: readonly Point[] };

function pointClearsCircles(point: Point, circles: readonly CircleObstacle[]): boolean {
  return circles.every(obstacle => {
    const dx = point.x - obstacle.x, dz = point.z - obstacle.z, radius = obstacle.radius - EPSILON;
    return dx * dx + dz * dz >= radius * radius;
  });
}
function segmentClearsCircles(from: Point, to: Point, circles: readonly CircleObstacle[]): boolean {
  const dx = to.x - from.x, dz = to.z - from.z, lengthSquared = dx * dx + dz * dz;
  return circles.every(obstacle => {
    const projection = lengthSquared > 0 ? Math.max(0, Math.min(1, ((obstacle.x - from.x) * dx + (obstacle.z - from.z) * dz) / lengthSquared)) : 0;
    const gapX = from.x + projection * dx - obstacle.x, gapZ = from.z + projection * dz - obstacle.z;
    const radius = obstacle.radius - EPSILON;
    return gapX * gapX + gapZ * gapZ >= radius * radius;
  });
}
export function pointIsWalkable(point: Point, map: NavigationMap): boolean {
  const radius = map.radius + EPSILON;
  return Number.isFinite(point.x) && Number.isFinite(point.z) && point.x * point.x + point.z * point.z <= radius * radius
    && pointClearsCircles(point, map.obstacles);
}
export function segmentIsWalkable(from: Point, to: Point, map: NavigationMap): boolean {
  // A circle is convex, so endpoints inside the map guarantee that the entire
  // segment stays inside it. The segment test already checks both endpoints
  // against obstacles; checking all obstacles another two times is redundant.
  const radius = map.radius + EPSILON;
  return Number.isFinite(from.x) && Number.isFinite(from.z) && Number.isFinite(to.x) && Number.isFinite(to.z)
    && from.x * from.x + from.z * from.z <= radius * radius && to.x * to.x + to.z * to.z <= radius * radius
    && segmentClearsCircles(from, to, map.obstacles);
}

/** Precompute a visibility graph only when the theme/sector changes. Circular
 * samples sit beyond the tangent polygon, so even corner-cutting segments
 * have enough clearance; the per-frame simulation never needs pathfinding. */
export function createNavigation(input: NavigationInput): NavigationMap {
  const bodyRadius = Number.isFinite(input.bodyRadius) ? Math.max(RESIDENT_RADIUS, Math.min(2, input.bodyRadius!)) : RESIDENT_RADIUS;
  const radius = Number.isFinite(input.radius) ? Math.max(1, input.radius - bodyRadius - 0.08) : 13.64;
  const obstacles = (input.obstacles ?? []).filter(item => Number.isFinite(item.x) && Number.isFinite(item.z) && Number.isFinite(item.radius) && item.radius > 0)
    .map(item => ({ ...item, radius: item.radius + bodyRadius + 0.06 }));
  const map: NavigationMap = { radius, bodyRadius, obstacles, wanderPoints: [], nodes: [], edges: [] };
  const proposed = input.wanderPoints ?? Array.from({ length: 16 }, (_, index) => ({ x: Math.sin(index * TAU / 16) * radius * 0.5, z: Math.cos(index * TAU / 16) * radius * 0.5 }));
  map.wanderPoints = proposed.filter(point => pointIsWalkable(point, map)).map(copyPoint);
  const nodes: Point[] = map.wanderPoints.map(copyPoint);
  const samples = 12;
  for (const obstacle of obstacles) {
    const tangentRadius = obstacle.radius / Math.cos(Math.PI / samples) + 0.025;
    for (let index = 0; index < samples; index++) {
      const angle = index * TAU / samples;
      const point = { x: obstacle.x + Math.sin(angle) * tangentRadius, z: obstacle.z + Math.cos(angle) * tangentRadius };
      if (pointIsWalkable(point, map) && !nodes.some(node => distance(node, point) < 0.05)) nodes.push(point);
    }
  }
  const edges: Edge[][] = nodes.map(() => []);
  for (let a = 0; a < nodes.length; a++) {
    for (let b = a + 1; b < nodes.length; b++) {
      if (!segmentIsWalkable(nodes[a], nodes[b], map)) continue;
      const weight = distance(nodes[a], nodes[b]);
      edges[a].push({ to: b, distance: weight }); edges[b].push({ to: a, distance: weight });
    }
  }
  map.nodes = nodes; map.edges = edges;
  return map;
}

export function themeNavigation(theme: Theme, homes: readonly Placement[] = theme.layout.stations): NavigationMap {
  return createNavigation({
    radius: theme.layout.radius,
    bodyRadius: theme.environment === 'ocean' ? 1.35 : RESIDENT_RADIUS,
    obstacles: [
      ...theme.layout.obstacles,
      ...theme.layout.props.map(prop => ({ x: prop.x, z: prop.z, radius: prop.radius ?? PROP_OBSTACLE_RADII[prop.asset] * theme.heights[prop.asset] / DEFAULT_THEME.heights[prop.asset] })),
      ...(theme.environment === 'ocean' ? [] : homes.flatMap(stationObstacles)),
    ],
    wanderPoints: theme.layout.wanderPoints,
  });
}

/** Returns a collision-free path excluding `from`, or null when the goal is
 * disconnected. An unreachable route leaves the resident in place, never
 * projecting or teleporting it through a decoration. */
export function findResidentPath(from: Point, to: Point, map: NavigationMap): Point[] | null {
  if (!pointIsWalkable(from, map) || !pointIsWalkable(to, map)) return null;
  if (distance(from, to) < EPSILON) return [];
  if (segmentIsWalkable(from, to, map)) return [copyPoint(to)];
  const nodes = [...map.nodes, copyPoint(from), copyPoint(to)];
  const start = nodes.length - 2, goal = nodes.length - 1;
  const startEdges: Edge[] = [], goalEdges = new Map<number, number>();
  for (let i = 0; i < map.nodes.length; i++) {
    if (segmentIsWalkable(from, nodes[i], map)) startEdges.push({ to: i, distance: distance(from, nodes[i]) });
    if (segmentIsWalkable(nodes[i], to, map)) goalEdges.set(i, distance(nodes[i], to));
  }
  const cost = new Float64Array(nodes.length).fill(Infinity);
  const previous = new Int32Array(nodes.length).fill(-1);
  const open = new Set<number>([start]), closed = new Set<number>();
  cost[start] = 0;
  while (open.size) {
    let current = -1, bestScore = Infinity;
    for (const candidate of open) {
      const score = cost[candidate] + distance(nodes[candidate], to);
      if (score < bestScore) { current = candidate; bestScore = score; }
    }
    if (current === goal) {
      const path: Point[] = [];
      for (let node = goal; node !== start; node = previous[node]) path.push(copyPoint(nodes[node]));
      return path.reverse();
    }
    open.delete(current); closed.add(current);
    const edges: readonly Edge[] = current === start ? startEdges : map.edges[current];
    const visit = (edge: Edge): void => {
      if (closed.has(edge.to)) return;
      const nextCost = cost[current] + edge.distance;
      if (nextCost >= cost[edge.to]) return;
      cost[edge.to] = nextCost; previous[edge.to] = current; open.add(edge.to);
    };
    edges.forEach(visit);
    const goalDistance = goalEdges.get(current);
    if (goalDistance !== undefined) visit({ to: goal, distance: goalDistance });
  }
  return null;
}

/** Place a newcomer without displacing residents already crossing its home.
 * Samples and graph nodes make the search finite. Home stays the assignment;
 * its static route must be reachable once the passing traffic has cleared. */
export function findResidentArrival(home: Placement, map: NavigationMap, occupied: readonly Point[]): Point | null {
  if (!pointIsWalkable(home, map)) return null;
  const clearance = map.bodyRadius * 2 + 0.08 + 0.05;
  const safe = (point: Point): boolean => pointIsWalkable(point, map)
    && occupied.every(peer => distance(point, peer) >= clearance);
  if (safe(home)) return copyPoint(home);
  const candidates: Point[] = [...map.nodes];
  const radialStep = clearance / 2;
  for (let ring = 1; ring <= 8; ring++) {
    for (let sample = 0; sample < 24; sample++) {
      const angle = sample * TAU / 24;
      candidates.push({ x: home.x + Math.sin(angle) * radialStep * ring, z: home.z + Math.cos(angle) * radialStep * ring });
    }
  }
  candidates.sort((a, b) => distance(home, a) - distance(home, b));
  for (const point of candidates) {
    if (safe(point) && findResidentPath(point, home, map)) return copyPoint(point);
  }
  return null;
}

export type ResidentMotion = {
  id: string;
  x: number;
  z: number;
  heading: number;
  walking: boolean;
  phase: 'at_station' | 'wandering' | 'returning' | 'resting' | 'paused';
  intent: 'wander' | 'station';
  route: readonly Point[];
  routeIndex: number;
  pauseRemaining: number;
  sequence: number;
  speed: number;
  home: Placement;
  trafficCooldown?: number;
  trafficBlockedFor?: number;
};
export type MotionStep = { status: AgentStatus; home: Placement; dt: number; visible?: boolean; paused?: boolean; reducedMotion?: boolean; rosterIDs?: readonly string[] };
export const statusCanWander = (status: AgentStatus): boolean => status === 'idle' || status === 'completed';

/** Spread each round's destinations around the promenade. Roster order has
 * no effect; a roster change only influences the next chosen destination. */
export function residentWanderTargetIndex(id: string, sequence: number, count: number, rosterIDs: readonly string[] = [id]): number {
  if (count < 1) return 0;
  const ids = [...new Set([...rosterIDs, id].map(value => value.toLowerCase()))].sort();
  const slot = Math.floor(ids.indexOf(id.toLowerCase()) * count / ids.length);
  // A shared coprime stride keeps a complete round evenly distributed while
  // each resident's travel/rest duration supplies individual pacing.
  let stride = Math.max(1, Math.floor(count * 0.382));
  const gcd = (a: number, b: number): number => b === 0 ? a : gcd(b, a % b);
  while (gcd(stride, count) !== 1) stride += 1;
  return (slot + sequence * stride) % count;
}

/** Wander along the planted commons' perimeter instead of funneling every
 * long trip onto the shortest path that hugs the garden obstacle. Each leg
 * still uses the same collision graph, including custom theme decorations. */
function findPromenadePath(from: Point, destination: number, map: NavigationMap): Point[] | null {
  const points = map.wanderPoints;
  if (!points.length) return null;
  const ring = points.map((point, index) => ({ point, index })).sort((a, b) => Math.atan2(a.point.x, a.point.z) - Math.atan2(b.point.x, b.point.z));
  const goal = ring.findIndex(item => item.index === destination);
  let start = 0;
  for (let index = 1; index < ring.length; index++) if (distance(from, ring[index].point) < distance(from, ring[start].point)) start = index;
  const build = (direction: number): Point[] | null => {
    const path: Point[] = [];
    let current = from;
    for (let steps = 0, index = start; steps < ring.length; steps++, index = (index + direction + ring.length) % ring.length) {
      const leg = findResidentPath(current, ring[index].point, map);
      if (!leg) return null;
      path.push(...leg); current = ring[index].point;
      if (index === goal) return path;
    }
    return null;
  };
  const clockwise = build(1), counterclockwise = build(-1);
  if (!clockwise || !counterclockwise) return clockwise ?? counterclockwise;
  const length = (path: Point[]): number => path.reduce((sum, point, index) => sum + distance(index ? path[index - 1] : from, point), 0);
  return length(clockwise) <= length(counterclockwise) ? clockwise : counterclockwise;
}

export function createResidentMotion(id: string, home: Placement): ResidentMotion {
  return { id, x: home.x, z: home.z, heading: home.rotation ?? 0, walking: false, phase: 'at_station', intent: 'station', route: [], routeIndex: 0,
    pauseRemaining: 0.6 + randomUnit(id, 0, 'arrival') * 3.5, sequence: 0, speed: 0.65 + randomUnit(id, 0, 'pace') * 0.28, home: { ...home } };
}
function faceToward(heading: number, target: number, dt: number): number {
  const difference = Math.atan2(Math.sin(target - heading), Math.cos(target - heading));
  const turn = Math.max(-4.8 * dt, Math.min(4.8 * dt, difference));
  return Math.atan2(Math.sin(heading + turn), Math.cos(heading + turn));
}

export function stepResidentMotion(previous: ResidentMotion, input: MotionStep, map: NavigationMap): ResidentMotion {
  const state: ResidentMotion = { ...previous, walking: false };
  // Pauses do not consume rest timers or routes; a hidden tab's first large
  // elapsed delta on return is capped rather than caught up in one frame.
  if (input.visible === false || (input.paused && statusCanWander(input.status))) { state.phase = 'paused'; return state; }
  const dt = Number.isFinite(input.dt) ? Math.max(0, Math.min(MAX_MOTION_DT, input.dt)) : 0;
  if (dt === 0) return state;
  state.trafficCooldown = Math.max(0, (state.trafficCooldown ?? 0) - dt);
  if (state.trafficBlockedFor !== undefined) state.trafficBlockedFor += dt;
  const intent = statusCanWander(input.status) && !input.reducedMotion ? 'wander' : 'station';
  const homeChanged = distance(input.home, state.home) > EPSILON || input.home.rotation !== state.home.rotation;
  if (intent !== state.intent || homeChanged) {
    state.intent = intent; state.route = []; state.routeIndex = 0; state.home = { ...input.home };
    state.trafficBlockedFor = undefined;
    if (intent === 'station') state.pauseRemaining = 0;
  }
  const atHome = distance(state, input.home) < EPSILON;
  const parkedHeading = map.bodyRadius > RESIDENT_RADIUS ? shipBerthHeading(input.home) : input.home.rotation ?? 0;
  if (intent === 'station' && atHome) {
    state.phase = 'at_station'; state.route = []; state.routeIndex = 0;
    state.heading = faceToward(state.heading, parkedHeading, dt);
    return state;
  }
  if (state.routeIndex >= state.route.length) {
    state.route = []; state.routeIndex = 0;
    if (intent === 'station') {
      state.phase = 'returning';
      state.route = findResidentPath(state, input.home, map) ?? [];
    } else {
      state.phase = atHome ? 'at_station' : 'resting';
      if (atHome && map.bodyRadius > RESIDENT_RADIUS) state.heading = faceToward(state.heading, parkedHeading, dt * 0.42);
      state.pauseRemaining = Math.max(0, state.pauseRemaining - dt);
      if (state.pauseRemaining > 0) return state;
      const targets = map.wanderPoints;
      const offset = input.rosterIDs
        ? residentWanderTargetIndex(state.id, state.sequence, targets.length, input.rosterIDs)
        : Math.floor(randomUnit(state.id, state.sequence, 'destination') * targets.length);
      state.sequence += 1;
      for (let attempt = 0; attempt < targets.length; attempt++) {
        const destination = (offset + attempt) % targets.length;
        if (distance(state, targets[destination]) < 1.8) continue;
        // Idle ships explore the whole sea from their current location. Only
        // work or reduced motion sends them back to their assigned island.
        const path = map.bodyRadius > RESIDENT_RADIUS
          ? findResidentPath(state, targets[destination], map)
          : findPromenadePath(state, destination, map);
        if (path?.length) { state.route = path; break; }
      }
      if (state.route.length === 0) { state.pauseRemaining = 2; return state; }
    }
  }
  if (!state.route.length) return state;
  state.phase = intent === 'wander' ? 'wandering' : 'returning';
  let remainingDistance = state.speed * dt;
  while (remainingDistance > EPSILON && state.routeIndex < state.route.length) {
    const target = state.route[state.routeIndex];
    const remaining = distance(state, target);
    if (remaining < EPSILON) { state.routeIndex += 1; continue; }
    // Promenade markers describe a corridor, not a single-file position each
    // pedestrian must touch. Passing a marker within one body width lets a
    // sidestepping resident continue without circling a shared point forever.
    // Workstation goals retain exact arrival and their assigned facing.
    if (map.bodyRadius === RESIDENT_RADIUS && remaining < RESIDENT_RADIUS * 2 + 0.2) {
      const nextTarget = state.route[state.routeIndex + 1];
      if ((nextTarget && segmentIsWalkable(state, nextTarget, map)) || (!nextTarget && intent === 'wander')) { state.routeIndex += 1; continue; }
    }
    const course = Math.atan2(target.x - state.x, target.z - state.z);
    state.heading = faceToward(state.heading, course, map.bodyRadius > RESIDENT_RADIUS ? dt * 0.42 : dt);
    if (map.bodyRadius > RESIDENT_RADIUS && Math.abs(Math.atan2(Math.sin(course - state.heading), Math.cos(course - state.heading))) > 0.001) break;
    const moved = Math.min(remaining, remainingDistance);
    const next = { x: state.x + (target.x - state.x) * moved / remaining, z: state.z + (target.z - state.z) * moved / remaining };
    if (!segmentIsWalkable(state, next, map)) { state.route = []; state.routeIndex = 0; state.pauseRemaining = 2; break; }
    state.x = next.x; state.z = next.z; state.walking = true;
    remainingDistance -= moved;
    if (remaining - moved < EPSILON) state.routeIndex += 1;
    if (map.bodyRadius > RESIDENT_RADIUS) break;
  }
  if (state.routeIndex >= state.route.length) {
    state.route = []; state.routeIndex = 0;
    state.pauseRemaining = 2.2 + randomUnit(state.id, state.sequence, 'rest') * 4.8;
    state.trafficBlockedFor = undefined;
    state.phase = intent === 'station' || (map.bodyRadius > RESIDENT_RADIUS && distance(state, input.home) < EPSILON) ? 'at_station' : 'resting';
  }
  return state;
}


/** Keep the island visibility graph and add only the edges needed to route
 * around nearby traffic. This runs on an obstruction, never every frame. */
function navigationWithTraffic(map: NavigationMap, peers: readonly Point[]): NavigationMap {
  const circles = peers.map(point => ({ x: point.x, z: point.z, radius: map.bodyRadius * 2 + 0.08 }));
  const traffic: NavigationMap = { ...map, obstacles: [...map.obstacles, ...circles], nodes: [], edges: [] };
  const originalIndices = new Map<number, number>();
  const nodes: Point[] = [];
  map.nodes.forEach((point, index) => {
    if (pointClearsCircles(point, circles)) { originalIndices.set(index, nodes.length); nodes.push(point); }
  });
  const originalCount = nodes.length;
  const samples = 12;
  for (const circle of circles) {
    const radius = circle.radius / Math.cos(Math.PI / samples) + 0.025;
    for (let index = 0; index < samples; index++) {
      const angle = index * TAU / samples;
      const point = { x: circle.x + Math.sin(angle) * radius, z: circle.z + Math.cos(angle) * radius };
      if (pointIsWalkable(point, traffic) && !nodes.some(node => distance(node, point) < 0.05)) nodes.push(point);
    }
  }
  const edges: Edge[][] = nodes.map(() => []);
  for (const [oldIndex, index] of originalIndices) {
    for (const edge of map.edges[oldIndex]) {
      const to = originalIndices.get(edge.to);
      if (to === undefined || to <= index || !segmentClearsCircles(nodes[index], nodes[to], circles)) continue;
      edges[index].push({ to, distance: edge.distance }); edges[to].push({ to: index, distance: edge.distance });
    }
  }
  for (let index = originalCount; index < nodes.length; index++) {
    for (let to = 0; to < index; to++) {
      if (!segmentIsWalkable(nodes[index], nodes[to], traffic)) continue;
      const weight = distance(nodes[index], nodes[to]);
      edges[index].push({ to, distance: weight }); edges[to].push({ to: index, distance: weight });
    }
  }
  traffic.nodes = nodes; traffic.edges = edges;
  return traffic;
}


/** Resolve fleet traffic and local pedestrian yielding before mesh
 * transforms. It preserves the ordinary travel budget and leaves every
 * adjusted step collision-free. There is no catch-up, pushing, or teleport. */
export function resolveResidentSpacing(
  proposed: readonly ResidentMotion[], previous: readonly ResidentMotion[], map: NavigationMap,
  pausedIDs: ReadonlySet<string> = new Set(),
): ResidentMotion[] {
  const before = new Map(previous.map(state => [state.id, state]));
  const resolved = new Map<string, ResidentMotion>();
  const ordered = [...proposed].sort((a, b) => a.id.localeCompare(b.id));
  const clearance = map.bodyRadius * 2 + 0.08;
  for (const proposal of ordered) {
    let state = proposal;
    const start = before.get(state.id) ?? state;
    const budget = distance(start, state);
    if (!state.walking || budget < EPSILON || pausedIDs.has(state.id)) {
      resolved.set(state.id, state); continue;
    }
    const safe = (candidate: Point): boolean => {
      if (!segmentIsWalkable(start, candidate, map)) return false;
      return ordered.every(peer => {
        if (peer.id === state.id) return true;
        const peerStart = before.get(peer.id) ?? peer;
        const peerEnd = resolved.get(peer.id) ?? peerStart;
        const dx = start.x - peerStart.x, dz = start.z - peerStart.z;
        const vx = candidate.x - start.x - (peerEnd.x - peerStart.x);
        const vz = candidate.z - start.z - (peerEnd.z - peerStart.z);
        const speedSquared = vx * vx + vz * vz;
        const t = speedSquared > EPSILON * EPSILON ? Math.max(0, Math.min(1, -(dx * vx + dz * vz) / speedSquared)) : 0;
        return Math.hypot(dx + vx * t, dz + vz * t) >= clearance - EPSILON;
      });
    };
    if (safe(state)) { resolved.set(state.id, state.trafficBlockedFor === undefined ? state : { ...state, trafficBlockedFor: undefined }); continue; }
    if (map.bodyRadius > RESIDENT_RADIUS) {
      state = { ...state, trafficBlockedFor: state.trafficBlockedFor ?? 0 };
      const goal = state.route.at(-1);
      const occupiedGoal = goal && ordered.some(peer => peer.id !== state.id && distance(goal, resolved.get(peer.id) ?? before.get(peer.id) ?? peer) < clearance);
      // Ambient destinations are optional. A few ships can otherwise wait
      // forever for one another's neighboring waypoint to become free.
      if (state.intent === 'wander' && state.trafficBlockedFor! >= 3 && occupiedGoal) {
        resolved.set(state.id, { ...state, x: start.x, z: start.z, heading: start.heading, walking: false,
          route: [], routeIndex: 0, pauseRemaining: 0, trafficBlockedFor: undefined });
        continue;
      }
    }
    if (map.bodyRadius > RESIDENT_RADIUS && !state.trafficCooldown) {
      // Wide ships cannot always sidestep a parked vessel between shorelines.
      // Replan around the current fleet occasionally, then sail the detour at
      // the ordinary speed; never move another resident out of the way.
      const goal = state.intent === 'station' ? state.home : state.route.at(-1);
      state = { ...state, trafficCooldown: 1.5 };
      if (goal) {
        const nearbyPeers = ordered.filter(peer => peer.id !== state.id)
          .map(peer => resolved.get(peer.id) ?? before.get(peer.id) ?? peer)
          .filter(peer => distance(start, peer) < clearance * 3.5);
        const traffic = navigationWithTraffic(map, nearbyPeers);
        const route = findResidentPath(start, goal, traffic);
        if (route?.length) {
          resolved.set(state.id, { ...state, x: start.x, z: start.z, heading: start.heading, walking: false, route, routeIndex: 0 });
          continue;
        }
      }
    }
    // A vessel waits for its detour or for traffic to clear. Pedestrian-style
    // sidesteps would translate a hull sideways regardless of its bow heading.
    if (map.bodyRadius > RESIDENT_RADIUS) {
      resolved.set(state.id, { ...state, x: start.x, z: start.z, walking: false });
      continue;
    }
    const dx = (state.x - start.x) / budget, dz = (state.z - start.z) / budget;
    let alternate: Point | undefined;
    // Both directions of traffic prefer their own right, so they pass rather
    // than symmetrically stepping into each other's lane.
    for (const angle of [-Math.PI / 3, -Math.PI / 2, Math.PI / 3, Math.PI / 2]) {
      const candidate = { x: start.x + (dx * Math.cos(angle) - dz * Math.sin(angle)) * budget,
        z: start.z + (dx * Math.sin(angle) + dz * Math.cos(angle)) * budget };
      if (safe(candidate)) { alternate = candidate; break; }
    }
    if (alternate) {
      resolved.set(state.id, { ...state, ...alternate,
        heading: faceToward(start.heading, Math.atan2(alternate.x - start.x, alternate.z - start.z), Math.min(MAX_MOTION_DT, budget / state.speed)) });
    } else {
      resolved.set(state.id, { ...state, x: start.x, z: start.z, heading: start.heading, walking: false });
    }
  }
  return proposed.map(state => resolved.get(state.id) ?? state);
}
