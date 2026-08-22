{ config, lib, pkgs, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  # Bootloader optimisé
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.systemd-boot.configurationLimit = 3;

  # Préservation eMMC
  fileSystems."/var/log" = {
    device = "none";
    fsType = "tmpfs";
    options = [ "size=256M" "mode=0755" ];
  };
  boot.tmp.useTmpfs = true;
  boot.tmp.tmpfsSize = "256M";
  fileSystems."/".options = [ "compress=zstd" ];

  # Garbage Collection
  nix.settings.auto-optimise-store = true;
  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 1d";
  };

  # Réseau
  networking.hostName = "wyse-dns";
  networking.networkmanager.enable = false;
  networking.useDHCP = true;

  # Sécurité SSH (Accès par clé publique uniquement)
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "prohibit-password";
  };

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGPDZWfbEfJf4O2b5ACElABkSIiXcwbZWKUA5HuRBlOC"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEx6r4XlHlJlLPL3ZoCX8+HCFt0grzzlffIuZDLckeqg"
  ];

  # AdGuard Home (Binaire natif Go, léger en RAM)
  services.adguardhome = {
    enable = true;
    openFirewall = true;
    
    # Options NixOS natives (remplacent le sous-bloc settings.http)
    host = "0.0.0.0";
    port = 80;
    
    mutableSettings = false; # Verrouillage GitOps strict
    
    settings = {
      schema_version = 29;
      dns = {
        bind_hosts = [ "0.0.0.0" ];
        port = 53;
        bootstrap_dns = [ "1.1.1.1" "9.9.9.9" ];
        upstream_dns = [
          "https://dns.cloudflare.com/dns-query"
          "https://dns.quad9.net/dns-query"
        ];
      };
    };
  };

  system.stateVersion = "26.05";
}
