import test from 'node:test';
import assert from 'node:assert/strict';
import { NullEngine } from '@babylonjs/core/Engines/nullEngine.js';
import { Scene } from '@babylonjs/core/scene.js';
import { ArcRotateCamera } from '@babylonjs/core/Cameras/arcRotateCamera.js';
import { Vector3 } from '@babylonjs/core/Maths/math.vector.js';
import { stepShipCameraFollow } from '../src/shipCameraFollow.ts';

test('following a moving ship translates the camera without changing its orbit or user zoom', () => {
  const engine = new NullEngine(), scene = new Scene(engine);
  try {
    const camera = new ArcRotateCamera('camera', -1.2, 0.74, 16, new Vector3(0, 0.8, 0), scene);
    camera.getViewMatrix(true);
    const start = camera.position.clone();
    for (let frame = 0; frame < 240; frame++) stepShipCameraFollow(camera, { x: 10, z: 6 }, 1 / 30, false);
    camera.getViewMatrix(true);
    assert.ok(Math.abs(camera.target.x - 10) < 0.01);
    assert.ok(Math.abs(camera.target.z - 6) < 0.01);
    assert.equal(camera.alpha, -1.2);
    assert.equal(camera.beta, 0.74);
    assert.equal(camera.radius, 16);
    assert.ok(Math.abs(camera.position.x - start.x - 10) < 0.01, 'Camera position follows, instead of only pivoting toward the ship');
    camera.radius = 24;
    stepShipCameraFollow(camera, { x: 11, z: 7 }, 1 / 30, false);
    assert.equal(camera.radius, 24, 'Manual zoom persists after the initial focus');
  } finally { scene.dispose(); engine.dispose(); }
});

test('initial ship focus eases to a close view and respects reduced motion', () => {
  const engine = new NullEngine(), scene = new Scene(engine);
  try {
    const camera = new ArcRotateCamera('camera', -1.2, 0.74, 78, Vector3.Zero(), scene);
    let radius: number | undefined = 16;
    for (let frame = 0; frame < 120; frame++) radius = stepShipCameraFollow(camera, { x: 4, z: 5 }, 1 / 30, false, radius);
    assert.equal(radius, undefined);
    assert.ok(Math.abs(camera.radius - 16) < 0.02);
    assert.equal(stepShipCameraFollow(camera, { x: -3, z: 8 }, 0, true, 14), undefined);
    assert.deepEqual(camera.target.asArray(), [-3, 0.8, 8]);
    assert.equal(camera.radius, 14);
  } finally { scene.dispose(); engine.dispose(); }
});
