import test from 'node:test';
import assert from 'node:assert/strict';
import { LaboonReaction, LABOON_REACTION_SECONDS } from '../src/laboonInteraction.ts';

test('Laboon requires selection, ignores repeated triggers, and returns to rest after a song', () => {
  const whale = new LaboonReaction();
  assert.equal(whale.sing(0), false);
  for (const time of [0, 10, Infinity, NaN]) {
    const pose = whale.pose(time, false);
    assert.equal(pose.active, false);
    assert.ok([pose.bob, pose.sway, pose.turn].every(value => Number.isFinite(value) && value === 0));
  }
  whale.select(); assert.equal(whale.sing(2), true);
  assert.equal(whale.sing(2.1), false);
  assert.equal(whale.sing(NaN), false);
  const pose = whale.pose(3, false);
  assert.ok(pose.active && pose.bob > 0); assert.match(pose.text, /Bwooo/);
  const stopped = whale.pose(2 + LABOON_REACTION_SECONDS, false);
  assert.equal(stopped.active, false); assert.equal(stopped.bob, 0);
  whale.dismiss(); assert.equal(whale.sing(20), false);
});

test('reduced motion keeps the musical response without moving the whale', () => {
  const whale = new LaboonReaction(); whale.select(); whale.sing(1);
  const pose = whale.pose(3, true);
  assert.ok(pose.active); assert.match(pose.text, /♪/);
  assert.ok([pose.bob, pose.sway, pose.turn].every(value => value === 0));
  whale.sing(5); assert.match(whale.pose(6, false).text, /promise/);
});
