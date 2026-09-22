import { MaterialPluginBase } from '@babylonjs/core/Materials/materialPluginBase.js';
import type { PBRMaterial } from '@babylonjs/core/Materials/PBR/pbrMaterial.js';
import type { UniformBuffer } from '@babylonjs/core/Materials/uniformBuffer.js';
import type { Vector3 } from '@babylonjs/core/Maths/math.vector.js';
import type { TransformNode } from '@babylonjs/core/Meshes/transformNode.js';
import { GRAND_LINE_LANDMARKS } from './grandLineGeography.ts';

const TAU = Math.PI * 2;
const motionTime = (elapsed: number, reduced: boolean) => reduced || !Number.isFinite(elapsed) ? 0 : Math.max(0, elapsed);

/** Beyond the leftmost original islands in the screenshot's +Z camera view. */
export function zuneshaPose(elapsed: number, reduced = false) {
  const time = motionTime(elapsed, reduced), angle = time % 220 / 220 * TAU;
  const stride = (time % (TAU / 0.9)) * 0.9;
  return { x: 42 + Math.cos(angle) * 4, z: 1 + Math.sin(angle) * 11,
    y: reduced ? -0.18 : -0.18 + Math.sin(stride * 2) * 0.035,
    heading: Math.atan2(-4 * Math.sin(angle), 11 * Math.cos(angle)),
    roll: reduced ? 0 : Math.sin(stride) * 0.012 };
}

export function momonosukePose(elapsed: number, reduced = false) {
  const wano = GRAND_LINE_LANDMARKS.find(island => island.id === 'wano')!;
  const time = motionTime(elapsed, reduced), angle = time % 38 / 38 * TAU;
  return { x: wano.x + Math.cos(angle) * 5.2, z: wano.z + Math.sin(angle) * 4.3,
    y: 6.5 + (reduced ? 0 : Math.sin(angle * 2) * 0.8),
    heading: Math.atan2(-5.2 * Math.sin(angle), 4.3 * Math.cos(angle)),
    roll: reduced ? 0 : -0.16 + Math.sin(angle) * 0.06 };
}

export function moveCompanion(node: TransformNode, pose: ReturnType<typeof zuneshaPose>): void {
  node.position.set(pose.x, pose.y, pose.z);
  node.rotation.set(0, pose.heading, pose.roll);
}

/** Four alternating leg strokes on the supplied elephant mesh. The upper
 * body, island of Zou, tusks and central trunk keep their original geometry.
 * Deformation runs on the GPU and allocates no new meshes per frame. */
export class ZuneshaStride extends MaterialPluginBase {
  private time = 0;
  private motion = 1;
  private disposed = false;
  private minimum: Vector3;
  private span: Vector3;
  constructor(material: PBRMaterial, minimum: Vector3, span: Vector3) {
    super(material, 'LocusZuneshaStride', 210, {}, true, false);
    this.minimum = minimum; this.span = span;
    this.registerForExtraEvents = true; this._enable(true);
  }
  getClassName(): string { return 'LocusZuneshaStride'; }
  update(elapsed: number, reduced: boolean): void {
    this.time = motionTime(elapsed, reduced) % (TAU / 0.9 * 100);
    this.motion = reduced ? 0 : 1;
  }
  hardBindForSubMesh(buffer: UniformBuffer): void {
    if (this.disposed) return;
    buffer.updateFloat2('zuneshaGait', this.time, this.motion);
    buffer.updateVector3('zuneshaMinimum', this.minimum);
    buffer.updateVector3('zuneshaSpan', this.span);
  }
  getUniforms() {
    return { ubo: [{ name: 'zuneshaGait', size: 2, type: 'vec2' },
      { name: 'zuneshaMinimum', size: 3, type: 'vec3' }, { name: 'zuneshaSpan', size: 3, type: 'vec3' }],
      vertex: 'uniform vec2 zuneshaGait; uniform vec3 zuneshaMinimum; uniform vec3 zuneshaSpan;' };
  }
  getCustomCode(shaderType: string): Record<string, string> | null {
    if (shaderType !== 'vertex') return null;
    return { CUSTOM_VERTEX_UPDATE_POSITION: `
      vec3 elephant = (positionUpdated - zuneshaMinimum) / max(zuneshaSpan, vec3(0.0001));
      float belowBody = 1.0 - smoothstep(0.32, 0.55, elephant.y);
      float legSides = smoothstep(0.11, 0.20, abs(elephant.x - 0.5));
      float legDepth = smoothstep(0.03, 0.17, elephant.z) * (1.0 - smoothstep(0.83, 0.96, elephant.z));
      float legMask = belowBody * legSides * legDepth * zuneshaGait.y;
      float diagonal = (elephant.x - 0.5) * (elephant.z - 0.5) > 0.0 ? 0.0 : 3.14159265;
      float stride = sin(zuneshaGait.x * 0.9 + diagonal);
      positionUpdated.z += stride * zuneshaSpan.z * 0.055 * legMask;
      positionUpdated.y += max(0.0, stride) * zuneshaSpan.y * 0.020 * legMask;
    ` };
  }
  dispose(): void { this.disposed = true; this.motion = 0; }
}
