import test from 'node:test';
import assert from 'node:assert/strict';
import { NullEngine } from '@babylonjs/core/Engines/nullEngine.js';
import { Scene } from '@babylonjs/core/scene.js';
import { TransformNode } from '@babylonjs/core/Meshes/transformNode.js';
import { createShipWorkGlow } from '../src/shipWorkGlow.ts';
import { AGENT_STATUSES } from '../src/state.ts';

test('work glow follows a traveling worker, hands off at docking, respects reduced motion and disposes', () => {
  const engine = new NullEngine(), scene = new Scene(engine), sea = new TransformNode('sea', scene);
  try {
    const glow = createShipWorkGlow(scene, sea, 'a');
    for (const status of AGENT_STATUSES) {
      assert.equal(glow.update(status, false, { x: 4, z: 9 }, 1.2, 10, false), status === 'working');
      assert.equal(glow.root.isEnabled(), status === 'working');
    }
    glow.update('working', false, { x: 5, z: 8 }, 0.5, 20, true);
    assert.deepEqual(glow.root.position.asArray(), [5, 0, 8]);
    assert.equal(glow.root.rotation.y, 0.5);
    const sizes = [scene.meshes.length, scene.materials.length];
    for (let i = 0; i < 1000; i++) glow.update('working', false, { x: 5, z: 8 }, 0.5, i, true);
    assert.deepEqual(glow.root.scaling.asArray(), [1, 1, 1]);
    assert.deepEqual([scene.meshes.length, scene.materials.length], sizes);
    assert.ok(scene.meshes.every(mesh => !mesh.isPickable));
    glow.update('working', true, { x: 5, z: 8 }, 0.5, 25, false);
    assert.equal(glow.root.isEnabled(), false);
    glow.dispose();
    assert.equal(scene.meshes.length, 0);
    assert.equal(scene.materials.filter(material => material.name.startsWith('ship-work-light')).length, 0);
  } finally { scene.dispose(); engine.dispose(); }
});
