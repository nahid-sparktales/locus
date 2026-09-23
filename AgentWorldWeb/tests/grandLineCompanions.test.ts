import test from 'node:test';
import assert from 'node:assert/strict';
import { NullEngine } from '@babylonjs/core/Engines/nullEngine.js';
import { Scene } from '@babylonjs/core/scene.js';
import { PBRMaterial } from '@babylonjs/core/Materials/PBR/pbrMaterial.js';
import { Vector3 } from '@babylonjs/core/Maths/math.vector.js';
import { zuneshaPose, momonosukePose, ZuneshaStride } from '../src/grandLineCompanions.ts';
import { GRAND_LINE_LANDMARKS } from '../src/grandLineGeography.ts';

test('Zunesha walks beyond the left end without crossing islands, and Momo circles above Wano', () => {
  const wano = GRAND_LINE_LANDMARKS.find(island => island.id === 'wano')!;
  for (let time = 0; time < 440; time += 0.5) {
    const elephant = zuneshaPose(time), dragon = momonosukePose(time);
    assert.ok(elephant.x >= 54 && elephant.x <= 62);
    for (const island of GRAND_LINE_LANDMARKS) assert.ok(Math.hypot(elephant.x - island.x, elephant.z - island.z) > island.radius + 6);
    assert.ok(Math.hypot(dragon.x - wano.x, dragon.z - wano.z) >= 4.29);
    assert.ok(dragon.y >= 5.7 && dragon.y <= 7.3);
    const next = zuneshaPose(time + 0.001);
    const heading = Math.atan2(next.x - elephant.x, next.z - elephant.z);
    assert.ok(Math.abs(Math.sin(heading - elephant.heading)) < 0.001, 'Elephant faces its direction of travel');
  }
  assert.equal(zuneshaPose(0).x, zuneshaPose(220).x);
  assert.equal(zuneshaPose(0).z, zuneshaPose(220).z);
  for (const pose of [zuneshaPose, momonosukePose]) {
    for (const value of [NaN, Infinity, -Infinity, -1, Number.MAX_VALUE]) assert.ok(Object.values(pose(value)).every(Number.isFinite));
    assert.deepEqual(pose(12, true), pose(500, true), 'Reduced motion freezes location and pose');
  }
});

test('elephant leg animation receives actual material bind events and freezes without leaking resources', () => {
  const engine = new NullEngine(), scene = new Scene(engine), material = new PBRMaterial('elephant', scene);
  const gait = new ZuneshaStride(material, new Vector3(-1, 0, -1), new Vector3(2, 4, 2));
  const counts = [scene.meshes.length, scene.textures.length];
  const writes: number[][] = [];
  const original = material._uniformBuffer.updateFloat2;
  const originalVector = material._uniformBuffer.updateVector3;
  const vectors: Record<string, number[]> = {};
  material._uniformBuffer.updateVector3 = (name, value) => { vectors[name] = value.asArray(); };
  material._uniformBuffer.updateFloat2 = (_name, time, motion) => { writes.push([time, motion]); };
  const bind = () => material._callbackPluginEventHardBindForSubMesh({ subMesh: undefined } as never);
  try {
    gait.update(3, false); bind(); assert.deepEqual(writes.at(-1), [3, 1]);
    assert.deepEqual(vectors, { zuneshaMinimum: [-1, 0, -1], zuneshaSpan: [2, 4, 2] });
    gait.update(4, false); bind(); assert.deepEqual(writes.at(-1), [4, 1]);
    for (const time of [20, 100, Infinity]) { gait.update(time, true); bind(); assert.deepEqual(writes.at(-1), [0, 0]); }
    assert.deepEqual([scene.meshes.length, scene.textures.length], counts);
    material.dispose(); const count = writes.length;
    gait.update(8, false); gait.hardBindForSubMesh(material._uniformBuffer); assert.equal(writes.length, count);
  } finally { material._uniformBuffer.updateFloat2 = original; material._uniformBuffer.updateVector3 = originalVector; scene.dispose(); engine.dispose(); }
});
