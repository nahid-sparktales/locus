import { Color3 } from '@babylonjs/core/Maths/math.color';
import { PBRMaterial } from '@babylonjs/core/Materials/PBR/pbrMaterial';
import { MaterialPluginBase } from '@babylonjs/core/Materials/materialPluginBase';
import type { AssetContainer } from '@babylonjs/core/assetContainer';

/** Locus/Theme.swift owns these colors; the campus uses paper, charcoal and
 * the original lime accent, with the same sage/teal/amber content colors. */
export const LOCUS_OUTPOST_PALETTE = {
  paper: '#F3F1EA',
  paperDeep: '#ECE9E0',
  ivory: '#F2EEE4',
  charcoal: '#171713',
  charcoalRaised: '#20201B',
  alloy: '#292820',
  line: '#3D3B32',
  muted: '#ADA89A',
  lime: '#C9F54A',
  logoLime: '#DAF66C',
  sage: '#A6BB96',
  sageDeep: '#46613E',
  // Midpoint of native sageDeep and sage, for softly shaded planting.
  sageMid: '#768E6A',
  sageSoft: '#E2E9DB',
  teal: '#92B9B5',
  tealDeep: '#396B69',
  amber: '#CDB382',
  clay: '#D39F87',
  mauve: '#C1A4BD',
  blue: '#9AAEC4',
} as const;

const tintedContainers = new WeakSet<AssetContainer>();
class LocusSceneryColors extends MaterialPluginBase {
  constructor(material: PBRMaterial) {
    super(material, 'LocusSceneryColors', 200, {}, true, true);
  }

  getCustomCode(shaderType: string): { [pointName: string]: string } | null {
    if (shaderType !== 'fragment') return null;
    return {
      CUSTOM_FRAGMENT_BEFORE_LIGHTS: `
        // Preserve painted seams and wear while changing the outpost's old
        // navy/cyan/orange finishes to charcoal and the Locus lime accent.
        float locusLuma = dot(surfaceAlbedo, vec3(0.2126, 0.7152, 0.0722));
        float locusCool = smoothstep(0.012, 0.065, min(surfaceAlbedo.g, surfaceAlbedo.b) - surfaceAlbedo.r);
        float locusBlue = smoothstep(0.012, 0.055, surfaceAlbedo.b - surfaceAlbedo.r);
        float locusMax = max(surfaceAlbedo.r, max(surfaceAlbedo.g, surfaceAlbedo.b));
        float locusSaturation = (locusMax - min(surfaceAlbedo.r, min(surfaceAlbedo.g, surfaceAlbedo.b))) / max(locusMax, 0.0001);
        float locusOrange = smoothstep(0.38, 0.68, locusSaturation) * smoothstep(0.025, 0.12, surfaceAlbedo.r - surfaceAlbedo.g) * smoothstep(0.04, 0.16, surfaceAlbedo.r - surfaceAlbedo.b);
        float locusAccent = max(locusCool * smoothstep(0.09, 0.23, locusLuma), locusOrange);
        vec3 locusNeutral = vec3(1.0, 0.975, 0.89) * locusLuma;
        surfaceAlbedo = mix(surfaceAlbedo, locusNeutral, locusBlue * (1.0 - locusAccent));
        surfaceAlbedo = mix(surfaceAlbedo, vec3(0.584, 0.913, 0.069) * (0.48 + locusLuma * 0.7), locusAccent);
      `,
    };
  }
}

/** Recolor the packaged scenery's painted finishes toward Locus paper/lime.
 * Call only for campus artwork. Ocean artwork stays original and no texture
 * or model files are rewritten. */
export function applyLocusSceneryTint(container: AssetContainer): void {
  if (tintedContainers.has(container)) return;
  tintedContainers.add(container);
  const paperTint = new Color3(1, 0.965, 0.89);
  for (const material of container.materials) {
    if (material instanceof PBRMaterial) {
      material.albedoColor = material.albedoColor.multiply(paperTint);
      new LocusSceneryColors(material);
    }
  }
}
