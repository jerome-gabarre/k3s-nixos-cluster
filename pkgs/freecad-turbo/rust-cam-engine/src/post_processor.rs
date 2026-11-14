use crate::ClPoint;
use rayon::prelude::*;

#[derive(Clone, Debug)]
pub struct CncDialectProfile {
    pub name: &'static str,
    pub header: &'static str,
    pub tcp_on: &'static str,
    pub tcp_off: &'static str,
    pub footer: &'static str,
    pub use_heidenhain_klartext: bool,
}

impl CncDialectProfile {
    pub fn resolve(dialect: &str) -> Self {
        match dialect.to_uppercase().as_str() {
            "SIEMENS_840D" | "SINUMERIK_ONE" => Self {
                name: "SIEMENS_SINUMERIK",
                header: "G90 G710 G17 G54\nCYCLE832(0.01, 1, 1)",
                tcp_on: "TRAORI(1)",
                tcp_off: "TRAFOOF",
                footer: "M5\nM30",
                use_heidenhain_klartext: false,
            },
            "HEIDENHAIN_TNC640" | "HEIDENHAIN_TNC7" => Self {
                name: "HEIDENHAIN_KLARTEXT",
                header: "0 BEGIN PGM FREECAD_TURBO MM\n1 TOOL CALL 1 Z S12000",
                tcp_on: "2 FUNCTION TCPM F TCP AXIS POS PATHCTRL AXIS",
                tcp_off: "3 FUNCTION RESET TCPM",
                footer: "999999 END PGM FREECAD_TURBO MM",
                use_heidenhain_klartext: true,
            },
            "FANUC_31I" | "MAZAK_SMOOTH" | "OKUMA_OSP" | "HAAS_NGC" => Self {
                name: "ISO_INDUSTRIAL_TCP",
                header: "G90 G21 G17 G40 G80 G54",
                tcp_on: "G43.4 H1",
                tcp_off: "G49",
                footer: "M05\nG91 G28 Z0.0\nM30",
                use_heidenhain_klartext: false,
            },
            _ => Self {
                // LinuxCNC, GRBL, grblHAL, FluidNC, Mach4, Klipper
                name: "UNIVERSAL_RS274NGC",
                header: "G90 G21 G17 G64 P0.01",
                tcp_on: "(TCP-ACTIVE)",
                tcp_off: "(TCP-OFF)",
                footer: "M5\nM2",
                use_heidenhain_klartext: false,
            },
        }
    }
}

/// Cinématique inverse universelle : Vecteur (I,J,K) -> Angles rotatifs (A, C) en degrés
#[inline(always)]
fn solve_inverse_kinematics_ac(i: f64, j: f64, k: f64) -> (f64, f64) {
    let clamped_k = k.clamp(-1.0, 1.0);
    let a_rad = clamped_k.acos();
    let c_rad = if a_rad.abs() > 1e-6 { i.atan2(-j) } else { 0.0 };
    (a_rad.to_degrees(), c_rad.to_degrees())
}

/// Détection et fusion de 3 points colinéaires ou circulaires en arc G2/G3 dans le plan XY
#[inline(always)]
fn try_fit_xy_arc(p0: &ClPoint, p1: &ClPoint, p2: &ClPoint, tol: f64) -> Option<(bool, f64, f64)> {
    if p0.rapid || p1.rapid || p2.rapid || (p0.z - p2.z).abs() > tol {
        return None;
    }
    let d = 2.0 * (p0.x * (p1.y - p2.y) + p1.x * (p2.y - p0.y) + p2.x * (p0.y - p1.y));
    if d.abs() < 1e-6 {
        return None;
    }
    let ux = ((p0.x * p0.x + p0.y * p0.y) * (p1.y - p2.y)
        + (p1.x * p1.x + p1.y * p1.y) * (p2.y - p0.y)
        + (p2.x * p2.x + p2.y * p2.y) * (p0.y - p1.y))
        / d;
    let uy = ((p0.x * p0.x + p0.y * p0.y) * (p2.x - p1.x)
        + (p1.x * p1.x + p1.y * p1.y) * (p0.x - p2.x)
        + (p2.x * p2.x + p2.y * p2.y) * (p1.x - p0.x))
        / d;

    let r = (p0.x - ux).hypot(p0.y - uy);
    if r > 5000.0 || r < 0.05 {
        return None;
    }
    let mid_x = 0.5 * (p0.x + p2.x);
    let mid_y = 0.5 * (p0.y + p2.y);
    let sagitta = (r - (mid_x - ux).hypot(mid_y - uy)).abs();
    if sagitta > tol * 50.0 || sagitta < tol * 0.1 {
        return None;
    }
    let cross = (p1.x - p0.x) * (p2.y - p0.y) - (p1.y - p0.y) * (p2.x - p0.x);
    let clockwise = cross < 0.0;
    Some((clockwise, ux - p0.x, uy - p0.y))
}

/// Compilation parallèle par lots de CL-Data vers le dialecte CNC cible
pub fn compile_cldata_to_cnc(points: &[ClPoint], dialect: &str, arc_tol: f64) -> String {
    let profile = CncDialectProfile::resolve(dialect);
    if points.is_empty() {
        return format!("{}\n{}\n", profile.header, profile.footer);
    }

    // Formatage parallèle par lots de 4096 points pour saturer tous les threads RAM
    let body_chunks: Vec<String> = points
        .par_chunks(4096)
        .map(|chunk| {
            let mut buf = String::with_capacity(chunk.len() * 48);
            let mut idx = 0;
            while idx < chunk.len() {
                if !profile.use_heidenhain_klartext && idx + 2 < chunk.len() {
                    if let Some((cw, i_off, j_off)) =
                        try_fit_xy_arc(&chunk[idx], &chunk[idx + 1], &chunk[idx + 2], arc_tol)
                    {
                        let p2 = &chunk[idx + 2];
                        let g_arc = if cw { "G2" } else { "G3" };
                        buf.push_str(&format!(
                            "{} X{:.4} Y{:.4} Z{:.4} I{:.4} J{:.4} F{:.1}\n",
                            g_arc, p2.x, p2.y, p2.z, i_off, j_off, p2.feed
                        ));
                        idx += 3;
                        continue;
                    }
                }

                let p = &chunk[idx];
                let (a_deg, c_deg) = solve_inverse_kinematics_ac(p.i, p.j, p.k);

                if profile.use_heidenhain_klartext {
                    let feed_str = if p.rapid { "FMAX".to_string() } else { format!("F{:.0}", p.feed) };
                    buf.push_str(&format!(
                        "L X{:+.4} Y{:+.4} Z{:+.4} A{:+.3} C{:+.3} {}\n",
                        p.x, p.y, p.z, a_deg, c_deg, feed_str
                    ));
                } else {
                    let g_cmd = if p.rapid { "G0" } else { "G1" };
                    if a_deg.abs() > 1e-3 || c_deg.abs() > 1e-3 {
                        buf.push_str(&format!(
                            "{} X{:.4} Y{:.4} Z{:.4} A{:.3} C{:.3} F{:.1}\n",
                            g_cmd, p.x, p.y, p.z, a_deg, c_deg, p.feed
                        ));
                    } else {
                        buf.push_str(&format!(
                            "{} X{:.4} Y{:.4} Z{:.4} F{:.1}\n",
                            g_cmd, p.x, p.y, p.z, p.feed
                        ));
                    }
                }
                idx += 1;
            }
            buf
        })
        .collect();

    let mut out = String::with_capacity(body_chunks.iter().map(|s| s.len()).sum::<usize>() + 256);
    out.push_str(profile.header);
    out.push('\n');
    out.push_str(profile.tcp_on);
    out.push('\n');
    for c in body_chunks {
        out.push_str(&c);
    }
    out.push_str(profile.tcp_off);
    out.push('\n');
    out.push_str(profile.footer);
    out.push('\n');
    out
}