import { Mesh } from '@babylonjs/core/Meshes/mesh.js';
import { MeshBuilder } from '@babylonjs/core/Meshes/meshBuilder.js';
import { ShaderMaterial } from '@babylonjs/core/Materials/shaderMaterial.js';
import { TransformNode } from '@babylonjs/core/Meshes/transformNode.js';
import type { Scene } from '@babylonjs/core/scene.js';

/** A fixed, small pool of soft spray at the foot of the mountain waterfalls. */
export function createWaterfallMist(scene: Scene, parent: TransformNode) {
  const root = new TransformNode('waterfall-spray', scene); root.parent = parent;
  const material = new ShaderMaterial('waterfall-mist', scene, {
    vertexSource: `precision highp float;
      attribute vec3 position; attribute vec2 uv;
      uniform mat4 worldViewProjection; varying vec2 vUV;
      void main() { vUV = uv; gl_Position = worldViewProjection * vec4(position, 1.0); }`,
    fragmentSource: `precision highp float;
      varying vec2 vUV;
      void main() {
        vec2 p = (vUV - 0.5) * 2.0;
        float softness = pow(max(0.0, 1.0 - dot(p, p)), 3.0);
        float wisps = 0.72 + 0.28 * sin(p.x * 11.0 + sin(p.y * 8.0));
        gl_FragColor = vec4(0.80, 0.96, 0.95, softness * wisps * 0.095);
      }`,
  }, { attributes: ['position', 'uv'], uniforms: ['worldViewProjection'], needAlphaBlending: true });
  material.backFaceCulling = false; material.disableDepthWrite = true;
  const particles = [-1, 1].flatMap(sign => Array.from({ length: 6 }, (_, index) => {
    const angle = index / 6 * Math.PI * 2;
    const mesh = MeshBuilder.CreatePlane('waterfall-spray-wisp', { size: 1.15 }, scene);
    mesh.parent = root; mesh.material = material; mesh.isPickable = false;
    mesh.billboardMode = Mesh.BILLBOARDMODE_ALL;
    return { mesh, x: -29 + Math.sin(angle) * 1.58, z: sign * 6.3 + Math.cos(angle) * 1.58, phase: index / 6 };
  }));
  let disposed = false;
  return {
    update(elapsed: number, reducedMotion: boolean) {
      if (disposed) return;
      const time = Number.isFinite(elapsed) ? Math.max(0, elapsed) : 0;
      for (const particle of particles) {
        const age = reducedMotion ? 0.35 : (time * 0.19 + particle.phase) % 1;
        particle.mesh.position.set(particle.x + (reducedMotion ? 0 : age * 0.20), 0.18 + age * 0.78, particle.z);
        particle.mesh.scaling.setAll(0.60 + age * 0.88);
        particle.mesh.visibility = reducedMotion ? 0.4 : Math.sin(age * Math.PI);
      }
    },
    dispose() { if (disposed) return; disposed = true; root.dispose(); material.dispose(); },
  };
}
