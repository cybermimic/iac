#!/usr/bin/env bash
# Les scripts PowerShell du repo doivent être en ASCII pur : Windows
# PowerShell 5.1 (celui livré avec Windows) lit un script UTF-8 sans BOM
# en Windows-1252. Un caractère comme « — » y devient « â€” », dont le
# dernier octet est lu comme un guillemet fermant : le script ne se parse
# plus. Constaté sur features/security/cert-manager/clients/.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

status=0
while IFS= read -r -d '' f; do
  if LC_ALL=C grep -n -P '[^\x00-\x7F]' "$f"; then
    echo "$f : caractères non ASCII (voir lignes ci-dessus)"
    status=1
  fi
done < <(git ls-files -z '*.ps1')
exit "$status"
