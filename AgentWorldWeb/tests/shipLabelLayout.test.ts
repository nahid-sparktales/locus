import test from 'node:test';
import assert from 'node:assert/strict';
import { placeShipLabel } from '../src/shipLabelLayout.ts';

test('ship cards remain inside the viewport for distant, off-screen and close-up anchors', () => {
  for (const [x, y] of [[450, 250], [-2000, -1000], [2000, 900], [NaN, Infinity], [1, 1]]) {
    const box = placeShipLabel(x, y, 150, 80, 900, 620, []);
    assert.ok(box.left >= 12 && box.top >= 12 && box.right <= 888 && box.bottom <= 608);
    assert.equal(box.right - box.left, 150, 'Zoom never shrinks the text');
  }
});

test('a crowded twelve-ship fleet keeps every card clear of the controls and each other', () => {
  const occupied = [{ left: 0, top: 0, right: 1280, bottom: 80 }, { left: 950, top: 90, right: 1280, bottom: 270 }];
  for (let i = 0; i < 12; i++) {
    const card = placeShipLabel(600 + i * 2, 450, 150, 80, 1280, 820, occupied);
    for (const other of occupied) assert.ok(card.right <= other.left || card.left >= other.right || card.bottom <= other.top || card.top >= other.bottom);
    occupied.push(card);
  }
});
