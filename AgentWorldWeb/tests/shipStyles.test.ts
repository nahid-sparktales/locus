import test from 'node:test';
import assert from 'node:assert/strict';
import { NullEngine } from '@babylonjs/core/Engines/nullEngine.js';
import { Scene } from '@babylonjs/core/scene.js';
import { TransformNode } from '@babylonjs/core/Meshes/transformNode.js';
import { MeshBuilder } from '@babylonjs/core/Meshes/meshBuilder.js';
import { DirectionalLight } from '@babylonjs/core/Lights/directionalLight.js';
import { ShadowGenerator } from '@babylonjs/core/Lights/Shadows/shadowGenerator.js';
import { Vector3 } from '@babylonjs/core/Maths/math.vector.js';
import { DEFAULT_SHIP_ASSET_TYPES, DEFAULT_THEME, SHIP_ASSET_TYPES, SHIP_NAMES, parseTheme } from '../src/theme.ts';
import { residentAssetForID } from '../src/residentMotion.ts';
import { replaceShipFallback } from '../src/ships.ts';

const originalTypes = ['ship_thousand_sunny', 'ship_going_merry', 'ship_baratie', 'ship_navy_h03', 'ship_polar_tang', 'ship_spade_pirates', 'ship_red_force', 'ship_moby_dick', 'ship_perfume_yuda', 'ship_oro_jackson', 'ship_queen_mama_chanter', 'ship_dragons_ship'] as const;

test('manual ship choices extend the library without changing automatic assignments', () => {
  assert.deepEqual(DEFAULT_SHIP_ASSET_TYPES, originalTypes);
  assert.equal(SHIP_ASSET_TYPES.length, 15);
  assert.equal(new Set(SHIP_ASSET_TYPES.map(type => SHIP_NAMES[type])).size, 15);
  for (let index = 0; index < 100; index++) assert.equal(residentAssetForID(`captain-${index}`, DEFAULT_SHIP_ASSET_TYPES), residentAssetForID(`captain-${index}`, originalTypes));
  for (const type of ['ship_mihawk_coffin', 'ship_garp_battleship', 'ship_marine_patrol'] as const) {
    assert.ok(!(DEFAULT_SHIP_ASSET_TYPES as readonly string[]).includes(type));
    assert.ok(DEFAULT_THEME.heights[type] > 0);
    const theme = parseTheme({ version: 1, id: 'grand-line', environment: 'ocean', assets: { [type]: `assets/${type}.glb` }, rotations: { [type]: -Math.PI / 2 } });
    assert.equal(theme.assets[type], `assets/${type}.glb`); assert.equal(theme.rotations[type], -Math.PI / 2);
  }
});

test('all fifteen ship fallbacks can be swapped without moving the captain or deleting a live Den Den signal', () => {
  const engine = new NullEngine(), scene = new Scene(engine), root = new TransformNode('captain-id', scene);
  const sun = new DirectionalLight('sun', new Vector3(-1, -2, -1), scene), shadow = new ShadowGenerator(256, sun);
  try {
    root.position.set(11, 0.075, -7); root.rotation.set(0.018, 0.74, -0.027);
    const signal = new TransformNode('live-den-den', scene); signal.parent = root; signal.metadata = { worldSignal: true };
    const phone = MeshBuilder.CreateBox('telephone', { size: 0.3 }, scene); phone.parent = signal; phone.metadata = { attentionID: 'real-request' };
    const rootPosition = root.position.asArray(), rootRotation = root.rotation.asArray();
    for (let repeat = 0; repeat < 2; repeat++) for (const type of SHIP_ASSET_TYPES) {
      const fallback = replaceShipFallback(scene, shadow, root, type);
      assert.deepEqual(root.position.asArray(), rootPosition); assert.deepEqual(root.rotation.asArray(), rootRotation);
      assert.equal(signal.parent, root); assert.ok(!phone.isDisposed()); assert.equal(phone.metadata.attentionID, 'real-request');
      assert.equal(root.getChildren().length, 2, 'Only the current fallback and live signal remain');
      for (const mesh of fallback.getChildMeshes()) {
        assert.ok(mesh.isPickable); assert.equal(mesh.metadata.actorID, 'captain-id');
        mesh.computeWorldMatrix(true);
        assert.ok(mesh.getBoundingInfo().boundingBox.minimumWorld.asArray().every(Number.isFinite));
      }
      if (type === 'ship_mihawk_coffin') assert.ok(fallback.getChildMeshes().some(mesh => mesh.name === 'coffin-cross-mast'));
      if (type === 'ship_garp_battleship') assert.ok(fallback.getChildMeshes().some(mesh => mesh.name === 'garp-dog-figurehead'));
      if (type === 'ship_marine_patrol') assert.ok(fallback.getChildMeshes().some(mesh => mesh.name === 'marine-blue-sail-stripe'));
    }
    const materials = scene.materials.length;
    for (const type of SHIP_ASSET_TYPES) replaceShipFallback(scene, shadow, root, type);
    assert.equal(scene.materials.length, materials, 'Repeated changes reuse bounded palette materials');
    root.dispose();
    assert.equal(scene.meshes.length, 0); assert.equal(scene.geometries.length, 0); assert.equal(shadow.getShadowMap()?.renderList?.length, 0);
  } finally { scene.dispose(); engine.dispose(); }
});
