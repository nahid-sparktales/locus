import test from 'node:test';
import assert from 'node:assert/strict';
import { NullEngine } from '@babylonjs/core/Engines/nullEngine.js';
import { Scene } from '@babylonjs/core/scene.js';
import { TransformNode } from '@babylonjs/core/Meshes/transformNode.js';
import { DirectionalLight } from '@babylonjs/core/Lights/directionalLight.js';
import { ShadowGenerator } from '@babylonjs/core/Lights/Shadows/shadowGenerator.js';
import { Vector3 } from '@babylonjs/core/Maths/math.vector.js';
import { createPanda, PANDA_VARIANTS } from '../src/pandas.ts';

function setup() {
  const engine = new NullEngine();
  const scene = new Scene(engine), parent = new TransformNode('world', scene);
  const light = new DirectionalLight('sun', new Vector3(-1, -2, -1), scene);
  const shadow = new ShadowGenerator(256, light);
  return { engine, scene, parent, shadow, close() { scene.dispose(); engine.dispose(); } };
}
function bounds(root: TransformNode) {
  const meshes = root.getChildMeshes();
  meshes.forEach(mesh => mesh.computeWorldMatrix(true));
  return {
    minY: Math.min(...meshes.map(mesh => mesh.getBoundingInfo().boundingBox.minimumWorld.y)),
    maxY: Math.max(...meshes.map(mesh => mesh.getBoundingInfo().boundingBox.maximumWorld.y)),
  };
}
function footHeights(root: TransformNode) {
  return root.getChildMeshes().filter(mesh => mesh.name.includes('-foot-')).map(mesh => {
    mesh.computeWorldMatrix(true);
    return mesh.getBoundingInfo().boundingBox.minimumWorld.y;
  });
}
function transforms(root: TransformNode) {
  return [root, ...root.getDescendants()].map(node => {
    const transform = node as TransformNode;
    return [node.name, ...transform.position.asArray(), ...transform.rotation.asArray(), ...transform.scaling.asArray()];
  });
}

test('all four panda outfits are ground aligned, pickable and use merged articulated geometry', () => {
  const world = setup();
  try {
    for (let seed = 0; seed < PANDA_VARIANTS.length; seed++) {
      const panda = createPanda(world.scene, world.shadow, world.parent, `agent-${seed}`, seed);
      assert.equal(panda.variant, PANDA_VARIANTS[seed]);
      const measured = bounds(panda.root);
      assert.ok(Math.abs(measured.minY) < 0.001, `Feet must begin at ground height: ${measured.minY}`);
      assert.ok(measured.maxY > 1.75 && measured.maxY < 1.85, `Mascot height: ${measured.maxY}`);
      const meshes = panda.root.getChildMeshes();
      assert.ok(meshes.length <= 34, `Static geometry must be merged; found ${meshes.length} meshes`);
      for (const mesh of meshes) {
        assert.equal(mesh.metadata.actorID, `agent-${seed}`);
        assert.equal(mesh.isPickable, true);
        assert.ok(world.shadow.getShadowMap()?.renderList?.includes(mesh));
      }
      const nose = meshes.find(mesh => mesh.name.includes('head') && mesh.material?.name === 'locus-panda-ink');
      assert.ok(nose, 'The black face features must belong to the head pivot');
      panda.dispose();
    }
  } finally { world.close(); }
});

test('walking alternates lifted feet while maintaining a grounded stance and a fixed map root', () => {
  const world = setup();
  try {
    const panda = createPanda(world.scene, world.shadow, world.parent, 'walker', 1);
    let liftedLeft = false, liftedRight = false;
    for (let frame = 0; frame < 240; frame++) {
      panda.animate(true, frame / 30, false);
      const feet = footHeights(panda.root);
      assert.equal(feet.length, 2);
      assert.ok(feet.every(y => y >= -0.001 && y < 0.08), `Foot penetrated ground or jumped: ${feet}`);
      assert.ok(Math.min(...feet) < 0.001, `At least one foot must remain planted: ${feet}`);
      liftedLeft ||= feet[0] > 0.025;
      liftedRight ||= feet[1] > 0.025;
      assert.deepEqual(panda.root.position.asArray(), [0, 0, 0], 'Animation must not drift the agent root');
    }
    assert.ok(liftedLeft && liftedRight, 'Both legs must participate in the gait');
    panda.animate(false, 9, true);
    const reduced = transforms(panda.root);
    panda.animate(true, 19, true);
    assert.deepEqual(transforms(panda.root), reduced, 'Reduced motion keeps all body parts in a stable pose');
    assert.ok(footHeights(panda.root).every(y => Math.abs(y) < 0.001));
  } finally { world.close(); }
});

test('pandas reuse scene materials and owning-root disposal releases shadows, meshes and final material references', () => {
  const world = setup();
  try {
    const first = createPanda(world.scene, world.shadow, world.parent, 'one', 0);
    const second = createPanda(world.scene, world.shadow, world.parent, 'two', 4);
    assert.equal(first.variant, second.variant, 'Outfit selection must be deterministic');
    assert.equal(world.scene.geometries.length, first.root.getChildMeshes().length, 'Repeated outfits must share joint geometry');
    assert.equal(world.scene.materials.filter(material => material.name.startsWith('locus-panda-')).length, 7);
    first.root.dispose();
    assert.ok(second.root.getChildMeshes().every(mesh => mesh.material && world.scene.materials.includes(mesh.material)));
    assert.equal(world.scene.materials.filter(material => material.name.startsWith('locus-panda-')).length, 7);
    second.root.dispose();
    assert.equal(world.scene.meshes.length, 0);
    assert.equal(world.scene.geometries.length, 0);
    assert.equal(world.scene.materials.filter(material => material.name.startsWith('locus-panda-')).length, 0);
    assert.equal(world.shadow.getShadowMap()?.renderList?.length, 0);
  } finally { world.close(); }
});
