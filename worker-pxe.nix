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
    requiredBy = [ "k3s.service" "sshd.service" ];
    
    path = with pkgs;
    [ util-linux parted e2fsprogs systemd gawk sops ssh-to-age openssh ];
    
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    
    script = ''
      set -e
      LABEL="K3S_DATA"
      MOUNT_POINT="/var/lib/rancher/k3s"
      
      echo "Vérification de la présence d'une partition locale '$LABEL'..."

      # -----------------------------------------------------------------
      # ÉTAPE 1 : RÉCUPÉRATION OU FORMATAGE (DESTRUCTIF)
      # -----------------------------------------------------------------
      if blkid -L $LABEL > /dev/null; then
        echo "✅ Partition $LABEL trouvée. Les données sont intactes."
      else
        echo "⚠️ Partition $LABEL introuvable. Initialisation d'un nouveau Worker..."
        # On cherche le premier disque physique disponible (type disk, non-amovible)
        TARGET_DISK=$(lsblk -dpno NAME,TYPE,RM | awk '$2=="disk" && $3=="0" {print $1}' | head -n 1)
        
        # Sécurité : Si aucun disque n'est branché, on abandonne proprement
        if [ -z "$TARGET_DISK" ]; then exit 0; fi
        
        # Formatage complet du disque
        wipefs -a "$TARGET_DISK"
        parted -s "$TARGET_DISK" mklabel gpt mkpart primary ext4 0% 100%
        
        # udevadm settle est CRITIQUE ici : il force le système à attendre
        # que le noyau ait fini de créer les fichiers virtuels de la nouvelle partition
        udevadm settle
        
        TARGET_PART=$(lsblk -rno NAME "$TARGET_DISK" | awk 'NR==2 {print "/dev/"$1}')
        mkfs.ext4 -L $LABEL "$TARGET_PART"
      fi

      # -----------------------------------------------------------------
      # ÉTAPE 2 : BIND MOUNTS (PERSISTANCE DES DOSSIERS CRITIQUES)
      # -----------------------------------------------------------------
      echo "Montage de la partition sur $MOUNT_POINT..."
      mkdir -p $MOUNT_POINT
      if ! mountpoint -q $MOUNT_POINT; then
        mount -L $LABEL $MOUNT_POINT
      fi
      
      # Persistance de l'identité du nœud K3s
      echo "Persistance du dossier /etc/rancher/node..."
      mkdir -p $MOUNT_POINT/etc_rancher_node
      mkdir -p /etc/rancher/node
      if ! mountpoint -q /etc/rancher/node; then
        mount --bind $MOUNT_POINT/etc_rancher_node /etc/rancher/node
      fi

      # Anticipation pour le stockage distribué des futurs pods (Volumes K8s)
      echo "Persistance du dossier Longhorn sur le disque physique..."
      mkdir -p $MOUNT_POINT/longhorn_data
      mkdir -p /var/lib/longhorn
      if ! mountpoint -q /var/lib/longhorn; then
        mount --bind $MOUNT_POINT/longhorn_data /var/lib/longhorn
      fi

      # -----------------------------------------------------------------
      # ÉTAPE 3 : DÉCHIFFREMENT DES SECRETS À LA VOLÉE (SOPS)
      # -----------------------------------------------------------------
      echo "Déchiffrement du token K3s avec la clé SSH locale..."

      # Génération de la clé maître si c'est le tout premier boot de ce PC
      if [ ! -f "$MOUNT_POINT/ssh_host_ed25519_key" ]; then
        ssh-keygen -t ed25519 -f "$MOUNT_POINT/ssh_host_ed25519_key" -N "" -q
      fi

      # Conversion de l'identité SSH en clé Age pour déverrouiller SOPS
      export SOPS_AGE_KEY=$(ssh-to-age -private-key -i $MOUNT_POINT/ssh_host_ed25519_key)

      # Extraction chirurgicale du mot de passe k3s depuis le coffre-fort YAML
      sops -d --extract '["k3s_token"]' /etc/secrets.yaml > $MOUNT_POINT/k3s_token

      # Sécurisation stricte : seul le compte root a le droit de lire ce mot de passe
      chmod 600 $MOUNT_POINT/k3s_token

      echo "🚀 Stockage local et secrets prêts ! K3s va pouvoir démarrer."
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
