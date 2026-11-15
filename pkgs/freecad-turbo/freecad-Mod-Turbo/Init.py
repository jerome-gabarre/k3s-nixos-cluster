import json
import os
import time
import FreeCAD
import freecad_rs_universal


def _extract_mesh_and_bounds(part_shape, linear_deflection=0.02):
    verts, facets = part_shape.tessellate(linear_deflection)
    flat_vertices = []
    triangles = []
    for tri in facets:
        v0, v1, v2 = verts[tri[0]], verts[tri[1]], verts[tri[2]]
        p0 = [float(v0.x), float(v0.y), float(v0.z)]
        p1 = [float(v1.x), float(v1.y), float(v1.z)]
        p2 = [float(v2.x), float(v2.y), float(v2.z)]
        flat_vertices.extend(p0 + p1 + p2)
        triangles.append({
            "v0": p0,
            "v1": p1,
            "v2": p2,
            "aabb_min": [min(p0[0], p1[0], p2[0]), min(p0[1], p1[1], p2[1]), min(p0[2], p1[2], p2[2])],
            "aabb_max": [max(p0[0], p1[0], p2[0]), max(p0[1], p1[1], p2[1]), max(p0[2], p1[2], p2[2])],
        })

    bb = part_shape.BoundBox
    bounds_min = [float(bb.XMin), float(bb.YMin), float(bb.ZMin)]
    bounds_max = [float(bb.XMax), float(bb.YMax), float(bb.ZMax)]
    return flat_vertices, triangles, bounds_min, bounds_max


def generate_turbo_cnc_job(
    part_shape,
    mode="SURFACE_5AXIS",
    dialect="SIEMENS_840D",
    linear_deflection=0.01,
    tool_diameter=6.0,
    stepover=1.5,
    stepdown=2.0,
    feedrate=2400.0,
    arc_tolerance=0.005,
):
    flat_vertices, _, bounds_min, bounds_max = _extract_mesh_and_bounds(
        part_shape, linear_deflection
    )
    return freecad_rs_universal.compute_cam_and_post(
        mode,
        dialect,
        flat_vertices,
        bounds_min,
        bounds_max,
        float(tool_diameter),
        float(stepover),
        float(stepdown),
        float(feedrate),
        float(arc_tolerance),
    )


def run_turbo_fem(
    part_shape,
    mesh_size_mm=2.5,
    young_modulus_mpa=210000.0,
    poisson_ratio=0.30,
    density_kg_m3=7850.0,
    yield_strength_mpa=355.0,
    total_force_n=1500.0,
    linear_deflection=0.05,
):
    flat_vertices, _, bounds_min, bounds_max = _extract_mesh_and_bounds(
        part_shape, linear_deflection
    )
    raw_json = freecad_rs_universal.compute_fem_analysis(
        flat_vertices,
        bounds_min,
        bounds_max,
        float(mesh_size_mm),
        float(young_modulus_mpa),
        float(poisson_ratio),
        float(density_kg_m3),
        float(yield_strength_mpa),
        float(total_force_n),
    )
    return json.loads(raw_json)


def dispatch_turbo_batch(
    part_shape,
    job_id=None,
    mode="SURFACE_5AXIS",
    dialect="SIEMENS_840D",
    linear_deflection=0.02,
    tool_diameter=6.0,
    stepover=1.5,
    stepdown=2.0,
    feedrate=2400.0,
    arc_tolerance=0.005,
    total_force_n=1500.0,
    spool_dir="/dev/shm/freecad-global-spool",
):
    """
    Publie un lot CFAO ou FEM compressé en zstd dans le spool RAM (/dev/shm)
    pour exécution à flux tiré par le démon worker (E-Cores locaux ou ferme K3s).
    """
    import backports.zstd as zstd

    if job_id is None:
        job_id = f"job-{int(time.time() * 1000)}"

    _, triangles, bounds_min, bounds_max = _extract_mesh_and_bounds(
        part_shape, linear_deflection
    )
    payload = {
        "job_id": job_id,
        "mode": mode,
        "dialect": dialect,
        "triangles": triangles,
        "bounds_min": bounds_min,
        "bounds_max": bounds_max,
        "tool_diameter": float(tool_diameter),
        "stepover": float(stepover),
        "stepdown": float(stepdown),
        "feedrate": float(feedrate),
        "arc_tolerance": float(arc_tolerance),
        "total_force_n": float(total_force_n),
    }

    queue_dir = os.path.join(spool_dir, "queue")
    os.makedirs(queue_dir, exist_ok=True)
    tmp_path = os.path.join(queue_dir, f"{job_id}.tmp")
    zst_path = os.path.join(queue_dir, f"{job_id}.zst")

    compressed = zstd.compress(json.dumps(payload).encode("utf-8"), 3)
    with open(tmp_path, "wb") as f:
        f.write(compressed)
    os.replace(tmp_path, zst_path)
    return job_id


def nest_parts_2d(part_sizes, sheet_width=2000.0, sheet_height=1000.0, kerf_spacing=2.0):
    return freecad_rs_universal.compute_nesting_2d(
        part_sizes, float(sheet_width), float(sheet_height), float(kerf_spacing)
    )


def supported_modes():
    return freecad_rs_universal.list_cam_modes()


def supported_dialects():
    return freecad_rs_universal.list_cnc_dialects()


FreeCAD.Turbo = generate_turbo_cnc_job
FreeCAD.TurboFEM = run_turbo_fem
FreeCAD.TurboDispatch = dispatch_turbo_batch
FreeCAD.TurboNest2D = nest_parts_2d
FreeCAD.TurboModes = supported_modes
FreeCAD.TurboDialects = supported_dialects
FreeCAD.Console.PrintLog(
    '{"level":"INFO","module":"FreeCADTurbo","status":"Universal CAM + FEM PCG + Hybrid Spool Dispatcher Ready"}\n'
)
