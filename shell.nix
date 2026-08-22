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
    echo "🛠️  ENVIRONNEMENT DE DÉPLOIEMENT HYBRIDE (K3S / NIXOS)"
    echo "======================================================"
    echo "Commandes disponibles :"
    echo "  deploy-os    -> Compile et pousse la config NixOS vers le Master"
    echo "  deploy-dns   -> Compile et pousse la config NixOS vers le Wyse 3040"
    echo "  git-sync     -> Ajoute, commit et pousse le code pour FluxCD (k3s)"
    echo "======================================================"

    deploy-os() {
      echo "📂 1 - Synchronisation intelligente vers le Pi (via rsync)..."
      rsync -avz --exclude='.git' --exclude='.github' --exclude='secrets.yaml' ./ root@192.168.10.103:/etc/nixos/ && \

      echo "🚀 2 - Compilation de l'infrastructure sur Windows..." && \
      nix-build '<nixpkgs/nixos>' -A system -I nixos-config=./configuration.nix && \

      echo "📦 3 - Envoi sécurisé au Raspberry Pi..." && \
      nix-copy-closure --to root@192.168.10.103 ./result && \

      echo "🔄 4 - Activation du nouveau système..." && \
      ssh root@192.168.10.103 "$(readlink result)/bin/switch-to-configuration switch" && \

      echo "✅ Couche Système déployée avec succès !" || \
      echo "❌ Échec lors du déploiement OS."
    }

    deploy-dns() {
      echo "📂 1 - Synchronisation des sources vers le Wyse..."
      rsync -avz ./hosts/wyse-dns/ root@192.168.10.104:/etc/nixos/ && \

      echo "🚀 2 - Compilation locale (x86_64) sur WSL2..." && \
      nix-build '<nixpkgs/nixos>' -A system -I nixos-config=./hosts/wyse-dns/configuration.nix && \

      echo "📦 3 - Envoi de la closure au Wyse 3040..." && \
      nix-copy-closure --to root@192.168.10.104 ./result && \

      echo "🔄 4 - Activation du service DNS..." && \
      ssh root@192.168.10.104 "$(readlink result)/bin/switch-to-configuration switch" && \

      echo "✅ Serveur DNS déployé avec succès !" || \
      echo "❌ Échec lors du déploiement DNS."
    }

    git-sync() {
      echo "🚀 Poussée des modifications vers GitHub pour FluxCD..."
      git add . && \
      git commit -m "Auto-sync via shell.nix" && \
      git push && \
      echo "✅ Code envoyé ! FluxCD va appliquer les manifestes k3s." || \
      echo "❌ Échec de la synchronisation Git."
    }
  '';
}