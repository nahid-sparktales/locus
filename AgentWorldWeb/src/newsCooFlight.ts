export type NewsCooPose = { visible: boolean; x: number; y: number; z: number; heading: number; bank: number; flap: number };
const hidden: NewsCooPose = { visible: false, x: 0, y: 0, z: 0, heading: 0, bank: 0, flap: 0 };

/** Short, occasional flock visits; no link to real mail or agent activity. */
export function newsCooFlight(elapsed: number, bird: number, ocean: boolean, reducedMotion: boolean): NewsCooPose {
  if (reducedMotion || !Number.isFinite(elapsed) || elapsed < 10 || !Number.isInteger(bird) || bird < 0 || bird >= 3) return { ...hidden };
  const cycle = Math.floor((elapsed - 10) / 68);
  const local = (elapsed - 10) % 68 - bird * 1.45;
  const duration = 24;
  if (local < 0 || local > duration) return { ...hidden };
  const t = local / duration, sign = cycle % 2 ? -1 : 1;
  const span = ocean ? 43 : 22;
  const sweep = t * Math.PI * 1.4 + cycle * 0.75;
  const lane = ocean ? 4 : 1;
  const spread = ocean ? 7.0 : 3.4;
  const dx = sign * span * 2 / duration;
  const dz = Math.cos(sweep) * spread * Math.PI * 1.4 / duration;
  const glide = Math.sin(local * 0.52 + bird) > 0.18;
  return {
    visible: true, x: sign * (t * 2 - 1) * span,
    y: (ocean ? 8.4 : 6.2) + Math.sin(local * 0.36 + bird * 0.4) * 0.65 + bird * 0.30,
    z: lane + Math.sin(sweep) * spread + (bird === 1 ? 1.9 : bird === 2 ? -1.8 : 0),
    heading: Math.atan2(dx, dz), bank: -Math.sin(sweep) * sign * 0.12,
    flap: glide ? -0.10 + Math.sin(local * 1.3) * 0.035 : Math.sin(local * 7.8 + bird * 0.8) * 0.40,
  };
}
