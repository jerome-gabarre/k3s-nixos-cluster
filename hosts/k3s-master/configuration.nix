# =====================================================================
# ⚠️ RÔLE : CONTROL-PLANE (MASTER - ARM64 / 8GB RAM)
# =====================================================================
# 1. DÉPLOIEMENT OS (NixOS) : Mode "Push" depuis le poste d'administration (`deploy-os`).
# 2. DÉPLOIEMENT APPLICATIF (k3s) : Mode "Pull" GitOps via FluxCD (`git-sync`).
# =====================================================================

{ config, pkgs, lib, clusterIps, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  nixpkgs.hostPlatform = "aarch64-linux";
  networking.hostName = "k3s-master";

  # Désactivation de la documentation locale (zéro surcharge I/O et store)
  documentation = {
    nixos.enable = false;
    doc.enable = false;
    man.enable = false;
    info.enable = false;
  };

  # Noyau Linux LTS standard + contournement ASLR VA 39-bit ARM64
  boot.kernelPackages = lib.mkForce pkgs.linuxPackages;
  boot.loader.grub.enable = false;
  boot.kernel.sysctl."vm.mmap_rnd_bits" = 24;
  boot.kernelParams = [ "cma=64M" ];

  # Injection déclarative atomique de config.txt
  system.activationScripts.rpi-config = ''
    if [ -d /boot/firmware ]; then
      install -m 0644 ${./config_rpi4.txt} /boot/firmware/config.txt.tmp
      mv -f /boot/firmware/config.txt.tmp /boot/firmware/config.txt
    fi
  '';

  fileSystems."/boot/firmware" = {
    device = "/dev/disk/by-uuid/2178-694E";
    fsType = "vfat";
    options = [ "fmask=0022" "dmask=0022" "noatime" ];
  };

  hardware.deviceTree.enable = false;
  hardware.i2c.enable = true;
  boot.kernelModules = [ "i2c-dev" "i2c-bcm2835" "goodix" ];
  boot.blacklistedKernelModules = [ "brcmfmac" "brcmutil" ];

  powerManagement.cpuFreqGovernor = "performance";

  # --- PRÉREQUIS LONGHORN (ISCSI) AUTO-RÉPARATEUR ---
  services.openiscsi = {
    enable = true;
    name = "iqn.2016-04.com.open-iscsi:${config.networking.hostName}";
  };
  systemd.services.iscsid.serviceConfig = {
    Restart = lib.mkForce "always";
    RestartSec = lib.mkForce "2s";
  };
  systemd.tmpfiles.rules = [
    "L+ /usr/bin/iscsiadm - - - - ${pkgs.openiscsi}/bin/iscsiadm"
    "L+ /usr/local/bin/iscsiadm - - - - ${pkgs.openiscsi}/bin/iscsiadm"
  ];

  # --- SÉCURITÉ SSH & UTILISATEURS ---
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  security.sudo.wheelNeedsPassword = false;

  users.users.nixos = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGPDZWfbEfJf4O2b5ACElABkSIiXcwbZWKUA5HuRBlOC admin@cluster-k3s"
    ];
  };

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGPDZWfbEfJf4O2b5ACElABkSIiXcwbZWKUA5HuRBlOC admin@cluster-k3s"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBkzXmKDx+HcklREJcMUBTt6ID69XGxDfg16OGGNmOGl root@k3s-master"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEx6r4XlHlJlLPL3ZoCX8+HCFt0grzzlffIuZDLckeqg jerom@jerome"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBc1GQqEyCWsi1xcnk3DxSo6LNdLjIV/4ACyyjlJobpi PC Bureau - Jerome"
  ];

  # --- RÉSEAU & PARE-FEU ---
  networking.networkmanager.enable = true;
  networking.firewall = {
    enable = true;
    checkReversePath = "loose";
    trustedInterfaces = [ "cni0" "flannel.1" "flannel-wg" ];
    allowedTCPPorts = [
      22    # SSH
      6443  # API Kubernetes k3s
      80    # HTTP
      443   # HTTPS
      8088  # Pixiecore PXE HTTP/Status
    ];
    allowedTCPPortRanges = [
      { from = 30000; to = 32767; }
    ];
    allowedUDPPorts = [
      67    # ProxyDHCP Pixiecore
      69    # TFTP Pixiecore
      4011  # PXE Pixiecore
      8472  # Flannel VXLAN
      51820 # Flannel WireGuard IPv4
      51821 # Flannel WireGuard IPv6
    ];
  };

  environment.etc."secrets.yaml".source = ../../secrets.yaml;

  # --- ORCHESTRATION K3S (RÔLE CONTROL-PLANE PROTÉGÉ) ---
  services.k3s = {
    enable = true;
    # renovate: datasource=github-releases depName=k3s-io/k3s
    package = pkgs.k3s;
    role = "server";
    extraFlags = toString [
      "--node-taint=node-role.kubernetes.io/control-plane=true:NoSchedule"
      "--node-ip=${clusterIps.master}"
      "--advertise-address=${clusterIps.master}"
      "--node-label=svccontroller.k3s.cattle.io/enable=false"
      "--disable=servicelb"
      "--disable=traefik"
      "--disable=local-storage"
      "--flannel-backend=wireguard-native"
      "--kubelet-arg=container-log-max-size=10Mi"
      "--kubelet-arg=container-log-max-files=3"
      "--kubelet-arg=max-pods=60"
      "--kube-apiserver-arg=max-requests-inflight=400"
      "--kube-apiserver-arg=max-mutating-requests-inflight=200"
    ];
  };

  # Résilience maximale et bornage mémoire Go sur k3s control-plane
  systemd.services.k3s = {
    unitConfig.StartLimitIntervalSec = lib.mkForce 0;
    environment = {
      GOMEMLIMIT = "2500MiB";
      GOGC = "80";
    };
    serviceConfig = {
      Restart = lib.mkForce "always";
      RestartSec = lib.mkForce "3s";
      MemoryHigh = "2800M";
      MemoryMax = "3200M";
      OOMScoreAdjust = lib.mkForce (-900);
    };
  };

  # --- MAINTENANCE SQLITE ASYNCHRONE ET COMPACTAGE WAL ---
  systemd.services.k3s-sqlite-vacuum = {
    description = "Optimisation et compactage WAL de la base K3s (SQLite)";
    path = [ pkgs.sqlite ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      IOSchedulingClass = "idle";
      CPUSchedulingPolicy = "idle";
    };
    script = ''
      sqlite3 /var/lib/rancher/k3s/server/db/state.db \
        'PRAGMA busy_timeout=10000; PRAGMA synchronous=NORMAL; PRAGMA journal_mode=WAL; PRAGMA wal_checkpoint(TRUNCATE); PRAGMA optimize; VACUUM;'
    '';
  };

  systemd.timers.k3s-sqlite-vacuum = {
    wantedBy = [ "timers.target" ];
    partOf = [ "k3s-sqlite-vacuum.service" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:00:00";
      Persistent = true;
      RandomizedDelaySec = "10m";
    };
  };

  # --- SAUVEGARDE PARALLÈLE EN RAM (/dev/shm) COMPRESSÉE ZSTD VERS GOOGLE DRIVE ---
  systemd.services.backup-config-gdrive = {
    description = "Sauvegarde parallèle en RAM (ZSTD) de NixOS et K3s vers Google Drive";
    path = with pkgs; [ coreutils inetutils sqlite rclone sops ssh-to-age gnutar zstd ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      MemoryMax = "512M";
    };
    script = ''
      set -euo pipefail
      DATE=$(date +%Y-%m-%d)
      HOSTNAME=$(hostname)
      BACKUP_DIR="/dev/shm/backup_staging"
      RCLONE_CONF="/dev/shm/rclone_gdrive.conf"
      REMOTE="gdrive:NixOS-Backups/$HOSTNAME"

      cleanup() {
        rm -rf "$BACKUP_DIR" "$RCLONE_CONF"
      }
      trap cleanup EXIT

      rm -rf "$BACKUP_DIR"
      mkdir -p "$BACKUP_DIR/nixos" "$BACKUP_DIR/k3s-state"

      # 1. Extraction et préparation en sous-processus parallèles en RAM (/dev/shm)
      (
        export SOPS_AGE_KEY=$(ssh-to-age -private-key -i /etc/ssh/ssh_host_ed25519_key)
        sops -d --extract '["rclone_conf"]' /etc/secrets.yaml > "$RCLONE_CONF"
        chmod 600 "$RCLONE_CONF"
      ) &

      (
        if [ -d /etc/nixos ]; then
          cp -a /etc/nixos/. "$BACKUP_DIR/nixos/"
          rm -f "$BACKUP_DIR/nixos/result"
        fi
        [ -f /boot/firmware/config.txt ] && cp /boot/firmware/config.txt "$BACKUP_DIR/" || true
      ) &

      (
        sqlite3 /var/lib/rancher/k3s/server/db/state.db ".timeout 10000" ".backup '$BACKUP_DIR/k3s-state/state.db'"
      ) &

      (
        cp -a /var/lib/rancher/k3s/server/tls "$BACKUP_DIR/k3s-state/"
      ) &

      wait

      # 2. Compression multi-thread ZSTD en RAM pour minimiser les transactions I/O Cloud
      ARCHIVE_FILE="$BACKUP_DIR/cluster-state-$DATE.tar.zst"
      tar -C "$BACKUP_DIR" -I "zstd -T0 -9" -cf "$ARCHIVE_FILE" nixos k3s-state

      # 3. Synchronisation parallèle rclone
      rclone --config "$RCLONE_CONF" sync "$BACKUP_DIR" "$REMOTE/latest" \
        --transfers 8 --checkers 16 --tpslimit 8 --fast-list
      rclone --config "$RCLONE_CONF" copy "$ARCHIVE_FILE" "$REMOTE/history/$DATE" \
        --transfers 8 --checkers 16 --tpslimit 8

      # 4. Purge asynchrone des archives de plus de 30 jours
      rclone --config "$RCLONE_CONF" delete "$REMOTE/history" --min-age 30d --tpslimit 8 || true
      rclone --config "$RCLONE_CONF" rmdirs "$REMOTE/history" --leave-root --tpslimit 8 || true
    '';
  };

  systemd.paths.backup-config-gdrive = {
    description = "Déclencheur événementiel inotify pour sauvegarde K3s vers GDrive";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathModified = "/var/lib/rancher/k3s/server/db/state.db-wal";
    };
  };

  # --- SERVEUR PXE (PIXIECORE - GO NATIF) AUTO-RÉPARATEUR ---
  services.pixiecore = {
    enable = true;
    openFirewall = true;
    dhcpNoBind = true;
    mode = "boot";
    port = 8088;
    statusPort = 8088;
    kernel = "${inputs.self.nixosConfigurations.worker-pxe.config.system.build.kernel}/bzImage";
    initrd = "${inputs.self.nixosConfigurations.worker-pxe.config.system.build.netbootRamdisk}/initrd";
    cmdLine = "init=${inputs.self.nixosConfigurations.worker-pxe.config.system.build.toplevel}/init loglevel=4";
  };

  systemd.services.pixiecore = {
    unitConfig.StartLimitIntervalSec = lib.mkForce 0;
    environment.GOMEMLIMIT = "256MiB";
    serviceConfig = {
      Restart = lib.mkForce "always";
      RestartSec = lib.mkForce "2s";
      MemoryMax = "300M";
    };
  };

  environment.systemPackages = with pkgs; [
    vim
    wget
    git
    rclone
    libinput
    i2c-tools
    usbutils
    lshw
    inxi
    pciutils
    hwinfo
    btop
    util-linux
    nfs-utils
    openiscsi
    nftables
    zstd
  ];

  system.stateVersion = "26.05";
}