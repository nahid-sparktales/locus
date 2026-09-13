import test from 'node:test';
import assert from 'node:assert/strict';
import { NullEngine } from '@babylonjs/core/Engines/nullEngine.js';
import { Scene } from '@babylonjs/core/scene.js';
import { TransformNode } from '@babylonjs/core/Meshes/transformNode.js';
import { DirectionalLight } from '@babylonjs/core/Lights/directionalLight.js';
import { ShadowGenerator } from '@babylonjs/core/Lights/Shadows/shadowGenerator.js';
import { Vector3 } from '@babylonjs/core/Maths/math.vector.js';
import { createIslandCrew, islandCrewVariants, ISLAND_CREW_VARIANTS } from '../src/islandCrew.ts';

function setup() {
  const engine = new NullEngine();
  const scene = new Scene(engine), parent = new TransformNode('island-plaza', scene);
  const light = new DirectionalLight('sun', new Vector3(-1, -2, -1), scene);
  const shadow = new ShadowGenerator(256, light);
  return { engine, scene, parent, shadow, close() { scene.dispose(); engine.dispose(); } };
}
function bounds(root: TransformNode) {
  const meshes = root.getChildMeshes();
  meshes.forEach(mesh => mesh.computeWorldMatrix(true));
  return {
    minX: Math.min(...meshes.map(mesh => mesh.getBoundingInfo().boundingBox.minimumWorld.x)),
    maxX: Math.max(...meshes.map(mesh => mesh.getBoundingInfo().boundingBox.maximumWorld.x)),
    minY: Math.min(...meshes.map(mesh => mesh.getBoundingInfo().boundingBox.minimumWorld.y)),
    maxY: Math.max(...meshes.map(mesh => mesh.getBoundingInfo().boundingBox.maximumWorld.y)),
    minZ: Math.min(...meshes.map(mesh => mesh.getBoundingInfo().boundingBox.minimumWorld.z)),
    maxZ: Math.max(...meshes.map(mesh => mesh.getBoundingInfo().boundingBox.maximumWorld.z)),
  };
}
function transforms(root: TransformNode) {
  return [root, ...root.getDescendants()].map(node => {
    const transform = node as TransformNode;
    return [node.name, ...transform.position.asArray(), ...transform.rotation.asArray(), ...transform.scaling.asArray()];
  });
}
function assertInsidePlaza(root: TransformNode) {
  const measured = bounds(root);
  assert.ok(measured.minY >= -0.002, `Crew penetrates plaza: ${JSON.stringify(measured)}`);
  assert.ok(measured.minX >= -0.561 && measured.maxX <= 0.561, `Crew leaves plaza width: ${JSON.stringify(measured)}`);
  assert.ok(measured.minZ >= -0.231 && measured.maxZ <= 0.231, `Crew leaves plaza depth: ${JSON.stringify(measured)}`);
}

test('stable, diverse landing parties have two or three distinct crew references', () => {
  const found = new Set<string>(), counts = new Set<number>();
  for (let index = 0; index < 32; index++) {
    const id = `captain-${index}`, seed = index * 497;
    const first = islandCrewVariants(id, seed);
    assert.deepEqual(first, islandCrewVariants(id, seed));
    assert.ok(first.length === 2 || first.length === 3);
    assert.equal(new Set(first).size, first.length);
    counts.add(first.length);
    first.forEach(variant => found.add(variant));
  }
  assert.deepEqual([...found].sort(), [...ISLAND_CREW_VARIANTS].sort());
  assert.deepEqual([...counts].sort(), [2, 3]);
});

test('all crew references are readable, grounded, pickable and stay inside the actual pier during work and walking', () => {
  const world = setup(), found = new Set<string>();
  try {
    for (let seed = 0; seed < 32 && found.size < ISLAND_CREW_VARIANTS.length; seed++) {
      const crew = createIslandCrew(world.scene, world.shadow, world.parent, `captain-${seed}`, seed * 497);
      assert.equal(crew.count, crew.variants.length);
      const people = crew.root.getChildren(undefined, true) as TransformNode[];
      assert.equal(people.length, crew.count);
      for (const person of people) {
        found.add(person.metadata.crewVariant);
        const measured = bounds(person);
        assert.ok(Math.abs(measured.minY) < 0.002, `Feet need to meet the plaza: ${measured.minY}`);
        assert.ok(measured.maxY >= 0.62 && measured.maxY < 0.75, `${person.metadata.crewVariant} height ${measured.maxY}`);
        assert.ok(person.getChildMeshes().length <= 46, 'Rigid details should merge by joint and material');
      }
      for (const mesh of crew.root.getChildMeshes()) {
        assert.equal(mesh.metadata.actorID, `captain-${seed}`);
        assert.ok(ISLAND_CREW_VARIANTS.includes(mesh.metadata.crewVariant));
        assert.equal(mesh.isPickable, true);
        assert.ok(world.shadow.getShadowMap()?.renderList?.includes(mesh));
      }
      for (let frame = 0; frame < 130; frame++) {
        crew.animate(true, frame / 10, false);
        assertInsidePlaza(crew.root);
        assert.deepEqual(crew.root.position.asArray(), [0, 0, 0], 'Only crew members move; the island anchor cannot drift');
      }
      crew.dispose();
    }
    assert.equal(found.size, ISLAND_CREW_VARIANTS.length, 'The geometry test must actually cover every character');
  } finally { world.close(); }
});

test('work alternates planted walking feet and tool gestures; waiting and reduced motion are quiet', () => {
  const world = setup();
  try {
    const crew = createIslandCrew(world.scene, world.shadow, world.parent, 'active-crew', 9);
    const people = crew.root.getChildren(undefined, true) as TransformNode[];
    const paths = people.map(() => new Set<string>());
    const arms = people.map(person => person.getDescendants().find(node => node.name.endsWith('shoulder-1')) as TransformNode);
    const gestures = people.map(() => new Set<string>());
    const feetLifted = people.map(() => [false, false]);
    for (let frame = 0; frame < 260; frame++) {
      crew.animate(true, frame / 20, false);
      people.forEach((person, index) => {
        paths[index].add(person.position.x.toFixed(3));
        gestures[index].add(arms[index].rotation.x.toFixed(2));
        const feet = person.getChildMeshes().filter(mesh => mesh.name.includes('-foot-'));
        assert.equal(feet.length, 2);
        const heights = feet.map(mesh => {
          mesh.computeWorldMatrix(true);
          return mesh.getBoundingInfo().boundingBox.minimumWorld.y;
        });
        assert.ok(heights.every(height => height >= -0.002 && height < 0.03), `A foot leaves its safe step: ${heights}`);
        assert.ok(Math.min(...heights) < 0.002, `At least one foot remains planted: ${heights}`);
        heights.forEach((height, side) => { feetLifted[index][side] ||= height > 0.01; });
      });
    }
    paths.forEach(path => assert.ok(path.size > 20, 'Every character walks a continuous small route'));
    gestures.forEach(gesture => assert.ok(gesture.size > 20, 'Every character has articulated arm motion'));
    feetLifted.forEach(feet => assert.ok(feet.every(Boolean), 'Both legs participate in the gait'));
    crew.animate(false, 13, false);
    const waiting = transforms(crew.root);
    crew.animate(false, 300, false);
    assert.deepEqual(transforms(crew.root), waiting, 'An attention or queued state must not imply work');
    crew.animate(true, 15, true);
    const reduced = transforms(crew.root);
    crew.animate(true, 300, true);
    assert.deepEqual(transforms(crew.root), reduced, 'Reduced motion must be completely stable');
    crew.animate(true, Number.NaN, false);
    assertInsidePlaza(crew.root);
  } finally { world.close(); }
});

test('landing parties share geometry/materials and disappear without leaking shadows or scene resources', () => {
  const world = setup();
  try {
    const first = createIslandCrew(world.scene, world.shadow, world.parent, 'repeat', 2);
    const initialGeometries = world.scene.geometries.length;
    const second = createIslandCrew(world.scene, world.shadow, world.parent, 'repeat', 2);
    assert.deepEqual(second.variants, first.variants);
    assert.equal(world.scene.geometries.length, initialGeometries, 'Repeated crews should reuse their joint geometry');
    assert.equal(world.scene.materials.filter(material => material.name.startsWith('island-crew-')).length, 21);
    first.root.dispose();
    assert.ok(second.root.getChildMeshes().every(mesh => mesh.material && world.scene.materials.includes(mesh.material)));
    assert.ok(second.root.getChildMeshes().every(mesh => world.shadow.getShadowMap()?.renderList?.includes(mesh)));
    second.animate(true, 1, false);
    second.dispose();
    assert.equal(world.scene.meshes.length, 0);
    assert.equal(world.scene.geometries.length, 0);
    assert.equal(world.scene.materials.filter(material => material.name.startsWith('island-crew-')).length, 0);
    assert.equal(world.shadow.getShadowMap()?.renderList?.length, 0);
    first.animate(true, 100, false);
    first.dispose();
    const replacement = createIslandCrew(world.scene, world.shadow, world.parent, 'repeat', 2);
    assert.ok(replacement.root.getChildMeshes().length > 0, 'A later landing party can recreate released shared assets');
    replacement.dispose();
  } finally { world.close(); }
});
