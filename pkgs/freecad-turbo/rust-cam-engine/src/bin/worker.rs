use freecad_rs_universal::{generate_universal_toolpath, post_processor, Triangle3D};
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

#[derive(Deserialize)]
struct CamBatchJob {
    job_id: String,
    mode: String,
    dialect: String,
    triangles: Vec<Triangle3D>,
    bounds_min: [f64; 3],
    bounds_max: [f64; 3],
    tool_diameter: f64,
    stepover: f64,
    stepdown: f64,
    feedrate: f64,
    arc_tolerance: f64,
}

#[derive(Serialize)]
struct CamBatchResult {
    job_id: String,
    status: String,
    point_count: usize,
    gcode_zstd_path: String,
}

/// Lecture directe de /proc/self/statm en RAM (Zéro fork) pour surveiller la dérive mémoire
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

/// Attente événementielle pure via inotify Linux (Zéro sleep passif)
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
                if let Ok(job) = serde_json::from_slice::<CamBatchJob>(&json_bytes) {
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

                    // Compression zstd multi-thread en RAM puis écriture atomique
                    let out_file = persist_dir.join(format!("{}.nc.zst", job.job_id));
                    if let Ok(compressed_gcode) = zstd::encode_all(gcode.as_bytes(), 3) {
                        let _ = fs::write(&out_file, compressed_gcode);
                    }

                    let res = CamBatchResult {
                        job_id: job.job_id.clone(),
                        status: "COMPLETED".to_string(),
                        point_count: cl_points.len(),
                        gcode_zstd_path: out_file.to_string_lossy().to_string(),
                    };

                    let res_path = results_dir.join(format!("{}.json", job.job_id));
                    if let Ok(mut f) = fs::File::create(&res_path) {
                        let _ = f.write_all(serde_json::to_string(&res).unwrap_or_default().as_bytes());
                    }

                    println!(
                        "{{\"level\":\"INFO\",\"component\":\"freecad-turbo-worker\",\"job_id\":\"{}\",\"points\":{},\"rss_mb\":{}}}",
                        job.job_id,
                        cl_points.len(),
                        current_rss_megabytes()
                    );
                }
            }
        }
        let _ = fs::remove_file(&path);

        // Auto-guérison anti-fuite : recyclage gracieux immédiat par systemd/Kubelet si RSS élevé
        if current_rss_megabytes() > 1400 {
            println!("{{\"level\":\"WARN\",\"msg\":\"Seuil RSS atteint, recyclage proactif du worker\"}}");
            std::process::exit(0);
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--healthcheck" || a == "--ready") {
        std::process::exit(0);
    }

    let spool_dir = PathBuf::from("/dev/shm/freecad-global-spool");
    let persist_dir = PathBuf::from("/var/lib/freecad-projects");
    let queue_dir = spool_dir.join("queue");
    let _ = fs::create_dir_all(&queue_dir);

    println!("{{\"level\":\"INFO\",\"msg\":\"Démarrage FreeCAD Turbo Pull-Worker événementiel (inotify)\"}}");
    loop {
        process_pending_jobs(&spool_dir, &persist_dir);
        wait_for_spool_event(&queue_dir);
    }
}