import { Engine } from '@babylonjs/core/Engines/engine';
import { Scene } from '@babylonjs/core/scene';
import { ArcRotateCamera } from '@babylonjs/core/Cameras/arcRotateCamera';
import { Vector3, Matrix } from '@babylonjs/core/Maths/math.vector';
import { Color3, Color4 } from '@babylonjs/core/Maths/math.color';
import { HemisphericLight } from '@babylonjs/core/Lights/hemisphericLight';
import { DirectionalLight } from '@babylonjs/core/Lights/directionalLight';
import { StandardMaterial } from '@babylonjs/core/Materials/standardMaterial';
import { MeshBuilder } from '@babylonjs/core/Meshes/meshBuilder';
import { Mesh } from '@babylonjs/core/Meshes/mesh';
import { TransformNode } from '@babylonjs/core/Meshes/transformNode';
import { LoadAssetContainerAsync } from '@babylonjs/core/Loading/sceneLoader';
import type { AssetContainer, InstantiatedEntries } from '@babylonjs/core/assetContainer';
import type { AnimationGroup } from '@babylonjs/core/Animations/animationGroup';
import '@babylonjs/core/Animations/animatable';
import '@babylonjs/core/Culling/ray';
import '@babylonjs/loaders/glTF';
import { ShadowGenerator } from '@babylonjs/core/Lights/Shadows/shadowGenerator';
import { STATUS_META, isClickGesture, labelIsUnobscured } from './state';
import type { Agent, ScreenPoint } from './state';
import { RESIDENT_ASSET_TYPES, DEFAULT_STATIONS } from './theme';
import type { Theme, AssetType, ResidentAssetType, PropAssetType, Placement } from './theme';
import { createResidentMotion, residentAssetForID, residentSeed, resolveResidentSpacing, stationObstacle, statusCanWander, stepResidentMotion, themeNavigation } from './residentMotion';
import type { NavigationMap, ResidentMotion } from './residentMotion';

type Actor = { root: TransformNode; fallback: TransformNode; appearance: ResidentAssetType; model?: InstantiatedEntries; loadedAppearance?: ResidentAssetType; idle?: AnimationGroup; walk?: AnimationGroup; walking: boolean; body?: TransformNode; leftLeg?: TransformNode; rightLeg?: TransformNode };
type Resident = { agent: Agent; actor: Actor; label: HTMLDivElement; ring: Mesh; home: Placement; motion: ResidentMotion; id: string; phase: number };
type Callbacks = { onSelect: (id: string) => void; onAssetFailure: () => void; onAssetProgress: (completed: number, total: number) => void; onGraphicsFailure: () => void };

export class OutpostWorld {
  private engine: Engine;
  private scene: Scene;
  private camera: ArcRotateCamera;
  private shadow: ShadowGenerator;
  private residents: Resident[] = [];
  private stations: TransformNode[] = [];
  private containers = new Map<AssetType, AssetContainer>();
  private materials = new Map<string, StandardMaterial>();
  private appearanceAssignments = new Map<string, ResidentAssetType>();
  private navigation: NavigationMap;
  private visible = true;
  private disposed = false;
  private lastFrame = 0;
  private elapsed = 0;
  private reducedMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;
  private hoveredID?: string;
  private selectedID?: string;
  private cleanups: (() => void)[] = [];
  private mapRoot: TransformNode;
  private labels: HTMLElement;
  private hudOverlays: HTMLElement[];
  private stars?: TransformNode;

  constructor(private canvas: HTMLCanvasElement, private theme: Theme, private callbacks: Callbacks) {
    this.engine = new Engine(canvas, true, { preserveDrawingBuffer: false, stencil: true, powerPreference: 'low-power', audioEngine: false }, true);
    this.engine.setHardwareScalingLevel(Math.max(1, (window.devicePixelRatio || 1) / 1.4));
    this.scene = new Scene(this.engine);
    this.scene.clearColor = Color4.FromColor3(Color3.FromHexString(theme.palette.sky), 1);
    this.scene.ambientColor = new Color3(0.25, 0.34, 0.36);
    this.scene.fogMode = Scene.FOGMODE_EXP2;
    this.scene.fogColor = Color3.FromHexString(theme.palette.sky).scale(1.9);
    this.scene.fogDensity = 0.0045;
    this.scene.skipPointerMovePicking = true;
    this.scene.autoClear = true;
    this.labels = document.getElementById('agent-labels')!;
    this.hudOverlays = Array.from(document.querySelectorAll<HTMLElement>('.roster-panel, .world-header, .world-footer, .coordinate-label, #theme-popover, #selection-note, #asset-loading, #asset-notice, #graphics-fallback'));
    this.mapRoot = new TransformNode('outpost', this.scene);
    this.navigation = themeNavigation(theme, []);

    this.camera = new ArcRotateCamera('overview-camera', Math.PI / 2 - 0.3, 1.01, 33, new Vector3(0, 0.9, -0.4), this.scene);
    this.camera.lowerRadiusLimit = 14;
    this.camera.upperRadiusLimit = 46;
    this.camera.lowerBetaLimit = 0.35;
    this.camera.upperBetaLimit = 1.16;
    this.camera.minZ = 0.2;
    this.camera.maxZ = 250;
    this.camera.wheelPrecision = 22;
    this.camera.panningSensibility = 0;
    this.camera.angularSensibilityX = 620;
    this.camera.angularSensibilityY = 620;
    this.camera.inertia = this.reducedMotion ? 0 : 0.75;
    this.camera.attachControl(canvas, true);
    this.camera.inputs.removeByType('ArcRotateCameraKeyboardMoveInput');

    const ambient = new HemisphericLight('sky-light', new Vector3(0.2, 1, -0.4), this.scene);
    ambient.intensity = 0.65;
    ambient.diffuse = new Color3(0.85, 0.96, 1);
    ambient.groundColor = new Color3(0.24, 0.34, 0.37);
    const sun = new DirectionalLight('sunrise', new Vector3(-0.5, -1, 0.5), this.scene);
    sun.position = new Vector3(14, 24, -17);
    sun.intensity = 1.0;
    sun.diffuse = new Color3(1, 0.9, 0.74);
    this.shadow = new ShadowGenerator(1024, sun);
    this.shadow.usePercentageCloserFiltering = true;
    this.shadow.filteringQuality = ShadowGenerator.QUALITY_LOW;
    this.shadow.bias = 0.001;
    this.shadow.normalBias = 0.02;
    this.shadow.setDarkness(0.28);

    this.buildMap();
    this.buildInput();
    this.engine.runRenderLoop(this.render);
    void this.loadAssets();
  }

  private material(name: string, color: string, emission = 0, alpha = 1): StandardMaterial {
    const key = `${name}:${color}:${emission}:${alpha}`;
    const existing = this.materials.get(key);
    if (existing) return existing;
    const material = new StandardMaterial(name, this.scene);
    material.diffuseColor = Color3.FromHexString(color);
    material.specularColor = new Color3(0.13, 0.17, 0.17);
    material.emissiveColor = material.diffuseColor.scale(emission);
    material.alpha = alpha;
    this.materials.set(key, material);
    return material;
  }

  private box(name: string, dimensions: [number, number, number], position: [number, number, number], material: StandardMaterial, parent = this.mapRoot): Mesh {
    const mesh = MeshBuilder.CreateBox(name, { width: dimensions[0], height: dimensions[1], depth: dimensions[2] }, this.scene);
    mesh.position.set(...position);
    mesh.material = material;
    mesh.parent = parent;
    mesh.receiveShadows = true;
    mesh.isPickable = false;
    return mesh;
  }

  private cylinder(name: string, diameter: number, height: number, y: number, material: StandardMaterial, sides = 80, parent = this.mapRoot): Mesh {
    const mesh = MeshBuilder.CreateCylinder(name, { diameter, height, tessellation: sides }, this.scene);
    mesh.position.y = y;
    mesh.material = material;
    mesh.parent = parent;
    mesh.receiveShadows = true;
    mesh.isPickable = false;
    return mesh;
  }

  private ring(name: string, diameter: number, thickness: number, y: number, material: StandardMaterial, parent = this.mapRoot): Mesh {
    const mesh = MeshBuilder.CreateTorus(name, { diameter, thickness, tessellation: 80 }, this.scene);
    mesh.position.y = y;
    mesh.material = material;
    mesh.parent = parent;
    mesh.isPickable = false;
    return mesh;
  }

  private buildMap(): void {
    const radius = this.theme.layout.radius;
    const moss = this.material('campus-lawn', '#526f60');
    const grass = this.material('commons-grass', '#6f936a');
    const dark = this.material('navy-alloy', '#233d48');
    const trim = this.material('warm-ceramic', '#c3bca0');
    const path = this.material('promenade-stone', '#9da99a');
    const wood = this.material('warm-timber', '#8f7054');
    const woodLight = this.material('warm-timber-light', '#a18461');
    const light = this.material('guide-light', this.theme.palette.accent, 0.65);
    const copper = this.material('brushed-copper', '#bd8c65');
    const rock = this.material('bedrock', '#263d43');
    const base = MeshBuilder.CreateCylinder('floating-campus-foundation', { diameterTop: radius * 2 + 1, diameterBottom: radius * 1.65, height: 3.8, tessellation: 13, subdivisions: 2 }, this.scene);
    base.position.y = -2.5;
    base.material = rock;
    base.convertToFlatShadedMesh();
    base.parent = this.mapRoot;
    base.isPickable = false;
    this.cylinder('foundation-rim', radius * 2 + 0.65, 0.65, -0.39, dark, 80);
    this.cylinder('campus-ground', radius * 2, 0.14, -0.08, moss, 80);
    this.ring('outer-copper-trim', radius * 2 - 0.24, 0.09, 0.03, copper);
    this.ring('lower-rim-light', radius * 2 + 0.2, 0.065, -0.57, light);

    // A broad promenade joins three work districts around a planted commons.
    this.cylinder('commons-promenade', 16.4, 0.075, -0.005, path);
    this.cylinder('commons-curb', 10.75, 0.17, 0.055, trim);
    this.cylinder('commons-lawn', 10.4, 0.16, 0.085, grass);
    this.ring('commons-guide-light', 10.65, 0.035, 0.17, light);
    this.ring('promenade-outer-border', 16.1, 0.035, 0.038, trim);
    const districts = [
      { name: 'research', x: 0, z: -10.75, width: 11.9, depth: 3.85 },
      { name: 'design', x: -10.15, z: -0.7, width: 3.9, depth: 13.25 },
      { name: 'engineering', x: 10.15, z: -0.7, width: 3.9, depth: 13.25 },
    ];
    for (const district of districts) {
      this.box(`${district.name}-deck-frame`, [district.width + 0.18, 0.15, district.depth + 0.18], [district.x, -0.025, district.z], copper);
      this.box(`${district.name}-deck`, [district.width, 0.15, district.depth], [district.x, 0, district.z], wood);
      const strips = Math.floor(district.depth / 0.27);
      for (let strip = 0; strip < strips; strip++) this.box(`${district.name}-plank-${strip}`, [district.width - 0.12, 0.012, 0.018], [district.x, 0.081, district.z - district.depth / 2 + 0.16 + strip * 0.27], strip % 4 === 0 ? woodLight : dark);
    }
    // Short radial connections keep the real navigation routes visually clear.
    for (const [x, z, width, depth] of [[0, -8.5, 5.4, 3.2], [-8.6, 0, 3.2, 6.8], [8.6, 0, 3.2, 6.8]] as number[][]) {
      this.box('district-connection', [width, 0.055, depth], [x, 0.005, z], path);
    }
    for (const x of [-4.9, 4.9]) {
      this.box('lounge-deck-border', [5.0, 0.12, 3.9], [x, -0.015, 9.1], copper);
      this.box('lounge-deck', [4.84, 0.13, 3.74], [x, 0.01, 9.1], wood);
      for (let strip = 0; strip < 14; strip++) this.box('lounge-deck-plank', [4.7, 0.012, 0.018], [x, 0.082, 7.35 + strip * 0.26], dark);
    }
    this.box('south-approach', [3.0, 0.06, 5.8], [0, 0.01, 10.6], path);
    this.box('campus-inlay-long', [0.18, 0.012, 1.05], [-0.28, 0.047, 11.6], dark);
    this.box('campus-inlay-foot', [0.75, 0.012, 0.18], [0, 0.047, 12.04], dark);
    this.buildCommons();

    for (let index = 0; index < 20; index++) {
      const angle = index * Math.PI * 2 / 20;
      const x = Math.sin(angle) * (radius - 0.18), z = Math.cos(angle) * (radius - 0.18);
      const bollard = this.box(`rim-bollard-${index}`, [0.15, 0.48, 0.15], [x, 0.23, z], dark);
      bollard.rotation.y = angle;
      this.box(`rim-lamp-${index}`, [0.12, 0.09, 0.12], [x, 0.49, z], light);
    }
    for (const prop of this.theme.layout.props) this.createPropFallback(prop.asset, prop.x, prop.z, prop.rotation || 0);
    const plankGroups = new Map<StandardMaterial, Mesh[]>();
    for (const mesh of this.mapRoot.getChildMeshes(true)) {
      if (!(mesh instanceof Mesh) || !mesh.name.includes('plank') || !(mesh.material instanceof StandardMaterial)) continue;
      const group = plankGroups.get(mesh.material) ?? []; group.push(mesh); plankGroups.set(mesh.material, group);
    }
    for (const [material, planks] of plankGroups) {
      const merged = Mesh.MergeMeshes(planks, true, true);
      if (merged) { merged.name = 'campus-deck-planks'; merged.material = material; merged.isPickable = false; merged.receiveShadows = true; }
    }
    this.buildBackground();
  }

  private buildCommons(): void {
    const stone = this.material('pond-ceramic', '#c7c1a8');
    const pond = this.cylinder('pond-rim', 4.1, 0.22, 0.2, stone, 48);
    pond.scaling.set(1.1, 1, 0.72); pond.position.x = 1.2; pond.position.z = 1.1;
    const water = this.cylinder('pond-water', 3.77, 0.055, 0.305, this.material('garden-water', '#3f9f99', 0.13), 48);
    water.scaling.set(1.1, 1, 0.72); water.position.x = 1.2; water.position.z = 1.1;
    for (let index = 0; index < 3; index++) {
      const ripple = this.ring(`pond-ripple-${index}`, 0.5 + index * 0.48, 0.012, 0.34, this.material('water-ripple', '#89c9b7', 0.18));
      ripple.scaling.z = 0.72; ripple.position.x = 1.0; ripple.position.z = 1.2;
    }
    const wood = this.material('garden-bench-wood', '#a38461');
    const iron = this.material('garden-bench-frame', '#324e4e');
    for (const [x, z, angle] of [[-2.2, 3.25, -0.4], [3.2, -1.6, 0.8]]) {
      const bench = new TransformNode('commons-bench', this.scene);
      bench.position.set(x, 0.17, z); bench.rotation.y = angle;
      this.box('bench-seat', [1.55, 0.1, 0.48], [0, 0.37, 0], wood, bench);
      this.box('bench-back', [1.55, 0.35, 0.08], [0, 0.61, -0.19], wood, bench);
      for (const side of [-0.58, 0.58]) this.box('bench-leg', [0.1, 0.4, 0.43], [side, 0.16, 0], iron, bench);
      for (const mesh of bench.getChildMeshes()) this.shadow.addShadowCaster(mesh);
    }
    this.createGardenTree(-1.75, -1.35, 4.25, '#699b78');
    this.createGardenTree(2.25, -2.55, 2.7, '#81a979');
    this.createGardenTree(-3.1, 1.15, 2.35, '#ab987e');
    this.createGardenTree(2.85, 2.7, 1.8, '#729878');
    const leaves = ['#628966', '#8b9f6c', '#557e65', '#89a683'];
    for (let index = 0; index < 31; index++) {
      const angle = index * 2.39996;
      const radius = 3.6 + (index % 3) * 0.18;
      const x = Math.sin(angle) * radius, z = Math.cos(angle) * radius;
      const shrub = MeshBuilder.CreateIcoSphere(`commons-shrub-${index}`, { radius: 0.3 + (index % 3) * 0.06, subdivisions: 1, flat: true }, this.scene);
      shrub.position.set(x, 0.34, z); shrub.scaling.set(1.2, 0.68, 1);
      shrub.material = this.material('commons-shrub', leaves[index % leaves.length]); shrub.isPickable = false;
      this.shadow.addShadowCaster(shrub);
      if (index % 4 === 0) {
        const bloom = MeshBuilder.CreateIcoSphere(`commons-bloom-${index}`, { radius: 0.12, subdivisions: 1, flat: true }, this.scene);
        bloom.position.set(x, 0.64, z); bloom.material = this.material('commons-flowers', index % 8 === 0 ? '#e3ae8f' : '#b2d4a4', 0.08); bloom.isPickable = false;
      }
    }
  }

  private createGardenTree(x: number, z: number, height: number, color: string, parent?: TransformNode): void {
    const root = new TransformNode('garden-tree', this.scene); root.position.set(x, 0.18, z);
    if (parent) root.parent = parent;
    const trunk = this.cylinder('tree-trunk', height * 0.085, height * 0.64, height * 0.32, this.material('tree-trunk', '#806d57'), 7, root);
    trunk.rotation.z = 0.07;
    this.shadow.addShadowCaster(trunk);
    for (let index = 0; index < 5; index++) {
      const angle = index * 2.39996;
      const crown = MeshBuilder.CreateIcoSphere(`tree-crown-${index}`, { radius: height * (index === 0 ? 0.27 : 0.22), subdivisions: 1, flat: true }, this.scene);
      crown.position.set(index === 0 ? 0 : Math.sin(angle) * height * 0.15, height * (0.63 + (index % 3) * 0.1), index === 0 ? 0 : Math.cos(angle) * height * 0.15);
      crown.scaling.y = 0.9; crown.parent = root; crown.isPickable = false;
      const shade = Color3.FromHexString(color).scale(0.88 + index * 0.055).toHexString();
      crown.material = this.material('tree-leaves', shade); this.shadow.addShadowCaster(crown);
    }
  }

  private buildBackground(): void {
    const rock = this.material('satellite-rock', '#274350');
    for (let index = 0; index < 9; index++) {
      const angle = index * 2.39996;
      const distance = 19 + ((index * 7) % 19);
      const mesh = MeshBuilder.CreatePolyhedron(`orbiting-rock-${index}`, { type: index % 3, size: 0.5 + (index % 4) * 0.4 }, this.scene);
      mesh.position.set(Math.sin(angle) * distance, -4.2 - (index % 5), Math.cos(angle) * distance);
      mesh.rotation.set(index * 0.3, index, 0.7);
      mesh.scaling.y = 1.3;
      mesh.material = rock;
      mesh.isPickable = false;
    }
    const planet = MeshBuilder.CreateSphere('distant-world', { diameter: 24, segments: 32 }, this.scene);
    planet.position.set(36, 19, -65);
    planet.material = this.material('distant-world-surface', '#57797e', 0.25);
    planet.isPickable = false;
    const orbit = this.ring('planet-ring', 33, 1.8, 0, this.material('planet-dust', '#81a1a0', 0.18, 0.23));
    orbit.parent = planet;
    orbit.rotation.set(0.45, 0, -0.35);
    const stars = new TransformNode('constellations', this.scene);
    this.stars = stars;
    const source = MeshBuilder.CreateSphere('star-source', { diameter: 0.09, segments: 3 }, this.scene);
    source.material = this.material('starlight', '#adcac8', 1.2);
    source.isVisible = false;
    for (let index = 0; index < 180; index++) {
      // Deterministic stars: appearance does not change every time a project opens.
      const angle = index * 2.399963;
      const y = 3 + ((index * 31) % 79);
      const r = 90 + ((index * 7) % 50);
      const star = source.createInstance(`star-${index}`);
      star.position.set(Math.sin(angle) * r, y, Math.cos(angle) * r);
      star.scaling.setAll(index % 11 === 0 ? 2 : 0.7 + (index % 4) * 0.2);
      star.isPickable = false;
      star.parent = stars;
    }
  }

  private createPropFallback(type: PropAssetType, x: number, z: number, rotation: number): TransformNode {
    const root = new TransformNode(`prop-${type}-${x}`, this.scene);
    root.position.set(x, 0, z);
    root.rotation.y = rotation;
    root.metadata = { assetType: type, propFallback: true };
    const dark = this.material('navy-alloy', '#233d48');
    const pearl = this.material('pearl-alloy', '#b0bcb4');
    const light = this.material('guide-light', this.theme.palette.accent, 0.9);
    if (type === 'habitat') {
      const building = this.box('habitat-shell', [3.4, 2.3, 2.4], [0, 1.25, 0], pearl, root);
      this.shadow.addShadowCaster(building);
      this.box('habitat-foundation', [3.8, 0.25, 2.7], [0, 0.12, 0], dark, root);
      this.box('habitat-window', [2.8, 0.52, 0.05], [0, 1.53, 1.22], dark, root);
      this.box('habitat-window-light', [2.45, 0.035, 0.065], [0, 1.3, 1.24], light, root);
      this.box('habitat-roof', [3.6, 0.13, 2.6], [0, 2.46, 0], dark, root);
      this.box('habitat-chimney', [0.4, 0.6, 0.4], [-1, 2.78, 0], dark, root);
    } else if (type === 'beacon') {
      this.cylinder('beacon-base', 1.5, 0.22, 0.11, dark, 6, root);
      const tower = this.cylinder('beacon-tower', 0.35, 3.2, 1.8, pearl, 6, root);
      this.shadow.addShadowCaster(tower);
      this.ring('beacon-orbit', 1.15, 0.065, 2.9, light, root);
      this.cylinder('beacon-lamp', 0.45, 0.35, 3.4, light, 6, root);
    } else if (type === 'planter') {
      this.cylinder('planter-pot', 1.35, 0.45, 0.22, pearl, 12, root);
      this.cylinder('planter-soil', 1.2, 0.06, 0.46, this.material('planter-soil', '#5e6850'), 12, root);
      this.createGardenTree(0, 0, 1.0, '#8ca984', root);
    } else if (type === 'lounge') {
      const cushion = this.material('lounge-cushion', '#8ba393');
      for (const side of [-0.53, 0.53]) {
        this.box('lounge-seat', [0.96, 0.24, 0.85], [side, 0.39, 0], cushion, root);
        this.box('lounge-back', [0.96, 0.53, 0.16], [side, 0.59, -0.38], cushion, root);
        this.box('lounge-base', [0.86, 0.24, 0.7], [side, 0.15, 0], dark, root);
      }
      for (const mesh of root.getChildMeshes()) this.shadow.addShadowCaster(mesh);
    } else if (type === 'server') {
      const cabinet = this.box('server-cabinet', [0.9, 1.8, 0.65], [0, 0.9, 0], dark, root);
      this.shadow.addShadowCaster(cabinet);
      this.box('server-cap', [1.0, 0.12, 0.75], [0, 1.86, 0], pearl, root);
      for (let rack = 0; rack < 6; rack++) {
        this.box('server-rack', [0.69, 0.18, 0.05], [0, 0.29 + rack * 0.25, 0.34], pearl, root);
        this.box('server-light', [0.19, 0.035, 0.06], [0.18, 0.29 + rack * 0.25, 0.35], light, root);
      }
    } else {
      const crate = this.box('cargo-crate', [1.2, 0.9, 0.9], [0, 0.45, 0], pearl, root);
      this.shadow.addShadowCaster(crate);
      this.box('cargo-strap', [0.17, 0.95, 0.95], [0, 0.46, 0], dark, root);
      this.box('cargo-indicator', [0.32, 0.12, 0.03], [0.32, 0.64, 0.47], light, root);
    }
    return root;
  }

  private createActor(name: string, accent: string, appearance: ResidentAssetType): Actor {
    const root = new TransformNode(name, this.scene);
    const fallback = new TransformNode(`${name}-fallback`, this.scene);
    fallback.parent = root;
    const pearl = this.material('actor-shell', '#ccd4c6');
    const navy = this.material('actor-joints', '#25414c');
    const color = this.material('actor-accent', accent, 0.2);
    const visor = this.material('actor-visor', '#76d8cd', 0.42);
    const body = new TransformNode(`${name}-body`, this.scene);
    body.parent = fallback;
    const torso = this.box(`${name}-torso`, [0.58, 0.54, 0.34], [0, 0.97, 0], pearl, body);
    this.box(`${name}-belt`, [0.48, 0.1, 0.33], [0, 0.65, 0], navy, body);
    this.box(`${name}-chest`, [0.2, 0.19, 0.06], [0, 1.02, 0.19], color, body);
    const helmet = MeshBuilder.CreateSphere(`${name}-helmet`, { diameter: 0.54, segments: 6 }, this.scene);
    helmet.position.y = 1.48;
    helmet.scaling.set(1, 0.87, 0.86);
    helmet.material = pearl;
    helmet.parent = body;
    this.box(`${name}-visor`, [0.36, 0.14, 0.065], [0, 1.5, 0.225], navy, body);
    this.box(`${name}-eyes`, [0.27, 0.035, 0.07], [0, 1.51, 0.235], visor, body);
    for (const sign of [-1, 1]) {
      this.box(`${name}-arm-${sign}`, [0.17, 0.51, 0.19], [sign * 0.39, 0.89, 0], pearl, body);
      this.box(`${name}-hand-${sign}`, [0.16, 0.15, 0.18], [sign * 0.39, 0.59, 0.025], navy, body);
    }
    const legs = [-1, 1].map(sign => {
      const leg = new TransformNode(`${name}-leg-${sign}`, this.scene);
      leg.parent = fallback;
      leg.position.set(sign * 0.16, 0.6, 0);
      this.box(`${name}-leg-shell-${sign}`, [0.22, 0.4, 0.23], [0, -0.23, 0], pearl, leg);
      this.box(`${name}-boot-${sign}`, [0.25, 0.15, 0.34], [0, -0.52, 0.05], navy, leg);
      return leg;
    });
    this.shadow.addShadowCaster(torso, true);
    for (const mesh of fallback.getChildMeshes()) { this.shadow.addShadowCaster(mesh); mesh.isPickable = true; mesh.metadata = { actorID: name }; }
    return { root, fallback, body, appearance, walking: false, leftLeg: legs[0], rightLeg: legs[1] };
  }

  private createStation(x: number, z: number, rotation: number): TransformNode {
    const root = new TransformNode('workstation', this.scene);
    root.position.set(x, 0, z);
    root.rotation.y = rotation;
    const berth = this.box('workstation-berth', [1.85, 0.035, 2.2], [0, 0.085, 0], this.material('station-berth', '#546c67'), root);
    berth.receiveShadows = true;
    const marking = this.material('berth-markings', '#7ca89f', 0.05);
    this.box('berth-edge-left', [0.035, 0.045, 1.8], [-0.9, 0.11, 0], marking, root);
    this.box('berth-edge-right', [0.035, 0.045, 1.8], [0.9, 0.11, 0], marking, root);
    const container = this.containers.get('station');
    if (container) {
      this.attachModel('station', root, container);
    } else {
      const pearl = this.material('pearl-alloy', '#b0bcb4');
      const navy = this.material('navy-alloy', '#233d48');
      this.box('desk-pedestal', [0.5, 0.8, 0.45], [0, 0.4, 0], navy, root);
      const top = this.box('desk-console', [1.35, 0.18, 0.75], [0, 0.96, 0], pearl, root);
      top.rotation.x = -0.16;
      const glass = this.box('desk-screen', [1.08, 0.04, 0.54], [0, 1.07, 0.015], this.material('console-display', '#6eceba', 0.48), root);
      glass.rotation.x = -0.16;
      this.shadow.addShadowCaster(top);
    }
    return root;
  }

  private attachModel(type: AssetType, parent: TransformNode, container: AssetContainer): InstantiatedEntries {
    for (const mesh of container.meshes) if (mesh instanceof Mesh) mesh.receiveShadows = true;
    const isResident = RESIDENT_ASSET_TYPES.includes(type as ResidentAssetType);
    const instance = container.instantiateModelsToScene(name => `${parent.name}-${name}`, false, { doNotInstantiate: isResident });
    const pivot = new TransformNode(`${parent.name}-model`, this.scene);
    const normalized = new TransformNode(`${parent.name}-normalized`, this.scene);
    for (const root of instance.rootNodes) root.parent = normalized;
    normalized.computeWorldMatrix(true);
    for (const mesh of normalized.getChildMeshes()) mesh.computeWorldMatrix(true);
    // Normalize in isolation before applying the resident's location and facing.
    const bounds = normalized.getHierarchyBoundingVectors(true);
    const height = bounds.max.y - bounds.min.y;
    const scale = height > 0.0001 ? this.theme.heights[type] / height : 1;
    normalized.scaling.setAll(scale);
    normalized.position.set(-(bounds.min.x + bounds.max.x) / 2 * scale, -bounds.min.y * scale, -(bounds.min.z + bounds.max.z) / 2 * scale);
    normalized.parent = pivot;
    pivot.parent = parent;
    pivot.rotation.y = this.theme.rotations[type] || 0;
    for (const mesh of pivot.getChildMeshes()) {
      mesh.isPickable = isResident;
      mesh.metadata = { actorID: isResident ? parent.name : undefined };
      if (mesh instanceof Mesh) mesh.receiveShadows = true;
      this.shadow.addShadowCaster(mesh);
    }
    for (const group of instance.animationGroups) group.stop();
    return instance;
  }

  private upgradeActor(actor: Actor): void {
    const type = this.containers.has(actor.appearance) ? actor.appearance : 'resident';
    const container = this.containers.get(type);
    if (!container || actor.loadedAppearance === type) return;
    try {
      actor.model?.dispose();
      for (const child of [...actor.root.getChildren()]) if (child !== actor.fallback) child.dispose();
      actor.model = this.attachModel(type, actor.root, container);
      actor.loadedAppearance = type;
      actor.fallback.setEnabled(false);
      actor.idle = actor.model.animationGroups.find(group => /idle|standing|breath/i.test(group.name));
      actor.walk = actor.model.animationGroups.find(group => /walk|running|run/i.test(group.name));
      actor.walking = false;
      if (!this.reducedMotion) actor.idle?.start(true);
    } catch { this.callbacks.onAssetFailure(); }
  }

  private async loadAssets(): Promise<void> {
    const entries = Object.entries(this.theme.assets) as [AssetType, string][];
    let completed = 0;
    this.callbacks.onAssetProgress(0, entries.length);
    // Two at once keeps texture upload from monopolizing the native window.
    for (let index = 0; index < entries.length; index += 2) {
      await Promise.all(entries.slice(index, index + 2).map(async ([type, path]) => {
        try {
          const url = new URL(`./themes/${this.theme.id}/${path}`, document.baseURI).href;
          const container = await LoadAssetContainerAsync(url, this.scene, { pluginExtension: '.glb' });
          if (this.disposed) { container.dispose(); return; }
          this.containers.set(type, container);
          if (RESIDENT_ASSET_TYPES.includes(type as ResidentAssetType)) for (const resident of this.residents) this.upgradeActor(resident.actor);
          if (type === 'station') this.rebuildStations();
          if (!RESIDENT_ASSET_TYPES.includes(type as ResidentAssetType) && type !== 'station') {
            for (const node of [...this.scene.transformNodes]) {
              if (node.metadata?.assetType === type && node.metadata?.propFallback) {
                for (const mesh of [...node.getChildMeshes()]) mesh.dispose();
                this.attachModel(type, node, container);
                node.metadata.propFallback = false;
              }
            }
          }
        } catch (error) {
          if (!this.disposed) { console.warn(`Outpost artwork unavailable: ${type}`, error instanceof Error ? error.message : 'load failed'); this.callbacks.onAssetFailure(); }
        } finally {
          completed++;
          if (!this.disposed) this.callbacks.onAssetProgress(completed, entries.length);
        }
      }));
      if (this.disposed) break;
    }
  }

  private rebuildStations(): void {
    for (const station of this.stations) station.dispose();
    this.stations = [];
    for (const resident of this.residents) {
      const center = stationObstacle(resident.home);
      const station = this.createStation(center.x, center.z, (resident.home.rotation ?? 0) + Math.PI);
      this.stations.push(station);
    }
    this.navigation = themeNavigation(this.theme, this.residents.map(resident => resident.home));
  }

  setAgents(agents: Agent[], selectedID?: string): void {
    this.selectedID = selectedID;
    const existingByID = new Map(this.residents.map(resident => [resident.id, resident]));
    const sameResidents = agents.length === this.residents.length && agents.every(agent => existingByID.has(agent.id));
    if (sameResidents) {
      // Reordering profiles must not interrupt their walk or change their desks.
      for (const agent of agents) { const resident = existingByID.get(agent.id)!; resident.agent = agent; this.updateLabel(resident); }
      return;
    }
    for (const resident of this.residents) { resident.actor.model?.dispose(); resident.actor.root.dispose(); resident.ring.dispose(); resident.label.remove(); }
    const appearances = RESIDENT_ASSET_TYPES.filter(type => !!this.theme.assets[type]);
    if (!appearances.length) appearances.push('resident');
    // Balance the initial campus while preserving every existing profile's look
    // when statuses change, profiles reorder, or another sector is visited.
    const counts = new Map(appearances.map(type => [type, 0]));
    for (const appearance of this.appearanceAssignments.values()) if (counts.has(appearance)) counts.set(appearance, counts.get(appearance)! + 1);
    for (const id of agents.map(agent => agent.id).sort()) {
      if (this.appearanceAssignments.has(id)) continue;
      const minimum = Math.min(...counts.values());
      const appearance = residentAssetForID(id, appearances.filter(type => counts.get(type) === minimum));
      this.appearanceAssignments.set(id, appearance);
      counts.set(appearance, counts.get(appearance)! + 1);
    }
    this.residents = agents.map((agent, index) => {
      const placement = this.theme.layout.stations[index] || DEFAULT_STATIONS[index];
      const appearance = this.appearanceAssignments.get(agent.id)!;
      const actor = this.createActor(agent.id, ['#80c6b2', '#d2bb7e', '#d99874', '#a79ed4'][residentSeed(agent.id) % 4], appearance);
      actor.root.position.set(placement.x, 0.075, placement.z);
      actor.root.rotation.y = placement.rotation ?? 0;
      this.upgradeActor(actor);
      const label = document.createElement('div');
      label.className = 'agent-label';
      label.dataset.agentId = agent.id;
      label.dataset.appearance = appearance;
      label.title = `Interact with ${agent.name}`;
      label.addEventListener('click', () => this.callbacks.onSelect(agent.id));
      label.addEventListener('pointerenter', () => this.setHovered(agent.id));
      label.addEventListener('pointerleave', () => this.setHovered(undefined));
      const ring = this.ring(`resident-pad-${agent.id}`, 1.45, 0.032, 0.115, this.material('resident-pad', '#829c96', 0.1));
      ring.position.x = placement.x; ring.position.z = placement.z;
      const resident = { agent, actor, label, ring, home: placement, motion: createResidentMotion(agent.id, placement), id: agent.id, phase: index * 1.5 };
      this.labels.append(label);
      this.updateLabel(resident);
      return resident;
    });
    this.rebuildStations();
    this.setHovered(undefined);
  }

  private updateLabel(resident: Resident): void {
    const meta = STATUS_META[resident.agent.status];
    resident.label.replaceChildren();
    const inner = document.createElement('div'); inner.className = 'agent-label-inner';
    const name = document.createElement('span'); name.className = 'agent-label-name'; name.textContent = resident.agent.name;
    const state = document.createElement('span'); state.className = 'agent-label-state'; state.textContent = meta.label;
    inner.append(name, state); resident.label.append(inner);
    resident.label.classList.toggle('selected', resident.id === this.selectedID);
    resident.label.classList.toggle('hovered', resident.id === this.hoveredID);
    resident.label.title = `Interact with ${resident.agent.name}`;
    resident.label.style.setProperty('--status', meta.color);
    resident.label.dataset.status = resident.agent.status;
    const selected = resident.id === this.selectedID, hovered = resident.id === this.hoveredID;
    resident.ring.material = this.material('resident-pad', selected ? '#a6f1dc' : hovered ? '#9ed7c5' : '#829c96', selected ? 0.8 : hovered ? 0.45 : 0.1);
    resident.ring.isVisible = selected || hovered;
  }

  private buildInput(): void {
    const listen = <K extends keyof WindowEventMap>(type: K, listener: (event: WindowEventMap[K]) => void) => { window.addEventListener(type, listener); this.cleanups.push(() => window.removeEventListener(type, listener)); };
    listen('resize', () => this.engine.resize());
    const motionPreference = matchMedia('(prefers-reduced-motion: reduce)');
    const motionPreferenceChanged = (event: MediaQueryListEvent) => {
      this.reducedMotion = event.matches;
      this.camera.inertia = this.reducedMotion ? 0 : 0.75;
      if (this.reducedMotion) {
        this.camera.inertialAlphaOffset = 0;
        this.camera.inertialBetaOffset = 0;
        this.camera.inertialRadiusOffset = 0;
      }
      for (const resident of this.residents) this.setActorWalking(resident.actor, resident.motion.walking, true);
    };
    motionPreference.addEventListener('change', motionPreferenceChanged);
    this.cleanups.push(() => motionPreference.removeEventListener('change', motionPreferenceChanged));
    let pointerStart: ScreenPoint | undefined;
    let dragged = false;
    const pickResident = (event: PointerEvent): string | undefined => {
      const rect = this.canvas.getBoundingClientRect();
      return this.scene.pick(event.clientX - rect.left, event.clientY - rect.top, mesh => mesh.isEnabled() && mesh.isVisible && mesh.isPickable && typeof mesh.metadata?.actorID === 'string')?.pickedMesh?.metadata?.actorID;
    };
    const down = (event: PointerEvent) => {
      if (event.button !== 0) return;
      pointerStart = { x: event.clientX, y: event.clientY }; dragged = false;
      this.canvas.focus({ preventScroll: true });
    };
    const move = (event: PointerEvent) => {
      if (pointerStart) {
        dragged ||= !isClickGesture(pointerStart, { x: event.clientX, y: event.clientY });
        if (dragged) { this.setHovered(undefined); this.canvas.style.cursor = 'grabbing'; }
        return;
      }
      this.setHovered(pickResident(event));
    };
    const up = (event: PointerEvent) => {
      const click = pointerStart && !dragged && isClickGesture(pointerStart, { x: event.clientX, y: event.clientY });
      pointerStart = undefined;
      dragged = false;
      const id = pickResident(event);
      this.setHovered(id);
      if (click && id) this.callbacks.onSelect(id);
    };
    const cancel = () => { pointerStart = undefined; dragged = false; this.setHovered(undefined); };
    this.canvas.addEventListener('pointerdown', down); this.canvas.addEventListener('pointermove', move); this.canvas.addEventListener('pointerup', up);
    this.canvas.addEventListener('pointerleave', cancel); this.canvas.addEventListener('pointercancel', cancel);
    listen('blur', cancel);
    this.cleanups.push(() => { this.canvas.removeEventListener('pointerdown', down); this.canvas.removeEventListener('pointermove', move); this.canvas.removeEventListener('pointerup', up); this.canvas.removeEventListener('pointerleave', cancel); this.canvas.removeEventListener('pointercancel', cancel); });
    this.engine.onContextLostObservable.add(() => this.callbacks.onGraphicsFailure());
  }

  private setHovered(id?: string): void {
    this.canvas.style.cursor = id ? 'pointer' : 'grab';
    if (id === this.hoveredID) return;
    this.hoveredID = id;
    for (const resident of this.residents) this.updateLabel(resident);
  }

  private render = (): void => {
    if (this.disposed || !this.visible || document.hidden) return;
    const now = performance.now();
    if (now - this.lastFrame < 1000 / 30 - 1) return;
    const dt = Math.min((now - (this.lastFrame || now)) / 1000, 0.05);
    this.lastFrame = now;
    this.elapsed += dt;
    const rosterIDs = this.residents.map(resident => resident.id);
    const pausedIDs = new Set(this.residents.filter(resident => statusCanWander(resident.agent.status) && (resident.id === this.selectedID || resident.id === this.hoveredID)).map(resident => resident.id));
    const previous = this.residents.map(resident => resident.motion);
    const proposed = this.residents.map(resident => stepResidentMotion(resident.motion, { status: resident.agent.status, home: resident.home, dt, rosterIDs, visible: this.visible, paused: pausedIDs.has(resident.id), reducedMotion: this.reducedMotion }, this.navigation));
    const motions = resolveResidentSpacing(proposed, previous, this.navigation, pausedIDs);
    for (let index = 0; index < this.residents.length; index++) {
      const resident = this.residents[index];
      resident.motion = motions[index];
      resident.actor.root.position.set(resident.motion.x, 0.075, resident.motion.z);
      resident.actor.root.rotation.y = resident.motion.heading;
      resident.ring.position.x = resident.motion.x;
      resident.ring.position.z = resident.motion.z;
      resident.label.dataset.behavior = resident.motion.phase;
      resident.label.dataset.walking = String(resident.motion.walking);
      resident.label.dataset.worldX = resident.motion.x.toFixed(3);
      resident.label.dataset.worldZ = resident.motion.z.toFixed(3);
      this.setActorWalking(resident.actor, resident.motion.walking);
      if (!this.reducedMotion && !resident.actor.model && resident.actor.body) {
        resident.actor.body.position.y = resident.motion.walking ? Math.abs(Math.sin(this.elapsed * 8 + resident.phase)) * 0.035 : Math.sin(this.elapsed * 1.4 + resident.phase) * 0.017;
        if (resident.actor.leftLeg) resident.actor.leftLeg.rotation.x = resident.motion.walking ? Math.sin(this.elapsed * 8 + resident.phase) * 0.42 : 0;
        if (resident.actor.rightLeg) resident.actor.rightLeg.rotation.x = resident.motion.walking ? -Math.sin(this.elapsed * 8 + resident.phase) * 0.42 : 0;
        // Real working status only; available residents do not simulate task activity.
        resident.actor.body.rotation.y = resident.agent.status === 'working' ? Math.sin(this.elapsed * 1.8 + resident.phase) * 0.045 : 0;
      }
    }
    this.scene.render();
    this.updateLabels();
  };

  private setActorWalking(actor: Actor, walking: boolean, force = false): void {
    if (!force && actor.walking === walking) return;
    actor.walking = walking;
    actor.walk?.stop();
    actor.idle?.stop();
    if (this.reducedMotion) return;
    if (walking && actor.walk) actor.walk.start(true, 0.8);
    else actor.idle?.start(true);
  }

  private updateLabels(): void {
    const viewport = this.camera.viewport.toGlobal(this.engine.getRenderWidth(), this.engine.getRenderHeight());
    const scaleX = this.canvas.clientWidth / this.engine.getRenderWidth();
    const scaleY = this.canvas.clientHeight / this.engine.getRenderHeight();
    const canvasRect = this.canvas.getBoundingClientRect();
    const overlays = this.hudOverlays.filter(element => !element.hidden && element.getClientRects().length > 0).map(element => {
      const rect = element.getBoundingClientRect();
      return { left: rect.left - canvasRect.left, top: rect.top - canvasRect.top, right: rect.right - canvasRect.left, bottom: rect.bottom - canvasRect.top };
    });
    const candidates = this.residents.map(resident => {
      const projected = Vector3.Project(resident.actor.root.position.add(new Vector3(0, this.theme.heights[resident.actor.appearance] + 0.26, 0)), Matrix.IdentityReadOnly, this.scene.getTransformMatrix(), viewport);
      const x = projected.x * scaleX, y = projected.y * scaleY;
      const halfWidth = resident.label.offsetWidth / 2;
      const bounds = { left: x - halfWidth, top: y - resident.label.offsetHeight, right: x + halfWidth, bottom: y };
      const priority = resident.id === this.selectedID ? 0 : resident.id === this.hoveredID ? 1 : resident.agent.status === 'needs_attention' ? 2 : resident.agent.status === 'working' ? 3 : 4;
      return { resident, projected, x, y, bounds, priority };
    }).sort((a, b) => a.priority - b.priority || a.projected.z - b.projected.z || a.resident.id.localeCompare(b.resident.id));
    const occupied = [...overlays];
    for (const { resident, projected, x, y, bounds } of candidates) {
      const visible = projected.z > 0 && projected.z < 1 && labelIsUnobscured(bounds, this.canvas.clientWidth, this.canvas.clientHeight, occupied);
      if (visible) occupied.push(bounds);
      resident.label.dataset.labelVisible = String(visible);
      resident.label.style.opacity = visible ? '1' : '0';
      // Hide immediately on overlap; an opacity transition must not linger over the HUD.
      resident.label.style.visibility = visible ? 'visible' : 'hidden';
      resident.label.style.transform = `translate(${x.toFixed(1)}px,${y.toFixed(1)}px) translate(-50%,-100%)`;
      resident.label.style.zIndex = `${Math.round(1000 - projected.z * 1000)}`;
    }
  }

  focusResident(id: string): void {
    const resident = this.residents.find(item => item.id === id);
    if (!resident) return;
    this.selectedID = id;
    for (const item of this.residents) this.updateLabel(item);
  }

  setVisible(visible: boolean): void {
    this.visible = visible;
    this.setHovered(undefined);
    this.lastFrame = 0;
    if (visible) { this.engine.resize(); this.engine.runRenderLoop(this.render); }
    else { this.engine.stopRenderLoop(this.render); }
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    for (const cleanup of this.cleanups) cleanup();
    this.engine.stopRenderLoop();
    this.labels.replaceChildren();
    for (const container of this.containers.values()) container.dispose();
    this.scene.dispose();
    this.engine.dispose();
  }
}
