import test from 'node:test';
import assert from 'node:assert/strict';
import { shipLabelDetail, shipLabelOnScreen } from '../src/shipLabelDetail.ts';

test('zooming in progressively restores ship name and full details', () => {
  assert.equal(shipLabelDetail(180, 800, 0.8), 'badge');
  assert.equal(shipLabelDetail(70, 800, 0.8), 'compact');
  assert.equal(shipLabelDetail(25, 800, 0.8), 'full');
  assert.equal(shipLabelDetail(70, 400, 0.8), 'badge', 'Short windows keep the map uncluttered');
});

test('camera limits and invalid geometry never produce an unusably small target', () => {
  assert.equal(shipLabelDetail(10000, 800, 0.8), 'badge');
  assert.equal(shipLabelDetail(1, 800, 0.8), 'full');
  for (const radius of [0, -1, Infinity, NaN]) assert.equal(shipLabelDetail(radius, 800, 0.8), 'badge');
  assert.equal(shipLabelDetail(30, 0, 0.8), 'badge');
  assert.equal(shipLabelDetail(30, 800, Math.PI), 'badge');
});

test('labels only appear for ships inside the visible camera viewport', () => {
  assert.equal(shipLabelOnScreen(400, 300, 0.5, 800, 600), true);
  for (const [x, y, depth] of [[-1, 300, 0.5], [801, 300, 0.5], [400, -1, 0.5], [400, 601, 0.5], [400, 300, -1], [400, 300, 1.1], [NaN, 300, 0.5]]) {
    assert.equal(shipLabelOnScreen(x, y, depth, 800, 600), false);
  }
});
