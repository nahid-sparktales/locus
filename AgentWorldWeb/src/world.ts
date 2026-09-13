import { fetchCompressedModel } from './assetBytes';
import { createNewsCoo } from './newsCoo';
import { Engine } from '@babylonjs/core/Engines/engine';
import { Scene } from '@babylonjs/core/scene';
import { ArcRotateCamera } from '@babylonjs/core/Cameras/arcRotateCamera';
import { Vector3, Matrix } from '@babylonjs/core/Maths/math.vector';
import { Color3, Color4 } from '@babylonjs/core/Maths/math.color';
import { HemisphericLight } from '@babylonjs/core/Lights/hemisphericLight';
import { DirectionalLight } from '@babylonjs/core/Lights/directionalLight';
import { StandardMaterial } from '@babylonjs/core/Materials/standardMaterial';
import { ImageProcessingConfiguration } from '@babylonjs/core/Materials/imageProcessingConfiguration';
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
import { LOCUS_OUTPOST_PALETTE as OUTPOST } from './outpostPalette';
import { STATUS_META, isClickGesture, labelIsUnobscured } from './state';
import type { Agent, AgentTransfer, AttentionRequest, Point, ResidentStyle, ScreenPoint } from './state';
import { createDenDenMushi, createCourierBoat } from './seaSignals';
import { courierPose, courierRouteLength } from './fleetActivity';
import { ShipEncounterState } from './shipEncounters';
import type { EncounterShip } from './shipEncounters';
import { createShipEncounterVisuals } from './shipEncounterVisuals';
import { createIslandWorkSignals } from './islandWorkSignals';
import { RESIDENT_ASSET_TYPES, HUMANOID_ASSET_TYPES, SHIP_ASSET_TYPES, DEFAULT_SHIP_ASSET_TYPES, SHIP_NAMES, DEFAULT_STATIONS } from './theme';
import { SCENERY_ASSET_TYPES, type SceneryAssetType } from './theme';
import { buildGrandLineScenery, GRAND_LINE_HOME_NAMES, GRAND_LINE_CREW_PLAZAS, GRAND_LINE_LANDMARKS } from './grandLineScenery';
import { assignHarbors } from './harborAssignments';
import { createShipFallback, replaceShipFallback, createShipWake, fitShipModel } from './ships';
import { createPanda } from './pandas';
import { createPerson } from './people';
import { createIslandCrew } from './islandCrew';
import { islandCrewActivity, shipBerthHeading } from './islandBerths';
import { assignCrewKinds } from './crewAssignments';
import type { ResidentKind } from './crewAssignments';
import { applyLocusSceneryTint } from './outpostPalette';
import type { Theme, AssetType, ResidentAssetType, ShipAssetType, PropAssetType, Placement } from './theme';
import { createNavigation, findResidentArrival, findResidentPath, pointIsWalkable, createResidentMotion, residentAssetForID, residentSeed, resolveResidentSpacing, stationObstacle, statusCanWander, stepResidentMotion, themeNavigation } from './residentMotion';
import type { NavigationMap, ResidentMotion } from './residentMotion';

type Actor = { root: TransformNode; fallback: TransformNode; appearance: ResidentAssetType; kind: ResidentKind | 'ship'; panda?: ReturnType<typeof createPanda>; person?: ReturnType<typeof createPerson>; model?: InstantiatedEntries; loadedAppearance?: ResidentAssetType; idle?: AnimationGroup; walk?: AnimationGroup; walking: boolean; body?: TransformNode; leftLeg?: TransformNode; rightLeg?: TransformNode };
type Resident = { crew?: ReturnType<typeof createIslandCrew>; agent: Agent; actor: Actor; label: HTMLDivElement; ring: Mesh; wake?: TransformNode; home: Placement; motion: ResidentMotion; id: string; phase: number };
type Courier = { event: AgentTransfer; boat: ReturnType<typeof createCourierBoat>; route: Point[]; wake: TransformNode; started: number; duration: number; arrivedAt?: number; label: HTMLDivElement };
type Callbacks = { onAttention?: (requestID: string) => void; onTransfer?: (transferID: string) => void; onSelect: (id: string) => void; onAssetFailure: () => void; onAssetProgress: (completed: number, total: number) => void; onGraphicsFailure: () => void };

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
  private shipStyles = new Map<string, ShipAssetType>();
  private crewAssignments = new Map<string, ResidentKind>();
  private harborAssignments = new Map<string, number>();
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
  private ocean?: ReturnType<typeof buildGrandLineScenery>;
  private navigationMode: 'orbit' | 'pan' = 'orbit';
  private attentionRequests: readonly AttentionRequest[] = [];
  private snails = new Map<string, ReturnType<typeof createDenDenMushi>>();
  private couriers = new Map<string, Courier>();
  private courierNavigation?: NavigationMap;
  private newsCoo?: ReturnType<typeof createNewsCoo>;
  private encounters = new ShipEncounterState();
  private encounterVisuals?: ReturnType<typeof createShipEncounterVisuals>;
  private islandWorkSignals?: ReturnType<typeof createIslandWorkSignals>;

  constructor(private canvas: HTMLCanvasElement, private theme: Theme, private callbacks: Callbacks, private residentStyle: ResidentStyle = 'mixed') {
    this.engine = new Engine(canvas, true, { preserveDrawingBuffer: false, stencil: true, powerPreference: 'low-power', audioEngine: false });
    this.resizeRenderer();
    this.scene = new Scene(this.engine);
    this.scene.imageProcessingConfiguration.toneMappingEnabled = true;
    this.scene.imageProcessingConfiguration.toneMappingType = ImageProcessingConfiguration.TONEMAPPING_ACES;
    this.scene.imageProcessingConfiguration.exposure = 1.05;
    this.scene.clearColor = Color4.FromColor3(Color3.FromHexString(theme.palette.sky), 1);
    this.scene.ambientColor = theme.environment === 'ocean' ? new Color3(0.25, 0.34, 0.36) : new Color3(0.30, 0.30, 0.25);
    this.scene.fogMode = Scene.FOGMODE_EXP2;
    this.scene.fogColor = Color3.FromHexString(theme.palette.sky).scale(1.9);
    this.scene.fogDensity = theme.environment === 'ocean' ? 0.002 : 0.0045;
    this.scene.skipPointerMovePicking = true;
    this.scene.autoClear = true;
    this.labels = document.getElementById('agent-labels')!;
    this.hudOverlays = Array.from(document.querySelectorAll<HTMLElement>('.roster-panel, .world-header, .world-footer, .coordinate-label, .voyage-chart, .view-reset, #theme-popover, #selection-note, #asset-loading, #asset-notice, #graphics-fallback, #fleet-activity, #snail-alert'));
    this.mapRoot = new TransformNode('outpost', this.scene);
    this.navigation = themeNavigation(theme, []);
    if (theme.environment === 'ocean') this.courierNavigation = createNavigation({ radius: theme.layout.radius, bodyRadius: 0.48, obstacles: theme.layout.obstacles });

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
    if (theme.environment === 'ocean') {
      this.camera.lowerRadiusLimit = 13;
      this.camera.upperRadiusLimit = 84;
      this.camera.wheelPrecision = 10;
      this.camera.panningSensibility = 85;
      this.camera.panningAxis.set(1, 0, 1);
      this.camera.panningDistanceLimit = 55;
      this.camera.upperBetaLimit = 1.28;
      this.resetView();
    }

    const ambient = new HemisphericLight('sky-light', new Vector3(0.2, 1, -0.4), this.scene);
    ambient.intensity = theme.environment === 'ocean' ? 0.75 : 0.65;
    ambient.diffuse = theme.environment === 'ocean' ? new Color3(0.85, 0.96, 1) : new Color3(1, 0.98, 0.91);
    ambient.groundColor = theme.environment === 'ocean' ? new Color3(0.42, 0.57, 0.61) : new Color3(0.26, 0.27, 0.23);
    const sun = new DirectionalLight('sunrise', new Vector3(-0.5, -1, 0.5), this.scene);
    sun.position = new Vector3(14, 24, -17);
    sun.intensity = 1.0;
    sun.diffuse = theme.environment === 'ocean' ? new Color3(1, 0.9, 0.74) : new Color3(1, 0.96, 0.88);
    if (theme.environment === 'ocean') {
      const seaFill = new DirectionalLight('ocean-bounce-fill', new Vector3(0.6, -0.45, -0.35), this.scene);
      seaFill.intensity = 0.32; seaFill.diffuse = new Color3(0.80, 0.92, 1);
    }
    this.shadow = new ShadowGenerator(Math.min(theme.environment === 'ocean' ? 4096 : 2048, this.engine.getCaps().maxTextureSize), sun);
    this.shadow.usePercentageCloserFiltering = true;
    this.shadow.filteringQuality = ShadowGenerator.QUALITY_MEDIUM;
    this.shadow.bias = 0.001;
    this.shadow.normalBias = 0.02;
    this.shadow.setDarkness(0.28);

    this.buildMap();
    this.newsCoo = createNewsCoo(this.scene, this.mapRoot, theme.environment === 'ocean');
    if (theme.environment === 'ocean') {
      this.encounterVisuals = createShipEncounterVisuals(this.scene, this.mapRoot);
      this.islandWorkSignals = createIslandWorkSignals(this.scene, this.mapRoot, GRAND_LINE_LANDMARKS.map((island, index) => ({ ...island, marker: GRAND_LINE_CREW_PLAZAS[index] })));
    }
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
    if (this.theme.environment === 'ocean') {
      this.ocean = buildGrandLineScenery(this.scene, this.shadow, this.mapRoot, this.theme);
      return;
    }
    const radius = this.theme.layout.radius;
    const moss = this.material('campus-lawn', OUTPOST.sageDeep);
    const grass = this.material('commons-grass', OUTPOST.sage);
    const dark = this.material('navy-alloy', OUTPOST.charcoalRaised);
    const trim = this.material('warm-ceramic', OUTPOST.paper);
    const path = this.material('promenade-stone', OUTPOST.paperDeep);
    const wood = this.material('warm-timber', OUTPOST.muted);
    const woodLight = this.material('warm-timber-light', OUTPOST.amber);
    const light = this.material('guide-light', this.theme.palette.accent, 0.65);
    const copper = this.material('brushed-copper', OUTPOST.amber);
    const rock = this.material('bedrock', OUTPOST.charcoal);
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
    const stone = this.material('pond-ceramic', OUTPOST.paper);
    const pond = this.cylinder('pond-rim', 4.1, 0.22, 0.2, stone, 48);
    pond.scaling.set(1.1, 1, 0.72); pond.position.x = 1.2; pond.position.z = 1.1;
    const water = this.cylinder('pond-water', 3.77, 0.055, 0.305, this.material('garden-water', OUTPOST.tealDeep, 0.13), 48);
    water.scaling.set(1.1, 1, 0.72); water.position.x = 1.2; water.position.z = 1.1;
    for (let index = 0; index < 3; index++) {
      const ripple = this.ring(`pond-ripple-${index}`, 0.5 + index * 0.48, 0.012, 0.34, this.material('water-ripple', OUTPOST.teal, 0.18));
      ripple.scaling.z = 0.72; ripple.position.x = 1.0; ripple.position.z = 1.2;
    }
    const wood = this.material('garden-bench-wood', OUTPOST.amber);
    const iron = this.material('garden-bench-frame', OUTPOST.alloy);
    for (const [x, z, angle] of [[-2.2, 3.25, -0.4], [3.2, -1.6, 0.8]]) {
      const bench = new TransformNode('commons-bench', this.scene);
      bench.position.set(x, 0.17, z); bench.rotation.y = angle;
      this.box('bench-seat', [1.55, 0.1, 0.48], [0, 0.37, 0], wood, bench);
      this.box('bench-back', [1.55, 0.35, 0.08], [0, 0.61, -0.19], wood, bench);
      for (const side of [-0.58, 0.58]) this.box('bench-leg', [0.1, 0.4, 0.43], [side, 0.16, 0], iron, bench);
      for (const mesh of bench.getChildMeshes()) this.shadow.addShadowCaster(mesh);
    }
    this.createGardenTree(-1.75, -1.35, 4.25, OUTPOST.sageDeep);
    this.createGardenTree(2.25, -2.55, 2.7, OUTPOST.sage);
    this.createGardenTree(-3.1, 1.15, 2.35, OUTPOST.amber);
    this.createGardenTree(2.85, 2.7, 1.8, OUTPOST.sageMid);
    const leaves = [OUTPOST.sageMid, OUTPOST.sage, OUTPOST.sageDeep, OUTPOST.sage];
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
        bloom.position.set(x, 0.64, z); bloom.material = this.material('commons-flowers', index % 8 === 0 ? OUTPOST.clay : OUTPOST.logoLime, 0.08); bloom.isPickable = false;
      }
    }
  }

  private createGardenTree(x: number, z: number, height: number, color: string, parent?: TransformNode): void {
    const root = new TransformNode('garden-tree', this.scene); root.position.set(x, 0.18, z);
    if (parent) root.parent = parent;
    const trunk = this.cylinder('tree-trunk', height * 0.085, height * 0.64, height * 0.32, this.material('tree-trunk', OUTPOST.muted), 7, root);
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
    const rock = this.material('satellite-rock', OUTPOST.line);
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
    planet.material = this.material('distant-world-surface', OUTPOST.sageMid, 0.25);
    planet.isPickable = false;
    const orbit = this.ring('planet-ring', 33, 1.8, 0, this.material('planet-dust', OUTPOST.ivory, 0.18, 0.23));
    orbit.parent = planet;
    orbit.rotation.set(0.45, 0, -0.35);
    const stars = new TransformNode('constellations', this.scene);
    this.stars = stars;
    const source = MeshBuilder.CreateSphere('star-source', { diameter: 0.09, segments: 3 }, this.scene);
    source.material = this.material('starlight', OUTPOST.paper, 1.2);
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
    const dark = this.material('navy-alloy', OUTPOST.charcoalRaised);
    const pearl = this.material('pearl-alloy', OUTPOST.paper);
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
      this.cylinder('planter-soil', 1.2, 0.06, 0.46, this.material('planter-soil', OUTPOST.line), 12, root);
      this.createGardenTree(0, 0, 1.0, OUTPOST.sage, root);
    } else if (type === 'lounge') {
      const cushion = this.material('lounge-cushion', OUTPOST.sage);
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
    if (this.theme.environment === 'ocean') {
      createShipFallback(this.scene, this.shadow, fallback, appearance as ShipAssetType);
      for (const mesh of fallback.getChildMeshes()) { mesh.isPickable = true; mesh.metadata = { actorID: name }; }
      return { root, fallback, appearance, kind: 'ship', walking: false };
    }
    const kind = this.residentKind(name, appearance);
    if (kind === 'panda') {
      const panda = createPanda(this.scene, this.shadow, fallback, name, residentSeed(name));
      return { root, fallback, appearance, kind, panda, walking: false };
    }
    if (this.residentStyle === 'mixed' && kind === 'person') {
      const person = createPerson(this.scene, this.shadow, fallback, name, residentSeed(name));
      return { root, fallback, appearance, kind, person, walking: false };
    }
    if (this.residentStyle === 'mixed' && appearance === 'resident_explorer') {
      const robots = HUMANOID_ASSET_TYPES.filter(type => type !== 'resident_explorer' && this.theme.assets[type]);
      appearance = residentAssetForID(name, robots.length ? robots : ['resident']);
    }
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
    return { root, fallback, body, appearance, kind, walking: false, leftLeg: legs[0], rightLeg: legs[1] };
  }

  private createStation(x: number, z: number, rotation: number): TransformNode {
    const root = new TransformNode('workstation', this.scene);
    root.position.set(x, 0, z);
    root.rotation.y = rotation;
    const berth = this.box('workstation-berth', [1.85, 0.035, 2.2], [0, 0.085, 0], this.material('station-berth', OUTPOST.line), root);
    berth.receiveShadows = true;
    const marking = this.material('berth-markings', OUTPOST.sage, 0.05);
    this.box('berth-edge-left', [0.035, 0.045, 1.8], [-0.9, 0.11, 0], marking, root);
    this.box('berth-edge-right', [0.035, 0.045, 1.8], [0.9, 0.11, 0], marking, root);
    const container = this.containers.get('station');
    if (container) {
      this.attachModel('station', root, container);
    } else {
      const pearl = this.material('pearl-alloy', OUTPOST.paper);
      const navy = this.material('navy-alloy', OUTPOST.charcoalRaised);
      this.box('desk-pedestal', [0.5, 0.8, 0.45], [0, 0.4, 0], navy, root);
      const top = this.box('desk-console', [1.35, 0.18, 0.75], [0, 0.96, 0], pearl, root);
      top.rotation.x = -0.16;
      const glass = this.box('desk-screen', [1.08, 0.04, 0.54], [0, 1.07, 0.015], this.material('console-display', OUTPOST.lime, 0.48), root);
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
    const ship = SHIP_ASSET_TYPES.includes(type as ShipAssetType);
    const shipFit = ship ? fitShipModel(type as ShipAssetType, bounds, this.theme.heights[type], this.theme.rotations[type]) : undefined;
    const scale = shipFit?.scale ?? (height > 0.0001 ? this.theme.heights[type] / height : 1);
    normalized.scaling.setAll(scale);
    if (shipFit) normalized.position.copyFrom(shipFit.offset);
    else normalized.position.set(-(bounds.min.x + bounds.max.x) / 2 * scale, -bounds.min.y * scale, -(bounds.min.z + bounds.max.z) / 2 * scale);
    normalized.parent = pivot;
    pivot.parent = parent;
    pivot.rotation.y = shipFit?.rotation ?? this.theme.rotations[type] ?? 0;
    if (shipFit) pivot.position.y = shipFit.waterline;
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
    if (actor.panda || actor.person) return;
    const type = this.containers.has(actor.appearance) ? actor.appearance : this.theme.environment === 'ocean' ? actor.appearance : 'resident';
    const container = this.containers.get(type);
    if (!container || actor.loadedAppearance === type) return;
    try {
      actor.model?.dispose();
      for (const child of [...actor.root.getChildren()]) if (child !== actor.fallback && !child.metadata?.worldSignal) child.dispose();
      actor.model = this.attachModel(type, actor.root, container);
      actor.loadedAppearance = type;
      actor.fallback.setEnabled(false);
      actor.idle = actor.model.animationGroups.find(group => /idle|standing|breath/i.test(group.name));
      actor.walk = actor.model.animationGroups.find(group => /walk|running|run/i.test(group.name));
      actor.walking = false;
      if (!this.reducedMotion) actor.idle?.start(true);
    } catch { this.callbacks.onAssetFailure(); }
  }

  private readonly assetRequests = new AbortController();

  private async loadAssets(): Promise<void> {
    const entries = (Object.entries(this.theme.assets) as [AssetType, string][]).sort(([a], [b]) => Number(SCENERY_ASSET_TYPES.includes(b as SceneryAssetType)) - Number(SCENERY_ASSET_TYPES.includes(a as SceneryAssetType)));
    let completed = 0;
    this.callbacks.onAssetProgress(0, entries.length);
    // Two at once keeps texture upload from monopolizing the native window.
    for (let index = 0; index < entries.length; index += 2) {
      await Promise.all(entries.slice(index, index + 2).map(async ([type, path]) => {
        try {
          const url = new URL(`./themes/${this.theme.id}/${path}`, document.baseURI).href;
          const source = path.endsWith('.glb.gz') ? await fetchCompressedModel(url, this.assetRequests.signal) : url;
          if (this.disposed) return;
          const container = await LoadAssetContainerAsync(source, this.scene, { pluginExtension: '.glb', name: path.replace(/\.gz$/, '') });
          if (this.disposed) { container.dispose(); return; }
          if (this.theme.environment !== 'ocean') applyLocusSceneryTint(container);
          for (const texture of container.textures) texture.anisotropicFilteringLevel = 16;
          this.containers.set(type, container);
          if (RESIDENT_ASSET_TYPES.includes(type as ResidentAssetType)) for (const resident of this.residents) this.upgradeActor(resident.actor);
          if (type === 'station') this.rebuildStations();
          if (SCENERY_ASSET_TYPES.includes(type as SceneryAssetType)) this.ocean?.installAsset(type as SceneryAssetType, container);
          if (!RESIDENT_ASSET_TYPES.includes(type as ResidentAssetType) && !SCENERY_ASSET_TYPES.includes(type as SceneryAssetType) && type !== 'station') {
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
    if (this.theme.environment === 'ocean') {
      this.navigation = themeNavigation(this.theme, []);
      return;
    }
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
      for (const agent of agents) { const resident = existingByID.get(agent.id)!; resident.agent = agent; this.syncIslandCrew(resident); this.updateLabel(resident); }
      this.updateSeaAlerts();
      return;
    }
    this.clearCouriers();
    this.encounters.clear();
    for (const snail of this.snails.values()) snail.dispose();
    this.snails.clear();
    for (const resident of this.residents) { resident.crew?.dispose(); resident.actor.model?.dispose(); resident.actor.root.dispose(); resident.ring.dispose(); resident.wake?.dispose(); resident.label.remove(); }
    if (this.theme.environment !== 'ocean') {
      for (const [id, kind] of assignCrewKinds(agents.map(agent => agent.id), this.crewAssignments)) this.crewAssignments.set(id, kind);
    }
    const candidates: readonly ResidentAssetType[] = this.theme.environment === 'ocean' ? DEFAULT_SHIP_ASSET_TYPES : HUMANOID_ASSET_TYPES;
    const appearances = candidates.filter(type => !!this.theme.assets[type]);
    if (!appearances.length) appearances.push(this.theme.environment === 'ocean' ? 'ship_thousand_sunny' : 'resident');
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
    if (this.theme.environment === 'ocean') this.harborAssignments = assignHarbors(agents.map(agent => agent.id), this.harborAssignments, this.theme.layout.stations.length);
    const placements = agents.map((agent, index) => {
      const homeIndex = this.theme.environment === 'ocean' ? this.harborAssignments.get(agent.id) ?? index : index;
      return this.theme.layout.stations[homeIndex] || DEFAULT_STATIONS[index];
    });
    // Reserve surviving ships before placing newcomers, regardless of roster
    // order. An idle ship may be passing another island's berth.
    const occupied: Point[] = agents.flatMap((agent, index) => {
      const previous = existingByID.get(agent.id), placement = placements[index];
      return previous?.home.x === placement.x && previous.home.z === placement.z ? [previous.motion] : [];
    });
    this.residents = agents.flatMap((agent, index) => {
      const placement = placements[index];
      const previous = existingByID.get(agent.id);
      const keepsHome = previous?.home.x === placement.x && previous?.home.z === placement.z;
      const motion = keepsHome ? previous.motion : createResidentMotion(agent.id, placement);
      if (this.theme.environment === 'ocean' && !keepsHome) {
        const arrival = findResidentArrival(placement, this.navigation, occupied);
        // An overfull custom map still exposes the agent in the roster.
        if (!arrival) return [];
        motion.x = arrival.x; motion.z = arrival.z;
        motion.speed *= 0.65;
        motion.heading = shipBerthHeading(placement);
        occupied.push(motion);
      }
      const appearance = this.theme.environment === 'ocean' ? this.shipStyles.get(agent.id.toLowerCase()) ?? this.appearanceAssignments.get(agent.id)! : this.appearanceAssignments.get(agent.id)!;
      const actor = this.createActor(agent.id, ['#80c6b2', '#d2bb7e', '#d99874', '#a79ed4'][residentSeed(agent.id) % 4], appearance);
      // Adding a captain must not send the rest of the fleet back to port.
      actor.root.position.set(motion.x, 0.075, motion.z);
      actor.root.rotation.y = motion.heading;
      this.upgradeActor(actor);
      const label = document.createElement('div');
      label.className = 'agent-label';
      label.dataset.agentId = agent.id;
      label.dataset.appearance = actor.appearance;
      label.dataset.residentKind = actor.kind;
      label.dataset.residentStyle = this.theme.environment === 'ocean' ? 'ships' : this.residentStyle;
      if (this.theme.environment === 'ocean') label.dataset.homeIsland = this.getAgentHome(agent.id) ?? '';
      label.title = `Interact with ${agent.name}`;
      label.addEventListener('click', () => this.callbacks.onSelect(agent.id));
      label.addEventListener('pointerenter', () => this.setHovered(agent.id));
      label.addEventListener('pointerleave', () => this.setHovered(undefined));
      const ring = this.ring(`resident-pad-${agent.id}`, this.theme.environment === 'ocean' ? 3.6 : 1.45, 0.032, 0.115, this.material('resident-pad', '#829c96', 0.1));
      ring.position.x = placement.x; ring.position.z = placement.z;
      const wake = this.theme.environment === 'ocean' ? createShipWake(this.scene, this.mapRoot, agent.id) : undefined;
      const resident = { agent, actor, label, ring, wake, home: placement, motion, id: agent.id, phase: index * 1.5 };
      this.labels.append(label);
      this.updateLabel(resident);
      return [resident];
    });
    this.rebuildStations();
    this.updateSeaAlerts();
    this.setHovered(undefined);
  }

  private updateLabel(resident: Resident): void {
    const meta = STATUS_META[resident.agent.status];
    resident.label.replaceChildren();
    const inner = document.createElement('div'); inner.className = 'agent-label-inner';
    const name = document.createElement('span'); name.className = 'agent-label-name'; name.textContent = resident.agent.name;
    if (this.theme.environment === 'ocean') {
      const ship = document.createElement('span'); ship.className = 'agent-label-ship'; ship.textContent = SHIP_NAMES[resident.actor.appearance as ShipAssetType];
      name.append(ship);
      const port = document.createElement('span'); port.className = 'agent-label-port'; port.textContent = this.getAgentHome(resident.id) ?? '';
      name.append(port);
      resident.label.dataset.ship = ship.textContent ?? '';
    }
    const state = document.createElement('span'); state.className = 'agent-label-state'; state.textContent = meta.label;
    inner.append(name, state);
    const request = this.theme.environment === 'ocean' ? this.attentionRequests.find(item => item.agentID.toLowerCase() === resident.id.toLowerCase()) : undefined;
    if (request) {
      const call = document.createElement('button'); call.type = 'button'; call.tabIndex = -1; call.className = 'den-den-call';
      call.textContent = request.kind === 'approval' ? 'Ping Ping · Approval' : 'Ping Ping · Needs your input';
      call.title = request.title; call.dataset.requestId = request.id;
      call.addEventListener('click', event => { event.stopPropagation(); this.callbacks.onAttention?.(request.id); });
      inner.append(call);
    }
    resident.label.append(inner);
    resident.label.classList.toggle('selected', resident.id === this.selectedID);
    resident.label.classList.toggle('hovered', resident.id === this.hoveredID);
    resident.label.title = `Interact with ${resident.agent.name}`;
    resident.label.style.setProperty('--status', meta.color);
    resident.label.dataset.status = resident.agent.status;
    const selected = resident.id === this.selectedID, hovered = resident.id === this.hoveredID;
    resident.ring.material = this.material('resident-pad', selected ? '#a6f1dc' : hovered ? '#9ed7c5' : '#829c96', selected ? 0.8 : hovered ? 0.45 : 0.1);
    resident.ring.isVisible = selected || hovered;
  }

  private resizeRenderer(): void {
    // Babylon's scale is inverse: 0.5 renders two pixels per CSS pixel.
    // Reapply the cap when the window moves between displays or changes size.
    const pixelRatio = Math.max(1, Math.min(2, window.devicePixelRatio || 1));
    this.engine.setHardwareScalingLevel(1 / pixelRatio);
  }

  handleCreatureKey(key: string, repeat = false): boolean { return this.ocean?.handleCreatureKey(key, repeat) ?? false; }

  private buildInput(): void {
    const listen = <K extends keyof WindowEventMap>(type: K, listener: (event: WindowEventMap[K]) => void) => { window.addEventListener(type, listener); this.cleanups.push(() => window.removeEventListener(type, listener)); };
    listen('resize', () => this.resizeRenderer());
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
    const pick = (event: PointerEvent): { actorID?: string; attentionID?: string; transferID?: string; creatureID?: string } | undefined => {
      const rect = this.canvas.getBoundingClientRect();
      return this.scene.pick(event.clientX - rect.left, event.clientY - rect.top, mesh => mesh.isEnabled() && mesh.isVisible && mesh.isPickable && (typeof mesh.metadata?.actorID === 'string' || typeof mesh.metadata?.transferID === 'string' || typeof mesh.metadata?.creatureID === 'string'))?.pickedMesh?.metadata;
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
      const target = pick(event);
      this.setHovered(target?.actorID);
      if (target?.transferID || target?.attentionID || target?.creatureID) this.canvas.style.cursor = 'pointer';
    };
    const up = (event: PointerEvent) => {
      const click = pointerStart && !dragged && isClickGesture(pointerStart, { x: event.clientX, y: event.clientY });
      pointerStart = undefined;
      dragged = false;
      const target = pick(event);
      this.setHovered(target?.actorID);
      if (click && target?.creatureID) this.ocean?.selectCreature(target.creatureID);
      else if (click && target?.attentionID) this.callbacks.onAttention?.(target.attentionID);
      else if (click && target?.transferID) this.callbacks.onTransfer?.(target.transferID);
      else if (click && target?.actorID) this.callbacks.onSelect(target.actorID);
    };
    const cancel = () => { pointerStart = undefined; dragged = false; this.setHovered(undefined); };
    this.canvas.addEventListener('pointerdown', down); this.canvas.addEventListener('pointermove', move); this.canvas.addEventListener('pointerup', up);
    this.canvas.addEventListener('pointerleave', cancel); this.canvas.addEventListener('pointercancel', cancel);
    listen('blur', cancel);
    this.cleanups.push(() => { this.canvas.removeEventListener('pointerdown', down); this.canvas.removeEventListener('pointermove', move); this.canvas.removeEventListener('pointerup', up); this.canvas.removeEventListener('pointerleave', cancel); this.canvas.removeEventListener('pointercancel', cancel); });
    this.engine.onContextLostObservable.add(() => this.callbacks.onGraphicsFailure());
  }

  private setHovered(id?: string): void {
    this.canvas.style.cursor = id ? 'pointer' : this.navigationMode === 'pan' ? 'move' : 'grab';
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
    this.newsCoo?.update(this.elapsed, this.reducedMotion);
    this.ocean?.update(this.elapsed, this.reducedMotion);
    const rosterIDs = this.residents.map(resident => resident.id);
    const pausedIDs = new Set(this.residents.filter(resident => statusCanWander(resident.agent.status) && (resident.id === this.selectedID || resident.id === this.hoveredID)).map(resident => resident.id));
    if (this.theme.environment === 'ocean') this.encounters.updateIdle(this.encounterShips(), this.navigation, this.elapsed, this.reducedMotion, this.encounterHeldIDs());
    const destinations = this.theme.environment === 'ocean'
      ? this.encounters.destinations(this.encounterShips(), this.elapsed, this.reducedMotion, this.encounterHeldIDs()) : new Map<string, Placement>();
    const previous = this.residents.map(resident => resident.motion);
    const proposed = this.residents.map(resident => {
      const rendezvous = destinations.get(resident.id);
      return stepResidentMotion(resident.motion, { status: rendezvous ? 'working' : resident.agent.status, home: rendezvous ?? resident.home, dt, rosterIDs, visible: this.visible, paused: pausedIDs.has(resident.id), reducedMotion: this.reducedMotion }, this.navigation);
    });
    const motions = resolveResidentSpacing(proposed, previous, this.navigation, pausedIDs);
    for (let index = 0; index < this.residents.length; index++) {
      const resident = this.residents[index];
      resident.motion = motions[index];
      resident.actor.root.position.set(resident.motion.x, 0.075, resident.motion.z);
      resident.actor.root.rotation.y = resident.motion.heading;
      if (this.theme.environment === 'ocean') {
        resident.actor.root.position.y = this.reducedMotion ? 0.025 : 0.045 + Math.sin(this.elapsed * 1.5 + resident.phase) * 0.055;
        resident.actor.root.rotation.x = this.reducedMotion ? 0 : Math.sin(this.elapsed * 1.2 + resident.phase) * 0.018;
        resident.actor.root.rotation.z = this.reducedMotion ? 0 : Math.sin(this.elapsed * 1.6 + resident.phase) * 0.027;
        if (resident.wake) {
          resident.wake.position.set(resident.motion.x, 0.075, resident.motion.z);
          resident.wake.rotation.y = resident.motion.heading;
          resident.wake.setEnabled(resident.motion.walking && !this.reducedMotion);
          resident.wake.scaling.z = 0.95 + Math.sin(this.elapsed * 2 + resident.phase) * 0.12;
        }
      }
      resident.ring.position.x = resident.motion.x;
      resident.ring.position.z = resident.motion.z;
      resident.label.dataset.behavior = resident.motion.phase;
      resident.label.dataset.walking = String(resident.motion.walking);
      resident.label.dataset.worldX = resident.motion.x.toFixed(3);
      resident.label.dataset.worldZ = resident.motion.z.toFixed(3);
      resident.label.dataset.heading = resident.motion.heading.toFixed(5);
      if (this.theme.environment === 'ocean') {
        this.syncIslandCrew(resident);
        const atBerth = Math.hypot(resident.motion.x - resident.home.x, resident.motion.z - resident.home.z) < 0.08 && !resident.motion.walking;
        const parkedHeading = shipBerthHeading(resident.home);
        const aligned = Math.abs(Math.atan2(Math.sin(resident.motion.heading - parkedHeading), Math.cos(resident.motion.heading - parkedHeading))) < 0.06;
        const docked = atBerth && aligned;
        const berthState = docked ? 'Docked' : atBerth ? 'Mooring' : resident.motion.intent === 'station' ? 'Returning to port' : 'Sailing';
        const home = this.getAgentHome(resident.id) ?? 'Home island';
        const portText = `${berthState} · ${home}${resident.crew ? ` · ${resident.crew.count} crew ashore` : ''}`;
        const port = resident.label.querySelector('.agent-label-port');
        if (port && port.textContent !== portText) port.textContent = portText;
        resident.label.dataset.docked = String(docked);
      }
      this.setActorWalking(resident.actor, resident.motion.walking);
      resident.actor.panda?.animate(resident.motion.walking, this.elapsed + resident.phase, this.reducedMotion);
      resident.actor.person?.animate(resident.motion.walking, this.elapsed + resident.phase, this.reducedMotion);
      if (!this.reducedMotion && !resident.actor.model && resident.actor.body) {
        resident.actor.body.position.y = resident.motion.walking ? Math.abs(Math.sin(this.elapsed * 8 + resident.phase)) * 0.035 : Math.sin(this.elapsed * 1.4 + resident.phase) * 0.017;
        if (resident.actor.leftLeg) resident.actor.leftLeg.rotation.x = resident.motion.walking ? Math.sin(this.elapsed * 8 + resident.phase) * 0.42 : 0;
        if (resident.actor.rightLeg) resident.actor.rightLeg.rotation.x = resident.motion.walking ? -Math.sin(this.elapsed * 8 + resident.phase) * 0.42 : 0;
        // Real working status only; available residents do not simulate task activity.
        resident.actor.body.rotation.y = resident.agent.status === 'working' ? Math.sin(this.elapsed * 1.8 + resident.phase) * 0.045 : 0;
      }
    }
    this.updateSeaActivity();
    this.updateShipEncounters();
    this.updateIslandWorkSignals();
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
      return { label: resident.label, id: resident.id, projected, x, y, bounds, priority };
    });
    for (const courier of this.couriers.values()) {
      const projected = Vector3.Project(courier.boat.root.position.add(new Vector3(0, 1.7, 0)), Matrix.IdentityReadOnly, this.scene.getTransformMatrix(), viewport);
      const x = projected.x * scaleX, y = projected.y * scaleY, halfWidth = courier.label.offsetWidth / 2;
      candidates.push({ label: courier.label, id: courier.event.id, projected, x, y, bounds: { left: x - halfWidth, top: y - courier.label.offsetHeight, right: x + halfWidth, bottom: y }, priority: 3 });
    }
    candidates.sort((a, b) => a.priority - b.priority || a.projected.z - b.projected.z || a.id.localeCompare(b.id));
    const occupied = [...overlays];
    for (const { label, projected, x, y, bounds } of candidates) {
      const visible = projected.z > 0 && projected.z < 1 && labelIsUnobscured(bounds, this.canvas.clientWidth, this.canvas.clientHeight, occupied);
      if (visible) occupied.push(bounds);
      label.dataset.labelVisible = String(visible);
      label.style.opacity = visible ? '1' : '0';
      // Hide immediately on overlap; an opacity transition must not linger over the HUD.
      label.style.visibility = visible ? 'visible' : 'hidden';
      label.style.transform = `translate(${x.toFixed(1)}px,${y.toFixed(1)}px) translate(-50%,-100%)`;
      label.style.zIndex = `${Math.round(1000 - projected.z * 1000)}`;
    }
  }


  /** Requests persist until the native snapshot removes them; transfers arrive once. */
  setActivity(requests: readonly AttentionRequest[], transfers: readonly AgentTransfer[]): void {
    this.attentionRequests = requests;
    this.updateSeaAlerts();
    if (!this.courierNavigation || this.theme.environment !== 'ocean') return;
    this.encounters.addTransfers(transfers, this.encounterShips(), this.navigation, this.elapsed, Date.now() / 1000, this.reducedMotion);
    for (const event of transfers) {
      if (this.couriers.has(event.id) || this.couriers.size >= 8) continue;
      const from = this.residents.find(resident => resident.id.toLowerCase() === event.fromAgentID.toLowerCase());
      const to = this.residents.find(resident => resident.id.toLowerCase() === event.toAgentID.toLowerCase());
      if (!from || !to) continue;
      const berth = (resident: Resident): Point => {
        const direction = resident.home.rotation ?? 0;
        const point = { x: resident.home.x + Math.sin(direction) * 1.7, z: resident.home.z + Math.cos(direction) * 1.7 };
        return pointIsWalkable(point, this.courierNavigation!) ? point : { x: resident.home.x, z: resident.home.z };
      };
      const start = berth(from), end = berth(to), path = findResidentPath(start, end, this.courierNavigation);
      if (!path?.length) continue;
      const route = [start, ...path];
      const boat = createCourierBoat(this.scene, this.shadow, this.mapRoot, event.id, event.kind);
      const wake = createShipWake(this.scene, this.mapRoot, `courier-${event.id}`); wake.scaling.set(0.4, 1, 0.4);
      const label = document.createElement('div'); label.className = 'agent-label courier-label'; label.dataset.transferId = event.id;
      const inner = document.createElement('div'); inner.className = 'agent-label-inner';
      const text = document.createElement('span'); text.className = 'agent-label-name'; text.textContent = event.kind === 'artifact' ? 'Artifact delivery' : 'Agent handoff';
      inner.append(text); label.append(inner); label.title = `${from.agent.name} → ${to.agent.name}: ${event.title}`;
      label.addEventListener('click', () => this.callbacks.onTransfer?.(event.id));
      this.labels.append(label);
      this.couriers.set(event.id, { event, boat, route, wake, started: this.elapsed, duration: Math.max(14, Math.min(36, courierRouteLength(route) / 2.2)), label });
    }
    this.updateSeaActivity();
  }

  private updateSeaAlerts(): void {
    if (this.theme.environment !== 'ocean') return;
    const active = new Set<string>();
    for (const resident of this.residents) {
      const request = this.attentionRequests.find(item => item.agentID.toLowerCase() === resident.id.toLowerCase());
      if (request) {
        active.add(request.id);
        if (!this.snails.has(request.id)) {
          const snail = createDenDenMushi(this.scene, this.shadow, resident.actor.root, request.id, resident.id);
          snail.root.metadata = { worldSignal: true };
          snail.root.position.set(0.70, 0.95, 0.55);
          this.snails.set(request.id, snail);
        }
      }
      this.updateLabel(resident);
    }
    for (const [id, snail] of this.snails) if (!active.has(id)) { snail.dispose(); this.snails.delete(id); }
  }

  private updateSeaActivity(): void {
    for (const snail of this.snails.values()) snail.animate(this.elapsed, this.reducedMotion);
    for (const [id, courier] of this.couriers) {
      const progress = this.reducedMotion || courier.arrivedAt !== undefined ? 1 : Math.min(1, (this.elapsed - courier.started) / courier.duration);
      if (progress === 1 && courier.arrivedAt === undefined) courier.arrivedAt = this.elapsed;
      if (courier.arrivedAt !== undefined && this.elapsed - courier.arrivedAt > 10) {
        courier.boat.dispose(); courier.wake.dispose(); courier.label.remove(); this.couriers.delete(id); continue;
      }
      const pose = courierPose(courier.route, progress);
      courier.boat.root.position.set(pose.x, this.reducedMotion ? 0.02 : 0.035 + Math.sin(this.elapsed * 2.2) * 0.025, pose.z);
      courier.boat.root.rotation.set(this.reducedMotion ? 0 : Math.sin(this.elapsed * 1.8) * 0.018, pose.heading, this.reducedMotion ? 0 : Math.sin(this.elapsed * 2.4) * 0.04);
      courier.wake.position.set(pose.x, 0.078, pose.z); courier.wake.rotation.y = pose.heading; courier.wake.setEnabled(progress < 1 && !this.reducedMotion);
      courier.label.dataset.progress = progress.toFixed(3);
      courier.label.dataset.worldX = pose.x.toFixed(3); courier.label.dataset.worldZ = pose.z.toFixed(3);
      courier.label.dataset.delivered = String(progress === 1);
    }
  }

  private encounterShips(): EncounterShip[] {
    return this.residents.map(resident => ({ id: resident.id, agent: resident.agent, position: resident.motion, home: resident.home,
      heading: resident.motion.heading, walking: resident.motion.walking, speed: resident.motion.speed }));
  }

  private encounterHeldIDs(): Set<string> {
    const held = this.residents.filter(resident => statusCanWander(resident.agent.status) && (resident.id === this.selectedID || resident.id === this.hoveredID)).map(resident => resident.id);
    return new Set([...held, ...this.attentionRequests.map(request => request.agentID)].map(id => id.toLowerCase()));
  }

  private updateShipEncounters(): void {
    if (!this.encounterVisuals) return;
    const descriptions = this.encounterVisuals.update(this.encounterShips(), [...this.encounters.alliances.values()], this.elapsed, this.reducedMotion, this.encounterHeldIDs(), [...this.encounters.idleEncounters.values()]);
    for (const resident of this.residents) {
      const description = descriptions.get(resident.id) ?? '';
      resident.label.dataset.encounter = description;
      const port = resident.label.querySelector('.agent-label-port');
      if (description && port) port.textContent = `${description} · ${this.getAgentHome(resident.id) ?? 'Home island'}`;
    }
  }

  private updateIslandWorkSignals(): void {
    if (!this.islandWorkSignals) return;
    const active = this.islandWorkSignals.update(this.residents.map(resident => ({ id: resident.id, status: resident.agent.status,
      motion: resident.motion, home: resident.home, harbor: this.harborAssignments.get(resident.id) })), this.elapsed, this.reducedMotion);
    for (const resident of this.residents) resident.label.dataset.workIsland = active.has(resident.id) ? String(active.get(resident.id)) : '';
  }

  private syncIslandCrew(resident: Resident): void {
    if (this.theme.environment !== 'ocean') return;
    const activity = islandCrewActivity(resident.agent.status, resident.motion, resident.home);
    const harbor = this.harborAssignments.get(resident.id);
    const plaza = harbor === undefined ? undefined : GRAND_LINE_CREW_PLAZAS[harbor];
    if (!activity || !plaza) {
      resident.crew?.dispose(); resident.crew = undefined;
    } else {
      if (!resident.crew) {
        resident.crew = createIslandCrew(this.scene, this.shadow, this.mapRoot, resident.id, residentSeed(resident.id));
        resident.crew.root.position.set(plaza.x, plaza.y, plaza.z);
        resident.crew.root.rotation.y = plaza.rotation;
        // This short boarding plank retracts with the landing party, before any
        // departure. It connects the fixed jetty to the side of the parked hull.
        const berthDistance = Math.hypot(resident.home.x - plaza.x, resident.home.z - plaza.z);
        const wood = this.material('boarding-plank', '#966747'), rope = this.material('boarding-rope', '#dec68d');
        this.box('ship-boarding-plank', [0.48, 0.065, 0.91], [0, 0.635 - plaza.y, berthDistance - 1.065], wood, resident.crew.root);
        for (const x of [-0.23, 0.23]) this.box('ship-boarding-edge', [0.027, 0.035, 0.91], [x, 0.68 - plaza.y, berthDistance - 1.065], rope, resident.crew.root);
      }
      resident.crew.animate(activity === 'working', this.elapsed + resident.phase, this.reducedMotion);
    }
    const count = resident.crew?.count ?? 0;
    resident.label.dataset.crewAshore = String(count);
    resident.label.dataset.crewActivity = resident.crew ? activity ?? '' : '';
    resident.actor.root.metadata = { ...resident.actor.root.metadata, crewAshore: count };
  }

  private clearCouriers(): void {
    for (const courier of this.couriers.values()) { courier.boat.dispose(); courier.wake.dispose(); courier.label.remove(); }
    this.couriers.clear();
  }

  focusResident(id: string): void {
    const resident = this.residents.find(item => item.id === id);
    if (!resident) return;
    this.selectedID = id;
    for (const item of this.residents) this.updateLabel(item);
    this.camera.setTarget(new Vector3(resident.motion.x, 0.8, resident.motion.z));
    this.camera.radius = Math.min(this.camera.radius, this.theme.environment === 'ocean' ? 16 : 14);
  }

  /** A paint/ship preference changes only artwork. The resident, berth, motion,
   * current work, selection, landing party and live Den Den signals stay put. */
  setShipStyles(styles: Readonly<Record<string, ShipAssetType>>): void {
    this.shipStyles = new Map(Object.entries(styles).filter(([, style]) => (SHIP_ASSET_TYPES as readonly string[]).includes(style)).map(([id, style]) => [id.toLowerCase(), style]));
    if (this.theme.environment !== 'ocean') return;
    for (const resident of this.residents) {
      const appearance = this.shipStyles.get(resident.id.toLowerCase()) ?? this.appearanceAssignments.get(resident.id) as ShipAssetType | undefined;
      if (!appearance || resident.actor.appearance === appearance) continue;
      const actor = resident.actor;
      // Keep the owning root: attention markers are parented to this exact node.
      actor.idle?.stop(); actor.walk?.stop(); actor.model?.dispose();
      actor.fallback = replaceShipFallback(this.scene, this.shadow, actor.root, appearance);
      actor.appearance = appearance; actor.model = undefined;
      actor.loadedAppearance = undefined; actor.idle = undefined; actor.walk = undefined;
      this.upgradeActor(actor);
      this.setActorWalking(actor, resident.motion.walking, true);
      resident.label.dataset.appearance = appearance;
      this.updateLabel(resident);
    }
  }

  setResidentStyle(style: ResidentStyle): void {
    if (this.residentStyle === style) return;
    this.residentStyle = style;
    if (this.theme.environment === 'ocean') return;
    for (const resident of this.residents) {
      const previous = resident.actor;
      const position = previous.root.position.clone();
      const rotation = previous.root.rotation.clone();
      previous.model?.dispose();
      previous.root.dispose();
      resident.actor = this.createActor(resident.id, ['#C9F54A', '#CDB382', '#D39F87', '#A6BB96'][residentSeed(resident.id) % 4], this.appearanceAssignments.get(resident.id) ?? previous.appearance);
      resident.actor.root.position.copyFrom(position);
      resident.actor.root.rotation.copyFrom(rotation);
      this.upgradeActor(resident.actor);
      resident.label.dataset.residentStyle = style;
      resident.label.dataset.residentKind = resident.actor.kind;
      resident.label.dataset.appearance = resident.actor.appearance;
    }
  }

  private residentKind(id: string, appearance: ResidentAssetType): ResidentKind {
    if (this.residentStyle === 'pandas') return 'panda';
    if (this.residentStyle === 'mixed') return this.crewAssignments.get(id) ?? 'person';
    return appearance === 'resident_explorer' ? 'person' : 'robot';
  }

  getAgentKind(id: string): ResidentKind | 'ship' | undefined {
    const appearance = this.appearanceAssignments.get(id);
    if (!appearance) return undefined;
    return this.theme.environment === 'ocean' ? 'ship' : this.residentKind(id, appearance);
  }

  getAgentAppearance(id: string): ResidentAssetType | undefined { return (this.theme.environment === 'ocean' ? this.shipStyles.get(id.toLowerCase()) : undefined) ?? this.appearanceAssignments.get(id); }

  getAgentHome(id: string): string | undefined {
    const index = this.harborAssignments.get(id);
    return this.theme.environment === 'ocean' && index !== undefined ? GRAND_LINE_HOME_NAMES[index] : undefined;
  }

  setNavigationMode(mode: 'orbit' | 'pan'): void {
    this.navigationMode = mode;
    this.camera.detachControl();
    this.camera.attachControl(false, true, mode === 'pan' ? 0 : 2);
    this.camera.panningSensibility = mode === 'pan' || this.theme.environment === 'ocean' ? 85 : 0;
    this.camera.inertialAlphaOffset = 0; this.camera.inertialBetaOffset = 0;
    this.canvas.style.cursor = mode === 'pan' ? 'move' : 'grab';
    this.canvas.dataset.navigationMode = mode;
  }

  panMap(direction: 'left' | 'right' | 'up' | 'down'): void {
    const step = Math.max(0.45, this.camera.radius * 0.025);
    const right = new Vector3(-Math.sin(this.camera.alpha), 0, Math.cos(this.camera.alpha));
    const forward = new Vector3(-Math.cos(this.camera.alpha), 0, -Math.sin(this.camera.alpha));
    const offset = direction === 'left' ? right.scale(-step) : direction === 'right' ? right.scale(step) : direction === 'up' ? forward.scale(step) : forward.scale(-step);
    const target = this.camera.target.add(offset);
    const limit = this.theme.layout.radius + 12;
    target.x = Math.max(-limit, Math.min(limit, target.x)); target.z = Math.max(-limit, Math.min(limit, target.z));
    this.camera.target.copyFrom(target);
  }

  resetView(): void {
    this.camera.inertialAlphaOffset = 0; this.camera.inertialBetaOffset = 0; this.camera.inertialRadiusOffset = 0;
    this.camera.inertialPanningX = 0; this.camera.inertialPanningY = 0;
    this.camera.setTarget(new Vector3(this.theme.environment === 'ocean' ? -2.5 : 0, 0.9, -0.4));
    this.camera.alpha = this.theme.environment === 'ocean' ? -Math.PI / 2 : Math.PI / 2 - 0.3;
    this.camera.beta = this.theme.environment === 'ocean' ? 0.74 : 1.01;
    this.camera.radius = this.theme.environment === 'ocean' ? 68 : 33;
  }

  setVisible(visible: boolean): void {
    this.visible = visible;
    this.setHovered(undefined);
    this.lastFrame = 0;
    if (visible) { this.resizeRenderer(); this.engine.runRenderLoop(this.render); }
    else { this.engine.stopRenderLoop(this.render); }
  }

  dispose(): void {
    this.assetRequests.abort();
    if (this.disposed) return;
    this.disposed = true;
    for (const cleanup of this.cleanups) cleanup();
    this.engine.stopRenderLoop();
    this.clearCouriers();
    this.encounters.clear();
    this.encounterVisuals?.dispose();
    this.islandWorkSignals?.dispose();
    this.newsCoo?.dispose();
    for (const resident of this.residents) resident.crew?.dispose();
    for (const snail of this.snails.values()) snail.dispose();
    this.snails.clear();
    this.labels.replaceChildren();
    this.ocean?.dispose();
    for (const container of this.containers.values()) container.dispose();
    this.scene.dispose();
    this.engine.dispose();
  }
}
