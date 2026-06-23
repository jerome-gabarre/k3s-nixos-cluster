{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  # Déclaration des paquets requis pour travailler sur ce dépôt
  buildInputs = with pkgs; [
    rsync
    git
    openssh
  ];

  # Message d'accueil et fonctions Bash
  shellHook = ''
    echo "======================================================"
    echo "🛠️  ENVIRONNEMENT DE DÉPLOIEMENT HYBRIDE (K3S / NIXOS)"
    echo "======================================================"
    echo "Commandes disponibles :"
    echo "  deploy-os   -> Compile et pousse la config NixOS vers le Master"
    echo "  git-sync    -> Ajoute, commit et pousse le code pour FluxCD (k3s)"
    echo "======================================================"

    # Fonctions Bash qui remplacent l'ancien script
    deploy-os() {
      echo "📂 1 - Synchronisation intelligente vers le Pi (via rsync)..."
      rsync -avz --exclude='.git' --exclude='.github' --exclude='secrets.yaml' ./ root@192.168.10.103:/etc/nixos/

      echo "🚀 2 - Compilation de l'infrastructure sur Windows..."
      nix-build '<nixpkgs/nixos>' -A system -I nixos-config=./configuration.nix

      echo "📦 3 - Envoi sécurisé au Raspberry Pi..."
      nix-copy-closure --to root@192.168.10.103 ./result

      echo "🔄 4 - Activation du nouveau système..."
      ssh root@192.168.10.103 "\$(readlink result)/bin/switch-to-configuration switch"

      echo "✅ Couche Système déployée avec succès !"
    }

    git-sync() {
      echo "🚀 Poussée des modifications vers GitHub pour FluxCD..."
      git add .
      git commit -m "Auto-sync via shell.nix"
      git push
      echo "✅ Code envoyé ! FluxCD va appliquer les manifestes k3s."
    }
  '';
}