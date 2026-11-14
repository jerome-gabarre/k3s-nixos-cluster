import FreeCAD
import freecad_rs_universal


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
    verts, facets = part_shape.tessellate(linear_deflection)
    flat_vertices = []
    for tri in facets:
        for idx in tri:
            v = verts[idx]
            flat_vertices.extend([float(v.x), float(v.y), float(v.z)])

    bb = part_shape.BoundBox
    bounds_min = [float(bb.XMin), float(bb.YMin), float(bb.ZMin)]
    bounds_max = [float(bb.XMax), float(bb.YMax), float(bb.ZMax)]

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


FreeCAD.Turbo = generate_turbo_cnc_job
FreeCAD.Console.PrintLog(
    '{"level":"INFO","module":"FreeCADTurbo","status":"Engine Rust SIMD + OCCT oneTBB Ready"}\n'
)
