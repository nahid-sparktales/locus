import { MARINEFORD_CURRENT, GRAND_LINE_CALM_BELT } from './grandLineGeography.ts';
import { MeshBuilder } from '@babylonjs/core/Meshes/meshBuilder.js';
import { ShaderMaterial } from '@babylonjs/core/Materials/shaderMaterial.js';
import { Vector3 } from '@babylonjs/core/Maths/math.vector.js';
import { RawTexture } from '@babylonjs/core/Materials/Textures/rawTexture.js';
import { Texture } from '@babylonjs/core/Materials/Textures/texture.js';
import type { Scene } from '@babylonjs/core/scene.js';
import type { TransformNode } from '@babylonjs/core/Meshes/transformNode.js';

type IslandCoast = { x: number; z: number; radius: number };
export const MAX_OCEAN_COASTS = 20;
export const oceanTime = (elapsed: number, reducedMotion: boolean): number => reducedMotion || !Number.isFinite(elapsed) ? 0 : Math.max(0, elapsed) % 4096;

/** Periodic gradient noise gives a seamless, deterministic normal tile. The
 * two slope channels are calculated from one height field, so light follows
 * coherent ripples instead of unrelated noise in each direction. */
export function oceanNormalPixels(size = 256): Uint8Array {
  const width = Number.isFinite(size) ? Math.max(32, Math.min(256, Math.floor(size))) : 256, heights = new Float32Array(width * width);
  const gradients = [[1, 0], [-1, 0], [0, 1], [0, -1], [0.707, 0.707], [-0.707, 0.707], [0.707, -0.707], [-0.707, -0.707]];
  const smooth = (t: number) => t * t * t * (t * (t * 6 - 15) + 10);
  const noise = (x: number, y: number, period: number) => {
    const ix = Math.floor(x), iy = Math.floor(y), fx = x - ix, fy = y - iy;
    const corner = (dx: number, dy: number) => {
      let hash = Math.imul((ix + dx + period) % period + 13, 374761393) ^ Math.imul((iy + dy + period) % period + 37, 668265263);
      hash = Math.imul(hash ^ (hash >>> 13), 1274126177);
      const gradient = gradients[(hash ^ (hash >>> 16)) & 7];
      return gradient[0] * (fx - dx) + gradient[1] * (fy - dy);
    };
    const sx = smooth(fx), sy = smooth(fy), a = corner(0, 0), b = corner(1, 0), c = corner(0, 1), d = corner(1, 1);
    return (a + (b - a) * sx) * (1 - sy) + (c + (d - c) * sx) * sy;
  };
  for (let y = 0; y < width; y++) for (let x = 0; x < width; x++) {
    heights[y * width + x] = noise(x / width * 8, y / width * 8, 8) * 0.64
      + noise(x / width * 16 + 3.2, y / width * 16 + 5.7, 16) * 0.25
      + noise(x / width * 32 + 8.1, y / width * 32 + 2.4, 32) * 0.11;
  }
  const pixels = new Uint8Array(width * width * 4), encode = (value: number) => Math.round(Math.max(0, Math.min(1, value * 0.5 + 0.5)) * 255);
  const height = (x: number, y: number) => heights[((y + width) % width) * width + (x + width) % width];
  let maximumSlope = 0.0001;
  for (let y = 0; y < width; y++) for (let x = 0; x < width; x++) maximumSlope = Math.max(maximumSlope,
    Math.abs(height(x + 1, y) - height(x - 1, y)), Math.abs(height(x, y + 1) - height(x, y - 1)));
  const strength = 0.92 / maximumSlope;
  for (let y = 0; y < width; y++) for (let x = 0; x < width; x++) {
    const index = (y * width + x) * 4;
    pixels[index] = encode((height(x + 1, y) - height(x - 1, y)) * strength);
    pixels[index + 1] = encode((height(x, y + 1) - height(x, y - 1)) * strength);
    pixels[index + 2] = encode(height(x, y)); pixels[index + 3] = 255;
  }
  return pixels;
}

/** One local normal tile, sampled at several flowing scales, replaces the
 * screen-wide contour pattern. No reflection buffers or remote images. */
export function createOceanWater(scene: Scene, parent: TransformNode, islands: readonly IslandCoast[]) {
  const coasts = islands.slice(0, MAX_OCEAN_COASTS).filter(island => [island.x, island.z, island.radius].every(Number.isFinite) && island.radius > 0);
  const surface = MeshBuilder.CreateGround('endless-grand-line-ocean', { width: 260, height: 260, subdivisions: 150 }, scene);
  surface.parent = parent; surface.position.y = -0.19; surface.isPickable = false;
  // Wide whole-map views must never expose the square edge of the detailed sea.
  // Four distant vertices share its shader and texture without adding a render target.
  const horizon = MeshBuilder.CreateGround('grand-line-ocean-horizon', { width: 2400, height: 2400, subdivisions: 1 }, scene);
  horizon.parent = parent; horizon.position.y = -0.45; horizon.isPickable = false;
  const rippleNormal = RawTexture.CreateRGBATexture(oceanNormalPixels(), 256, 256, scene, true, false, Texture.TRILINEAR_SAMPLINGMODE);
  rippleNormal.name = 'local-ocean-ripple-normal'; rippleNormal.wrapU = Texture.WRAP_ADDRESSMODE; rippleNormal.wrapV = Texture.WRAP_ADDRESSMODE;
  rippleNormal.gammaSpace = false; rippleNormal.anisotropicFilteringLevel = 4;
  const material = new ShaderMaterial('grand-line-living-ocean', scene, {
    vertexSource: `precision highp float;
      attribute vec3 position;
      uniform mat4 worldViewProjection; uniform mat4 world; uniform float time;
      varying vec3 vPosition; varying vec3 vWorld;
      void main(void) {
        vec3 p = position;
        float calm = 1.0 - 0.72 * smoothstep(${GRAND_LINE_CALM_BELT.inner.toFixed(1)}, ${GRAND_LINE_CALM_BELT.solid.toFixed(1)}, abs(p.z)) * (1.0 - smoothstep(${GRAND_LINE_CALM_BELT.fade.toFixed(1)}, ${GRAND_LINE_CALM_BELT.outer.toFixed(1)}, abs(p.z)));
        p.y += (sin(dot(p.xz, vec2(0.19, 0.12)) - time * 0.23) * 0.042
          + sin(dot(p.xz, vec2(-0.09, 0.28)) - time * 0.31 + 1.7) * 0.026) * calm;
        vPosition = p; vWorld = (world * vec4(p, 1.0)).xyz;
        gl_Position = worldViewProjection * vec4(p, 1.0);
      }`,
    fragmentSource: `precision highp float;
      varying vec3 vPosition; varying vec3 vWorld;
      uniform float time; uniform vec3 cameraPosition; uniform vec3 marinefordCurrent;
      uniform sampler2D rippleNormal;
      uniform vec4 islandCoasts[${Math.max(1, coasts.length)}];
      float hash(vec2 p) {
        vec3 p3 = fract(vec3(p.xyx) * 0.1031);
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.x + p3.y) * p3.z);
      }
      float noise(vec2 p) {
        vec2 cell = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
        return mix(mix(hash(cell), hash(cell + vec2(1.0, 0.0)), f.x),
          mix(hash(cell + vec2(0.0, 1.0)), hash(cell + vec2(1.0, 1.0)), f.x), f.y);
      }
      float distanceToShore(vec2 p) {
        float shore = 100.0;
        for (int i = 0; i < ${coasts.length}; i++) {
          vec4 island = islandCoasts[i];
          vec2 local = (p - island.xy) * vec2(1.0, 1.25);
          float range = island.z * 1.2 + 3.1;
          if (dot(local, local) < range * range) {
            float radial = length(local), a = atan(local.y, local.x);
            float contour = 1.0 + sin(a * 3.0 + island.w) * 0.065 + cos(a * 5.0 - island.w) * 0.035 + sin(a * 9.0 + island.w * 2.0) * 0.012;
            shore = min(shore, radial - island.z * 1.07 * contour);
          }
        }
        return shore;
      }
      void main(void) {
        vec2 p = vPosition.xz;
        float calm = smoothstep(${GRAND_LINE_CALM_BELT.inner.toFixed(1)}, ${GRAND_LINE_CALM_BELT.solid.toFixed(1)}, abs(p.y)) * (1.0 - smoothstep(${GRAND_LINE_CALM_BELT.fade.toFixed(1)}, ${GRAND_LINE_CALM_BELT.outer.toFixed(1)}, abs(p.y)));
        // Two very broad currents bend the wave trains, so their highlights
        // never form straight light shafts or a repeating fingerprint grid.
        vec2 flow = vec2(noise(p * 0.09 + vec2(time * 0.012, 2.8)), noise(p * 0.073 + vec2(8.3, -time * 0.010))) - 0.5;
        vec2 q = p + flow * 3.8;
        vec2 windUV = vec2(dot(q, vec2(0.92, 0.39)), dot(q, vec2(-0.39, 0.92)));
        vec2 smallUV = vec2(dot(q, vec2(0.61, -0.79)), dot(q, vec2(0.79, 0.61)));
        vec2 broad = texture2D(rippleNormal, windUV * vec2(0.053, 0.097) + vec2(time * 0.009, time * 0.006)).rg * 2.0 - 1.0;
        vec2 fine = texture2D(rippleNormal, smallUV * vec2(0.139, 0.173) + vec2(-time * 0.013, time * 0.009) + 0.37).rg * 2.0 - 1.0;
        float farDetail = 1.0 - smoothstep(55.0, 125.0, length(cameraPosition - vWorld));
        vec2 micro = texture2D(rippleNormal, windUV * vec2(0.337, 0.419) + vec2(time * 0.018, -time * 0.011) + 0.71).rg * 2.0 - 1.0;
        vec2 slope = broad * 0.24 + fine * 0.16 + micro * (0.07 * farDetail);
        slope *= (1.0 - calm * 0.66) * mix(0.58, 1.0, farDetail);
        vec3 normal = normalize(vec3(-slope.x, 1.0, -slope.y));
        vec3 view = normalize(cameraPosition - vWorld);
        float facing = clamp(dot(normal, view), 0.0, 1.0);
        float shore = distanceToShore(p);
        float shelf = 1.0 - smoothstep(0.10, 2.65, shore);
        float shallows = 1.0 - smoothstep(-0.15, 0.76, shore);
        float depth = smoothstep(22.0, 85.0, length(p * vec2(0.72, 1.0)));
        float depthVariation = noise(p * 0.065 + vec2(12.6, 3.7));
        vec3 color = mix(vec3(0.026, 0.445, 0.535), vec3(0.022, 0.265, 0.365), depth);
        color += vec3(0.006, 0.045, 0.036) * (depthVariation - 0.35);
        color = mix(color, vec3(0.12, 0.53, 0.49), calm * 0.32);
        color = mix(color, vec3(0.085, 0.655, 0.635), shelf * 0.82);
        color = mix(color, vec3(0.36, 0.755, 0.665), shallows * 0.60);
        // The sea reflects a broad sky gradient. Fresnel adds gloss at grazing
        // angles while the overhead view retains clear turquoise depth.
        vec3 reflected = reflect(-view, normal);
        vec3 sky = mix(vec3(0.59, 0.77, 0.76), vec3(0.15, 0.43, 0.54), smoothstep(0.0, 0.92, reflected.y));
        float cloud = noise(reflected.xz * 4.2 + vec2(7.0, 2.0));
        sky = mix(sky, vec3(0.77, 0.86, 0.82), smoothstep(0.57, 0.82, cloud) * 0.22);
        float fresnel = 0.035 + 0.38 * pow(1.0 - facing, 4.0);
        color = mix(color, sky, fresnel);
        vec3 sun = normalize(vec3(-0.36, 0.82, 0.45));
        float sunFacing = max(0.0, dot(normal, normalize(sun + view)));
        float glint = pow(sunFacing, 310.0) * 0.13 + pow(sunFacing, 44.0) * 0.022;
        color += vec3(0.96, 0.91, 0.72) * glint * (0.65 + noise(q * 0.83) * 0.35);
        color *= 0.98 + dot(normal, sun) * 0.045;
        // Caustics exist only in shallow water, as soft flecks rather than a
        // screen-wide line network. Shore wash breaks up as each wave recedes.
        float seabedLight = noise(q * 2.4 + vec2(time * 0.045, -time * 0.03));
        color += vec3(0.14, 0.20, 0.14) * smoothstep(0.60, 0.88, seabedLight) * shelf * 0.11;
        float washNoise = noise(p * 3.2 + flow * 1.5 + vec2(time * 0.08, -time * 0.055));
        float washPhase = shore * 6.8 - time * 0.66 + washNoise * 2.2;
        float wash = pow(max(0.0, sin(washPhase)), 5.0);
        float foam = wash * smoothstep(-0.04, 0.10, shore) * (1.0 - smoothstep(0.25, 0.83, shore));
        foam *= smoothstep(0.25, 0.63, washNoise);
        float lace = (1.0 - smoothstep(0.02, 0.14, abs(shore - 0.07))) * smoothstep(0.42, 0.74, washNoise);
        color = mix(color, vec3(0.80, 0.94, 0.87), clamp(foam * 0.62 + lace * 0.24, 0.0, 0.68));
        // A small three-armed whirlpool in the Marineford triangle. Its dark
        // center and broken foam rotate with ocean time, which freezes for
        // reduced motion. It is surface decoration, never a navigation hazard.
        vec2 vortex = (p - marinefordCurrent.xy) / marinefordCurrent.z;
        float vr = length(vortex);
        float vortexMask = 1.0 - smoothstep(0.68, 1.0, vr);
        float angle = atan(vortex.y, vortex.x);
        float spiral = sin(angle * 3.0 + vr * 19.0 + time * 0.85);
        float streak = smoothstep(0.78, 0.97, spiral) * smoothstep(0.10, 0.24, vr);
        float breakup = 0.62 + 0.38 * noise(vortex * 13.0 + vec2(time * 0.07));
        color = mix(color, vec3(0.018, 0.23, 0.30), vortexMask * (0.35 + 0.22 * (1.0 - smoothstep(0.0, 0.22, vr))));
        color = mix(color, vec3(0.56, 0.83, 0.79), streak * breakup * vortexMask * 0.70);
        gl_FragColor = vec4(color, 1.0);
      }`,
  }, { attributes: ['position'], uniforms: ['worldViewProjection', 'world', 'time', 'cameraPosition', 'islandCoasts', 'marinefordCurrent'], samplers: ['rippleNormal'] });
  material.setVector3('marinefordCurrent', new Vector3(MARINEFORD_CURRENT.x, MARINEFORD_CURRENT.z, MARINEFORD_CURRENT.radius));
  material.setFloat('time', 0); material.setVector3('cameraPosition', new Vector3(0, 30, -40));
  material.setArray4('islandCoasts', coasts.length ? coasts.flatMap((island, index) => [island.x, island.z, island.radius, index * 2.3999632297 + 0.73]) : [0, 0, 0, 0]);
  material.setTexture('rippleNormal', rippleNormal);
  surface.material = material;
  horizon.material = material;
  let disposed = false;
  return {
    surface, material,
    update(elapsed: number, reducedMotion: boolean) {
      if (disposed) return;
      material.setFloat('time', oceanTime(elapsed, reducedMotion));
      const camera = scene.activeCamera?.globalPosition;
      if (camera && [camera.x, camera.y, camera.z].every(Number.isFinite)) material.setVector3('cameraPosition', camera);
    },
    dispose() { if (disposed) return; disposed = true; surface.dispose(); horizon.dispose(); material.dispose(); rippleNormal.dispose(); },
  };
}
