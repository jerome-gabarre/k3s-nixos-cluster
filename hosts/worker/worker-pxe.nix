# =====================================================================
# ⚠️ RÔLE : WORKER PXE STATELESS (DATA PLANE & STORAGE PLANE)
# =====================================================================
{ config, pkgs, lib, clusterIps, inputs, ... }:

{
  imports = [
    "${inputs.nixpkgs}/nixos/modules/installer/netboot/netboot-minimal.nix"
  ];

  nixpkgs.hostPlatform = "x86_64-linux";

  # Compression maximale ZSTD de l'initrd PXE pour un transfert réseau ultra-rapide
  boot.initrd.compressor = lib.mkForce "zstd";
  boot.initrd.compressorArgs = lib.mkForce [ "-19" "-T0" ];
  boot.zfs.forceImportRoot = false;
  boot.kernelParams = [ "consoleblank=0" ];

  # Support matériel universel multi-constructeurs (Realtek, Intel, Broadcom, AMD, NVIDIA)
  hardware.enableRedistributableFirmware = true;

  # Journalisation en RAM compressée (OS stateless)
  services.journald.extraConfig = lib.mkForce ''
    Storage=volatile
    Compress=yes
    RateLimitIntervalSec=0
    RateLimitBurst=0
    RuntimeMaxUse=64M
    MaxRetentionSec=1d
  '';

  # --- ATTRIBUTION DYNAMIQUE DU HOSTNAME (ÉVÉNEMENTIEL PUR, ZÉRO SLEEP) ---
  systemd.services.set-deterministic-hostname = {
    description = "Attribution déterministe du hostname via SMBIOS/DMI et route par défaut";
    before = [ "k3s.service" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = with pkgs; [ iproute2 coreutils dmidecode gawk nettools xxd ];
    script = ''
      set -euo pipefail
      if ! ip -4 route show | grep -q "^default"; then
        (ip -4 monitor route & echo $! > /dev/shm/ip_mon.pid) | grep -q -m 1 "default"
        kill $(cat /dev/shm/ip_mon.pid) 2>/dev/null || true
        rm -f /dev/shm/ip_mon.pid
      fi

      SYSTEM_UUID=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null | tr '[:upper:]' '[:lower:]' | cut -d '-' -f 1 || true)
      if [ -n "$SYSTEM_UUID" ] && [ "$SYSTEM_UUID" != "ffffffff" ]; then
        TARGET_HOSTNAME="worker-$SYSTEM_UUID"
      else
        DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
        MAC_SUFFIX=$(cat "/sys/class/net/$DEFAULT_IFACE/address" 2>/dev/null | tr -d ':' | tail -c 7 || head -c 3 /dev/urandom | xxd -p)
        TARGET_HOSTNAME="worker-$MAC_SUFFIX"
      fi

      hostname "$TARGET_HOSTNAME"
    '';
  };

  systemd.services.NetworkManager-wait-online.enable = true;

  networking.networkmanager = {
    enable = true;
    settings.main.hostname-mode = "none";
  };

  # --- PARE-FEU WORKER ---
  networking.firewall = {
    enable = true;
    checkReversePath = "loose";
    trustedInterfaces = [ "cni0" "flannel.1" "flannel-wg" ];
    allowedTCPPorts = [
      22    # SSH
      10250 # Kubelet API
      9500  # Longhorn Manager / CSI
      9501  # Longhorn Conversion Webhook
      9502  # Longhorn Admission Webhook
      9503  # Longhorn Recovery Backend
    ];
    allowedTCPPortRanges = [
      { from = 10000; to = 10020; } # Longhorn Instance Manager
      { from = 30000; to = 32767; } # NodePort
    ];
    allowedUDPPorts = [
      8472  # Flannel VXLAN
      51820 # Flannel WireGuard IPv4
      51821 # Flannel WireGuard IPv6
    ];
  };

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

  environment.etc."secrets.yaml".source = ../../secrets.yaml;

  environment.systemPackages = with pkgs; [
    util-linux
    nfs-utils
    openiscsi
    nftables
    iptables
    xfsprogs
    e2fsprogs
    pciutils
    usbutils
  ];

  # --- SSH AVEC IDENTITÉ PERSISTANTE SUR DISQUE D'ÉTAT ---
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
    hostKeys = [
      {
        path = "/var/lib/rancher/k3s/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];
  };

  systemd.services.sshd = {
    requires = [ "var-lib-rancher-k3s.mount" "prepare-k3s-state.service" ];
    after = [ "var-lib-rancher-k3s.mount" "prepare-k3s-state.service" ];
  };

  users.users.root = {
    initialHashedPassword = lib.mkForce null;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGPDZWfbEfJf4O2b5ACElABkSIiXcwbZWKUA5HuRBlOC admin@cluster-k3s"
    ];
  };

  # --- AGENT K3S AUTO-RÉPARATEUR & ÉVICTION DYNAMIQUE ---
  services.k3s = {
    enable = true;
    # renovate: datasource=github-releases depName=k3s-io/k3s
    package = pkgs.k3s;
    role = "agent";
    serverAddr = "https://${clusterIps.master}:6443";
    tokenFile = "/var/lib/rancher/k3s/k3s_token";
    extraFlags = toString [
      "--kubelet-arg=root-dir=/var/lib/kubelet"
      "--kubelet-arg=eviction-hard=memory.available<5%,nodefs.available<10%,nodefs.inodesFree<5%,imagefs.available<10%"
      "--kubelet-arg=eviction-soft=memory.available<10%,nodefs.available<15%"
      "--kubelet-arg=eviction-soft-grace-period=memory.available=2m,nodefs.available=2m"
      "--kubelet-arg=eviction-max-pod-grace-period=120"
      "--kubelet-arg=serialize-image-pulls=false"
      "--kubelet-arg=container-log-max-size=10Mi"
      "--kubelet-arg=container-log-max-files=3"
    ];
  };

  # =====================================================================
  # ⚠️ ORCHESTRATION DU STOCKAGE HYBRIDE ET PROVISIONNEMENT PARALLÈLE
  # =====================================================================
  fileSystems."/var/lib/rancher/k3s" = {
    device = "/dev/disk/by-label/LONGHORN_DAT";
    fsType = "xfs";
    options = [ "defaults" "noatime" "nodiratime" "pquota" "x-systemd.automount" "noauto" "x-systemd.idle-timeout=0" ];
  };

  systemd.services.init-k3s-dirs = {
    description = "Initialisation parallèle des répertoires sources K3s/Longhorn";
    unitConfig.DefaultDependencies = false;
    wantedBy = [ "local-fs.target" ];
    before = [
      "var-lib-longhorn.mount"
      "var-lib-kubelet.mount"
      "etc-rancher-node.mount"
      "k3s.service"
    ];
    requires = [ "var-lib-rancher-k3s.mount" ];
    after = [ "var-lib-rancher-k3s.mount" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      mkdir -p \
        /var/lib/rancher/k3s/longhorn_default \
        /var/lib/rancher/k3s/kubelet \
        /var/lib/rancher/k3s/etc_rancher_node
    '';
  };

  fileSystems."/var/lib/longhorn" = {
    device = "/var/lib/rancher/k3s/longhorn_default";
    fsType = "none";
    options = [ "bind" ];
    depends = [ "/var/lib/rancher/k3s" ];
  };

  fileSystems."/etc/rancher/node" = {
    device = "/var/lib/rancher/k3s/etc_rancher_node";
    fsType = "none";
    options = [ "bind" ];
    depends = [ "/var/lib/rancher/k3s" ];
  };

  fileSystems."/var/lib/kubelet" = {
    device = "/var/lib/rancher/k3s/kubelet";
    fsType = "none";
    options = [ "bind" "shared" ];
    depends = [ "/var/lib/rancher/k3s" ];
  };

  # Provisionnement concurrent (Clé SSH + SOPS + Détection Disque Longhorn + Purge CSI)
  systemd.services.prepare-k3s-state = {
    description = "Provisionnement parallèle de l'état K3s, SOPS et Longhorn";
    wantedBy = [ "multi-user.target" ];
    before = [ "k3s.service" "sshd.service" ];
    requiredBy = [ "k3s.service" ];
    requires = [ "var-lib-rancher-k3s.mount" "var-lib-longhorn.mount" ];
    after = [ "var-lib-rancher-k3s.mount" "var-lib-longhorn.mount" ];
    path = with pkgs; [ coreutils util-linux sops ssh-to-age openssh jq ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail
      MOUNT_POINT="/var/lib/rancher/k3s"

      # Tâche 1 : Clé SSH hôte + déchiffrement SOPS du token k3s en RAM puis écriture atomique
      (
        if [ ! -f "$MOUNT_POINT/ssh_host_ed25519_key" ]; then
          ssh-keygen -t ed25519 -f "$MOUNT_POINT/ssh_host_ed25519_key" -N "" -q
        fi
        export SOPS_AGE_KEY=$(ssh-to-age -private-key -i "$MOUNT_POINT/ssh_host_ed25519_key")
        sops -d --extract '["k3s_token"]' /etc/secrets.yaml > /dev/shm/k3s_token.tmp
        chmod 600 /dev/shm/k3s_token.tmp
        mv -f /dev/shm/k3s_token.tmp "$MOUNT_POINT/k3s_token"
      ) &

      # Tâche 2 : Détection agnostique du type de support (SSD/NVMe vs HDD) pour Longhorn
      (
        if [ ! -f /var/lib/longhorn/default-disks.json ]; then
          DISK_NAME=$(lsblk -no PKNAME /dev/disk/by-label/LONGHORN_DAT | tr -d ' ' | head -n 1 || true)
          if [ -z "$DISK_NAME" ]; then
            DISK_NAME=$(basename "$(readlink -f /dev/disk/by-label/LONGHORN_DAT)")
          fi
          ROTA=$(cat "/sys/block/$DISK_NAME/queue/rotational" 2>/dev/null || lsblk -d -n -o ROTA "/dev/$DISK_NAME" | tr -d ' ' || echo "0")
          if [ "$ROTA" = "1" ]; then DISK_TAG="hdd"; else DISK_TAG="ssd"; fi
          echo "[{\"path\":\"/var/lib/longhorn\",\"allowScheduling\":true,\"storageReserved\":0,\"tags\":[\"$DISK_TAG\",\"primary\"]}]" > /var/lib/longhorn/default-disks.json
        fi
      ) &

      # Tâche 3 : Nettoyage des sockets CSI résiduels
      (
        rm -f "$MOUNT_POINT"/agent/kubelet/plugins_registry/*.sock || true
        rm -rf "$MOUNT_POINT"/agent/kubelet/plugins/driver.longhorn.io/* || true
      ) &

      wait
    '';
  };

  systemd.services.k3s = {
    unitConfig.StartLimitIntervalSec = lib.mkForce 0;
    environment = {
      GOMEMLIMIT = "1024MiB";
      GOGC = "80";
    };
    after = [
      "var-lib-rancher-k3s.mount"
      "var-lib-longhorn.mount"
      "var-lib-kubelet.mount"
      "etc-rancher-node.mount"
      "init-k3s-dirs.service"
      "prepare-k3s-state.service"
      "set-deterministic-hostname.service"
    ];
    requires = [
      "var-lib-rancher-k3s.mount"
      "var-lib-longhorn.mount"
      "var-lib-kubelet.mount"
      "etc-rancher-node.mount"
      "prepare-k3s-state.service"
    ];
    serviceConfig = {
      Restart = lib.mkForce "always";
      RestartSec = lib.mkForce "3s";
      OOMScoreAdjust = lib.mkForce (-900);
    };
  };

  system.stateVersion = "26.05";
}