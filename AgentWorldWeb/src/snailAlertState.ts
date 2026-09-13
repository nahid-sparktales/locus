import type { AttentionRequest } from './state.ts';

/** Keep the chosen native request across reorders; never manufacture an alert from status. */
export function selectAttentionRequest(requests: readonly AttentionRequest[], currentID?: string, offset = 0): AttentionRequest | undefined {
  if (!requests.length) return undefined;
  const retained = currentID ? requests.findIndex(request => request.id.toLowerCase() === currentID.toLowerCase()) : -1;
  const start = retained < 0 ? 0 : retained;
  const step = Number.isFinite(offset) ? Math.trunc(offset) : 0;
  return requests[((start + step) % requests.length + requests.length) % requests.length];
}
