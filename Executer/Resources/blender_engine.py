#!/usr/bin/env python3
"""
Executer Blender Engine — Creates 3D models from JSON spec with embedded bpy code.

Usage: blender -b --python blender_engine.py -- --spec spec.json --output model.glb

The spec JSON contains:
  - filename: output filename
  - bpy_code: LLM-generated geometry code (executed in a sandboxed namespace)
  - materials: array of {name, base_color, roughness, metallic, ...}
  - export_format: glb (default), obj, fbx, stl
  - validation: {ensure_manifold, ensure_normals, min_vertices, max_vertices}
"""

import sys
import json
import re
import traceback

# bpy is only available inside Blender's Python
import bpy
import bmesh
import mathutils
from mathutils import Vector, Matrix, Euler, Quaternion, Color
import math


# ---------------------------------------------------------------------------
# CLI argument parsing (args come after "--" in blender invocation)
# ---------------------------------------------------------------------------

def parse_args():
    argv = sys.argv
    # Everything after "--" is ours
    if "--" in argv:
        argv = argv[argv.index("--") + 1:]
    else:
        argv = []

    args = {}
    i = 0
    while i < len(argv):
        if argv[i] == "--spec" and i + 1 < len(argv):
            args["spec"] = argv[i + 1]
            i += 2
        elif argv[i] == "--output" and i + 1 < len(argv):
            args["output"] = argv[i + 1]
            i += 2
        else:
            i += 1
    return args


# ---------------------------------------------------------------------------
# Security: reject dangerous code patterns in bpy_code
# ---------------------------------------------------------------------------

BLOCKED_PATTERNS = [
    r'\bimport\s+os\b',
    r'\bimport\s+subprocess\b',
    r'\bimport\s+sys\b',
    r'\bimport\s+socket\b',
    r'\bimport\s+http\b',
    r'\bimport\s+urllib\b',
    r'\bimport\s+shutil\b',
    r'\bimport\s+pathlib\b',
    r'\bfrom\s+os\b',
    r'\bfrom\s+subprocess\b',
    r'\bfrom\s+sys\b',
    r'\bfrom\s+socket\b',
    r'\bfrom\s+http\b',
    r'\bfrom\s+urllib\b',
    r'\bfrom\s+shutil\b',
    r'\b__import__\s*\(',
    r'\beval\s*\(',
    r'\bexec\s*\(',
    r'\bcompile\s*\(',
    r'\bglobals\s*\(',
    r'\bopen\s*\(',
]


def check_code_safety(code):
    """Returns (safe: bool, reason: str)."""
    for pattern in BLOCKED_PATTERNS:
        match = re.search(pattern, code)
        if match:
            return False, f"Blocked pattern detected: '{match.group()}'. Only bpy/bmesh/mathutils imports are allowed."
    return True, ""


# ---------------------------------------------------------------------------
# Scene helpers
# ---------------------------------------------------------------------------

def clear_scene():
    """Remove all default objects (cube, camera, light)."""
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)
    # Clean orphan data
    for block in bpy.data.meshes:
        if block.users == 0:
            bpy.data.meshes.remove(block)
    for block in bpy.data.materials:
        if block.users == 0:
            bpy.data.materials.remove(block)
    for block in bpy.data.cameras:
        if block.users == 0:
            bpy.data.cameras.remove(block)
    for block in bpy.data.lights:
        if block.users == 0:
            bpy.data.lights.remove(block)


def create_material(name, base_color=None, roughness=0.5, metallic=0.0,
                    emission_color=None, emission_strength=0.0, alpha=1.0,
                    specular=0.5):
    """Create a Principled BSDF material and return it.

    Args:
        name: Material name
        base_color: [R, G, B, A] with values 0-1. Default white.
        roughness: 0.0 (glossy) to 1.0 (rough). Default 0.5.
        metallic: 0.0 (dielectric) to 1.0 (metallic). Default 0.0.
        emission_color: [R, G, B, A] for glow. Default None (no emission).
        emission_strength: Emission intensity. Default 0.0.
        alpha: Opacity 0-1. Default 1.0 (opaque).
        specular: Specular intensity. Default 0.5.
    """
    mat = bpy.data.materials.new(name=name)
    mat.use_nodes = True
    nodes = mat.node_tree.nodes
    bsdf = nodes.get("Principled BSDF")
    if bsdf is None:
        # Blender 4.x may name it differently
        for node in nodes:
            if node.type == 'BSDF_PRINCIPLED':
                bsdf = node
                break
    if bsdf is None:
        return mat

    if base_color:
        bc = list(base_color)
        if len(bc) == 3:
            bc.append(1.0)
        bsdf.inputs["Base Color"].default_value = bc

    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic

    # Specular — handle Blender 4.x rename to "Specular IOR Level"
    if "Specular IOR Level" in bsdf.inputs:
        bsdf.inputs["Specular IOR Level"].default_value = specular
    elif "Specular" in bsdf.inputs:
        bsdf.inputs["Specular"].default_value = specular

    if emission_color and emission_strength > 0:
        ec = list(emission_color)
        if len(ec) == 3:
            ec.append(1.0)
        if "Emission Color" in bsdf.inputs:
            bsdf.inputs["Emission Color"].default_value = ec
        elif "Emission" in bsdf.inputs:
            bsdf.inputs["Emission"].default_value = ec
        bsdf.inputs["Emission Strength"].default_value = emission_strength

    if alpha < 1.0:
        mat.blend_method = 'BLEND' if hasattr(mat, 'blend_method') else None
        bsdf.inputs["Alpha"].default_value = alpha

    return mat


def assign_material(obj, mat):
    """Assign a material to an object."""
    if obj.data is not None:
        if len(obj.data.materials) == 0:
            obj.data.materials.append(mat)
        else:
            obj.data.materials[0] = mat


# ---------------------------------------------------------------------------
# Validation suite
# ---------------------------------------------------------------------------

def validate_scene():
    """Run all validation checks on mesh objects in the scene. Returns dict."""
    results = {
        "passed": True,
        "checks": {},
        "warnings": [],
        "total_vertices": 0,
        "total_faces": 0,
        "object_count": 0,
    }

    mesh_objects = [obj for obj in bpy.data.objects if obj.type == 'MESH']
    results["object_count"] = len(mesh_objects)

    if len(mesh_objects) == 0:
        results["passed"] = False
        results["checks"]["has_objects"] = False
        results["warnings"].append("No mesh objects in scene")
        return results

    results["checks"]["has_objects"] = True
    all_manifold = True
    all_normals_ok = True
    all_no_loose_verts = True
    all_no_loose_edges = True
    all_no_zero_area = True
    all_materials_ok = True
    all_mesh_valid = True

    for obj in mesh_objects:
        mesh = obj.data

        # mesh.validate()
        had_errors = mesh.validate(verbose=False)
        if had_errors:
            all_mesh_valid = False
            results["warnings"].append(f"'{obj.name}': mesh.validate() fixed errors")

        # Create bmesh for detailed checks
        bm = bmesh.new()
        bm.from_mesh(mesh)
        bm.edges.ensure_lookup_table()
        bm.verts.ensure_lookup_table()
        bm.faces.ensure_lookup_table()

        results["total_vertices"] += len(bm.verts)
        results["total_faces"] += len(bm.faces)

        # Non-manifold edges
        non_manifold = [e for e in bm.edges if not e.is_manifold and not e.is_boundary]
        if non_manifold:
            all_manifold = False
            results["warnings"].append(f"'{obj.name}': {len(non_manifold)} non-manifold edges")

        # Loose vertices (not connected to any edge)
        loose_verts = [v for v in bm.verts if not v.link_edges]
        if loose_verts:
            all_no_loose_verts = False
            results["warnings"].append(f"'{obj.name}': {len(loose_verts)} loose vertices")

        # Loose edges (not connected to any face)
        loose_edges = [e for e in bm.edges if not e.link_faces]
        if loose_edges:
            all_no_loose_edges = False
            results["warnings"].append(f"'{obj.name}': {len(loose_edges)} loose edges")

        # Zero-area faces
        zero_faces = [f for f in bm.faces if f.calc_area() < 1e-7]
        if zero_faces:
            all_no_zero_area = False
            results["warnings"].append(f"'{obj.name}': {len(zero_faces)} zero-area faces")

        # Recalculate normals (fix if needed)
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        bm.to_mesh(mesh)

        bm.free()

        # Material check
        if len(obj.data.materials) == 0:
            all_materials_ok = False
            results["warnings"].append(f"'{obj.name}': no material assigned")
        else:
            for i, slot in enumerate(obj.data.materials):
                if slot is None:
                    all_materials_ok = False
                    results["warnings"].append(f"'{obj.name}': material slot {i} is None")

    results["checks"]["mesh_valid"] = all_mesh_valid
    results["checks"]["manifold"] = all_manifold
    results["checks"]["normals_consistent"] = all_normals_ok
    results["checks"]["no_loose_vertices"] = all_no_loose_verts
    results["checks"]["no_loose_edges"] = all_no_loose_edges
    results["checks"]["no_zero_area_faces"] = all_no_zero_area
    results["checks"]["materials_assigned"] = all_materials_ok
    results["checks"]["vertex_count"] = results["total_vertices"]
    results["checks"]["face_count"] = results["total_faces"]

    # Overall pass: critical checks must all be true
    critical = ["manifold", "normals_consistent", "no_loose_vertices", "no_zero_area_faces", "materials_assigned"]
    results["passed"] = all(results["checks"].get(c, True) for c in critical)

    return results


# ---------------------------------------------------------------------------
# Apply transforms
# ---------------------------------------------------------------------------

def apply_all_transforms():
    """Apply location, rotation, and scale to all objects."""
    for obj in bpy.data.objects:
        if obj.type == 'MESH':
            bpy.context.view_layer.objects.active = obj
            obj.select_set(True)
    if any(obj.select_get() for obj in bpy.data.objects):
        bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    bpy.ops.object.select_all(action='DESELECT')


# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------

def export_model(filepath, fmt="glb"):
    """Export the scene to the given format."""
    fmt = fmt.lower()

    # Ensure directory exists
    import os
    dirpath = os.path.dirname(filepath)
    if dirpath:
        os.makedirs(dirpath, exist_ok=True)

    if fmt == "glb":
        if not filepath.lower().endswith(".glb"):
            filepath += ".glb"
        bpy.ops.export_scene.gltf(filepath=filepath, export_format='GLB')
    elif fmt == "gltf":
        if not filepath.lower().endswith(".gltf"):
            filepath += ".gltf"
        bpy.ops.export_scene.gltf(filepath=filepath, export_format='GLTF_SEPARATE')
    elif fmt == "obj":
        if not filepath.lower().endswith(".obj"):
            filepath += ".obj"
        # Blender 4.x uses wm.obj_export, 3.x uses export_scene.obj
        if bpy.app.version >= (4, 0, 0):
            bpy.ops.wm.obj_export(filepath=filepath)
        else:
            bpy.ops.export_scene.obj(filepath=filepath)
    elif fmt == "fbx":
        if not filepath.lower().endswith(".fbx"):
            filepath += ".fbx"
        bpy.ops.export_scene.fbx(filepath=filepath)
    elif fmt == "stl":
        if not filepath.lower().endswith(".stl"):
            filepath += ".stl"
        if bpy.app.version >= (4, 0, 0):
            bpy.ops.wm.stl_export(filepath=filepath)
        else:
            bpy.ops.export_mesh.stl(filepath=filepath)
    else:
        raise ValueError(f"Unsupported export format: {fmt}. Use glb, gltf, obj, fbx, or stl.")

    return filepath


def validate_export(filepath, fmt="glb"):
    """Post-export validation: file exists, size > 0, magic bytes for GLB."""
    import os
    checks = {}

    checks["file_exists"] = os.path.isfile(filepath)
    if not checks["file_exists"]:
        return checks

    size = os.path.getsize(filepath)
    checks["file_size_bytes"] = size
    checks["file_not_empty"] = size > 0

    if fmt == "glb" and size >= 4:
        with open(filepath, "rb") as f:
            magic = f.read(4)
        checks["glb_magic_valid"] = magic == b'glTF'

    checks["file_size_warning"] = "large file (>50MB)" if size > 50_000_000 else None

    return checks


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    args = parse_args()
    result = {"success": False}

    if "spec" not in args:
        result["error"] = "Missing --spec argument"
        print(json.dumps(result))
        return

    if "output" not in args:
        result["error"] = "Missing --output argument"
        print(json.dumps(result))
        return

    # Load spec
    try:
        with open(args["spec"], "r", encoding="utf-8") as f:
            spec = json.load(f)
    except Exception as e:
        result["error"] = f"Failed to load spec JSON: {e}"
        print(json.dumps(result))
        return

    # Validate spec structure
    bpy_code = spec.get("bpy_code", "")
    if not bpy_code:
        result["error"] = "Spec must contain 'bpy_code' with geometry creation code."
        print(json.dumps(result))
        return

    # Security check
    safe, reason = check_code_safety(bpy_code)
    if not safe:
        result["error"] = f"Security: {reason}"
        print(json.dumps(result))
        return

    # Determine output path and format
    export_format = spec.get("export_format", "glb").lower()
    output_path = args["output"]

    # Clear scene
    clear_scene()

    # Execute LLM-generated bpy code in controlled namespace
    namespace = {
        "bpy": bpy,
        "bmesh": bmesh,
        "mathutils": mathutils,
        "Vector": Vector,
        "Matrix": Matrix,
        "Euler": Euler,
        "Quaternion": Quaternion,
        "Color": Color,
        "math": math,
        "create_material": create_material,
        "assign_material": assign_material,
    }
    try:
        exec(bpy_code, namespace)
    except Exception as e:
        tb = traceback.format_exc()
        result["error"] = f"bpy_code execution failed: {e}"
        result["traceback"] = tb
        print(json.dumps(result))
        return

    # Apply structured materials from spec
    materials_spec = spec.get("materials", [])
    for mat_def in materials_spec:
        mat_name = mat_def.get("name", "Material")
        mat = create_material(
            name=mat_name,
            base_color=mat_def.get("base_color"),
            roughness=mat_def.get("roughness", 0.5),
            metallic=mat_def.get("metallic", 0.0),
            emission_color=mat_def.get("emission_color"),
            emission_strength=mat_def.get("emission_strength", 0.0),
            alpha=mat_def.get("alpha", 1.0),
            specular=mat_def.get("specular", 0.5),
        )
        # Assign to any unassigned mesh objects
        for obj in bpy.data.objects:
            if obj.type == 'MESH' and len(obj.data.materials) == 0:
                assign_material(obj, mat)

    # Ensure every mesh has at least a default material
    default_mat = None
    for obj in bpy.data.objects:
        if obj.type == 'MESH' and len(obj.data.materials) == 0:
            if default_mat is None:
                default_mat = create_material("Default", base_color=[0.8, 0.8, 0.8, 1.0])
            assign_material(obj, default_mat)

    # Apply transforms
    apply_all_transforms()

    # Validate
    validation_spec = spec.get("validation", {})
    validation = validate_scene()

    # Check vertex bounds if specified
    min_verts = validation_spec.get("min_vertices")
    max_verts = validation_spec.get("max_vertices")
    if min_verts and validation["total_vertices"] < min_verts:
        validation["warnings"].append(f"Vertex count {validation['total_vertices']} below minimum {min_verts}")
    if max_verts and validation["total_vertices"] > max_verts:
        validation["warnings"].append(f"Vertex count {validation['total_vertices']} above maximum {max_verts}")

    # Export
    try:
        final_path = export_model(output_path, export_format)
    except Exception as e:
        result["error"] = f"Export failed: {e}"
        result["validation"] = validation
        print(json.dumps(result))
        return

    # Post-export validation
    export_checks = validate_export(final_path, export_format)
    validation["checks"]["export_file_valid"] = export_checks.get("file_exists", False) and export_checks.get("file_not_empty", False)
    if export_format == "glb":
        validation["checks"]["glb_magic_valid"] = export_checks.get("glb_magic_valid", False)
    validation["checks"]["file_size_bytes"] = export_checks.get("file_size_bytes", 0)

    # Build result
    result["success"] = validation["passed"] and validation["checks"].get("export_file_valid", False)
    result["path"] = final_path
    result["validation"] = validation
    result["stats"] = {
        "vertices": validation["total_vertices"],
        "faces": validation["total_faces"],
        "objects": validation["object_count"],
        "file_size_bytes": export_checks.get("file_size_bytes", 0),
        "export_format": export_format,
        "blender_version": ".".join(str(v) for v in bpy.app.version),
    }

    print(json.dumps(result))


if __name__ == "__main__":
    main()
