import test from 'node:test';
import assert from 'node:assert/strict';
import { NullEngine } from '@babylonjs/core/Engines/nullEngine.js';
import { Scene } from '@babylonjs/core/scene.js';
import { AssetContainer } from '@babylonjs/core/assetContainer.js';
import { TransformNode } from '@babylonjs/core/Meshes/transformNode.js';
import { MeshBuilder } from '@babylonjs/core/Meshes/meshBuilder.js';
import { InstancedMesh } from '@babylonjs/core/Meshes/instancedMesh.js';
import { StandardMaterial } from '@babylonjs/core/Materials/standardMaterial.js';
import { DirectionalLight } from '@babylonjs/core/Lights/directionalLight.js';
import { ShadowGenerator } from '@babylonjs/core/Lights/Shadows/shadowGenerator.js';
import { Vector3 } from '@babylonjs/core/Maths/math.vector.js';
import { GrandLineModels } from '../src/grandLineModels.ts';
import { DEFAULT_THEME } from '../src/theme.ts';

const near = (a: number, b: number) => assert.ok(Math.abs(a - b) < 0.00002, `${a} differs from ${b}`);
test('interactive creatures retain picking and inherit animation after installation', () => {
  const world = setup();
  try {
    world.models.add('creature_laboon', { parent: world.parent, width: 2, depth: 2, height: 2, floor: -0.25, animated: true, interactionID: 'laboon' });
    world.models.install('creature_laboon', world.container);
    const mesh = world.parent.getChildMeshes()[0];
    assert.equal(mesh.isWorldMatrixFrozen, false); assert.equal(mesh.isPickable, true);
    assert.equal(mesh.metadata.creatureID, 'laboon');
    const before = mesh.getAbsolutePosition().y;
    world.parent.position.y += 0.25; world.parent.computeWorldMatrix(true); mesh.computeWorldMatrix(true);
    near(mesh.getAbsolutePosition().y - before, 0.25);
  } finally { world.close(); }
});
function setup(size = { width: 8, height: 12, depth: 6 }) {
  const engine = new NullEngine(), scene = new Scene(engine), parent = new TransformNode('island-owner', scene);
  const sun = new DirectionalLight('sun', new Vector3(-1, -2, -1), scene), shadow = new ShadowGenerator(256, sun);
  const container = new AssetContainer(scene), mesh = MeshBuilder.CreateBox('off-center-meshy-geometry', size, scene);
  mesh.position.set(7, -4, 3);
  const material = new StandardMaterial('embedded-island-material', scene); mesh.material = material;
  container.meshes.push(mesh); container.materials.push(material); container.removeAllFromScene();
  const models = new GrandLineModels(scene, shadow, { ...DEFAULT_THEME, environment: 'ocean', assets: { island_twin_cape: 'island.glb', scenery_red_line: 'cliff.glb' } });
  return { scene, parent, shadow, mesh, material, container, models, close() { models.dispose(); container.dispose(); scene.dispose(); engine.dispose(); } };
}

test('off-center island geometry is grounded, centered and fitted under transformed parents without copying materials', () => {
  const world = setup();
  try {
    world.parent.position.set(11, 2, -9); world.parent.rotation.y = Math.PI / 2;
    world.models.add('island_twin_cape', { parent: world.parent, width: 2, depth: 4, height: 3, floor: -0.12 });
    world.models.install('island_twin_cape', world.container);
    const bounds = world.parent.getHierarchyBoundingVectors(true);
    near(bounds.min.x, 9); near(bounds.max.x, 13); near(bounds.min.z, -10); near(bounds.max.z, -8);
    near(bounds.min.y, 1.88); near(bounds.max.y, 4.88);
    const meshes = world.parent.getChildMeshes();
    assert.equal(meshes.length, 1); assert.ok(meshes[0] instanceof InstancedMesh);
    assert.equal(meshes[0].material, world.material); assert.equal(meshes[0].sourceMesh, world.mesh);
    assert.ok(meshes[0].isWorldMatrixFrozen && !meshes[0].isPickable && meshes[0].receiveShadows);
    assert.equal(world.shadow.getShadowMap()?.renderList?.length, meshes.length);
    assert.ok(meshes.every(mesh => world.shadow.getShadowMap()?.renderList?.includes(mesh)));
  } finally { world.close(); }
});

test('Red Line model long axis is normalized before fitting and repeated ridges share source geometry', () => {
  const world = setup({ width: 10, height: 5, depth: 2 });
  try {
    const second = new TransformNode('other-ridge', world.scene); second.position.z = 15;
    for (const parent of [world.parent, second]) world.models.add('scenery_red_line', { parent, width: 4, depth: 12, height: 6, floor: -0.36 });
    world.models.install('scenery_red_line', world.container);
    const bounds = world.parent.getHierarchyBoundingVectors(true);
    near(bounds.max.x - bounds.min.x, 4); near(bounds.max.z - bounds.min.z, 12); near(bounds.max.y - bounds.min.y, 6); near(bounds.min.y, -0.36);
    assert.ok(world.scene.transformNodes.filter(node => node.name === 'scenery_red_line-orientation').every(node => node.rotation.y === Math.PI / 2));
    const first = world.parent.getChildMeshes()[0] as InstancedMesh, other = second.getChildMeshes()[0] as InstancedMesh;
    assert.equal(first.sourceMesh, other.sourceMesh); assert.equal(first.material, other.material);
    const counts = [world.scene.meshes.length, world.scene.transformNodes.length, world.scene.materials.length];
    world.models.install('scenery_red_line', world.container);
    assert.deepEqual([world.scene.meshes.length, world.scene.transformNodes.length, world.scene.materials.length], counts);
    world.models.dispose();
    assert.equal(world.parent.getChildren().length, 0); assert.equal(second.getChildren().length, 0);
    assert.equal(world.shadow.getShadowMap()?.renderList?.length, 0);
    assert.equal(world.mesh.instances.length, 0); assert.equal(world.material.isFrozen, false);
    assert.ok(!world.mesh.isDisposed(), 'Source assets remain owned by their container');
  } finally { world.close(); }
});

test('installation failure rolls back earlier instances and wrappers and can be retried', () => {
  const world = setup();
  try {
    const first = { parent: world.parent, width: 4, depth: 3, height: 4, floor: -0.12 };
    const invalid = { ...first, width: 0 };
    world.models.add('island_twin_cape', first); world.models.add('island_twin_cape', invalid);
    const before = [world.scene.meshes.length, world.scene.transformNodes.length];
    assert.throws(() => world.models.install('island_twin_cape', world.container), /Invalid island placement/);
    assert.deepEqual([world.scene.meshes.length, world.scene.transformNodes.length], before);
    assert.equal(world.shadow.getShadowMap()?.renderList?.length, 0); assert.equal(world.mesh.instances.length, 0);
    invalid.width = 4; world.models.install('island_twin_cape', world.container);
    assert.equal(world.parent.getChildMeshes().length, 2);
    world.models.dispose(); world.models.dispose();
    assert.deepEqual([world.scene.meshes.length, world.scene.transformNodes.length], before);
    world.models.install('island_twin_cape', world.container); assert.equal(world.parent.getChildren().length, 0);
  } finally { world.close(); }
});

test('empty or degenerate imported geometry leaves no wrappers or shadow registrations', () => {
  const world = setup();
  try {
    const empty = new AssetContainer(world.scene);
    world.models.add('island_twin_cape', { parent: world.parent, width: 3, depth: 3, height: 4, floor: 0 });
    const before = world.scene.transformNodes.length;
    assert.throws(() => world.models.install('island_twin_cape', empty), /Invalid island geometry/);
    assert.equal(world.scene.transformNodes.length, before); assert.equal(world.parent.getChildren().length, 0);
    empty.dispose();
  } finally { world.close(); }
});


test('a rectangular imported island stays inside its navigation disk without changing height or source geometry', () => {
  const world = setup();
  try {
    const radius = 2.1;
    world.models.add('island_twin_cape', { parent: world.parent, width: 4.2, depth: 3.4, height: 3, floor: -0.12, footprintRadius: radius });
    world.models.install('island_twin_cape', world.container);
    const mesh = world.parent.getChildMeshes()[0], positions = mesh.getVerticesData('position')!;
    for (let index = 0; index < positions.length; index += 3) {
      const point = Vector3.TransformCoordinates(new Vector3(positions[index], positions[index + 1], positions[index + 2]), mesh.getWorldMatrix());
      assert.ok(Math.hypot(point.x, point.z) <= radius + 0.000001);
    }
    const bounds = world.parent.getHierarchyBoundingVectors(true);
    near(bounds.max.y - bounds.min.y, 3); near(bounds.min.y, -0.12);
    assert.equal((mesh as InstancedMesh).sourceMesh, world.mesh);
    near(world.mesh.getBoundingInfo().boundingBox.extendSize.x * 2, 8);
  } finally { world.close(); }
});
