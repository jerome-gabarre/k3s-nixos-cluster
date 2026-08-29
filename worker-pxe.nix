{ config, pkgs, lib, ... }:

{
  # Import du module officiel pour image RAM
  imports = [
    <nixpkgs/nixos/modules/installer/netboot/netboot-minimal.nix>
  ];

  # Architecture ciblée : PC Standard
  nixpkgs.hostPlatform = "x86_64-linux";

  systemd.services.set-deterministic-hostname = {
    description = "Set deterministic hostname based on MAC address";
    before = [ "k3s.service" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = with pkgs; [ nettools iproute2 gawk coreutils ]; 
    script = ''
      echo "Attente de la connectivité réseau et de la route par défaut..."
      
      # Attente active (jusqu'à 30 secondes) de la route par défaut au lieu d'un sleep arbitraire
      for i in {1..30}; do
        DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n 1)
        [ -n "$DEFAULT_IFACE" ] && break
        sleep 1
      done
      
      # Fallback extrême si le routage est manuel ou anormalement lent
      if [ -z "$DEFAULT_IFACE" ]; then
        echo "AVERTISSEMENT: Aucune route par défaut. Fallback sur la première interface physique."
        DEFAULT_IFACE=$(ls /sys/class/net | grep -E '^en|^eth' | head -n 1)
      fi

      # Extraction de la MAC
      MAC_RAW=$(cat "/sys/class/net/$DEFAULT_IFACE/address" 2>/dev/null || echo "unknown")
      
      if [ "$MAC_RAW" = "14:b3:1f:14:e0:99" ]; then
        TARGET_HOSTNAME="worker-amd64-01"
      else
        MAC_CLEAN=$(echo "$MAC_RAW" | tr -d ':')
        TARGET_HOSTNAME="worker-$MAC_CLEAN"
      fi

      echo "Assignation du hostname: $TARGET_HOSTNAME"
      hostname "$TARGET_HOSTNAME"
    '';
  };

  # On intègre le fichier chiffré dans le système du Worker
  environment.etc."secrets.yaml".source = ./secrets.yaml;

  # --- CRITIQUE POUR LE MATÉRIEL DE RÉCUPÉRATION ---
  # Charge tous les pilotes propriétaires (Realtek, Intel, Broadcom...)
  hardware.enableRedistributableFirmware = true;

  # --- PARAMÈTRE SYSTÈME OBLIGATOIRE ---
  # Cette ligne est requise pour la gestion des versions d'état de NixOS.
  system.stateVersion = "25.11";

  # --- CONFIGURATION RÉSEAU ---
  networking.networkmanager.enable = true;

  # Création déclarative des liens symboliques attendus par Longhorn
  systemd.tmpfiles.rules = [
    "L+ /usr/bin/iscsiadm - - - - ${pkgs.openiscsi}/bin/iscsiadm"
    "L+ /usr/local/bin/iscsiadm - - - - ${pkgs.openiscsi}/bin/iscsiadm"
  ];

  # --- SÉCURITÉ : PARE-FEU WORKER ---
  networking.firewall.enable = true;

  # TOLÉRANCE AU ROUTAGE ASYMÉTRIQUE DU CNI (FLANNEL)
  networking.firewall.checkReversePath = "loose";

  services.journald.extraConfig = ''
    SystemMaxUse=50M
    RuntimeMaxUse=50M
    MaxRetentionSec=1d
  '';

  # Confiance absolue sur les interfaces réseau internes du cluster k3s
  networking.firewall.trustedInterfaces = [ "cni0" "flannel.1" "flannel-wg" ];

  # Ouverture des ports vitaux pour un nœud agent k3s
  networking.firewall.allowedTCPPorts = [ 
    22      # Maintenance SSH
    10250   # API Kubelet (Nécessaire pour les logs, metrics-server et port-forwarding)
  ];

  # Ouverture de la plage NodePort pour l'accès externe aux applications
  networking.firewall.allowedTCPPortRanges = [
    { from = 30000; to = 32767; }
  ];

  networking.firewall.allowedUDPPorts = [
    8472    # Flannel VXLAN (Communication inter-nœuds)
    51820   # Flannel WireGuard IPv4
    51821   # Flannel WireGuard IPv6
  ];

  # --- PRÉREQUIS POUR LONGHORN (STOCKAGE K8S) ---
  services.openiscsi.enable = true;
  services.openiscsi.name = "iqn.2016-04.com.open-iscsi:${config.networking.hostName}";
  environment.systemPackages = with pkgs; [ 
    util-linux 
    nfs-utils 
    openiscsi 
    nftables
    iptables
    xfsprogs
  ];

  # --- ACTIVATION SSH AVEC IDENTITÉ PERSISTANTE ---
  services.openssh = {
    enable = true;
    # On force la clé SSH à être stockée sur notre disque physique et non en RAM
    hostKeys = [
      {
        path = "/var/lib/rancher/k3s/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];
  };

  # Clés SSH (Windows + Pi)
  users.users.root = {
    initialHashedPassword = lib.mkForce null; # <-- C'est cette ligne qui fait taire l'avertissement
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGPDZWfbEfJf4O2b5ACElABkSIiXcwbZWKUA5HuRBlOC admin@cluster-k3s" 
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBkzXmKDx+HcklREJcMUBTt6ID69XGxDfg16OGGNmOGl root@k3s-master" 
    ];
  };

  # --- OPTIMISATION MÉMOIRE (OS EN RAM) ---
  zramSwap.enable = true;

  # --- 1. CONFIGURATION DE L'AGENT K3S ---
   services.k3s = {
    enable = true;
    # renovate: datasource=github-releases depName=k3s-io/k3s
    package = pkgs.k3s_1_31;
    role = "agent";
    serverAddr = "https://192.168.10.103:6443";
    tokenFile = "/var/lib/rancher/k3s/k3s_token";

  # Sécurisation RAM/Disque via seuils d'éviction Kubelet dynamiques (%)
    extraFlags = toString [
      "--kubelet-arg=eviction-hard=memory.available<5%,nodefs.available<10%,nodefs.inodesFree<5%,imagefs.available<10%"
      "--kubelet-arg=eviction-soft=memory.available<10%,nodefs.available<15%"
      "--kubelet-arg=eviction-soft-grace-period=memory.available=2m,nodefs.available=2m"
      "--kubelet-arg=eviction-max-pod-grace-period=120"
      "--kubelet-arg=container-log-max-size=10Mi"
      "--kubelet-arg=container-log-max-files=3"
    ];
  };

  # =====================================================================
  # ⚠️ ORCHESTRATION DU STOCKAGE HYBRIDE (DÉCLARATIF NIXOS)
  # =====================================================================

  # 1. Montage natif du disque d'état (Stateful)
  fileSystems."/var/lib/rancher/k3s" = {
    device = "/dev/disk/by-label/LONGHORN_DAT";
    fsType = "xfs";
    options = [ "defaults" "pquota" ]; # pquota est fortement recommandé par Longhorn
  };

  # 2. Création des répertoires de liaison AVANT les bind mounts
  systemd.services.init-k3s-dirs = {
    description = "Initialisation des dossiers sources pour K3s";
    unitConfig = {
      DefaultDependencies = false;
    };
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
      mkdir -p /var/lib/rancher/k3s/longhorn_default
      mkdir -p /var/lib/rancher/k3s/kubelet
      mkdir -p /var/lib/rancher/k3s/etc_rancher_node
    '';
  };

  # 3. Bind Mounts déclaratifs (liaison de la RAM vers le disque physique)
  fileSystems."/var/lib/longhorn" = {
    device = "/var/lib/rancher/k3s/longhorn_default";
    options = [ "bind" ];
    depends = [ "/var/lib/rancher/k3s" ];
  };

  fileSystems."/var/lib/kubelet" = {
    device = "/var/lib/rancher/k3s/kubelet";
    options = [ "bind" ];
    depends = [ "/var/lib/rancher/k3s" ];
  };

  fileSystems."/etc/rancher/node" = {
    device = "/var/lib/rancher/k3s/etc_rancher_node";
    options = [ "bind" ];
    depends = [ "/var/lib/rancher/k3s" ];
  };

  # 4. Configuration finale (SSH, Longhorn JSON et SOPS)
  systemd.services.prepare-k3s-state = {
    description = "Génération SSH, JSON Longhorn et décryptage SOPS";
    wantedBy = [ "multi-user.target" ];
    # CORRECTION : Liaison stricte avec k3s-agent.service
    before = [ "k3s.service" "sshd.service" ];
    requiredBy = [ "k3s.service" ];
    requires = [ "var-lib-rancher-k3s.mount" "var-lib-longhorn.mount" ];
    after = [ "var-lib-rancher-k3s.mount" "var-lib-longhorn.mount" ];
    path = with pkgs; [ util-linux sops ssh-to-age openssh jq ];
    serviceConfig = { 
      Type = "oneshot"; 
      RemainAfterExit = true; 
    };
    script = ''
      set -e
      MOUNT_POINT="/var/lib/rancher/k3s"

      echo "🛡️ PROVISIONNEMENT DE L'ÉTAT DU NŒUD"

      if [ ! -f "$MOUNT_POINT/ssh_host_ed25519_key" ]; then
        ssh-keygen -t ed25519 -f "$MOUNT_POINT/ssh_host_ed25519_key" -N "" -q
      fi

      DISK_NAME=$(lsblk -no PKNAME /dev/disk/by-label/LONGHORN_DAT | tr -d ' ' || true)
      if [ -z "$DISK_NAME" ]; then
        DISK_NAME=$(basename $(readlink -f /dev/disk/by-label/LONGHORN_DAT))
      fi
      
      ROTA=$(lsblk -d -n -o ROTA "/dev/$DISK_NAME" | tr -d ' ' || echo "0")
      if [ "$ROTA" = "1" ]; then DISK_TAG="hdd"; else DISK_TAG="ssd"; fi
      
      echo "[{\"path\":\"/var/lib/longhorn\",\"allowScheduling\":true,\"storageReserved\":0,\"tags\":[\"$DISK_TAG\",\"primary\"]}]" > /var/lib/longhorn/default-disks.json

      PUBLIC_AGE_KEY=$(ssh-to-age -private-key -i $MOUNT_POINT/ssh_host_ed25519_key)
      export SOPS_AGE_KEY=$PUBLIC_AGE_KEY
      sops -d --extract '["k3s_token"]' /etc/secrets.yaml > $MOUNT_POINT/k3s_token
      chmod 600 $MOUNT_POINT/k3s_token

      echo "🧹 Nettoyage des sockets CSI résiduels..."
      rm -f $MOUNT_POINT/agent/kubelet/plugins_registry/*.sock || true
      rm -rf $MOUNT_POINT/agent/kubelet/plugins/driver.longhorn.io/* || true
    '';
  };

  # 5. Sécurité : Forcer K3s-agent à attendre la fin absolue des montages
  systemd.services.k3s = {
    after = [ 
      "var-lib-rancher-k3s.mount" 
      "var-lib-longhorn.mount" 
      "var-lib-kubelet.mount" 
      "etc-rancher-node.mount" 
      "init-k3s-dirs.service"
      "prepare-k3s-state.service"
    ];
    requires = [ 
      "var-lib-rancher-k3s.mount" 
      "var-lib-longhorn.mount" 
      "var-lib-kubelet.mount"
      "etc-rancher-node.mount" 
    ];
  };

  # --- AUTOMATISATION DU NETTOYAGE ET OPTIMISATION ---
  nix = {
    gc = {
      automatic = true;
      dates = "daily"; # Se lance tous les jours
      options = "--delete-older-than 3d"; # SUPPRIME les versions de plus de 3 jours
    };
    optimise = {
      automatic = true;
      dates = [ "daily" ]; # DÉDOUBLONNE le store tous les jours en arrière-plan
    };
    settings.auto-optimise-store = true; # Dédoublonne aussi à la volée pendant la compilation
  };

 }
