import { safeThemeID } from './state.ts';

export const ASSET_TYPES = ['resident', 'player', 'station', 'beacon', 'habitat', 'crates'] as const;
export type AssetType = typeof ASSET_TYPES[number];
export type Placement = { x: number; z: number; rotation?: number };
export type PropPlacement = Placement & { asset: 'beacon' | 'habitat' | 'crates'; collisionRadius?: number };
export type Theme = {
  version: 1;
  id: string;
  name: string;
  description: string;
  assets: Partial<Record<AssetType, string>>;
  heights: Record<AssetType, number>;
  rotations: Partial<Record<AssetType, number>>;
  palette: { ground: string; accent: string; sky: string };
  layout: { radius: number; playerSpawn: Placement; stations: Placement[]; props: PropPlacement[] };
};
export const DEFAULT_THEME: Theme = {
  version: 1, id: 'outpost', name: 'Orbital Outpost', description: 'Your agents, among the stars.',
  assets: {}, heights: { resident: 1.7, player: 1.7, station: 1.25, beacon: 3.5, habitat: 4, crates: 1.2 }, rotations: {},
  palette: { ground: '#647978', accent: '#7ce8d0', sky: '#132b37' },
  layout: { radius: 14.1, playerSpawn: { x: 0, z: 5.5 }, stations: [], props: [
    { asset: 'habitat', x: -10.5, z: -11.8, rotation: 0.3, collisionRadius: 2 },
    { asset: 'habitat', x: 10.5, z: -11.8, rotation: -0.3, collisionRadius: 2 },
    { asset: 'beacon', x: 0, z: -13.8, collisionRadius: 0.8 },
    { asset: 'crates', x: -11.5, z: 8, rotation: -0.4, collisionRadius: 0.9 },
    { asset: 'crates', x: 11.5, z: 8, rotation: 0.6, collisionRadius: 0.9 },
  ] },
};
export function safeAssetPath(value: unknown): value is string {
  return typeof value === 'string' && /^assets\/[a-zA-Z0-9_./-]+\.glb$/.test(value) && !value.split('/').some(segment => segment === '..' || segment === '.') && !value.includes('//');
}
export function parseTheme(input: unknown): Theme {
  if (!input || typeof input !== 'object') return DEFAULT_THEME;
  const value = input as Record<string, unknown>;
  if (value.version !== 1 || !safeThemeID(value.id)) return DEFAULT_THEME;
  const result: Theme = { ...DEFAULT_THEME, assets: {}, heights: { ...DEFAULT_THEME.heights }, rotations: {}, palette: { ...DEFAULT_THEME.palette }, layout: { ...DEFAULT_THEME.layout, playerSpawn: { ...DEFAULT_THEME.layout.playerSpawn }, stations: [], props: [...DEFAULT_THEME.layout.props] } };
  result.id = value.id;
  if (typeof value.name === 'string' && value.name.length <= 100) result.name = value.name;
  if (typeof value.description === 'string' && value.description.length <= 500) result.description = value.description;
  for (const type of ASSET_TYPES) {
    const asset = (value.assets as Record<string, unknown> | undefined)?.[type];
    if (safeAssetPath(asset)) result.assets[type] = asset;
    const height = (value.heights as Record<string, unknown> | undefined)?.[type];
    if (typeof height === 'number' && Number.isFinite(height) && height >= 0.2 && height <= 8) result.heights[type] = height;
    const rotation = (value.rotations as Record<string, unknown> | undefined)?.[type];
    if (typeof rotation === 'number' && Number.isFinite(rotation)) result.rotations[type] = rotation;
  }
  for (const key of ['ground', 'accent', 'sky'] as const) {
    const color = (value.palette as Record<string, unknown> | undefined)?.[key];
    if (typeof color === 'string' && /^#[\da-f]{6}$/i.test(color)) result.palette[key] = color;
  }
  const layout = value.layout as Record<string, unknown> | undefined;
  if (layout && typeof layout === 'object') {
    if (typeof layout.radius === 'number' && Number.isFinite(layout.radius) && layout.radius >= 10 && layout.radius <= 24) result.layout.radius = layout.radius;
    const placement = (p: unknown): p is Placement => !!p && typeof p === 'object' && typeof (p as Placement).x === 'number' && Number.isFinite((p as Placement).x) && Math.abs((p as Placement).x) <= 30 && typeof (p as Placement).z === 'number' && Number.isFinite((p as Placement).z) && Math.abs((p as Placement).z) <= 30 && ((p as Placement).rotation === undefined || (typeof (p as Placement).rotation === 'number' && Number.isFinite((p as Placement).rotation)));
    if (placement(layout.playerSpawn) && Math.hypot(layout.playerSpawn.x, layout.playerSpawn.z) < result.layout.radius - 1) result.layout.playerSpawn = layout.playerSpawn;
    if (Array.isArray(layout.stations) && layout.stations.length <= 12 && layout.stations.every(p => placement(p) && Math.hypot(p.x, p.z) < result.layout.radius - 1)) result.layout.stations = layout.stations;
    if (Array.isArray(layout.props) && layout.props.length <= 32 && layout.props.every(p => placement(p) && ['beacon', 'habitat', 'crates'].includes((p as PropPlacement).asset) && ((p as PropPlacement).collisionRadius === undefined || (typeof (p as PropPlacement).collisionRadius === 'number' && Number.isFinite((p as PropPlacement).collisionRadius) && (p as PropPlacement).collisionRadius! >= 0 && (p as PropPlacement).collisionRadius! <= 4)))) result.layout.props = layout.props;
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
