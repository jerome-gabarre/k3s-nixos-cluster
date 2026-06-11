#!/usr/bin/env bash
set -e

echo "📂 1/5 - Synchronisation intelligente vers le Pi (via rsync)..."
# On synchronise tout le dossier courant (./) vers le Pi
# Mais on exclut Git, GitHub, et les secrets SOPS pour ne pas casser le Pi
rsync -avz --exclude='.git' --exclude='.github' --exclude='secrets.yaml' ./ root@192.168.10.103:/etc/nixos/

echo "🚀 2/5 - Compilation de l'infrastructure sur Windows..."
nix-build '<nixpkgs/nixos>' -A system -I nixos-config=./configuration.nix

echo "📦 3/5 - Envoi sécurisé au Raspberry Pi..."
nix-copy-closure --to root@192.168.10.103 ./result

echo "🔄 4/5 - Activation du nouveau système..."
ssh root@192.168.10.103 "$(readlink result)/bin/switch-to-configuration switch"

echo "🚢 5/5 - Déploiement des manifestes Kubernetes..."
# On se connecte au Pi et on applique tout le dossier k8s/system de manière récursive
ssh root@192.168.10.103 "kubectl apply -f /etc/nixos/k8s/system/ --recursive"

echo "✅ Infrastructure et Applicatif déployés avec succès !"