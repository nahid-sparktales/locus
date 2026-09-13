import { Vector3, Matrix } from '@babylonjs/core/Maths/math.vector.js';
import type { Scene } from '@babylonjs/core/scene.js';
import type { TransformNode } from '@babylonjs/core/Meshes/transformNode.js';

export const LABOON_REACTION_SECONDS = 8;
const SONGS = ['♪ Bwooo~! ♫', 'A promise can cross any sea. ♪', '♪ An encore for the whole crew! ♫'];

export class LaboonReaction {
  selected = false;
  started = -Infinity;
  private song = -1;
  select(): void { this.selected = true; }
  dismiss(): void { this.selected = false; }
  sing(time: number): boolean {
    if (!this.selected || !Number.isFinite(time) || time < this.started + 0.6) return false;
    this.started = time; this.song = (this.song + 1) % SONGS.length; return true;
  }
  pose(time: number, reducedMotion: boolean) {
    const age = Number.isFinite(time) ? time - this.started : Infinity;
    const active = age >= 0 && age < LABOON_REACTION_SECONDS;
    const phase = active ? age : 0;
    const envelope = active && !reducedMotion ? Math.min(1, age * 2, (LABOON_REACTION_SECONDS - age) * 1.5) : 0;
    return {
      active, text: active ? SONGS[Math.max(0, this.song)] : 'A familiar song is all it takes.',
      bob: envelope * (0.08 + Math.abs(Math.sin(phase * 3.4)) * 0.22),
      sway: envelope * Math.sin(phase * 3.4) * 0.085,
      turn: envelope * Math.sin(phase * 1.7) * 0.12,
    };
  }
}

/** Purely local Easter egg. No audio, provider request, or agent task is created. */
export class LaboonCompanion {
  readonly reaction = new LaboonReaction();
  private panel: HTMLDivElement;
  private notes: HTMLSpanElement;
  private message: HTMLSpanElement;
  private prompt: HTMLButtonElement;
  private anchor = new Vector3();
  private elapsed = 0;
  private disposed = false;
  private scene: Scene;
  private whale: TransformNode;
  private baseY: number;
  private baseRotation: number;

  constructor(scene: Scene, whale: TransformNode) {
    this.scene = scene; this.whale = whale; this.baseY = whale.position.y; this.baseRotation = whale.rotation.y;
    this.panel = document.createElement('div'); this.panel.className = 'laboon-companion'; this.panel.hidden = true;
    this.panel.setAttribute('role', 'group'); this.panel.setAttribute('aria-label', 'Laboon the island whale');
    const heading = document.createElement('strong'); heading.textContent = 'Laboon';
    const close = document.createElement('button'); close.className = 'laboon-close'; close.textContent = '×'; close.type = 'button'; close.setAttribute('aria-label', 'Leave Laboon');
    this.message = document.createElement('span'); this.message.className = 'laboon-message'; this.message.setAttribute('role', 'status');
    this.prompt = document.createElement('button'); this.prompt.type = 'button'; this.prompt.textContent = 'E · Sing along'; this.prompt.setAttribute('aria-label', 'Sing with Laboon'); this.prompt.setAttribute('aria-keyshortcuts', 'E');
    this.notes = document.createElement('span'); this.notes.className = 'laboon-notes'; this.notes.textContent = '♪  ♫  ♪'; this.notes.setAttribute('aria-hidden', 'true');
    this.panel.append(heading, close, this.message, this.prompt, this.notes);
    document.getElementById('world-shell')?.append(this.panel);
    close.addEventListener('click', this.dismiss); this.prompt.addEventListener('click', this.sing);
    this.panel.addEventListener('keydown', this.keyDown);
  }

  select(): void { this.reaction.select(); this.panel.hidden = false; }
  private dismiss = (): void => { this.reaction.dismiss(); this.panel.hidden = true; this.scene.getEngine().getRenderingCanvas()?.focus({ preventScroll: true }); };
  private sing = (): void => { this.reaction.sing(this.elapsed); };
  private keyDown = (event: KeyboardEvent): void => {
    if (event.altKey || event.ctrlKey || event.metaKey) return;
    if (this.handleKey(event.key, event.repeat)) event.preventDefault();
  };
  handleKey(key: string, repeat = false): boolean {
    if (!this.reaction.selected || repeat) return false;
    if (key === 'Escape') { this.dismiss(); return true; }
    if (key.toLowerCase() !== 'e') return false;
    return this.reaction.sing(this.elapsed);
  }

  update(elapsed: number, reducedMotion: boolean): void {
    if (this.disposed) return;
    this.elapsed = elapsed;
    const pose = this.reaction.pose(elapsed, reducedMotion);
    this.whale.position.y = this.baseY + pose.bob;
    this.whale.rotation.z = pose.sway; this.whale.rotation.y = this.baseRotation + pose.turn;
    if (!this.reaction.selected) return;
    if (this.message.textContent !== pose.text) this.message.textContent = pose.text;
    this.notes.hidden = !pose.active;
    this.panel.dataset.dancing = String(pose.active && !reducedMotion);
    const camera = this.scene.activeCamera, engine = this.scene.getEngine(), canvas = engine.getRenderingCanvas();
    if (!camera || !canvas) return;
    const viewport = camera.viewport.toGlobal(engine.getRenderWidth(), engine.getRenderHeight());
    this.whale.computeWorldMatrix(true);
    Vector3.TransformCoordinatesToRef(new Vector3(0, 1.8, 0), this.whale.getWorldMatrix(), this.anchor);
    const projected = Vector3.Project(this.anchor, Matrix.IdentityReadOnly, this.scene.getTransformMatrix(), viewport);
    const x = projected.x / engine.getRenderWidth() * canvas.clientWidth, y = projected.y / engine.getRenderHeight() * canvas.clientHeight;
    const visible = projected.z >= 0 && projected.z <= 1 && x > 12 && x < canvas.clientWidth - 12 && y > 12 && y < canvas.clientHeight - 40;
    this.panel.hidden = !visible;
    if (visible) {
      this.panel.style.left = `${Math.max(112, Math.min(canvas.clientWidth - 112, x))}px`;
      this.panel.style.top = `${Math.max(this.panel.offsetHeight + 12, y - 8)}px`;
    }
  }

  dispose(): void {
    if (this.disposed) return; this.disposed = true;
    this.prompt.removeEventListener('click', this.sing); this.panel.removeEventListener('keydown', this.keyDown); this.panel.remove();
    this.reaction.dismiss();
  }
}
