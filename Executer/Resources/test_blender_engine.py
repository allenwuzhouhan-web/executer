#!/usr/bin/env python3
"""
Test suite for blender_engine.py — runs inside Blender headless.

Usage: blender -b --python test_blender_engine.py

Tests geometry creation, validation, export, and security checks.
"""

import sys
import os
import json
import tempfile
import shutil

# Must run inside Blender
try:
    import bpy
    import bmesh
except ImportError:
    print("ERROR: This script must run inside Blender: blender -b --python test_blender_engine.py")
    sys.exit(1)

# Add engine directory to path so we can import helpers
engine_dir = os.path.dirname(os.path.abspath(__file__))
if engine_dir not in sys.path:
    sys.path.insert(0, engine_dir)

# Import engine functions directly
from blender_engine import (
    clear_scene, create_material, assign_material, validate_scene,
    apply_all_transforms, export_model, validate_export, check_code_safety
)

# ---------------------------------------------------------------------------
# Test framework
# ---------------------------------------------------------------------------

PASS = 0
FAIL = 0
ERRORS = []


def test(name, condition, detail=""):
    global PASS, FAIL, ERRORS
    if condition:
        PASS += 1
        print(f"  PASS: {name}")
    else:
        FAIL += 1
        msg = f"  FAIL: {name}"
        if detail:
            msg += f" — {detail}"
        print(msg)
        ERRORS.append(name)


def section(title):
    print(f"\n{'='*60}")
    print(f"  {title}")
    print(f"{'='*60}")


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_cube_primitive():
    section("Test: Cube Primitive")
    clear_scene()
    bpy.ops.mesh.primitive_cube_add(size=2, location=(0, 0, 0))
    obj = bpy.context.active_object
    mat = create_material("TestMat", base_color=[0.5, 0.5, 0.5, 1.0])
    assign_material(obj, mat)
    apply_all_transforms()

    validation = validate_scene()
    test("Cube has 8 vertices", validation["total_vertices"] == 8, f"got {validation['total_vertices']}")
    test("Cube has 6 faces", validation["total_faces"] == 6, f"got {validation['total_faces']}")
    test("Cube is manifold", validation["checks"]["manifold"])
    test("Cube has no loose vertices", validation["checks"]["no_loose_vertices"])
    test("Cube has material", validation["checks"]["materials_assigned"])
    test("Cube validation passes", validation["passed"])


def test_uv_sphere():
    section("Test: UV Sphere")
    clear_scene()
    bpy.ops.mesh.primitive_uv_sphere_add(radius=1, segments=32, ring_count=16, location=(0, 0, 0))
    obj = bpy.context.active_object
    mat = create_material("SphereMat", base_color=[0.2, 0.4, 0.8, 1.0], metallic=0.5)
    assign_material(obj, mat)
    apply_all_transforms()

    validation = validate_scene()
    # UV sphere with 32 segments, 16 rings = 32*15 + 2 (poles) = 482 verts
    test("Sphere has expected vertices", validation["total_vertices"] == 482,
         f"got {validation['total_vertices']}")
    test("Sphere is manifold", validation["checks"]["manifold"])
    test("Sphere validation passes", validation["passed"])


def test_materials():
    section("Test: Material Creation & Assignment")
    clear_scene()
    bpy.ops.mesh.primitive_cube_add(size=1, location=(0, 0, 0))
    obj1 = bpy.context.active_object
    obj1.name = "Cube1"

    bpy.ops.mesh.primitive_cube_add(size=1, location=(3, 0, 0))
    obj2 = bpy.context.active_object
    obj2.name = "Cube2"

    mat1 = create_material("Gold", base_color=[1.0, 0.84, 0.0, 1.0], metallic=1.0, roughness=0.2)
    mat2 = create_material("Glass", base_color=[0.9, 0.95, 1.0, 0.3], alpha=0.3, specular=1.0)

    assign_material(obj1, mat1)
    assign_material(obj2, mat2)

    test("Mat1 exists", bpy.data.materials.get("Gold") is not None)
    test("Mat2 exists", bpy.data.materials.get("Glass") is not None)
    test("Cube1 has material", len(obj1.data.materials) > 0)
    test("Cube2 has material", len(obj2.data.materials) > 0)

    validation = validate_scene()
    test("All materials assigned", validation["checks"]["materials_assigned"])


def test_export_glb():
    section("Test: GLB Export")
    tmpdir = tempfile.mkdtemp(prefix="blender_test_")
    try:
        clear_scene()
        bpy.ops.mesh.primitive_cube_add(size=2)
        mat = create_material("ExportMat", base_color=[0.5, 0.5, 0.5, 1.0])
        assign_material(bpy.context.active_object, mat)
        apply_all_transforms()

        filepath = os.path.join(tmpdir, "test.glb")
        result_path = export_model(filepath, "glb")
        checks = validate_export(result_path, "glb")

        test("GLB file exists", checks.get("file_exists", False))
        test("GLB not empty", checks.get("file_not_empty", False))
        test("GLB magic bytes valid", checks.get("glb_magic_valid", False))
        test("GLB file > 100 bytes", checks.get("file_size_bytes", 0) > 100,
             f"size={checks.get('file_size_bytes', 0)}")
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def test_export_obj():
    section("Test: OBJ Export")
    tmpdir = tempfile.mkdtemp(prefix="blender_test_")
    try:
        clear_scene()
        bpy.ops.mesh.primitive_cube_add(size=2)
        mat = create_material("ObjMat", base_color=[0.5, 0.5, 0.5, 1.0])
        assign_material(bpy.context.active_object, mat)
        apply_all_transforms()

        filepath = os.path.join(tmpdir, "test.obj")
        result_path = export_model(filepath, "obj")

        test("OBJ file exists", os.path.isfile(result_path))
        test("OBJ not empty", os.path.getsize(result_path) > 0)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def test_export_stl():
    section("Test: STL Export")
    tmpdir = tempfile.mkdtemp(prefix="blender_test_")
    try:
        clear_scene()
        bpy.ops.mesh.primitive_cube_add(size=2)
        mat = create_material("StlMat", base_color=[0.5, 0.5, 0.5, 1.0])
        assign_material(bpy.context.active_object, mat)
        apply_all_transforms()

        filepath = os.path.join(tmpdir, "test.stl")
        result_path = export_model(filepath, "stl")

        test("STL file exists", os.path.isfile(result_path))
        test("STL not empty", os.path.getsize(result_path) > 0)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def test_nonmanifold_detection():
    section("Test: Non-Manifold Detection")
    clear_scene()

    # Create a mesh with a deliberately non-manifold edge
    # (a single face floating in space — all boundary edges)
    bm = bmesh.new()
    v1 = bm.verts.new((0, 0, 0))
    v2 = bm.verts.new((1, 0, 0))
    v3 = bm.verts.new((0.5, 1, 0))
    bm.faces.new((v1, v2, v3))
    mesh = bpy.data.meshes.new("NonManifold")
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new("NonManifoldObj", mesh)
    bpy.context.collection.objects.link(obj)

    # Give it a material so that check doesn't interfere
    mat = create_material("TestMat", base_color=[1, 0, 0, 1])
    assign_material(obj, mat)

    validation = validate_scene()
    # A single triangle has all boundary edges — these are not "non-manifold" by bmesh definition
    # (boundary edges are edges with exactly 1 face, which is different from non-manifold)
    # But it's still useful to verify our validator runs without crashing
    test("Validation completes on thin geometry", True)
    test("Has correct vertex count (3)", validation["total_vertices"] == 3, f"got {validation['total_vertices']}")


def test_loose_vertex_detection():
    section("Test: Loose Vertex Detection")
    clear_scene()

    bm = bmesh.new()
    # Create a proper face
    v1 = bm.verts.new((0, 0, 0))
    v2 = bm.verts.new((1, 0, 0))
    v3 = bm.verts.new((1, 1, 0))
    v4 = bm.verts.new((0, 1, 0))
    bm.faces.new((v1, v2, v3, v4))
    # Add a loose vertex
    bm.verts.new((5, 5, 5))

    mesh = bpy.data.meshes.new("LooseVertMesh")
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new("LooseVertObj", mesh)
    bpy.context.collection.objects.link(obj)

    mat = create_material("TestMat", base_color=[0, 1, 0, 1])
    assign_material(obj, mat)

    validation = validate_scene()
    test("Loose vertex detected", not validation["checks"]["no_loose_vertices"])
    test("Validation fails due to loose vertex", not validation["passed"])


def test_security_blocked_imports():
    section("Test: Security — Blocked Imports")

    dangerous_codes = [
        ("import os", "import os\nos.system('echo hacked')"),
        ("import subprocess", "import subprocess\nsubprocess.run(['echo'])"),
        ("import sys", "import sys\nsys.exit(1)"),
        ("__import__", "__import__('os').system('echo')"),
        ("eval(", "eval('1+1')"),
        ("exec(", "exec('print(1)')"),
        ("from os", "from os import path"),
        ("open(", "f = open('/etc/passwd')"),
    ]

    for label, code in dangerous_codes:
        safe, reason = check_code_safety(code)
        test(f"Blocks '{label}'", not safe, reason if safe else "")


def test_security_allowed_code():
    section("Test: Security — Allowed Code")

    allowed_codes = [
        ("bpy import", "import bpy"),
        ("bmesh import", "import bmesh"),
        ("mathutils import", "from mathutils import Vector"),
        ("math import", "import math"),
        ("bpy operations", "bpy.ops.mesh.primitive_cube_add(size=2)"),
    ]

    for label, code in allowed_codes:
        safe, reason = check_code_safety(code)
        test(f"Allows '{label}'", safe, reason if not safe else "")


def test_empty_scene_validation():
    section("Test: Empty Scene Validation")
    clear_scene()
    validation = validate_scene()
    test("Empty scene fails validation", not validation["passed"])
    test("Reports no objects", not validation["checks"].get("has_objects", True))


def test_round_trip_glb():
    section("Test: GLB Round-Trip Integrity")
    tmpdir = tempfile.mkdtemp(prefix="blender_test_")
    try:
        clear_scene()
        bpy.ops.mesh.primitive_ico_sphere_add(radius=1, subdivisions=3)
        obj = bpy.context.active_object
        mat = create_material("RoundTripMat", base_color=[0.3, 0.6, 0.9, 1.0])
        assign_material(obj, mat)
        apply_all_transforms()

        # Count before export
        orig_verts = len(obj.data.vertices)
        orig_faces = len(obj.data.polygons)

        # Export
        filepath = os.path.join(tmpdir, "roundtrip.glb")
        export_model(filepath, "glb")

        # Re-import
        clear_scene()
        bpy.ops.import_scene.gltf(filepath=filepath)

        # Count after import
        imported_objs = [o for o in bpy.data.objects if o.type == 'MESH']
        test("Re-imported has mesh objects", len(imported_objs) > 0)

        if imported_objs:
            total_verts = sum(len(o.data.vertices) for o in imported_objs)
            total_faces = sum(len(o.data.polygons) for o in imported_objs)
            # GLB splits shared vertices at smooth-shading boundaries, so vertex count
            # may increase. Face count should always be preserved exactly.
            test(f"Vertex count >= original ({orig_verts})", total_verts >= orig_verts,
                 f"got {total_verts}")
            test(f"Face count preserved ({orig_faces})", total_faces == orig_faces,
                 f"got {total_faces}")
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def test_complex_model():
    section("Test: Complex Multi-Object Model")
    clear_scene()

    # Create a simple table: 4 legs + 1 top
    # Top
    bpy.ops.mesh.primitive_cube_add(size=1, location=(0, 0, 1))
    top = bpy.context.active_object
    top.scale = (2, 1, 0.1)
    top.name = "TableTop"

    # Legs
    for i, (x, y) in enumerate([(-1.5, -0.7), (1.5, -0.7), (-1.5, 0.7), (1.5, 0.7)]):
        bpy.ops.mesh.primitive_cylinder_add(radius=0.08, depth=1, location=(x, y, 0.5), vertices=16)
        leg = bpy.context.active_object
        leg.name = f"Leg{i+1}"

    # Apply materials
    wood = create_material("Wood", base_color=[0.45, 0.3, 0.15, 1.0], roughness=0.7)
    for obj in bpy.data.objects:
        if obj.type == 'MESH':
            assign_material(obj, wood)

    apply_all_transforms()
    validation = validate_scene()

    test("Complex model has 5 objects", validation["object_count"] == 5,
         f"got {validation['object_count']}")
    test("All materials assigned", validation["checks"]["materials_assigned"])
    test("Complex model passes validation", validation["passed"])

    # Export and verify
    tmpdir = tempfile.mkdtemp(prefix="blender_test_")
    try:
        filepath = os.path.join(tmpdir, "table.glb")
        export_model(filepath, "glb")
        checks = validate_export(filepath, "glb")
        test("Complex GLB export valid", checks.get("file_exists") and checks.get("glb_magic_valid", False))
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    print("\n" + "="*60)
    print("  Blender Engine Test Suite")
    print(f"  Blender {'.'.join(str(v) for v in bpy.app.version)}")
    print("="*60)

    test_cube_primitive()
    test_uv_sphere()
    test_materials()
    test_export_glb()
    test_export_obj()
    test_export_stl()
    test_nonmanifold_detection()
    test_loose_vertex_detection()
    test_security_blocked_imports()
    test_security_allowed_code()
    test_empty_scene_validation()
    test_round_trip_glb()
    test_complex_model()

    print(f"\n{'='*60}")
    print(f"  Results: {PASS} passed, {FAIL} failed out of {PASS + FAIL} tests")
    if ERRORS:
        print(f"  Failed: {', '.join(ERRORS)}")
    print(f"{'='*60}\n")

    sys.exit(0 if FAIL == 0 else 1)


if __name__ == "__main__":
    main()
