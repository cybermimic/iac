#!/usr/bin/env python3
"""Vérifie la documentation du repo.

- Liens Markdown relatifs : la cible existe.
- ADR : un numéro n'est utilisé qu'une fois (collision vue le 2026-10-27 entre deux PR).
- README de feature : les sections exigées par CLAUDE.md sont présentes.

    ./hack/check-docs.py
"""

import re
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LINK = re.compile(r"\]\(([^)\s]+)\)")
# Sections communes à toutes les features existantes (CLAUDE.md, « Documenter chaque
# feature »). Installation n'en fait pas partie : certaines features n'en ont pas
# (ex. actions-runners, livrée par ArgoCD sans étape manuelle propre).
REQUIRED_SECTIONS = (
    "Objectif",
    "Dépendances",
    "Ressources approximatives",
    "Upgrade",
    "Rollback",
    "Troubleshooting",
)


def markdown_files() -> list[Path]:
    return sorted(p for p in ROOT.rglob("*.md") if ".git" not in p.parts)


def check_links() -> list[str]:
    errors = []
    for md in markdown_files():
        text = md.read_text(encoding="utf-8")
        # Les blocs de code ne contiennent pas de vrais liens.
        text = re.sub(r"```.*?```", "", text, flags=re.DOTALL)
        for target in LINK.findall(text):
            if re.match(r"^[a-z][a-z0-9+.-]*:", target) or target.startswith("#"):
                continue
            path = target.split("#", 1)[0]
            if path and not (md.parent / path).exists():
                errors.append(f"{md.relative_to(ROOT)} : lien cassé vers {target}")
    return errors


def check_adr_numbers() -> list[str]:
    by_number = defaultdict(list)
    for adr in (ROOT / "docs" / "adr").glob("ADR-*.md"):
        match = re.match(r"ADR-(\d{3})-", adr.name)
        if match is None:
            by_number["format"].append(adr.name)
        else:
            by_number[match.group(1)].append(adr.name)
    return [
        f"ADR-{number} utilisé plusieurs fois : {', '.join(sorted(names))}"
        if number != "format"
        else f"nom d'ADR hors format ADR-NNN-sujet.md : {', '.join(names)}"
        for number, names in sorted(by_number.items())
        if len(names) > 1 or number == "format"
    ]


def check_feature_readmes() -> list[str]:
    errors = []
    for feature in sorted((ROOT / "features").glob("*/*")):
        if not feature.is_dir():
            continue
        readme = feature / "README.md"
        if not readme.exists():
            errors.append(f"{feature.relative_to(ROOT)} : README.md manquant")
            continue
        headings = {
            h.strip() for h in re.findall(r"^## (.+)$", readme.read_text(encoding="utf-8"), re.M)
        }
        missing = [s for s in REQUIRED_SECTIONS if not any(h.startswith(s) for h in headings)]
        if missing:
            errors.append(f"{readme.relative_to(ROOT)} : sections manquantes : {', '.join(missing)}")
    return errors


def main() -> int:
    errors = check_links() + check_adr_numbers() + check_feature_readmes()
    for error in errors:
        print(error)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
