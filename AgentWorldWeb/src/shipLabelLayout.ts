import type { ScreenRect } from './state.ts';

const overlaps = (a: ScreenRect, b: ScreenRect) => a.left < b.right + 6 && a.right > b.left - 6 && a.top < b.bottom + 6 && a.bottom > b.top - 6;

/** Keep cards at a readable CSS size, move them clear of controls and other
 * cards, and pin off-screen ships to an edge instead of dropping their labels. */
export function placeShipLabel(anchorX: number, anchorY: number, width: number, height: number,
  viewportWidth: number, viewportHeight: number, occupied: readonly ScreenRect[]): ScreenRect {
  const margin = 12;
  const fit = (x: number, y: number): ScreenRect => {
    const left = Math.max(margin, Math.min(viewportWidth - width - margin, x - width / 2));
    const top = Math.max(margin, Math.min(viewportHeight - height - margin, y - height));
    return { left, top, right: left + width, bottom: top + height };
  };
  const preferred = fit(Number.isFinite(anchorX) ? anchorX : viewportWidth / 2, Number.isFinite(anchorY) ? anchorY : viewportHeight / 2);
  if (occupied.every(other => !overlaps(preferred, other))) return preferred;
  // Search nearest clear slots in a stable order. Even a tiny crowded window
  // retains every card; visibility never depends on zoom or activity status.
  const choices: ScreenRect[] = [];
  for (let y = margin; y <= viewportHeight - height - margin; y += height + 8) {
    for (let x = margin; x <= viewportWidth - width - margin; x += width + 8) {
      choices.push({ left: x, top: y, right: x + width, bottom: y + height });
    }
  }
  choices.sort((a, b) => Math.hypot(a.left - preferred.left, a.top - preferred.top) - Math.hypot(b.left - preferred.left, b.top - preferred.top));
  return choices.find(rect => occupied.every(other => !overlaps(rect, other))) ?? preferred;
}
