import test from 'node:test';
import assert from 'node:assert/strict';
import { NullEngine } from '@babylonjs/core/Engines/nullEngine.js';
import { Scene } from '@babylonjs/core/scene.js';
import { TransformNode } from '@babylonjs/core/Meshes/transformNode.js';
import { DirectionalLight } from '@babylonjs/core/Lights/directionalLight.js';
import { ShadowGenerator } from '@babylonjs/core/Lights/Shadows/shadowGenerator.js';
import { Vector3 } from '@babylonjs/core/Maths/math.vector.js';
import { createPerson, PERSON_VARIANTS } from '../src/people.ts';

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
    minX: Math.min(...meshes.map(mesh => mesh.getBoundingInfo().boundingBox.minimumWorld.x)),
    maxX: Math.max(...meshes.map(mesh => mesh.getBoundingInfo().boundingBox.maximumWorld.x)),
  };
}
function footHeights(root: TransformNode) {
  return root.getChildMeshes().filter(mesh => mesh.name.includes('-sole-')).map(mesh => {
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

test('every human variant has visible face details, human proportions and selectable merged geometry', () => {
  const world = setup();
  try {
    const faceColors = new Set<string>();
    for (let seed = 0; seed < PERSON_VARIANTS.length; seed++) {
      const person = createPerson(world.scene, world.shadow, world.parent, `agent-${seed}`, seed);
      assert.equal(person.variant, PERSON_VARIANTS[seed]);
      const measured = bounds(person.root);
      assert.ok(Math.abs(measured.minY) < 0.001, `Feet must begin at ground height: ${measured.minY}`);
      assert.ok(measured.maxY > 1.75 && measured.maxY < 1.85, `Human height: ${measured.maxY}`);
      assert.ok(measured.maxX - measured.minX < 0.78, 'Humans must fit the existing navigation footprint');
      const meshes = person.root.getChildMeshes();
      assert.ok(meshes.length <= 40, `Static details must be merged; found ${meshes.length} meshes`);
      for (const mesh of meshes) {
        assert.equal(mesh.metadata.actorID, `agent-${seed}`);
        assert.equal(mesh.isPickable, true);
        assert.ok(world.shadow.getShadowMap()?.renderList?.includes(mesh));
        assert.ok(mesh.getTotalVertices() > 0);
      }
      const face = meshes.find(mesh => mesh.name.includes('-head-') && mesh.name.endsWith('-merged'));
      assert.ok(face?.material, 'Skin, nose, jaw and ears must be attached to the head');
      faceColors.add(face.material.name);
      assert.equal(person.root.getDescendants().filter(node => /-eye-(-1|1)$/.test(node.name)).length, 2);
      assert.ok(person.root.getDescendants().some(node => node.name.endsWith('-head')));
      person.dispose();
    }
    assert.equal(faceColors.size, PERSON_VARIANTS.length, 'The six people must have distinct skin tones');
  } finally { world.close(); }
});

test('all human gaits alternate grounded feet without drifting and reduce to a stable standing pose', () => {
  const world = setup();
  try {
    for (let seed = 0; seed < PERSON_VARIANTS.length; seed++) {
      const person = createPerson(world.scene, world.shadow, world.parent, `walker-${seed}`, seed);
      let liftedLeft = false, liftedRight = false;
      const initial = transforms(person.root);
      for (let frame = 0; frame < 180; frame++) {
        person.animate(true, frame / 30, false);
        const feet = footHeights(person.root);
        assert.equal(feet.length, 2);
        assert.ok(feet.every(y => y >= -0.001 && y < 0.08), `Foot penetrated ground or jumped: ${feet}`);
        assert.ok(Math.min(...feet) < 0.001, `At least one foot must remain planted: ${feet}`);
        liftedLeft ||= feet[0] > 0.025;
        liftedRight ||= feet[1] > 0.025;
        assert.deepEqual(person.root.position.asArray(), [0, 0, 0], 'Animation must not drift the map root');
      }
      assert.ok(liftedLeft && liftedRight, 'Both legs must participate in the gait');
      assert.notDeepEqual(transforms(person.root), initial, 'Walking must articulate the model');
      person.animate(false, 9, true);
      const reduced = transforms(person.root);
      person.animate(true, 19, true);
      assert.deepEqual(transforms(person.root), reduced, 'Reduced motion keeps all body parts stable');
      assert.ok(footHeights(person.root).every(y => Math.abs(y) < 0.001));
      person.animate(false, 20, false);
      person.animate(false, 20.5, false);
      assert.notDeepEqual(transforms(person.root), reduced, 'Idle breathing and gaze resume after reduced motion');
      person.dispose();
    }
  } finally { world.close(); }
});

test('repeated humans share geometry and materials while actor disposal preserves surviving crew', () => {
  const world = setup();
  try {
    const first = createPerson(world.scene, world.shadow, world.parent, 'one', 2);
    const second = createPerson(world.scene, world.shadow, world.parent, 'two', 8);
    assert.equal(first.variant, second.variant);
    assert.equal(world.scene.geometries.length, first.root.getChildMeshes().length, 'Repeated variants must share rigid joint geometry');
    const materialCount = world.scene.materials.length;
    assert.ok(materialCount <= 12);
    first.root.dispose();
    assert.ok(second.root.getChildMeshes().every(mesh => mesh.material && world.scene.materials.includes(mesh.material)));
    assert.equal(world.scene.materials.length, materialCount);
    second.animate(true, 1, false);
    second.dispose();
    second.dispose();
    second.animate(true, 2, false);
    assert.equal(world.scene.meshes.length, 0);
    assert.equal(world.scene.geometries.length, 0);
    assert.equal(world.scene.materials.length, 0);
    assert.equal(world.shadow.getShadowMap()?.renderList?.length, 0);
    const recreated = createPerson(world.scene, world.shadow, world.parent, 'three', 2);
    assert.ok(recreated.root.getChildMeshes().every(mesh => mesh.material && world.scene.materials.includes(mesh.material)), 'Switching back after final disposal must recreate valid resources');
    recreated.dispose();
    assert.equal(world.scene.materials.length, 0);
  } finally { world.close(); }
});
