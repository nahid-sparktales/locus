#!/usr/bin/env python3
"""Build editable Houdini terrain; does not generate Houdini output without hou.

Run --validate-design with ordinary Python for a geometry-bound design check.
Run with Houdini's hython to create the real SOP network and HIP file. --export
uses Houdini's GLTF ROP, never a substitute exporter. Outputs remain staged.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import sys

DEFAULT_PLAN = Path(globals().get('__file__', 'HoudiniGrandLineTerrain.py')).with_suffix('.json')
TAU = math.tau


def plan_from(path):
    plan = json.loads(Path(path).read_text())
    if plan.get('version') != 1 or len(plan.get('assets', [])) != 2:
        raise ValueError('Expected the two-asset version 1 terrain plan')
    for spec in plan['assets']:
        if spec['id'] not in ('scenery_red_line', 'scenery_reverse_mountain'):
            raise ValueError('Unrecognized terrain identity')
        for key in ('width', 'depth', 'height'):
            if not isinstance(spec[key], (float, int)) or not 0 < spec[key] <= 12:
                raise ValueError(f'Invalid {key}')
        envelope = (4.2, 10.4, 6.9) if spec['id'] == 'scenery_red_line' else (5.2, 5.0, 8.0)
        if any(spec[key] > maximum for key, maximum in zip(('width', 'depth', 'height'), envelope)):
            raise ValueError('The design exceeds the existing runtime terrain envelope')
        if spec['id'] == 'scenery_reverse_mountain' and spec.get('footprint_radius') != 2.5:
            raise ValueError('The mountain must retain the 2.5-unit navigation footprint')
        if not 32 <= spec['angular_samples'] <= 256 or not 16 <= spec['vertical_samples'] <= 128:
            raise ValueError('Resolution is outside the interactive authoring budget')
    return plan


def fractal(x, y, z, seed):
    """Bounded deterministic fBm, independent of Houdini version or random state."""
    total = 0.0
    for frequency, weight in ((1.0, 0.55), (2.03, 0.27), (4.11, 0.13), (8.17, 0.05)):
        total += weight * math.sin(x * frequency + seed * 0.017) * math.sin(z * frequency * 1.31 + y * 0.73) * math.cos(y * frequency * 0.83 - x * 0.37)
    return total


def angle_distance(a, b):
    return (a - b + math.pi) % TAU - math.pi


def river_angle(t):
    return 0.10 + 0.19 * math.sin(t * 4.0) + 0.10 * math.sin(t * 9.5)


def surface(spec, theta, t, seed):
    mountain = spec['kind'] == 'mountain'
    c, s = math.cos(theta), math.sin(theta)
    # Elliptic cliff sections form a continuous ridge; a circular mountain base
    # obeys the existing radius exactly, including the downhill water ribbon.
    x0, z0 = s * spec['width'] / 2, c * spec['depth'] / 2
    if mountain:
        taper = 0.965 * (1 - 0.86 * t ** 1.20)
        crown = 0.97 + 0.03 * math.sin(theta * 3.0)
    else:
        taper = 0.955 - 0.20 * t - 0.07 * t ** 4
        crown = 0.89 + 0.075 * math.cos(theta * 2.0) + 0.035 * math.sin(theta * 7.0)
    y = t * spec['height'] * crown
    strata = spec.get('strata_amount', 1.0) * (0.032 * math.sin(y * 8.0 + math.sin(theta * 2.0)) + 0.012 * math.sin(y * 27.0))
    geology = fractal(x0 * 2.7, y * 1.7, z0 * 2.4, seed)
    radius = taper * (1 + 0.07 * spec.get('geology_amount', 1.0) * geology + strata)
    channel = 0.0
    if mountain:
        # The tributaries converge into the front gorge. This is actual carved
        # rock geometry, with a separate narrow water surface in the same bed.
        for center, width, depth in ((river_angle(t), 0.085, 0.115), (-0.68 + 0.74 * t, 0.055, 0.055), (0.85 - 0.61 * t, 0.06, 0.055)):
            channel += spec.get('channel_depth', 1.0) * depth * math.exp(-(angle_distance(theta, center) / width) ** 2)
        radius -= channel * math.sin(min(1.0, t / 0.08) * math.pi / 2)
    radius = max(0.045, min(0.995, radius))
    x, z = x0 * radius, z0 * radius
    # Hard geometric limits are also checked after Houdini cooks the network.
    if 'footprint_radius' in spec:
        scale = min(1.0, (spec['footprint_radius'] - 0.012) / max(0.0001, math.hypot(x, z)))
        x, z = x * scale, z * scale
    return (x, y, z), geology, channel


def rock_color(y, geology, channel, height):
    band = 0.5 + 0.5 * math.sin(y * 8.2 + geology * 0.7)
    shade = 0.88 + 0.12 * geology
    color = tuple(v * shade for v in (0.40 + 0.25 * band, 0.19 + 0.13 * band, 0.12 + 0.09 * band))
    if y > height * 0.58 and band < 0.23 and channel < 0.012:
        return (0.19 + geology * 0.025, 0.28 + geology * 0.035, 0.13)
    return color


def mesh_data(spec, seed):
    vertices, colors, faces = [], [], []
    angular, vertical = spec['angular_samples'], spec['vertical_samples']
    for row in range(vertical + 1):
        for column in range(angular):
            point, geology, channel = surface(spec, column / angular * TAU, row / vertical, seed)
            vertices.append(point)
            colors.append(rock_color(point[1], geology, channel, spec['height']))
    for row in range(vertical):
        for column in range(angular):
            next_column = (column + 1) % angular
            a, b = row * angular + column, row * angular + next_column
            faces.extend(((a, b, b + angular), (a, b + angular, a + angular)))
    for row, reverse in ((0, True), (vertical, False)):
        start = row * angular
        center = len(vertices)
        vertices.append(tuple(sum(vertices[start + c][axis] for c in range(angular)) / angular for axis in range(3)))
        colors.append(colors[start])
        for column in range(angular):
            edge = (start + column, start + (column + 1) % angular)
            faces.append((center, *reversed(edge)) if reverse else (center, *edge))
    rock_face_count = len(faces)
    if spec['kind'] == 'mountain':
        first = len(vertices)
        for row in range(vertical + 1):
            t = 0.015 + 0.96 * row / vertical
            for side in (-1, 1):
                theta = river_angle(t) + side * (0.018 + 0.011 * (1 - t))
                point, _, _ = surface(spec, theta, t, seed)
                vertices.append((point[0] + math.sin(theta) * 0.009, point[1] + 0.009, point[2] + math.cos(theta) * 0.009))
                foam = 0.5 + 0.5 * math.sin(row * 0.87)
                colors.append((0.22 + 0.34 * foam, 0.64 + 0.22 * foam, 0.68 + 0.20 * foam))
        for row in range(vertical):
            a = first + row * 2
            faces.extend(((a, a + 3, a + 2), (a, a + 1, a + 3)))
    return vertices, colors, faces, rock_face_count


def validate_mesh(spec, vertices, faces):
    if len(faces) > spec['triangle_limit']:
        raise ValueError(f"{spec['id']} exceeds its triangle budget")
    for x, y, z in vertices:
        if not all(math.isfinite(value) for value in (x, y, z)):
            raise ValueError('Non-finite terrain position')
        if abs(x) > spec['width'] / 2 + 1e-6 or abs(z) > spec['depth'] / 2 + 1e-6 or not -1e-6 <= y <= spec['height'] + 1e-6:
            raise ValueError(f"{spec['id']} leaves the existing navigation envelope")
        if 'footprint_radius' in spec and math.hypot(x, z) > spec['footprint_radius'] + 1e-6:
            raise ValueError('Mountain vertex intrudes into the passage')
    return {'points': len(vertices), 'triangles': len(faces), 'min': [min(p[i] for p in vertices) for i in range(3)], 'max': [max(p[i] for p in vertices) for i in range(3)]}


def cook_geometry(node, spec, seed):
    """Called only inside the real Houdini Python SOP cook."""
    import hou
    vertices, colors, faces, rock_count = mesh_data(spec, seed)
    validate_mesh(spec, vertices, faces)
    geo = node.geometry()
    geo.clear()
    color = geo.addAttrib(hou.attribType.Point, 'Cd', (1.0, 1.0, 1.0))
    uv = geo.addAttrib(hou.attribType.Vertex, 'uv', (0.0, 0.0, 0.0))
    material = geo.addAttrib(hou.attribType.Prim, 'shop_materialpath', '')
    points = geo.createPoints(vertices)
    for point, value in zip(points, colors):
        point.setAttribValue(color, value)
    for index, face in enumerate(faces):
        polygon = geo.createPolygon()
        for point_index in face:
            vertex = polygon.addVertex(points[point_index])
            x, y, z = vertices[point_index]
            vertex.setAttribValue(uv, ((math.atan2(x, z) / TAU) % 1, y / spec['height'], 0.0))
        polygon.setAttribValue(material, '/mat/locus_water' if index >= rock_count else '/mat/locus_sandstone')
    geo.addAttrib(hou.attribType.Global, 'locus_terrain_author', 'Houdini Python SOP')


def parameter_by_label(node, label, value, required=True):
    matches = [parm for parm in node.parms() if parm.parmTemplate().label() == label]
    if len(matches) == 1:
        matches[0].set(value)
        return matches[0]
    if required:
        raise RuntimeError(f'{node.path()}: expected one {label!r} parameter, found {len(matches)}; inspect this Houdini version before export')
    return None


def build_houdini(plan, destination, export):
    try:
        import hou
    except ImportError as error:
        raise RuntimeError('Houdini is not available in this Python. Install and license Houdini, then use its hython or Python shell. No HIP or GLB was generated.') from error
    category = str(hou.licenseCategory())
    noncommercial = any(word in category.lower() for word in ('apprentice', 'education', 'noncommercial'))
    if export and 'apprentice' in category.lower():
        raise RuntimeError('Houdini Apprentice does not support native glTF/GLB export. Run without --export to save the editable .hipnc study; use an export-capable license for GLB output.')
    destination.mkdir(parents=True, exist_ok=False)
    if hou.node('/obj/locus_terrain_authoring'):
        raise RuntimeError('The authoring network already exists; use a clean Houdini session')
    parent = hou.node('/obj').createNode('subnet', 'locus_terrain_authoring')
    material_root = hou.node('/mat')
    for name, roughness in (('locus_sandstone', 0.88), ('locus_water', 0.24)):
        if material_root.node(name):
            raise RuntimeError(f'An unrelated material already uses {name}; use a clean session')
        shader = material_root.createNode('principledshader::2.0', name)
        shader.parmTuple('basecolor').set((1.0, 1.0, 1.0))
        shader.parm('rough').set(roughness)
    reports = []
    for spec in plan['assets']:
        obj = parent.createNode('geo', spec['id'])
        for child in obj.children():
            child.destroy()
        source = obj.createNode('python', 'strata_and_riverbed')
        # Embed the implementation so saved HIP files remain editable without
        # relying on a checkout path or importing an untrusted external module.
        implementation = Path(__file__).read_text().rsplit("\nif __name__ == '__main__':", 1)[0]
        templates = source.parmTemplateGroup()
        controls = [hou.IntParmTemplate('terrain_seed', 'Terrain seed', 1, default_value=(plan['seed'],))]
        for name, label in (('geology_amount', 'Rock detail'), ('strata_amount', 'Strata relief'), ('channel_depth', 'Riverbed depth')):
            controls.append(hou.FloatParmTemplate(name, label, 1, default_value=(1.0,), min=0.0, max=1.5, min_is_strict=True, max_is_strict=True))
        templates.append(hou.FolderParmTemplate('terrain_controls', 'Terrain controls', parm_templates=controls))
        source.setParmTemplateGroup(templates)
        invocation = f'\nimport hou\nspec = {spec!r}\n'
        invocation += "for key in ('geology_amount', 'strata_amount', 'channel_depth'):\n    spec[key] = hou.pwd().evalParm(key)\n"
        invocation += "cook_geometry(hou.pwd(), spec, hou.pwd().evalParm('terrain_seed'))\n"
        source.parm('python').set(implementation + invocation)
        normal = obj.createNode('normal', 'terrain_normals')
        normal.setInput(0, source)
        output = obj.createNode('null', 'OUT_TERRAIN')
        output.setInput(0, normal)
        output.setDisplayFlag(True)
        output.setRenderFlag(True)
        output.cook(force=True)
        if output.errors():
            raise RuntimeError('; '.join(output.errors()))
        geometry = output.geometry()
        report = validate_mesh(spec, [tuple(point.position()) for point in geometry.points()], [tuple(vertex.point().number() for vertex in prim.vertices()) for prim in geometry.prims()])
        report['asset'] = spec['id']
        if export:
            rop_type = 'rop_gltf::2.0' if hou.sopNodeTypeCategory().nodeTypes().get('rop_gltf::2.0') else 'rop_gltf'
            rop = obj.createNode(rop_type, 'EXPORT_GLB')
            rop.setInput(0, output)
            glb = destination / (spec['id'] + '.glb')
            parameter_by_label(rop, 'Output File', str(glb))
            parameter_by_label(rop, 'Use Draco Compression', False, required=False)
            buttons = [p for p in rop.parms() if p.parmTemplate().label() in ('Save to Disk', 'Render to Disk')]
            if len(buttons) != 1:
                raise RuntimeError('This GLTF ROP has no unique disk-export action; inspect it in Houdini')
            buttons[0].pressButton()
            if rop.errors() or not glb.is_file() or glb.read_bytes()[:4] != b'glTF':
                raise RuntimeError('Houdini GLB export did not complete: ' + '; '.join(rop.errors()))
            report.update(file=glb.name, sha256=hashlib.sha256(glb.read_bytes()).hexdigest())
        obj.layoutChildren()
        reports.append(report)
    parent.layoutChildren()
    extension = '.hipnc' if noncommercial else '.hiplc' if 'indie' in category.lower() else '.hip'
    hip = destination / ('grand_line_terrain' + extension)
    hou.hipFile.save(str(hip))
    result = {'status': 'exported' if export else 'authored', 'houdini_version': hou.applicationVersionString(), 'license_category': category, 'project': hip.name, 'assets': reports, 'source_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
    (destination / 'houdini-authoring-report.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plan', type=Path, default=DEFAULT_PLAN)
    parser.add_argument('--validate-design', action='store_true', help='Check the design math only; creates no Houdini output')
    parser.add_argument('--output', type=Path, help='New staging directory; existing directories are refused')
    parser.add_argument('--export', action='store_true', help='Also run the real Houdini GLTF exporter under a suitable license')
    args = parser.parse_args()
    plan = plan_from(args.plan)
    if args.validate_design:
        print(json.dumps({'status': 'design-only; Houdini has not run', 'assets': [{**validate_mesh(spec, *[mesh_data(spec, plan['seed'])[i] for i in (0, 2)]), 'asset': spec['id']} for spec in plan['assets']]}, indent=2))
        return
    if args.output is None:
        parser.error('--output is required for a real Houdini authoring run')
    build_houdini(plan, args.output.resolve(), args.export)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError) as error:
        sys.exit(str(error))
