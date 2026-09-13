import { MaterialPluginBase } from '@babylonjs/core/Materials/materialPluginBase.js';
import type { PBRMaterial } from '@babylonjs/core/Materials/PBR/pbrMaterial.js';
import type { UniformBuffer } from '@babylonjs/core/Materials/uniformBuffer.js';

/** Moving highlights follow the model's painted water without moving its rock texture. */
export class WaterfallFlow extends MaterialPluginBase {
  private time = 0;
  private motion = 1;
  private disposed = false;

  constructor(material: PBRMaterial) {
    // Hard-bind registration is captured at activation time by Babylon.
    // Enable only after requesting the extra events so uniforms update even
    // when the PBR material remains cached between frames.
    super(material, 'LocusWaterfallFlow', 200, {}, true, false);
    this.registerForExtraEvents = true;
    this._enable(true);
  }

  getClassName(): string { return 'LocusWaterfallFlow'; }

  update(elapsed: number, reducedMotion: boolean): void {
    if (this.disposed) return;
    this.time = !reducedMotion && Number.isFinite(elapsed) ? Math.max(0, elapsed) % 4096 : 0;
    this.motion = reducedMotion ? 0 : 1;
  }

  hardBindForSubMesh(buffer: UniformBuffer): void {
    if (!this.disposed) buffer.updateFloat2('locusWaterfall', this.time, this.motion);
  }

  dispose(): void {
    this.disposed = true; this.time = 0; this.motion = 0;
  }

  getUniforms() {
    return {
      ubo: [{ name: 'locusWaterfall', size: 2, type: 'vec2' }],
      fragment: 'uniform vec2 locusWaterfall;',
    };
  }

  getCustomCode(shaderType: string): Record<string, string> | null {
    if (shaderType !== 'fragment') return null;
    return {
      CUSTOM_FRAGMENT_BEFORE_LIGHTS: `
        float locusWaterMask = smoothstep(0.008, 0.070, min(surfaceAlbedo.g, surfaceAlbedo.b) - surfaceAlbedo.r);
        locusWaterMask *= smoothstep(0.06, 0.3, surfaceAlbedo.g + surfaceAlbedo.b);
        float locusFlow = vPositionW.y * 8.0 + locusWaterfall.x * 5.8;
        float locusRivulets = sin(vPositionW.x * 23.0 + sin(vPositionW.z * 17.0));
        float locusFoam = pow(max(0.0, sin(locusFlow + locusRivulets * 1.5)), 5.0);
        float locusShimmer = 0.5 + 0.5 * sin(locusFlow * 0.41 + vPositionW.z * 11.0);
        surfaceAlbedo = mix(surfaceAlbedo, vec3(0.72, 0.94, 0.96),
          locusWaterMask * locusWaterfall.y * (locusFoam * 0.22 + locusShimmer * 0.035));
      `,
    };
  }
}
