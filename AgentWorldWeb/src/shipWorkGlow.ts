import { Scene } from '@babylonjs/core/scene.js';
import { TransformNode } from '@babylonjs/core/Meshes/transformNode.js';
import { MeshBuilder } from '@babylonjs/core/Meshes/meshBuilder.js';
import { StandardMaterial } from '@babylonjs/core/Materials/standardMaterial.js';
import { Color3 } from '@babylonjs/core/Maths/math.color.js';
import type { AgentStatus, Point } from './state.ts';

/** Layered emissive water halos stay legible without a costly full-scene bloom. */
export function createShipWorkGlow(scene: Scene, parent: TransformNode, id: string) {
  const root = new TransformNode(`ship-work-glow-${id}`, scene); root.parent = parent; root.setEnabled(false);
  const materials: StandardMaterial[] = [];
  for (const [index, thickness, alpha] of [[0, 0.52, 0.09], [1, 0.26, 0.22], [2, 0.075, 0.95]]) {
    const material = new StandardMaterial(`ship-work-light-${id}-${index}`, scene);
    material.diffuseColor = Color3.FromHexString('#83F5D7'); material.emissiveColor = material.diffuseColor;
    material.disableLighting = true; material.alpha = alpha; material.specularColor.setAll(0); materials.push(material);
    const ring = MeshBuilder.CreateTorus(`ship-work-halo-${index}`, { diameter: 3.7, thickness, tessellation: 64 }, scene);
    ring.parent = root; ring.position.y = 0.105 + index * 0.012; ring.scaling.set(0.83, 0.12, 1.17);
    ring.material = material; ring.isPickable = false;
  }
  return {
    root,
    update(status: AgentStatus, docked: boolean, position: Point, heading: number, elapsed: number, reducedMotion: boolean) {
      const traveling = status === 'working' && !docked;
      root.setEnabled(traveling); root.position.set(position.x, 0, position.z); root.rotation.y = heading;
      root.scaling.setAll(reducedMotion ? 1 : 1 + Math.sin(elapsed * 2) * 0.045);
      return traveling;
    },
    dispose() { root.dispose(); materials.forEach(material => material.dispose()); },
  };
}
