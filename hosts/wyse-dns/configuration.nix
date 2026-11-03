# =====================================================================
# ⚠️ RÔLE : DNS-RESOLVER HORS BANDE (EDGE DNS - BARE-METAL)
# =====================================================================
{ config, lib, pkgs, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  nixpkgs.hostPlatform = "x86_64-linux";
  networking.hostName = "wyse-dns";
  networking.networkmanager.enable = true;

  # Bootloader EFI limité à 3 générations pour protéger l'espace eMMC
  boot.loader.systemd-boot = {
    enable = true;
    configurationLimit = 3;
  };
  boot.loader.efi.canTouchEfiVariables = true;

  # Préservation maximale de l'eMMC : logs et tmp en RAM + compression ZSTD
  fileSystems."/var/log" = {
    device = "none";
    fsType = "tmpfs";
    options = [ "size=256M" "mode=0755" ];
  };
  boot.tmp = {
    useTmpfs = true;
    tmpfsSize = "256M";
  };
  fileSystems."/".options = [ "compress=zstd" "noatime" ];

  # Désactivation stricte de toute mise en veille
  systemd.targets = {
    sleep.enable = false;
    suspend.enable = false;
    hibernate.enable = false;
    hybrid-sleep.enable = false;
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGPDZWfbEfJf4O2b5ACElABkSIiXcwbZWKUA5HuRBlOC admin@cluster-k3s"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEx6r4XlHlJlLPL3ZoCX8+HCFt0grzzlffIuZDLckeqg jerom@jerome"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBc1GQqEyCWsi1xcnk3DxSo6LNdLjIV/4ACyyjlJobpi PC Bureau - Jerome"
  ];

  # AdGuard Home (Binaire natif Go, requêtes parallèles et cache optimisé en RAM)
  services.adguardhome = {
    enable = true;
    openFirewall = true;
    host = "0.0.0.0";
    port = 80;
    mutableSettings = false;
    settings = {
      schema_version = 29;
      dns = {
        bind_hosts = [ "0.0.0.0" ];
        port = 53;
        upstream_mode = "parallel"; # Requêtes parallèles sur tous les résolveurs amont
        cache_size = 33554432;      # 32 Mo de cache DNS en RAM
        cache_optimistic = true;    # Réponse instantanée depuis le cache avec rafraîchissement asynchrone
        bootstrap_dns = [ "1.1.1.1" "9.9.9.9" ];
        upstream_dns = [
          "https://dns.cloudflare.com/dns-query"
          "https://dns.quad9.net/dns-query"
        ];
      };
    };
  };

  # Auto-réparation et plafond mémoire strict sans fuite sur AdGuard Home
  systemd.services.adguardhome = {
    unitConfig.StartLimitIntervalSec = lib.mkForce 0;
    environment = {
      GOMEMLIMIT = "384MiB";
      GOGC = "80";
    };
    serviceConfig = {
      Restart = lib.mkForce "always";
      RestartSec = lib.mkForce "2s";
      MemoryHigh = "400M";
      MemoryMax = "512M";
    };
  };

  system.stateVersion = "26.05";
}