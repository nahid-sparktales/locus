/** Stable map IDs shared with the native island-quarters bridge. */
export const ISLAND_QUARTERS = {
  elbaf: { name: 'Elbaf', subtitle: 'Beneath the great tree', artwork: 'elbaf', paper: '#172d23', panel: '#233d2e', raised: '#36513b', line: '#6d8154', ink: '#f4f1d9', muted: '#c1d0b1', accent: '#e4c27d' },
  marineford: { name: 'Marineford', subtitle: 'At the heart of the stronghold', artwork: 'marineford', paper: '#182b42', panel: '#243d59', raised: '#365372', line: '#6988a4', ink: '#f0f5fc', muted: '#bdd0e2', accent: '#c6deef' },
  'water-seven': { name: 'Water 7', subtitle: 'Above the city of canals', artwork: 'water-seven', paper: '#133437', panel: '#204a4c', raised: '#326568', line: '#639e99', ink: '#ecf6ed', muted: '#b8d9d1', accent: '#f3bf88' },
  wano: { name: 'Wano', subtitle: 'Among the cherry blossoms', artwork: 'wano', paper: '#302034', panel: '#462d47', raised: '#61405c', line: '#9b6e8b', ink: '#fff0ee', muted: '#dec1d0', accent: '#f3b5ce' },
  drum: { name: 'Drum Island', subtitle: 'A warm refuge in the snow', artwork: 'drum', paper: '#233248', panel: '#30465e', raised: '#435e79', line: '#819db4', ink: '#f2f8ff', muted: '#c9dceb', accent: '#bddff6' },
} as const;
export type QuartersIslandID = keyof typeof ISLAND_QUARTERS;
export function isQuartersIsland(value: unknown): value is QuartersIslandID {
  return typeof value === 'string' && Object.hasOwn(ISLAND_QUARTERS, value);
}
export function canOpenIslandQuarters(value: unknown, enabled: boolean, theme: string): value is QuartersIslandID {
  return enabled && theme === 'grand-line' && isQuartersIsland(value);
}
