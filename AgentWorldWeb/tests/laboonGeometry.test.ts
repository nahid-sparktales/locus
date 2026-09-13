import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { gunzipSync } from 'node:zlib';
import { NullEngine } from '@babylonjs/core/Engines/nullEngine.js';
import { Scene } from '@babylonjs/core/scene.js';
import { AssetContainer } from '@babylonjs/core/assetContainer.js';
import { TransformNode } from '@babylonjs/core/Meshes/transformNode.js';
import { Mesh } from '@babylonjs/core/Meshes/mesh.js';
import { DirectionalLight } from '@babylonjs/core/Lights/directionalLight.js';
import { ShadowGenerator } from '@babylonjs/core/Lights/Shadows/shadowGenerator.js';
import { Vector3 } from '@babylonjs/core/Maths/math.vector.js';
import { VertexBuffer } from '@babylonjs/core/Buffers/buffer.js';
import { GrandLineModels } from '../src/grandLineModels.ts';
import { LaboonReaction, LABOON_REACTION_SECONDS } from '../src/laboonInteraction.ts';
import { GRAND_LINE_LABOON_POSITION, GRAND_LINE_OBSTACLES } from '../src/grandLineGeography.ts';
import { parseTheme } from '../src/theme.ts';

test('the actual Laboon model stays inside its reserved water throughout its singing motion', t => {
  const manifestURL = new URL('../../plugins/agent-world/ui/themes/grand-line/theme.json', import.meta.url);
  const theme = parseTheme(JSON.parse(readFileSync(manifestURL, 'utf8')));
  const asset = theme.assets.creature_laboon; assert.ok(asset, 'Laboon must use its packaged Meshy model');
  const packed = readFileSync(new URL(asset, manifestURL)), file = asset.endsWith('.gz') ? gunzipSync(packed) : packed;
  const jsonLength = file.readUInt32LE(12), gltf = JSON.parse(file.subarray(20, 20 + jsonLength).toString('utf8'));
  assert.deepEqual(gltf.nodes, [{ mesh: 0, matrix: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1] }]);
  const primitive = gltf.meshes[0].primitives[0], accessor = gltf.accessors[primitive.attributes.POSITION], view = gltf.bufferViews[accessor.bufferView];
  assert.equal(accessor.type, 'VEC3'); assert.equal(accessor.componentType, 5126);
  const positions = new Float32Array(accessor.count * 3), dataStart = 28 + jsonLength + (view.byteOffset ?? 0) + (accessor.byteOffset ?? 0);
  for (let index = 0; index < accessor.count; index++) for (let axis = 0; axis < 3; axis++) {
    // Apply the same X reflection as Babylon's glTF root, keeping the actual
    // authored geometry while avoiding texture decoding in a NullEngine test.
    positions[index * 3 + axis] = file.readFloatLE(dataStart + index * (view.byteStride ?? 12) + axis * 4) * (axis === 0 ? -1 : 1);
  }
  const engine = new NullEngine(), scene = new Scene(engine), whale = new TransformNode('laboon', scene);
  const light = new DirectionalLight('sun', new Vector3(-1, -2, -1), scene), shadow = new ShadowGenerator(256, light);
  const container = new AssetContainer(scene), source = new Mesh('actual-laboon-geometry', scene);
  source.setVerticesData(VertexBuffer.PositionKind, positions); container.meshes.push(source); container.removeAllFromScene();
  const models = new GrandLineModels(scene, shadow, theme);
  try {
    whale.position.set(GRAND_LINE_LABOON_POSITION.x, 0, GRAND_LINE_LABOON_POSITION.z);
    models.add('creature_laboon', { parent: whale, width: 2.1, depth: 2.0, height: 1.8, footprintRadius: 0.96, floor: -0.25, rotation: -Math.PI / 4, animated: true, interactionID: 'laboon' });
    models.install('creature_laboon', container);
    const mesh = whale.getChildMeshes()[0], reaction = new LaboonReaction(); reaction.select(); reaction.sing(0);
    const reserved = GRAND_LINE_OBSTACLES.find(obstacle => obstacle.x === whale.position.x && obstacle.z === whale.position.z)!;
    assert.ok(mesh.isPickable); assert.equal(mesh.metadata.creatureID, 'laboon'); assert.equal(mesh.isWorldMatrixFrozen, false);
    const point = new Vector3(), world = new Vector3(); let maximumRadius = 0, maximumLift = 0;
    for (let frame = 0; frame <= 160; frame++) {
      const pose = reaction.pose(frame * LABOON_REACTION_SECONDS / 160, false);
      whale.position.y = pose.bob; whale.rotation.y = pose.turn; whale.rotation.z = pose.sway;
      maximumLift = Math.max(maximumLift, pose.bob);
      const matrix = mesh.computeWorldMatrix(true);
      for (let vertex = 0; vertex < positions.length; vertex += 3) {
        point.set(positions[vertex], positions[vertex + 1], positions[vertex + 2]); Vector3.TransformCoordinatesToRef(point, matrix, world);
        assert.ok(Number.isFinite(world.x) && Number.isFinite(world.y) && Number.isFinite(world.z));
        maximumRadius = Math.max(maximumRadius, Math.hypot(world.x - reserved.x, world.z - reserved.z));
      }
    }
    assert.ok(maximumLift > 0.25, 'Exercise the full reaction, not only a stationary model');
    assert.ok(maximumRadius <= reserved.radius, `Singing footprint ${maximumRadius} exceeds obstacle radius ${reserved.radius}`);
    t.diagnostic(`Maximum singing radius ${maximumRadius.toFixed(4)} within reserved ${reserved.radius}`);
    for (const time of [1, 3, 5, 7]) {
      const pose = reaction.pose(time, true); assert.ok([pose.bob, pose.sway, pose.turn].every(value => value === 0));
    }
    models.dispose(); assert.equal(whale.getChildren().length, 0); assert.equal(shadow.getShadowMap()?.renderList?.length, 0);
  } finally { models.dispose(); container.dispose(); scene.dispose(); engine.dispose(); }
});
