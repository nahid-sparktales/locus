const MAX_MODEL_BYTES = 64 * 1024 * 1024;

/** Gzip is a lossless package container; embedded geometry and images are intact. */
export async function decompressModel(bytes: Uint8Array): Promise<Uint8Array> {
  // Some HTTP hosts transparently decode Content-Encoding: gzip.
  if (bytes[0] === 0x67 && bytes[1] === 0x6c && bytes[2] === 0x54 && bytes[3] === 0x46) return validateGLB(bytes);
  if (bytes[0] !== 0x1f || bytes[1] !== 0x8b) throw new Error('Invalid compressed model');
  const stream = new Blob([bytes as Uint8Array<ArrayBuffer>]).stream().pipeThrough(new DecompressionStream('gzip'));
  const reader = stream.getReader(), chunks: Uint8Array[] = [];
  let length = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > MAX_MODEL_BYTES) throw new Error('Model exceeds supported size');
      chunks.push(value);
    }
  } finally { await reader.cancel(); reader.releaseLock(); }
  const result = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) { result.set(chunk, offset); offset += chunk.byteLength; }
  return validateGLB(result);
}

function validateGLB(bytes: Uint8Array): Uint8Array {
  if (bytes.length < 20 || bytes.length > MAX_MODEL_BYTES) throw new Error('Invalid model size');
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (view.getUint32(0, true) !== 0x46546c67 || view.getUint32(4, true) !== 2 || view.getUint32(8, true) !== bytes.length) throw new Error('Invalid GLB model');
  return bytes;
}

export async function fetchCompressedModel(url: string, signal?: AbortSignal): Promise<Uint8Array> {
  const response = await fetch(url, { signal });
  if (!response.ok) throw new Error(`Model request failed (${response.status})`);
  const bytes = new Uint8Array(await response.arrayBuffer());
  if (bytes.length > MAX_MODEL_BYTES) throw new Error('Model exceeds supported size');
  return decompressModel(bytes);
}
