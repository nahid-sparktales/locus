import type { CircleObstacle, Placement, SceneryAssetType } from './theme.ts';
import type { Point } from './state.ts';

/** Stable voyage order with irregular spacing. Array order preserves captain homes. */
export const RED_LINE_X = -29;
export const GRAND_LINE_MAP_RADIUS = 84;
export const GRAND_LINE_CALM_BELT = { inner: 20.8, solid: 23, fade: 25, outer: 27.2, center: 24 } as const;
export const GRAND_LINE_SAILING_BOUNDS = { minZ: -GRAND_LINE_CALM_BELT.inner, maxZ: GRAND_LINE_CALM_BELT.inner } as const;
export const MARY_GEOISE = { id: 'mary-geoise', name: 'Mary Geoise', subtitle: 'THE HOLY LAND ABOVE THE RED LINE', x: -30.4, z: -16, radius: 2.1, floor: 5.6 } as const;
export const GRAND_LINE_LANDMARKS = [
  { id: 'twin-cape', name: 'Twin Cache', subtitle: 'A FRESH CONTEXT WINDOW', x: -79, z: 8, radius: 1.8, harborFacing: 'south' },
  { id: 'little-garden', name: 'Little Gradient', subtitle: 'SMALL MODELS. BIG IDEAS.', x: -72, z: -3.5, radius: 2.0, harborFacing: 'south' },
  { id: 'drum', name: 'DRAM Island', subtitle: 'COLD STORAGE. WARM WELCOMES.', x: -67, z: 14, radius: 2.3, harborFacing: 'south' },
  { id: 'alabasta', name: 'Alabatcha', subtitle: 'BATCHES IN THE DUNES', x: -59, z: 0, radius: 3.2, harborFacing: 'south' },
  { id: 'water-seven', name: 'Water 7B', subtitle: 'SEVEN BILLION POSSIBILITIES', x: -43, z: 14.5, radius: 3.1, harborFacing: 'south' },
  { id: 'enies-lobby', name: 'Enies LoRA', subtitle: 'SMALL ADAPTERS. BIG ADVENTURES.', x: -65, z: -12, radius: 1.7, harborFacing: 'north' },
  { id: 'sabaody', name: 'Sabaudio', subtitle: 'WHERE EVERY VOICE HAS A HOME', x: -35, z: 6, radius: 2.8, harborFacing: 'west' },
  { id: 'marineford', name: 'Machineford', subtitle: 'LOCAL INFERENCE HEADQUARTERS', x: -33.5, z: -11.5, radius: 2.5, harborFacing: 'west' },
  { id: 'wano', name: 'Wano Weights', subtitle: 'LAND OF OPEN WEIGHTS', x: 9, z: 13, radius: 3.2, harborFacing: 'west' },
  { id: 'whole-cake', name: 'Whole Cache', subtitle: 'SWEET TOKENS, FRESHLY CACHED', x: -1, z: -4.5, radius: 2.6, harborFacing: 'north' },
  { id: 'laugh-tale', name: 'LoRA Tale', subtitle: 'THE LAST TOKEN IS A TREASURE', x: 46, z: 14, radius: 1.2, harborFacing: 'west' },
  { id: 'jaya', name: 'JAXa', subtitle: 'WHERE IDEAS COMPILE', x: -54, z: 12.5, radius: 1.6, harborFacing: 'east' },
  { id: 'elbaf', name: 'Elbatch', subtitle: 'GIANT CONTEXT. GREATER ADVENTURES.', x: 29, z: 5, radius: 3.5, harborFacing: 'south' },
  { id: 'egghead', name: 'Egghead', subtitle: 'TOMORROW IS ALREADY RUNNING', x: 20, z: -12, radius: 3.0, harborFacing: 'north' },
  { id: 'impel-down', name: 'Impel Down', subtitle: 'GREAT PRISON OF THE CALM BELT', x: -50, z: -23.8, radius: 2.1, harborFacing: 'north' },
  { id: 'amazon-lily', name: 'Amazon Lily', subtitle: 'ISLAND OF THE KUJA', x: -75, z: -24, radius: 2.8, harborFacing: 'north' },
  { id: 'dressrosa', name: 'Dressrosa', subtitle: 'THE KINGDOM OF FLOWERS', x: -11, z: 5.5, radius: 3.1, harborFacing: 'north' },
  { id: 'punk-hazard', name: 'Punk Hazard', subtitle: 'FIRE AND ICE', x: -19, z: -11, radius: 2.9, harborFacing: 'north' },
  { id: 'hachinosu', name: 'Hachinosu', subtitle: 'PIRATE ISLAND', x: 40, z: -6, radius: 2.8, harborFacing: 'north' },
  { id: 'long-ring-long-land', name: 'Long Ring Long Land', subtitle: 'A LONG WAY ROUND', x: -48, z: -3, radius: 2.5, harborFacing: 'north' },
] as const;

/** Generated island entrances face local +Z. Keep artwork, front docks,
 * work plazas and boarding planks aligned on the same outward bearing. */
export function islandArtworkRotation(id: string): number {
  const facing = GRAND_LINE_LANDMARKS.find(island => island.id === id)?.harborFacing;
  const bearing = facing === 'south' ? Math.PI : facing === 'east' ? Math.PI / 2 : facing === 'west' ? -Math.PI / 2 : 0;
  return bearing;
}

/** Front depth is identical after rotating the artwork toward any dock. The
 * timber overlaps the irregular land edge instead of beginning offshore. */
export const islandShoreDistance = (radius: number): number => radius * 0.72;
export const GRAND_LINE_SKY_ISLAND = { x: -54.024, y: 6, z: 11.99 } as const;
export const MARINEFORD_CURRENT = { x: -51, z: -12, radius: 4.2 } as const;

export const GRAND_LINE_ISLAND_MODELS: Record<typeof GRAND_LINE_LANDMARKS[number]['id'], SceneryAssetType> = {
  'twin-cape': 'island_twin_cape', 'little-garden': 'island_little_garden', drum: 'island_drum',
  alabasta: 'island_alabasta', 'water-seven': 'island_water_seven', 'enies-lobby': 'island_enies_lobby',
  sabaody: 'island_sabaody_archipelago', marineford: 'island_marineford', wano: 'island_wano',
  'whole-cake': 'island_whole_cake', 'laugh-tale': 'island_laugh_tale', jaya: 'island_jaya',
  elbaf: 'island_elbaf', egghead: 'island_egghead',
  'impel-down': 'island_impel_down', 'amazon-lily': 'island_amazon_lily',
  dressrosa: 'island_dressrosa', 'punk-hazard': 'island_punk_hazard', hachinosu: 'island_hachinosu',
  'long-ring-long-land': 'island_long_ring_long_land',
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
  const shoreDistance = islandShoreDistance(landmark.radius);
  const distance = shoreDistance + (landmark.id === 'water-seven' ? 0.15 : -0.10);
  return {
    x: landmark.x + direction.x * distance, z: landmark.z + direction.z * distance,
    y: landmark.id === 'water-seven' ? 1.07 : landmark.id === 'marineford' ? 1.10 : 0.69,
    rotation: Math.atan2(direction.x, direction.z), width: 1.50, depth: 0.82,
  };
});
// A sector still owns twelve homes. Additional destinations are visitable
// harbors, so existing captains keep the same islands and native assignments.
export const GRAND_LINE_HOME_NAMES: readonly string[] = GRAND_LINE_HARBORS.slice(0, 12).map(harbor => harbor.name);
export const GRAND_LINE_STATIONS: readonly Placement[] = GRAND_LINE_HARBORS.slice(0, 12).map(({ x, z, rotation }) => ({ x, z, rotation }));
export const GRAND_LINE_LABOON_POSITION = { x: GRAND_LINE_LANDMARKS[0].x - 3.8, z: GRAND_LINE_LANDMARKS[0].z + 1.5 };
export const GRAND_LINE_SEA_KING_POSITIONS = [{ x: -16.56, z: -25 }, { x: 16.56, z: 25.2 }] as const;
export const GRAND_LINE_OBSTACLES: readonly CircleObstacle[] = [
  ...GRAND_LINE_LANDMARKS.map(({ x, z, radius }) => ({ x, z, radius: radius + 0.18 })),
  { ...GRAND_LINE_LABOON_POSITION, radius: 1.05 },
  ...GRAND_LINE_SEA_KING_POSITIONS.map(position => ({ ...position, radius: 1.3 })),
  { x: MARY_GEOISE.x + 0.4, z: MARY_GEOISE.z, radius: 3.7 },
  ...[-1, 1].flatMap(sign => Array.from({ length: 15 }, (_, index) => ({ x: -29, z: sign * (6.3 + index * 2.5), radius: 2.5 }))),
];
export const GRAND_LINE_WANDER_POINTS: readonly Point[] = [
  ...GRAND_LINE_HARBORS.flatMap(harbor => {
    const offshore = harbor.rotation + Math.PI;
    return [-0.5, 0.5].map(offset => ({
      x: harbor.x + Math.sin(offshore + offset) * 3.2,
      z: harbor.z + Math.cos(offshore + offset) * 3.2,
    }));
  }),
  ...GRAND_LINE_HARBORS.slice(12).map(({ x, z }) => ({ x, z })),
].filter(point => Math.abs(point.z) < GRAND_LINE_CALM_BELT.inner - 1.43 && Math.hypot(point.x, point.z) < GRAND_LINE_MAP_RADIUS - 1.43 && GRAND_LINE_OBSTACLES.every(obstacle =>
  Math.hypot(point.x - obstacle.x, point.z - obstacle.z) > obstacle.radius + 1.41));
