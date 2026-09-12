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
import '@babylonjs/loaders/glTF';
import { ShadowGenerator } from '@babylonjs/core/Lights/Shadows/shadowGenerator';
import { STATUS_META, findNearby, isTypingTarget, labelIsUnobscured, moveWithCollisions, residentPosition } from './state';
import type { Agent, Obstacle } from './state';
import type { Theme, AssetType } from './theme';

type Actor = { root: TransformNode; fallback: TransformNode; model?: InstantiatedEntries; idle?: AnimationGroup; walk?: AnimationGroup; body?: TransformNode; leftLeg?: TransformNode; rightLeg?: TransformNode; moving: boolean };
type Resident = { agent: Agent; actor: Actor; label: HTMLDivElement; ring: Mesh; x: number; z: number; id: string; phase: number };
type Callbacks = { onSelect: (id: string) => void; onNearby: (agent?: Agent) => void; onAssetFailure: () => void; onAssetProgress: (completed: number, total: number) => void; onGraphicsFailure: () => void };

export class OutpostWorld {
  private engine: Engine;
  private scene: Scene;
  private camera: ArcRotateCamera;
  private shadow: ShadowGenerator;
  private residents: Resident[] = [];
  private player: Actor;
  private stations: TransformNode[] = [];
  private containers = new Map<AssetType, AssetContainer>();
  private materials = new Map<string, StandardMaterial>();
  private obstacles: Obstacle[] = [];
  private propObstacles: Obstacle[] = [];
  private keys = new Set<string>();
  private visible = true;
  private disposed = false;
  private lastFrame = 0;
  private elapsed = 0;
  private reducedMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;
  private nearbyID?: string;
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
    this.hudOverlays = Array.from(document.querySelectorAll<HTMLElement>('.roster-panel, .world-header, .world-footer, .coordinate-label, #theme-popover, #interaction, #selection-note, #asset-loading, #asset-notice, #graphics-fallback'));
    this.mapRoot = new TransformNode('outpost', this.scene);

    this.camera = new ArcRotateCamera('explorer-camera', Math.PI / 2 - 0.18, 1.07, 20, new Vector3(0, 0.85, 4), this.scene);
    this.camera.lowerRadiusLimit = 8;
    this.camera.upperRadiusLimit = 43;
    this.camera.lowerBetaLimit = 0.42;
    this.camera.upperBetaLimit = 1.31;
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
    this.player = this.createActor('explorer', '#e49c59', true);
    this.player.root.position.set(theme.layout.playerSpawn.x, 0, theme.layout.playerSpawn.z);
    this.player.root.rotation.y = Math.PI;
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
    const floorColor = Color3.Lerp(Color3.FromHexString(this.theme.palette.ground), new Color3(0.6, 0.7, 0.66), 0.16).toHexString();
    const deck = this.material('deck', floorColor);
    const inner = this.material('inner-deck', '#263e47');
    const dark = this.material('navy-alloy', '#233d48');
    const trim = this.material('deck-trim', '#a5b8b2');
    const light = this.material('guide-light', this.theme.palette.accent, 0.9);
    const orange = this.material('safety-orange', '#e8a267', 0.12);
    const rock = this.material('bedrock', '#213b48');
    const base = MeshBuilder.CreateCylinder('floating-bedrock', { diameterTop: radius * 2 + 1, diameterBottom: radius * 1.5, height: 4.8, tessellation: 11, subdivisions: 2 }, this.scene);
    base.position.y = -3;
    base.material = rock;
    base.convertToFlatShadedMesh();
    base.parent = this.mapRoot;
    base.isPickable = false;
    this.cylinder('foundation', radius * 2 + 0.7, 0.8, -0.48, dark, 64);
    this.cylinder('upper-deck', radius * 2, 0.14, -0.1, deck, 64);
    this.ring('outer-rail-glow', radius * 2 - 0.45, 0.055, 0.035, light);
    this.ring('lower-rim', radius * 2 + 0.3, 0.11, -0.63, light);
    this.ring('orbit-lane-outer', 17, 0.065, 0.002, trim);
    this.ring('orbit-lane-inner', 14.8, 0.042, 0.005, trim);
    this.cylinder('arrival-pad', 6.2, 0.045, 0.002, dark);
    this.cylinder('arrival-inset', 5.3, 0.035, 0.03, inner);
    this.ring('arrival-guide', 5.7, 0.06, 0.045, light);
    this.ring('arrival-center', 3.9, 0.025, 0.055, trim);
    // The geometric L on the arrival platform reads from the overhead camera.
    this.box('arrival-logo-long', [0.3, 0.045, 1.35], [-0.39, 0.063, 0], trim);
    this.box('arrival-logo-foot', [1.0, 0.045, 0.3], [0, 0.063, 0.53], trim);
    for (let index = 0; index < 32; index++) {
      const angle = index * Math.PI * 2 / 32;
      const marking = this.box(`deck-marking-${index}`, [0.075, 0.018, index % 4 === 0 ? 0.45 : 0.2], [Math.sin(angle) * 6.9, 0.015, Math.cos(angle) * 6.9], trim);
      marking.rotation.y = angle;
    }
    for (let index = 0; index < 16; index++) {
      const angle = index * Math.PI * 2 / 16;
      const x = Math.sin(angle) * (radius - 0.13), z = Math.cos(angle) * (radius - 0.13);
      const bollard = this.box(`rim-bollard-${index}`, [0.18, 0.37, 0.18], [x, 0.2, z], dark);
      bollard.rotation.y = angle;
      this.box(`rim-lamp-${index}`, [0.13, 0.08, 0.13], [x, 0.42, z], index % 4 === 0 ? orange : light);
      const panel = this.box(`hull-panel-${index}`, [2.0, 0.45, 0.1], [Math.sin(angle) * (radius + 0.23), -0.45, Math.cos(angle) * (radius + 0.23)], trim);
      panel.rotation.y = angle;
    }
    for (const prop of this.theme.layout.props) {
      if (prop.collisionRadius) this.propObstacles.push({ x: prop.x, z: prop.z, radius: prop.collisionRadius });
      this.createPropFallback(prop.asset, prop.x, prop.z, prop.rotation || 0);
    }
    this.buildBackground();
  }

  private buildBackground(): void {
    const rock = this.material('satellite-rock', '#274350');
    for (let index = 0; index < 18; index++) {
      const angle = index * 2.39996;
      const distance = 19 + ((index * 7) % 19);
      const mesh = MeshBuilder.CreatePolyhedron(`orbiting-rock-${index}`, { type: index % 3, size: 0.7 + (index % 4) * 0.7 }, this.scene);
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

  private createPropFallback(type: 'beacon' | 'habitat' | 'crates', x: number, z: number, rotation: number): TransformNode {
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
    } else {
      const crate = this.box('cargo-crate', [1.2, 0.9, 0.9], [0, 0.45, 0], pearl, root);
      this.shadow.addShadowCaster(crate);
      this.box('cargo-strap', [0.17, 0.95, 0.95], [0, 0.46, 0], dark, root);
      this.box('cargo-indicator', [0.32, 0.12, 0.03], [0.32, 0.64, 0.47], light, root);
    }
    return root;
  }

  private createActor(name: string, accent: string, player = false): Actor {
    const root = new TransformNode(name, this.scene);
    const fallback = new TransformNode(`${name}-fallback`, this.scene);
    fallback.parent = root;
    const pearl = this.material('actor-shell', player ? '#d8ae79' : '#ccd4c6');
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
    for (const mesh of fallback.getChildMeshes()) { this.shadow.addShadowCaster(mesh); mesh.isPickable = !player; mesh.metadata = { actorID: player ? undefined : name }; }
    return { root, fallback, body, leftLeg: legs[0], rightLeg: legs[1], moving: false };
  }

  private createStation(x: number, z: number, rotation: number): TransformNode {
    const root = new TransformNode('workstation', this.scene);
    root.position.set(x, 0, z);
    root.rotation.y = rotation;
    const berth = this.box('workstation-berth', [2.35, 0.035, 2.2], [0, 0.005, 0], this.material('station-berth', '#344e59'), root);
    berth.receiveShadows = true;
    const marking = this.material('berth-markings', '#7ca89f', 0.05);
    this.box('berth-edge-left', [0.035, 0.045, 1.8], [-1.1, 0.035, 0], marking, root);
    this.box('berth-edge-right', [0.035, 0.045, 1.8], [1.1, 0.035, 0], marking, root);
    for (let stripe = 0; stripe < 3; stripe++) this.box('berth-access-stripe', [0.6, 0.025, 0.055], [0, 0.027, 1.1 + stripe * 0.17], marking, root);
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
    const instance = container.instantiateModelsToScene(name => `${parent.name}-${name}`, false, { doNotInstantiate: type === 'resident' || type === 'player' });
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
      mesh.isPickable = type === 'resident';
      mesh.metadata = { actorID: type === 'resident' ? parent.name : undefined };
      if (mesh instanceof Mesh) mesh.receiveShadows = true;
      this.shadow.addShadowCaster(mesh);
    }
    for (const group of instance.animationGroups) group.stop();
    return instance;
  }

  private upgradeActor(actor: Actor, type: 'resident' | 'player'): void {
    const container = this.containers.get(type);
    if (!container) return;
    try {
      actor.model = this.attachModel(type, actor.root, container);
      actor.fallback.setEnabled(false);
      actor.idle = actor.model.animationGroups.find(group => /idle|standing|breath/i.test(group.name));
      actor.walk = actor.model.animationGroups.find(group => /walk|running|run/i.test(group.name));
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
          if (type === 'player') this.upgradeActor(this.player, type);
          if (type === 'resident') for (const resident of this.residents) this.upgradeActor(resident.actor, type);
          if (type === 'station') this.rebuildStations();
          if (type === 'habitat' || type === 'beacon' || type === 'crates') {
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
    this.obstacles = [...this.propObstacles];
    for (const resident of this.residents) {
      const radius = Math.hypot(resident.x, resident.z) || 1;
      const x = resident.x + resident.x / radius * 1.15;
      const z = resident.z + resident.z / radius * 1.15;
      const station = this.createStation(x, z, Math.atan2(-resident.x, -resident.z));
      this.stations.push(station);
      this.obstacles.push({ x, z, radius: 0.8 }, { x: resident.x, z: resident.z, radius: 0.38 });
    }
  }

  setAgents(agents: Agent[], selectedID?: string, resetPlayer = false): void {
    this.selectedID = selectedID;
    if (resetPlayer) { this.player.root.position.set(this.theme.layout.playerSpawn.x, 0, this.theme.layout.playerSpawn.z); this.keys.clear(); }
    const sameResidents = agents.length === this.residents.length && agents.every((agent, index) => agent.id === this.residents[index].id);
    if (sameResidents) {
      for (let index = 0; index < agents.length; index++) { this.residents[index].agent = agents[index]; this.updateLabel(this.residents[index]); }
      if (this.nearbyID) this.callbacks.onNearby(this.residents.find(resident => resident.id === this.nearbyID)?.agent);
      return;
    }
    for (const resident of this.residents) { resident.actor.model?.dispose(); resident.actor.root.dispose(); resident.ring.dispose(); resident.label.remove(); }
    this.residents = agents.map((agent, index) => {
      const placement = this.theme.layout.stations[index] || residentPosition(index, agents.length);
      const actor = this.createActor(agent.id, ['#80c6b2', '#d2bb7e', '#d99874', '#a79ed4'][index % 4]);
      actor.root.position.set(placement.x, 0, placement.z);
      actor.root.rotation.y = placement.rotation ?? Math.atan2(-placement.x, -placement.z);
      this.upgradeActor(actor, 'resident');
      const label = document.createElement('div');
      label.className = 'agent-label';
      label.dataset.agentId = agent.id;
      const ring = this.ring(`resident-pad-${agent.id}`, 1.65, 0.035, 0.04, this.material('resident-pad', '#829c96', 0.1));
      ring.position.x = placement.x; ring.position.z = placement.z;
      const resident = { agent, actor, label, ring, x: placement.x, z: placement.z, id: agent.id, phase: index * 1.5 };
      this.labels.append(label);
      this.updateLabel(resident);
      return resident;
    });
    this.rebuildStations();
    this.nearbyID = undefined;
    this.callbacks.onNearby(undefined);
  }

  private updateLabel(resident: Resident): void {
    const meta = STATUS_META[resident.agent.status];
    resident.label.replaceChildren();
    const inner = document.createElement('div'); inner.className = 'agent-label-inner';
    const name = document.createElement('span'); name.className = 'agent-label-name'; name.textContent = resident.agent.name;
    const state = document.createElement('span'); state.className = 'agent-label-state'; state.textContent = meta.label;
    inner.append(name, state); resident.label.append(inner);
    resident.label.classList.toggle('selected', resident.id === this.selectedID);
    resident.label.style.setProperty('--status', meta.color);
    resident.ring.material = this.material('resident-pad', resident.id === this.selectedID ? '#a6f1dc' : '#829c96', resident.id === this.selectedID ? 0.8 : 0.1);
  }

  private buildInput(): void {
    const listen = <K extends keyof WindowEventMap>(type: K, listener: (event: WindowEventMap[K]) => void) => { window.addEventListener(type, listener); this.cleanups.push(() => window.removeEventListener(type, listener)); };
    listen('keydown', event => {
      if (isTypingTarget(event.target) || !this.visible) return;
      const key = event.key.toLowerCase();
      if (['w', 'a', 's', 'd', 'arrowup', 'arrowdown', 'arrowleft', 'arrowright', 'e'].includes(key)) {
        event.preventDefault();
        if (key === 'e' && !event.repeat && this.nearbyID) this.callbacks.onSelect(this.nearbyID);
        else this.keys.add(key);
      }
    });
    listen('keyup', event => this.keys.delete(event.key.toLowerCase()));
    listen('blur', () => this.keys.clear());
    listen('resize', () => this.engine.resize());
    const focusListener = () => { if (isTypingTarget(document.activeElement)) this.keys.clear(); };
    document.addEventListener('focusin', focusListener);
    this.cleanups.push(() => document.removeEventListener('focusin', focusListener));
    let pointerStart: { x: number; y: number } | undefined;
    const down = (event: PointerEvent) => { pointerStart = { x: event.clientX, y: event.clientY }; this.canvas.focus({ preventScroll: true }); };
    const up = (event: PointerEvent) => {
      if (!pointerStart || Math.hypot(event.clientX - pointerStart.x, event.clientY - pointerStart.y) > 6) { pointerStart = undefined; return; }
      pointerStart = undefined;
      const rect = this.canvas.getBoundingClientRect();
      const pick = this.scene.pick(event.clientX - rect.left, event.clientY - rect.top, mesh => typeof mesh.metadata?.actorID === 'string');
      if (pick?.pickedMesh?.metadata?.actorID) this.callbacks.onSelect(pick.pickedMesh.metadata.actorID);
    };
    this.canvas.addEventListener('pointerdown', down); this.canvas.addEventListener('pointerup', up);
    this.cleanups.push(() => { this.canvas.removeEventListener('pointerdown', down); this.canvas.removeEventListener('pointerup', up); });
    this.engine.onContextLostObservable.add(() => { this.keys.clear(); this.callbacks.onGraphicsFailure(); });
  }

  private setWalking(actor: Actor, moving: boolean): void {
    if (actor.moving === moving) return;
    actor.moving = moving;
    if (moving && actor.walk) { actor.idle?.stop(); actor.walk.start(true); }
    else { actor.walk?.stop(); if (!this.reducedMotion) actor.idle?.start(true); }
  }

  private render = (): void => {
    if (this.disposed || !this.visible || document.hidden) return;
    const now = performance.now();
    if (now - this.lastFrame < 1000 / 30 - 1) return;
    const dt = Math.min((now - (this.lastFrame || now)) / 1000, 0.05);
    this.lastFrame = now;
    this.elapsed += dt;
    this.updateMovement(dt);
    for (const resident of this.residents) {
      if (!this.reducedMotion && !resident.actor.model && resident.actor.body) {
        resident.actor.body.position.y = Math.sin(this.elapsed * 1.4 + resident.phase) * 0.017;
        // Real working status only; available residents do not simulate task activity.
        resident.actor.body.rotation.y = resident.agent.status === 'working' ? Math.sin(this.elapsed * 1.8 + resident.phase) * 0.045 : 0;
      }
    }
    this.scene.render();
    this.updateLabels();
  };

  private updateMovement(dt: number): void {
    const forward = Number(this.keys.has('w') || this.keys.has('arrowup')) - Number(this.keys.has('s') || this.keys.has('arrowdown'));
    const side = Number(this.keys.has('d') || this.keys.has('arrowright')) - Number(this.keys.has('a') || this.keys.has('arrowleft'));
    const moving = !isTypingTarget(document.activeElement) && !!(forward || side);
    this.setWalking(this.player, moving);
    if (moving) {
      const direction = this.camera.getTarget().subtract(this.camera.position); direction.y = 0; direction.normalize();
      const right = new Vector3(-direction.z, 0, direction.x);
      const desired = direction.scale(forward).add(right.scale(side)).normalize();
      const previous = this.player.root.position;
      const next = moveWithCollisions({ x: previous.x, z: previous.z }, { x: desired.x * dt * 3.7, z: desired.z * dt * 3.7 }, this.obstacles, this.theme.layout.radius);
      this.player.root.position.set(next.x, 0, next.z);
      const angle = Math.atan2(desired.x, desired.z);
      let difference = angle - this.player.root.rotation.y;
      difference = Math.atan2(Math.sin(difference), Math.cos(difference));
      this.player.root.rotation.y += difference * Math.min(1, dt * 13);
      if (!this.player.model) {
        if (this.player.leftLeg) this.player.leftLeg.rotation.x = Math.sin(this.elapsed * 11) * 0.5;
        if (this.player.rightLeg) this.player.rightLeg.rotation.x = -Math.sin(this.elapsed * 11) * 0.5;
        if (this.player.body) this.player.body.position.y = Math.abs(Math.sin(this.elapsed * 11)) * 0.035;
      }
    } else if (!this.player.model) {
      if (this.player.leftLeg) this.player.leftLeg.rotation.x = 0;
      if (this.player.rightLeg) this.player.rightLeg.rotation.x = 0;
      if (this.player.body) this.player.body.position.y = 0;
    }
    const target = this.player.root.position.add(new Vector3(0, 0.85, -1.5));
    this.camera.setTarget(Vector3.Lerp(this.camera.getTarget(), target, this.reducedMotion ? 1 : Math.min(1, dt * 4)));
    const nearby = findNearby(this.player.root.position, this.residents);
    if (nearby?.id !== this.nearbyID) { this.nearbyID = nearby?.id; this.callbacks.onNearby(nearby?.agent); }
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
    for (const resident of this.residents) {
      const projected = Vector3.Project(new Vector3(resident.x, 2.13, resident.z), Matrix.IdentityReadOnly, this.scene.getTransformMatrix(), viewport);
      const x = projected.x * scaleX, y = projected.y * scaleY;
      const halfWidth = resident.label.offsetWidth / 2;
      const bounds = { left: x - halfWidth, top: y - resident.label.offsetHeight, right: x + halfWidth, bottom: y };
      const visible = projected.z > 0 && projected.z < 1 && labelIsUnobscured(bounds, this.canvas.clientWidth, this.canvas.clientHeight, overlays);
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
    this.keys.clear();
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
