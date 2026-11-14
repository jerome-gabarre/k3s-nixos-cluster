{ lib
, pkgs
, stdenv
, rustPlatform
, dockerTools
}:

let
  freecadRsEngine = rustPlatform.buildRustPackage {
    pname = "freecad-rs-universal";
    version = "1.0.0";
    src = ./rust-cam-engine;
    cargoLock.lockFile = ./rust-cam-engine/Cargo.lock;

    nativeBuildInputs = [ pkgs.pkg-config ];
    buildInputs = [
      pkgs.python3
      pkgs.zstd
      pkgs.onetbb
    ];

    PYO3_PYTHON = "${pkgs.python3}/bin/python3";

    RUSTFLAGS =
      if stdenv.hostPlatform.isx86_64
      then "-C target-cpu=x86-64-v3 -C codegen-units=1 -C opt-level=3"
      else "-C target-feature=+neon -C codegen-units=1 -C opt-level=3";

    postInstall = ''
      ln -sf $out/lib/libfreecad_rs_universal.so $out/lib/freecad_rs_universal.so
    '';
  };

  freecadTurboBase = pkgs.symlinkJoin {
    name = "freecad-turbo-base";
    paths = [
      pkgs.freecad
      freecadRsEngine
    ];
    postBuild = ''
      mkdir -p $out/Mod/FreeCADTurbo
      {
        echo "import sys"
        echo "if '$out/lib' not in sys.path: sys.path.insert(0, '$out/lib')"
        cat ${./freecad-Mod-Turbo/Init.py}
      } > $out/Mod/FreeCADTurbo/Init.py
      cp $out/Mod/FreeCADTurbo/Init.py $out/lib/FreeCADTurbo.py
      ln -sf ${freecadRsEngine}/lib/libfreecad_rs_universal.so $out/lib/freecad_rs_universal.so
      ln -sf ${freecadRsEngine}/lib/libfreecad_rs_universal.so $out/Mod/FreeCADTurbo/freecad_rs_universal.so
    '';
  };

  freecadNativeLauncher = pkgs.writers.writeRustBin "freecad-turbo" { } ''
    use std::fs;
    use std::os::unix::process::CommandExt;
    use std::process::Command;

    extern "C" {
        fn getuid() -> u32;
        fn getpid() -> u32;
    }

    fn extract_var(content: &str, key: &str) -> Option<String> {
        let prefix = format!("{}=", key);
        for line in content.lines() {
            if let Some(val) = line.strip_prefix(&prefix) {
                return Some(val.trim_matches('"').trim().to_string());
            }
        }
        None
    }

    fn main() {
        let uid = unsafe { getuid() };
        let pid = unsafe { getpid() };
        let spool_dir = format!("/dev/shm/freecad-spool-{}", uid);
        let _ = fs::create_dir_all(format!("{}/cache", spool_dir));
        let _ = fs::create_dir_all(format!("{}/queue", spool_dir));

        let topo = fs::read_to_string("/run/os-topology/env").unwrap_or_default();
        let threads = extract_var(&topo, "OPTIMAL_THREADS").unwrap_or_else(|| "4".to_string());
        let batch_size = extract_var(&topo, "OPTIMAL_BATCH").unwrap_or_else(|| "512".to_string());

        let raw_args: Vec<String> = std::env::args().skip(1).collect();
        let mut args: Vec<String> = vec![
            "-M".to_string(),
            "${freecadTurboBase}/Mod/FreeCADTurbo".to_string(),
            "-P".to_string(),
            "${freecadTurboBase}/lib".to_string(),
        ];

        let mut is_cmd = false;
        let mut i = 0;
        while i < raw_args.len() {
            if raw_args[i] == "-c" && i + 1 < raw_args.len() {
                is_cmd = true;
                let script_path = format!("{}/inline_cmd_{}.py", spool_dir, pid);
                let _ = fs::write(&script_path, format!("{}\nimport os; os._exit(0)\n", raw_args[i + 1]));
                args.push(script_path);
                i += 2;
            } else {
                if raw_args[i] == "--cmd" {
                    is_cmd = true;
                }
                args.push(raw_args[i].clone());
                i += 1;
            }
        }

        let bin = if is_cmd {
            "${pkgs.freecad}/bin/freecadcmd"
        } else {
            "${pkgs.freecad}/bin/FreeCAD"
        };

        let err = Command::new(bin)
            .args(&args)
            .env("TMPDIR", &spool_dir)
            .env("FREECAD_USER_TEMP", &spool_dir)
            .env("FREECAD_TURBO_SPOOL", &spool_dir)
            .env("FREECAD_TURBO_BATCH", &batch_size)
            .env("OMP_NUM_THREADS", &threads)
            .env("TBB_NUM_THREADS", &threads)
            .env("RAYON_NUM_THREADS", &threads)
            .env("MIMALLOC_PAGE_RESET", "1")
            .env("MMGT_OPT", "0")
            .env("MMGT_CLEAR", "0")
            .env("PYTHONMALLOC", "malloc")
            .env("GLIBC_TUNABLES", "glibc.malloc.trim_threshold=65536:glibc.malloc.arena_max=2")
            .exec();

        eprintln!("{{\"level\":\"FATAL\",\"msg\":\"Echec lancement FreeCAD\",\"err\":\"{}\"}}", err);
        std::process::exit(1);
    }
  '';

  freecadWorkerOci = dockerTools.buildLayeredImage {
    name = "freecad-turbo-worker";
    tag = "latest";
    contents = [
      freecadRsEngine
      pkgs.mimalloc
      pkgs.zstd
      pkgs.cacert
    ];
    config = {
      Entrypoint = [ "${freecadRsEngine}/bin/freecad-turbo-worker" ];
    };
  };
in
{
  inherit freecadRsEngine freecadTurboBase freecadNativeLauncher freecadWorkerOci;
}
