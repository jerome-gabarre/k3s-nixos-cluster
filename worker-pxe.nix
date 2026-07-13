{ config, pkgs, lib, ... }:

{
  # Import du module officiel pour image RAM
  imports = [
    <nixpkgs/nixos/modules/installer/netboot/netboot-minimal.nix>
  ];

  # Architecture ciblée : PC Standard
  nixpkgs.hostPlatform = "x86_64-linux";

  # Nom générique pour facilement le repérer sur le réseau
  networking.hostName = "nixos-pxe-installer";

  # --- NEUTRALISATION DUAL-STACK DOUCE (SYSTÈME ACTIF, INTERFACES MUETTES) ---
  boot.kernel.sysctl = {
    "net.ipv6.conf.all.disable_ipv6" = 1;
    "net.ipv6.conf.default.disable_ipv6" = 1;
  };

  # On intègre le fichier chiffré dans le système du Worker
  environment.etc."secrets.yaml".source = ./secrets.yaml;

  # --- CRITIQUE POUR LE MATÉRIEL DE RÉCUPÉRATION ---
  # Charge tous les pilotes propriétaires (Realtek, Intel, Broadcom...)
  hardware.enableRedistributableFirmware = false;

  # --- PARAMÈTRE SYSTÈME OBLIGATOIRE ---
  # Cette ligne est requise pour la gestion des versions d'état de NixOS.
  system.stateVersion = "25.11";

  # --- CONTOURNEMENT POUR LONGHORN SUR NIXOS ---
  system.activationScripts.longhorn-iscsi = ''
    mkdir -p /usr/bin /usr/local/bin
    ln -sfn /run/current-system/sw/bin/iscsiadm /usr/bin/iscsiadm
    ln -sfn /run/current-system/sw/bin/iscsiadm /usr/local/bin/iscsiadm
  '';

  # --- SÉCURITÉ : PARE-FEU WORKER ---
  networking.firewall.enable = true;

  # TOLÉRANCE AU ROUTAGE ASYMÉTRIQUE DU CNI (FLANNEL)
  networking.firewall.checkReversePath = "loose";

  # Confiance absolue sur les interfaces réseau internes du cluster k3s
  networking.firewall.trustedInterfaces = [ "cni0" "flannel.1" ];



  # Ouverture des ports vitaux pour un nœud agent k3s
  networking.firewall.allowedTCPPorts = [ 
    22      # Maintenance SSH
    10250   # API Kubelet (Nécessaire pour les logs, metrics-server et port-forwarding)
  ];

  networking.firewall.allowedUDPPorts = [
    8472    # Flannel VXLAN (Communication inter-nœuds)
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
  # --- 1. CONFIGURATION DE L'AGENT K3S ---
   services.k3s = {
    enable = true;
    package = pkgs.k3s_1_31;
    role = "agent";
    serverAddr = "https://192.168.10.103:6443";
    tokenFile = "/var/lib/rancher/k3s/k3s_token";
    extraFlags = "--with-node-id";
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
  systemd.services.prepare-k3s-disk = {
    description = "Initialisation, montage du disque et déchiffrement SOPS";
    
    before = [ "k3s.service" "sshd.service" ];
    requiredBy = [ "k3s.service" ];
    
    path = with pkgs;
      [ util-linux parted e2fsprogs systemd gawk sops ssh-to-age openssh ];
      
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    
    script = ''
      set -e
      MOUNT_POINT="/var/lib/rancher/k3s"
      PRIMARY_DISK_MOUNTED=false
      JSON_DISKS=""
      
      echo "🛡️ DÉMARRAGE DU CHECK DE SÉCURITÉ DES DISQUES (MULTI-DISQUES)"
      udevadm settle
      
      echo "Recherche des disques physiques..."
      for i in {1..10}; do
        disks=$(lsblk -dpno NAME,TYPE,RM | awk '$2=="disk" && $3=="0" {print $1}')
        if [ -n "$disks" ]; then break; fi
        echo "Disques non prêts, attente ($i/10)..."
        sleep 1
      done

      for disk in $disks; do
        disk_name=$(basename "$disk")
        expected_label="K3S_DATA_$disk_name"
        
        # DÉTECTION MATÉRIELLE (ROTA = 1 pour HDD, 0 pour SSD/NVMe)
        ROTA=$(lsblk -d -n -o ROTA "$disk" | tr -d ' ')
        if [ "$ROTA" = "1" ]; then DISK_TAG="hdd"; else DISK_TAG="ssd"; fi
        
        k3s_part=$(lsblk -r -n -o NAME,LABEL "$disk" | awk '/K3S_DATA/ {print "/dev/"$1}' | head -n 1)

        if [ -n "$k3s_part" ]; then
          echo "✅ Disque K3s reconnu : $k3s_part ($DISK_TAG)"
          part_path="$k3s_part"
        else
          has_data=$(lsblk -r -n -o FSTYPE,PTTYPE "$disk" | awk 'NF>0' | head -n 1)
          if [ -z "$has_data" ]; then
            echo "⚠️ Disque vierge détecté ($disk). Formatage ext4 en cours..."
            wipefs -af "$disk"
            parted -s "$disk" mklabel gpt mkpart primary ext4 0% 100%
            udevadm settle
            part_path=$(lsblk -rno NAME "$disk" | awk 'NR==2 {print "/dev/"$1}')
            mkfs.ext4 -L "$expected_label" "$part_path"
          else
            echo "🚨 ALERTE CRITIQUE : Disque $disk ignoré. Données inconnues détectées."
            continue
          fi
        fi

        if [ "$PRIMARY_DISK_MOUNTED" = false ]; then
          mkdir -p $MOUNT_POINT
          if ! mountpoint -q $MOUNT_POINT; then mount "$part_path" $MOUNT_POINT; fi
          JSON_DISKS+="{\"path\":\"/var/lib/longhorn\",\"allowScheduling\":true,\"storageReserved\":0,\"tags\":[\"$DISK_TAG\",\"primary\"]},"
          PRIMARY_DISK_MOUNTED=true
        else
          lh_mount="/var/lib/longhorn/disks/$disk_name"
          mkdir -p "$lh_mount"
          if ! grep -qs "$lh_mount" /proc/mounts; then mount "$part_path" "$lh_mount"; fi
          JSON_DISKS+="{\"path\":\"$lh_mount\",\"allowScheduling\":true,\"storageReserved\":0,\"tags\":[\"$DISK_TAG\"]},"
        fi
      done

      if [ "$PRIMARY_DISK_MOUNTED" = false ]; then
        echo "❌ Aucun disque utilisable trouvé pour K3s. Arrêt."
        exit 1
      fi

      mkdir -p $MOUNT_POINT/etc_rancher_node /etc/rancher/node
      if ! mountpoint -q /etc/rancher/node; then mount --bind $MOUNT_POINT/etc_rancher_node /etc/rancher/node; fi

      mkdir -p $MOUNT_POINT/longhorn_default /var/lib/longhorn
      if ! mountpoint -q /var/lib/longhorn; then mount --bind $MOUNT_POINT/longhorn_default /var/lib/longhorn; fi

      # Persistance de l'état Kubelet (CRITIQUE pour le CSI au reboot PXE)
      mkdir -p $MOUNT_POINT/kubelet /var/lib/kubelet
      if ! mountpoint -q /var/lib/kubelet; then mount --bind $MOUNT_POINT/kubelet /var/lib/kubelet; fi
      # Kubelet requiert explicitement une propagation de montage partagée pour le CSI
      mount --make-shared /var/lib/kubelet

      # Sauvegarde de la structure pour le service de patch API
      echo "[''${JSON_DISKS%,}]" > /var/lib/longhorn/default-disks.json

      if [ ! -f "$MOUNT_POINT/ssh_host_ed25519_key" ]; then ssh-keygen -t ed25519 -f "$MOUNT_POINT/ssh_host_ed25519_key" -N "" -q; fi
      PUBLIC_AGE_KEY=$(ssh-to-age -private-key -i $MOUNT_POINT/ssh_host_ed25519_key)
      
      export SOPS_AGE_KEY=$PUBLIC_AGE_KEY
      sops -d --extract '["k3s_token"]' /etc/secrets.yaml > $MOUNT_POINT/k3s_token
      chmod 600 $MOUNT_POINT/k3s_token
    '';
  };

 # =====================================================================
  # 2. PATCH API LONGHORN (APRÈS K3S)
  # =====================================================================
  systemd.services.longhorn-auto-discovery = {
    description = "Patch API Kubernetes pour l'auto-discovery Longhorn";
    
    after = [ "k3s.service" ];
    wantedBy = [ "multi-user.target" ];
    
    path = with pkgs; [ kubectl coreutils ];
    
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    
    script = ''
      # Utilisation du Kubeconfig de l'agent (Kubelet)
      export KUBECONFIG=/var/lib/rancher/k3s/agent/kubelet.kubeconfig
      
      # Lecture directe depuis le noyau (zéro dépendance binaire)
      BASE_HOSTNAME=$(cat /proc/sys/kernel/hostname)
      
      # On attend que le fichier d'ID soit généré par k3s
      for i in {1..12}; do
        if [ -f "/etc/rancher/node/id" ]; then break; fi
        sleep 5
      done
      
      NODE_ID=$(cat /etc/rancher/node/id)
      NODE_NAME="$BASE_HOSTNAME-$NODE_ID"
      
      echo "Attente du démarrage de l'agent K3s local et de l'enregistrement du noeud ($NODE_NAME)..."
      for i in {1..36}; do
        if [ -f "$KUBECONFIG" ] && kubectl get node $NODE_NAME > /dev/null 2>&1; then
          if [ -f "/var/lib/longhorn/default-disks.json" ]; then
            FINAL_JSON=$(cat /var/lib/longhorn/default-disks.json)
            echo "API disponible. Injection du payload Longhorn sur $NODE_NAME..."
            kubectl annotate node $NODE_NAME "node.longhorn.io/default-disks-config=$FINAL_JSON" --overwrite
            echo "✅ Annotation injectée avec succès."
            exit 0
          fi
        fi
        sleep 5
      done
      
      echo "❌ Délai dépassé. Impossible d'appliquer l'annotation Longhorn."
      exit 1
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
