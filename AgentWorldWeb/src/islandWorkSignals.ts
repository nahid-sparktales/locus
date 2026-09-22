import { Scene } from '@babylonjs/core/scene.js';
import { TransformNode } from '@babylonjs/core/Meshes/transformNode.js';
import { MeshBuilder } from '@babylonjs/core/Meshes/meshBuilder.js';
import { StandardMaterial } from '@babylonjs/core/Materials/standardMaterial.js';
import { Color3 } from '@babylonjs/core/Maths/math.color.js';
import { islandCrewActivity } from './islandBerths.ts';
import type { AgentStatus, Point } from './state.ts';
import type { Placement } from './theme.ts';
import type { ResidentMotion } from './residentMotion.ts';

export const MAX_WORK_ISLANDS = 14;
export type WorkIsland = Point & { radius: number; marker?: Point & { y: number } };
export type IslandWorker = { id: string; status: AgentStatus; motion: ResidentMotion; home: Placement; harbor?: number };

/** Work lights belong to the real crew's own shore. Returning ships, alliance
 * visitors, waiting crews and available captains never light an empty island. */
export function activeWorkIslands(workers: readonly IslandWorker[], islandCount: number): Map<string, number> {
  const active = new Map<string, number>();
  for (const worker of workers) {
    if (worker.harbor === undefined || !Number.isInteger(worker.harbor) || worker.harbor < 0 || worker.harbor >= Math.min(MAX_WORK_ISLANDS, islandCount)) continue;
    if (islandCrewActivity(worker.status, worker.motion, worker.home) === 'working') active.set(worker.id, worker.harbor);
  }
  return active;
}

/** Two soft shoreline rings and a little gold work beacon per island, with
 * shared materials and no lights/shadow passes or per-frame mesh creation. */
export function createIslandWorkSignals(scene: Scene, parent: TransformNode, islands: readonly WorkIsland[]) {
  const root = new TransformNode('island-work-signals', scene); root.parent = parent;
  const material = (name: string, color: string, alpha: number) => {
    const value = new StandardMaterial(name, scene); value.diffuseColor = Color3.FromHexString(color);
    value.emissiveColor = value.diffuseColor; value.disableLighting = true; value.alpha = alpha; value.specularColor.setAll(0); return value;
  };
  const mint = material('work-shore-mint', '#8FEBCE', 0.32), gold = material('work-shore-gold', '#F1CE83', 0.95);
  const beacon = material('work-beacon-gold', '#F4D18B', 0.92);
  const signals = islands.slice(0, MAX_WORK_ISLANDS).map((island, index) => {
    const owner = new TransformNode(`island-work-${index}`, scene); owner.parent = root; owner.setEnabled(false);
    const halo = MeshBuilder.CreateTorus('working-shore-halo', { diameter: island.radius * 2.2, thickness: 0.52, tessellation: 72 }, scene);
    halo.parent = owner; halo.position.set(island.x, 0.015, island.z); halo.scaling.z = 0.81; halo.scaling.y = 0.2; halo.material = mint;
    const shore = MeshBuilder.CreateTorus('working-shore-trim', { diameter: island.radius * 2.13, thickness: 0.085, tessellation: 72 }, scene);
    shore.parent = owner; shore.position.set(island.x, 0.047, island.z); shore.scaling.z = 0.81; shore.material = gold;
    const marker = MeshBuilder.CreatePolyhedron('island-work-beacon', { type: 1, size: 0.14 }, scene);
    marker.parent = owner; marker.material = beacon;
    const position = island.marker ?? { x: island.x, z: island.z + island.radius, y: 0.7 };
    marker.position.set(position.x, position.y + 0.72, position.z);
    marker.scaling.set(0.75, 1.2, 0.75);
    for (const mesh of [halo, shore, marker]) { mesh.isPickable = false; mesh.metadata = { islandWorkSignal: true, islandIndex: index }; }
    return { owner, halo, shore, marker, markerY: marker.position.y };
  });
  let disposed = false;
  return {
    root,
    update(workers: readonly IslandWorker[], elapsed: number, reducedMotion: boolean): Map<string, number> {
      if (disposed) return new Map();
      const active = activeWorkIslands(workers, signals.length), lit = new Set(active.values());
      signals.forEach((signal, index) => {
        const enabled = lit.has(index); signal.owner.setEnabled(enabled);
        if (!enabled) return;
        const pulse = reducedMotion ? 0 : Math.sin(elapsed * 1.5 + index * 0.9);
        signal.halo.visibility = 0.80 + pulse * 0.12; signal.shore.visibility = 0.88 + pulse * 0.08;
        signal.marker.position.y = signal.markerY + (reducedMotion ? 0 : Math.sin(elapsed * 1.25 + index) * 0.055);
        signal.marker.rotation.y = reducedMotion ? Math.PI / 4 : elapsed * 0.35 + index;
      });
      return active;
    },
    dispose() { if (disposed) return; disposed = true; root.dispose(); mint.dispose(); gold.dispose(); beacon.dispose(); },
  };
}
