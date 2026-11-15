pub mod fem_solver;
pub mod post_processor;

use pyo3::prelude::*;
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use std::f64::consts::PI;

#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
pub struct ClPoint {
    pub x: f64,
    pub y: f64,
    pub z: f64,
    pub i: f64,
    pub j: f64,
    pub k: f64,
    pub feed: f64,
    pub rapid: bool,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
pub struct Triangle3D {
    pub v0: [f64; 3],
    pub v1: [f64; 3],
    pub v2: [f64; 3],
    pub aabb_min: [f64; 3],
    pub aabb_max: [f64; 3],
}

impl Triangle3D {
    pub fn from_vertices(v0: [f64; 3], v1: [f64; 3], v2: [f64; 3]) -> Self {
        let aabb_min = [
            v0[0].min(v1[0]).min(v2[0]),
            v0[1].min(v1[1]).min(v2[1]),
            v0[2].min(v1[2]).min(v2[2]),
        ];
        let aabb_max = [
            v0[0].max(v1[0]).max(v2[0]),
            v0[1].max(v1[1]).max(v2[1]),
            v0[2].max(v1[2]).max(v2[2]),
        ];
        Self { v0, v1, v2, aabb_min, aabb_max }
    }
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
pub struct DexelSpan {
    pub min_z: f64,
    pub max_z: f64,
}

pub struct TriDexelGrid {
    pub origin: [f64; 3],
    pub step: f64,
    pub nx: usize,
    pub ny: usize,
    pub z_columns: Vec<Vec<DexelSpan>>,
}

impl TriDexelGrid {
    pub fn build_parallel(triangles: &[Triangle3D], origin: [f64; 3], max_bound: [f64; 3], step: f64) -> Self {
        let nx = (((max_bound[0] - origin[0]) / step).ceil() as usize).max(1);
        let ny = (((max_bound[1] - origin[1]) / step).ceil() as usize).max(1);
        let total_cells = nx * ny;

        let z_columns: Vec<Vec<DexelSpan>> = (0..total_cells)
            .into_par_iter()
            .map(|idx| {
                let ix = idx % nx;
                let iy = idx / nx;
                let px = origin[0] + (ix as f64) * step;
                let py = origin[1] + (iy as f64) * step;

                let mut z_hits = Vec::new();
                for tri in triangles {
                    if px >= tri.aabb_min[0] && px <= tri.aabb_max[0]
                        && py >= tri.aabb_min[1] && py <= tri.aabb_max[1]
                    {
                        if let Some(z) = raycast_z_triangle(px, py, tri) {
                            z_hits.push(z);
                        }
                    }
                }
                z_hits.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));

                let mut spans = Vec::with_capacity(z_hits.len() / 2 + 1);
                let mut chunks = z_hits.chunks_exact(2);
                for pair in &mut chunks {
                    spans.push(DexelSpan { min_z: pair[0], max_z: pair[1] });
                }
                if let Some(&last_z) = chunks.remainder().first() {
                    spans.push(DexelSpan { min_z: origin[2], max_z: last_z });
                }
                spans
            })
            .collect();

        Self { origin, step, nx, ny, z_columns }
    }

    #[inline(always)]
    pub fn sample_cutter_z(&self, x: f64, y: f64, tool_radius: f64, safe_z: f64) -> f64 {
        let r_cells = (tool_radius / self.step).ceil() as isize;
        let cx = ((x - self.origin[0]) / self.step).round() as isize;
        let cy = ((y - self.origin[1]) / self.step).round() as isize;
        let r2 = tool_radius * tool_radius;

        let mut max_contact_z = self.origin[2];
        for dy in -r_cells..=r_cells {
            let iy = cy + dy;
            if iy < 0 || (iy as usize) >= self.ny {
                continue;
            }
            for dx in -r_cells..=r_cells {
                let ix = cx + dx;
                if ix < 0 || (ix as usize) >= self.nx {
                    continue;
                }
                let dist_sq = ((dx * dx + dy * dy) as f64) * self.step * self.step;
                if dist_sq <= r2 {
                    let col = &self.z_columns[(iy as usize) * self.nx + (ix as usize)];
                    for span in col {
                        if span.max_z > max_contact_z {
                            max_contact_z = span.max_z;
                        }
                    }
                }
            }
        }
        max_contact_z.min(safe_z)
    }

    #[inline(always)]
    pub fn sample_normal_and_z(&self, x: f64, y: f64, tool_radius: f64, safe_z: f64) -> (f64, [f64; 3]) {
        let z0 = self.sample_cutter_z(x, y, tool_radius, safe_z);
        let dz_dx = (self.sample_cutter_z(x + self.step, y, tool_radius, safe_z) - z0) / self.step;
        let dz_dy = (self.sample_cutter_z(x, y + self.step, tool_radius, safe_z) - z0) / self.step;
        let norm = (dz_dx * dz_dx + dz_dy * dz_dy + 1.0).sqrt();
        (z0, [-dz_dx / norm, -dz_dy / norm, 1.0 / norm])
    }
}

#[inline(always)]
fn raycast_z_triangle(px: f64, py: f64, tri: &Triangle3D) -> Option<f64> {
    let (x0, y0, z0) = (tri.v0[0], tri.v0[1], tri.v0[2]);
    let (x1, y1, z1) = (tri.v1[0], tri.v1[1], tri.v1[2]);
    let (x2, y2, z2) = (tri.v2[0], tri.v2[1], tri.v2[2]);

    let denom = (y1 - y2) * (x0 - x2) + (x2 - x1) * (y0 - y2);
    if denom.abs() < 1e-12 {
        return None;
    }
    let u = ((y1 - y2) * (px - x2) + (x2 - x1) * (py - y2)) / denom;
    let v = ((y2 - y0) * (px - x2) + (x0 - x2) * (py - y2)) / denom;
    let w = 1.0 - u - v;

    if u >= -1e-7 && v >= -1e-7 && w >= -1e-7 {
        Some(u * z0 + v * z1 + w * z2)
    } else {
        None
    }
}

pub fn generate_universal_toolpath(
    mode: &str,
    triangles: &[Triangle3D],
    bounds_min: [f64; 3],
    bounds_max: [f64; 3],
    tool_diameter: f64,
    stepover: f64,
    stepdown: f64,
    feedrate: f64,
) -> Vec<ClPoint> {
    let tool_radius = tool_diameter * 0.5;
    let safe_z = bounds_max[2] + 10.0;
    let dexel_step = (stepover * 0.25).clamp(0.05, 1.0);
    let grid = TriDexelGrid::build_parallel(triangles, bounds_min, bounds_max, dexel_step);

    match mode.to_uppercase().as_str() {
        "ADAPTIVE_TROCHOIDAL" => {
            let z_levels = (((bounds_max[2] - bounds_min[2]) / stepdown.max(0.2)).ceil() as usize).max(1);
            let trochoid_radius = (stepover * 0.65).max(0.5);
            let pitch = (stepover * 0.4).max(0.2);
            let ny = (((bounds_max[1] - bounds_min[1]) / (stepover * 1.5)).ceil() as usize).max(1);
            let nx = (((bounds_max[0] - bounds_min[0]) / pitch).ceil() as usize).max(1);

            let slices: Vec<Vec<ClPoint>> = (0..z_levels)
                .into_par_iter()
                .map(|iz| {
                    let z_cut = (bounds_max[2] - ((iz + 1) as f64) * stepdown).max(bounds_min[2]);
                    let mut pts = Vec::with_capacity(ny * nx * 4);
                    for iy in 0..=ny {
                        let base_y = bounds_min[1] + (iy as f64) * (stepover * 1.5);
                        pts.push(ClPoint { x: bounds_min[0], y: base_y, z: safe_z, i: 0.0, j: 0.0, k: 1.0, feed: feedrate, rapid: true });
                        for ix in 0..=nx {
                            let cx = bounds_min[0] + (ix as f64) * pitch;
                            let model_z = grid.sample_cutter_z(cx, base_y, tool_radius, safe_z);
                            if z_cut >= model_z {
                                for step_angle in [0.0, PI * 0.5, PI, PI * 1.5] {
                                    let tx = cx + trochoid_radius * step_angle.cos();
                                    let ty = base_y + trochoid_radius * step_angle.sin();
                                    pts.push(ClPoint { x: tx, y: ty, z: z_cut, i: 0.0, j: 0.0, k: 1.0, feed: feedrate, rapid: false });
                                }
                            }
                        }
                    }
                    pts
                })
                .collect();
            slices.into_iter().flatten().collect()
        }
        "WATERLINE_ZLEVEL" => {
            let z_levels = (((bounds_max[2] - bounds_min[2]) / stepdown.max(0.1)).ceil() as usize).max(1);
            let nx = (((bounds_max[0] - bounds_min[0]) / stepover).ceil() as usize).max(1);
            let ny = (((bounds_max[1] - bounds_min[1]) / stepover).ceil() as usize).max(1);

            let contours: Vec<Vec<ClPoint>> = (0..=z_levels)
                .into_par_iter()
                .map(|iz| {
                    let z_target = bounds_max[2] - (iz as f64) * stepdown;
                    let mut ring = Vec::new();
                    for iy in 0..=ny {
                        let y = bounds_min[1] + (iy as f64) * stepover;
                        for ix in 0..=nx {
                            let x = bounds_min[0] + (ix as f64) * stepover;
                            let z_surf = grid.sample_cutter_z(x, y, tool_radius, safe_z);
                            if (z_surf - z_target).abs() <= stepdown * 0.55 {
                                if ring.is_empty() {
                                    ring.push(ClPoint { x, y, z: safe_z, i: 0.0, j: 0.0, k: 1.0, feed: feedrate, rapid: true });
                                }
                                ring.push(ClPoint { x, y, z: z_target, i: 0.0, j: 0.0, k: 1.0, feed: feedrate, rapid: false });
                            }
                        }
                    }
                    ring
                })
                .collect();
            contours.into_iter().flatten().collect()
        }
        "CONSTANT_SCALLOP" => {
            let n_lines = (((bounds_max[1] - bounds_min[1]) / stepover).ceil() as usize).max(1);
            let rows: Vec<Vec<ClPoint>> = (0..=n_lines)
                .into_par_iter()
                .map(|iy| {
                    let y = bounds_min[1] + (iy as f64) * stepover;
                    let mut x = bounds_min[0];
                    let mut row = Vec::new();
                    row.push(ClPoint { x, y, z: safe_z, i: 0.0, j: 0.0, k: 1.0, feed: feedrate, rapid: true });
                    while x <= bounds_max[0] {
                        let (z, norm) = grid.sample_normal_and_z(x, y, tool_radius, safe_z);
                        let cos_slope = norm[2].abs().clamp(0.25, 1.0);
                        row.push(ClPoint { x, y, z, i: 0.0, j: 0.0, k: 1.0, feed: feedrate, rapid: false });
                        x += (stepover * cos_slope).max(0.05);
                    }
                    row
                })
                .collect();
            rows.into_iter().flatten().collect()
        }
        "SWARF_5AXIS" => {
            let nx = (((bounds_max[0] - bounds_min[0]) / (stepover * 0.5)).ceil() as usize).max(1);
            (0..=nx)
                .into_par_iter()
                .map(|ix| {
                    let x = bounds_min[0] + (ix as f64) * (stepover * 0.5);
                    let y = bounds_min[1];
                    let (z, norm) = grid.sample_normal_and_z(x, y, tool_radius, safe_z);
                    let tilt_i = (-norm[1]).clamp(-0.7, 0.7);
                    let tilt_j = (norm[0]).clamp(-0.7, 0.7);
                    let tilt_k = (1.0 - tilt_i * tilt_i - tilt_j * tilt_j).max(0.1).sqrt();
                    ClPoint { x, y, z: z.min(bounds_min[2]), i: tilt_i, j: tilt_j, k: tilt_k, feed: feedrate, rapid: ix == 0 }
                })
                .collect()
        }
        "TURNING_PROFILE" | "MILL_TURN_CYB" => {
            let is_mill_turn = mode.eq_ignore_ascii_case("MILL_TURN_CYB");
            let nz = (((bounds_max[2] - bounds_min[2]) / stepover).ceil() as usize).max(1);
            (0..=nz)
                .into_par_iter()
                .map(|iz| {
                    let z = bounds_max[2] - (iz as f64) * stepover;
                    let mut max_r = 0.0_f64;
                    for t in triangles {
                        if z >= t.aabb_min[2] && z <= t.aabb_max[2] {
                            let r0 = t.v0[0].hypot(t.v0[1]) + tool_radius;
                            let r1 = t.v1[0].hypot(t.v1[1]) + tool_radius;
                            let r2 = t.v2[0].hypot(t.v2[1]) + tool_radius;
                            max_r = max_r.max(r0).max(r1).max(r2);
                        }
                    }
                    let c_angle = if is_mill_turn { (iz as f64) * 0.15 } else { 0.0 };
                    ClPoint {
                        x: max_r * c_angle.cos(),
                        y: max_r * c_angle.sin(),
                        z,
                        i: c_angle.sin(),
                        j: c_angle.cos(),
                        k: 0.0,
                        feed: feedrate,
                        rapid: iz == 0,
                    }
                })
                .collect()
        }
        "WIRE_EDM_4X" => {
            let kerf = tool_radius;
            let taper_uv = stepover * 0.2;
            let z_wire = bounds_min[2];
            vec![
                ClPoint { x: bounds_min[0] - kerf, y: bounds_min[1] - kerf, z: z_wire, i: -taper_uv, j: -taper_uv, k: 1.0, feed: feedrate, rapid: true },
                ClPoint { x: bounds_max[0] + kerf, y: bounds_min[1] - kerf, z: z_wire, i: taper_uv, j: -taper_uv, k: 1.0, feed: feedrate, rapid: false },
                ClPoint { x: bounds_max[0] + kerf, y: bounds_max[1] + kerf, z: z_wire, i: taper_uv, j: taper_uv, k: 1.0, feed: feedrate, rapid: false },
                ClPoint { x: bounds_min[0] - kerf, y: bounds_max[1] + kerf, z: z_wire, i: -taper_uv, j: taper_uv, k: 1.0, feed: feedrate, rapid: false },
                ClPoint { x: bounds_min[0] - kerf, y: bounds_min[1] - kerf, z: z_wire, i: -taper_uv, j: -taper_uv, k: 1.0, feed: feedrate, rapid: false },
            ]
        }
        "CUTTING_2D_EDM" | "CUTTING_2D_KERF" => {
            let kerf = tool_radius;
            let lead_in = (tool_diameter * 1.5).max(2.0);
            let z_cut = bounds_min[2];
            let z_tab = bounds_min[2] + (stepdown * 0.35).min(1.5);
            let mid_x = 0.5 * (bounds_min[0] + bounds_max[0]);
            vec![
                ClPoint { x: bounds_min[0] - kerf - lead_in, y: bounds_min[1] - kerf - lead_in, z: safe_z, i: 0.0, j: 0.0, k: 1.0, feed: feedrate, rapid: true },
                ClPoint { x: bounds_min[0] - kerf, y: bounds_min[1] - kerf, z: z_cut, i: 0.0, j: 0.0, k: 1.0, feed: feedrate, rapid: false },
                ClPoint { x: mid_x - tool_diameter, y: bounds_min[1] - kerf, z: z_cut, i: 0.0, j: 0.0, k: 1.0, feed: feedrate, rapid: false },
                ClPoint { x: mid_x, y: bounds_min[1] - kerf, z: z_tab, i: 0.0, j: 0.0, k: 1.0, feed: feedrate, rapid: false },
                ClPoint { x: mid_x + tool_diameter, y: bounds_min[1] - kerf, z: z_cut, i: 0.0, j: 0.0, k: 1.0, feed: feedrate, rapid: false },
                ClPoint { x: bounds_max[0] + kerf, y: bounds_min[1] - kerf, z: z_cut, i: 0.0, j: 0.0, k: 1.0, feed: feedrate, rapid: false },
                ClPoint { x: bounds_max[0] + kerf, y: bounds_max[1] + kerf, z: z_cut, i: 0.0, j: 0.0, k: 1.0, feed: feedrate, rapid: false },
                ClPoint { x: bounds_min[0] - kerf, y: bounds_max[1] + kerf, z: z_cut, i: 0.0, j: 0.0, k: 1.0, feed: feedrate, rapid: false },
                ClPoint { x: bounds_min[0] - kerf, y: bounds_min[1] - kerf, z: z_cut, i: 0.0, j: 0.0, k: 1.0, feed: feedrate, rapid: false },
            ]
        }
        "PROBING_GRID" => {
            let mut pts = Vec::with_capacity(27);
            for ix in 0..3 {
                for iy in 0..3 {
                    let px = bounds_min[0] + (ix as f64 + 0.5) * (bounds_max[0] - bounds_min[0]) / 3.0;
                    let py = bounds_min[1] + (iy as f64 + 0.5) * (bounds_max[1] - bounds_min[1]) / 3.0;
                    let pz = grid.sample_cutter_z(px, py, tool_radius, safe_z);
                    pts.push(ClPoint { x: px, y: py, z: safe_z, i: 0.0, j: 0.0, k: 1.0, feed: feedrate, rapid: true });
                    pts.push(ClPoint { x: px, y: py, z: pz, i: 0.0, j: 0.0, k: 1.0, feed: feedrate * 0.2, rapid: false });
                    pts.push(ClPoint { x: px, y: py, z: safe_z, i: 0.0, j: 0.0, k: 1.0, feed: feedrate, rapid: true });
                }
            }
            pts
        }
        _ => {
            let n_lines = (((bounds_max[1] - bounds_min[1]) / stepover).ceil() as usize).max(1);
            let n_steps = (((bounds_max[0] - bounds_min[0]) / (stepover * 0.5)).ceil() as usize).max(1);
            let tilt_5x = mode.eq_ignore_ascii_case("SURFACE_5AXIS");

            let lines: Vec<Vec<ClPoint>> = (0..=n_lines)
                .into_par_iter()
                .map(|iy| {
                    let y = bounds_min[1] + (iy as f64) * stepover;
                    let mut row = Vec::with_capacity(n_steps + 2);
                    let zig_zag_rev = iy % 2 == 1;

                    for ix_raw in 0..=n_steps {
                        let ix = if zig_zag_rev { n_steps - ix_raw } else { ix_raw };
                        let x = bounds_min[0] + (ix as f64) * (stepover * 0.5);
                        let (z_raw, norm) = grid.sample_normal_and_z(x, y, tool_radius, safe_z);
                        let z_surface = z_raw.max(bounds_min[2] - stepdown);

                        let (i, j, k) = if tilt_5x {
                            (norm[0], norm[1], norm[2])
                        } else {
                            (0.0, 0.0, 1.0)
                        };

                        if ix_raw == 0 {
                            row.push(ClPoint { x, y, z: safe_z, i, j, k, feed: feedrate, rapid: true });
                        }
                        row.push(ClPoint { x, y, z: z_surface, i, j, k, feed: feedrate, rapid: false });
                    }
                    row
                })
                .collect();

            lines.into_iter().flatten().collect()
        }
    }
}

#[pyfunction]
fn compute_nesting_2d(
    py: Python<'_>,
    part_sizes: Vec<[f64; 2]>,
    sheet_width: f64,
    sheet_height: f64,
    kerf_spacing: f64,
) -> PyResult<Vec<[f64; 3]>> {
    let placements = py.allow_threads(move || {
        let mut indexed: Vec<(usize, [f64; 2])> = part_sizes.into_iter().enumerate().collect();
        indexed.par_sort_by(|a, b| {
            let area_b = b.1[0] * b.1[1];
            let area_a = a.1[0] * a.1[1];
            area_b.partial_cmp(&area_a).unwrap_or(std::cmp::Ordering::Equal)
        });

        let mut results = vec![[0.0, 0.0, 0.0]; indexed.len()];
        let mut cursor_x = kerf_spacing;
        let mut cursor_y = kerf_spacing;
        let mut row_max_h = 0.0_f64;

        for (orig_idx, [w, h]) in indexed {
            let (pw, ph, rot) = if w > h && (cursor_x + h <= sheet_width) && (cursor_x + w > sheet_width) {
                (h, w, 90.0)
            } else {
                (w, h, 0.0)
            };

            if cursor_x + pw + kerf_spacing > sheet_width {
                cursor_x = kerf_spacing;
                cursor_y += row_max_h + kerf_spacing;
                row_max_h = 0.0;
            }

            if cursor_y + ph + kerf_spacing <= sheet_height {
                results[orig_idx] = [cursor_x, cursor_y, rot];
                cursor_x += pw + kerf_spacing;
                row_max_h = row_max_h.max(ph);
            } else {
                results[orig_idx] = [-1.0, -1.0, 0.0];
            }
        }
        results
    });
    Ok(placements)
}

#[pyfunction]
fn compute_fem_analysis(
    py: Python<'_>,
    flat_vertices: Vec<f64>,
    bounds_min: [f64; 3],
    bounds_max: [f64; 3],
    mesh_size_mm: f64,
    young_modulus_mpa: f64,
    poisson_ratio: f64,
    density_kg_m3: f64,
    yield_strength_mpa: f64,
    total_force_n: f64,
) -> PyResult<String> {
    let json_res = py.allow_threads(move || {
        let triangles: Vec<Triangle3D> = flat_vertices
            .par_chunks_exact(9)
            .map(|c| {
                Triangle3D::from_vertices(
                    [c[0], c[1], c[2]],
                    [c[3], c[4], c[5]],
                    [c[6], c[7], c[8]],
                )
            })
            .collect();

        let res = fem_solver::solve_fem_and_generate_inp(
            &triangles,
            bounds_min,
            bounds_max,
            mesh_size_mm,
            young_modulus_mpa,
            poisson_ratio,
            density_kg_m3,
            yield_strength_mpa,
            total_force_n,
        );
        serde_json::to_string(&res).unwrap_or_default()
    });
    Ok(json_res)
}

#[pyfunction]
fn list_cam_modes() -> Vec<&'static str> {
    vec![
        "ADAPTIVE_TROCHOIDAL",
        "WATERLINE_ZLEVEL",
        "CONSTANT_SCALLOP",
        "SURFACE_3AXIS",
        "SURFACE_5AXIS",
        "SWARF_5AXIS",
        "TURNING_PROFILE",
        "MILL_TURN_CYB",
        "CUTTING_2D_KERF",
        "WIRE_EDM_4X",
        "PROBING_GRID",
    ]
}

#[pyfunction]
fn list_cnc_dialects() -> Vec<&'static str> {
    post_processor::SUPPORTED_DIALECTS.to_vec()
}

#[pyfunction]
fn compute_cam_and_post(
    py: Python<'_>,
    mode: String,
    dialect: String,
    flat_vertices: Vec<f64>,
    bounds_min: [f64; 3],
    bounds_max: [f64; 3],
    tool_diameter: f64,
    stepover: f64,
    stepdown: f64,
    feedrate: f64,
    arc_tolerance: f64,
) -> PyResult<String> {
    let gcode = py.allow_threads(move || {
        let triangles: Vec<Triangle3D> = flat_vertices
            .par_chunks_exact(9)
            .map(|c| {
                Triangle3D::from_vertices(
                    [c[0], c[1], c[2]],
                    [c[3], c[4], c[5]],
                    [c[6], c[7], c[8]],
                )
            })
            .collect();

        let cl_points = generate_universal_toolpath(
            &mode,
            &triangles,
            bounds_min,
            bounds_max,
            tool_diameter,
            stepover,
            stepdown,
            feedrate,
        );

        post_processor::compile_cldata_to_cnc(&cl_points, &dialect, arc_tolerance)
    });

    Ok(gcode)
}

#[pymodule]
fn freecad_rs_universal(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(compute_cam_and_post, m)?)?;
    m.add_function(wrap_pyfunction!(compute_nesting_2d, m)?)?;
    m.add_function(wrap_pyfunction!(compute_fem_analysis, m)?)?;
    m.add_function(wrap_pyfunction!(list_cam_modes, m)?)?;
    m.add_function(wrap_pyfunction!(list_cnc_dialects, m)?)?;
    Ok(())
}
