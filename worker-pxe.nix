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

  # --- AUTORISER LE RÉSEAU INTERNE KUBERNETES ---
  networking.firewall.enable = false;

  # --- PRÉREQUIS POUR LONGHORN (STOCKAGE K8S) ---
  services.openiscsi.enable = true;
  services.openiscsi.name = "iqn.2016-04.com.open-iscsi:${config.networking.hostName}";
  environment.systemPackages = with pkgs; [ util-linux nfs-utils openiscsi ];

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
  };

  # =====================================================================
  # ⚠️ ORCHESTRATION DU STOCKAGE HYBRIDE (STATELESS OS -> STATEFUL DATA)
  # =====================================================================
  # Ce Worker bootant en réseau (PXE), sa RAM et son OS sont réinitialisés à chaque démarrage.
  # Ce script garantit la survie des bases de données (K3s/Longhorn) et des secrets (SOPS)
  # en forçant l'écriture sur le disque dur physique de la machine.
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
      
      echo "🛡️ DÉMARRAGE DU CHECK DE SÉCURITÉ DES DISQUES (MULTI-DISQUES)"

      # --- CORRECTION PXE : SYNCHRONISATION MATÉRIELLE ---
      # L'OS bootant en RAM, les bus SATA/NVMe sont sondés de manière asynchrone.
      # On force l'attente de l'initialisation des périphériques.
      udevadm settle
      
      echo "Recherche des disques physiques..."
      for i in {1..10}; do
        disks=$(lsblk -dpno NAME,TYPE,RM | awk '$2=="disk" && $3=="0" {print $1}')
        if [ -n "$disks" ]; then
          break
        fi
        echo "Disques non prêts, attente ($i/10)..."
        sleep 1
      done

      # On boucle sur tous les disques physiques (non amovibles)
      for disk in $disks; do
        disk_name=$(basename "$disk")
        expected_label="K3S_DATA_$disk_name"
        
        # 1. Recherche récursive d'un label K3S sur le disque OU ses partitions
        k3s_part=$(lsblk -r -n -o NAME,LABEL "$disk" | awk '/K3S_DATA/ {print "/dev/"$1}' | head -n 1)

        if [ -n "$k3s_part" ]; then
          # CAS 1 : Disque K3s déjà existant
          echo "✅ Disque K3s reconnu : $k3s_part"
          part_path="$k3s_part"

        else
          # CAS 2 : Pas de label K3s. Le disque est-il VRAIMENT vierge ?
          has_data=$(lsblk -r -n -o FSTYPE,PTTYPE "$disk" | awk 'NF>0' | head -n 1)
          
          if [ -z "$has_data" ]; then
            echo "⚠️ Disque vierge détecté ($disk). Formatage ext4 en cours..."
            wipefs -af "$disk"
            parted -s "$disk" mklabel gpt mkpart primary ext4 0% 100%
            udevadm settle
            
            part_path=$(lsblk -rno NAME "$disk" | awk 'NR==2 {print "/dev/"$1}')
            mkfs.ext4 -L "$expected_label" "$part_path"
          else
            # CAS 3 : Disque contenant des données non-K3s
            echo "🚨 ALERTE CRITIQUE : Disque $disk ignoré. Données inconnues détectées."
            continue
          fi
        fi

        # -----------------------------------------------------------------
        # ÉTAPE 2 : DISTRIBUTION DES MONTAGES (K3S vs LONGHORN)
        # -----------------------------------------------------------------
        if [ "$PRIMARY_DISK_MOUNTED" = false ]; then
          echo "Montage du disque principal sur $MOUNT_POINT..."
          mkdir -p $MOUNT_POINT
          if ! mountpoint -q $MOUNT_POINT; then
            mount "$part_path" $MOUNT_POINT
          fi
          PRIMARY_DISK_MOUNTED=true
        else
          lh_mount="/var/lib/longhorn/disks/$disk_name"
          echo "Montage du disque d'extension sur $lh_mount..."
          mkdir -p "$lh_mount"
          if ! grep -qs "$lh_mount" /proc/mounts; then
            mount "$part_path" "$lh_mount"
          fi
        fi
      done

      if [ "$PRIMARY_DISK_MOUNTED" = false ]; then
        echo "❌ Aucun disque utilisable trouvé pour K3s. Arrêt."
        exit 1
      fi

      # -----------------------------------------------------------------
      # ÉTAPE 3 : BIND MOUNTS ET SOPS (PERSISTANCE)
      # -----------------------------------------------------------------
      echo "Persistance de l'identité du noeud..."
      mkdir -p $MOUNT_POINT/etc_rancher_node
      mkdir -p /etc/rancher/node
      if ! mountpoint -q /etc/rancher/node; then
        mount --bind $MOUNT_POINT/etc_rancher_node /etc/rancher/node
      fi

      echo "Persistance de l'espace Longhorn par défaut..."
      mkdir -p $MOUNT_POINT/longhorn_default
      mkdir -p /var/lib/longhorn
      if ! mountpoint -q /var/lib/longhorn; then
        mount --bind $MOUNT_POINT/longhorn_default /var/lib/longhorn
      fi

      echo "Vérification/Génération de la clé d'identité..."
      if [ ! -f "$MOUNT_POINT/ssh_host_ed25519_key" ]; then
        ssh-keygen -t ed25519 -f "$MOUNT_POINT/ssh_host_ed25519_key" -N "" -q
      fi

      PUBLIC_AGE_KEY=$(ssh-to-age -private-key -i $MOUNT_POINT/ssh_host_ed25519_key)
      echo "🔑 [SOPS-BOOTSTRAP] Clé publique AGE de ce Worker : $PUBLIC_AGE_KEY"

      echo "Déchiffrement du token K3s..."
      export SOPS_AGE_KEY=$PUBLIC_AGE_KEY
      sops -d --extract '["k3s_token"]' /etc/secrets.yaml > $MOUNT_POINT/k3s_token
      chmod 600 $MOUNT_POINT/k3s_token

      echo "🚀 Stockage multi-disques et secrets prêts !"
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
