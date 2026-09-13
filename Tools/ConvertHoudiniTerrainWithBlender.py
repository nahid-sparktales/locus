#!/usr/bin/env python3
"""Convert the staged terrain using native Houdini PLY and actual Blender.

Run with ordinary Python. Application-specific phases run in separate background
processes; the source HIP and any interactive application session remain untouched.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys


ASSETS = ("scenery_red_line", "scenery_reverse_mountain")
NODE_ROOT = "/obj/locus_terrain_authoring"


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_json(path, data):
    Path(path).write_text(json.dumps(data, indent=2) + "\n")


def bounds(points):
    return {"min": [min(p[a] for p in points) for a in range(3)],
            "max": [max(p[a] for p in points) for a in range(3)]}


def houdini_export(args):
    import hou

    source_hash = digest(args.source_hip)
    hou.hipFile.load(str(args.source_hip), suppress_save_prompt=True,
                     ignore_load_warnings=True)
    report = {"houdini_version": hou.applicationVersionString(),
              "license_category": str(hou.licenseCategory()),
              "source_file": args.source_hip.name,
              "source_sha256": source_hash, "assets": []}
    for name in ASSETS:
        node = hou.node(f"{NODE_ROOT}/{name}/OUT_TERRAIN")
        if node is None:
            raise RuntimeError(f"Missing terrain output: {name}")
        node.cook(force=True)
        if node.errors():
            raise RuntimeError(str(node.errors()))
        geo = node.geometry().freeze()
        if not geo.findPointAttrib("Cd") or not geo.findPrimAttrib("shop_materialpath"):
            raise RuntimeError(f"{name}: expected source color/material attributes")
        primitives = geo.prims()
        faces = [[v.point().number() for v in p.vertices()] for p in primitives]
        if any(len(face) != 3 for face in faces):
            raise RuntimeError(f"{name}: expected triangulated source")
        points = [list(p.position()) for p in geo.points()]
        colors = [list(p.attribValue("Cd")) for p in geo.points()]
        paths = sorted(set(p.stringAttribValue("shop_materialpath") for p in primitives))
        materials = []
        for path in paths:
            material = hou.node(path)
            if material is None or material.parm("rough") is None:
                raise RuntimeError(f"Missing source Principled material {path}")
            base_color = list(material.parmTuple("basecolor").eval())
            uses_cd = material.parm("basecolor_usePointColor")
            uses_texture = material.parm("basecolor_useTexture")
            if (base_color != [1.0, 1.0, 1.0] or uses_cd is None or uses_cd.eval() != 1
                    or uses_texture is None or uses_texture.eval() != 0):
                raise RuntimeError(f"{path}: converter supports the study's white base tint, "
                                   "enabled point Cd and no base texture; preserve edited "
                                   "shader settings explicitly before converting")
            materials.append({"source_path": path, "name": material.name(),
                              "roughness": material.parm("rough").eval(),
                              "base_color": base_color, "uses_point_cd": True})
        metadata = {"name": name, "positions": points, "faces": faces,
                    "colors_linear": colors, "materials": materials,
                    "material_indices": [paths.index(p.stringAttribValue("shop_materialpath"))
                                         for p in primitives],
                    "uv": [[list(v.attribValue("uv"))[:2] for v in p.vertices()]
                           for p in primitives] if geo.findVertexAttrib("uv") else None,
                    "normals": [[list(v.attribValue("N")) for v in p.vertices()]
                                for p in primitives] if geo.findVertexAttrib("N") else None}
        # PLY carries the actual native-exported geometry. The sidecar preserves
        # float Cd, face materials and corner attributes the format may discard.
        ply = args.output / f"{name}.ply"
        interchange = hou.Geometry(geo)
        # Native PLY promotes corner normals to points by splitting vertices.
        # Keep those losslessly in the sidecar so the geometry file retains the
        # original point and face order for verified attribute reconstruction.
        for attribute in interchange.vertexAttribs():
            attribute.destroy()
        interchange.saveToFile(str(ply))
        if not ply.is_file() or not ply.read_bytes().startswith(b"ply\n"):
            raise RuntimeError(f"Native Houdini PLY export failed: {name}")
        write_json(args.output / f"{name}.attributes.json", metadata)
        report["assets"].append({"name": name, "points": len(points),
                                 "triangles": len(faces), **bounds(points),
                                 "ply_sha256": digest(ply), "ply_bytes": ply.stat().st_size})
    if digest(args.source_hip) != source_hash:
        raise RuntimeError("Source HIP unexpectedly changed")
    report["source_unchanged"] = True
    write_json(args.output / "houdini-interchange-report.json", report)
    print(json.dumps(report))


def glb_report(path, expected):
    data = path.read_bytes()
    magic, version, size = struct.unpack_from("<4sII", data)
    if magic != b"glTF" or version != 2 or size != len(data):
        raise RuntimeError(f"Invalid GLB: {path}")
    json_size, json_kind = struct.unpack_from("<II", data, 12)
    if json_kind != 0x4E4F534A:
        raise RuntimeError("GLB JSON chunk missing")
    document = json.loads(data[20:20 + json_size])
    primitives = [p for m in document["meshes"] for p in m["primitives"]]
    count = sum(document["accessors"][p["indices"]]["count"] // 3 for p in primitives)
    if count != len(expected["faces"]):
        raise RuntimeError(f"GLB triangle count changed: {count}")
    position_accessors = [document["accessors"][p["attributes"]["POSITION"]] for p in primitives]
    measured = {"min": [min(a["min"][i] for a in position_accessors) for i in range(3)],
                "max": [max(a["max"][i] for a in position_accessors) for i in range(3)]}
    original = bounds(expected["positions"])
    delta = max(abs(measured[key][axis] - original[key][axis])
                for key in ("min", "max") for axis in range(3))
    if delta > 0.00001:
        raise RuntimeError(f"GLB y-up geometry bounds changed: {delta}")
    for primitive in primitives:
        for attribute in ("NORMAL", "COLOR_0", "TEXCOORD_0"):
            if attribute not in primitive["attributes"]:
                raise RuntimeError(f"GLB lost {attribute}")
        if primitive.get("mode", 4) != 4:
            raise RuntimeError("GLB contains non-triangle primitives")
    if any(n.get("translation") or n.get("rotation") or n.get("scale") or n.get("matrix")
           for n in document.get("nodes", [])):
        raise RuntimeError("Individual terrain GLB must retain origin and unit scale")
    if any("uri" in item for key in ("images", "buffers") for item in document.get(key, [])):
        raise RuntimeError("GLB depends on an external resource")
    return {"file": path.name, "sha256": digest(path), "bytes": len(data),
            "triangles": count, "y_up_bounds": measured, "bounds_max_error": delta,
            "materials": [m["name"] for m in document.get("materials", [])],
            "attributes": sorted(primitives[0]["attributes"]),
            "embedded_resources": True}


def blender_convert(args):
    import bpy
    from mathutils import Matrix, Vector

    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    # Houdini Y-up -> Blender Z-up; glTF's Y-up export applies the inverse.
    axis = Matrix(((1, 0, 0, 0), (0, 0, -1, 0), (0, 1, 0, 0), (0, 0, 0, 1)))
    report = {"blender_version": bpy.app.version_string,
              "source": json.loads((args.output / "houdini-interchange-report.json").read_text()),
              "assets": []}
    objects = []
    for name in ASSETS:
        metadata = json.loads((args.output / f"{name}.attributes.json").read_text())
        bpy.ops.object.select_all(action="DESELECT")
        result = bpy.ops.wm.ply_import(filepath=str(args.output / f"{name}.ply"),
                                       forward_axis="Y", up_axis="Z", merge_verts=False,
                                       import_colors="LINEAR")
        if "FINISHED" not in result:
            raise RuntimeError(f"Blender PLY import failed: {name}")
        obj = bpy.context.object
        obj.name = name
        mesh = obj.data
        if len(mesh.vertices) != len(metadata["positions"]) or len(mesh.polygons) != len(metadata["faces"]):
            raise RuntimeError(f"PLY topology changed: {name}")
        max_error = max((Vector(p) - v.co).length for p, v in zip(metadata["positions"], mesh.vertices))
        if max_error > 0.00001:
            raise RuntimeError(f"PLY positions changed: {max_error}")
        if any(list(poly.vertices) != face for poly, face in zip(mesh.polygons, metadata["faces"])):
            raise RuntimeError(f"PLY face order changed: {name}; sidecar cannot be applied safely")
        for attr in list(mesh.color_attributes):
            mesh.color_attributes.remove(attr)
        cd = mesh.color_attributes.new(name="Cd", type="FLOAT_COLOR", domain="POINT")
        cd.data.foreach_set("color", [value for c in metadata["colors_linear"] for value in (*c, 1.0)])
        mesh.color_attributes.active_color = cd
        uv = mesh.uv_layers.new(name="terrain_uv")
        for polygon, coordinates in zip(mesh.polygons, metadata["uv"]):
            for loop, coordinate in zip(polygon.loop_indices, coordinates):
                uv.data[loop].uv = coordinate
        mesh.transform(axis)
        normal_sign = 1
        if metadata["normals"]:
            # Houdini's cooked N in this HIP uses the opposite orientation to
            # the outward PLY triangle cross products. Verify a uniform sign;
            # retain geometry/corner order and align shading normals explicitly.
            signs = set()
            for face, normals in zip(metadata["faces"], metadata["normals"]):
                a, b, c = (Vector(metadata["positions"][i]) for i in face)
                cross = (b - a).cross(c - a)
                mean = sum((Vector(n) for n in normals), Vector())
                if cross.length_squared > 1e-20 and mean.length_squared > 1e-20:
                    alignment = cross.normalized().dot(mean.normalized())
                    if abs(alignment) > 1e-6:
                        signs.add(1 if alignment > 0 else -1)
            if len(signs) != 1:
                raise RuntimeError(f"{name}: inconsistent source normal orientation; inspect the HIP")
            normal_sign = signs.pop()
            normals = [normal_sign * (axis.to_3x3() @ Vector(n))
                       for face in metadata["normals"] for n in face]
            mesh.normals_split_custom_set(normals)
        for source in metadata["materials"]:
            material = bpy.data.materials.get(source["name"])
            if material is None:
                material = bpy.data.materials.new(source["name"])
                material.use_nodes = True
                shader = material.node_tree.nodes.get("Principled BSDF")
                shader.inputs["Roughness"].default_value = source["roughness"]
                shader.inputs["Base Color"].default_value = (*source["base_color"], 1)
                color = material.node_tree.nodes.new("ShaderNodeVertexColor")
                color.layer_name = "Cd"
                material.node_tree.links.new(color.outputs["Color"], shader.inputs["Base Color"])
            mesh.materials.append(material)
        for polygon, material_index in zip(mesh.polygons, metadata["material_indices"]):
            polygon.material_index = material_index
            polygon.use_smooth = True
        mesh.update()
        obj["source_file"] = args.source_hip.name
        obj["source_sop"] = f"{NODE_ROOT}/{name}/OUT_TERRAIN"
        obj["source_license"] = report["source"]["license_category"]
        obj["interchange"] = "Houdini native PLY -> Blender"
        obj["source_normal_sign_correction"] = normal_sign
        glb = args.output / f"{name}.glb"
        result = bpy.ops.export_scene.gltf(filepath=str(glb), export_format="GLB",
                    use_selection=True, export_yup=True, export_normals=True,
                    export_texcoords=True, export_materials="EXPORT",
                    export_vertex_color="MATERIAL", export_all_vertex_colors=False,
                    export_draco_mesh_compression_enable=False, export_extras=True)
        if "FINISHED" not in result:
            raise RuntimeError(f"Blender GLB export failed: {name}")
        asset = glb_report(glb, metadata)
        asset.update({"ply_max_position_error": max_error,
                      "source_topology_preserved": True,
                      "source_float_colors_restored": True,
                      "source_corner_normal_sign_correction": normal_sign,
                      "blender_review_offset": [-4.1 if not objects else 4.1, 0, 0]})
        # Render the actual GLB round-trip, so the preview also checks Blender's
        # exported colors, materials and normals rather than only the input mesh.
        bpy.data.objects.remove(obj, do_unlink=True)
        bpy.ops.object.select_all(action="DESELECT")
        result = bpy.ops.import_scene.gltf(filepath=str(glb))
        imported = [item for item in bpy.context.selected_objects if item.type == "MESH"]
        if "FINISHED" not in result or len(imported) != 1:
            raise RuntimeError(f"{name}: GLB round-trip did not produce one terrain mesh")
        obj = imported[0]
        obj.data.calc_loop_triangles()
        if len(obj.data.loop_triangles) != len(metadata["faces"]):
            raise RuntimeError(f"{name}: GLB round-trip changed triangle count")
        actual_bounds = bounds([axis.inverted() @ (obj.matrix_world @ v.co) for v in obj.data.vertices])
        original_bounds = bounds(metadata["positions"])
        if any(abs(actual_bounds[k][a] - original_bounds[k][a]) > 0.00001
               for k in ("min", "max") for a in range(3)):
            raise RuntimeError(f"{name}: GLB reimport bounds changed")
        asset["blender_glb_reimport_verified"] = True
        report["assets"].append(asset)
        objects.append(obj)

    # Only the editable review scene is laid out side by side. Individual GLBs
    # above already retain their original local origin, orientation and scale.
    for obj, item in zip(objects, report["assets"]):
        obj.location = item["blender_review_offset"]
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.samples = 48
    scene.cycles.use_denoising = True
    scene.render.resolution_x = 1500
    scene.render.resolution_y = 1100
    scene.render.resolution_percentage = 100
    scene.world.color = (0.14, 0.14, 0.14)
    scene.view_settings.view_transform = "AgX"
    bpy.ops.mesh.primitive_plane_add(size=200, location=(0, 0, -0.06))
    ground = bpy.context.object
    ground.name = "Preview ground — excluded from individual exports"
    mat = bpy.data.materials.new("Preview slate")
    mat.use_nodes = True
    mat.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.055, 0.08, 0.10, 1)
    mat.node_tree.nodes["Principled BSDF"].inputs["Roughness"].default_value = 0.85
    ground.data.materials.append(mat)
    for name, position, energy, size, color in (
        ("Key", (-7, -10, 17), 2500, 10, (1, 0.86, 0.70)),
        ("Fill", (10, -1, 10), 1400, 9, (0.65, 0.83, 1)),
        ("Rim", (0, 9, 15), 2200, 8, (1, 0.95, 0.82)),
    ):
        lamp = bpy.data.lights.new(name, "AREA")
        lamp.energy, lamp.shape, lamp.size, lamp.color = energy, "DISK", size, color
        obj = bpy.data.objects.new(name, lamp)
        scene.collection.objects.link(obj)
        obj.location = position
        obj.rotation_euler = (Vector((0, 0, 3)) - obj.location).to_track_quat("-Z", "Y").to_euler()
    camera = bpy.data.cameras.new("Terrain review camera")
    camera.type, camera.ortho_scale = "ORTHO", 22
    camera_obj = bpy.data.objects.new("Terrain review camera", camera)
    scene.collection.objects.link(camera_obj)
    camera_obj.location = (18, -28, 21)
    camera_obj.rotation_euler = (Vector((0, 0, 3.2)) - camera_obj.location).to_track_quat("-Z", "Y").to_euler()
    scene.camera = camera_obj
    scene.render.image_settings.file_format = "PNG"
    scene.render.filepath = str(args.output / "blender_terrain_preview.png")
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    project = args.output / "grand_line_terrain_converted.blend"
    bpy.ops.wm.save_as_mainfile(filepath=str(project))
    bpy.ops.render.render(write_still=True)
    report["project"] = {"file": project.name, "sha256": digest(project)}
    report["preview"] = {"file": "blender_terrain_preview.png",
                         "renderer": "Blender Cycles", "samples": scene.cycles.samples,
                         "width": 1500, "height": 1100}
    report["source_unchanged"] = digest(args.source_hip) == report["source"]["source_sha256"]
    if not report["source_unchanged"]:
        raise RuntimeError("Source HIP unexpectedly changed")
    write_json(args.output / "blender-conversion-report.json", report)
    print(json.dumps(report))


def main():
    arguments = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-hip", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--hython", default=shutil.which("hython"))
    parser.add_argument("--blender", default=shutil.which("blender") or
                        "/Applications/Blender.app/Contents/MacOS/Blender")
    parser.add_argument("--phase", choices=("houdini", "blender"), help=argparse.SUPPRESS)
    args = parser.parse_args(arguments)
    args.source_hip = args.source_hip.expanduser().resolve(strict=True)
    args.output = args.output.expanduser().resolve()
    if args.phase == "houdini":
        houdini_export(args)
    elif args.phase == "blender":
        blender_convert(args)
    else:
        if not args.hython or not Path(args.hython).is_file() or not Path(args.blender).is_file():
            parser.error("Provide installed --hython and --blender executables")
        args.output.mkdir(parents=True, exist_ok=False)
        common = ["--source-hip", str(args.source_hip), "--output", str(args.output)]
        script = str(Path(__file__).resolve())
        subprocess.run([args.hython, script, *common, "--phase", "houdini"], check=True)
        subprocess.run([args.blender, "--background", "--factory-startup", "--python-exit-code", "1",
                        "--python", script, "--", *common, "--phase", "blender"], check=True)
        print(f"Converted terrain and verification report: {args.output}")


if __name__ == "__main__":
    main()
