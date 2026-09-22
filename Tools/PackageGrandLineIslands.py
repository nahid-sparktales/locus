#!/usr/bin/env python3
"""Package completed, approved local Meshy campaigns without making API calls.

Repeat --state-dir to package several campaigns together, or invoke it again as
another campaign finishes. Existing paid history is retained and cannot be
replaced with different task IDs. The normal package verifier requires all approved
campaigns; --require-complete applies that same final gate before writing.
--compact requires Pillow with WebP support. It preserves source artwork outside
the repository and does not alter runtime geometry or decoded texture pixels.
"""
from __future__ import annotations

import argparse
import copy
from concurrent.futures import ThreadPoolExecutor, as_completed
import io
import os
import hashlib
import gzip
import json
from pathlib import Path

from GenerateAgentWorldAssets import save
from VerifyAgentWorldPackage import (
    GRAND_LINE_CAMPAIGNS, GRAND_LINE_ASSET_NAMES, ISLAND_NAMES, SHIP_NAMES, geometry_digest, local_file, glb_payload,
    verify_glb, verify_grand_line_history, verify_public_provenance, verify_reference, verify_texture_encoding, verify_container_encoding,
)

PUBLIC_TASK_KEYS = (
    'asset', 'stage', 'reserved_credits', 'consumed_credits', 'id', 'ai_model', 'status', 'settings',
)


def read_campaign(private: Path, repo: Path, root: Path, published: dict, backup: Path) -> tuple[str, set[str], int, dict]:
    private = private.resolve()
    assert not private.is_relative_to(repo), 'Private task state must stay outside the repository'
    state = json.loads(local_file(private, 'ledger.json').read_text())
    assert state['version'] == 1 and type(state['approved_credits']) is int
    names = set(state['assets'])
    matches = [(name, expected, credits) for name, expected, credits in GRAND_LINE_CAMPAIGNS if names == expected]
    assert len(matches) == 1, 'The ledger must contain exactly one complete approved campaign'
    campaign, expected, credits = matches[0]
    assert state['approved_credits'] == credits, 'Credit approval does not match this campaign'
    assert names == set(state['references']) == expected, 'Missing retained reference or runtime asset'
    tasks = state['tasks']
    assert len(tasks) == len(expected) * 2 and len({task['id'] for task in tasks}) == len(tasks)
    assert all(task['status'] == 'SUCCEEDED' and task.get('downloaded') is True for task in tasks), 'Wait for every download to finish'
    assert all(type(task[key]) is int for task in tasks for key in ('reserved_credits', 'consumed_credits'))
    assert sum(task['reserved_credits'] for task in tasks) == sum(task['consumed_credits'] for task in tasks) == credits
    for name, asset in state['assets'].items():
        current = published.get('assets', {}).get(name, {})
        if current.get('texture_encoding') or current.get('container_encoding'):
            encoding = current.get('texture_encoding') or current['container_encoding']
            assert encoding['source_sha256'] == asset['sha256']
            source_root = backup / 'grand-line' if current.get('texture_encoding') else backup / 'grand-line/containers'
            assert hashlib.sha256(local_file(source_root, encoding['source_path']).read_bytes()).hexdigest() == asset['sha256']
            for key in ('source_sha256', 'source_bytes', 'source_task_id', 'reference_task_id', 'geometry_sha256'):
                assert current[key] == asset[key], f'Lossless packaging ancestry changed: {name}'
            state['assets'][name] = asset = copy.deepcopy(current)
        runtime = local_file(root, asset['path'])
        source = local_file(private, name + '.glb')
        stats = verify_glb(runtime, humanoid=False, ship=True)
        assert stats['sha256'] == asset['sha256'] and stats['bytes'] == asset['runtime_bytes'], f'Runtime asset mismatch: {name}'
        assert hashlib.sha256(source.read_bytes()).hexdigest() == asset['source_sha256'], f'Private source hash mismatch: {name}'
        assert source.stat().st_size == asset['source_bytes'] and asset['geometry_unchanged'] is True
        assert geometry_digest(source) == geometry_digest(runtime) == asset['geometry_sha256'], f'Geometry changed: {name}'
        reference = state['references'][name]
        current_reference = published.get('references', {}).get(name, {})
        if current_reference.get('encoding'):
            assert current_reference['source_sha256'] == reference['sha256'] and current_reference['task_id'] == reference['task_id']
            assert hashlib.sha256(local_file(backup / 'grand-line', current_reference['source_path']).read_bytes()).hexdigest() == reference['sha256']
            state['references'][name] = reference = copy.deepcopy(current_reference)
        verify_reference(root, reference)
        verify_texture_encoding(runtime, asset)
        verify_container_encoding(runtime, asset)
    return campaign, expected, credits, state


def package(state_dirs: list[Path], *, require_complete: bool = False, check_only: bool = False, backup: Path, write_manifest: bool = True) -> dict:
    repo = Path(__file__).resolve().parents[1]
    root = repo / 'plugins/agent-world/ui/themes/grand-line'
    manifest = json.loads(local_file(root, 'theme.json').read_text())
    provenance = json.loads(local_file(root, 'provenance.json').read_text())
    verify_public_provenance(provenance, theme_id='grand-line')
    assert set(manifest['assets']) <= GRAND_LINE_ASSET_NAMES, 'Unknown asset in the theme'
    # Renderer layout and packaging can be prepared independently. Validate the
    # existing published history against its own paths before merging campaigns.
    manifest['assets'] = {name: asset.get('path', manifest['assets'].get(name)) for name, asset in provenance['assets'].items()}
    verify_grand_line_history(manifest, provenance, require_complete=False)
    original_tasks = [task for task in provenance['tasks'] if task['asset'] in SHIP_NAMES]
    assert len(original_tasks) == 36, 'Preserve the original ship reference, model and upgrade history'
    original_ids = [task['id'] for task in original_tasks]
    incoming = [read_campaign(private, repo, root, provenance, backup) for private in state_dirs]
    assert len({campaign for campaign, _, _, _ in incoming}) == len(incoming), 'The same campaign was supplied more than once'
    for campaign, names, credits, state in incoming:
        previous = [task for task in provenance['tasks'] if task['asset'] in names]
        public_tasks = [{key: task[key] for key in PUBLIC_TASK_KEYS} for task in state['tasks']]
        if previous:
            assert {task['id'] for task in previous} == {task['id'] for task in public_tasks}, f'Refusing to discard paid history for {campaign}'
        provenance['tasks'] = [task for task in provenance['tasks'] if task['asset'] not in names] + public_tasks
        for name in sorted(names):
            manifest['assets'][name] = state['assets'][name]['path']
            provenance['assets'][name] = state['assets'][name]
            provenance['references'][name] = state['references'][name]
    present = [(campaign, names, credits) for campaign, names, credits in GRAND_LINE_CAMPAIGNS if names <= set(provenance['assets'])]
    # Preserve all 36 original records verbatim, then use one stable ordering for
    # completed campaigns so incremental and combined invocations are equivalent.
    new_tasks = [task for task in provenance['tasks'] if task['asset'] not in SHIP_NAMES]
    provenance['tasks'] = original_tasks + [
        task for _, names, _ in present
        for task in sorted((task for task in new_tasks if task['asset'] in names),
                           key=lambda task: (task['asset'], 0 if task['stage'] in ('reference', 'preview') else 1))
    ]
    assert [task['id'] for task in provenance['tasks'][:36]] == original_ids
    total = 648 + sum(credits for _, _, credits in present)
    provenance['reserved_credits'] = provenance['reported_credits'] = provenance['credit_ceiling'] = total
    provenance.pop('user_credit_ceiling_exclusive', None)
    provenance['campaigns'] = [
        {'name': 'ship_references_and_two_model_passes', 'reserved_credits': 648, 'reported_credits': 648},
        *[{'name': campaign, 'approved_credits': credits, 'reserved_credits': credits, 'reported_credits': credits}
          for campaign, _, credits in present],
    ]
    summaries = {}
    for campaign, names, _ in present:
        assets = [provenance['assets'][name] for name in sorted(names)]
        summaries[campaign] = {
            'geometry_unchanged': True, 'base_color_max_dimension': 2048, 'pbr_max_dimension': 1024,
            'runtime_bytes': sum(asset['runtime_bytes'] for asset in assets),
            'source_bytes': sum(asset['source_bytes'] for asset in assets),
        }
    provenance['campaign_packaging'] = summaries
    if ISLAND_NAMES <= set(provenance['assets']):
        provenance['island_packaging'] = summaries['islands_and_cliffs']
    verify_public_provenance(provenance, theme_id='grand-line')
    verify_grand_line_history(manifest, provenance, require_complete=require_complete)
    source = provenance['source_image']
    assert hashlib.sha256(local_file(root, source['path']).read_bytes()).hexdigest() == source['sha256']
    if not check_only:
        save(root / 'provenance.json', provenance)
        if write_manifest:
            save(root / 'theme.json', manifest)
    print(f"{'Validated' if check_only else 'Packaged'} {len(provenance['assets'])} models, "
          f"{len(provenance['tasks'])} paid tasks, {len(provenance['references'])} references; "
          f"{total} Local Line credits, {total + 209 + 44} all-theme lifetime credits.")
    return provenance



def private_backup(backup: Path, theme_id: str, relative: str, payload: bytes) -> None:
    target = backup / theme_id / relative
    assert not Path(relative).is_absolute() and target.resolve().is_relative_to(backup.resolve())
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        assert target.read_bytes() == payload, f'Existing source backup differs: {relative}'
    else:
        with target.open('xb') as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())


def atomic_bytes(path: Path, payload: bytes) -> None:
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_bytes(payload)
    temporary.replace(path)


def encode_reference(root: Path, theme_id: str, reference: dict, backup: Path) -> str | None:
    from PIL import Image
    if reference.get('encoding'):
        verify_reference(root, reference)
        source = local_file(backup / theme_id, reference['source_path'])
        assert hashlib.sha256(source.read_bytes()).hexdigest() == reference['source_sha256']
        return None
    path = local_file(root, reference['path'])
    if path.suffix.lower() != '.png':
        return None
    payload = path.read_bytes()
    assert hashlib.sha256(payload).hexdigest() == reference['sha256']
    original = Image.open(io.BytesIO(payload))
    # References are art-direction proofs, never runtime textures. Preserve their
    # dimensions and original PNGs while using high-quality JPEG in the package.
    if original.mode == 'RGBA' and original.getextrema()[3] != (255, 255):
        return None
    output = io.BytesIO()
    original.convert('RGB').save(output, format='JPEG', quality=94, subsampling=0, optimize=True)
    encoded = output.getvalue()
    if len(encoded) >= len(payload):
        return None
    private_backup(backup, theme_id, reference['path'], payload)
    old_relative = reference['path']
    target = path.with_suffix('.jpg')
    atomic_bytes(target, encoded)
    reference.update(source_path=old_relative, source_sha256=hashlib.sha256(payload).hexdigest(),
                     source_bytes=len(payload), path=target.relative_to(root).as_posix(),
                     sha256=hashlib.sha256(encoded).hexdigest(), bytes=len(encoded),
                     dimensions=list(original.size), encoding={'format': 'JPEG', 'quality': 94, 'subsampling': 0,
                     'dimensions_unchanged': True, 'purpose': 'reference_artwork'})
    verify_reference(root, reference)
    return old_relative


def encode_textures(root: Path, theme_id: str, relative: str, asset: dict, backup: Path) -> bool:
    from PIL import Image
    from OptimizeGrandLineAssets import parse_glb, pack_glb, view_bytes, geometry_digest as gltf_geometry
    path = local_file(root, relative)
    if asset.get('container_encoding'):
        verify_container_encoding(path, asset)
        verify_texture_encoding(path, asset)
        source = local_file(backup / theme_id / 'containers', asset['container_encoding']['source_path'])
        assert hashlib.sha256(source.read_bytes()).hexdigest() == asset['container_encoding']['source_sha256']
        return False
    if asset.get('texture_encoding'):
        verify_texture_encoding(path, asset)
        source = local_file(backup / theme_id, asset['texture_encoding']['source_path'])
        assert hashlib.sha256(source.read_bytes()).hexdigest() == asset['texture_encoding']['source_sha256']
        return False
    payload = path.read_bytes()
    assert hashlib.sha256(payload).hexdigest() == asset['sha256']
    original, binary = parse_glb(payload)
    gltf = copy.deepcopy(original)
    replacements, image_records, converted = {}, [], set()
    for index, image in enumerate(gltf['images']):
        encoded = view_bytes(original, binary, image['bufferView'])
        pixels = Image.open(io.BytesIO(encoded)).convert('RGBA')
        previous_mime = image['mimeType']
        original_bytes = len(encoded)
        if previous_mime == 'image/png':
            output = io.BytesIO()
            pixels.save(output, format='WEBP', lossless=True, quality=100, method=6, exact=True)
            candidate = output.getvalue()
            decoded = Image.open(io.BytesIO(candidate)).convert('RGBA')
            assert decoded.size == pixels.size and decoded.tobytes() == pixels.tobytes(), 'Lossless codec changed pixels'
            if len(candidate) < len(encoded):
                encoded = candidate
                replacements[image['bufferView']] = encoded
                image['mimeType'] = 'image/webp'
                converted.add(index)
        image_records.append({'index': index, 'dimensions': list(pixels.size),
                              'rgba_sha256': hashlib.sha256(pixels.tobytes()).hexdigest(),
                              'source_mime_type': previous_mime, 'mime_type': image['mimeType'],
                              'source_bytes': original_bytes, 'bytes': len(encoded),
                              'encoded_sha256': hashlib.sha256(encoded).hexdigest()})
    if not converted:
        return False
    for texture in gltf.get('textures', []):
        if texture.get('source') in converted:
            texture.setdefault('extensions', {})['EXT_texture_webp'] = {'source': texture.pop('source')}
    for key in ('extensionsUsed', 'extensionsRequired'):
        gltf[key] = sorted(set(gltf.get(key, [])) | {'EXT_texture_webp'})
    packed_binary = bytearray()
    for index, view in enumerate(gltf['bufferViews']):
        packed_binary.extend(b'\x00' * (-len(packed_binary) % 4))
        chunk = replacements.get(index, view_bytes(original, binary, index))
        view['byteOffset'], view['byteLength'] = len(packed_binary), len(chunk)
        packed_binary.extend(chunk)
    gltf['buffers'][0]['byteLength'] = len(packed_binary)
    encoded = pack_glb(gltf, bytes(packed_binary))
    checked, checked_binary = parse_glb(encoded)
    geometry = gltf_geometry(original, binary)
    assert geometry == gltf_geometry(checked, checked_binary), 'Geometry, rig or animation changed'
    assert original.get('materials') == checked.get('materials') and original.get('samplers') == checked.get('samplers')
    private_backup(backup, theme_id, relative, payload)
    atomic_bytes(path, encoded)
    asset.update(sha256=hashlib.sha256(encoded).hexdigest(), runtime_bytes=len(encoded),
                 geometry_sha256=geometry, geometry_unchanged=True,
                 texture_encoding={'operation': 'lossless_png_to_webp', 'meshy_credits': 0,
                 'source_path': relative, 'source_sha256': hashlib.sha256(payload).hexdigest(),
                 'source_bytes': len(payload), 'runtime_bytes': len(encoded),
                 'geometry_unchanged': True, 'decoded_pixels_unchanged': True, 'images': image_records})
    if 'bytes' in asset:
        asset['bytes'] = len(encoded)
    for item in asset.get('images', []):
        item['mime_type'] = image_records[item['index']]['mime_type']
    verify_texture_encoding(path, asset)
    print(f'{theme_id}/{path.stem}: lossless textures save {(len(payload)-len(encoded))/1e6:.2f} MB', flush=True)
    return True


def compact_package(backup: Path) -> None:
    repo = Path(__file__).resolve().parents[1]
    assert not backup.resolve().is_relative_to(repo), 'Original artwork must stay outside the repository'
    ui = repo / 'plugins/agent-world/ui'
    for theme_id in ('grand-line', 'outpost', 'shared'):
        root = ui / 'assets' if theme_id == 'shared' else ui / 'themes' / theme_id
        provenance = json.loads(local_file(root, 'provenance.json').read_text())
        stale = []
        references = list(provenance.get('references', {}).values())
        references += [provenance[key] for key in ('source_image', 'reference') if key in provenance]
        for reference in references:
            old = encode_reference(root, theme_id, reference, backup)
            if old:
                stale.append(old)
        replacements = {ref['source_path']: ref['path'] for ref in references if ref.get('source_path')}
        for asset in provenance['assets'].values():
            if asset.get('reference_image') in replacements:
                asset['reference_image'] = replacements[asset['reference_image']]
        save(root / 'provenance.json', provenance)
        for relative in stale:
            local_file(root, relative).unlink()
        if theme_id == 'shared':
            continue
        manifest = json.loads(local_file(root, 'theme.json').read_text())
        def encode_one(name: str, relative: str) -> tuple[str, dict]:
            metadata = copy.deepcopy(provenance['assets'][name])
            encode_textures(root, theme_id, relative, metadata, backup)
            return name, metadata
        with ThreadPoolExecutor(max_workers=4) as workers:
            pending = [workers.submit(encode_one, name, asset.get('path', manifest['assets'].get(name))) for name, asset in provenance['assets'].items()]
            for future in as_completed(pending):
                name, metadata = future.result()
                provenance['assets'][name] = metadata
                save(root / 'provenance.json', provenance)
        provenance['lossless_packaging'] = {
            'operation': 'lossless_png_to_webp', 'meshy_credits': 0,
            'geometry_unchanged': True, 'decoded_pixels_unchanged': True,
            'source_bytes': sum(a['texture_encoding']['source_bytes'] for a in provenance['assets'].values() if 'texture_encoding' in a),
            'runtime_bytes': sum(a.get('runtime_bytes', a.get('bytes', 0)) for a in provenance['assets'].values()),
        }
        verify_public_provenance(provenance, theme_id=theme_id)
        save(root / 'provenance.json', provenance)
    size = sum(path.stat().st_size for path in (repo / 'plugins/agent-world').rglob('*') if path.is_file())
    print(f'Complete plugin: {size:,} bytes ({size / 2**20:.2f} MiB); originals retained outside the repository.', flush=True)


def compress_containers(backup: Path, path_map: Path, *, write_manifest: bool) -> None:
    repo = Path(__file__).resolve().parents[1]
    assert not backup.resolve().is_relative_to(repo), 'Source containers belong outside the repository'
    paths = {}
    for theme_id in ('grand-line', 'outpost'):
        root = repo / 'plugins/agent-world/ui/themes' / theme_id
        manifest = json.loads(local_file(root, 'theme.json').read_text())
        provenance = json.loads(local_file(root, 'provenance.json').read_text())
        current_paths, stale = {}, []
        for name, asset in provenance['assets'].items():
            relative = asset.get('path', manifest['assets'].get(name))
            path = local_file(root, relative)
            if container := asset.get('container_encoding'):
                verify_container_encoding(path, asset)
                original = local_file(backup / theme_id / 'containers', container['source_path'])
                assert hashlib.sha256(original.read_bytes()).hexdigest() == container['source_sha256']
                current_paths[name] = relative
                continue
            source = path.read_bytes()
            assert hashlib.sha256(source).hexdigest() == asset['sha256']
            buffer = io.BytesIO()
            # A fixed timestamp and absent filename make the package repeatable
            # across machines and keep private source paths out of gzip headers.
            with gzip.GzipFile(filename='', mode='wb', compresslevel=9, fileobj=buffer, mtime=0) as handle:
                handle.write(source)
            encoded = buffer.getvalue()
            assert gzip.decompress(encoded) == source, 'Container compression changed model bytes'
            if len(encoded) >= len(source):
                current_paths[name] = relative
                continue
            geometry = geometry_digest(path)
            private_backup(backup, theme_id + '/containers', relative, source)
            target = path.with_suffix('.glb.gz')
            atomic_bytes(target, encoded)
            asset.update(path=target.relative_to(root).as_posix(), sha256=hashlib.sha256(encoded).hexdigest(),
                         runtime_bytes=len(encoded), geometry_sha256=geometry, geometry_unchanged=True,
                         container_encoding={'format': 'gzip', 'compression_level': 9, 'meshy_credits': 0,
                         'source_path': relative, 'source_sha256': hashlib.sha256(source).hexdigest(),
                         'source_bytes': len(source), 'runtime_bytes': len(encoded), 'geometry_unchanged': True,
                         'materials_unchanged': True, 'decoded_pixels_unchanged': True})
            if 'bytes' in asset:
                asset['bytes'] = len(encoded)
            verify_container_encoding(target, asset)
            verify_texture_encoding(target, asset)
            current_paths[name] = asset['path']
            stale.append(relative)
            print(f'{theme_id}/{name}: exact GLB container saves {(len(source)-len(encoded))/1e6:.2f} MB', flush=True)
        provenance['container_packaging'] = {
            'format': 'gzip', 'meshy_credits': 0, 'decoded_model_bytes_unchanged': True,
            'source_bytes': sum(a['container_encoding']['source_bytes'] for a in provenance['assets'].values() if 'container_encoding' in a),
            'runtime_bytes': sum(a.get('runtime_bytes', a.get('bytes', 0)) for a in provenance['assets'].values()),
        }
        verify_public_provenance(provenance, theme_id=theme_id)
        save(root / 'provenance.json', provenance)
        if write_manifest:
            manifest['assets'] = current_paths
            save(root / 'theme.json', manifest)
        paths[theme_id] = current_paths
        for relative in stale:
            local_file(root, relative).unlink()
    path_map.parent.mkdir(parents=True, exist_ok=True)
    save(path_map, {'version': 1, 'themes': paths})
    total = sum(p.stat().st_size for p in (repo / 'plugins/agent-world').rglob('*') if p.is_file())
    print(f'Container paths written to {path_map}; complete plugin {total:,} bytes ({total/2**20:.2f} MiB).', flush=True)

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state-dir', type=Path, action='append', required=True,
                        help='Completed private ledger directory; repeat for each campaign')
    parser.add_argument('--require-complete', action='store_true', help='Require every approved Local Line campaign before publishing')
    parser.add_argument('--check-only', action='store_true', help='Validate sources and candidate provenance without writing files')
    parser.add_argument('--compact', action='store_true', help='Package JPEG reference artwork and pixel-identical lossless WebP textures')
    parser.add_argument('--source-backup-dir', type=Path, default=Path.home() / '.codex/agent-world-package-sources-20260913',
                        help='Private source backup directory outside the repository')
    parser.add_argument('--gzip-containers', action='store_true', help='Wrap exact GLB bytes in local gzip containers; requires the matching renderer loader')
    parser.add_argument('--provenance-only', action='store_true', help='Leave theme manifests to their owner; emit a path map for container integration')
    parser.add_argument('--path-map', type=Path, default=Path('/tmp/agent-world-container-paths.json'), help='JSON asset path map for renderer manifest integration')
    args = parser.parse_args()
    assert not ((args.compact or args.gzip_containers) and args.check_only), '--compact writes files and cannot be combined with --check-only'
    package(args.state_dir, require_complete=args.require_complete, check_only=args.check_only, backup=args.source_backup_dir, write_manifest=not args.provenance_only)
    if args.compact:
        compact_package(args.source_backup_dir)
    if args.gzip_containers:
        compress_containers(args.source_backup_dir, args.path_map, write_manifest=not args.provenance_only)
    if args.compact or args.gzip_containers:
        # Rebuild current campaign totals after encoding, exercising the same
        # source-chain checks used by subsequent reproducible invocations.
        package(args.state_dir, require_complete=args.require_complete, backup=args.source_backup_dir, write_manifest=not args.provenance_only)


if __name__ == '__main__':
    main()
