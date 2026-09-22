import type { CircleObstacle, Placement, SceneryAssetType } from './theme.ts';
import type { Point } from './state.ts';

/** A winding chain of small archipelagos: varied scale, open central water,
 * and broad passages between destinations. Original order preserves homes. */
export const GRAND_LINE_LANDMARKS = [
  { id: 'twin-cape', name: 'Twin Cache', subtitle: 'A FRESH CONTEXT WINDOW', x: -23, z: -12, radius: 1.8, harborFacing: 'east' },
  { id: 'little-garden', name: 'Little Gradient', subtitle: 'SMALL MODELS. BIG IDEAS.', x: -18.5, z: 7.5, radius: 2.0, harborFacing: 'south' },
  { id: 'drum', name: 'DRAM Island', subtitle: 'COLD STORAGE. WARM WELCOMES.', x: -13.8, z: -5.8, radius: 2.3, harborFacing: 'north' },
  { id: 'alabasta', name: 'Alabatcha', subtitle: 'BATCHES IN THE DUNES', x: -13, z: 18, radius: 3.2, harborFacing: 'east' },
  { id: 'water-seven', name: 'Water 7B', subtitle: 'SEVEN BILLION POSSIBILITIES', x: -3, z: -6, radius: 3.1, harborFacing: 'south' },
  { id: 'enies-lobby', name: 'Enies LoRA', subtitle: 'SMALL ADAPTERS. BIG ADVENTURES.', x: 5, z: -14, radius: 1.7, harborFacing: 'east' },
  { id: 'sabaody', name: 'Sabaudio', subtitle: 'WHERE EVERY VOICE HAS A HOME', x: 5.5, z: 8.5, radius: 2.8, harborFacing: 'south' },
  { id: 'marineford', name: 'Machineford', subtitle: 'LOCAL INFERENCE HEADQUARTERS', x: 14, z: -4.2, radius: 2.5, harborFacing: 'west' },
  { id: 'wano', name: 'Wano Weights', subtitle: 'LAND OF OPEN WEIGHTS', x: 19, z: 14.5, radius: 3.2, harborFacing: 'west' },
  { id: 'whole-cake', name: 'Whole Cache', subtitle: 'SWEET TOKENS, FRESHLY CACHED', x: 26, z: -8, radius: 2.6, harborFacing: 'north' },
  { id: 'laugh-tale', name: 'LoRA Tale', subtitle: 'THE LAST TOKEN IS A TREASURE', x: 28, z: 4.5, radius: 1.2, harborFacing: 'west' },
  { id: 'jaya', name: 'JAXa', subtitle: 'WHERE IDEAS COMPILE', x: -6.6, z: -21.5, radius: 1.6, harborFacing: 'north' },
  { id: 'elbaf', name: 'Elbatch', subtitle: 'GIANT CONTEXT. GREATER ADVENTURES.', x: 0.5, z: 24, radius: 3.5, harborFacing: 'south' },
  { id: 'egghead', name: 'Egghead', subtitle: 'TOMORROW IS ALREADY RUNNING', x: 12, z: -22, radius: 3.0, harborFacing: 'north' },
] as const;

/** These four near-bank landmarks face across the channel. Their docks,
 * navigation obstacles and work plazas already face inward and stay fixed. */
export function islandArtworkRotation(id: string): number {
  return ['little-garden', 'alabasta', 'sabaody', 'elbaf'].includes(id) ? Math.PI : 0;
}

export const GRAND_LINE_ISLAND_MODELS: Record<typeof GRAND_LINE_LANDMARKS[number]['id'], SceneryAssetType> = {
  'twin-cape': 'island_twin_cape', 'little-garden': 'island_little_garden', drum: 'island_drum',
  alabasta: 'island_alabasta', 'water-seven': 'island_water_seven', 'enies-lobby': 'island_enies_lobby',
  sabaody: 'island_sabaody', marineford: 'island_marineford', wano: 'island_wano',
  'whole-cake': 'island_whole_cake', 'laugh-tale': 'island_laugh_tale', jaya: 'island_jaya',
  elbaf: 'island_elbaf', egghead: 'island_egghead',
};
const HARBOR_DIRECTIONS = { north: { x: 0, z: 1 }, south: { x: 0, z: -1 }, east: { x: 1, z: 0 }, west: { x: -1, z: 0 } } as const;
export const GRAND_LINE_HARBORS = GRAND_LINE_LANDMARKS.map(landmark => {
  const direction = HARBOR_DIRECTIONS[landmark.harborFacing];
  return {
    id: landmark.id, name: landmark.name,
    x: Number((landmark.x + direction.x * (landmark.radius + 2.35)).toFixed(4)),
    z: Number((landmark.z + direction.z * (landmark.radius + 2.35)).toFixed(4)),
    rotation: Math.atan2(-direction.x, -direction.z) || 0, direction,
  };
});

/** Flat shore work plazas provide verified footing clear of island buildings. */
export const GRAND_LINE_CREW_PLAZAS = GRAND_LINE_LANDMARKS.map((landmark, index) => {
  const direction = GRAND_LINE_HARBORS[index].direction;
  const shoreDistance = landmark.radius * (direction.x ? 1 : 0.80);
  const distance = shoreDistance + (landmark.id === 'water-seven' ? 0.15 : -0.10);
  return {
    x: landmark.x + direction.x * distance, z: landmark.z + direction.z * distance,
    y: landmark.id === 'water-seven' ? 1.07 : landmark.id === 'marineford' ? 1.10 : 0.69,
    rotation: Math.atan2(direction.x, direction.z), width: 1.50, depth: 0.82,
  };
});
// A sector still owns twelve homes. The two new destinations are visitable
// harbors, so existing captains keep the same islands and native assignments.
export const GRAND_LINE_HOME_NAMES: readonly string[] = GRAND_LINE_HARBORS.slice(0, 12).map(harbor => harbor.name);
export const GRAND_LINE_STATIONS: readonly Placement[] = GRAND_LINE_HARBORS.slice(0, 12).map(({ x, z, rotation }) => ({ x, z, rotation }));
export const GRAND_LINE_LABOON_POSITION = { x: GRAND_LINE_LANDMARKS[0].x - 1.38, z: GRAND_LINE_LANDMARKS[0].z - 4.96 };
export const GRAND_LINE_SEA_KING_POSITIONS = [{ x: -16.56, z: -25 }, { x: 16.56, z: 25.2 }] as const;
export const GRAND_LINE_OBSTACLES: readonly CircleObstacle[] = [
  ...GRAND_LINE_LANDMARKS.map(({ x, z, radius }) => ({ x, z, radius: radius + 0.18 })),
  { ...GRAND_LINE_LABOON_POSITION, radius: 1.05 },
  ...GRAND_LINE_SEA_KING_POSITIONS.map(position => ({ ...position, radius: 1.3 })),
  ...[-1, 1].flatMap(sign => Array.from({ length: 15 }, (_, index) => ({ x: -29, z: sign * (6.3 + index * 2.5), radius: 2.5 }))),
];
export const GRAND_LINE_WANDER_POINTS: readonly Point[] = [
  ...GRAND_LINE_HARBORS.flatMap(harbor => {
    const offshore = harbor.rotation + Math.PI;
    return [-0.7, 0, 0.7].map(offset => ({
      x: harbor.x + Math.sin(offshore + offset) * 3.2,
      z: harbor.z + Math.cos(offshore + offset) * 3.2,
    }));
  }),
  ...GRAND_LINE_HARBORS.slice(12).map(({ x, z }) => ({ x, z })),
].filter(point => Math.hypot(point.x, point.z) < 32.57 && GRAND_LINE_OBSTACLES.every(obstacle =>
  Math.hypot(point.x - obstacle.x, point.z - obstacle.z) > obstacle.radius + 1.41));
