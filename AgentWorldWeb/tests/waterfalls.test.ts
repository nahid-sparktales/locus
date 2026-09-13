import test from 'node:test';
import assert from 'node:assert/strict';
import { NullEngine } from '@babylonjs/core/Engines/nullEngine.js';
import { Scene } from '@babylonjs/core/scene.js';
import { TransformNode } from '@babylonjs/core/Meshes/transformNode.js';
import { PBRMaterial } from '@babylonjs/core/Materials/PBR/pbrMaterial.js';
import { WaterfallFlow } from '../src/waterfallFlow.ts';
import { createWaterfallMist } from '../src/waterfallMist.ts';

function setup() {
  const engine = new NullEngine(), scene = new Scene(engine), material = new PBRMaterial('model-water', scene);
  const flow = new WaterfallFlow(material), writes: [string, number, number][] = [];
  const original = material._uniformBuffer.updateFloat2;
  material._uniformBuffer.updateFloat2 = (name, x, y) => { writes.push([name, x, y]); };
  const bind = () => material._callbackPluginEventHardBindForSubMesh({ subMesh: undefined } as never);
  return { scene, material, flow, writes, bind, close() { material._uniformBuffer.updateFloat2 = original; scene.dispose(); engine.dispose(); } };
}

test('the waterfall plugin actually receives Babylon hard-bind events and writes its declared uniform', () => {
  const world = setup();
  try {
    world.flow.update(12.5, false); world.bind();
    assert.deepEqual(world.writes, [['locusWaterfall', 12.5, 1]], 'Activating before extra-event registration silently leaves the waterfall static');
    world.flow.update(13, false); world.bind();
    assert.deepEqual(world.writes.at(-1), ['locusWaterfall', 13, 1]);
    const declared = world.flow.getUniforms().ubo;
    assert.ok(declared.some(uniform => uniform.name === world.writes[0][0] && uniform.size === 2 && uniform.type === 'vec2'));
    assert.equal(world.material.pluginManager?.getPlugin('LocusWaterfallFlow'), world.flow);
    assert.equal(world.flow.getCustomCode('vertex'), null, 'Water flow does not move imported geometry');
  } finally { world.close(); }
});

test('waterfall time stays finite and bounded and reduced motion writes a constant disabled state', () => {
  const world = setup();
  try {
    for (const time of [NaN, Infinity, -Infinity, -50, 0, 4097.25, Number.MAX_VALUE]) {
      world.flow.update(time, false); world.bind();
      const [, elapsed, motion] = world.writes.at(-1)!;
      assert.ok(Number.isFinite(elapsed) && elapsed >= 0 && elapsed < 4096); assert.equal(motion, 1);
    }
    for (const time of [20, 21, 4000, Infinity]) {
      world.flow.update(time, true); world.bind();
      assert.deepEqual(world.writes.at(-1), ['locusWaterfall', 0, 0]);
    }
    world.flow.update(34, false); world.bind(); assert.deepEqual(world.writes.at(-1), ['locusWaterfall', 34, 1]);
  } finally { world.close(); }
});

test('the imported material owns plugin disposal, without adding textures or retaining active writes', () => {
  const world = setup();
  try {
    const before = [world.scene.meshes.length, world.scene.textures.length, world.scene.materials.length];
    for (let index = 0; index < 1000; index++) { world.flow.update(index / 30, false); world.bind(); }
    assert.deepEqual([world.scene.meshes.length, world.scene.textures.length, world.scene.materials.length], before);
    world.material.dispose();
    assert.equal(world.material.pluginManager, undefined);
    const count = world.writes.length;
    world.flow.update(4, false); world.flow.hardBindForSubMesh(world.material._uniformBuffer);
    assert.equal(world.writes.length, count, 'A disposed material must leave no writable waterfall plugin');
    world.flow.dispose();
  } finally { world.close(); }
});

test('waterfall mist uses a fixed finite pool, becomes static for reduced motion and fully cleans up', () => {
  const engine = new NullEngine(), scene = new Scene(engine), root = new TransformNode('mountain', scene);
  try {
    const mist = createWaterfallMist(scene, root), meshes = root.getChildMeshes();
    assert.equal(meshes.length, 12); assert.equal(new Set(meshes.map(mesh => mesh.material)).size, 1);
    assert.ok(meshes.every(mesh => !mesh.isPickable));
    const counts = [scene.meshes.length, scene.geometries.length, scene.materials.length];
    for (const time of [NaN, Infinity, -Infinity, -40, 0, 200, Number.MAX_VALUE]) {
      mist.update(time, false);
      assert.ok(meshes.every(mesh => [...mesh.position.asArray(), ...mesh.scaling.asArray(), mesh.visibility].every(Number.isFinite)));
      assert.ok(meshes.every(mesh => mesh.visibility >= 0 && mesh.visibility <= 1));
    }
    for (let index = 0; index < 1000; index++) mist.update(index / 30, false);
    assert.deepEqual([scene.meshes.length, scene.geometries.length, scene.materials.length], counts);
    mist.update(20, true); const still = meshes.map(mesh => [mesh.position.asArray(), mesh.scaling.asArray(), mesh.visibility]);
    mist.update(80, true); assert.deepEqual(meshes.map(mesh => [mesh.position.asArray(), mesh.scaling.asArray(), mesh.visibility]), still);
    mist.dispose(); mist.dispose(); mist.update(90, false);
    assert.equal(root.getChildren().length, 0); assert.equal(scene.meshes.length, 0); assert.equal(scene.geometries.length, 0);
    assert.equal(scene.getMaterialByName('waterfall-mist'), null);
  } finally { scene.dispose(); engine.dispose(); }
});
