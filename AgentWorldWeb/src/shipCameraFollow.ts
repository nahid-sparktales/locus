import type { ArcRotateCamera } from '@babylonjs/core/Cameras/arcRotateCamera.js';
import { Vector3 } from '@babylonjs/core/Maths/math.vector.js';

/** Move the camera with its target, preserving the user's orbit and zoom. */
export function stepShipCameraFollow(camera: ArcRotateCamera, position: { x: number; z: number }, dt: number,
  reducedMotion: boolean, focusRadius?: number): number | undefined {
  const blend = reducedMotion ? 1 : 1 - Math.exp(-Math.max(0, Math.min(dt, 0.05)) * 7);
  camera.setTarget(Vector3.Lerp(camera.target, new Vector3(position.x, 0.8, position.z), blend), false, false, true);
  if (focusRadius === undefined) return;
  camera.radius += (focusRadius - camera.radius) * blend;
  return Math.abs(camera.radius - focusRadius) < 0.02 ? undefined : focusRadius;
}
