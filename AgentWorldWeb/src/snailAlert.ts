import { fetchCompressedModel } from './assetBytes';
import { Engine } from '@babylonjs/core/Engines/engine';
import { Scene } from '@babylonjs/core/scene';
import { ArcRotateCamera } from '@babylonjs/core/Cameras/arcRotateCamera';
import { Color3, Color4 } from '@babylonjs/core/Maths/math.color';
import { Vector3 } from '@babylonjs/core/Maths/math.vector';
import { HemisphericLight } from '@babylonjs/core/Lights/hemisphericLight';
import { DirectionalLight } from '@babylonjs/core/Lights/directionalLight';
import { TransformNode } from '@babylonjs/core/Meshes/transformNode';
import { ImageProcessingConfiguration } from '@babylonjs/core/Materials/imageProcessingConfiguration';
import { LoadAssetContainerAsync } from '@babylonjs/core/Loading/sceneLoader';
import type { AssetContainer } from '@babylonjs/core/assetContainer';
import '@babylonjs/loaders/glTF';

export const SNAIL_ALERT_ASSET = './assets/models/den-den-mushi.glb';
export const COMMUNICATION_BEACON_ASSET = './themes/outpost/assets/beacon.glb.gz';
/** A tiny isolated viewport keeps the alert independent of map camera movement. */
class SnailViewport {
  private engine: Engine;
  private scene!: Scene;
  private model!: TransformNode;
  private container?: AssetContainer;
  private visible = true;
  private reduced = false;
  private disposed = false;
  private loaded = false;
  private ringing = false;
  private lastFrame = 0;
  private elapsed = 0;
  private resizeObserver?: ResizeObserver;

  constructor(private canvas: HTMLCanvasElement, private ocean: boolean, private onState: (state: 'loading' | 'ready' | 'unavailable') => void) {
    this.engine = new Engine(canvas, true, { alpha: true, premultipliedAlpha: true, audioEngine: false, powerPreference: 'low-power', preserveDrawingBuffer: false }, false);
    try {
    this.engine.setHardwareScalingLevel(1 / Math.min(window.devicePixelRatio || 1, 2));
    this.scene = new Scene(this.engine);
    this.scene.clearColor = new Color4(0, 0, 0, 0);
    this.scene.imageProcessingConfiguration.toneMappingEnabled = true;
    this.scene.imageProcessingConfiguration.toneMappingType = ImageProcessingConfiguration.TONEMAPPING_ACES;
    this.scene.imageProcessingConfiguration.exposure = 1.06;
    this.scene.skipPointerMovePicking = true;
    const camera = new ArcRotateCamera('snail-alert-camera', Math.PI / 2 - 0.28, 1.17, 3.2, new Vector3(0, 0.76, 0), this.scene);
    camera.fov = 0.69; camera.minZ = 0.03; camera.maxZ = 15;
    const ambient = new HemisphericLight('snail-alert-ambient', new Vector3(0, 1, 0), this.scene);
    ambient.intensity = 1.0; ambient.diffuse = ocean ? new Color3(1, 0.97, 0.88) : new Color3(0.97, 1, 0.91); ambient.groundColor = new Color3(0.52, 0.60, 0.59);
    const key = new DirectionalLight('snail-alert-key', new Vector3(-0.7, -1, -0.8), this.scene);
    key.intensity = 1.9; key.diffuse = ocean ? new Color3(1, 0.91, 0.76) : new Color3(0.95, 1, 0.86);
    const fill = new DirectionalLight('snail-alert-fill', new Vector3(0.7, -0.3, 0.4), this.scene);
    fill.intensity = 0.65; fill.diffuse = ocean ? new Color3(0.7, 0.91, 1) : new Color3(0.85, 0.97, 0.65);
    this.model = new TransformNode('snail-alert-model', this.scene);
    this.resizeObserver = new ResizeObserver(() => { if (!this.disposed) { this.engine.resize(); this.drawStill(); } });
    this.resizeObserver.observe(canvas);
    this.engine.onContextLostObservable.add(() => { this.loaded = false; this.engine.stopRenderLoop(); this.onState('unavailable'); });
    this.engine.onContextRestoredObservable.add(() => {
      if (!this.disposed && this.container) { this.loaded = true; this.onState('ready'); this.refreshLoop(); }
    });
    this.onState('loading');
    void this.load();
    } catch (error) {
      this.resizeObserver?.disconnect(); this.scene?.dispose(); this.engine.dispose();
      throw error;
    }
  }

  private async load(): Promise<void> {
    try {
      const path = this.ocean ? SNAIL_ALERT_ASSET : COMMUNICATION_BEACON_ASSET;
      const url = new URL(path, document.baseURI).href;
      const source = path.endsWith('.glb.gz') ? await fetchCompressedModel(url) : url;
      if (this.disposed) return;
      const container = await LoadAssetContainerAsync(source, this.scene, { pluginExtension: '.glb', name: path.replace(/\.gz$/, '') });
      if (this.disposed) { container.dispose(); return; }
      this.container = container;
      container.addAllToScene();
      for (const root of container.rootNodes) root.parent = this.model;
      for (const group of container.animationGroups) group.stop();
      for (const mesh of this.model.getChildMeshes()) { mesh.computeWorldMatrix(true); mesh.isPickable = false; }
      const bounds = this.model.getHierarchyBoundingVectors(true);
      const height = bounds.max.y - bounds.min.y, width = Math.max(bounds.max.x - bounds.min.x, bounds.max.z - bounds.min.z);
      if (!Number.isFinite(height) || height <= 0.0001 || !Number.isFinite(width)) throw new Error('Invalid communicator artwork');
      const scale = Math.min(1.67 / height, width > 0 ? 1.88 / width : Infinity);
      this.model.scaling.setAll(scale);
      this.model.position.set(-(bounds.min.x + bounds.max.x) / 2 * scale, -bounds.min.y * scale, -(bounds.min.z + bounds.max.z) / 2 * scale);
      for (const material of container.materials) for (const texture of material.getActiveTextures()) texture.anisotropicFilteringLevel = 8;
      // Reduced motion draws a still frame. Wait for texture uploads and shader
      // compilation so that first frame contains the communicator, not a blank canvas.
      await this.scene.whenReadyAsync();
      if (this.disposed) return;
      this.loaded = true;
      this.onState('ready');
      this.refreshLoop();
    } catch {
      if (!this.disposed) { this.container?.dispose(); this.container = undefined; this.onState('unavailable'); }
    }
  }

  setRinging(ringing: boolean): void { this.ringing = ringing; }
  setVisible(visible: boolean, reduced: boolean): void {
    if (this.disposed) return;
    this.visible = visible; this.reduced = reduced;
    this.refreshLoop();
  }
  private refreshLoop(): void {
    this.engine.stopRenderLoop(this.render);
    this.lastFrame = 0;
    if (!this.visible || !this.loaded || this.disposed) return;
    if (this.reduced) { this.model.rotation.setAll(0); this.drawStill(); }
    else this.engine.runRenderLoop(this.render);
  }
  private drawStill(): void {
    if (this.visible && this.loaded && !this.disposed) this.scene.render();
  }
  private render = (): void => {
    if (!this.visible || !this.loaded || this.disposed) return;
    const now = performance.now();
    if (now - this.lastFrame < 1000 / 20 - 1) return;
    this.elapsed += Math.min((now - (this.lastFrame || now)) / 1000, 0.05); this.lastFrame = now;
    const ringing = this.ocean && this.ringing && this.elapsed % 3.8 < 0.48;
    this.model.rotation.y = Math.sin(this.elapsed * 1.1) * 0.095;
    this.model.rotation.z = ringing ? Math.sin(this.elapsed * 24) * 0.018 : 0;
    this.scene.render();
  };
  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.resizeObserver?.disconnect(); this.engine.stopRenderLoop();
    this.container?.dispose(); this.scene.dispose(); this.engine.dispose();
  }
}

/** A persistent communicator opens the same center whether or not a call is pending. */
export class SnailAlert {
  private viewport?: SnailViewport;
  private visible = !document.hidden;
  private disposed = false;
  private pending = 0;
  private active = 0;
  private expanded = false;
  private demo = false;
  private ocean = false;
  private themeReady = false;
  private reducedPreference = matchMedia('(prefers-reduced-motion: reduce)');
  private readonly openButton: HTMLButtonElement;
  private readonly canvas: HTMLCanvasElement;

  constructor(private element: HTMLElement, private onToggle: () => void) {
    this.openButton = element.querySelector<HTMLButtonElement>('#snail-alert-open')!;
    this.canvas = element.querySelector<HTMLCanvasElement>('canvas')!;
    this.openButton.addEventListener('click', this.toggle);
    this.reducedPreference.addEventListener('change', this.motionChanged);
  }
  update(pending: number, active: number, demo: boolean): void {
    if (this.disposed) return;
    this.pending = pending; this.active = active; this.demo = demo;
    this.render();
  }
  setTheme(ocean: boolean): void {
    if (this.disposed || (this.themeReady && this.ocean === ocean)) return;
    this.themeReady = true;
    this.ocean = ocean;
    this.viewport?.dispose(); this.viewport = undefined;
    this.element.dataset.modelState = 'loading';
    this.render();
  }
  setExpanded(expanded: boolean): void { this.expanded = expanded; this.render(); }
  focus(): void { this.openButton.focus(); }
  setVisible(visible: boolean): void {
    if (this.disposed) return;
    this.visible = visible;
    if (visible) this.ensureViewport();
    this.viewport?.setVisible(visible, this.reducedPreference.matches);
  }
  private toggle = (): void => { this.onToggle(); };
  private motionChanged = (): void => { this.viewport?.setVisible(this.visible, this.reducedPreference.matches); };
  private ensureViewport(): void {
    if (this.viewport || !this.visible || this.disposed || !this.themeReady) return;
    try {
      this.viewport = new SnailViewport(this.canvas, this.ocean, state => { this.element.dataset.modelState = state; });
      this.viewport.setRinging(this.pending > 0);
      this.viewport.setVisible(this.visible, this.reducedPreference.matches);
    } catch { this.element.dataset.modelState = 'unavailable'; }
  }
  private render(): void {
    if (this.disposed) return;
    this.element.hidden = false;
    this.element.dataset.pending = String(this.pending > 0);
    this.element.dataset.expanded = String(this.expanded);
    this.element.dataset.communicator = this.ocean ? 'snail' : 'beacon';
    this.element.setAttribute('aria-label', this.ocean ? 'Den Den Dispatch communicator' : 'Outpost communications beacon');
    this.openButton.setAttribute('aria-expanded', String(this.expanded));
    const status = this.pending ? `${this.pending} need${this.pending === 1 ? 's' : ''} your attention` : this.active ? this.ocean ? `${this.active} ${this.active === 1 ? 'captain' : 'captains'} at work` : `${this.active} ${this.active === 1 ? 'agent' : 'agents'} at work` : this.ocean ? 'All quiet on the line' : 'All systems clear';
    const title = this.ocean ? 'Activity Center' : 'Mission Control';
    const eyebrow = this.ocean ? 'DEN DEN DISPATCH' : 'COMMS BEACON';
    this.element.querySelector('#snail-alert-name')!.textContent = title;
    this.element.querySelector('#snail-alert-eyebrow')!.textContent = `${this.demo ? 'DEMO · ' : ''}${eyebrow}`;
    this.element.querySelector('#snail-alert-kind')!.textContent = status;
    this.element.querySelector('#snail-alert-indicator')!.textContent = this.expanded ? '⌃' : '⌄';
    const badge = this.element.querySelector<HTMLElement>('#snail-alert-badge')!;
    badge.hidden = !this.pending; badge.textContent = String(this.pending);
    const label = `${this.expanded ? 'Close' : 'Open'} ${title}. ${this.demo ? 'Demo. ' : ''}${status}.`;
    this.openButton.setAttribute('aria-label', label);
    this.openButton.title = label;
    const summary = this.element.querySelector('#snail-alert-summary')!;
    const announcement = `${this.demo ? 'Demo. ' : ''}${status}.`;
    if (summary.textContent !== announcement) summary.textContent = announcement;
    this.ensureViewport();
    this.viewport?.setRinging(this.pending > 0);
  }
  dispose(): void {
    if (this.disposed) return;
    this.disposed = true; this.viewport?.dispose(); this.viewport = undefined;
    this.openButton.removeEventListener('click', this.toggle);
    this.reducedPreference.removeEventListener('change', this.motionChanged);
  }
}
