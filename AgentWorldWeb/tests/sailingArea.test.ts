import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { NullEngine } from '@babylonjs/core/Engines/nullEngine.js';
import { Scene } from '@babylonjs/core/scene.js';
import { ArcRotateCamera } from '@babylonjs/core/Cameras/arcRotateCamera.js';
import { Vector3, Matrix } from '@babylonjs/core/Maths/math.vector.js';
import { parseTheme } from '../src/theme.ts';
import { sailingHarbors, sailingNavigation, sailingCameraFrame, isSailingArea } from '../src/sailingArea.ts';
import { GRAND_LINE_LANDMARKS, RED_LINE_X } from '../src/grandLineGeography.ts';
import { pointIsWalkable, segmentIsWalkable, findResidentPath, createResidentMotion, stepResidentMotion, resolveResidentSpacing } from '../src/residentMotion.ts';
import { agentSector, sectorAgents, parseHostMessage } from '../src/state.ts';

const theme = parseTheme(JSON.parse(readFileSync(new URL('../../plugins/agent-world/ui/themes/grand-line/theme.json', import.meta.url), 'utf8')));

test('restricted fleets retain navigable berths and cannot cross to the other sea', () => {
  for (const area of ['left', 'right'] as const) {
    const harbors = sailingHarbors(area), sea = sailingNavigation(theme, area);
    assert.ok(harbors.length >= 8);
    for (const harbor of harbors) {
      assert.ok(pointIsWalkable(harbor, sea), `${area}: ${harbor.name}`);
      assert.equal(GRAND_LINE_LANDMARKS[harbor.islandIndex].name, harbor.name, 'Crew and work lights keep the original island identity');
      for (const target of harbors) {
        const path = findResidentPath(harbor, target, sea); assert.ok(path, `${harbor.id} → ${target.id}`);
        let from = harbor;
        for (const step of path) { assert.ok(segmentIsWalkable(from, step, sea)); from = { ...from, ...step }; }
      }
      for (const foreign of sailingHarbors(area === 'left' ? 'right' : 'left')) assert.equal(findResidentPath(harbor, foreign, sea), null);
    }
    for (const point of sea.wanderPoints) assert.equal(point.x > RED_LINE_X, area === 'left');
    assert.equal(segmentIsWalkable({ x: -35, z: 0 }, { x: -23, z: 0 }, sea), false, 'The mountain entrance also respects the selected side');
  }
});

test('idle, working and attention ships stay inside the selected sea during traffic', () => {
  for (const area of ['left', 'right'] as const) {
    const homes = sailingHarbors(area).slice(0, 12), sea = sailingNavigation(theme, area);
    const ids = homes.map((_, i) => `scoped-${i}`);
    let states = homes.map((home, i) => createResidentMotion(ids[i], home));
    for (let frame = 0; frame < 1600; frame++) {
      const proposed = states.map((state, i) => stepResidentMotion(state, { home: homes[i], status: i % 3 === 0 ? 'working' : i % 3 === 1 ? 'idle' : 'needs_attention', dt: 0.05, rosterIDs: ids }, sea));
      const next = resolveResidentSpacing(proposed, states, sea);
      for (let i = 0; i < next.length; i++) assert.ok(segmentIsWalkable(states[i], next[i], sea));
      states = next;
    }
  }
});

test('left and right match the overview screen, with tighter zoom limits and responsive framing', () => {
  const engine = new NullEngine({ renderWidth: 1280, renderHeight: 800, textureSize: 512, deterministicLockstep: false, lockstepMaxSteps: 4 }), scene = new Scene(engine);
  try {
    const whole = sailingCameraFrame('whole', 1280, 800);
    const camera = new ArcRotateCamera('overview', Math.PI / 2, whole.beta, whole.radius, new Vector3(whole.x, 0.9, 0), scene);
    camera.getViewMatrix(true); camera.getProjectionMatrix(true); scene.updateTransformMatrix(true);
    const viewport = camera.viewport.toGlobal(1280, 800);
    const project = (x: number) => Vector3.Project(new Vector3(x, 0, 0), Matrix.IdentityReadOnly, scene.getTransformMatrix(), viewport).x;
    assert.ok(project(sailingCameraFrame('left', 1280, 800).x) < project(RED_LINE_X));
    assert.ok(project(sailingCameraFrame('right', 1280, 800).x) > project(RED_LINE_X));
    for (const area of ['left', 'right'] as const) {
      const frame = sailingCameraFrame(area, 1280, 800);
      assert.ok(frame.radius < whole.radius && frame.maximum < whole.maximum);
      assert.ok(sailingCameraFrame(area, 500, 800).radius > frame.radius, 'Narrow windows fit the same sea');
    }
  } finally { scene.dispose(); engine.dispose(); }
});

test('regional fleet pages keep every captain selectable and validate saved choices', () => {
  const agents = Array.from({ length: 27 }, (_, i) => ({ id: `00000000-0000-4000-8000-${String(i).padStart(12, '0')}`, name: 'Captain', role: '', status: 'idle' as const }));
  for (const area of ['whole', 'left', 'right'] as const) {
    const size = Math.min(12, sailingHarbors(area).length);
    for (const agent of agents) assert.ok(sectorAgents(agents, agentSector(agents, agent.id, size), size).includes(agent));
    assert.ok(parseHostMessage({ version: 1, type: 'snapshot', theme: 'grand-line', projectName: '', agents, sailingArea: area }));
  }
  for (const bad of ['', 'north', 1, null, true]) {
    assert.equal(isSailingArea(bad), false);
    assert.equal(parseHostMessage({ version: 1, type: 'snapshot', theme: 'grand-line', projectName: '', agents, sailingArea: bad }), null);
  }
});
