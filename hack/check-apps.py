#!/usr/bin/env python3
"""Rend chaque Application ArgoCD de gitops/apps/ comme ArgoCD, puis la vérifie.

Pour chaque source d'une Application :
- chart Helm (dépôt Helm, OCI ou dossier d'un dépôt Git public) : `helm template` avec ses
  `valuesObject` ;
- dossier de ce repo : les fichiers YAML tels quels (récursivement si `directory.recurse`) ;
- dépôt privé (git@…) : SKIP explicite, la CI n'y a pas accès.

Puis, sur le rendu :
- validation des schémas (kubeconform -strict, CRD comprises via le catalogue datreeio ;
  les types sans schéma connu sont listés, pas validés). Limite connue : pour une CRD, un
  champ inconnu à la racine du document passe ; dans `spec`, il est refusé ;
- aucune image sans version, ni en `latest` / `stable` / nom de branche ;
- aucune source externe qui suit une branche (`targetRevision`), seul ce repo suit `main`.

    ./hack/check-apps.py            # toutes les Applications
    ./hack/check-apps.py registry   # une seule (nom de fichier sans .yaml)

Prérequis : helm, kubeconform, git (versions de la CI : .github/workflows/validate.yml).
"""

import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
APPS = ROOT / "gitops" / "apps"
SELF_REPO = "https://github.com/cybermimic/iac.git"
KUBE_VERSION = "1.36.1"  # CLAUDE.md, « Stack »
CRD_CATALOG = (
    "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/"
    "{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
)
VERSION = re.compile(r"^v?\d+\.\d+\.\d+([-+][0-9A-Za-z.-]+)?$")
FLOATING_TAGS = {"latest", "stable", "main", "master", "edge", "nightly", "dev"}


class CheckError(Exception):
    pass


def run(cmd: list[str], stdin: str | None = None, allow_failure: bool = False) -> str:
    result = subprocess.run(cmd, input=stdin, capture_output=True, text=True, check=False)
    if result.returncode != 0 and not allow_failure:
        raise CheckError(f"{' '.join(cmd[:3])}… : {result.stderr.strip()[:400]}")
    return result.stdout


def applications(names: list[str]) -> list[Path]:
    files = sorted(APPS.glob("*.yaml"))
    if names:
        files = [f for f in files if f.stem in names]
    return files


def check_revision(source: dict, errors: list[str]) -> None:
    repo, revision = source.get("repoURL", ""), str(source.get("targetRevision", ""))
    if repo == SELF_REPO:
        if revision != "main":
            errors.append(f"ce repo doit être suivi sur main, pas {revision!r}")
    elif not VERSION.match(revision):
        errors.append(f"{repo} : targetRevision {revision!r} n'est pas une version épinglée")


def render_helm(app: dict, source: dict, workdir: Path) -> str:
    helm = source.get("helm", {})
    release = helm.get("releaseName") or app["metadata"]["name"]
    namespace = app["spec"]["destination"].get("namespace", "default")
    values = workdir / f"values-{abs(hash(json.dumps(source, sort_keys=True)))}.json"
    values.write_text(json.dumps(helm.get("valuesObject", {})))
    repo, revision = source["repoURL"], str(source["targetRevision"])
    cmd = ["helm", "template", release]
    if "chart" in source:
        if "://" in repo:
            cmd += [source["chart"], "--repo", repo]
        else:  # OCI sans schéma, comme ArgoCD l'écrit
            cmd += [f"oci://{repo}/{source['chart']}"]
        cmd += ["--version", revision]
    else:
        checkout = workdir / f"git-{abs(hash(repo + revision))}"
        if not checkout.exists():
            run(["git", "clone", "--quiet", "--depth", "1", "--branch", revision, repo, str(checkout)])
        cmd += [str(checkout / source["path"])]
    cmd += ["--namespace", namespace, "--kube-version", KUBE_VERSION, "--include-crds", "-f", str(values)]
    return run(cmd)


def read_directory(source: dict) -> str:
    base = ROOT / source["path"]
    if not base.is_dir():
        raise CheckError(f"dossier introuvable : {source['path']}")
    pattern = "**/*" if source.get("directory", {}).get("recurse") else "*"
    files = sorted(p for p in base.glob(pattern) if p.suffix in {".yaml", ".yml"})
    return "\n---\n".join(p.read_text(encoding="utf-8") for p in files)


def images(manifests: str) -> list[str]:
    found: list[str] = []

    def walk(node: object) -> None:
        if isinstance(node, dict):
            for key in ("containers", "initContainers"):
                for container in node.get(key) or []:
                    if isinstance(container, dict) and container.get("image"):
                        found.append(str(container["image"]))
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    for document in yaml.safe_load_all(manifests):
        walk(document)
    return found


def check_image(image: str) -> str | None:
    if "@sha256:" in image:
        return None
    name = image.rsplit("/", 1)[-1]
    if ":" not in name:
        return f"image sans version : {image}"
    tag = name.rsplit(":", 1)[1]
    if tag in FLOATING_TAGS:
        return f"image en tag flottant : {image}"
    return None


def validate(manifests: str) -> tuple[int, list[str]]:
    out = run(
        [
            "kubeconform", "-strict", "-summary", "-output", "json",
            "-kubernetes-version", KUBE_VERSION, "-ignore-missing-schemas",
            "-schema-location", "default", "-schema-location", CRD_CATALOG,
        ],
        stdin=manifests,
        # Code de retour non nul dès qu'une ressource est invalide : le détail est dans
        # le rapport JSON, lu ci-dessous.
        allow_failure=True,
    )
    report = json.loads(out)
    invalid = [
        f"{r.get('kind')}/{r.get('name')} : {r.get('msg')}"
        for r in report.get("resources", [])
        if r.get("status") in {"statusInvalid", "statusError"}
    ]
    if invalid:
        raise CheckError("schéma : " + " ; ".join(invalid[:5]))
    without_schema = sorted(
        {r.get("kind", "?") for r in report.get("resources", []) if r.get("status") == "statusSkipped"}
    )
    return report["summary"]["valid"], without_schema


def check(path: Path, workdir: Path) -> tuple[str, str]:
    app = yaml.safe_load(path.read_text(encoding="utf-8"))
    spec = app["spec"]
    sources = spec.get("sources") or [spec["source"]]
    errors: list[str] = []
    rendered: list[str] = []
    skipped: list[str] = []
    for source in sources:
        check_revision(source, errors)
    # Règle de version d'abord : inutile de rendre une source qui suit une branche.
    if errors:
        raise CheckError(" ; ".join(errors))
    for source in sources:
        repo = source.get("repoURL", "")
        if repo.startswith("git@"):
            skipped.append(f"{repo} (dépôt privé, inaccessible à la CI)")
        elif repo == SELF_REPO:
            rendered.append(read_directory(source))
        else:
            rendered.append(render_helm(app, source, workdir))
    manifests = "\n---\n".join(rendered)
    errors += [e for e in (check_image(i) for i in images(manifests)) if e]
    if errors:
        raise CheckError(" ; ".join(errors))
    valid, without_schema = validate(manifests) if manifests.strip() else (0, [])
    detail = f"{valid} ressources valides"
    if without_schema:
        detail += f" ; sans schéma connu, non validés : {', '.join(without_schema)}"
    if skipped:
        return "SKIP", detail + " ; non rendu : " + ", ".join(skipped)
    return "OK", detail


def main() -> int:
    status = 0
    with tempfile.TemporaryDirectory() as tmp:
        for path in applications(sys.argv[1:]):
            try:
                result, detail = check(path, Path(tmp))
            except CheckError as error:
                result, detail = "FAIL", str(error)
                status = 1
            print(f"{result:5} {path.stem} : {detail}")
    return status


if __name__ == "__main__":
    sys.exit(main())
