{
  description = "Infrastructure GitOps K3s & NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
  };

  outputs = { self, nixpkgs, nixos-hardware, ... }@inputs:
  let
    # Dictionnaire centralisé des IPs
    clusterIps = {
      master = "192.168.10.103";
      dns    = "192.168.10.104";
    };
    
    # Configuration du shell de développement pour WSL/x86_64
    pkgs = import nixpkgs { system = "x86_64-linux"; };
  in {
    nixosConfigurations = {
      "k3s-master" = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = { inherit clusterIps inputs; };
        modules = [
          nixos-hardware.nixosModules.raspberry-pi-4
          ./hosts/k3s-master/configuration.nix
        ];
      };

      "wyse-dns" = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit clusterIps inputs; };
        modules = [
          ./hosts/wyse-dns/configuration.nix
        ];
      };

      "worker-pxe" = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit clusterIps inputs; };
        modules = [
          ./hosts/worker/worker-pxe.nix
        ];
      };
    };

    # Environnement de déploiement (Remplace le shell.nix)
    devShells."x86_64-linux".default = pkgs.mkShell {
      buildInputs = with pkgs; [
        rsync git openssh fluxcd kubectl ssh-to-age sops nmap k9s tree nixos-rebuild
      ];

      shellHook = ''
        echo "======================================================"
        echo "🛠️  ENVIRONNEMENT DE DÉPLOIEMENT GITOPS & FLAKES"
        echo "======================================================"

        export MASTER_IP="${clusterIps.master}"
        export DNS_IP="${clusterIps.dns}"

        deploy-os() {
          export NIX_SSHOPTS="-o StrictHostKeyChecking=accept-new"
          
          echo "🚀 1/3 - Compilation native de l'image PXE (x86_64) sur WSL..."
          nix build --no-link .#nixosConfigurations.worker-pxe.config.system.build.toplevel \
                              .#nixosConfigurations.worker-pxe.config.system.build.kernel \
                              .#nixosConfigurations.worker-pxe.config.system.build.netbootRamdisk
          
          echo "📦 2/3 - Transfert silencieux des binaires x86_64 vers le cache du Master..."
          nix copy .#nixosConfigurations.worker-pxe.config.system.build.toplevel \
                   .#nixosConfigurations.worker-pxe.config.system.build.kernel \
                   .#nixosConfigurations.worker-pxe.config.system.build.netbootRamdisk \
                   --to ssh://root@$MASTER_IP
                   
          echo "🚀 3/3 - Compilation ARM64 et déploiement du Master NixOS..."
          nixos-rebuild switch \
            --flake .#k3s-master \
            --target-host root@$MASTER_IP \
            --build-host root@$MASTER_IP --sudo
        }

        deploy-dns() {
          echo "🚀 Déploiement NixOS (Flake) vers le Wyse ($DNS_IP)..."
          NIX_SSHOPTS="-o StrictHostKeyChecking=accept-new" nixos-rebuild switch \
            --flake .#wyse-dns \
            --target-host root@$DNS_IP --sudo
        }

        git-sync() {
          echo "🚀 Poussée des modifications vers GitHub pour FluxCD..."
          git add . && git commit -m "Auto-sync via Flake env" && git push
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
    };
  };
}