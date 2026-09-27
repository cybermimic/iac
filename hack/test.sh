#!/usr/bin/env bash
# Orchestrateur de validations locales. Chaque check est ignoré (avec un
# avertissement) si l'outil correspondant n'est pas installé — le repo est
# encore en phase de scaffolding et tous les layers n'existent pas encore.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

status=0

run_check() {
  local name="$1"
  shift
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "SKIP  ${name}: '$1' non installé"
    return 0
  fi
  echo "RUN   ${name}"
  if "$@"; then
    echo "OK    ${name}"
  else
    echo "FAIL  ${name}"
    status=1
  fi
}

# Terraform
if find infrastructure features -name '*.tf' -print -quit 2>/dev/null | grep -q .; then
  run_check "terraform fmt" terraform fmt -check -recursive infrastructure features
fi

# Ansible
if find bootstrap -name '*.yml' -print -quit 2>/dev/null | grep -q .; then
  run_check "ansible-lint" ansible-lint bootstrap
fi

# YAML
run_check "yamllint" yamllint .

# Shell
mapfile -t shell_files < <(find . -name '*.sh' -not -path './.git/*')
if [ "${#shell_files[@]}" -gt 0 ]; then
  run_check "shellcheck" shellcheck "${shell_files[@]}"
fi

# CA du homelab : empreinte épinglée dans les scripts = certificat versionné
if [ -f docs/homelab-root-ca.crt ]; then
  run_check "homelab CA fingerprint" ./hack/check-ca-fingerprint.sh
fi

exit "$status"
