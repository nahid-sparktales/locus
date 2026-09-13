import { Scene } from '@babylonjs/core/scene.js';
import { MeshBuilder } from '@babylonjs/core/Meshes/meshBuilder.js';
import { Mesh } from '@babylonjs/core/Meshes/mesh.js';
import { VertexData } from '@babylonjs/core/Meshes/mesh.vertexData.js';
import { TransformNode } from '@babylonjs/core/Meshes/transformNode.js';
import { StandardMaterial } from '@babylonjs/core/Materials/standardMaterial.js';
import { Color3 } from '@babylonjs/core/Maths/math.color.js';
import { Vector3 } from '@babylonjs/core/Maths/math.vector.js';
import type { ShadowGenerator } from '@babylonjs/core/Lights/Shadows/shadowGenerator.js';
import { SHIP_ASSET_TYPES, SHIP_MODEL_ROTATIONS } from './theme.ts';
import type { ShipAssetType } from './theme.ts';

/** Fit in model space, before the captain's heading/location is applied. The
 * hull stays centered on its navigation body and sits just below the water. */
export function fitShipModel(type: ShipAssetType, bounds: { min: Vector3; max: Vector3 }, targetHeight: number, configuredRotation?: number): { scale: number; offset: Vector3; rotation: number; waterline: number } {
  const height = bounds.max.y - bounds.min.y;
  const horizontal = Math.max(bounds.max.x - bounds.min.x, bounds.max.z - bounds.min.z);
  const scale = height > 0.0001 ? Math.min(targetHeight / height, horizontal > 0 ? 3.35 / horizontal : Infinity) : 1;
  return {
    scale,
    offset: new Vector3(-(bounds.min.x + bounds.max.x) / 2 * scale, -bounds.min.y * scale, -(bounds.min.z + bounds.max.z) / 2 * scale),
    rotation: configuredRotation ?? SHIP_MODEL_ROTATIONS[type],
    waterline: -0.12,
  };
}

function material(scene: Scene, color: string, alpha = 1): StandardMaterial {
  const name = `fleet-${color}-${alpha}`;
  const existing = scene.getMaterialByName(name);
  if (existing instanceof StandardMaterial) return existing;
  const result = new StandardMaterial(name, scene);
  result.diffuseColor = Color3.FromHexString(color);
  result.specularColor.setAll(0.12); result.alpha = alpha; result.backFaceCulling = false;
  return result;
}
/** A recognizable, selectable boat even before its GLB loads. */
export function createShipFallback(scene: Scene, shadow: ShadowGenerator, parent: TransformNode, type: ShipAssetType): void {
  const index = Math.max(0, SHIP_ASSET_TYPES.indexOf(type));
  const hullColors = ['#a84926', '#765139', '#c65329', '#e5ece5', '#e9bc28', '#51463d', '#8d302c', '#b9d9e3', '#782c39', '#5c2625', '#f3bc65', '#283936', '#302437', '#e6e8dd', '#dbe9e7'];
  const sailColors = ['#f7eed6', '#f4e8c8', '#f2c24e', '#faf6eb', '#b32227', '#eee8d3', '#f6e6ce', '#fcf4df', '#b32944', '#a62c24', '#f7ced6', '#2a2e31', '#251c30', '#edf4ed', '#f5f5ec'];
  const hull = material(scene, hullColors[index]), gold = material(scene, '#e5ba62');
  const wood = material(scene, '#654331'), canvas = material(scene, sailColors[index]), navy = material(scene, '#142c33');
  const sphere = (name: string, scale: [number, number, number], pos: [number, number, number], mat: StandardMaterial) => {
    const mesh = MeshBuilder.CreateSphere(name, { diameter: 1, segments: 14 }, scene);
    mesh.scaling.set(...scale); mesh.position.set(...pos); mesh.material = mat; mesh.parent = parent;
    shadow.addShadowCaster(mesh); return mesh;
  };
  const box = (name: string, scale: [number, number, number], pos: [number, number, number], mat: StandardMaterial) => {
    const mesh = MeshBuilder.CreateBox(name, { width: scale[0], height: scale[1], depth: scale[2] }, scene);
    mesh.position.set(...pos); mesh.material = mat; mesh.parent = parent; shadow.addShadowCaster(mesh); return mesh;
  };
  if (type === 'ship_mihawk_coffin') {
    const coffin = MeshBuilder.CreateCylinder('coffin-boat-hull', { diameterTop: 1.6, diameterBottom: 1.32, height: 0.31, tessellation: 6 }, scene);
    coffin.parent = parent; coffin.position.y = 0.18; coffin.scaling.set(0.62, 1, 1.6); coffin.material = hull; shadow.addShadowCaster(coffin, false);
    const lining = MeshBuilder.CreateCylinder('coffin-velvet-deck', { diameter: 1.36, height: 0.045, tessellation: 6 }, scene);
    lining.parent = parent; lining.position.y = 0.36; lining.scaling.set(0.62, 1, 1.6); lining.material = material(scene, '#773441');
    box('coffin-cross-mast', [0.09, 2.1, 0.10], [0, 1.43, -0.48], gold);
    box('coffin-cross-yard', [1.03, 0.10, 0.10], [0, 2.04, -0.48], gold);
    box('coffin-cross-sail', [0.36, 1.45, 0.035], [0, 1.66, -0.52], canvas);
    box('coffin-cross-sail-arms', [0.92, 0.31, 0.035], [0, 2.02, -0.52], canvas);
    box('coffin-throne', [0.46, 0.48, 0.12], [0, 0.63, -0.80], gold);
    for (const side of [-1, 1]) {
      box('coffin-candle', [0.06, 0.33, 0.06], [side * 0.38, 0.53, 0.54], gold);
      const flame = sphere('coffin-green-flame', [0.09, 0.17, 0.09], [side * 0.38, 0.75, 0.54], material(scene, '#83DDAB'));
      (flame.material as StandardMaterial).emissiveColor = Color3.FromHexString('#3D9E76');
    }
    return;
  }
  sphere('ship-timber-hull', [1.45, 0.9, 2.8], [0, 0.27, 0], hull);
  sphere('ship-gilded-bulwark', [1.47, 0.28, 2.6], [0, 0.63, 0], gold);
  sphere('ship-deck', [1.3, 0.19, 2.44], [0, 0.75, 0], wood);
  box('quarterdeck', [1.05, 0.55, 0.72], [0, 0.98, -0.74], hull);
  box('quarterdeck-roof', [1.2, 0.13, 0.83], [0, 1.28, -0.74], gold);
  for (const side of [-1, 1]) for (let p = 0; p < 4; p++) {
    sphere('brass-porthole', [0.07, 0.19, 0.19], [side * 0.7, 0.48, -0.65 + p * 0.4], gold);
    sphere('porthole-glass', [0.08, 0.1, 0.1], [side * 0.73, 0.48, -0.65 + p * 0.4], navy);
  }
  if (type === 'ship_polar_tang') {
    sphere('submarine-dome', [1.26, 0.6, 1.65], [0, 0.84, 0], hull);
    box('submarine-tower', [0.5, 0.6, 0.6], [0, 1.21, -0.2], hull);
    box('periscope', [0.08, 0.4, 0.08], [0.1, 1.62, -0.2], navy); return;
  }
  if (type === 'ship_garp_battleship') {
    const ivory = material(scene, '#F2E9D1');
    sphere('garp-dog-figurehead', [0.7, 0.63, 0.58], [0, 1.05, 1.22], ivory);
    sphere('garp-dog-muzzle', [0.41, 0.3, 0.25], [0, 0.99, 1.48], ivory);
    sphere('garp-dog-nose', [0.17, 0.13, 0.08], [0, 1.06, 1.63], navy);
    for (const side of [-1, 1]) {
      sphere('garp-dog-ear', [0.21, 0.36, 0.17], [side * 0.3, 1.33, 1.19], material(scene, '#8C6945'));
      sphere('garp-dog-eye', [0.065, 0.08, 0.05], [side * 0.15, 1.18, 1.48], navy);
      for (let index = 0; index < 3; index++) {
        const cannon = MeshBuilder.CreateCylinder('garp-broadside-cannon', { diameter: 0.13, height: 0.33, tessellation: 10 }, scene);
        cannon.parent = parent; cannon.position.set(side * 0.77, 0.69, -0.38 + index * 0.36); cannon.rotation.z = Math.PI / 2; cannon.material = navy; shadow.addShadowCaster(cannon, false);
      }
    }
  }
  const mastCount = index === 1 || type === 'ship_marine_patrol' ? 1 : 2;
  for (let m = 0; m < mastCount; m++) {
    const z = mastCount === 1 ? 0.05 : 0.44 - m * 1.02, high = 2.9 - m * 0.28;
    const mast = MeshBuilder.CreateCylinder('timber-mast', { diameter: 0.085, height: high - 0.7, tessellation: 10 }, scene);
    mast.position.set(0, (high + 0.7) / 2, z); mast.material = wood; mast.parent = parent;
    for (let level = 0; level < 2; level++) {
      const y = high - 0.42 - level * 0.76;
      const sail = MeshBuilder.CreateRibbon('billowing-canvas', { pathArray: Array.from({ length: 9 }, (_, row) => Array.from({ length: 13 }, (_, col) => {
        const u = col / 12, v = row / 8;
        return new Vector3((u - 0.5) * (1.45 - m * 0.13), y - v * 0.69, z + Math.sin(u * Math.PI) * Math.sin(v * Math.PI) * 0.25);
      })), sideOrientation: Mesh.DOUBLESIDE }, scene);
      sail.material = canvas; sail.parent = parent; shadow.addShadowCaster(sail);
      if (type === 'ship_garp_battleship' || type === 'ship_marine_patrol') {
        const stripe = box('marine-blue-sail-stripe', [1.26 - m * 0.12, 0.10, 0.03], [0, y - 0.41, z + 0.16], material(scene, '#397B9F'));
        stripe.isPickable = true;
      }
      box('sail-yard', [1.56 - m * 0.13, 0.045, 0.045], [0, y, z], wood);
    }
    const flag = MeshBuilder.CreatePlane('pirate-pennant', { width: 0.47, height: 0.27, sideOrientation: Mesh.DOUBLESIDE }, scene);
    flag.position.set(0.22, high - 0.06, z); flag.material = navy; flag.parent = parent;
  }
  if (index === 0 || index === 1 || index === 7) {
    sphere('figurehead', [0.52, 0.52, 0.52], [0, 0.97, 1.3], index === 0 ? gold : material(scene, '#f0e8d2'));
    if (index === 0) for (let ray = 0; ray < 10; ray++) sphere('lion-mane', [0.22, 0.25, 0.18], [Math.sin(ray * Math.PI / 5) * 0.31, 0.97 + Math.cos(ray * Math.PI / 5) * 0.31, 1.29], material(scene, '#d8782e'));
    for (const side of [-1, 1]) sphere('figurehead-eye', [0.06, 0.08, 0.05], [side * 0.11, 1.05, 1.55], navy);
  }
}
/** Replace hull artwork in place. Signals belong to the resident's owning
 * root and must not be recreated, lost, or moved by a ship preference change. */
export function replaceShipFallback(scene: Scene, shadow: ShadowGenerator, parent: TransformNode, type: ShipAssetType): TransformNode {
  const fallback = new TransformNode(`${parent.name}-fallback`, scene); fallback.parent = parent;
  createShipFallback(scene, shadow, fallback, type);
  for (const mesh of fallback.getChildMeshes()) { mesh.isPickable = true; mesh.metadata = { actorID: parent.name }; }
  for (const child of [...parent.getChildren()]) if (child !== fallback && !child.metadata?.worldSignal) child.dispose();
  return fallback;
}

export function createShipWake(scene: Scene, parent: TransformNode, id: string): TransformNode {
  const root = new TransformNode(`wake-${id}`, scene); root.parent = parent;
  const foam = material(scene, '#c8f6eb', 0.40);
  foam.disableLighting = true; foam.emissiveColor = Color3.FromHexString('#c8f6eb');
  // Soft, broken foam tapers into the sea instead of drawing hard white rails.
  // The small fixed ribbons keep wakes inexpensive across a full fleet.
  for (const side of [-1, 1]) {
    const positions: number[] = [], colors: number[] = [], indices: number[] = [], normals: number[] = [];
    const steps = 28, columns = 5;
    for (let step = 0; step <= steps; step++) {
      const t = step / steps, width = 0.08 + t * 0.27;
      const center = 0.36 + 0.64 * t + 0.22 * t * t + Math.sin(t * 28) * t * 0.027;
      const breakup = 0.62 + 0.25 * Math.sin(t * 46 + side) + 0.13 * Math.sin(t * 83);
      const trail = Math.pow(Math.sin(Math.PI * t), 0.65) * breakup;
      for (let column = 0; column < columns; column++) {
        const across = column / (columns - 1), edge = Math.pow(Math.sin(across * Math.PI), 1.6);
        positions.push(side * (center + (across - 0.5) * width), 0, 1 - t * 4.2);
        normals.push(0, 1, 0); colors.push(1, 1, 1, Math.max(0, trail * edge));
        if (step < steps && column < columns - 1) {
          const a = step * columns + column;
          indices.push(a, a + columns, a + 1, a + 1, a + columns, a + columns + 1);
        }
      }
    }
    const data = new VertexData(); data.positions = positions; data.indices = indices; data.normals = normals; data.colors = colors;
    const strip = new Mesh('ship-foam', scene); data.applyToMesh(strip);
    strip.hasVertexAlpha = true; strip.useVertexColors = true;
    strip.material = foam; strip.parent = root; strip.isPickable = false;
  }
  root.setEnabled(false); return root;
}
