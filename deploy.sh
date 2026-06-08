#!/usr/bin/env bash
set -e

echo "📂 1/5 - Synchronisation des fichiers sources vers le Pi..."
# On copie les fichiers .nix et le script vers le Pi, 
# sans toucher à secrets.yaml qui reste bien au chaud sur le Pi !
scp *.nix deploy.sh root@192.168.10.103:/etc/nixos/

echo "🚀 2/5 - Compilation de l'infrastructure sur Windows..."
nix-build '<nixpkgs/nixos>' -A system -I nixos-config=./configuration.nix

echo "📦 3/5 - Envoi sécurisé au Raspberry Pi..."
nix-copy-closure --to root@192.168.10.103 ./result

echo "🔄 4/5 - Activation du nouveau système..."
ssh root@192.168.10.103 "$(readlink result)/bin/switch-to-configuration switch"

echo "✅ 5/5 - Déploiement terminé avec succès !"