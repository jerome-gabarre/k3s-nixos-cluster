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
    before = [ "k3s.service" "k3s-agent.service" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    # Injection des binaires nécessaires dans le $PATH du service
    path = [ pkgs.nettools ]; 
    script = ''
      DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5}')
      MAC=$(cat /sys/class/net/$DEFAULT_IFACE/address 2>/dev/null | tr -d ':' || echo "unknown")
      
      if [ "$MAC" = "14:b3:1f:14:e0:99" ]; then
        TARGET_HOSTNAME="worker-amd64-01"
      else
        TARGET_HOSTNAME="worker-''${MAC//:/}"
      fi

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
  # ⚠️ ORCHESTRATION DU STOCKAGE HYBRIDE (STATELESS OS -> STATEFUL DATA)
  # =====================================================================
  # Ce Worker bootant en réseau (PXE), sa RAM et son OS sont réinitialisés à chaque démarrage.
  # Ce script garantit la survie des bases de données (K3s/Longhorn) et des secrets (SOPS)
  # en forçant l'écriture sur le disque dur physique de la machine.
  # =====================================================================
  # =====================================================================
  # 1. PRÉPARATION DU STOCKAGE ET DES SECRETS (AVANT K3S)
  # =====================================================================

  # utiliser la commande suivante sur le noeud en SSH pour formater les disques au préalable puis faire un reboot pour détecter les disques.
  # for disk in $(lsblk -dpno NAME,TYPE,RM | awk '$2=="disk" && $3=="0" && $1 !~ /zram|loop/ {print $1}'); do
  # echo "⚠️ Formatage destructif du disque : $disk"
  # wipefs -a "$disk"
  # parted -s "$disk" mklabel gpt mkpart primary xfs 0% 100%
  # udevadm settle
  # Trouver le nom de la nouvelle partition (gère les cas sda1 vs nvme0n1p1)
  # if [[ "$disk" == *nvme* || "$disk" == *mmcblk* ]]; then
  #   part="${disk}p1"
  # else
  #   part="${disk}1"
  # fi
  # mkfs.xfs -f -L LONGHORN_DATA "$part"
  # echo "✅ $part formaté avec succès."
  # done

  systemd.services.prepare-k3s-disk = {
    description = "Initialisation, montage du disque et déchiffrement SOPS";
    
    before = [ "k3s.service" "sshd.service" ];
    requiredBy = [ "k3s.service" ];
    
    path = with pkgs;
      [ util-linux parted e2fsprogs xfsprogs systemd gawk sops ssh-to-age openssh jq ];
      
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    
    script = ''
      set -e
      MOUNT_POINT="/var/lib/rancher/k3s"
      PRIMARY_DISK_MOUNTED=false
      JSON_DISKS=""
      TARGET_LABEL="LONGHORN_DATA"
      
      echo "🛡️ DÉMARRAGE DU PROVISIONNEMENT DÉTERMINISTE DES DISQUES"
      udevadm settle
      
      # Recherche stricte des partitions portant le label exact
      target_parts=$(blkid -L "$TARGET_LABEL" || true)
      
      if [ -z "$target_parts" ]; then
        echo "❌ Aucun disque avec le label $TARGET_LABEL trouvé."
        echo "Action requise : Formatez manuellement le disque cible via 'mkfs.xfs -L $TARGET_LABEL /dev/sdX1'"
        exit 1
      fi
      
      for part in $target_parts; do
        disk=$(lsblk -no PKNAME "$part" | tr -d ' ' || echo "$part")
        disk_name=$(basename "$disk")
        
        echo "✅ Disque autorisé détecté : $part"
        
        ROTA=$(lsblk -d -n -o ROTA "/dev/$disk_name" | tr -d ' ')
        if [ "$ROTA" = "1" ]; then DISK_TAG="hdd"; else DISK_TAG="ssd"; fi
        
        if [ "$PRIMARY_DISK_MOUNTED" = false ]; then
          mkdir -p $MOUNT_POINT
          if ! mountpoint -q $MOUNT_POINT; then mount "$part" $MOUNT_POINT; fi
          JSON_DISKS+="{\"path\":\"/var/lib/longhorn\",\"allowScheduling\":true,\"storageReserved\":0,\"tags\":[\"$DISK_TAG\",\"primary\"]},"
          PRIMARY_DISK_MOUNTED=true
        else
          lh_mount="/var/lib/longhorn/disks/$disk_name"
          mkdir -p "$lh_mount"
          if ! grep -qs "$lh_mount" /proc/mounts; then mount "$part" "$lh_mount"; fi
          JSON_DISKS+="{\"path\":\"$lh_mount\",\"allowScheduling\":true,\"storageReserved\":0,\"tags\":[\"$DISK_TAG\"]},"
        fi
      done

      mkdir -p $MOUNT_POINT/etc_rancher_node /etc/rancher/node
      if ! mountpoint -q /etc/rancher/node; then mount --bind $MOUNT_POINT/etc_rancher_node /etc/rancher/node; fi

      mkdir -p $MOUNT_POINT/longhorn_default /var/lib/longhorn
      if ! mountpoint -q /var/lib/longhorn; then mount --bind $MOUNT_POINT/longhorn_default /var/lib/longhorn; fi

      mkdir -p $MOUNT_POINT/kubelet /var/lib/kubelet
      if ! mountpoint -q /var/lib/kubelet; then mount --bind $MOUNT_POINT/kubelet /var/lib/kubelet; fi
      mount --make-shared /var/lib/kubelet

      echo "[''${JSON_DISKS%,}]" > /var/lib/longhorn/default-disks.json

      if [ ! -f "$MOUNT_POINT/ssh_host_ed25519_key" ]; then ssh-keygen -t ed25519 -f "$MOUNT_POINT/ssh_host_ed25519_key" -N "" -q; fi
      PUBLIC_AGE_KEY=$(ssh-to-age -private-key -i $MOUNT_POINT/ssh_host_ed25519_key)
      
      export SOPS_AGE_KEY=$PUBLIC_AGE_KEY
      sops -d --extract '["k3s_token"]' /etc/secrets.yaml > $MOUNT_POINT/k3s_token
      chmod 600 $MOUNT_POINT/k3s_token
    '';
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
