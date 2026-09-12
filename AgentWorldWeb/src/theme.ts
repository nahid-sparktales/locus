import { safeThemeID } from './state.ts';
import type { Point } from './state.ts';

export const RESIDENT_ASSET_TYPES = ['resident', 'resident_explorer', 'resident_botanist', 'resident_engineer'] as const;
export type ResidentAssetType = typeof RESIDENT_ASSET_TYPES[number];
export const PROP_ASSET_TYPES = ['beacon', 'habitat', 'crates', 'planter', 'lounge', 'server'] as const;
export type PropAssetType = typeof PROP_ASSET_TYPES[number];
export const ASSET_TYPES = [...RESIDENT_ASSET_TYPES, 'station', ...PROP_ASSET_TYPES] as const;
export type AssetType = typeof ASSET_TYPES[number];
export type Placement = Point & { rotation?: number };
export type CircleObstacle = Point & { radius: number };
export type PropPlacement = Placement & { asset: PropAssetType; radius?: number };
export type ThemeLayout = { radius: number; stations: Placement[]; props: PropPlacement[]; obstacles: CircleObstacle[]; wanderPoints: Point[] };
export type Theme = {
  version: 1;
  id: string;
  name: string;
  description: string;
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
  version: 1, id: 'outpost', name: 'Orbital Outpost', description: 'A living campus for your agents.',
  assets: {},
  heights: { resident: 1.8, resident_explorer: 1.8, resident_botanist: 1.8, resident_engineer: 1.8, station: 1.25, beacon: 3.5, habitat: 4, crates: 1.2, planter: 1.15, lounge: 0.9, server: 1.9 },
  rotations: {}, palette: { ground: '#647978', accent: '#7ce8d0', sky: '#132b37' },
  layout: campusLayout(),
};

export function safeAssetPath(value: unknown): value is string {
  return typeof value === 'string' && /^assets\/[a-zA-Z0-9_./-]+\.glb$/.test(value) && !value.split('/').some(segment => segment === '..' || segment === '.') && !value.includes('//');
}
function placement(p: unknown): p is Placement {
  return !!p && typeof p === 'object' && typeof (p as Placement).x === 'number' && Number.isFinite((p as Placement).x) && Math.abs((p as Placement).x) <= 30
    && typeof (p as Placement).z === 'number' && Number.isFinite((p as Placement).z) && Math.abs((p as Placement).z) <= 30
    && ((p as Placement).rotation === undefined || (typeof (p as Placement).rotation === 'number' && Number.isFinite((p as Placement).rotation)));
}
const boundedRadius = (value: unknown): value is number => typeof value === 'number' && Number.isFinite(value) && value >= 0.2 && value <= 8;
export function parseTheme(input: unknown): Theme {
  if (!input || typeof input !== 'object') return DEFAULT_THEME;
  const value = input as Record<string, unknown>;
  if (value.version !== 1 || !safeThemeID(value.id)) return DEFAULT_THEME;
  const result: Theme = { ...DEFAULT_THEME, assets: {}, heights: { ...DEFAULT_THEME.heights }, rotations: {}, palette: { ...DEFAULT_THEME.palette }, layout: campusLayout() };
  result.id = value.id;
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
    if (typeof layout.radius === 'number' && Number.isFinite(layout.radius) && layout.radius >= 10 && layout.radius <= 24) result.layout = campusLayout(layout.radius);
    if (Array.isArray(layout.stations) && layout.stations.length <= 12 && layout.stations.every(p => placement(p) && Math.hypot(p.x, p.z) < result.layout.radius - 1)) {
      result.layout.stations = layout.stations.map(p => ({ x: p.x, z: p.z, ...(p.rotation === undefined ? {} : { rotation: p.rotation }) }));
    }
    if (Array.isArray(layout.props) && layout.props.length <= 32 && layout.props.every(p => placement(p) && PROP_ASSET_TYPES.includes((p as PropPlacement).asset) && ((p as PropPlacement).radius === undefined || boundedRadius((p as PropPlacement).radius)))) {
      result.layout.props = layout.props.map(p => ({ asset: p.asset, x: p.x, z: p.z, ...(p.rotation === undefined ? {} : { rotation: p.rotation }), ...(p.radius === undefined ? {} : { radius: p.radius }) }));
    }
    if (Array.isArray(layout.obstacles) && layout.obstacles.length <= 32 && layout.obstacles.every(p => placement(p) && boundedRadius((p as CircleObstacle).radius))) {
      result.layout.obstacles = layout.obstacles.map(p => ({ x: p.x, z: p.z, radius: p.radius }));
    }
    if (Array.isArray(layout.wanderPoints) && layout.wanderPoints.length <= 64 && layout.wanderPoints.every(p => placement(p) && Math.hypot(p.x, p.z) < result.layout.radius - 0.5)) {
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
