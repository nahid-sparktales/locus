import { Scene } from '@babylonjs/core/scene.js';
import { TransformNode } from '@babylonjs/core/Meshes/transformNode.js';
import { Mesh } from '@babylonjs/core/Meshes/mesh.js';
import { MeshBuilder } from '@babylonjs/core/Meshes/meshBuilder.js';
import { StandardMaterial } from '@babylonjs/core/Materials/standardMaterial.js';
import { Color3 } from '@babylonjs/core/Maths/math.color.js';
import { Quaternion, Vector3 } from '@babylonjs/core/Maths/math.vector.js';
import { cannonArc, MAX_ALLIANCES, MAX_CANNON_PAIRS, MAX_IDLE_ENCOUNTERS, shipAtEncounterBerth, workingShipPairs } from './shipEncounters.ts';
import type { Alliance, EncounterShip, IdleEncounter, WorkingPair } from './shipEncounters.ts';
import { residentSeed } from './residentMotion.ts';

/** Fixed pools: no per-frame particles, geometry allocations, lights, sounds,
 * or host events. Idle play is explicitly ambient; only genuine alliances
 * carry transfer IDs. Nothing here creates work or collaboration records. */
export function createShipEncounterVisuals(scene: Scene, parent: TransformNode) {
  const root = new TransformNode('ship-encounters', scene); root.parent = parent;
  const materials: StandardMaterial[] = [];
  const material = (name: string, color: string, emission = 0) => {
    const value = new StandardMaterial(`encounter-${name}`, scene); value.diffuseColor = Color3.FromHexString(color);
    value.specularColor.setAll(0.12); value.emissiveColor = value.diffuseColor.scale(emission); materials.push(value); return value;
  };
  const oak = material('oak', '#A77347'), rope = material('rope', '#EBD4A3'), brass = material('brass', '#E7B95E', 0.2);
  const iron = material('iron', '#263C4C'), smoke = material('smoke', '#D8E5DF'), foam = material('foam', '#AFE8DB', 0.3);
  const finish = (mesh: Mesh, owner: TransformNode, surface: StandardMaterial) => { mesh.parent = owner; mesh.material = surface; mesh.isPickable = false; return mesh; };
  const bridges = Array.from({ length: MAX_ALLIANCES + MAX_IDLE_ENCOUNTERS }, (_, index) => {
    const owner = new TransformNode(`alliance-gangplank-${index}`, scene); owner.parent = root; owner.setEnabled(false);
    finish(MeshBuilder.CreateBox('retractable-gangplank', { width: 1, height: 0.09, depth: 0.6 }, scene), owner, oak);
    for (let plank = 0; plank < 8; plank++) {
      const edge = finish(MeshBuilder.CreateBox('gangplank-grain', { width: 0.012, height: 0.012, depth: 0.57 }, scene), owner, brass);
      edge.position.set(-0.45 + plank * 0.13, 0.053, 0);
    }
    for (const side of [-1, 1]) {
      const line = finish(MeshBuilder.CreateTube('alliance-mooring-rope', { path: Array.from({ length: 17 }, (_, i) => new Vector3(-0.5 + i / 16, 0.34 - Math.sin(i / 16 * Math.PI) * 0.1, side * 0.31)), radius: 0.027, tessellation: 8 }, scene), owner, rope);
      line.receiveShadows = true;
      for (const end of [-0.46, 0.46]) {
        const post = finish(MeshBuilder.CreateCylinder('gangplank-post', { height: 0.35, diameter: 0.055, tessellation: 8 }, scene), owner, brass);
        post.position.set(end, 0.17, side * 0.31);
      }
    }
    return owner;
  });
  const volleys = Array.from({ length: MAX_CANNON_PAIRS + MAX_IDLE_ENCOUNTERS }, (_, index) => {
    const owner = new TransformNode(`cannon-practice-${index}`, scene); owner.parent = root; owner.setEnabled(false);
    const ball = finish(MeshBuilder.CreateSphere('practice-cannonball', { diameter: 0.23, segments: 12 }, scene), owner, iron);
    const flash = finish(MeshBuilder.CreateSphere('cannon-muzzle-glow', { diameter: 0.48, segments: 12 }, scene), owner, brass);
    const puffs = Array.from({ length: 3 }, () => finish(MeshBuilder.CreateSphere('cannon-smoke', { diameter: 0.42, segments: 10 }, scene), owner, smoke));
    const splash = finish(MeshBuilder.CreateTorus('practice-water-ring', { diameter: 0.7, thickness: 0.065, tessellation: 28 }, scene), owner, foam);
    const droplets = Array.from({ length: 5 }, () => finish(MeshBuilder.CreateSphere('practice-water-droplet', { diameter: 0.12, segments: 8 }, scene), owner, foam));
    const trail = finish(MeshBuilder.CreateCylinder('cannonball-trail', { height: 1, diameterTop: 0.015, diameterBottom: 0.065, tessellation: 8 }, scene), owner, brass);
    return { owner, ball, flash, puffs, splash, droplets, trail, pairID: '', started: 0 };
  });
  let disposed = false;
  return {
    root,
    update(ships: readonly EncounterShip[], alliances: readonly Alliance[], time: number, reducedMotion: boolean, held: ReadonlySet<string> = new Set(), idleEncounters: readonly IdleEncounter[] = []): Map<string, string> {
      const labels = new Map<string, string>();
      if (disposed) return labels;
      root.setEnabled(!reducedMotion);
      for (const bridge of bridges) bridge.setEnabled(false);
      for (const volley of volleys) volley.owner.setEnabled(false);
      if (reducedMotion) return labels;
      const byID = new Map(ships.map(ship => [ship.id.toLowerCase(), ship])), excluded = new Set([...held].map(id => id.toLowerCase()));
      let bridgeIndex = 0;
      const connect = (from: EncounterShip, to: EncounterShip, metadata: Record<string, string>) => {
        const bridge = bridges[bridgeIndex++], a = from.position, b = to.position;
        bridge.setEnabled(true); bridge.position.set((a.x + b.x) / 2, 0.84, (a.z + b.z) / 2);
        bridge.rotation.y = -Math.atan2(b.z - a.z, b.x - a.x);
        bridge.scaling.x = Math.max(0.4, Math.hypot(b.x - a.x, b.z - a.z) - 1.75);
        bridge.metadata = metadata;
      };
      for (const alliance of alliances.slice(0, MAX_ALLIANCES)) {
        const from = byID.get(alliance.fromID), to = byID.get(alliance.toID);
        if (!from || !to || excluded.has(alliance.fromID) || excluded.has(alliance.toID)
          || [from, to].some(ship => ['needs_attention', 'failed', 'queued'].includes(ship.agent.status))) continue;
        excluded.add(alliance.fromID); excluded.add(alliance.toID);
        const alongside = shipAtEncounterBerth(from, alliance.visitorBerth) && shipAtEncounterBerth(to, alliance.hostBerth);
        labels.set(from.id, alongside ? 'Alliance · ships connected' : 'Alliance rendezvous');
        labels.set(to.id, alongside ? 'Alliance · ships connected' : 'Awaiting ally');
        if (!alongside) continue;
        connect(from, to, { transferID: alliance.id, fromAgentID: from.id, toAgentID: to.id });
      }
      const idlePairs: (WorkingPair & { ambientIdle: boolean })[] = [];
      for (const encounter of idleEncounters.slice(0, MAX_IDLE_ENCOUNTERS)) {
        const from = byID.get(encounter.fromID), to = byID.get(encounter.toID);
        if (!from || !to || time >= encounter.expiresAt || from.agent.status !== 'idle' || to.agent.status !== 'idle'
          || excluded.has(encounter.fromID) || excluded.has(encounter.toID)) continue;
        excluded.add(encounter.fromID); excluded.add(encounter.toID);
        const alongside = shipAtEncounterBerth(from, encounter.fromBerth) && shipAtEncounterBerth(to, encounter.toBerth);
        const description = encounter.kind === 'cannon' ? alongside ? 'Play fight · cannon practice' : 'Meeting for a play fight'
          : alongside ? 'Chilling · ships connected' : 'Meeting for a breather';
        labels.set(from.id, description); labels.set(to.id, description);
        if (!alongside) continue;
        if (encounter.kind === 'chill') connect(from, to, { kind: 'ambient-idle-meetup', encounterID: encounter.id, fromAgentID: from.id, toAgentID: to.id });
        else idlePairs.push({ id: encounter.id, from, to, ambientIdle: true });
      }
      const pairs = [...workingShipPairs(ships, excluded).map(pair => ({ ...pair, ambientIdle: false })), ...idlePairs];
      pairs.forEach((pair, index) => {
        const volley = volleys[index];
        if (volley.pairID !== pair.id) { volley.pairID = pair.id; volley.started = time + (residentSeed(pair.id) % 150) / 100; }
        if (!pair.ambientIdle) { labels.set(pair.from.id, 'Cannon practice · working'); labels.set(pair.to.id, 'Cannon practice · working'); }
        const sinceStart = time - volley.started;
        if (sinceStart < 0) return;
        const clock = sinceStart % 13;
        // A broadside and a reply, followed by calm sea between exchanges.
        const returning = clock >= 4.3, shot = returning ? clock - 4.3 : clock;
        if (shot > 3.25) return;
        const from = (returning ? pair.to : pair.from).position, to = (returning ? pair.from : pair.to).position;
        volley.owner.setEnabled(true); volley.owner.metadata = { kind: pair.ambientIdle ? 'ambient-idle-play-fight' : 'ambient-cannon-practice', fromAgentID: pair.from.id, toAgentID: pair.to.id };
        const flight = Math.min(2.3, 1.05 + Math.hypot(from.x - to.x, from.z - to.z) * 0.035), progress = shot / flight;
        const pose = cannonArc(from, to, progress), origin = cannonArc(from, to, 0), landing = cannonArc(from, to, 1);
        volley.ball.setEnabled(progress < 1); volley.ball.position.set(pose.x, pose.y, pose.z);
        volley.flash.setEnabled(shot < 0.16); volley.flash.position.set(origin.x, origin.y, origin.z); volley.flash.scaling.setAll(1 + Math.sin(shot / 0.16 * Math.PI) * 0.5);
        volley.puffs.forEach((puff, puffIndex) => {
          const age = shot - puffIndex * 0.07; puff.setEnabled(age >= 0 && age < 0.95);
          puff.position.set(origin.x + puffIndex * 0.11, origin.y + Math.max(0, age) * 0.6, origin.z + puffIndex * 0.09);
          puff.scaling.setAll(Math.max(0.01, (0.55 + age * 1.4) * Math.min(1, (0.95 - age) * 3)));
        });
        volley.trail.setEnabled(progress > 0.06 && progress < 1);
        if (progress > 0.06 && progress < 1) {
          const behind = cannonArc(from, to, progress - 0.035), start = new Vector3(behind.x, behind.y, behind.z), end = new Vector3(pose.x, pose.y, pose.z);
          volley.trail.position.copyFrom(Vector3.Center(start, end)); volley.trail.scaling.y = Vector3.Distance(start, end);
          const direction = end.subtract(start).normalize();
          volley.trail.rotationQuaternion = Quaternion.RotationAxis(Vector3.Cross(Vector3.Up(), direction).normalize(), Math.acos(Math.max(-1, Math.min(1, direction.y))));
        }
        const splashAge = shot - flight;
        volley.splash.setEnabled(splashAge >= 0 && splashAge < 0.9);
        volley.splash.position.set(landing.x, 0.1, landing.z); volley.splash.scaling.setAll(Math.max(0.01, 0.5 + splashAge * 2.4));
        volley.droplets.forEach((drop, dropIndex) => {
          drop.setEnabled(splashAge >= 0 && splashAge < 0.6);
          const angle = dropIndex / volley.droplets.length * Math.PI * 2, spread = Math.max(0, splashAge) * 0.85;
          drop.position.set(landing.x + Math.sin(angle) * spread, 0.13 + Math.max(0, Math.sin(splashAge / 0.6 * Math.PI)) * 0.65, landing.z + Math.cos(angle) * spread);
          drop.scaling.set(1, 1.5, 1);
        });
      });
      return labels;
    },
    dispose() { if (disposed) return; disposed = true; root.dispose(); for (const material of materials) material.dispose(); },
  };
}
