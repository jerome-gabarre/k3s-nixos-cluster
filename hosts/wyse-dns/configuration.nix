# =====================================================================
# ⚠️ RÔLE : DNS-RESOLVER HORS BANDE (EDGE DNS - BARE-METAL)
# =====================================================================
{ config, lib, pkgs, clusterIps, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  nixpkgs.hostPlatform = "x86_64-linux";
  networking.hostName = "wyse-dns";
  networking.networkmanager.enable = true;

  # Ouverture explicite du port DNS 53 (UDP/TCP) et de l'interface Web (80)
  networking.firewall = {
    enable = true;
    allowedUDPPorts = [ 53 ];
    allowedTCPPorts = [ 22 53 80 ];
  };

  boot.loader.systemd-boot = {
    enable = true;
    configurationLimit = 3;
  };
  boot.loader.efi.canTouchEfiVariables = true;

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

  security.sudo.wheelNeedsPassword = false;

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGPDZWfbEfJf4O2b5ACElABkSIiXcwbZWKUA5HuRBlOC admin@cluster-k3s"
  ];

  # AdGuard Home avec réécriture déclarative *.home.arpa vers Traefik (192.168.10.51)
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
        upstream_mode = "parallel";
        cache_size = 33554432;
        cache_optimistic = true;
        bootstrap_dns = [ "1.1.1.1" "9.9.9.9" ];
        upstream_dns = [
          "https://dns.cloudflare.com/dns-query"
          "https://dns.quad9.net/dns-query"
        ];
      };
      filtering = {
        rewrites_enabled = true;
        rewrites = [
          {
            domain = "*.home.arpa";
            answer = "192.168.10.51";
          }
          {
            domain = "home.arpa";
            answer = "192.168.10.51";
          }
        ];
      };
    };
  };

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
