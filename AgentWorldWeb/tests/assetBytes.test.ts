import test from 'node:test';
import assert from 'node:assert/strict';
import { gzipSync } from 'node:zlib';
import { decompressModel } from '../src/assetBytes.ts';
import { safeAssetPath } from '../src/theme.ts';

test('lossless model containers decode to the exact GLB, including transparent HTTP decoding', async () => {
  const model = new Uint8Array(24), view = new DataView(model.buffer);
  view.setUint32(0, 0x46546c67, true); view.setUint32(4, 2, true); view.setUint32(8, 24, true);
  assert.deepEqual(await decompressModel(gzipSync(model)), model);
  assert.deepEqual(await decompressModel(model), model);
  await assert.rejects(decompressModel(gzipSync(new Uint8Array(25))), /Invalid GLB/);
  await assert.rejects(decompressModel(new Uint8Array(8)), /Invalid compressed/);
  assert.ok(safeAssetPath('assets/creature_laboon.glb.gz'));
  for (const path of ['../assets/a.glb.gz', 'assets/../a.glb.gz', 'https://example.com/a.glb.gz', 'assets/a.gz', 'assets/a.glb.gz.exe']) assert.equal(safeAssetPath(path), false);
});
