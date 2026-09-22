import test from 'node:test';
import assert from 'node:assert/strict';
import { NullEngine } from '@babylonjs/core/Engines/nullEngine.js';
import { Scene } from '@babylonjs/core/scene.js';
import { TransformNode } from '@babylonjs/core/Meshes/transformNode.js';
import { activeWorkIslands, createIslandWorkSignals, MAX_WORK_ISLANDS } from '../src/islandWorkSignals.ts';
import type { IslandWorker } from '../src/islandWorkSignals.ts';
import { createResidentMotion } from '../src/residentMotion.ts';
import { shipBerthHeading } from '../src/islandBerths.ts';
import { AGENT_STATUSES } from '../src/state.ts';

function worker(id = 'captain', harbor = 0): IslandWorker {
  const home = { x: 0, z: 5, rotation: 0 };
  return { id, harbor, home, status: 'working', motion: { ...createResidentMotion(id, home), heading: shipBerthHeading(home) } };
}

test('only real working crew settled at its own shore lights an island', () => {
  const captain = worker();
  assert.equal(activeWorkIslands([captain], 12).get('captain'), 0);
  assert.equal(activeWorkIslands([worker('new-world', 15)], 16).get('new-world'), 15, 'The newly available islands also light up');
  for (const status of AGENT_STATUSES.filter(status => status !== 'working')) assert.equal(activeWorkIslands([{ ...captain, status }], 12).size, 0);
  for (const change of [{ walking: true }, { x: 6 }, { heading: 0 }, { phase: 'returning' as const }, { intent: 'wander' as const }]) {
    assert.equal(activeWorkIslands([{ ...captain, motion: { ...captain.motion, ...change } }], 12).size, 0);
  }
  assert.equal(activeWorkIslands([{ ...captain, motion: { ...captain.motion, x: 9, z: 9, home: { x: 9, z: 9 } } }], 12).size, 0, 'An alliance visitor must not illuminate its empty home island');
  for (const harbor of [undefined, -1, 0.5, 16, 200]) assert.equal(activeWorkIslands([{ ...captain, harbor }], 20).size, 0);
});

test('island glow is bounded, turns off immediately, stays static for reduced motion and fully disposes', () => {
  const engine = new NullEngine(), scene = new Scene(engine), parent = new TransformNode('sea', scene);
  try {
    const signals = createIslandWorkSignals(scene, parent, Array.from({ length: 20 }, (_, index) => ({ x: index * 4, z: 0, radius: 2, marker: { x: index * 4, z: 1.8, y: 0.7 } })));
    assert.equal(signals.root.getChildTransformNodes(true).length, MAX_WORK_ISLANDS);
    const captain = worker(), counts = [scene.meshes.length, scene.geometries.length, scene.materials.length];
    for (let index = 0; index < 1000; index++) signals.update([captain], index / 30, false);
    assert.deepEqual([scene.meshes.length, scene.geometries.length, scene.materials.length], counts);
    assert.equal(scene.meshes.filter(mesh => mesh.isEnabled()).length, 3);
    assert.ok(scene.meshes.every(mesh => !mesh.isPickable));
    signals.update([captain], 5, true);
    const transforms = scene.meshes.map(mesh => [mesh.position.asArray(), mesh.rotation.asArray(), mesh.visibility]);
    signals.update([captain], 25, true);
    assert.deepEqual(scene.meshes.map(mesh => [mesh.position.asArray(), mesh.rotation.asArray(), mesh.visibility]), transforms);
    signals.update([{ ...captain, status: 'completed' }], 26, false);
    assert.equal(scene.meshes.filter(mesh => mesh.isEnabled()).length, 0);
    signals.dispose(); signals.dispose(); signals.update([captain], 27, false);
    assert.equal(scene.meshes.length, 0); assert.equal(scene.geometries.length, 0);
    assert.equal(scene.materials.filter(material => /work-shore|work-beacon/.test(material.name)).length, 0);
  } finally { scene.dispose(); engine.dispose(); }
});
