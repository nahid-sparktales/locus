import { safeThemeID } from './state.ts';
import type { Point } from './state.ts';

export const HUMANOID_ASSET_TYPES = ['resident', 'resident_explorer', 'resident_botanist', 'resident_engineer'] as const;
export const DEFAULT_SHIP_ASSET_TYPES = ['ship_thousand_sunny', 'ship_going_merry', 'ship_baratie', 'ship_navy_h03', 'ship_polar_tang', 'ship_spade_pirates', 'ship_red_force', 'ship_moby_dick', 'ship_perfume_yuda', 'ship_oro_jackson', 'ship_queen_mama_chanter', 'ship_dragons_ship'] as const;
export const SHIP_ASSET_TYPES = [...DEFAULT_SHIP_ASSET_TYPES, 'ship_mihawk_coffin', 'ship_garp_battleship', 'ship_marine_patrol'] as const;
export type ShipAssetType = typeof SHIP_ASSET_TYPES[number];
/** Visually calibrated against the packaged GLBs: after Babylon's glTF
 * handedness conversion, each bow points along +X. Residents move along +Z.
 * Keep this explicit so a new model requires its own facing calibration. */
export const SHIP_MODEL_ROTATIONS: Readonly<Record<ShipAssetType, number>> = {
  ship_thousand_sunny: -Math.PI / 2, ship_going_merry: -Math.PI / 2, ship_baratie: -Math.PI / 2,
  ship_navy_h03: -Math.PI / 2, ship_polar_tang: -Math.PI / 2, ship_spade_pirates: -Math.PI / 2,
  ship_red_force: -Math.PI / 2, ship_moby_dick: -Math.PI / 2, ship_perfume_yuda: -Math.PI / 2,
  ship_oro_jackson: -Math.PI / 2, ship_queen_mama_chanter: -Math.PI / 2, ship_dragons_ship: -Math.PI / 2,
  ship_mihawk_coffin: -Math.PI / 2, ship_garp_battleship: -Math.PI / 2, ship_marine_patrol: -Math.PI / 2,
};
export const SHIP_NAMES: Record<ShipAssetType, string> = {
  ship_thousand_sunny: 'Thousand Funny', ship_going_merry: 'Going Sherry', ship_baratie: 'BaratAI',
  ship_navy_h03: 'Navy Q4', ship_polar_tang: 'Polar Tensor', ship_spade_pirates: "Spade Prompters’ Ship",
  ship_red_force: 'Thread Force', ship_moby_dick: 'Moby Disk', ship_perfume_yuda: 'Perfume CUDA',
  ship_oro_jackson: 'Oro JSON', ship_queen_mama_chanter: 'Queen Llama Chanter', ship_dragons_ship: "Dragon’s Chip",
  ship_mihawk_coffin: "Mihawk’s Coffin Boat", ship_garp_battleship: "Garp’s Battleship", ship_marine_patrol: 'Marine Patrol',
};
export const RESIDENT_ASSET_TYPES = [...HUMANOID_ASSET_TYPES, ...SHIP_ASSET_TYPES] as const;
export type ResidentAssetType = typeof RESIDENT_ASSET_TYPES[number];
export const PROP_ASSET_TYPES = ['beacon', 'habitat', 'crates', 'planter', 'lounge', 'server'] as const;
export type PropAssetType = typeof PROP_ASSET_TYPES[number];
export const SCENERY_ASSET_TYPES = ['island_twin_cape', 'island_little_garden', 'island_drum', 'island_alabasta', 'island_water_seven', 'island_enies_lobby', 'island_sabaody', 'island_marineford', 'island_wano', 'island_whole_cake', 'island_laugh_tale', 'island_jaya', 'island_skypiea', 'scenery_red_line', 'scenery_reverse_mountain', 'creature_laboon', 'creature_sea_king', 'island_elbaf', 'island_egghead', 'island_mary_geoise', 'island_impel_down', 'island_amazon_lily', 'island_sabaody_archipelago', 'creature_zunesha', 'creature_momonosuke', 'island_dressrosa', 'island_punk_hazard', 'island_hachinosu', 'island_long_ring_long_land'] as const;
export type SceneryAssetType = typeof SCENERY_ASSET_TYPES[number];
export const ASSET_TYPES = [...RESIDENT_ASSET_TYPES, 'station', ...PROP_ASSET_TYPES, ...SCENERY_ASSET_TYPES] as const;
export type AssetType = typeof ASSET_TYPES[number];
export type Placement = Point & { rotation?: number };
export type CircleObstacle = Point & { radius: number };
export type PropPlacement = Placement & { asset: PropAssetType; radius?: number };
export type SailingBounds = { minZ: number; maxZ: number };
export type ThemeLayout = { sailingBounds?: SailingBounds; radius: number; stations: Placement[]; props: PropPlacement[]; obstacles: CircleObstacle[]; wanderPoints: Point[] };
export type Theme = {
  version: 1;
  id: string;
  name: string;
  description: string;
  environment: 'campus' | 'ocean';
  assets: Partial<Record<AssetType, string>>;
  heights: Record<AssetType, number>;
  rotations: Partial<Record<AssetType, number>>;
  palette: { ground: string; accent: string; sky: string };
  layout: ThemeLayout;
};

/** Shared geometry keeps rendered workstations and autonomous routes aligned. */
export const DEFAULT_STATIONS: readonly Placement[] = [
  { x: -1.5, z: -10, rotation: Math.PI }, { x: -9.5, z: -3, rotation: -Math.PI / 2 }, { x: 9.5, z: -3, rotation: Math.PI / 2 },
  { x: 1.5, z: -10, rotation: Math.PI }, { x: -9.5, z: 1, rotation: -Math.PI / 2 }, { x: 9.5, z: 1, rotation: Math.PI / 2 },
  { x: -4.5, z: -10, rotation: Math.PI }, { x: -9.5, z: -5.5, rotation: -Math.PI / 2 }, { x: 9.5, z: -5.5, rotation: Math.PI / 2 },
  { x: 4.5, z: -10, rotation: Math.PI }, { x: -9.5, z: 3.5, rotation: -Math.PI / 2 }, { x: 9.5, z: 3.5, rotation: Math.PI / 2 },
];
export const DEFAULT_WANDER_POINTS: readonly Point[] = Array.from({ length: 16 }, (_, index) => {
  const angle = index * Math.PI * 2 / 16;
  return { x: Math.sin(angle) * 6.7, z: Math.cos(angle) * 6.7 };
});
export const PROP_OBSTACLE_RADII: Record<PropAssetType, number> = { habitat: 2.2, lounge: 1.9, planter: 1.15, server: 0.75, beacon: 0.8, crates: 0.8 };

export function campusLayout(radius = 14.1): ThemeLayout {
  const scale = radius / 14.1;
  const scaled = <T extends Placement>(point: T): T => ({ ...point, x: point.x * scale, z: point.z * scale });
  return {
    radius,
    stations: DEFAULT_STATIONS.map(scaled),
    props: ([
      { asset: 'habitat', x: -10, z: -10.5, rotation: 0.35 },
      { asset: 'habitat', x: 10, z: -10.5, rotation: -0.35 },
      { asset: 'lounge', x: -5, z: 9, rotation: 0.45 },
      { asset: 'lounge', x: 5, z: 9, rotation: -0.45 },
      { asset: 'planter', x: -11.5, z: 5.5 },
      { asset: 'planter', x: 11.5, z: 5.5 },
      { asset: 'server', x: -6.8, z: -11.5, rotation: Math.PI },
      { asset: 'server', x: 6.8, z: -11.5, rotation: Math.PI },
      { asset: 'beacon', x: 0, z: -12.5 },
    ] satisfies PropPlacement[]).map(scaled),
    obstacles: [{ x: 0, z: 0, radius: 4.8 * scale }],
    wanderPoints: DEFAULT_WANDER_POINTS.map(scaled),
  };
}

export const DEFAULT_THEME: Theme = {
  version: 1, id: 'outpost', name: 'Orbital Locus Outpost', description: 'A living campus for your agents.', environment: 'campus',
  assets: {},
  heights: { resident: 1.8, resident_explorer: 1.8, resident_botanist: 1.8, resident_engineer: 1.8, station: 1.25, beacon: 3.5, habitat: 4, crates: 1.2, planter: 1.15, lounge: 0.9, server: 1.9,
    ship_thousand_sunny: 3.2, ship_going_merry: 2.9, ship_baratie: 3.2, ship_navy_h03: 3.1, ship_polar_tang: 2.1, ship_spade_pirates: 3.2, ship_red_force: 3.4, ship_moby_dick: 3.3, ship_perfume_yuda: 3.2, ship_oro_jackson: 3.4, ship_queen_mama_chanter: 3.5, ship_dragons_ship: 3.3,
    ship_mihawk_coffin: 2.7, ship_garp_battleship: 3.4, ship_marine_patrol: 3.0,
    island_twin_cape: 4.8, island_little_garden: 4.5, island_drum: 6, island_alabasta: 4.2,
    island_water_seven: 4.4, island_enies_lobby: 4.6, island_sabaody: 5.5, island_marineford: 4.7,
    island_wano: 5, island_whole_cake: 5, island_laugh_tale: 3.2, island_jaya: 3.6, island_skypiea: 4.4, scenery_red_line: 7, scenery_reverse_mountain: 8, creature_laboon: 1.8, creature_sea_king: 3.4, island_elbaf: 7.5, island_egghead: 5, island_mary_geoise: 5, island_impel_down: 3.6, island_amazon_lily: 5.5, island_sabaody_archipelago: 6, creature_zunesha: 8, creature_momonosuke: 2, island_dressrosa: 5, island_punk_hazard: 3.6, island_hachinosu: 4.5, island_long_ring_long_land: 1.7 },
  rotations: { ...SHIP_MODEL_ROTATIONS }, palette: { ground: '#46613E', accent: '#C9F54A', sky: '#171713' },
  layout: campusLayout(),
};

export function safeAssetPath(value: unknown): value is string {
  return typeof value === 'string' && /^assets\/[a-zA-Z0-9_./-]+\.glb(?:\.gz)?$/.test(value) && !value.split('/').some(segment => segment === '..' || segment === '.') && !value.includes('//');
}
function placement(p: unknown, limit = 48): p is Placement {
  return !!p && typeof p === 'object' && typeof (p as Placement).x === 'number' && Number.isFinite((p as Placement).x) && Math.abs((p as Placement).x) <= limit
    && typeof (p as Placement).z === 'number' && Number.isFinite((p as Placement).z) && Math.abs((p as Placement).z) <= limit
    && ((p as Placement).rotation === undefined || (typeof (p as Placement).rotation === 'number' && Number.isFinite((p as Placement).rotation)));
}
const boundedRadius = (value: unknown): value is number => typeof value === 'number' && Number.isFinite(value) && value >= 0.2 && value <= 8;
export function parseTheme(input: unknown): Theme {
  if (!input || typeof input !== 'object') return DEFAULT_THEME;
  const value = input as Record<string, unknown>;
  if (value.version !== 1 || !safeThemeID(value.id)) return DEFAULT_THEME;
  const result: Theme = { ...DEFAULT_THEME, assets: {}, heights: { ...DEFAULT_THEME.heights }, rotations: { ...SHIP_MODEL_ROTATIONS }, palette: { ...DEFAULT_THEME.palette }, layout: campusLayout() };
  result.id = value.id;
  result.environment = value.environment === 'ocean' ? 'ocean' : 'campus';
  if (typeof value.name === 'string' && value.name.length <= 100) result.name = value.name;
  if (typeof value.description === 'string' && value.description.length <= 500) result.description = value.description;
  for (const type of ASSET_TYPES) {
    const asset = (value.assets as Record<string, unknown> | undefined)?.[type];
    if (safeAssetPath(asset)) result.assets[type] = asset;
    const height = (value.heights as Record<string, unknown> | undefined)?.[type];
    if (boundedRadius(height)) result.heights[type] = height;
    const rotation = (value.rotations as Record<string, unknown> | undefined)?.[type];
    if (typeof rotation === 'number' && Number.isFinite(rotation)) result.rotations[type] = rotation;
  }
  for (const key of ['ground', 'accent', 'sky'] as const) {
    const color = (value.palette as Record<string, unknown> | undefined)?.[key];
    if (typeof color === 'string' && /^#[\da-f]{6}$/i.test(color)) result.palette[key] = color;
  }
  const layout = value.layout as Record<string, unknown> | undefined;
  if (layout && typeof layout === 'object') {
    const coordinateLimit = result.environment === 'ocean' ? 96 : 48;
    if (typeof layout.radius === 'number' && Number.isFinite(layout.radius) && layout.radius >= 10 && layout.radius <= (result.environment === 'ocean' ? 84 : 24)) result.layout = campusLayout(layout.radius);
    const bounds = layout.sailingBounds as Partial<SailingBounds> | undefined;
    if (result.environment === 'ocean' && bounds && typeof bounds.minZ === 'number' && typeof bounds.maxZ === 'number'
      && Number.isFinite(bounds.minZ) && Number.isFinite(bounds.maxZ) && bounds.minZ < bounds.maxZ - 4
      && bounds.minZ >= -result.layout.radius && bounds.maxZ <= result.layout.radius) {
      result.layout.sailingBounds = { minZ: bounds.minZ, maxZ: bounds.maxZ };
    }
    if (Array.isArray(layout.stations) && layout.stations.length <= 12 && layout.stations.every(p => placement(p, coordinateLimit) && Math.hypot(p.x, p.z) < result.layout.radius - 1)) {
      result.layout.stations = layout.stations.map(p => ({ x: p.x, z: p.z, ...(p.rotation === undefined ? {} : { rotation: p.rotation }) }));
    }
    if (Array.isArray(layout.props) && layout.props.length <= 32 && layout.props.every(p => placement(p, coordinateLimit) && PROP_ASSET_TYPES.includes((p as PropPlacement).asset) && ((p as PropPlacement).radius === undefined || boundedRadius((p as PropPlacement).radius)))) {
      result.layout.props = layout.props.map(p => ({ asset: p.asset, x: p.x, z: p.z, ...(p.rotation === undefined ? {} : { rotation: p.rotation }), ...(p.radius === undefined ? {} : { radius: p.radius }) }));
    }
    if (Array.isArray(layout.obstacles) && layout.obstacles.length <= (result.environment === 'ocean' ? 64 : 32) && layout.obstacles.every(p => placement(p, coordinateLimit) && boundedRadius((p as CircleObstacle).radius))) {
      result.layout.obstacles = layout.obstacles.map(p => ({ x: p.x, z: p.z, radius: p.radius }));
    }
    if (Array.isArray(layout.wanderPoints) && layout.wanderPoints.length <= 64 && layout.wanderPoints.every(p => placement(p, coordinateLimit) && Math.hypot(p.x, p.z) < result.layout.radius - 0.5)) {
      result.layout.wanderPoints = layout.wanderPoints.map(p => ({ x: p.x, z: p.z }));
    }
  }
  return result;
}

export type ThemeChoice = { id: string; name: string };
export function parseCatalog(input: unknown): ThemeChoice[] {
  if (!input || typeof input !== 'object') return [];
  const value = input as { version?: unknown; themes?: unknown };
  if (value.version !== 1 || !Array.isArray(value.themes) || value.themes.length > 50) return [];
  const ids = new Set<string>();
  return value.themes.filter((item): item is ThemeChoice => {
    if (!item || typeof item !== 'object' || !safeThemeID(item.id) || typeof item.name !== 'string' || item.name.length > 100 || ids.has(item.id)) return false;
    ids.add(item.id); return true;
  });
}
