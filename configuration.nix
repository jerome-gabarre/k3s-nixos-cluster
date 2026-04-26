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

  # --- ACTIVATION DE L'ÉMULATION X86_64 (CRITIQUE) ---
  # Permet au Raspberry Pi (ARM) d'assembler l'image pour le PC (Intel/AMD)
  boot.binfmt.emulatedSystems = [ "x86_64-linux" ];

  # --- BOOTLOADER ET NOYAU ---
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;
  
  # NOYAU RPI4 (Le seul qui comprend le DSI correctement)
  boot.kernelPackages = pkgs.linuxPackages_rpi4;

  # --- CONFIGURATIONS MATÉRIELLES SUPPLÉMENTAIRES ---
  hardware.deviceTree.enable = false;
  hardware.i2c.enable = true;

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

  # Définition déclarative de l'utilisateur
  users.users.nixos = {
    isNormalUser = true;
    extraGroups = [ "wheel" ]; # Permet d'utiliser sudo
    initialPassword = "CHANGE_ME_MOT_DE_PASSE";
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


  # Activation du serveur X11 (nécessaire pour l'interface graphique)
  services.xserver.enable = true;
  # Activation de l'environnement de bureau léger XFCE
  services.xserver.desktopManager.xfce.enable = true;

  services.xserver.displayManager.lightdm.greeters.gtk.extraConfig = ''
    keyboard=onboard
    show-indicators=~language;~a11y;~session;~power
  '';

  # Activation du serveur RDP (pour la Connexion Bureau à distance Windows)
  services.xrdp = {
    enable = true;
    defaultWindowManager = "xfce4-session"; # Indique à xrdp de lancer XFCE
    openFirewall = true; # Ouvre automatiquement le port 3389 dans le pare-feu
  };

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

  # --- 1. CONFIGURATION RÉSEAU ET WI-FI ---
  # NetworkManager est le standard industriel pour gérer le Wi-Fi facilement
  networking.networkmanager.enable = true;
  boot.blacklistedKernelModules = [ "brcmfmac" "brcmutil" ];
  # Optionnel : définir le nom de la machine sur le réseau
  networking.hostName = "k3s-master";

  # --- 2. OPTIMISATIONS DES PERFORMANCES (NIXOS) ---
  
  # Forcer le processeur en mode performance (utile pour l'overclocking)
  powerManagement.cpuFreqGovernor = "schedutil";
  
  # Activation du ZRAM (Ultra Critique)
  zramSwap.enable = true;

  # --- 3. OPTIMISATION DU STOCKAGE NIX ---
  nix.settings.auto-optimise-store = true;
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 15d";
  };

  # --- 4. ORCHESTRATION K3S (NŒUD MAÎTRE) ---
  
  # Ouverture du port vital pour que les "Workers" (votre PC) puissent communiquer avec le Master
  networking.firewall.allowedTCPPorts = [ 6443 ];

  services.k3s = {
    enable = true;
    role = "server"; # Rôle master
    
    # Déclaration explicite du Taint et autres arguments de démarrage
    extraFlags = toString [
      # Empêche la planification des pods normaux sur ce noeud
      "--node-taint node-role.kubernetes.io/control-plane=true:NoSchedule"
      # On force l'IP filaire pour toutes les communications du cluster
      "--node-ip=192.168.10.103"
      "--advertise-address=192.168.10.103"
      # Optionnel mais recommandé : Désactive Traefik et Servicelb
      "--disable traefik"
      "--disable servicelb"
    ];
  };

  # --- 5. PAQUETS SYSTÈME ---
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

  ];

  # --- 6. SAUVEGARDE AUTOMATIQUE VERS GOOGLE DRIVE ---
  systemd.services.backup-config-gdrive = {
    description = "Backup NixOS config and K3s token to Google Drive";
    path = [ pkgs.coreutils pkgs.inetutils ];
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
      mkdir -p $BACKUP_DIR

      # 3. Copie des fichiers vitaux
      echo "Sauvegarde de la configuration NixOS..."
      cp /etc/nixos/*.nix $BACKUP_DIR/
      
      if [ -f /boot/firmware/config.txt ]; then
        echo "Sauvegarde du config.txt..."
        cp /boot/firmware/config.txt $BACKUP_DIR/
      fi

      if [ -f /var/lib/rancher/k3s/server/node-token ]; then
        echo "Sauvegarde du Token K3s..."
        cp /var/lib/rancher/k3s/server/node-token $BACKUP_DIR/k3s-node-token.txt
      fi

      # 4. Envoi Cloud
      echo "Upload vers Google Drive..."
      ${pkgs.rclone}/bin/rclone copy $BACKUP_DIR "$REMOTE/latest"
      ${pkgs.rclone}/bin/rclone copy $BACKUP_DIR "$REMOTE/history/$DATE"
      
      # --- PURGE DES VIEUX FICHIERS (> 30 Jours) ---
      echo "Nettoyage des archives de plus de 30 jours..."
      ${pkgs.rclone}/bin/rclone delete "$REMOTE/history" --min-age 30d --rmdirs
      
      # 5. Nettoyage local
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

  # --- 7. CONFIGURATION DU SERVEUR PXE (PIXIECORE) ---
  services.pixiecore = {
    enable = true;
    openFirewall = true;
    dhcpNoBind = true;
    mode = "boot";
    # On pointe vers les fichiers générés par l'évaluation du workerImage
    kernel = "${workerImage.config.system.build.kernel}/bzImage";
    initrd = "${workerImage.config.system.build.netbootRamdisk}/initrd";
    # Les paramètres passés au noyau du worker au démarrage
    cmdLine = "init=${workerImage.config.system.build.toplevel}/init loglevel=4";
  };
}
