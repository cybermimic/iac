#!/usr/bin/env bash
# Installe (ou retire) la CA du homelab dans le magasin système d'un poste
# Debian/Ubuntu (update-ca-certificates).
#
# 1. Récupère le certificat public (URL ou fichier local).
# 2. Vérifie son empreinte SHA-256 contre la valeur ÉPINGLÉE ci-dessous
#    (jamais contre une valeur téléchargée au même endroit : ça ne
#    prouverait rien).
# 3. L'installe s'il n'est pas déjà présent (relançable sans effet de bord).
#
# Usage :
#   sudo ./install-homelab-ca.sh                  # depuis GitHub
#   sudo ./install-homelab-ca.sh --source docs/homelab-root-ca.crt
#   ./install-homelab-ca.sh --check               # vérifie seulement
#   sudo ./install-homelab-ca.sh --uninstall
#
# Firefox sous Linux utilise son propre magasin : voir le README de
# features/security/cert-manager.
set -euo pipefail

# Empreinte SHA-256 de "Homelab Root CA" (docs/homelab-root-ca.crt).
# À mettre à jour ici, dans install-homelab-ca.ps1 et dans le README si la
# CA est un jour régénérée.
expected_sha256="89:C0:C5:2E:A0:00:AB:60:C4:DF:40:4F:49:59:38:FE:8D:3F:04:BB:92:E4:66:D2:27:06:10:3D:0B:7A:F6:7C"
source_ref="https://raw.githubusercontent.com/cybermimic/iac/main/docs/homelab-root-ca.crt"
target="/usr/local/share/ca-certificates/homelab-root-ca.crt"
mode="install"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source) source_ref="$2"; shift 2 ;;
    --check) mode="check"; shift ;;
    --uninstall) mode="uninstall"; shift ;;
    *) echo "Option inconnue : $1" >&2; exit 2 ;;
  esac
done

if [ "$mode" != "check" ] && [ "$(id -u)" -ne 0 ]; then
  echo "Lancer avec sudo (écrit dans le magasin système)." >&2
  exit 1
fi

if [ "$mode" = "uninstall" ]; then
  if [ ! -f "$target" ]; then
    echo "CA non installée : rien à faire."
    exit 0
  fi
  rm -f "$target"
  update-ca-certificates --fresh >/dev/null
  echo "CA retirée."
  exit 0
fi

# 1. Récupération
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
case "$source_ref" in
  http://* | https://*) curl -fsSL "$source_ref" -o "$tmp" ;;
  *) cp "$source_ref" "$tmp" ;;
esac

# 2. Vérification
actual="$(openssl x509 -in "$tmp" -noout -fingerprint -sha256 | cut -d= -f2)"
if [ "$actual" != "$expected_sha256" ]; then
  echo "EMPREINTE INCORRECTE — certificat NON installé." >&2
  echo "  attendue : $expected_sha256" >&2
  echo "  obtenue  : $actual" >&2
  exit 1
fi
echo "Empreinte SHA-256 conforme : $actual ($(openssl x509 -in "$tmp" -noout -subject -enddate | paste -sd' '))"
[ "$mode" = "check" ] && exit 0

# 3. Installation (idempotente)
if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
  echo "Déjà installée : rien à faire."
  exit 0
fi
install -m 0644 "$tmp" "$target"
update-ca-certificates >/dev/null
echo "CA installée."
