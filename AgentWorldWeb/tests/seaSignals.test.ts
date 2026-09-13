import test from 'node:test';
import assert from 'node:assert/strict';
import { NullEngine } from '@babylonjs/core/Engines/nullEngine.js';
import { Scene } from '@babylonjs/core/scene.js';
import { TransformNode } from '@babylonjs/core/Meshes/transformNode.js';
import { DirectionalLight } from '@babylonjs/core/Lights/directionalLight.js';
import { ShadowGenerator } from '@babylonjs/core/Lights/Shadows/shadowGenerator.js';
import { Vector3 } from '@babylonjs/core/Maths/math.vector.js';
import { createDenDenMushi, createCourierBoat } from '../src/seaSignals.ts';

function setup() {
  const engine = new NullEngine(), scene = new Scene(engine), parent = new TransformNode('world', scene);
  const light = new DirectionalLight('sun', new Vector3(-1, -2, -1), scene), shadow = new ShadowGenerator(256, light);
  return { scene, parent, shadow, close() { scene.dispose(); engine.dispose(); } };
}
const rotations = (root: TransformNode) => root.getChildTransformNodes().map(node => node.rotation.asArray());

test('Den Den Mushi carries the exact request ID and stops ringing under reduced motion', () => {
  const world = setup();
  try {
    const snail = createDenDenMushi(world.scene, world.shadow, world.parent, 'request-123', 'captain-456');
    assert.ok(snail.root.getChildMeshes().length < 18, 'Rigid details should merge by material');
    for (const mesh of snail.root.getChildMeshes()) {
      assert.equal(mesh.metadata.attentionID, 'request-123');
      assert.equal(mesh.metadata.actorID, 'captain-456');
      assert.ok(mesh.isPickable && world.shadow.getShadowMap()?.renderList?.includes(mesh));
    }
    snail.animate(1, false); const ringing = rotations(snail.root);
    snail.animate(2, false); assert.notDeepEqual(rotations(snail.root), ringing);
    snail.animate(3, true); const stopped = rotations(snail.root);
    snail.animate(7, true); assert.deepEqual(rotations(snail.root), stopped);
    assert.deepEqual(snail.root.position.asArray(), [0, 0, 0], 'Ringing does not shift its deck position');
    snail.dispose(); snail.animate(8, false);
    assert.equal(world.scene.meshes.length, 0);
    assert.equal(world.scene.geometries.length, 0);
    assert.equal(world.shadow.getShadowMap()?.renderList?.length, 0);
  } finally { world.close(); }
});

test('both courier payloads stay selectable by exact transfer ID and reuse bounded scene materials', () => {
  const world = setup();
  try {
    for (const kind of ['handoff', 'artifact'] as const) {
      const boat = createCourierBoat(world.scene, world.shadow, world.parent, `event-${kind}`, kind);
      assert.ok(boat.root.getChildMeshes().length < 10);
      for (const mesh of boat.root.getChildMeshes()) {
        assert.equal(mesh.metadata.transferID, `event-${kind}`);
        assert.equal(mesh.metadata.actorID, undefined, 'A courier must not select a different agent by accident');
        assert.ok(mesh.isPickable && world.shadow.getShadowMap()?.renderList?.includes(mesh));
      }
      boat.dispose();
    }
    const paletteSize = world.scene.materials.length;
    for (let index = 0; index < 10; index++) createCourierBoat(world.scene, world.shadow, world.parent, `more-${index}`, 'artifact').dispose();
    assert.equal(world.scene.materials.length, paletteSize);
    assert.equal(world.scene.meshes.length, 0);
    assert.equal(world.scene.geometries.length, 0);
    assert.equal(world.shadow.getShadowMap()?.renderList?.length, 0);
  } finally { world.close(); }
});
