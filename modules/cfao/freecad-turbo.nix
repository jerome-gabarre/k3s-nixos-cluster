{ config, lib, pkgs, ... }:

let
  cfg = config.services.freecadTurbo;
  freecadPkg = pkgs.callPackage ../../pkgs/freecad-turbo { };
  isWorkstation = cfg.role == "workstation";
in
{
  options.services.freecadTurbo = {
    enable = lib.mkEnableOption "Architecture CFAO FreeCAD Turbo (P/E-Cores + Spool RAM + Worker)";

    role = lib.mkOption {
      type = lib.types.enum [ "worker-headless" "workstation" ];
      default = "worker-headless";
      description = "worker-headless: binaire Rust seul (~4 Mo) pour noeud PXE K3s | workstation: GUI FreeCAD + CalculiX/Gmsh + démon E-Cores";
    };

    dispatcherUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://freecad-cam-farm-dispatcher.cfao-system.svc.cluster.local:50051";
      description = "Endpoint du dispatcher K3s (bascule locale automatique si injoignable)";
    };

    persistentProjectDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/freecad-projects";
      description = "Répertoire persistant recevant les lots compressés zstd depuis /dev/shm";
    };
  };

  config = lib.mkIf cfg.enable {
    # Sur worker-pxe (worker-headless), seul le binaire Rust (~4 Mo) est inclus dans l'image PXE
    environment.systemPackages =
      [ freecadPkg.freecadRsEngine ]
      ++ lib.optionals isWorkstation [ freecadPkg.freecadNativeLauncher ];

    systemd.tmpfiles.rules = [
      "L+ /run/freecad-turbo-bin - - - - ${freecadPkg.freecadRsEngine}/bin"
      "d /dev/shm/freecad-global-spool 1777 root root -"
      "d /dev/shm/freecad-global-spool/queue 1777 root root -"
      "d /dev/shm/freecad-global-spool/results 1777 root root -"
      "d ${cfg.persistentProjectDir} 0775 root users -"
    ];

    # Le démon systemd local n'est activé que sur un poste de travail (sur K3s, le pod freecad-farm gère le worker)
    systemd.services.freecad-local-worker = lib.mkIf isWorkstation {
      description = "FreeCAD Turbo Local Pull-Worker & Async RAM Spooler (E-Cores)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        EnvironmentFile = "-/run/os-topology/env";
        ExecStart = ''
          ${freecadPkg.freecadRsEngine}/bin/freecad-turbo-worker \
            --mode=hybrid-local \
            --spool-dir=/dev/shm/freecad-global-spool \
            --persist-dir=${cfg.persistentProjectDir} \
            --dispatcher=${cfg.dispatcherUrl}
        '';
        Restart = "always";
        RestartSec = "500ms";
        StartLimitIntervalSec = 0;
        Nice = 15;
        CPUSchedulingPolicy = "idle";
        IOSchedulingClass = "idle";
        MemoryHigh = "60%";
        MemoryMax = "75%";
        TasksMax = 512;
        PrivateTmp = false;
        ProtectSystem = "strict";
        ReadWritePaths = [ "/dev/shm" cfg.persistentProjectDir ];
        LogRateLimitIntervalSec = 0;
      };
    };
  };
}
