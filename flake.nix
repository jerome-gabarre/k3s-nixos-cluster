{
  description = "Infrastructure GitOps K3s & NixOS (Architecture Orientée Rôles & Parallélisation Bas Niveau)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
  };

  outputs = { self, nixpkgs, nixos-hardware, ... }@inputs:
  let
    clusterIps = {
      master = "192.168.10.103";
      dns    = "192.168.10.104";
    };

    commonSpecialArgs = { inherit clusterIps inputs; };
    pkgs = import nixpkgs { system = "x86_64-linux"; };
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    deploy-os = pkgs.writeShellScriptBin "deploy-os" ''
      set -euo pipefail
      export NIX_SSHOPTS="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=15"
      echo "🚀 Évaluation, compilation parallèle (WSL) et déploiement vers k3s-master (${clusterIps.master})..."
      nixos-rebuild switch \
        --flake .#k3s-master \
        --target-host "root@${clusterIps.master}" \
        --build-host "" \
        --option max-jobs auto \
        --option cores 0 \
        --sudo
    '';

    deploy-dns = pkgs.writeShellScriptBin "deploy-dns" ''
      set -euo pipefail
      export NIX_SSHOPTS="-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=15 -o ServerAliveCountMax=12 -o IPQoS=none -o TCPKeepAlive=no"
      echo "🚀 Déploiement NixOS parallèle (Flake) vers wyse-dns (${clusterIps.dns})..."
      nixos-rebuild switch -L \
        --flake .#wyse-dns \
        --target-host "root@${clusterIps.dns}" \
        --option max-jobs auto \
        --option cores 0 \
        --sudo
    '';

    git-sync = pkgs.writeShellScriptBin "git-sync" ''
      set -euo pipefail
      MSG="''${1:-chore(gitops): sync declarative state}"
      echo "🚀 Poussée des modifications vers GitHub pour FluxCD..."
      git add -A
      git commit -m "$MSG" || echo "Aucun changement à valider."
      git push
      echo "✅ Code envoyé !"
    '';

    clean-local = pkgs.writeShellScriptBin "clean-local" ''
      set -euo pipefail
      echo "🧹 Nettoyage et dédoublonnage du Nix store local (WSL)..."
      nix-collect-garbage -d
      nix store optimise
      echo "✅ Espace libéré et dédoublonné sur la machine de déploiement."
    '';

    format-worker = pkgs.writeShellScriptBin "format-worker" ''
      set -euo pipefail
      ip="''${1:-}"
      dev="''${2:-}"
      if [ -z "$ip" ] || [ -z "$dev" ]; then
        echo "Usage: format-worker <IP> <DEVICE> (ex: format-worker 192.168.10.105 /dev/sda)"
        exit 1
      fi
      echo "⚠️ Formatage destructif de $dev sur $ip..."
      ssh "root@$ip" "wipefs -a -f $dev && mkfs.xfs -f -L LONGHORN_DAT $dev && echo '✅ Disque formaté et labellisé LONGHORN_DAT'"
    '';
  in {
    nixosModules.freecad-turbo = ./modules/cfao/freecad-turbo.nix;

    packages = forAllSystems (system:
      let
        sysPkgs = import nixpkgs { inherit system; };
        fcTurbo = sysPkgs.callPackage ./pkgs/freecad-turbo { };
      in {
        inherit (fcTurbo)
          freecadRsEngine
          freecadTurboBase
          freecadNativeLauncher
          freecadWorkerOci;
        default = fcTurbo.freecadNativeLauncher;
      }
    );

    nixosConfigurations = {
      "k3s-master" = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = commonSpecialArgs;
        modules = [
          nixos-hardware.nixosModules.raspberry-pi-4
          ./modules/common/universal-tuning.nix
          ./hosts/k3s-master/configuration.nix
        ];
      };

      "wyse-dns" = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = commonSpecialArgs;
        modules = [
          ./modules/common/universal-tuning.nix
          ./hosts/wyse-dns/configuration.nix
        ];
      };

      "worker-pxe" = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = commonSpecialArgs;
        modules = [
          ./modules/common/universal-tuning.nix
          ./modules/cfao/freecad-turbo.nix
          ./hosts/worker/worker-pxe.nix
          { services.freecadTurbo.enable = true; }
        ];
      };
    };

    devShells."x86_64-linux".default = pkgs.mkShell {
      buildInputs = with pkgs; [
        rsync
        git
        openssh
        fluxcd
        kubectl
        kubernetes-helm
        ssh-to-age
        sops
        age
        nmap
        k9s
        tree
        jq
        yq-go
        ripgrep
        fd
        cargo
        rustc
        pkg-config
        nixos-rebuild
        deploy-os
        deploy-dns
        git-sync
        clean-local
        format-worker
      ];

      shellHook = ''
        export MASTER_IP="${clusterIps.master}"
        export DNS_IP="${clusterIps.dns}"
        echo "======================================================"
        echo "🛠️  ENVIRONNEMENT DE DÉPLOIEMENT GITOPS & FLAKES"
        echo "   Master: $MASTER_IP | DNS: $DNS_IP"
        echo "======================================================"
      '';
    };
  };
}
