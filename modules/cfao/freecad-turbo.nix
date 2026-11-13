{ config, lib, pkgs, ... }:

let
  cfg = config.services.freecadTurbo;
  freecadPkg = pkgs.callPackage ../../pkgs/freecad-turbo { };
in
{
  options.services.freecadTurbo = {
    enable = lib.mkEnableOption "Architecture CFAO FreeCAD Turbo (P/E-Cores + Spool RAM + Worker)";
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
    environment.systemPackages = [
      freecadPkg.freecadNativeLauncher
      freecadPkg.freecadRsEngine
    ];

    # Préparation déclarative des répertoires (Zéro script shell)
    systemd.tmpfiles.rules = [
      "d /dev/shm/freecad-global-spool 1777 root root -"
      "d /dev/shm/freecad-global-spool/queue 1777 root root -"
      "d /dev/shm/freecad-global-spool/results 1777 root root -"
      "d ${cfg.persistentProjectDir} 0775 root users -"
    ];

    # Démon Worker + Spooler RAM épinglé sur les E-Cores (Flux tiré local & Sync zstd)
    systemd.services.freecad-local-worker = {
      description = "FreeCAD Turbo Local Pull-Worker & Async RAM Spooler (E-Cores)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
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

        # Ordonnancement asymétrique : tâche de fond sur cœurs d'efficience
        Nice = 15;
        CPUSchedulingPolicy = "idle";
        IOSchedulingClass = "idle";

        # Plafonds mémoire stricts anti-fuite (Recyclage proactif via cgroups v2)
        MemoryHigh = "60%";
        MemoryMax = "75%";
        TasksMax = 512;

        # Durcissement et accès natif à la RAM partagée
        PrivateTmp = false;
        ProtectSystem = "strict";
        ReadWritePaths = [ "/dev/shm" cfg.persistentProjectDir ];
        LogRateLimitIntervalSec = 0;
      };
    };
  };
}