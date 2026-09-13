import { Color3 } from '@babylonjs/core/Maths/math.color.js';
import { MeshBuilder } from '@babylonjs/core/Meshes/meshBuilder.js';
import { Mesh } from '@babylonjs/core/Meshes/mesh.js';
import { VertexData } from '@babylonjs/core/Meshes/mesh.vertexData.js';
import { TransformNode } from '@babylonjs/core/Meshes/transformNode.js';
import { StandardMaterial } from '@babylonjs/core/Materials/standardMaterial.js';
import type { Scene } from '@babylonjs/core/scene.js';
import { newsCooFlight } from './newsCooFlight.ts';

type XYZ = [number, number, number];
/** Tiny News Coo fan-art couriers: feathered wings, pilot caps and newspaper bags. */
export function createNewsCoo(scene: Scene, parent: TransformNode, ocean: boolean) {
  const flock = new TransformNode('news-coo-flock', scene); flock.parent = parent;
  const materials: StandardMaterial[] = [];
  function material(name: string, color: string) {
    const value = new StandardMaterial(`news-coo-${name}`, scene);
    value.diffuseColor = Color3.FromHexString(color); value.specularColor = Color3.Black();
    value.emissiveColor = value.diffuseColor.scale(0.06); materials.push(value); return value;
  }
  const ivory = material('ivory-feathers', '#f8f1dc'), ink = material('ink-feathers', '#233746');
  const ochre = material('golden-beak', '#e8b959'), leather = material('mailbag', '#894d38');
  const paper = material('newspaper', '#e4d4b0'), accent = material('pilot-cap', ocean ? '#46687a' : '#b2ce74');
  const birds: { root: TransformNode; left: TransformNode; right: TransformNode }[] = [];
  function ellipsoid(name: string, size: XYZ, at: XYZ, mat: StandardMaterial, owner: TransformNode) {
    const mesh = MeshBuilder.CreateSphere(name, { diameter: 1, segments: 10 }, scene);
    mesh.parent = owner; mesh.position.set(...at); mesh.scaling.set(...size); mesh.material = mat; mesh.isPickable = false; return mesh;
  }
  function box(name: string, size: XYZ, at: XYZ, mat: StandardMaterial, owner: TransformNode) {
    const mesh = MeshBuilder.CreateBox(name, { width: size[0], height: size[1], depth: size[2] }, scene);
    mesh.parent = owner; mesh.position.set(...at); mesh.material = mat; mesh.isPickable = false; return mesh;
  }
  function wing(side: number, owner: TransformNode) {
    const pivot = new TransformNode(side < 0 ? 'news-coo-left-wing' : 'news-coo-right-wing', scene);
    pivot.parent = owner; pivot.position.set(side * 0.10, 0.05, 0);
    const positions = [0, 0, 0.16, side * 0.38, 0.06, 0.12, side * 0.88, 0.02, -0.16,
      side * 1.02, -0.02, -0.42, side * 0.54, -0.015, -0.24, side * 0.18, -0.025, -0.23, 0, -0.03, -0.16];
    const indices = [0,1,5, 0,5,6, 1,4,5, 1,2,4, 2,3,4], normals: number[] = [];
    if (side > 0) for (let i = 0; i < indices.length; i += 3) [indices[i], indices[i+2]] = [indices[i+2], indices[i]];
    VertexData.ComputeNormals(positions, indices, normals);
    const mesh = new Mesh('news-coo-swept-wing', scene), data = new VertexData();
    data.positions = positions; data.indices = indices; data.normals = normals; data.applyToMesh(mesh);
    mesh.parent = pivot; mesh.material = ivory; mesh.isPickable = false; ivory.backFaceCulling = false;
    for (let feather = 0; feather < 4; feather++) {
      const plume = ellipsoid('news-coo-black-flight-feather', [0.085, 0.025, 0.36 - feather * 0.035],
        [side * (0.67 + feather * 0.086), -0.009, -0.26 - feather * 0.041], ink, pivot);
      plume.rotation.y = side * -0.24;
    }
    return pivot;
  }
  for (let index = 0; index < 3; index++) {
    const root = new TransformNode(`news-coo-${index}`, scene); root.parent = flock;
    root.scaling.setAll(ocean ? 0.92 : 0.62);
    ellipsoid('news-coo-body', [0.27, 0.28, 0.60], [0, 0, 0], ivory, root);
    ellipsoid('news-coo-head', [0.24, 0.25, 0.25], [0, 0.075, 0.30], ivory, root);
    ellipsoid('news-coo-bill', [0.10, 0.095, 0.29], [0, 0.05, 0.48], ochre, root);
    ellipsoid('news-coo-bill-tip', [0.078, 0.075, 0.078], [0, 0.025, 0.62], ink, root);
    for (const side of [-1, 1]) {
      ellipsoid('news-coo-eye', [0.028, 0.044, 0.044], [side * 0.114, 0.116, 0.35], ink, root);
      const tail = ellipsoid('news-coo-tail-feather', [0.11, 0.035, 0.31], [side * 0.065, -0.014, -0.39], ivory, root);
      tail.rotation.y = side * -0.15;
    }
    ellipsoid('news-coo-cap', [0.29, 0.13, 0.25], [0, 0.216, 0.30], ivory, root);
    box('news-coo-cap-band', [0.25, 0.04, 0.14], [0, 0.188, 0.34], accent, root);
    ellipsoid('news-coo-cap-visor', [0.27, 0.028, 0.14], [0, 0.174, 0.42], ink, root);
    const bag = box('news-coo-mailbag', [0.17, 0.19, 0.24], [0.20, -0.085, -0.045], leather, root); bag.rotation.z = -0.10;
    box('news-coo-mailbag-flap', [0.18, 0.055, 0.26], [0.20, 0.01, -0.045], leather, root);
    box('news-coo-bag-clasp', [0.025, 0.046, 0.015], [0.20, -0.054, 0.088], ochre, root);
    const roll = MeshBuilder.CreateCylinder('news-coo-newspaper-roll', { diameter: 0.13, height: 0.34, tessellation: 10 }, scene);
    roll.parent = root; roll.position.set(-0.17, -0.06, -0.04); roll.rotation.z = Math.PI / 2; roll.material = paper; roll.isPickable = false;
    const left = wing(-1, root), right = wing(1, root);
    root.setEnabled(false); birds.push({ root, left, right });
  }
  return {
    update(elapsed: number, reducedMotion: boolean) {
      birds.forEach((bird, index) => {
        const pose = newsCooFlight(elapsed, index, ocean, reducedMotion);
        bird.root.setEnabled(pose.visible);
        if (!pose.visible) return;
        bird.root.position.set(pose.x, pose.y, pose.z);
        bird.root.rotation.set(0, pose.heading, pose.bank);
        bird.left.rotation.z = -pose.flap; bird.right.rotation.z = pose.flap;
      });
    },
    dispose() { flock.dispose(false, false); for (const material of materials) material.dispose(); },
  };
}
