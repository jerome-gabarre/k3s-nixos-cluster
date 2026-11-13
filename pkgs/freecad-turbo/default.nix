{ lib
, pkgs
, stdenv
, rustPlatform
, dockerTools
}:

let
  # 1. Noyau géométrique OpenCASCADE recompilé avec oneTBB et mimalloc
  occtTurbo = pkgs.opencascade-occt.overrideAttrs (oldAttrs: {
    cmakeFlags = (oldAttrs.cmakeFlags or [ ]) ++ [
      "-DUSE_TBB=ON"
      "-DBUILD_RELEASE_DISABLE_EXCEPTIONS=OFF"
      "-DINSTALL_SAMPLES=OFF"
    ];
    buildInputs = (oldAttrs.buildInputs or [ ]) ++ [
      pkgs.onetbb
      pkgs.mimalloc
    ];
    NIX_CFLAGS_COMPILE = (oldAttrs.NIX_CFLAGS_COMPILE or "") + " -O3 -fno-math-errno";
  });

  # 2. Compilation du moteur Rust (Accélérateur PyO3 + Post-Processeur + Worker Pull)
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
      occtTurbo
    ];

    RUSTFLAGS =
      if stdenv.hostPlatform.isx86_64
      then "-C target-cpu=x86-64-v3 -C codegen-units=1 -C opt-level=3"
      else "-C target-feature=+neon -C codegen-units=1 -C opt-level=3";
  };

  # 3. Compilation de FreeCAD liée à occtTurbo + Patch C++ de parallélisme BRepMesh
  freecadTurboBase = (pkgs.freecad.override {
    opencascade-occt = occtTurbo;
  }).overrideAttrs (oldAttrs: {
    buildInputs = (oldAttrs.buildInputs or [ ]) ++ [
      pkgs.onetbb
      pkgs.mimalloc
      freecadRsEngine
    ];

    postPatch = (oldAttrs.postPatch or "") + ''
      # Force le parallélisme oneTBB global dans OpenCASCADE dès l'initialisation de Part
      sed -i '/initPart()/a BRepMesh_IncrementalMesh::SetParallelDefault(Standard_True);' \
        src/Mod/Part/App/AppPart.cpp || true
    '';

    postInstall = (oldAttrs.postInstall or "") + ''
      mkdir -p $out/Mod/FreeCADTurbo
      cp ${./freecad-Mod-Turbo/Init.py} $out/Mod/FreeCADTurbo/Init.py
      ln -sf ${freecadRsEngine}/lib/libfreecad_rs_universal.so $out/lib/freecad_rs_universal.so
      ln -sf ${freecadRsEngine}/bin/freecad-turbo-worker $out/bin/freecad-turbo-worker
    '';
  });

  # 4. Lanceur natif en Rust (Zéro Bash, lecture directe de /run/os-topology/env)
  freecadNativeLauncher = pkgs.writers.writeRustBin "freecad-turbo" { } ''
    use std::fs;
    use std::os::unix::process::CommandExt;
    use std::process::Command;

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
        let uid = unsafe { libc::getuid() };
        let spool_dir = format!("/dev/shm/freecad-spool-{}", uid);
        let cache_dir = format!("{}/cache", spool_dir);
        let queue_dir = format!("{}/queue", spool_dir);
        let _ = fs::create_dir_all(&cache_dir);
        let _ = fs::create_dir_all(&queue_dir);

        let topo = fs::read_to_string("/run/os-topology/env").unwrap_or_default();
        let threads = extract_var(&topo, "OPTIMAL_THREADS").unwrap_or_else(|| "4".to_string());
        let batch_size = extract_var(&topo, "OPTIMAL_BATCH").unwrap_or_else(|| "512".to_string());

        let args: Vec<String> = std::env::args().skip(1).collect();

        let err = Command::new("${freecadTurboBase}/bin/FreeCAD")
            .args(&args)
            .env("TMPDIR", &spool_dir)
            .env("FREECAD_USER_TEMP", &spool_dir)
            .env("FREECAD_TURBO_SPOOL", &spool_dir)
            .env("FREECAD_TURBO_BATCH", &batch_size)
            .env("PYTHONPATH", "${freecadTurboBase}/lib:${freecadTurboBase}/Mod/FreeCADTurbo")
            .env("OMP_NUM_THREADS", &threads)
            .env("TBB_NUM_THREADS", &threads)
            .env("RAYON_NUM_THREADS", &threads)
            // Éradication stricte des fuites mémoire C++ / OCCT / Python / Glibc
            .env("LD_PRELOAD", "${pkgs.mimalloc}/lib/libmimalloc.so")
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

  # 5. Image OCI minimale pour la ferme K3s
  freecadWorkerOci = dockerTools.buildLayeredImage {
    name = "registry.kube-system.svc.cluster.local:5000/freecad-turbo-worker";
    tag = "latest";
    contents = [
      freecadTurboBase
      freecadRsEngine
      pkgs.mimalloc
      pkgs.zstd
      pkgs.cacert
    ];
    config = {
      Entrypoint = [ "${freecadRsEngine}/bin/freecad-turbo-worker" ];
      Env = [
        "LD_PRELOAD=${pkgs.mimalloc}/lib/libmimalloc.so"
        "MIMALLOC_PAGE_RESET=1"
        "MMGT_OPT=0"
        "MMGT_CLEAR=0"
        "PYTHONMALLOC=malloc"
        "GLIBC_TUNABLES=glibc.malloc.trim_threshold=65536:glibc.malloc.arena_max=2"
        "PYTHONPATH=${freecadTurboBase}/lib:${freecadTurboBase}/Mod/FreeCADTurbo"
        "TMPDIR=/dev/shm"
      ];
    };
  };
in
{
  inherit occtTurbo freecadRsEngine freecadTurboBase freecadNativeLauncher freecadWorkerOci;
}