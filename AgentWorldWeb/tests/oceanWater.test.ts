import test from 'node:test';
import assert from 'node:assert/strict';
import { NullEngine } from '@babylonjs/core/Engines/nullEngine.js';
import { Scene } from '@babylonjs/core/scene.js';
import { TransformNode } from '@babylonjs/core/Meshes/transformNode.js';
import { FreeCamera } from '@babylonjs/core/Cameras/freeCamera.js';
import { Vector3 } from '@babylonjs/core/Maths/math.vector.js';
import { Texture } from '@babylonjs/core/Materials/Textures/texture.js';
import { createOceanWater, oceanNormalPixels, oceanTime } from '../src/oceanWater.ts';
import { GRAND_LINE_LANDMARKS } from '../src/grandLineGeography.ts';

test('local ripple normals are deterministic, smoothly wrapped and bounded in memory', () => {
  const pixels = oceanNormalPixels(), size = 256;
  assert.equal(pixels.length, size * size * 4); assert.deepEqual(pixels, oceanNormalPixels());
  assert.equal(oceanNormalPixels(1).length, 32 * 32 * 4); assert.equal(oceanNormalPixels(9999).length, pixels.length);
  assert.equal(oceanNormalPixels(NaN).length, pixels.length);
  let wrapChange = 0, interiorChange = 0, clipped = 0;
  for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) {
    const index = (y * size + x) * 4; assert.equal(pixels[index + 3], 255);
    for (const channel of [0, 1]) {
      if (pixels[index + channel] <= 1 || pixels[index + channel] >= 254) clipped++;
      if (x === 0) wrapChange += Math.abs(pixels[index + channel] - pixels[(y * size + size - 1) * 4 + channel]);
      else interiorChange += Math.abs(pixels[index + channel] - pixels[index - 4 + channel]);
    }
  }
  assert.ok(wrapChange / size < interiorChange / (size * (size - 1)) * 1.5, 'The repeat edge is as smooth as ordinary neighboring texels');
  assert.ok(clipped < size * size * 0.001, 'Normal slopes should not flatten into clipped patches');
});

test('ocean keeps all fourteen shore contours, updates finite uniforms and owns one bounded texture', () => {
  const engine = new NullEngine(), scene = new Scene(engine), parent = new TransformNode('sea', scene);
  const camera = new FreeCamera('camera', new Vector3(0, 30, -40), scene); scene.activeCamera = camera;
  const ocean = createOceanWater(scene, parent, GRAND_LINE_LANDMARKS);
  try {
    const saved = ocean.material.serialize();
    assert.deepEqual(saved.vectors4Arrays.islandCoasts, GRAND_LINE_LANDMARKS.flatMap((island, index) => [island.x, island.z, island.radius, index * 2.3999632297 + 0.73]));
    assert.equal(ocean.surface.isPickable, false); assert.equal(ocean.surface.position.y, -0.19);
    assert.ok(ocean.surface.getTotalVertices() <= 25000);
    const texture = ocean.material.getActiveTextures()[0]; assert.ok(texture);
    assert.equal(texture.wrapU, Texture.WRAP_ADDRESSMODE); assert.equal(texture.wrapV, Texture.WRAP_ADDRESSMODE);
    assert.equal(texture.gammaSpace, false); assert.ok(texture.anisotropicFilteringLevel <= 4);
    const baseline = [scene.meshes.length, scene.geometries.length, scene.materials.length, scene.textures.length];
    for (let frame = 0; frame < 1000; frame++) ocean.update(frame / 60, false);
    assert.deepEqual([scene.meshes.length, scene.geometries.length, scene.materials.length, scene.textures.length], baseline);
    for (const time of [-Infinity, Infinity, NaN, -4, Number.MAX_VALUE, 32]) {
      ocean.update(time, false); const value = ocean.material.serialize().floats.time;
      assert.ok(Number.isFinite(value) && value >= 0 && value < 4096);
    }
    ocean.update(8, true); const first = ocean.material.serialize().floats.time;
    ocean.update(800, true); assert.equal(first, 0); assert.equal(ocean.material.serialize().floats.time, first);
    ocean.dispose(); ocean.dispose(); ocean.update(123, false);
    assert.equal(scene.meshes.length, 0); assert.equal(scene.geometries.length, 0);
    assert.equal(scene.materials.length, 0); assert.equal(scene.textures.length, 0);
  } finally { ocean.dispose(); scene.dispose(); engine.dispose(); }
});

test('reduced motion and invalid elapsed time cannot animate the ocean texture or foam', () => {
  for (const time of [0, 1, 60, 4096, Infinity, NaN]) assert.equal(oceanTime(time, true), 0);
  for (const time of [-1, -Infinity, Infinity, NaN]) assert.equal(oceanTime(time, false), 0);
  assert.equal(oceanTime(4097, false), 1);
});
