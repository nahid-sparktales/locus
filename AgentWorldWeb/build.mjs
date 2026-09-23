import { build } from 'esbuild';
import { copyFile, mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.dirname(fileURLToPath(import.meta.url));
const output = path.resolve(root, '../plugins/agent-world/ui');
// Never empty the output: themes contain separately prepared production artwork.
await mkdir(path.join(output, 'static'), { recursive: true });
await build({
  entryPoints: [path.join(root, 'src/main.ts')],
  outfile: path.join(output, 'static/world.js'),
  bundle: true,
  format: 'iife',
  platform: 'browser',
  target: 'safari17',
  minify: true,
  legalComments: 'external',
  metafile: false,
});
await copyFile(path.join(root, 'index.html'), path.join(output, 'index.html'));
await copyFile(path.join(root, 'src/style.css'), path.join(output, 'static/world.css'));
await copyFile(path.join(root, 'assets/captain-deck-preview.webp'), path.join(output, 'static/captain-deck.webp'));
for (const island of ['elbaf', 'marineford', 'water-seven', 'wano', 'drum']) {
  await copyFile(path.join(root, `assets/quarters-${island}.webp`), path.join(output, `static/quarters-${island}.webp`));
}
console.log('Agent World built. Packaged themes preserved.');
