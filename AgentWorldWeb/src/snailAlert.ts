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
import { selectAttentionRequest } from './snailAlertState';
import type { Agent, AttentionRequest } from './state';

export const SNAIL_ALERT_ASSET = './assets/models/den-den-mushi.glb';
const DISPLAY_PREFERENCE = 'locus.agentWorld.pingPing.display.v1';
type AlertDisplay = 'expanded' | 'collapsed' | 'hidden';
function savedDisplay(): AlertDisplay {
  try { const value = localStorage.getItem(DISPLAY_PREFERENCE); return value === 'collapsed' || value === 'hidden' ? value : 'expanded'; }
  catch { return 'expanded'; }
}

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
  private lastFrame = 0;
  private elapsed = 0;
  private resizeObserver?: ResizeObserver;

  constructor(private canvas: HTMLCanvasElement, private onState: (state: 'loading' | 'ready' | 'unavailable') => void) {
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
    ambient.intensity = 1.0; ambient.diffuse = new Color3(1, 0.97, 0.88); ambient.groundColor = new Color3(0.52, 0.60, 0.59);
    const key = new DirectionalLight('snail-alert-key', new Vector3(-0.7, -1, -0.8), this.scene);
    key.intensity = 1.9; key.diffuse = new Color3(1, 0.91, 0.76);
    const fill = new DirectionalLight('snail-alert-fill', new Vector3(0.7, -0.3, 0.4), this.scene);
    fill.intensity = 0.65; fill.diffuse = new Color3(0.7, 0.91, 1);
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
      const container = await LoadAssetContainerAsync(new URL(SNAIL_ALERT_ASSET, document.baseURI).href, this.scene);
      if (this.disposed) { container.dispose(); return; }
      this.container = container;
      container.addAllToScene();
      for (const root of container.rootNodes) root.parent = this.model;
      for (const group of container.animationGroups) group.stop();
      for (const mesh of this.model.getChildMeshes()) { mesh.computeWorldMatrix(true); mesh.isPickable = false; }
      const bounds = this.model.getHierarchyBoundingVectors(true);
      const height = bounds.max.y - bounds.min.y, width = Math.max(bounds.max.x - bounds.min.x, bounds.max.z - bounds.min.z);
      if (!Number.isFinite(height) || height <= 0.0001 || !Number.isFinite(width)) throw new Error('Invalid snail artwork');
      const scale = Math.min(1.67 / height, width > 0 ? 1.88 / width : Infinity);
      this.model.scaling.setAll(scale);
      this.model.position.set(-(bounds.min.x + bounds.max.x) / 2 * scale, -bounds.min.y * scale, -(bounds.min.z + bounds.max.z) / 2 * scale);
      for (const material of container.materials) for (const texture of material.getActiveTextures()) texture.anisotropicFilteringLevel = 8;
      this.loaded = true;
      this.onState('ready');
      this.refreshLoop();
    } catch {
      if (!this.disposed) { this.container?.dispose(); this.container = undefined; this.onState('unavailable'); }
    }
  }

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
    const ringing = this.elapsed % 3.8 < 0.48;
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

export class SnailAlert {
  private display = savedDisplay();
  private requests: readonly AttentionRequest[] = [];
  private agents: readonly Agent[] = [];
  private currentID?: string;
  private viewport?: SnailViewport;
  private visible = !document.hidden;
  private demo = false;
  private disposed = false;
  private reducedPreference = matchMedia('(prefers-reduced-motion: reduce)');
  private readonly openButton: HTMLButtonElement;
  private readonly previous: HTMLButtonElement;
  private readonly next: HTMLButtonElement;
  private readonly canvas: HTMLCanvasElement;
  private readonly collapseButton: HTMLButtonElement;
  private readonly hideButton: HTMLButtonElement;
  private readonly compactButton: HTMLButtonElement;
  private readonly compactHideButton: HTMLButtonElement;
  private readonly restoreButton: HTMLButtonElement;

  constructor(private element: HTMLElement, private onOpen: (requestID: string) => void) {
    this.openButton = element.querySelector<HTMLButtonElement>('#snail-alert-open')!;
    this.previous = element.querySelector<HTMLButtonElement>('#snail-alert-previous')!;
    this.next = element.querySelector<HTMLButtonElement>('#snail-alert-next')!;
    this.canvas = element.querySelector<HTMLCanvasElement>('canvas')!;
    this.collapseButton = element.querySelector<HTMLButtonElement>('#snail-alert-collapse')!;
    this.hideButton = element.querySelector<HTMLButtonElement>('#snail-alert-hide')!;
    this.compactButton = element.querySelector<HTMLButtonElement>('#snail-alert-expand')!;
    this.compactHideButton = element.querySelector<HTMLButtonElement>('#snail-alert-compact-hide')!;
    this.restoreButton = element.querySelector<HTMLButtonElement>('#snail-alert-restore')!;
    this.openButton.addEventListener('click', this.openCurrent);
    this.previous.addEventListener('click', this.showPrevious);
    this.next.addEventListener('click', this.showNext);
    this.reducedPreference.addEventListener('change', this.motionChanged);
    this.collapseButton.addEventListener('click', this.collapse);
    this.hideButton.addEventListener('click', this.hide);
    this.compactButton.addEventListener('click', this.expand);
    this.compactHideButton.addEventListener('click', this.hide);
    this.restoreButton.addEventListener('click', this.expand);
  }
  update(requests: readonly AttentionRequest[], agents: readonly Agent[], demo: boolean): void {
    if (this.disposed) return;
    this.requests = requests; this.agents = agents; this.demo = demo;
    this.currentID = selectAttentionRequest(requests, this.currentID)?.id;
    this.render();
  }
  setVisible(visible: boolean): void {
    if (this.disposed) return;
    this.visible = visible;
    if (visible) this.ensureViewport();
    this.viewport?.setVisible(visible && this.requests.length > 0 && this.display === 'expanded', this.reducedPreference.matches);
  }
  private changeDisplay(display: AlertDisplay): void {
    this.display = display;
    try { localStorage.setItem(DISPLAY_PREFERENCE, display); } catch { /* Keep controls usable when storage is unavailable. */ }
    this.render();
    (display === 'expanded' ? this.collapseButton : display === 'collapsed' ? this.compactButton : this.restoreButton).focus();
  }
  private collapse = (): void => { this.changeDisplay('collapsed'); };
  private hide = (): void => { this.changeDisplay('hidden'); };
  private expand = (): void => { this.changeDisplay('expanded'); };
  private openCurrent = (): void => {
    const request = this.requests.find(item => item.id === this.currentID);
    if (request) this.onOpen(request.id);
  };
  private showPrevious = (): void => { this.currentID = selectAttentionRequest(this.requests, this.currentID, -1)?.id; this.render(); };
  private showNext = (): void => { this.currentID = selectAttentionRequest(this.requests, this.currentID, 1)?.id; this.render(); };
  private motionChanged = (): void => { this.viewport?.setVisible(this.visible && this.requests.length > 0 && this.display === 'expanded', this.reducedPreference.matches); };
  private ensureViewport(): void {
    if (this.viewport || !this.visible || !this.requests.length || this.disposed || this.display !== 'expanded') return;
    try {
      this.viewport = new SnailViewport(this.canvas, state => { this.element.dataset.modelState = state; });
      this.viewport.setVisible(this.visible, this.reducedPreference.matches);
    } catch { this.element.dataset.modelState = 'unavailable'; }
  }
  private render(): void {
    const request = selectAttentionRequest(this.requests, this.currentID);
    this.element.hidden = !request;
    this.element.dataset.display = this.display;
    document.body.dataset.snailAlert = String(!!request);
    if (!request) {
      delete this.element.dataset.requestId;
      this.viewport?.dispose(); this.viewport = undefined;
      return;
    }
    const name = this.agents.find(agent => agent.id.toLowerCase() === request.agentID.toLowerCase())?.name ?? 'An agent';
    const kind = request.kind === 'approval' ? 'Approval needed' : 'Your input is needed';
    this.element.dataset.requestId = request.id;
    this.element.querySelector('#snail-alert-name')!.textContent = name;
    this.element.querySelector('#snail-alert-kind')!.textContent = kind;
    this.element.querySelector('#snail-alert-title')!.textContent = request.title;
    this.element.querySelector('#snail-alert-eyebrow')!.textContent = this.demo ? 'DEMO · PING PING' : 'PING PING';
    const index = this.requests.findIndex(item => item.id === request.id);
    this.element.querySelector('#snail-alert-count')!.textContent = `${index + 1} of ${this.requests.length} requests`;
    this.element.querySelector<HTMLElement>('#snail-alert-navigation')!.hidden = this.requests.length < 2 || this.display !== 'expanded';
    this.element.querySelector<HTMLElement>('#snail-alert-toolbar')!.hidden = this.display !== 'expanded';
    this.openButton.hidden = this.display !== 'expanded';
    this.element.querySelector<HTMLElement>('#snail-alert-compact')!.hidden = this.display !== 'collapsed';
    this.restoreButton.hidden = this.display !== 'hidden';
    this.element.querySelector('#snail-alert-compact-name')!.textContent = this.demo ? 'Demo · Ping Ping' : 'Ping Ping';
    this.element.querySelector('#snail-alert-compact-count')!.textContent = String(this.requests.length);
    this.compactButton.setAttribute('aria-label', `Expand Ping Ping. ${this.requests.length} pending request${this.requests.length === 1 ? '' : 's'}.`);
    this.restoreButton.textContent = `Show alerts · ${this.requests.length}`;
    this.restoreButton.setAttribute('aria-label', `Show Ping Ping alerts. ${this.requests.length} pending request${this.requests.length === 1 ? '' : 's'}.`);
    this.openButton.setAttribute('aria-label', `${this.demo ? 'Demo request. ' : ''}${name}. ${kind}. ${request.title}. Check this request.`);
    this.openButton.title = `${name}: ${request.title}`;
    const summary = this.element.querySelector('#snail-alert-summary')!;
    const announcement = `${this.demo ? 'Demo. ' : ''}${this.requests.length} pending request${this.requests.length === 1 ? '' : 's'}. ${name}. ${kind}.`;
    if (summary.textContent !== announcement) summary.textContent = announcement;
    if (this.display === 'expanded') this.ensureViewport();
    else { this.viewport?.dispose(); this.viewport = undefined; this.element.dataset.modelState = 'loading'; }
  }
  dispose(): void {
    if (this.disposed) return;
    this.disposed = true; this.viewport?.dispose(); this.viewport = undefined;
    this.openButton.removeEventListener('click', this.openCurrent);
    this.previous.removeEventListener('click', this.showPrevious);
    this.next.removeEventListener('click', this.showNext);
    this.reducedPreference.removeEventListener('change', this.motionChanged);
    this.collapseButton.removeEventListener('click', this.collapse);
    this.hideButton.removeEventListener('click', this.hide);
    this.compactButton.removeEventListener('click', this.expand);
    this.compactHideButton.removeEventListener('click', this.hide);
    this.restoreButton.removeEventListener('click', this.expand);
  }
}
