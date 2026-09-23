export type ShipLabelDetail = 'badge' | 'compact' | 'full';

/** Match detail to the ship's apparent size, including short preview windows.
 * Badges keep a fixed 36px click target even at the most distant overview. */
export function shipLabelDetail(radius: number, viewportHeight: number, fieldOfView: number): ShipLabelDetail {
  if (![radius, viewportHeight, fieldOfView].every(Number.isFinite) || radius <= 0 || viewportHeight <= 0 || fieldOfView <= 0 || fieldOfView >= Math.PI) return 'badge';
  const pixelsPerUnit = viewportHeight / (2 * radius * Math.tan(fieldOfView / 2));
  return pixelsPerUnit < 10 ? 'badge' : pixelsPerUnit < 18 ? 'compact' : 'full';
}

/** Labels describe ships in the viewport, never off-screen edge indicators. */
export function shipLabelOnScreen(x: number, y: number, depth: number, width: number, height: number): boolean {
  return [x, y, depth, width, height].every(Number.isFinite) && width > 0 && height > 0
    && depth > 0 && depth < 1 && x >= 0 && x <= width && y >= 0 && y <= height;
}
