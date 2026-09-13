import test from 'node:test';
import assert from 'node:assert/strict';
import { islandCrewActivity, shipBerthHeading } from '../src/islandBerths.ts';
import { createResidentMotion, createNavigation, stepResidentMotion, MAX_MOTION_DT } from '../src/residentMotion.ts';

const home = { x: -3, z: 0, rotation: Math.PI / 2 };
const map = createNavigation({ radius: 14, bodyRadius: 1.35, wanderPoints: [{ x: -6, z: 0 }, { x: -6, z: 3 }] });
const difference = (a: number, b: number) => Math.abs(Math.atan2(Math.sin(a - b), Math.cos(a - b)));

test('a busy ship settles sideways smoothly before its crew may come ashore', () => {
  let motion = { ...createResidentMotion('captain', home), z: -3, speed: 1 };
  let allowed = false;
  for (let step = 0; step < 180; step++) {
    const next = stepResidentMotion(motion, { status: 'working', home, dt: MAX_MOTION_DT }, map);
    const moved = Math.hypot(next.x - motion.x, next.z - motion.z);
    assert.ok(moved <= MAX_MOTION_DT + 0.000001, 'Docking cannot teleport a ship');
    assert.ok(difference(next.heading, motion.heading) <= 4.8 * MAX_MOTION_DT + 0.000001, 'Docking turns stay bounded');
    if (moved > 0.00001) assert.ok(difference(next.heading, Math.atan2(next.x - motion.x, next.z - motion.z)) < 0.002, 'Approach stays bow-first');
    const activity = islandCrewActivity('working', next, home);
    if (next.walking || difference(next.heading, shipBerthHeading(home)) > 0.06) assert.equal(activity, undefined);
    allowed ||= activity === 'working'; motion = next;
  }
  assert.ok(allowed);
  assert.ok(difference(motion.heading, shipBerthHeading(home)) < 0.00001);
  assert.ok(Math.abs(Math.cos(motion.heading - home.rotation)) < 0.00001, 'The docked hull is tangent to the island');
  assert.equal(islandCrewActivity('idle', motion, home), undefined, 'Crew departs immediately when the task ends');
  assert.equal(islandCrewActivity('completed', motion, home), undefined);
  for (const status of ['queued', 'needs_attention', 'failed'] as const) assert.equal(islandCrewActivity(status, motion, home), 'waiting');
  assert.equal(islandCrewActivity('working', { ...motion, phase: 'paused' }, home), undefined, 'Selection pauses alone cannot create work');
  assert.equal(islandCrewActivity('working', { ...motion, x: home.x + 0.10 }, home), undefined, 'Near the pier is not the final berth');
});

test('departures turn the bow toward the course without dragging an ashore crew or shifting the approach bearing', () => {
  const original = structuredClone(home);
  let motion = { ...createResidentMotion('departing-captain', home), heading: shipBerthHeading(home), speed: 1, pauseRemaining: 0 };
  let departed = false;
  for (let step = 0; step < 1200; step++) {
    const next = stepResidentMotion(motion, { status: 'idle', home, dt: MAX_MOTION_DT }, map);
    assert.equal(islandCrewActivity('idle', next, home), undefined);
    const moved = Math.hypot(next.x - motion.x, next.z - motion.z);
    if (moved > 0.00001) {
      assert.ok(difference(next.heading, Math.atan2(next.x - motion.x, next.z - motion.z)) < 0.002);
      departed = true;
    }
    motion = next;
  }
  assert.ok(departed, 'A broadside-docked idle ship must still depart for its normal patrol');
  assert.deepEqual(home, original, 'Parked heading must not rotate the original offshore approach geometry');
});
