import { Scene } from '@babylonjs/core/scene';
import { MeshBuilder } from '@babylonjs/core/Meshes/meshBuilder';
import { Mesh } from '@babylonjs/core/Meshes/mesh';
import { TransformNode } from '@babylonjs/core/Meshes/transformNode';
import { StandardMaterial } from '@babylonjs/core/Materials/standardMaterial';
import { Color3 } from '@babylonjs/core/Maths/math.color';
import { Vector3 } from '@babylonjs/core/Maths/math.vector';
import type { ShadowGenerator } from '@babylonjs/core/Lights/Shadows/shadowGenerator';
import { SHIP_ASSET_TYPES } from './theme';
import type { ShipAssetType } from './theme';

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
  const hullColors = ['#a84926', '#765139', '#c65329', '#e5ece5', '#e9bc28', '#51463d', '#8d302c', '#b9d9e3', '#782c39', '#5c2625', '#f3bc65', '#283936'];
  const sailColors = ['#f7eed6', '#f4e8c8', '#f2c24e', '#faf6eb', '#b32227', '#eee8d3', '#f6e6ce', '#fcf4df', '#b32944', '#a62c24', '#f7ced6', '#2a2e31'];
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
  const mastCount = index === 1 ? 1 : 2;
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
export function createShipWake(scene: Scene, parent: TransformNode, id: string): TransformNode {
  const root = new TransformNode(`wake-${id}`, scene); root.parent = parent;
  const foam = material(scene, '#c8f6eb', 0.3);
  foam.disableLighting = true; foam.emissiveColor = Color3.FromHexString('#c8f6eb');
  for (const side of [-1, 1]) {
    const strip = MeshBuilder.CreateRibbon('ship-foam', { pathArray: [
      [new Vector3(side * 0.38, 0, 1), new Vector3(side * 0.78, 0, -0.7), new Vector3(side * 1.18, 0, -2.5)],
      [new Vector3(side * 0.44, 0, 1), new Vector3(side * 0.91, 0, -0.7), new Vector3(side * 1.27, 0, -2.5)],
    ], sideOrientation: Mesh.DOUBLESIDE }, scene);
    strip.material = foam; strip.parent = root; strip.isPickable = false;
  }
  root.setEnabled(false); return root;
}
