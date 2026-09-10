{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  buildInputs = with pkgs; [
    rsync
    git
    openssh
    fluxcd
    kubectl
    ssh-to-age
    sops
    nmap
    k9s
    tree
  ];

  shellHook = ''
    echo "======================================================"
    echo "🛠️  ENVIRONNEMENT DE DÉPLOIEMENT GITOPS & FLAKES"
    echo "======================================================"

    # Extraction dynamique des IPs depuis la source de vérité (flake.nix)
    export MASTER_IP=$(nix eval --raw .#nixosConfigurations.k3s-master._module.specialArgs.clusterIps.master)
    export DNS_IP=$(nix eval --raw .#nixosConfigurations.wyse-dns._module.specialArgs.clusterIps.dns)

    deploy-os() {
      echo "🚀 Déploiement NixOS (Flake) vers le Master ($MASTER_IP)..."
      # --build-host délègue la compilation ARM64 au Pi directement, 
      # --target-host applique la config, sans rsync manuel.
      NIX_SSHOPTS="-o StrictHostKeyChecking=accept-new" nixos-rebuild switch \
        --flake .#k3s-master \
        --target-host root@$MASTER_IP \
        --build-host root@$MASTER_IP --use-remote-sudo
    }

    deploy-dns() {
      echo "🚀 Déploiement NixOS (Flake) vers le Wyse ($DNS_IP)..."
      NIX_SSHOPTS="-o StrictHostKeyChecking=accept-new" nixos-rebuild switch \
        --flake .#wyse-dns \
        --target-host root@$DNS_IP --use-remote-sudo
    }

    git-sync() {
      echo "🚀 Poussée des modifications vers GitHub pour FluxCD..."
      git add . && git commit -m "Auto-sync via shell.nix" && git push
      echo "✅ Code envoyé !"
    }

    format-worker() {
      local ip=$1
      local dev=$2
      if [ -z "$ip" ] || [ -z "$dev" ]; then
        echo "Usage: format-worker <IP> <DEVICE> (ex: format-worker 192.168.10.105 /dev/sda)"
        return 1
      fi
      echo "⚠️ Formatage destructif de $dev sur $ip..."
      ssh root@$ip "wipefs -a -f $dev && mkfs.xfs -f -L LONGHORN_DAT $dev && echo '✅ Disque formaté et labellisé LONGHORN_DAT'"
    }
  '';
}