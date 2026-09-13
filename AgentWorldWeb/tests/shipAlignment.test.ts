import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { gunzipSync } from 'node:zlib';
import { NullEngine } from '@babylonjs/core/Engines/nullEngine.js';
import { Scene } from '@babylonjs/core/scene.js';
import { TransformNode } from '@babylonjs/core/Meshes/transformNode.js';
import { Vector3 } from '@babylonjs/core/Maths/math.vector.js';
import { VertexBuffer } from '@babylonjs/core/Buffers/buffer.js';
import { fitShipModel, createShipWake } from '../src/ships.ts';
import { SHIP_ASSET_TYPES, SHIP_MODEL_ROTATIONS, parseTheme } from '../src/theme.ts';
import type { ShipAssetType } from '../src/theme.ts';
import { createNavigation, createResidentMotion, stepResidentMotion } from '../src/residentMotion.ts';
import { shipBerthHeading } from '../src/islandBerths.ts';

const manifestURL = new URL('../../plugins/agent-world/ui/themes/grand-line/theme.json', import.meta.url);
const manifest = JSON.parse(readFileSync(manifestURL, 'utf8'));
const theme = parseTheme(manifest);
const newShips = ['ship_mihawk_coffin', 'ship_garp_battleship', 'ship_marine_patrol'] as const;
const near = (actual: number, expected: number, message = '') => assert.ok(Math.abs(actual - expected) < 0.00001, `${message}: ${actual} vs ${expected}`);

/** The September 2026 visual asset audit verified each raw GLB bow is -X.
 * Babylon's glTF root converts it to +X. Read the actual shipped geometry
 * bounds so new exports cannot silently bypass the normalization checks. */
function shippedBounds(type: ShipAssetType): { min: Vector3; max: Vector3 } {
  const packed = readFileSync(new URL(manifest.assets[type], manifestURL));
  const file = manifest.assets[type].endsWith('.gz') ? gunzipSync(packed) : packed;
  assert.equal(file.toString('ascii', 0, 4), 'glTF'); assert.equal(file.readUInt32LE(8), file.length);
  const gltf = JSON.parse(file.subarray(20, 20 + file.readUInt32LE(12)).toString('utf8'));
  assert.deepEqual(gltf.nodes, [{ mesh: 0, matrix: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1] }], `${type}: changed source transforms require a bow audit`);
  const min = new Vector3(Infinity, Infinity, Infinity), max = new Vector3(-Infinity, -Infinity, -Infinity);
  for (const primitive of gltf.meshes[0].primitives) {
    const accessor = gltf.accessors[primitive.attributes.POSITION];
    assert.equal(accessor.type, 'VEC3'); assert.equal(accessor.componentType, 5126);
    min.minimizeInPlace(new Vector3(-accessor.max[0], accessor.min[1], accessor.min[2]));
    max.maximizeInPlace(new Vector3(-accessor.min[0], accessor.max[1], accessor.max[2]));
  }
  assert.ok(max.x - min.x > max.z - min.z, `${type}: expected audited length on X`);
  return { min, max };
}

test('all fifteen packaged ship bows align with every compass course and retain centered waterlines', () => {
  const engine = new NullEngine(), scene = new Scene(engine);
  try {
    const captain = new TransformNode('captain', scene), pivot = new TransformNode('model-pivot', scene); pivot.parent = captain;
    for (const type of SHIP_ASSET_TYPES) {
      assert.equal(manifest.rotations[type], SHIP_MODEL_ROTATIONS[type], `${type}: manifest must explicitly calibrate the model`);
      const bounds = shippedBounds(type), fit = fitShipModel(type, bounds, theme.heights[type], theme.rotations[type]);
      assert.ok(Number.isFinite(fit.scale) && fit.scale > 0);
      assert.ok((bounds.max.y - bounds.min.y) * fit.scale <= theme.heights[type] + 0.00001);
      assert.ok(Math.max(bounds.max.x - bounds.min.x, bounds.max.z - bounds.min.z) * fit.scale <= 3.35001);
      near((bounds.min.x + bounds.max.x) / 2 * fit.scale + fit.offset.x, 0, `${type} X center`);
      near((bounds.min.z + bounds.max.z) / 2 * fit.scale + fit.offset.z, 0, `${type} Z center`);
      near(bounds.min.y * fit.scale + fit.offset.y + fit.waterline, -0.12, `${type} waterline`);
      pivot.rotation.y = fit.rotation;
      for (let compass = 0; compass < 16; compass++) {
        captain.rotation.y = compass * Math.PI / 8;
        const bow = Vector3.TransformNormal(Vector3.Right(), pivot.computeWorldMatrix(true)).normalize();
        near(bow.x, Math.sin(captain.rotation.y), `${type} bow X`);
        near(bow.z, Math.cos(captain.rotation.y), `${type} bow Z`);
      }
    }
  } finally { scene.dispose(); engine.dispose(); }
});

test('missing ship rotation inherits its audited calibration while a custom zero stays explicit', () => {
  for (const type of newShips) {
    const missing = parseTheme({ version: 1, id: 'grand-line', rotations: { [type]: NaN } });
    const custom = parseTheme({ version: 1, id: 'custom', rotations: { [type]: 0 } });
    assert.equal(missing.rotations[type], -Math.PI / 2);
    assert.equal(custom.rotations[type], 0);
    const bounds = shippedBounds(type);
    assert.equal(fitShipModel(type, bounds, 3).rotation, -Math.PI / 2);
    assert.equal(fitShipModel(type, bounds, 3, 0).rotation, 0);
  }
});

test('new ships sail bow-first through turns, trail their wake astern, and moor parallel to the pier', () => {
  const engine = new NullEngine(), scene = new Scene(engine), mapRoot = new TransformNode('map', scene);
  const sea = createNavigation({ radius: 20, bodyRadius: 1.35, obstacles: [{ x: 0, z: 0, radius: 3 }], wanderPoints: [{ x: 6, z: -6 }, { x: 6, z: 6 }, { x: -6, z: 6 }] });
  try {
    for (const type of newShips) {
      const home = { x: -6, z: -6, rotation: 0.7 }, fit = fitShipModel(type, shippedBounds(type), theme.heights[type], theme.rotations[type]);
      const captain = new TransformNode(type, scene), pivot = new TransformNode(`${type}-model`, scene);
      captain.parent = mapRoot; pivot.parent = captain; pivot.rotation.y = fit.rotation;
      const wake = createShipWake(scene, mapRoot, type);
      const foam = wake.getChildMeshes()[0], vertices = foam.getVerticesData(VertexBuffer.PositionKind)!;
      let motion = { ...createResidentMotion(type, home), speed: 1.2, pauseRemaining: 0 };
      let sailingFrames = 0, traveled = 0;
      const courses = new Set<number>();
      for (let tick = 0; tick < 2200; tick++) {
        const previous = motion;
        motion = stepResidentMotion(motion, { status: tick < 850 ? 'idle' : 'working', home, dt: 0.05 }, sea);
        captain.position.set(motion.x, 0, motion.z); captain.rotation.y = motion.heading;
        wake.position.copyFrom(captain.position); wake.rotation.y = motion.heading; wake.setEnabled(motion.walking);
        const bow = Vector3.TransformNormal(Vector3.Right(), pivot.computeWorldMatrix(true)).normalize();
        const displacement = new Vector3(motion.x - previous.x, 0, motion.z - previous.z);
        if (motion.walking) {
          sailingFrames++; traveled += displacement.length(); courses.add(Math.round(motion.heading * 10));
          assert.ok(Vector3.Dot(bow, displacement.normalize()) > 0.99999, `${type} must move along its bow, never sideways`);
          // The actual ribbon's trailing vertices remain behind both the bow
          // and velocity after each world-space heading change.
          const wakeMatrix = foam.computeWorldMatrix(true);
          let sternVertices = 0;
          for (let vertex = 0; vertex < vertices.length; vertex += 3) if (vertices[vertex + 2] < -2) {
            const tail = Vector3.TransformCoordinates(Vector3.FromArray(vertices, vertex), wakeMatrix).subtract(captain.position);
            assert.ok(Vector3.Dot(tail, bow) < -2, `${type} foam trails astern`); sternVertices++;
          }
          assert.ok(sternVertices >= 2);
        }
      }
      assert.ok(sailingFrames > 200 && traveled > 20 && courses.size >= 3, `${type}: exercise real travel and multiple turns`);
      near(motion.x, home.x); near(motion.z, home.z); near(motion.heading, shipBerthHeading(home));
      assert.equal(motion.walking, false); assert.equal(wake.isEnabled(), false);
      const bowAtBerth = Vector3.TransformNormal(Vector3.Right(), pivot.computeWorldMatrix(true)).normalize();
      near(Vector3.Dot(bowAtBerth, new Vector3(Math.sin(home.rotation), 0, Math.cos(home.rotation))), 0, `${type} moors alongside`);
      captain.dispose(); wake.dispose();
    }
  } finally { scene.dispose(); engine.dispose(); }
});
