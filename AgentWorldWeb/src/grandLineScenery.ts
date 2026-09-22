import { Scene } from '@babylonjs/core/scene';
import { Vector3 } from '@babylonjs/core/Maths/math.vector';
import { Color3 } from '@babylonjs/core/Maths/math.color';
import { Mesh } from '@babylonjs/core/Meshes/mesh';
import { MeshBuilder } from '@babylonjs/core/Meshes/meshBuilder';
import { VertexData } from '@babylonjs/core/Meshes/mesh.vertexData';
import { TransformNode } from '@babylonjs/core/Meshes/transformNode';
import { StandardMaterial } from '@babylonjs/core/Materials/standardMaterial';
import { DynamicTexture } from '@babylonjs/core/Materials/Textures/dynamicTexture';
import { ShadowGenerator } from '@babylonjs/core/Lights/Shadows/shadowGenerator';
import type { CircleObstacle, Placement, SceneryAssetType, Theme } from './theme';
import type { AssetContainer } from '@babylonjs/core/assetContainer';
import { GrandLineModels } from './grandLineModels';
import { createWaterfallMist } from './waterfallMist';
import { createOceanWater } from './oceanWater';
import { LaboonCompanion } from './laboonInteraction';
import type { Point } from './state';

import { islandArtworkRotation, GRAND_LINE_LANDMARKS, GRAND_LINE_ISLAND_MODELS, GRAND_LINE_HARBORS, GRAND_LINE_CREW_PLAZAS, GRAND_LINE_HOME_NAMES, GRAND_LINE_STATIONS, GRAND_LINE_OBSTACLES, GRAND_LINE_WANDER_POINTS, GRAND_LINE_LABOON_POSITION } from './grandLineGeography';
export { GRAND_LINE_LANDMARKS, GRAND_LINE_ISLAND_MODELS, GRAND_LINE_HARBORS, GRAND_LINE_CREW_PLAZAS, GRAND_LINE_HOME_NAMES, GRAND_LINE_STATIONS, GRAND_LINE_OBSTACLES, GRAND_LINE_WANDER_POINTS, GRAND_LINE_LABOON_POSITION } from './grandLineGeography';

type XYZ = [number, number, number];
type Scenery = { selectCreature: (id: string) => boolean; handleCreatureKey: (key: string, repeat?: boolean) => boolean; installAsset: (type: SceneryAssetType, container: AssetContainer) => void; update: (elapsed: number, reducedMotion: boolean) => void; dispose: () => void };
const TAU = Math.PI * 2;
const coastPhase = (index: number): number => index * 2.3999632297 + 0.73;
// The ocean uses the same contour to blend its sandy shallows into the sculpted shore.
const coastContour = (angle: number, phase: number): number =>
  1 + Math.sin(angle * 3 + phase) * 0.065 + Math.cos(angle * 5 - phase) * 0.035 + Math.sin(angle * 9 + phase * 2) * 0.012;

export function buildGrandLineScenery(scene: Scene, shadow: ShadowGenerator, parent: TransformNode, theme: Theme): Scenery {
  const root = new TransformNode('grand-line-archipelago', scene);
  root.parent = parent;
  const models = new GrandLineModels(scene, shadow, theme);
  let laboon: LaboonCompanion | undefined;
  const waterfallMist = models.has('scenery_reverse_mountain') ? createWaterfallMist(scene, root) : undefined;
  const materials = new Map<string, StandardMaterial>();
  const staticMeshes: Mesh[] = [];
  const textures: DynamicTexture[] = [];
  const drifting: { node: TransformNode; y: number; phase: number; amount: number }[] = [];
  let seed = 7719;
  const random = (): number => { seed = Math.imul(seed ^ (seed >>> 13), 1274126177); seed ^= seed >>> 16; return (seed >>> 0) / 4294967296; };
  const mat = (name: string, hex: string, emission = 0, alpha = 1): StandardMaterial => {
    const key = `${name}:${hex}:${emission}:${alpha}`;
    const found = materials.get(key); if (found) return found;
    const material = new StandardMaterial(`grand-line-${name}`, scene);
    material.diffuseColor = Color3.FromHexString(hex);
    material.specularColor = new Color3(0.055, 0.065, 0.055);
    material.specularPower = 48;
    material.emissiveColor = material.diffuseColor.scale(emission);
    material.alpha = alpha;
    materials.set(key, material); return material;
  };
  const sand = mat('warm-sand', '#f3d69a');
  const white = mat('ivory-plaster', '#fff0d2');
  const snow = mat('fresh-snow', '#e7fbff');
  const navy = mat('ink', '#183842');
  const wood = mat('cedar', '#955b36');
  const gold = mat('gold', '#e9b451');
  const red = mat('lacquer-red', '#b64539');
  const leaf = mat('jungle-green', '#237d52');
  const leafLight = mat('sunlit-leaves', '#51ac67');
  const pink = mat('cherry-blossom', '#f49bba');
  const turquoise = mat('fresh-water', '#3fd0cd', 0.16);
  const foam = mat('sea-foam', '#d0ffec', 0.2, 0.69);
  foam.disableLighting = true;
  const terrain = mat('terrain-vertex-color', '#ffffff');
  terrain.specularColor = Color3.Black();
  const rock = mat('shore-rock', '#a5a38a'), rockLight = mat('shore-rock-highlight', '#c9c7ab');
  const trim = mat('painted-trim', '#f6dfb7');
  const leafShade = mat('deep-leaves', '#286846');
  const finish = (mesh: Mesh, material: StandardMaterial, position: XYZ, owner: TransformNode = root, animated = false): Mesh => {
    mesh.position.set(...position); mesh.parent = owner; mesh.material = material;
    mesh.isPickable = false; mesh.receiveShadows = true;
    if (!animated) staticMeshes.push(mesh);
    return mesh;
  };
  const box = (name: string, size: XYZ, position: XYZ, material: StandardMaterial, owner = root, animated = false): Mesh =>
    finish(MeshBuilder.CreateBox(name, { width: size[0], height: size[1], depth: size[2] }, scene), material, position, owner, animated);
  const cylinder = (name: string, bottom: number, top: number, height: number, position: XYZ, material: StandardMaterial, sides = 24, owner = root): Mesh =>
    finish(MeshBuilder.CreateCylinder(name, { diameterBottom: bottom, diameterTop: top, height, tessellation: sides }, scene), material, position, owner);
  const sphere = (name: string, size: XYZ, position: XYZ, material: StandardMaterial, owner = root, animated = false): Mesh => {
    const mesh = finish(MeshBuilder.CreateSphere(name, { diameter: 1, segments: 12 }, scene), material, position, owner, animated);
    mesh.scaling.set(...size); return mesh;
  };
  const tube = (name: string, path: XYZ[], radius: number, material: StandardMaterial, owner = root, sides = 8): Mesh =>
    finish(MeshBuilder.CreateTube(name, { path: path.map(p => new Vector3(...p)), radius, tessellation: sides, cap: Mesh.CAP_ALL }, scene), material, [0, 0, 0], owner);
  const ring = (name: string, radius: number, height: number, material: StandardMaterial, owner = root, thickness = 0.035): Mesh => {
    return finish(MeshBuilder.CreateTorus(name, { diameter: radius * 2, thickness, tessellation: 48 }, scene), material, [0, height, 0], owner);
  };
  const label = (title: string, subtitle: string, position: XYZ, width = 4.3, isSea = false): void => {
    const texture = new DynamicTexture(`map-label-${title}`, { width: 1024, height: 192 }, scene, true);
    texture.anisotropicFilteringLevel = 8;
    const context = texture.getContext() as CanvasRenderingContext2D;
    context.clearRect(0, 0, 1024, 192);
    context.textAlign = 'center'; context.textBaseline = 'middle';
    context.font = `600 ${isSea ? 63 : 57}px Georgia, serif`;
    context.strokeStyle = 'rgba(12,59,66,0.56)';
    context.lineWidth = isSea ? 1 : 3;
    context.strokeText(title.toUpperCase(), 512, 74);
    context.fillStyle = isSea ? 'rgba(205,236,211,0.34)' : '#d9ead2';
    context.fillText(title.toUpperCase(), 512, 74);
    context.font = '500 25px Georgia, serif';
    context.fillStyle = isSea ? 'rgba(205,236,211,0.30)' : '#c3dbc7';
    context.fillText(subtitle, 512, 131);
    texture.update(); texture.hasAlpha = true; textures.push(texture);
    const material = new StandardMaterial(`map-label-${title}`, scene);
    material.diffuseTexture = texture; material.emissiveTexture = texture;
    material.useAlphaFromDiffuseTexture = true; material.disableLighting = true;
    material.backFaceCulling = false; material.specularColor = Color3.Black();
    materials.set(`label-${title}`, material);
    const plane = MeshBuilder.CreatePlane(`map-label-${title}`, { width, height: width * 192 / 1024 }, scene);
    finish(plane, material, position, root, true);
    plane.rotation.x = Math.PI / 2;
    plane.renderingGroupId = 1;
  };

  const oceanWater = createOceanWater(scene, root, GRAND_LINE_LANDMARKS);

  function island(index: number, grassColor: string, sandColor: string): TransformNode {
    const { x, z, radius, id } = GRAND_LINE_LANDMARKS[index];
    const owner = new TransformNode('island', scene); owner.parent = root; owner.position.set(x, 0, z);
    const segments = 80, positions: number[] = [], colors: number[] = [], indices: number[] = [], normals: number[] = [];
    const phase = coastPhase(index), snowy = id === 'drum', desert = id === 'alabasta';
    const grassBase = Color3.FromHexString(grassColor), sandBase = Color3.FromHexString(sandColor);
    const rings = [
      { r: 0, y: 0.60, c: grassBase }, { r: 0.30, y: 0.61, c: grassBase },
      { r: 0.57, y: 0.61, c: grassBase }, { r: 0.72, y: 0.57, c: grassBase },
      { r: 0.82, y: 0.46, c: grassBase.scale(0.94) },
      { r: 0.875, y: 0.28, c: Color3.Lerp(grassBase, sandBase, 0.72) },
      { r: 0.92, y: 0.17, c: sandBase }, { r: 0.99, y: 0.065, c: sandBase },
      { r: 1.04, y: -0.015, c: Color3.Lerp(sandBase, Color3.FromHexString('#a2b59a'), 0.26) },
      { r: 1.075, y: -0.17, c: Color3.FromHexString(snowy ? '#a6c5c7' : '#9da58b') },
      { r: 1.10, y: -0.32, c: Color3.FromHexString('#6d9485') },
    ];
    for (const layer of rings) {
      for (let n = 0; n < segments; n++) {
        const angle = n / segments * TAU;
        const contour = coastContour(angle, phase);
        const px = Math.cos(angle) * radius * layer.r * contour, pz = Math.sin(angle) * radius * layer.r * contour * 0.80;
        // Fine surface relief fades out at the center; established buildings keep their footing.
        const relief = layer.r < 0.85 ? (Math.sin(px * 4 + phase) * Math.cos(pz * 3 - phase) * 0.022 + Math.sin(angle * 4 + phase) * 0.022) * Math.min(layer.r * 3, 1) : 0;
        positions.push(px, layer.y + relief, pz);
        const shade = 0.97 + Math.sin(px * 5.3 + phase) * Math.cos(pz * 4.7) * (layer.r < 0.88 ? 0.045 : 0.019) + Math.sin(angle * 2 + phase) * 0.025;
        colors.push(layer.c.r * shade, layer.c.g * shade, layer.c.b * shade, 1);
      }
    }
    for (let r = 0; r < rings.length - 1; r++) for (let n = 0; n < segments; n++) {
      const a = r * segments + n, b = r * segments + (n + 1) % segments, c = a + segments, d = b + segments;
      indices.push(a, b, c, b, d, c);
    }
    VertexData.ComputeNormals(positions, indices, normals);
    const mesh = new Mesh('sculpted-island-coastline', scene);
    const data = new VertexData(); data.positions = positions; data.indices = indices; data.normals = normals; data.colors = colors; data.applyToMesh(mesh);
    finish(mesh, terrain, [0, 0, 0], owner); mesh.material!.backFaceCulling = false;
    const direction = GRAND_LINE_HARBORS[index].direction;
    for (let n = 0; n < 14; n++) {
      const angle = n * TAU / 14 + phase;
      // The harbor approach and the crew plaza remain a clear, open beach.
      if (Math.cos(angle) * direction.x + Math.sin(angle) * direction.z > 0.40) continue;
      const r = radius * (0.88 + random() * 0.035) * coastContour(angle, phase);
      const px = Math.cos(angle) * r, pz = Math.sin(angle) * r * 0.80;
      const size = 0.16 + random() * 0.20;
      const stone = sphere('weathered-coastal-boulder', [size * 1.35, size * 0.78, size], [px, 0.23, pz], snowy ? snow : desert ? sand : n % 3 ? rock : rockLight, owner);
      stone.rotation.set(random() * 0.22, angle, random() * 0.18);
      if (n % 3 === 0) sphere('coastal-pebble', [size * 0.53, size * 0.30, size * 0.60], [px + size * 0.65, 0.19, pz + size * 0.14], snowy ? snow : rockLight, owner);
      if (!snowy && !desert && n % 2 === 0) {
        const tuftX = px * 0.85, tuftZ = pz * 0.85;
        for (let blade = 0; blade < 3; blade++) {
          const grass = cylinder('coastal-grass', 0.07, 0, 0.18 + blade * 0.035, [tuftX + (blade - 1) * 0.045, 0.62, tuftZ], n % 4 ? leafLight : leaf, 4, owner);
          grass.rotation.z = (blade - 1) * 0.3;
        }
      }
    }
    return owner;
  }
  function palm(owner: TransformNode, x: number, z: number, height = 1.55, lean = 0.28): void {
    tube('curved-palm-trunk', [[x, 0.59, z], [x + lean * 0.12, height * 0.27 + 0.5, z], [x + lean * 0.35, height * 0.5 + 0.5, z], [x + lean * 0.65, height * 0.76 + 0.5, z + 0.05], [x + lean, height + 0.5, z + 0.10]], 0.068, wood, owner, 9);
    for (let n = 1; n < 7; n++) {
      const t = n / 7;
      cylinder('palm-trunk-ring', 0.144, 0.139, 0.027, [x + lean * t * t, 0.50 + height * t, z + Math.max(0, t - 0.5) * 0.20], mat('palm-bark-ring', '#b58b60'), 9, owner);
    }
    const center = new Vector3(x + lean, height + 0.5, z + 0.10);
    for (let n = 0; n < 9; n++) {
      const angle = TAU * n / 9 + random() * 0.16;
      const length = 0.80 + random() * 0.30, positions: number[] = [], indices: number[] = [], normals: number[] = [];
      const side = new Vector3(-Math.sin(angle), 0, Math.cos(angle));
      for (let i = 0; i <= 10; i++) {
        const f = i / 10, breadth = Math.sin(f * Math.PI) * (i % 2 ? 0.125 : 0.18);
        const p = center.add(new Vector3(Math.cos(angle) * length * f, Math.sin(f * Math.PI) * 0.31 - f * 0.30, Math.sin(angle) * length * f));
        for (const sign of [-1, 0, 1]) {
          const v = p.add(side.scale(breadth * sign));
          positions.push(v.x, v.y + (sign === 0 ? Math.sin(f * Math.PI) * 0.045 : 0), v.z);
        }
        if (i < 10) for (let side = 0; side < 2; side++) {
          const a = i * 3 + side; indices.push(a, a + 1, a + 3, a + 1, a + 4, a + 3);
        }
      }
      VertexData.ComputeNormals(positions, indices, normals);
      const mesh = new Mesh('palm-frond', scene), data = new VertexData(); data.positions = positions; data.indices = indices; data.normals = normals; data.applyToMesh(mesh);
      const material = n % 2 ? leaf : leafLight; material.backFaceCulling = false;
      finish(mesh, material, [0, 0, 0], owner);
    }
    for (let n = 0; n < 3; n++) sphere('coconut-cluster', [0.13, 0.17, 0.14], [center.x + Math.cos(n * TAU / 3) * 0.085, center.y - 0.10, center.z + Math.sin(n * TAU / 3) * 0.085], wood, owner);
  }
  function broadTree(owner: TransformNode, x: number, z: number, height: number, color = leafLight): void {
    cylinder('tree-trunk', 0.21, 0.13, height, [x, 0.56 + height / 2, z], wood, 8, owner);
    const highlight = color === pink ? mat('sunlit-blossom', '#ffc5d5') : leafLight;
    const shade = color === pink ? mat('blossom-shadow', '#d681a9') : leafShade;
    sphere('tree-canopy-understory', [height * 0.92, height * 0.50, height * 0.81], [x, height + 0.33, z], shade, owner);
    for (let n = 0; n < 5; n++) {
      const a = n * TAU / 5 + 0.3, cx = x + Math.cos(a) * height * 0.25, cz = z + Math.sin(a) * height * 0.22;
      tube('tree-branch', [[x, 0.56 + height * 0.65, z], [cx, height + 0.45, cz]], 0.040, wood, owner, 6);
      sphere('rounded-tree-crown', [height * 0.64, height * 0.60, height * 0.60], [cx, height + 0.56 + (n % 2) * height * 0.09, cz], n % 3 === 0 ? highlight : color, owner);
    }
    sphere('tree-canopy-crown', [height * 0.65, height * 0.51, height * 0.63], [x - height * 0.07, height + 0.87, z], highlight, owner);
  }
  function house(owner: TransformNode, x: number, z: number, w: number, h: number, body = white, roofMat = red, y = 0.58): void {
    box('house-stone-foundation', [w * 1.07, h * 0.11, w * 0.78], [x, y + h * 0.045, z], trim, owner);
    box('island-house', [w, h, w * 0.72], [x, y + h / 2, z], body, owner);
    box('house-roof-eaves', [w * 1.16, w * 0.055, w * 0.87], [x, y + h, z], wood, owner);
    const roof = cylinder('pitched-roof', w * 1.60, 0, w * 0.38, [x, y + h + w * 0.19, z], roofMat, 4, owner); roof.rotation.y = Math.PI / 4; roof.scaling.z = 0.80;
    for (const side of [-1, 1]) {
      box('window-surround', [w * 0.20, h * 0.34, 0.028], [x + side * w * 0.28, y + h * 0.60, z + w * 0.366], trim, owner);
      box('window', [w * 0.14, h * 0.25, 0.032], [x + side * w * 0.28, y + h * 0.60, z + w * 0.371], navy, owner);
      box('window-sill', [w * 0.24, h * 0.045, w * 0.06], [x + side * w * 0.28, y + h * 0.43, z + w * 0.38], trim, owner);
      box('window-shutter', [w * 0.062, h * 0.27, 0.035], [x + side * w * 0.40, y + h * 0.60, z + w * 0.365], roofMat, owner);
    }
    box('door-frame', [w * 0.26, h * 0.52, 0.027], [x, y + h * 0.26, z + w * 0.366], trim, owner);
    box('door', [w * 0.19, h * 0.46, 0.034], [x, y + h * 0.23, z + w * 0.371], wood, owner);
    sphere('door-handle', [w * 0.022, w * 0.022, w * 0.022], [x + w * 0.052, y + h * 0.23, z + w * 0.371 + 0.018], gold, owner);
    box('house-chimney', [w * 0.13, w * 0.30, w * 0.13], [x + w * 0.28, y + h + w * 0.26, z - w * 0.12], body, owner);
    box('house-chimney-cap', [w * 0.17, w * 0.045, w * 0.17], [x + w * 0.28, y + h + w * 0.42, z - w * 0.12], trim, owner);
  }
  function pagoda(owner: TransformNode, x: number, z: number, baseY = 0.62, scale = 1, levels = 3): void {
    for (let level = 0; level < levels; level++) {
      const width = (1.7 - level * 0.32) * scale, y = baseY + level * 0.71 * scale;
      box('pagoda-plaster', [width * 0.70, 0.55 * scale, width * 0.61], [x, y + 0.27 * scale, z], white, owner);
      for (const sx of [-1, 1]) for (const sz of [-1, 1]) box('pagoda-red-column', [0.075 * scale, 0.60 * scale, 0.075 * scale], [x + sx * width * 0.34, y + 0.27 * scale, z + sz * width * 0.29], red, owner);
      for (const sign of [-1, 1]) {
        box('pagoda-window', [width * 0.14, 0.25 * scale, 0.022], [x + sign * width * 0.18, y + 0.29 * scale, z + width * 0.312], navy, owner);
        box('pagoda-window-mullion', [0.018 * scale, 0.27 * scale, 0.025], [x + sign * width * 0.18, y + 0.29 * scale, z + width * 0.318], red, owner);
      }
      const extent = width * 0.60, divisions = 10;
      const roofPoint = (u: number, v: number): XYZ => {
        const edge = Math.max(Math.abs(u), Math.abs(v));
        const rise = 0.53 + 0.30 * Math.pow(1 - edge, 1.4) + 0.13 * Math.pow(edge, 7) * (0.55 + 0.45 * Math.abs(u * v));
        return [x + u * extent, y + rise * scale, z + v * extent];
      };
      const positions: number[] = [], indices: number[] = [], normals: number[] = [];
      for (let row = 0; row <= divisions; row++) for (let col = 0; col <= divisions; col++) {
        positions.push(...roofPoint(col / divisions * 2 - 1, row / divisions * 2 - 1));
        if (row < divisions && col < divisions) {
          const a = row * (divisions + 1) + col, b = a + divisions + 1;
          indices.push(a, b, a + 1, a + 1, b, b + 1);
        }
      }
      VertexData.ComputeNormals(positions, indices, normals);
      const roof = new Mesh('pagoda-sweeping-roof', scene), data = new VertexData();
      data.positions = positions; data.indices = indices; data.normals = normals; data.applyToMesh(roof);
      const roofMaterial = mat('pagoda-roof', '#275462'); roofMaterial.backFaceCulling = false;
      finish(roof, roofMaterial, [0, 0, 0], owner);
      for (const sign of [-1, 1]) {
        const front: XYZ[] = [], side: XYZ[] = [];
        for (let n = 0; n <= divisions; n++) {
          const t = n / divisions * 2 - 1;
          front.push(roofPoint(t, sign)); side.push(roofPoint(sign, t));
        }
        tube('pagoda-upturned-eave', front, 0.022 * scale, gold, owner, 6);
        tube('pagoda-upturned-eave', side, 0.022 * scale, gold, owner, 6);
      }
    }
    cylinder('pagoda-golden-spire', 0.12 * scale, 0, 0.50 * scale, [x, baseY + levels * 0.71 * scale + 0.20 * scale, z], gold, 8, owner);
  }
  function cloud(owner: TransformNode, x: number, y: number, z: number, scale = 1, moving = false): void {
    for (let n = 0; n < 5; n++) {
      const puff = sphere('billowing-cloud', [scale * (0.9 + random() * 0.5), scale * 0.57, scale * (0.8 + random() * 0.4)], [x + (n - 2) * scale * 0.43, y + Math.sin(n * 1.8) * 0.09, z + Math.sin(n * 2.3) * scale * 0.21], snow, owner, moving);
      if (moving) puff.receiveShadows = false;
    }
  }

  // The Thread Line follows the reference geography and leaves a true sea passage beneath the mountain.
  const cliff = mat('red-line-rock', '#be694b'), cliffLight = mat('red-line-sunlit', '#d48a5d'), cliffDark = mat('red-line-strata', '#914c42');
  for (const sign of [-1, 1]) {
    if (models.has('scenery_red_line')) {
      for (let n = 0; n < 4; n++) {
        const ridge = new TransformNode(`thread-line-ridge-${sign}-${n}`, scene);
        ridge.parent = root; ridge.position.set(-29, 0, sign * (9.7 + n * 9.4));
        models.add('scenery_red_line', { parent: ridge, width: 4.2, depth: 10.4, height: 6.5 + (n % 2) * 0.4, floor: -0.36, rotation: n % 2 ? Math.PI : 0 });
      }
    } else for (let n = 0; n < 15; n++) {
      const z = sign * (6.3 + n * 2.3), height = 3.4 + random() * 2.0 + (n < 2 ? 1.4 : 0);
      const rock = cylinder('red-line-cliff', 4.7, 2.5 + random() * 0.9, height, [-29 + Math.sin(n * 0.8) * 0.55, height / 2 - 0.14, z], n % 3 ? cliff : cliffLight, 7);
      rock.scaling.z = 0.76; rock.rotation.y = n * 0.71; rock.convertToFlatShadedMesh();
      const ledge = cylinder('red-line-sedimentary-ledge', 4.65, 4.45, 0.25, [-29 + Math.sin(n * 0.8) * 0.55, height * 0.35, z], cliffDark, 7);
      ledge.scaling.z = 0.76; ledge.rotation.y = n * 0.71;
      const cap = cylinder('red-line-grass-crown', 2.62, 2.4, 0.15, [-29 + Math.sin(n * 0.8) * 0.55, height - 0.16, z], leafLight, 7); cap.scaling.z = 0.76;
    }
    if (models.has('scenery_reverse_mountain')) {
      const mountain = new TransformNode(`recurse-mountain-${sign}`, scene);
      mountain.parent = root; mountain.position.set(-29, 0, sign * 6.3);
      models.add('scenery_reverse_mountain', { parent: mountain, width: 5.2, depth: 5.0, height: 8,
        footprintRadius: 2.5, floor: -0.20, rotation: sign > 0 ? Math.PI : 0 });
    } else {
      tube('reverse-mountain-river', [[-33.67, -0.01, sign * 12.4], [-31.88, 1.8, sign * 7.75], [-29.12, 5.2, sign * 5.89], [-26.50, 2.6, sign * 3.88], [-25.53, 0.08, sign * 1.55]], 0.25, turquoise, root, 10);
      tube('reverse-mountain-whitewater', [[-29.12, 5.3, sign * 5.89], [-26.50, 2.75, sign * 3.88], [-25.53, 0.14, sign * 1.55]], 0.055, foam, root, 7);
    }
  }
  label('Recurse Mountain', 'ENTER THE LOCAL LINE', [-29, 0.05, 1.90], 5.6);
  label('Thread Line', 'ONE THREAD CONNECTS EVERY PORT', [-33.5, 0.02, -20], 6.6, true);
  label('RAM Belt', 'HERE BE SEED KINGS', [-4, -0.04, -24], 7, true);
  label('RAM Belt', 'QUIET WATERS. PLENTY OF MEMORY.', [-4, -0.04, 24], 7, true);
  label('Local Line', 'OPEN WEIGHTS  ·  OPEN SEAS', [0, -0.03, 0.5], 10.7, true);

  for (const landmark of GRAND_LINE_LANDMARKS) {
    const desert = landmark.id === 'alabasta', snowy = landmark.id === 'drum';
    const type = GRAND_LINE_ISLAND_MODELS[landmark.id];
    const detailed = models.has(type);
    const owner = detailed ? new TransformNode(landmark.id, scene) : island(GRAND_LINE_LANDMARKS.indexOf(landmark), desert ? '#e4bd72' : snowy ? '#d8eeee' : '#76ac62', desert ? '#f1d299' : snowy ? '#d9eeee' : '#ecd49d');
    owner.name = landmark.id;
    if (detailed) {
      owner.parent = root; owner.position.set(landmark.x, 0, landmark.z);
      models.add(type, { parent: owner, width: landmark.radius * 2.02, depth: landmark.radius * 1.62, height: theme.heights[type], footprintRadius: landmark.radius + 0.10, floor: -0.12, rotation: islandArtworkRotation(landmark.id) });
    }
    if (landmark.id === 'twin-cape') {
      const whale = new TransformNode('laboon', scene); whale.parent = root;
      whale.position.set(GRAND_LINE_LABOON_POSITION.x, 0, GRAND_LINE_LABOON_POSITION.z);
      if (models.has('creature_laboon')) {
        models.add('creature_laboon', { parent: whale, width: 2.1, depth: 2.0, height: 1.8,
          footprintRadius: 0.96, floor: -0.25, rotation: -Math.PI / 4, animated: true, interactionID: 'laboon' });
      } else {
        const head = sphere('laboon-head', [1.6, 1.05, 1.7], [0, 0.12, 0], mat('laboon-blue', '#354f68'), whale, true);
        head.isPickable = true; head.metadata = { creatureID: 'laboon' };
      }
      laboon = new LaboonCompanion(scene, whale);
    }
    if (!detailed) {
    if (landmark.id === 'twin-cape') {
      cylinder('lighthouse-foot', 1.05, 0.98, 0.24, [-0.15, 0.66, -0.2], white, 24, owner);
      for (let level = 0; level < 7; level++) cylinder('twin-cape-lighthouse-stripe', 0.65 - level * 0.036, 0.61 - level * 0.036, 0.34, [-0.15, 0.95 + level * 0.34, -0.2], level % 2 ? red : white, 20, owner);
      cylinder('lighthouse-balcony', 0.89, 0.89, 0.12, [-0.15, 3.15, -0.2], navy, 24, owner);
      cylinder('lighthouse-lantern', 0.44, 0.44, 0.48, [-0.15, 3.44, -0.2], mat('lighthouse-lamp', '#fff0a5', 0.7), 12, owner);
      cylinder('lighthouse-cap', 0.81, 0, 0.38, [-0.15, 3.84, -0.2], red, 20, owner);
      house(owner, 0.95, 0.1, 0.70, 0.54);
      palm(owner, -0.8, 0.48, 1.0, -0.15);
    } else if (landmark.id === 'little-garden') {
      for (let n = 0; n < 7; n++) { const a = n * TAU / 7; palm(owner, Math.cos(a) * 1.3, Math.sin(a) * 0.85, 1.35 + random() * 0.65, Math.cos(a) * 0.22); }
      const dino = mat('dinosaur', '#609d62');
      sphere('dinosaur-body', [1.4, 0.58, 0.65], [0, 0.97, 0.25], dino, owner);
      tube('dinosaur-neck', [[0.48, 1.1, 0.25], [0.73, 1.85, 0.25], [0.69, 2.34, 0.23]], 0.17, dino, owner);
      sphere('dinosaur-head', [0.56, 0.31, 0.32], [0.88, 2.35, 0.23], dino, owner);
      sphere('dinosaur-eye', [0.055, 0.055, 0.04], [0.98, 2.43, 0.37], navy, owner);
      tube('dinosaur-tail', [[-0.51, 1.05, 0.25], [-1.05, 1.05, 0.20], [-1.38, 1.35, 0.17]], 0.11, dino, owner);
      for (const x of [-0.43, 0.42]) for (const z of [0.03, 0.47]) cylinder('dinosaur-leg', 0.18, 0.14, 0.43, [x, 0.75, z], dino, 8, owner);
      cylinder('ancient-volcano', 1.20, 0.30, 1.70, [-0.6, 1.32, -0.72], mat('volcano', '#756858'), 9, owner);
      cylinder('volcano-crater', 0.30, 0.30, 0.03, [-0.6, 2.19, -0.72], navy, 10, owner);
    } else if (landmark.id === 'drum') {
      const mountain = mat('drum-cliff', '#648999');
      for (const [x, z, h, r] of [[-1.1, -0.1, 2.5, 0.48], [0, -0.45, 3.6, 0.72], [0.95, 0.1, 2.1, 0.41]]) {
        cylinder('drum-rock-tower', r * 1.7, r * 2, h, [x, 0.54 + h / 2, z], mountain, 9, owner);
        cylinder('drum-snowcap', r * 2.16, r * 2.06, 0.17, [x, 0.60 + h, z], snow, 12, owner);
      }
      house(owner, 0, -0.45, 0.8, 0.75, white, mat('drum-castle-roof', '#ac697f'), 4.25);
      for (const x of [-0.41, 0.41]) { cylinder('drum-castle-turret', 0.26, 0.26, 0.91, [x, 4.78, -0.45], white, 12, owner); cylinder('drum-castle-turret-roof', 0.38, 0, 0.49, [x, 5.44, -0.45], red, 12, owner); }
      for (let n = 0; n < 5; n++) {
        const x = -1.40 + n * 0.65, z = 0.76 + Math.sin(n * 2) * 0.16;
        cylinder('snow-pine', 0.52, 0, 0.86, [x, 1.04, z], leaf, 7, owner);
        cylinder('snow-pine-top', 0.40, 0, 0.70, [x, 1.22, z], snow, 7, owner);
      }
    } else if (landmark.id === 'alabasta') {
      const sandstone = mat('alabasta-sandstone', '#e1b578');
      for (const [x, z, s] of [[-1.35, -0.30, 1.15], [-0.45, -0.76, 0.8]]) { const pyramid = cylinder('alabasta-pyramid', s * 1.5, 0, s, [x, 0.61 + s / 2, z], sandstone, 4, owner); pyramid.rotation.y = Math.PI / 4; }
      cylinder('alubarna-palace-base', 1.40, 1.40, 0.30, [0.8, 0.77, 0.05], sandstone, 24, owner);
      box('alubarna-palace', [0.95, 0.85, 0.8], [0.8, 1.28, 0.05], white, owner);
      sphere('alabasta-turquoise-dome', [0.95, 0.70, 0.86], [0.8, 1.78, 0.05], mat('palace-dome', '#57aa9e'), owner);
      for (const x of [0.12, 1.48]) {
        cylinder('alabasta-minaret', 0.22, 0.17, 1.65, [x, 1.48, 0.2], white, 12, owner);
        sphere('minaret-dome', [0.31, 0.29, 0.31], [x, 2.33, 0.2], gold, owner);
        cylinder('minaret-spire', 0.04, 0, 0.29, [x, 2.60, 0.2], gold, 8, owner);
      }
      for (let n = 0; n < 4; n++) house(owner, -1.2 + n * 0.53, 0.9, 0.4, 0.36, sandstone, white);
      palm(owner, 1.65, -0.48, 1.3, 0.13);
      const oasis = cylinder('desert-oasis', 0.85, 0.85, 0.025, [-0.9, 0.66, 0.53], turquoise, 32, owner); oasis.scaling.z = 0.65;
    } else if (landmark.id === 'water-seven') {
      for (let tier = 0; tier < 3; tier++) {
        const r = 1.98 - tier * 0.47, y = 0.68 + tier * 0.59;
        cylinder('water-seven-circular-city', r * 2, r * 2, 0.54, [0, y, 0], mat('water-seven-stone', '#dcb987'), 40, owner);
        ring('water-seven-circular-canal', r - 0.12, y + 0.30, turquoise, owner, 0.13);
        for (let n = 0; n < 7; n++) {
          const a = n * TAU / 7 + tier * 0.31;
          house(owner, Math.cos(a) * (r - 0.40), Math.sin(a) * (r - 0.40), 0.34 + (n % 2) * 0.09, 0.40, n % 3 === 0 ? mat('water-seven-peach', '#e8a782') : white, n % 2 ? red : mat('water-seven-blue-roof', '#508ba3'), y + 0.27);
        }
      }
      cylinder('water-seven-fountain-column', 0.34, 0.24, 1.0, [0, 2.6, 0], white, 20, owner);
      cylinder('water-seven-fountain-bowl', 0.46, 1.04, 0.23, [0, 3.02, 0], white, 24, owner);
      cylinder('water-seven-fountain-water', 0.99, 0.99, 0.03, [0, 3.15, 0], turquoise, 24, owner);
      for (const x of [-0.30, 0.30]) tube('water-seven-waterfall', [[x, 2.33, 1.00], [x, 1.1, 1.65], [x, 0.16, 2.06]], 0.085, turquoise, owner);
      box('water-seven-canal-bridge', [0.95, 0.13, 0.39], [0, 0.6, 2.08], white, owner);
      for (const x of [-0.42, 0.42]) box('water-seven-bridge-pillar', [0.12, 0.7, 0.24], [x, 0.25, 2.08], white, owner);
      tube('sea-train-track', [[0, 0.02, -2.15], [0.3, 0.02, -3.15], [1.3, 0.02, -4.15], [3.4, 0.02, -4.55]], 0.028, wood, owner);
    } else if (landmark.id === 'enies-lobby') {
      const gate = mat('justice-stone', '#cadad4');
      for (const x of [-0.92, 0.92]) { cylinder('justice-gate-tower', 0.59, 0.59, 3.05, [x, 2.08, 0], gate, 12, owner); cylinder('justice-gate-crown', 0.79, 0.66, 0.28, [x, 3.68, 0], white, 12, owner); }
      box('gates-of-justice', [1.56, 2.40, 0.22], [0, 1.85, -0.03], gate, owner);
      box('justice-gate-center-seam', [0.025, 2.33, 0.027], [0, 1.86, 0.094], navy, owner);
      box('justice-gate-top', [2.4, 0.34, 0.50], [0, 3.22, 0], white, owner);
      for (const x of [-0.40, 0.40]) for (const y of [1.35, 2.27]) box('justice-gate-panel', [0.55, 0.68, 0.034], [x, y, 0.10], white, owner);
      cylinder('justice-emblem', 0.60, 0.60, 0.04, [0, 2.89, 0.28], gold, 24, owner).rotation.x = Math.PI / 2;
      box('enies-lobby-bridge', [0.71, 0.16, 2.2], [0, 0.50, 1.4], gate, owner);
    } else if (landmark.id === 'sabaody') {
      const bark = mat('mangrove-bark', '#ba9877');
      for (const [x, z, h] of [[-1.15, -0.2, 3.2], [0.4, -0.50, 3.7], [1.15, 0.55, 2.65]]) {
        cylinder('yarukiman-mangrove', 0.62, 0.38, h, [x, 0.6 + h / 2, z], bark, 12, owner);
        for (let n = 0; n < 5; n++) { const a = n / 5 * TAU; tube('mangrove-arching-root', [[x, 1.75, z], [x + Math.cos(a) * 0.45, 0.84, z + Math.sin(a) * 0.45], [x + Math.cos(a) * 0.74, 0.5, z + Math.sin(a) * 0.74]], 0.11, bark, owner); }
        sphere('mangrove-canopy', [2.1, 1.02, 1.85], [x, h + 0.65, z], leafLight, owner);
        sphere('mangrove-canopy', [1.47, 0.91, 1.4], [x - 0.3, h + 1.02, z + 0.12], leaf, owner);
      }
      house(owner, -0.15, 0.90, 0.61, 0.64, white, red);
    } else if (landmark.id === 'marineford') {
      cylinder('marineford-fortress-island', 3.52, 3.25, 0.60, [0, 0.75, 0], white, 32, owner);
      pagoda(owner, 0, -0.10, 1.07, 0.9, 3);
      for (const x of [-1.3, 1.3]) {
        cylinder('marineford-gun-tower', 0.61, 0.61, 1.10, [x, 1.10, 0.58], white, 12, owner);
        cylinder('marineford-tower-cap', 0.74, 0.74, 0.14, [x, 1.71, 0.58], navy, 12, owner);
        const cannon = cylinder('marineford-cannon', 0.16, 0.12, 0.62, [x, 1.60, 0.95], navy, 8, owner); cannon.rotation.x = Math.PI / 2;
        cylinder('marine-flag-pole', 0.04, 0.04, 1.30, [x, 2.20, 0.5], wood, 8, owner);
        box('marine-banner', [0.48, 0.32, 0.022], [x + 0.25, 2.65, 0.5], snow, owner);
      }
      tube('marine-emblem', [[-0.38, 1.45, 0.58], [-0.17, 1.32, 0.60], [0, 1.60, 0.60], [0.17, 1.32, 0.60], [0.38, 1.45, 0.58]], 0.034, navy, owner);
    } else if (landmark.id === 'wano') {
      pagoda(owner, 0.3, -0.40, 0.61, 1.0, 3);
      for (const [x, z, h] of [[-1.25, -0.4, 1.25], [-1.1, 0.8, 1.0], [1.32, 0.52, 1.18]]) broadTree(owner, x, z, h, pink);
      for (const x of [-0.62, 0.25]) cylinder('torii-post', 0.12, 0.12, 1.28, [x, 1.16, 1.04], red, 10, owner);
      box('torii-crossbar', [1.31, 0.15, 0.20], [-0.18, 1.72, 1.04], red, owner);
      box('torii-top', [1.52, 0.13, 0.24], [-0.18, 1.92, 1.04], navy, owner);
      tube('wano-canal', [[-1.6, 0.63, 0.35], [-0.4, 0.63, 0.20], [0.65, 0.63, 0.47], [1.65, 0.43, 0.73]], 0.13, turquoise, owner);
      box('wano-red-bridge', [0.36, 0.12, 0.94], [-0.42, 0.85, 0.25], red, owner);
    } else if (landmark.id === 'whole-cake') {
      const icing = mat('pink-icing', '#f2b6c1'), cake = mat('cake-sponge', '#edcf99'), berry = mat('strawberry', '#c84b61');
      for (let tier = 0; tier < 4; tier++) {
        const radius = 1.44 - tier * 0.29, y = 0.65 + tier * 0.66;
        cylinder('whole-cake-tier', radius * 2, radius * 2, 0.63, [0, y + 0.31, -0.22], tier % 2 ? icing : cake, 40, owner);
        cylinder('whole-cake-frosting', radius * 2.08, radius * 2.08, 0.11, [0, y + 0.63, -0.22], white, 40, owner);
        for (let n = 0; n < 12; n++) { const a = n * TAU / 12; sphere('icing-scallop', [0.25, 0.27, 0.21], [Math.cos(a) * radius, y + 0.49, -0.22 + Math.sin(a) * radius], white, owner); }
      }
      for (const x of [-0.28, 0, 0.28]) { cylinder('cake-candle', 0.07, 0.07, 0.60, [x, 3.53, -0.22], red, 8, owner); sphere('candle-flame', [0.10, 0.20, 0.10], [x, 3.92, -0.22], mat('candle-glow', '#ffe496', 0.6), owner); }
      for (const [x, z] of [[-1.65, 0.2], [1.48, 0.48], [0.95, 1.20]]) {
        cylinder('candy-cane-stick', 0.09, 0.09, 1.37, [x, 1.21, z], white, 8, owner);
        cylinder('candy-cane-stripe', 0.11, 0.11, 0.18, [x, 1.31, z], red, 8, owner);
        sphere('lollipop', [0.58, 0.58, 0.22], [x, 1.97, z], pink, owner);
        sphere('lollipop-center', [0.30, 0.30, 0.025], [x, 1.97, z + 0.115], white, owner);
      }
      for (const x of [-0.60, 0.15, 0.9]) sphere('giant-strawberry', [0.32, 0.41, 0.32], [x, 0.8, 1.20], berry, owner);
    } else if (landmark.id === 'jaya') {
      palm(owner, -0.70, -0.12, 1.65, -0.16); palm(owner, 0.71, -0.44, 1.34, 0.18);
      house(owner, 0.08, 0.32, 0.72, 0.66, white, red);
      cylinder('jaya-ancient-column', 0.26, 0.21, 1.08, [-0.51, 1.08, 0.38], sand, 9, owner);
      box('jaya-ancient-ruin', [0.56, 0.16, 0.36], [-0.51, 1.67, 0.38], sand, owner);
    } else {
      const poneglyph = mat('road-poneglyph', '#834c68');
      box('road-poneglyph', [0.72, 1.10, 0.67], [0, 1.17, 0], poneglyph, owner);
      box('poneglyph-stone-plinth', [1.1, 0.15, 1.0], [0, 0.68, 0], mat('ancient-stone', '#8a9e92'), owner);
      for (let row = 0; row < 6; row++) for (let col = 0; col < 5; col++) {
        box('poneglyph-inscription', [0.049, 0.014, 0.014], [-0.25 + col * 0.12, 0.82 + row * 0.15, 0.341], mat('poneglyph-glyph', '#d798b0', 0.14), owner);
        if ((row + col) % 2) box('poneglyph-inscription', [0.012, 0.05, 0.014], [-0.24 + col * 0.12, 0.84 + row * 0.15, 0.342], mat('poneglyph-glyph', '#d798b0', 0.14), owner);
      }
      palm(owner, -0.68, -0.16, 1.45, -0.21); palm(owner, 0.65, -0.40, 1.25, 0.16);
    }
    }
    if (!detailed) {
      const art = new TransformNode(`${landmark.id}-facing`, scene); art.parent = owner;
      for (const child of owner.getChildren(undefined, true)) if (child !== art) child.parent = art;
      art.rotation.y = islandArtworkRotation(landmark.id);
    }
    if (landmark.id === 'sabaody') {
      const bubbleMat = mat('sabaody-bubble', '#b8f8e9', 0.30, 0.24); bubbleMat.specularColor = Color3.White(); bubbleMat.specularPower = 128;
      for (let n = 0; n < 13; n++) {
        const x = (random() - 0.5) * 5, z = (random() - 0.5) * 3.5, y = 1.1 + random() * 4.6, size = 0.24 + random() * 0.52;
        const bubble = sphere('floating-resin-bubble', [size, size, size], [x, y, z], bubbleMat, owner, true);
        drifting.push({ node: bubble, y, phase: random() * TAU, amount: 0.16 });
        sphere('bubble-highlight', [0.15, 0.23, 0.09], [-0.25, 0.24, 0.33], snow, bubble, true);
      }
    }
    const harbor = GRAND_LINE_HARBORS.find(item => item.id === landmark.id)!;
    const pier = new TransformNode(`${landmark.id}-harbor-pier`, scene); pier.parent = owner;
    const shoreDistance = landmark.radius * (harbor.direction.x ? 1 : 0.80);
    pier.position.set(harbor.direction.x * (shoreDistance + 0.24), 0, harbor.direction.z * (shoreDistance + 0.24));
    pier.rotation.y = Math.atan2(harbor.direction.x, harbor.direction.z);
    // A longer jetty reaches the broadside berth without changing ship routes.
    // Its fixed end leaves bow clearance; the boarding plank appears only at rest.
    const jettyEnd = landmark.radius + 2.35 - (shoreDistance + 0.24) - 1.45;
    const jettyStart = -0.49, jettyLength = jettyEnd - jettyStart;
    box('harbor-timber-deck', [0.65, 0.12, jettyLength], [0, 0.56, (jettyStart + jettyEnd) / 2], wood, pier);
    for (let z = jettyStart + 0.06; z < jettyEnd; z += 0.145) box('harbor-deck-plank', [0.67, 0.04, 0.018], [0, 0.63, z], sand, pier);
    box('harbor-berthing-head', [1.46, 0.13, 0.32], [0, 0.56, jettyEnd - 0.16], wood, pier);
    for (const x of [-0.64, 0.64]) {
      cylinder('harbor-berthing-piling', 0.12, 0.12, 0.98, [x, 0.36, jettyEnd - 0.14], wood, 8, pier);
      cylinder('harbor-berthing-cap', 0.17, 0.17, 0.09, [x, 0.90, jettyEnd - 0.14], sand, 8, pier);
      sphere('harbor-berthing-fender', [0.15, 0.33, 0.18], [x, 0.35, jettyEnd + 0.02], navy, pier);
    }
    cylinder('harbor-lantern-post', 0.045, 0.045, 0.66, [0.64, 1.14, jettyEnd - 0.14], navy, 8, pier);
    sphere('harbor-lantern', [0.15, 0.20, 0.15], [0.64, 1.51, jettyEnd - 0.14], mat('harbor-lantern-glow', '#fff0b3', 0.6), pier);
    const plaza = GRAND_LINE_CREW_PLAZAS[GRAND_LINE_LANDMARKS.indexOf(landmark)];
    const workPlaza = new TransformNode(`${landmark.id}-crew-work-plaza`, scene); workPlaza.parent = owner;
    workPlaza.position.set(plaza.x - landmark.x, 0, plaza.z - landmark.z); workPlaza.rotation.y = plaza.rotation;
    box('shore-work-plaza-base', [plaza.width, 0.10, plaza.depth], [0, plaza.y - 0.07, 0], wood, workPlaza);
    for (let plank = 0; plank < 9; plank++) box('shore-work-plaza-plank', [plaza.width, 0.02, 0.085], [0, plaza.y - 0.01, -0.36 + plank * 0.09], plank % 3 ? wood : sand, workPlaza);
    for (const x of [-0.69, 0.69]) for (const z of [-0.35, 0.35]) {
      cylinder('shore-work-plaza-piling', 0.085, 0.085, plaza.y + 0.12, [x, (plaza.y - 0.12) / 2, z], wood, 8, workPlaza);
      cylinder('shore-work-plaza-piling-cap', 0.11, 0.11, 0.08, [x, plaza.y + 0.04, z], sand, 8, workPlaza);
    }
    // Elevated city rims get visible steps down to the existing landing.
    if (plaza.y > 0.8) for (let step = 0; step < 3; step++) box('plaza-landing-step', [0.62, 0.10, 0.19], [0, plaza.y - 0.13 - step * 0.13, 0.47 + step * 0.12], wood, workPlaza);
    label(landmark.name, landmark.subtitle, [landmark.x, 0.02, landmark.z - landmark.radius * 0.87 - 0.50], landmark.id === 'laugh-tale' ? 3.2 : 4.3);
  }

  // JAXa's impossible upward current leads to the sky island and Shandora's golden bell.
  const sky = new TransformNode('skypiea-cloud-island', scene); sky.parent = root; sky.position.set(-6.624, 6.0, -22.01);
  if (models.has('island_skypiea')) {
    models.add('island_skypiea', { parent: sky, width: 4.1, depth: 3.1, height: 4.2, floor: -0.50 });
  } else {
  cloud(sky, 0, 0, 0, 1.55);
  cloud(sky, -0.45, 0.20, 0.65, 1.10);
  const skyLand = cylinder('skypiea-island', 2.1, 2.1, 0.16, [0, 0.34, 0], sand, 32, sky); skyLand.scaling.z = 0.75;
  for (const x of [-0.40, 0.40]) cylinder('shandora-bell-pillar', 0.18, 0.15, 1.38, [x, 1.02, 0], gold, 12, sky);
  box('shandora-bell-lintel', [1.20, 0.20, 0.33], [0, 1.72, 0], gold, sky);
  cylinder('golden-bell', 0.60, 0.24, 0.61, [0, 1.22, 0], gold, 24, sky);
  cylinder('golden-bell-rim', 0.68, 0.68, 0.07, [0, 0.92, 0], gold, 24, sky);
  sphere('golden-bell-clapper', [0.10, 0.16, 0.10], [0, 0.88, 0], navy, sky);
  palm(sky, 0.80, -0.17, 1.22, 0.15);
  }
  tube('knock-up-stream', [[-6.624, -0.05, -22.01], [-6.574, 2, -21.91], [-6.774, 3.8, -22.01], [-6.624, 6, -22.01]], 0.20, mat('knock-up-stream-water', '#96e8e1', 0.2, 0.50));
  label('SkypiAI', 'LOCAL DREAMS, SKY-HIGH IDEAS', [-6.624, 6.40, -23.71], 4.3);

  // Two Seed Kings guard the windless waters; their silhouettes never enter the shipping lanes.
  for (const [x, z, sign] of [[-16.56, -25, 1], [16.56, 25.2, -1]]) {
    if (models.has('creature_sea_king')) {
      const guardian = new TransformNode(`sea-king-${sign}`, scene); guardian.parent = root; guardian.position.set(x, 0, z);
      models.add('creature_sea_king', { parent: guardian, width: 2.4, depth: 2.0, height: 3.4,
        footprintRadius: 1.2, floor: -0.40, rotation: sign > 0 ? 0.5 : Math.PI + 0.5 });
    } else {
      const monster = mat('sea-king-jade', '#588e68');
      tube('sea-king-neck', [[x, -0.18, z], [x + 0.3, 0.4, z], [x + 0.45, 1.5, z], [x + 0.6, 2.25, z]], 0.28, monster);
      sphere('sea-king-head', [0.9, 0.65, 0.62], [x + 0.68, 2.28, z], monster);
    }
    for (let n = 0; n < 3; n++) {
      const loop = ring('sea-king-wake', 0.65 + n * 0.32, -0.01, foam); loop.position.x = x; loop.position.z = z; loop.scaling.z = 0.5;
    }
  }
  // Low, wispy clouds and seabirds give depth without obscuring the fleet.
  for (const [x, y, z, s] of [[-19.32, 7.6, -28.36, 1.7], [11.73, 7.8, -27.59, 1.3], [30.36, 6.4, -19.22, 1.8]]) {
    const puff = new TransformNode('slow-drifting-cloud', scene); puff.parent = root; puff.position.set(x, y, z);
    cloud(puff, 0, 0, 0, s, true); drifting.push({ node: puff, y, phase: random() * TAU, amount: 0.12 });
  }
  // Fine log-pose route marks are part of the cartography, beneath the animated vessels.
  const routeMat = mat('log-pose-route', '#a4e2c7', 0.08, 0.37); routeMat.disableLighting = true;
  for (let n = 0; n < 67; n++) {
    const x = -25 + n * 0.72, z = Math.sin((x + 25) * 0.11) * 0.67 - 0.40;
    const dash = box('log-pose-route-dash', [0.25, 0.01, 0.027], [x, -0.037, z], routeMat); dash.rotation.y = -Math.cos((x + 25) * 0.11) * 0.075;
  }
  const compass = new DynamicTexture('grand-line-compass', { width: 512, height: 512 }, scene, true);
  compass.anisotropicFilteringLevel = 8;
  const ctx = compass.getContext() as CanvasRenderingContext2D; ctx.clearRect(0, 0, 512, 512); ctx.translate(256, 256);
  ctx.strokeStyle = 'rgba(194,239,207,0.46)'; ctx.fillStyle = 'rgba(194,239,207,0.46)'; ctx.lineWidth = 2;
  for (const r of [133, 145]) { ctx.beginPath(); ctx.arc(0, 0, r, 0, TAU); ctx.stroke(); }
  for (let n = 0; n < 8; n++) {
    ctx.save(); ctx.rotate(n * Math.PI / 4); const length = n % 2 ? 104 : 137;
    ctx.beginPath(); ctx.moveTo(0, -length); ctx.lineTo(20, 0); ctx.lineTo(0, 25); ctx.closePath(); ctx.fill();
    ctx.beginPath(); ctx.moveTo(0, -length); ctx.lineTo(-20, 0); ctx.lineTo(0, 25); ctx.closePath(); ctx.stroke(); ctx.restore();
  }
  ctx.font = '30px Georgia, serif'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
  ctx.fillText('N', 0, -176); ctx.fillText('S', 0, 176); ctx.fillText('E', 178, 0); ctx.fillText('W', -178, 0);
  compass.update(); compass.hasAlpha = true; textures.push(compass);
  const compassMat = new StandardMaterial('compass-chart-ink', scene); compassMat.diffuseTexture = compass; compassMat.emissiveTexture = compass; compassMat.disableLighting = true; compassMat.useAlphaFromDiffuseTexture = true; compassMat.backFaceCulling = false; materials.set('compass', compassMat);
  const compassPlane = finish(MeshBuilder.CreatePlane('ocean-compass-rose', { size: 6.4 }, scene), compassMat, [31.74, -0.02, 21.7], root, true); compassPlane.rotation.x = Math.PI / 2;

  // Opaque static scenery is combined by material to keep a detailed archipelago inexpensive to draw.
  const groups = new Map<string, { material: StandardMaterial; meshes: Mesh[] }>();
  for (const mesh of staticMeshes) {
    const material = mesh.material as StandardMaterial;
    if (material.alpha < 1) continue;
    mesh.computeWorldMatrix(true);
    const key = `${material.uniqueId}:${mesh.getVerticesDataKinds().sort().join(',')}`;
    const group = groups.get(key) ?? { material, meshes: [] }; group.meshes.push(mesh); groups.set(key, group);
  }
  for (const { material, meshes } of groups.values()) {
    const merged = Mesh.MergeMeshes(meshes, true, true, undefined, false, false);
    if (merged) {
      merged.name = `grand-line-static-${material.name}`; merged.parent = root; merged.material = material;
      merged.isPickable = false; merged.receiveShadows = true; merged.freezeWorldMatrix();
      shadow.addShadowCaster(merged);
    }
  }
  return {
    selectCreature: id => { if (id !== 'laboon' || !laboon) return false; laboon.select(); return true; },
    handleCreatureKey: (key, repeat) => laboon?.handleKey(key, repeat) ?? false,
    installAsset: (type, container) => models.install(type, container),
    update(elapsed, reducedMotion) {
      models.update(elapsed, reducedMotion);
      laboon?.update(elapsed, reducedMotion);
      waterfallMist?.update(elapsed, reducedMotion);
      oceanWater.update(elapsed, reducedMotion);
      for (const item of drifting) item.node.position.y = item.y + (reducedMotion ? 0 : Math.sin(elapsed * 0.34 + item.phase) * item.amount);
    },
    dispose() {
      laboon?.dispose(); waterfallMist?.dispose(); models.dispose(); oceanWater.dispose(); root.dispose(false, false);
      for (const texture of textures) texture.dispose();
      for (const material of materials.values()) material.dispose();
    },
  };
}
