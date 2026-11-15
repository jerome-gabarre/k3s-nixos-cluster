use freecad_rs_universal::{fem_solver, generate_universal_toolpath, post_processor, Triangle3D};
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

extern "C" fn handle_shutdown_signal(_sig: libc::c_int) {
    unsafe {
        libc::_exit(0);
    }
}

#[derive(Deserialize)]
struct BatchJob {
    job_id: String,
    mode: String,
    #[serde(default)]
    dialect: String,
    triangles: Vec<Triangle3D>,
    bounds_min: [f64; 3],
    bounds_max: [f64; 3],
    #[serde(default = "default_tool_diam")]
    tool_diameter: f64,
    #[serde(default = "default_step")]
    stepover: f64,
    #[serde(default = "default_step")]
    stepdown: f64,
    #[serde(default = "default_feed")]
    feedrate: f64,
    #[serde(default = "default_tol")]
    arc_tolerance: f64,
    #[serde(default = "default_young")]
    young_modulus_mpa: f64,
    #[serde(default = "default_poisson")]
    poisson_ratio: f64,
    #[serde(default = "default_density")]
    density_kg_m3: f64,
    #[serde(default = "default_yield")]
    yield_strength_mpa: f64,
    #[serde(default = "default_force")]
    total_force_n: f64,
}

fn default_tool_diam() -> f64 { 6.0 }
fn default_step() -> f64 { 1.5 }
fn default_feed() -> f64 { 2400.0 }
fn default_tol() -> f64 { 0.005 }
fn default_young() -> f64 { 210000.0 }
fn default_poisson() -> f64 { 0.30 }
fn default_density() -> f64 { 7850.0 }
fn default_yield() -> f64 { 355.0 }
fn default_force() -> f64 { 1000.0 }

#[derive(Serialize)]
struct BatchResult {
    job_id: String,
    status: String,
    point_count: usize,
    output_zstd_path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    fem_summary: Option<fem_solver::FemAnalysisResult>,
}

fn current_rss_megabytes() -> usize {
    if let Ok(statm) = fs::read_to_string("/proc/self/statm") {
        if let Some(rss_pages) = statm.split_whitespace().nth(1) {
            if let Ok(pages) = rss_pages.parse::<usize>() {
                return (pages * 4096) / (1024 * 1024);
            }
        }
    }
    0
}

fn wait_for_spool_event(dir: &Path) {
    unsafe {
        let fd = libc::inotify_init1(libc::IN_CLOEXEC);
        if fd < 0 {
            return;
        }
        let c_path = std::ffi::CString::new(dir.to_string_lossy().as_bytes()).unwrap();
        let _wd = libc::inotify_add_watch(fd, c_path.as_ptr(), libc::IN_CLOSE_WRITE | libc::IN_MOVED_TO);
        let mut buf = [0u8; 256];
        let _ = libc::read(fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len());
        libc::close(fd);
    }
}

fn process_pending_jobs(spool_dir: &Path, persist_dir: &Path) {
    let queue_dir = spool_dir.join("queue");
    let results_dir = spool_dir.join("results");
    let _ = fs::create_dir_all(&queue_dir);
    let _ = fs::create_dir_all(&results_dir);
    let _ = fs::create_dir_all(persist_dir);

    let entries = match fs::read_dir(&queue_dir) {
        Ok(e) => e,
        Err(_) => return,
    };

    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("zst") {
            continue;
        }

        if let Ok(compressed_bytes) = fs::read(&path) {
            if let Ok(json_bytes) = zstd::decode_all(&compressed_bytes[..]) {
                if let Ok(job) = serde_json::from_slice::<BatchJob>(&json_bytes) {
                    if job.mode.eq_ignore_ascii_case("FEM_STATIC_MODAL") {
                        let fem_res = fem_solver::solve_fem_and_generate_inp(
                            &job.triangles,
                            job.bounds_min,
                            job.bounds_max,
                            job.stepover.max(1.0),
                            job.young_modulus_mpa,
                            job.poisson_ratio,
                            job.density_kg_m3,
                            job.yield_strength_mpa,
                            job.total_force_n,
                        );
                        let out_file = persist_dir.join(format!("{}.inp.zst", job.job_id));
                        if let Ok(compressed_inp) = zstd::encode_all(fem_res.calculix_inp_preview.as_bytes(), 3) {
                            let _ = fs::write(&out_file, compressed_inp);
                        }
                        let res = BatchResult {
                            job_id: job.job_id.clone(),
                            status: "COMPLETED_FEM".to_string(),
                            point_count: fem_res.node_count,
                            output_zstd_path: out_file.to_string_lossy().to_string(),
                            fem_summary: Some(fem_res),
                        };
                        let res_path = results_dir.join(format!("{}.json", job.job_id));
                        if let Ok(mut f) = fs::File::create(&res_path) {
                            let _ = f.write_all(serde_json::to_string(&res).unwrap_or_default().as_bytes());
                        }
                        println!(
                            "{{\"level\":\"INFO\",\"component\":\"freecad-turbo-worker\",\"type\":\"FEM\",\"job_id\":\"{}\",\"rss_mb\":{}}}",
                            job.job_id,
                            current_rss_megabytes()
                        );
                    } else {
                        let cl_points = generate_universal_toolpath(
                            &job.mode,
                            &job.triangles,
                            job.bounds_min,
                            job.bounds_max,
                            job.tool_diameter,
                            job.stepover,
                            job.stepdown,
                            job.feedrate,
                        );
                        let gcode = post_processor::compile_cldata_to_cnc(
                            &cl_points,
                            &job.dialect,
                            job.arc_tolerance,
                        );

                        let out_file = persist_dir.join(format!("{}.nc.zst", job.job_id));
                        if let Ok(compressed_gcode) = zstd::encode_all(gcode.as_bytes(), 3) {
                            let _ = fs::write(&out_file, compressed_gcode);
                        }

                        let res = BatchResult {
                            job_id: job.job_id.clone(),
                            status: "COMPLETED_CAM".to_string(),
                            point_count: cl_points.len(),
                            output_zstd_path: out_file.to_string_lossy().to_string(),
                            fem_summary: None,
                        };

                        let res_path = results_dir.join(format!("{}.json", job.job_id));
                        if let Ok(mut f) = fs::File::create(&res_path) {
                            let _ = f.write_all(serde_json::to_string(&res).unwrap_or_default().as_bytes());
                        }

                        println!(
                            "{{\"level\":\"INFO\",\"component\":\"freecad-turbo-worker\",\"type\":\"CAM\",\"job_id\":\"{}\",\"points\":{},\"rss_mb\":{}}}",
                            job.job_id,
                            cl_points.len(),
                            current_rss_megabytes()
                        );
                    }
                }
            }
        }
        let _ = fs::remove_file(&path);

        if current_rss_megabytes() > 1400 {
            println!("{{\"level\":\"WARN\",\"msg\":\"Seuil RSS atteint, recyclage proactif du worker\"}}");
            std::process::exit(0);
        }
    }
}

fn main() {
    unsafe {
        let handler_ptr = handle_shutdown_signal as *const () as libc::sighandler_t;
        libc::signal(libc::SIGTERM, handler_ptr);
        libc::signal(libc::SIGINT, handler_ptr);
    }

    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--healthcheck" || a == "--ready") {
        std::process::exit(0);
    }

    let spool_dir = PathBuf::from("/dev/shm/freecad-global-spool");
    let persist_dir = PathBuf::from("/var/lib/freecad-projects");
    let queue_dir = spool_dir.join("queue");
    let _ = fs::create_dir_all(&queue_dir);

    println!("{{\"level\":\"INFO\",\"msg\":\"Démarrage FreeCAD Turbo Pull-Worker (CAM + FEM, inotify, SIGTERM)\"}}");
    loop {
        process_pending_jobs(&spool_dir, &persist_dir);
        wait_for_spool_event(&queue_dir);
    }
}
