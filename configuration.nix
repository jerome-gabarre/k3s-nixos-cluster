# =====================================================================
# ⚠️ ARCHITECTURE MASTER (RASPBERRY PI 4 - ARM64 / 8GB RAM)
# =====================================================================
# RÈGLES DE DÉPLOIEMENT HYBRIDE (NE PAS MODIFIER SUR LE SERVEUR) :
#
# 1. DÉPLOIEMENT OS (NixOS) : Mode "Push" depuis WSL.
#    -> Ne JAMAIS lancer `nixos-rebuild switch` directement ici (Risque OOM).
#    -> Le build est déporté : utiliser les commandes `cd mon-infrastructure`, `nix-shell` puis `deploy-os` depuis le shell.
#
# 2. DÉPLOIEMENT APPLICATIF (k3s) : Mode "Pull" (GitOps via FluxCD).
#    -> L'état du cluster applicatif est géré de manière autonome.
#    -> Toute modification manuelle des pods via SSH/kubectl sera écrasée.
#    -> Modifier les manifestes locaux et pousser via les commandes `cd mon-infrastructure`, `nix-shell` puis `git-sync`.
# =====================================================================

{ config, pkgs, ... }:

let
  nixos-hardware = fetchTarball "https://github.com/NixOS/nixos-hardware/archive/master.tar.gz";
  
  # On demande à Nix d'évaluer la configuration de notre worker en x86_64
  workerImage = import <nixpkgs/nixos> {
    configuration = ./worker-pxe.nix;
    system = "x86_64-linux";
  };
in
{
  # --- INCLUSION DE LA CONFIGURATION MATÉRIELLE OBLIGATOIRE ---
  imports =
    [ 
      ./hardware-configuration.nix
      "${nixos-hardware}/raspberry-pi/4"
    ];

  # --- ARCHITECTURE CIBLE DU MASTER ---
  nixpkgs.hostPlatform = "aarch64-linux";

  services.journald.extraConfig = ''
    SystemMaxUse=100M
    MaxRetentionSec=3d
  '';

  # --- ACTIVATION DE L'ÉMULATION X86_64 (CRITIQUE) ---
  # Permet au Raspberry Pi (ARM) d'assembler l'image pour le PC (Intel/AMD)
  # boot.binfmt.emulatedSystems = [ "x86_64-linux" ];

  # --- BOOTLOADER ET NOYAU ---
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;
  
  # NOYAU RPI4 (Le seul qui comprend le DSI correctement)
  boot.kernelPackages = pkgs.linuxPackages_rpi4;

  # Activation des cgroups mémoire
  boot.kernelParams = [
    "cgroup_enable=cpuset"
    "cgroup_memory=1"
    "cgroup_enable=memory"
    "systemd.unified_cgroup_hierarchy=1" # Active Cgroup v2 pour le contrôle strict des I/O par kubelet
  ];

  # --- CONFIGURATIONS MATÉRIELLES SUPPLÉMENTAIRES ---
  hardware.deviceTree.enable = false;
  hardware.i2c.enable = true;

  # --- PRÉREQUIS POUR LONGHORN (STOCKAGE K8S) ---
  services.openiscsi.enable = true;
  services.openiscsi.name = "iqn.2016-04.com.open-iscsi:${config.networking.hostName}";

  systemd.tmpfiles.rules = [
    "L+ /usr/bin/iscsiadm - - - - ${pkgs.openiscsi}/bin/iscsiadm"
    "L+ /usr/local/bin/iscsiadm - - - - ${pkgs.openiscsi}/bin/iscsiadm"
  ];

  # --- ALLOCATION RAM VIDEO ET MODULES ---
  boot.kernelModules = [ 
    "i2c-dev" 
    "i2c-bcm2835" 
    "goodix" 
  ];
  
  # Activation de l'accélération matérielle vidéo (Nécessaire pour vc4)
  hardware.graphics.enable = true;

  # --- VOS CONFIGURATIONS ---

  # Configuration du serveur SSH
  services.openssh = {
    enable = true;
    	settings = {
  	PasswordAuthentication = false;
  	PermitRootLogin = "prohibit-password"; # Autorise Root uniquement via Clé SSH
	};
  };

  # --- MAINTENANCE K3S : OPTIMISATION DE LA BASE SQLITE ---
  systemd.services.k3s-sqlite-vacuum = {
    description = "Defragmentation et nettoyage de la base K3s (SQLite)";
    path = [ pkgs.sqlite ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
    };
    script = ''
      echo "Démarrage de l'optimisation de la base K3s..."
      # busy_timeout: attend jusqu'à 5s si k3s verrouille la base
      # wal_checkpoint(TRUNCATE): force l'écriture du journal WAL dans la base principale
      # VACUUM: reconstruit le fichier pour libérer l'espace disque physique
      sqlite3 /var/lib/rancher/k3s/server/db/state.db 'PRAGMA busy_timeout=5000; PRAGMA wal_checkpoint(TRUNCATE); VACUUM;'
      echo "Optimisation terminée."
    '';
  };

  systemd.timers.k3s-sqlite-vacuum = {
    wantedBy = [ "timers.target" ];
    partOf = [ "k3s-sqlite-vacuum.service" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:00:00"; # Tous les jours à 3h00 du matin
      Persistent = true;                 # Rattrape l'exécution si le Pi était éteint
      RandomizedDelaySec = "10m";        # Évite les pics de charge à la seconde pile
    };
  };

  # Définition déclarative de l'utilisateur
  users.users.nixos = {
    isNormalUser = true;
    extraGroups = [ "wheel" ]; # Permet d'utiliser sudo
    # Clé SSH :
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGPDZWfbEfJf4O2b5ACElABkSIiXcwbZWKUA5HuRBlOC admin@cluster-k3s"
    ];
  };

  # Définition de l'utilisateur système root
  users.users.root = {
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGPDZWfbEfJf4O2b5ACElABkSIiXcwbZWKUA5HuRBlOC admin@cluster-k3s"
    ];
  };

  # Autoriser l'élévation de privilèges sans mot de passe pour le groupe wheel (puisque l'authentification se fait par clé SSH)
  security.sudo.wheelNeedsPassword = false;


  # Activation du serveur X11 (nécessaire pour l'interface graphique)
  # services.xserver.enable = true;
  # Activation de l'environnement de bureau léger XFCE
  # services.xserver.desktopManager.xfce.enable = true;

  # services.xserver.displayManager.lightdm.greeters.gtk.extraConfig = ''
  #   keyboard=onboard
  #   show-indicators=~language;~a11y;~session;~power
  # '';

  # Activation du serveur RDP (pour la Connexion Bureau à distance Windows)
  # services.xrdp = {
  #   enable = true;
  #   defaultWindowManager = "xfce4-session"; # Indique à xrdp de lancer XFCE
  #   openFirewall = true; # Ouvre automatiquement le port 3389 dans le pare-feu
  # };

  # --- MONTAGE AUTOMATIQUE DU FIRMWARE (OBLIGATOIRE POUR SAUVEGARDE) ---
  fileSystems."/boot/firmware" = {
    device = "/dev/disk/by-uuid/2178-694E";
    fsType = "vfat";
    # Options pour que l'utilisateur root puisse lire/écrire sans souci
    options = [ "fmask=0022" "dmask=0022" ];
  };

  # --- PARAMÈTRE SYSTÈME OBLIGATOIRE ---
  # Cette ligne est requise pour la gestion des versions d'état de NixOS.
  system.stateVersion = "25.11";

  # --- SÉCURITÉ : PARE-FEU MASTER ---
  networking.firewall.enable = true;

  # TOLÉRANCE AU ROUTAGE ASYMÉTRIQUE DU CNI (FLANNEL)
  networking.firewall.checkReversePath = "loose";
  
  # Confiance absolue sur les interfaces réseau internes du cluster k3s
  networking.firewall.trustedInterfaces = [ "cni0" "flannel.1" "flannel-wg" ];
  # Ouverture des ports vitaux pour la grappe
  networking.firewall.allowedTCPPorts = [ 
    22    # SSH (Authentification sécurisée par clé configurée)
    6443  # API Kubernetes k3s (Communication vitale avec les Workers)
    80    # Ingress HTTP
    8088  # API/Statut Pixiecore
  ];

  # Ouverture de la plage NodePort pour l'accès externe aux applications
  networking.firewall.allowedTCPPortRanges = [
    { from = 30000; to = 32767; }
  ];
  
  networking.firewall.allowedUDPPorts = [
    8472  # Flannel VXLAN (Communication overlay inter-noeuds k3s)
    51820 # Flannel WireGuard IPv4
    51821 # Flannel WireGuard IPv6
  ];

  # --- CONFIGURATION RÉSEAU ET WI-FI ---
  # NetworkManager est le standard industriel pour gérer le Wi-Fi facilement
  networking.networkmanager.enable = true;
  boot.blacklistedKernelModules = [ "brcmfmac" "brcmutil" ];
  # Optionnel : définir le nom de la machine sur le réseau
  networking.hostName = "k3s-master";

  # --- OPTIMISATIONS DES PERFORMANCES (NIXOS) ---
  
  # Forcer le processeur en mode performance (utile pour l'overclocking et etcd)
  powerManagement.cpuFreqGovernor = "performance";
  
  # Activation du ZRAM (Ultra Critique)
  zramSwap.enable = true;

  # --- ORCHESTRATION K3S (NŒUD MAÎTRE) ---

  services.k3s = {
    enable = true;
    # renovate: datasource=github-releases depName=k3s-io/k3s
    package = pkgs.k3s_1_31;
    role = "server"; # Rôle master
    
    # Déclaration explicite du Taint et autres arguments de démarrage
    extraFlags = toString [
      # Empêche la planification des pods normaux sur ce noeud
      "--node-taint node-role.kubernetes.io/control-plane=true:NoSchedule"
      # On force l'IP filaire pour toutes les communications du cluster
      "--node-ip=192.168.10.103"
      "--advertise-address=192.168.10.103"
      "--node-label svccontroller.k3s.cattle.io/enable=false"
      # Désactivation du LoadBalancer par défaut (Klipper) pour installer MetalLB
      "--disable=servicelb"
      # Activation de WireGuard
      "--flannel-backend=wireguard-native"
      # Désactivation du Traefik par défaut pour gestion GitOps via Flux
      "--disable=traefik"
      "--disable=local-storage"
      "--kubelet-arg=container-log-max-size=10Mi"
      "--kubelet-arg=container-log-max-files=3"
    ];
  };

  # --- PAQUETS SYSTÈME ---
  environment.systemPackages = with pkgs; [
    vim
    wget
    git
    rclone
    libinput   # Pour tester le tactile
    i2c-tools  # Pour scanner le bus (I2C)
    usbutils   # Commande lsusb
    lshw
    inxi
    pciutils
    hwinfo
    btop
    onboard
    util-linux
    nfs-utils
    openiscsi
    nftables

  ];

  # --- SAUVEGARDE AUTOMATIQUE VERS GOOGLE DRIVE ---
  systemd.services.backup-config-gdrive = {
    description = "Backup NixOS config, K3s state and secrets to Google Drive";
    path = [ pkgs.coreutils pkgs.inetutils pkgs.sqlite pkgs.rclone ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
    };
    script = ''
 # 1. Variables
 DATE=$(date +%Y-%m-%d)
 HOSTNAME=$(hostname)
 BACKUP_DIR="/tmp/backup_staging"
 REMOTE="gdrive:NixOS-Backups/$HOSTNAME"

 # 2. Préparation
 rm -rf $BACKUP_DIR
 mkdir -p $BACKUP_DIR/nixos
 mkdir -p $BACKUP_DIR/k3s-state

 # 3. Copie des fichiers vitaux (Architecture NixOS)
 echo "Sauvegarde de l'environnement NixOS local..."
 cp -a /etc/nixos/. $BACKUP_DIR/nixos/
 
 # Exclure le lien symbolique 'result' généré par nix-build
 rm -f $BACKUP_DIR/nixos/result

 if [ -f /boot/firmware/config.txt ]; then
   echo "Sauvegarde du config.txt..."
   cp /boot/firmware/config.txt $BACKUP_DIR/
 fi

 # 4. Sauvegarde de l'état K3s (Cerveau du Cluster)
 echo "Sauvegarde de la base de données K3s et des certificats TLS..."
 sqlite3 /var/lib/rancher/k3s/server/db/state.db ".backup '$BACKUP_DIR/k3s-state/state.db'"
 cp -a /var/lib/rancher/k3s/server/tls $BACKUP_DIR/k3s-state/

 # 5. Envoi Cloud : Sync pour Latest, Copy pour History
 # Ajout du --tpslimit 4 pour ne pas déclencher l'anti-spam de l'API Google
 echo "Upload vers Google Drive..."
 rclone sync $BACKUP_DIR "$REMOTE/latest" --tpslimit 4
 rclone copy $BACKUP_DIR "$REMOTE/history/$DATE" --tpslimit 4
 
 # --- PURGE DES VIEUX FICHIERS (> 30 Jours) ---
 echo "Nettoyage des archives de plus de 30 jours..."
 rclone delete "$REMOTE/history" --min-age 30d --tpslimit 4 || true
 rclone rmdirs "$REMOTE/history" --leave-root --tpslimit 4 || true
 
 # 6. Nettoyage local
 rm -rf $BACKUP_DIR
 echo "Sauvegarde terminée avec succès."
 '';
  };

  systemd.timers.backup-config-gdrive = {
    wantedBy = [ "timers.target" ];
    partOf = [ "backup-config-gdrive.service" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "5m";
    };
  };

  # --- CONFIGURATION DU SERVEUR PXE (PIXIECORE) ---
  services.pixiecore = {
    enable = true;
    openFirewall = true;
    dhcpNoBind = true;
    mode = "boot";
    port = 8088;         # On libère le port 80 pour K3s
    statusPort = 8088;
    # On pointe vers les fichiers générés par l'évaluation du workerImage
    kernel = "${workerImage.config.system.build.kernel}/bzImage";
    initrd = "${workerImage.config.system.build.netbootRamdisk}/initrd";
    # Les paramètres passés au noyau du worker au démarrage
    cmdLine = "init=${workerImage.config.system.build.toplevel}/init loglevel=4";
  };

  # --- AUTOMATISATION DU NETTOYAGE ET OPTIMISATION ---
  nix = {
    gc = {
      automatic = true;
      dates = "daily"; # Se lance tous les jours
      options = "--delete-older-than 1d"; # SUPPRIME les versions de plus de 1 jours
    };
    optimise = {
      automatic = true;
      dates = [ "daily" ]; # DÉDOUBLONNE le store tous les jours en arrière-plan
    };
    settings.auto-optimise-store = true; # Dédoublonne aussi à la volée pendant la compilation
  };

}
