import { GRAND_LINE_HARBORS, GRAND_LINE_MAP_RADIUS, RED_LINE_X } from './grandLineGeography.ts';
import { createNavigation } from './residentMotion.ts';
import type { Theme } from './theme.ts';

export const SAILING_AREAS = ['whole', 'left', 'right'] as const;
export type SailingArea = typeof SAILING_AREAS[number];
export const isSailingArea = (value: unknown): value is SailingArea => SAILING_AREAS.includes(value as SailingArea);
export const SAILING_AREA_NAMES: Record<SailingArea, string> = { whole: 'Whole map', left: 'Left side', right: 'Right side' };

// The overview looks south: positive X is screen-left. These are fixed seas,
// so orbiting the camera never changes which islands the fleet may visit.
export function sailingHarbors(area: SailingArea) {
  return GRAND_LINE_HARBORS.map((harbor, islandIndex) => ({ ...harbor, islandIndex }))
    .filter(harbor => area === 'whole' || (area === 'left' ? harbor.x > RED_LINE_X : harbor.x < RED_LINE_X));
}

export function sailingNavigation(theme: Theme, area: SailingArea, bodyRadius = 1.35) {
  return createNavigation({ radius: theme.layout.radius, sailingBounds: theme.layout.sailingBounds, bodyRadius,
    horizontalBounds: area === 'whole' ? undefined : area === 'left'
      ? { minX: RED_LINE_X + 2.6, maxX: GRAND_LINE_MAP_RADIUS }
      : { minX: -GRAND_LINE_MAP_RADIUS, maxX: RED_LINE_X - 2.6 },
    obstacles: theme.layout.obstacles, wanderPoints: theme.layout.wanderPoints });
}

/** Fit the selected sea, including its tall scenery, at the actual window size. */
export function sailingCameraFrame(area: SailingArea, width: number, height: number, fov = 0.8) {
  const bounds = area === 'left' ? { minX: -32, maxX: 66 } : area === 'right' ? { minX: -86, maxX: -26 } : { minX: -86, maxX: 66 };
  const beta = 0.74, depth = area === 'whole' ? 32 : 24;
  const aspect = Math.max(0.4, Math.max(1, width) / Math.max(1, height));
  const tan = Math.tan(fov / 2);
  // Leave space above ships for their labels and below for the map controls.
  const radius = Math.max((bounds.maxX - bounds.minX) / (2 * tan * aspect), (depth * Math.cos(beta) + (area === 'whole' ? 9 : 6)) / tan) * 1.13 + depth * Math.sin(beta);
  return { x: (bounds.minX + bounds.maxX) / 2, z: area === 'right' ? -3 : 0, beta, radius, minimum: 13, maximum: radius * 1.55 };
}
