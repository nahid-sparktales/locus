import test from 'node:test';
import assert from 'node:assert/strict';
import { NullEngine } from '@babylonjs/core/Engines/nullEngine.js';
import { Scene } from '@babylonjs/core/scene.js';
import { TransformNode } from '@babylonjs/core/Meshes/transformNode.js';
import { createNewsCoo } from '../src/newsCoo.ts';
import { newsCooFlight } from '../src/newsCooFlight.ts';
import type { NewsCooPose } from '../src/newsCooFlight.ts';

function assertFinite(pose: NewsCooPose) {
  for (const field of ['x', 'y', 'z', 'heading', 'bank', 'flap'] as const) {
    assert.ok(Number.isFinite(pose[field]), `${field} is not finite: ${JSON.stringify(pose)}`);
  }
}
function setup() {
  const engine = new NullEngine(), scene = new Scene(engine), parent = new TransformNode('world-scenery', scene);
  return { engine, scene, parent, close() { scene.dispose(); engine.dispose(); } };
}
function resources(scene: Scene) {
  return { meshes: scene.meshes.length, nodes: scene.transformNodes.length, geometries: scene.geometries.length,
    materials: scene.materials.filter(material => material.name.startsWith('news-coo-')).length };
}
function birds(parent: TransformNode) {
  const flock = parent.getChildren(undefined, true).find(node => node.name === 'news-coo-flock') as TransformNode;
  assert.ok(flock, 'The flock belongs to the scene scenery root');
  return flock.getChildren(undefined, true) as TransformNode[];
}
function transforms(pool: TransformNode[]) {
  return pool.map(bird => [...bird.position.asArray(), ...bird.rotation.asArray(),
    ...bird.getChildTransformNodes(true).flatMap(wing => wing.rotation.asArray())]);
}

for (const ocean of [false, true]) {
  const environment = ocean ? 'ocean' : 'outpost';
  test(`${environment}: staggered visits leave long quiet intervals and return from the other direction`, () => {
    for (const bird of [0, 1, 2]) {
      assert.equal(newsCooFlight(9.99, bird, ocean, false).visible, false);
      const takeoff = 10 + bird * 1.45;
      assert.equal(newsCooFlight(takeoff + 0.01, bird, ocean, false).visible, true);
      assert.equal(newsCooFlight(takeoff + 24.01, bird, ocean, false).visible, false);
      const first = newsCooFlight(takeoff + 5, bird, ocean, false);
      const later = newsCooFlight(takeoff + 6, bird, ocean, false);
      const returning = newsCooFlight(takeoff + 68 + 5, bird, ocean, false);
      const returningLater = newsCooFlight(takeoff + 68 + 6, bird, ocean, false);
      assert.ok(later.x > first.x && returningLater.x < returning.x, 'Successive visits cross in opposite directions');
      let visibleFrames = 0;
      for (let frame = 0; frame < 680; frame++) {
        const pose = newsCooFlight(10 + frame / 10, bird, ocean, false);
        assertFinite(pose); visibleFrames += Number(pose.visible);
        if (pose.visible) {
          assert.ok(Math.abs(pose.x) <= (ocean ? 43 : 22));
          assert.ok(pose.y > (ocean ? 7 : 5), 'Birds clear the working areas');
          assert.ok(Math.abs(pose.bank) <= 0.12 && Math.abs(pose.flap) <= 0.4);
        }
      }
      assert.ok(visibleFrames > 200 && visibleFrames < 270, 'Visitors spend most of each cycle off the map');
    }
    assert.equal(newsCooFlight(10.5, 0, ocean, false).visible, true);
    assert.equal(newsCooFlight(10.5, 1, ocean, false).visible, false);
    assert.equal(newsCooFlight(12, 1, ocean, false).visible, true);
    assert.equal(newsCooFlight(12, 2, ocean, false).visible, false);
  });

  test(`${environment}: a fixed three-bird pool honors reduced motion and releases all resources`, () => {
    const world = setup();
    try {
      const baseline = resources(world.scene), coo = createNewsCoo(world.scene, world.parent, ocean);
      const pool = birds(world.parent), initial = resources(world.scene);
      assert.equal(pool.length, 3);
      assert.equal(initial.materials, 6, 'Birds share a small material palette');
      assert.ok(initial.meshes > 0 && initial.meshes <= 90, 'The flock has a bounded geometry budget');
      assert.ok(pool.every(bird => !bird.isEnabled()));
      assert.ok(world.scene.meshes.every(mesh => mesh.isPickable === false), 'Scenery must not intercept agent clicks');
      coo.update(18, false);
      assert.ok(pool.every(bird => bird.isEnabled()));
      const position = pool[0].position.asArray();
      coo.update(19, false);
      assert.notDeepEqual(pool[0].position.asArray(), position);
      for (let frame = 0; frame < 1_400; frame++) {
        coo.update(frame / 2, false);
        for (const bird of pool) assert.ok([...bird.position.asArray(), ...bird.rotation.asArray(), ...bird.scaling.asArray()].every(Number.isFinite));
      }
      assert.deepEqual(resources(world.scene), initial, 'Repeated visits cannot allocate scene resources');
      assert.deepEqual(birds(world.parent), pool, 'The same three birds serve every visit');
      coo.update(18, true);
      assert.ok(pool.every(bird => !bird.isEnabled()));
      const reduced = transforms(pool);
      coo.update(90, true);
      assert.deepEqual(transforms(pool), reduced);
      coo.update(Number.NaN, false);
      assert.ok(pool.every(bird => !bird.isEnabled()));
      coo.dispose();
      assert.deepEqual(resources(world.scene), baseline, 'Disposal releases all meshes, pivots, geometry and materials');
      assert.equal(world.parent.isDisposed(), false, 'The caller still owns the map root');
      coo.dispose(); coo.update(18, false);
      assert.deepEqual(resources(world.scene), baseline, 'Stale updates cannot recreate disposed birds');
      const replacement = createNewsCoo(world.scene, world.parent, ocean);
      replacement.update(18, false);
      assert.ok(birds(world.parent).every(bird => bird.isEnabled()));
      replacement.dispose();
      assert.deepEqual(resources(world.scene), baseline);
    } finally { world.close(); }
  });
}

test('invalid inputs never expose invalid poses and reduced motion suppresses every visit', () => {
  for (const ocean of [false, true]) {
    for (const elapsed of [Number.NaN, Number.POSITIVE_INFINITY, Number.NEGATIVE_INFINITY, -100, 0, 9.9]) {
      const pose = newsCooFlight(elapsed, 0, ocean, false);
      assert.equal(pose.visible, false); assertFinite(pose);
    }
    for (const elapsed of [10, 18, 80, 1e6, 1e20, Number.MAX_VALUE]) {
      for (const bird of [0, 1, 2]) {
        assertFinite(newsCooFlight(elapsed, bird, ocean, false));
        const reduced = newsCooFlight(elapsed, bird, ocean, true);
        assert.equal(reduced.visible, false); assertFinite(reduced);
      }
    }
    for (const bird of [Number.NaN, Number.POSITIVE_INFINITY, Number.NEGATIVE_INFINITY, -1, 0.5, 3]) {
      const pose = newsCooFlight(18, bird, ocean, false);
      assert.equal(pose.visible, false); assertFinite(pose);
    }
  }
});
