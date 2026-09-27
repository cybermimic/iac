#!/usr/bin/env bash
# Vérifie que l'empreinte SHA-256 épinglée dans les scripts d'installation
# de la CA correspond bien au certificat versionné (docs/homelab-root-ca.crt).
# Évite qu'une régénération de la CA laisse des scripts qui refusent le
# nouveau certificat (ou pire, qu'on "corrige" un script à la main).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

crt="docs/homelab-root-ca.crt"
clients="features/security/cert-manager/clients"

actual="$(openssl x509 -in "$crt" -noout -fingerprint -sha256 | cut -d= -f2)"
actual_nocolon="${actual//:/}"

status=0
if ! grep -q "expected_sha256=\"${actual}\"" "$clients/install-homelab-ca.sh"; then
  echo "install-homelab-ca.sh : empreinte différente de $crt ($actual)"
  status=1
fi
if ! grep -q "\$ExpectedSha256 = \"${actual_nocolon}\"" "$clients/install-homelab-ca.ps1"; then
  echo "install-homelab-ca.ps1 : empreinte différente de $crt ($actual_nocolon)"
  status=1
fi
if ! grep -q "${actual}" features/security/cert-manager/README.md; then
  echo "README cert-manager : empreinte différente de $crt ($actual)"
  status=1
fi
exit "$status"
