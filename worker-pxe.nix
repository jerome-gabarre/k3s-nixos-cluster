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
  networking.networkmanager.enable = true;

  # --- CRITIQUE POUR LE MATÉRIEL DE RÉCUPÉRATION ---
  # Charge tous les pilotes propriétaires (Realtek, Intel, Broadcom...)
  hardware.enableRedistributableFirmware = true;

  # --- PARAMÈTRE SYSTÈME OBLIGATOIRE ---
  # Cette ligne est requise pour la gestion des versions d'état de NixOS.
  system.stateVersion = "25.11";


  # Activation SSH
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
  };

  # Clés SSH (Windows + Pi)
  users.users.root = {
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGPDZWfbEfJf4O2b5ACElABkSIiXcwbZWKUA5HuRBlOC admin@cluster-k3s" 
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBkzXmKDx+HcklREJcMUBTt6ID69XGxDfg16OGGNmOGl root@k3s-master" 
    ];
  };
 }
