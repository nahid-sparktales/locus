import type { AgentStatus } from './state.ts';
import type { Placement } from './theme.ts';
import type { ResidentMotion } from './residentMotion.ts';

/** Home rotation is the approach bearing; a docked ship lies parallel to shore. */
export function shipBerthHeading(home: Placement): number {
  const heading = (home.rotation ?? 0) + Math.PI / 2;
  return Math.atan2(Math.sin(heading), Math.cos(heading));
}
export function islandCrewActivity(status: AgentStatus, motion: ResidentMotion, home: Placement): 'working' | 'waiting' | undefined {
  if (!['working', 'queued', 'needs_attention', 'failed'].includes(status)) return undefined;
  if (motion.walking || motion.intent !== 'station' || motion.phase !== 'at_station' || Math.hypot(motion.x - home.x, motion.z - home.z) > 0.08) return undefined;
  const difference = Math.atan2(Math.sin(motion.heading - shipBerthHeading(home)), Math.cos(motion.heading - shipBerthHeading(home)));
  if (Math.abs(difference) > 0.06) return undefined;
  return status === 'working' ? 'working' : 'waiting';
}
