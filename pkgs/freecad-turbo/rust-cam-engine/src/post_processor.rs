use crate::ClPoint;
use rayon::prelude::*;

pub const SUPPORTED_DIALECTS: &[&str] = &[
    "SIEMENS_840D",
    "SINUMERIK_ONE",
    "HEIDENHAIN_TNC640",
    "HEIDENHAIN_TNC7",
    "FANUC_31I",
    "FANUC_0I",
    "MAZAK_SMOOTH",
    "OKUMA_OSP",
    "HAAS_NGC",
    "HURCO_WINMAX",
    "DMG_CELOS",
    "NUM_FLEXIUM",
    "FAGOR_8065",
    "BROTHER_SPEEDIO",
    "CITIZEN_SWISS",
    "LINUXCNC",
    "GRBL_HAL",
    "FLUIDNC",
    "MACH4",
    "KLIPPER",
];

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum FormatStyle {
    IsoStandard,
    HeidenhainKlartext,
    WireEdmUv,
    KlipperAdditive,
}

#[derive(Clone, Debug)]
pub struct CncDialectProfile {
    pub name: &'static str,
    pub header: &'static str,
    pub tcp_on: &'static str,
    pub tcp_off: &'static str,
    pub footer: &'static str,
    pub style: FormatStyle,
}

impl CncDialectProfile {
    pub fn resolve(dialect: &str) -> Self {
        match dialect.to_uppercase().as_str() {
            "SIEMENS_840D" | "SINUMERIK_ONE" | "DMG_CELOS" => Self {
                name: "SIEMENS_SINUMERIK",
                header: "G90 G710 G17 G54\nCYCLE832(0.005, 1, 1)\nCOMPCAD",
                tcp_on: "TRAORI(1)",
                tcp_off: "TRAFOOF",
                footer: "M5\nM30",
                style: FormatStyle::IsoStandard,
            },
            "HEIDENHAIN_TNC640" | "HEIDENHAIN_TNC7" => Self {
                name: "HEIDENHAIN_KLARTEXT",
                header: "0 BEGIN PGM FREECAD_TURBO MM\n1 TOOL CALL 1 Z S12000\n2 CYCL DEF 32.0 TOLERANCE\n3 CYCL DEF 32.1 T0.005",
                tcp_on: "4 FUNCTION TCPM F TCP AXIS POS PATHCTRL AXIS",
                tcp_off: "5 FUNCTION RESET TCPM",
                footer: "999999 END PGM FREECAD_TURBO MM",
                style: FormatStyle::HeidenhainKlartext,
            },
            "FANUC_31I" | "FANUC_0I" | "BROTHER_SPEEDIO" => Self {
                name: "FANUC_HIGH_SPEED",
                header: "O1000 (FREECAD TURBO CNC)\nG90 G21 G17 G40 G80 G54\nG05.1 Q1",
                tcp_on: "G43.4 H1",
                tcp_off: "G49\nG05.1 Q0",
                footer: "M05\nG91 G28 Z0.0\nM30",
                style: FormatStyle::IsoStandard,
            },
            "MAZAK_SMOOTH" => Self {
                name: "MAZAK_SMOOTH_X",
                header: "O1000 (MAZATROL SMOOTH G-CODE)\nG90 G21 G17 G40 G80 G54\nG61.1",
                tcp_on: "G43.4 H1",
                tcp_off: "G49\nG64",
                footer: "M05\nG28 U0. W0.\nM30",
                style: FormatStyle::IsoStandard,
            },
            "OKUMA_OSP" => Self {
                name: "OKUMA_OSP_P300",
                header: "G90 G21 G17 G40 G80 G15 H1\nG131 J2 E0.005",
                tcp_on: "G169 H1",
                tcp_off: "G170\nG130",
                footer: "M05\nM02",
                style: FormatStyle::IsoStandard,
            },
            "HAAS_NGC" => Self {
                name: "HAAS_NEXT_GEN",
                header: "%\nO01000 (HAAS NGC TURBO)\nG90 G21 G17 G40 G80 G54\nG187 P3 E0.005",
                tcp_on: "G234 H1",
                tcp_off: "G49",
                footer: "M05\nG28 G91 Z0.\nM30\n%",
                style: FormatStyle::IsoStandard,
            },
            "HURCO_WINMAX" => Self {
                name: "HURCO_ISNC_ULTIMOTION",
                header: "%\nG90 G21 G17 G40 G80 G54\nG05.3 P1",
                tcp_on: "G43.4 H1",
                tcp_off: "G49",
                footer: "M05\nM02",
                style: FormatStyle::IsoStandard,
            },
            "NUM_FLEXIUM" => Self {
                name: "NUM_FLEXIUM_PLUS",
                header: "%1000\nG90 G71 G17 G40 G54\nG107",
                tcp_on: "G151 S1",
                tcp_off: "G151 S0",
                footer: "M05\nM02",
                style: FormatStyle::IsoStandard,
            },
            "FAGOR_8065" => Self {
                name: "FAGOR_8065_HSC",
                header: "%FREECAD_TURBO,MX\nG90 G71 G17 G40 G54\n#HSC ON [CONTERROR 0.005]",
                tcp_on: "#RTCP ON",
                tcp_off: "#RTCP OFF\n#HSC OFF",
                footer: "M05\nM30",
                style: FormatStyle::IsoStandard,
            },
            "CITIZEN_SWISS" | "STAR_SWISS" => Self {
                name: "SWISS_SLIDING_HEADSTOCK",
                header: "$1\nG90 G21 G18 G40 G99\nM18 C0",
                tcp_on: "G12.1",
                tcp_off: "G13.1",
                footer: "M05\nM50\nM02",
                style: FormatStyle::IsoStandard,
            },
            "WIRE_EDM" | "SODICK_EDM" | "AGIECHARMILLES_EDM" => Self {
                name: "WIRE_EDM_4AXIS_XYUV",
                header: "G90 G21 G92 X0. Y0. U0. V0.\nT91 (WIRE ON)",
                tcp_on: "G51 (TAPER UV SYNC ON)",
                tcp_off: "G50 (TAPER UV OFF)",
                footer: "T90 (WIRE CUT)\nM02",
                style: FormatStyle::WireEdmUv,
            },
            "KLIPPER" | "MARLIN" => Self {
                name: "KLIPPER_HYBRID_CNC",
                header: "G90\nG21\nM204 S3000",
                tcp_on: "; TCP_SIM_ON",
                tcp_off: "; TCP_SIM_OFF",
                footer: "M400\nM84",
                style: FormatStyle::KlipperAdditive,
            },
            "GRBL_HAL" | "FLUIDNC" | "MACH4" => Self {
                name: "GRBL_FLUIDNC_ISO",
                header: "G90 G21 G17 G94",
                tcp_on: "(RTCP-VIRTUAL)",
                tcp_off: "(RTCP-END)",
                footer: "M5\nM30",
                style: FormatStyle::IsoStandard,
            },
            _ => Self {
                name: "LINUXCNC_RS274NGC",
                header: "G90 G21 G17 G40 G49 G64 P0.005 Q0.001",
                tcp_on: "(LINUXCNC 5X KINEMATICS)",
                tcp_off: "(END KINEMATICS)",
                footer: "M5\nM2",
                style: FormatStyle::IsoStandard,
            },
        }
    }
}

#[inline(always)]
fn solve_inverse_kinematics_ac(i: f64, j: f64, k: f64) -> (f64, f64) {
    let clamped_k = k.clamp(-1.0, 1.0);
    let a_rad = clamped_k.acos();
    let c_rad = if a_rad.abs() > 1e-6 { i.atan2(-j) } else { 0.0 };
    (a_rad.to_degrees(), c_rad.to_degrees())
}

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

pub fn compile_cldata_to_cnc(points: &[ClPoint], dialect: &str, arc_tol: f64) -> String {
    let profile = CncDialectProfile::resolve(dialect);
    if points.is_empty() {
        return format!("{}\n{}\n", profile.header, profile.footer);
    }

    let body_chunks: Vec<String> = points
        .par_chunks(4096)
        .map(|chunk| {
            let mut buf = String::with_capacity(chunk.len() * 48);
            let mut idx = 0;
            while idx < chunk.len() {
                if profile.style == FormatStyle::IsoStandard && idx + 2 < chunk.len() {
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
                match profile.style {
                    FormatStyle::HeidenhainKlartext => {
                        let (a_deg, c_deg) = solve_inverse_kinematics_ac(p.i, p.j, p.k);
                        let feed_str = if p.rapid { "FMAX".to_string() } else { format!("F{:.0}", p.feed) };
                        buf.push_str(&format!(
                            "L X{:+.4} Y{:+.4} Z{:+.4} A{:+.3} C{:+.3} {}\n",
                            p.x, p.y, p.z, a_deg, c_deg, feed_str
                        ));
                    }
                    FormatStyle::WireEdmUv => {
                        let g_cmd = if p.rapid { "G0" } else { "G1" };
                        buf.push_str(&format!(
                            "{} X{:.4} Y{:.4} U{:.4} V{:.4} F{:.1}\n",
                            g_cmd, p.x, p.y, p.i, p.j, p.feed
                        ));
                    }
                    FormatStyle::KlipperAdditive => {
                        let g_cmd = if p.rapid { "G0" } else { "G1" };
                        buf.push_str(&format!(
                            "{} X{:.4} Y{:.4} Z{:.4} F{:.1}\n",
                            g_cmd, p.x, p.y, p.z, p.feed
                        ));
                    }
                    FormatStyle::IsoStandard => {
                        let (a_deg, c_deg) = solve_inverse_kinematics_ac(p.i, p.j, p.k);
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
