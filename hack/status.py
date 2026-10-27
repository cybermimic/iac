#!/usr/bin/env python3
"""Bilan de santé de la plateforme, en LECTURE SEULE.

À lancer au quotidien, après un redémarrage du NucBox, et à la fin d'une
reconstruction. N'écrit rien, n'affiche aucun secret.

    KUBECONFIG=<chemin> ./hack/status.py

Chaque ligne : OK, WARN (à surveiller) ou FAIL (à traiter) ; code de retour 1 si un
FAIL. Les contrôles de l'hôte (lien réseau, disque, RAM) ne tournent que sur le nœud.
Seuils : docs/operations.md (disque > 75 %, RAM disponible < 2 Gi).
"""

import json
import shutil
import subprocess
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path

DISK_MAX = 0.75
RAM_MIN_GIB = 2.0
CERT_WARN = timedelta(days=21)
BACKUP_MAX_AGE = timedelta(hours=26)  # CronJob quotidiens : un jour et une marge
RECENT = timedelta(hours=24)

results: list[tuple[str, str, str]] = []


def report(level: str, check: str, detail: str) -> None:
    results.append((level, check, detail))


def kubectl(*args: str) -> dict:
    out = subprocess.run(
        ["kubectl", *args, "-o", "json"], capture_output=True, text=True, check=False
    )
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip()[:200])
    return json.loads(out.stdout)


def parse_time(value: str | None) -> datetime | None:
    return datetime.fromisoformat(value.replace("Z", "+00:00")) if value else None


def ago(moment: datetime) -> str:
    hours = (datetime.now(UTC) - moment).total_seconds() / 3600
    return f"il y a {hours:.0f} h" if hours < 48 else f"il y a {hours / 24:.0f} j"


def check_nodes() -> str | None:
    try:
        nodes = kubectl("get", "nodes")["items"]
    except RuntimeError as error:
        report("FAIL", "API Kubernetes", f"injoignable : {error}")
        return None
    node_ip = None
    for node in nodes:
        name = node["metadata"]["name"]
        ready = next(
            (c["status"] for c in node["status"]["conditions"] if c["type"] == "Ready"), "?"
        )
        report("OK" if ready == "True" else "FAIL", f"nœud {name}", f"Ready={ready}")
        node_ip = next(
            (a["address"] for a in node["status"]["addresses"] if a["type"] == "InternalIP"),
            node_ip,
        )
    return node_ip


def check_host(node_ip: str | None) -> None:
    """Seulement sur le nœud lui-même : l'interface qui porte l'IP du nœud."""
    interface = None
    for path in Path("/sys/class/net").iterdir():
        out = subprocess.run(
            ["ip", "-4", "-o", "addr", "show", path.name], capture_output=True, text=True
        )
        if node_ip and f" {node_ip}/" in out.stdout:
            interface = path.name
    if interface is None:
        report("WARN", "hôte", f"IP du nœud {node_ip} absente ici : pas sur le nœud, ou IP perdue")
        return
    carrier = (Path("/sys/class/net") / interface / "carrier").read_text().strip()
    report("OK" if carrier == "1" else "FAIL", f"lien {interface}", f"carrier={carrier}")
    drops = subprocess.run(
        ["journalctl", "-k", "--since", "-24h", "--no-pager", "-q"],
        capture_output=True, text=True, check=False,
    )
    if drops.returncode == 0:
        count = drops.stdout.count(f"{interface}: NIC Link is Down")
        report(
            "OK" if count == 0 else "WARN",
            f"coupures {interface} (24 h)",
            f"{count} (voir docs/incidents/2026-10-nucbox-link-drops.md)" if count else "0",
        )
    usage = shutil.disk_usage("/")
    ratio = usage.used / usage.total
    report("OK" if ratio <= DISK_MAX else "WARN", "disque /", f"{ratio:.0%} utilisé")
    meminfo = dict(
        line.split(":", 1) for line in Path("/proc/meminfo").read_text().splitlines()
    )
    available = int(meminfo["MemAvailable"].split()[0]) / 1024**2
    report("OK" if available >= RAM_MIN_GIB else "WARN", "RAM disponible", f"{available:.1f} Gi")


def check_vault() -> None:
    out = subprocess.run(
        ["kubectl", "-n", "vault", "exec", "vault-0", "--", "vault", "status", "-format=json"],
        capture_output=True, text=True, check=False,
    )
    try:
        sealed = json.loads(out.stdout)["sealed"]
    except (json.JSONDecodeError, KeyError):
        report("FAIL", "Vault", "état illisible (pod absent ?)")
        return
    if sealed:
        report("FAIL", "Vault", "SCELLÉ : unseal manuel (features/security/vault/README.md, étape 3)")
    else:
        report("OK", "Vault", "descellé")


def check_applications() -> None:
    for app in kubectl("-n", "argocd", "get", "applications")["items"]:
        status = app.get("status", {})
        sync = status.get("sync", {}).get("status", "?")
        health = status.get("health", {}).get("status", "?")
        level = "OK" if (sync, health) == ("Synced", "Healthy") else "WARN"
        if health in {"Degraded", "Missing"}:
            level = "FAIL"
        report(level, f"argocd {app['metadata']['name']}", f"{sync}, {health}")


def check_secrets() -> None:
    before = len(results)
    for kind in ("clustersecretstores", "externalsecrets"):
        args = ["get", kind] if kind == "clustersecretstores" else ["get", kind, "-A"]
        for item in kubectl(*args)["items"]:
            meta = item["metadata"]
            name = f"{meta.get('namespace', '-')}/{meta['name']}"
            ready = next(
                (c for c in item.get("status", {}).get("conditions", []) if c["type"] == "Ready"),
                {},
            )
            if ready.get("status") != "True":
                report("FAIL", f"{kind[:-1]} {name}", ready.get("message", "non prêt")[:120])
    if len(results) == before:
        report("OK", "secrets", "ClusterSecretStore et ExternalSecret tous prêts")


def check_certificates() -> None:
    before = len(results)
    now = datetime.now(UTC)
    for cert in kubectl("get", "certificates", "-A")["items"]:
        meta, status = cert["metadata"], cert.get("status", {})
        name = f"{meta['namespace']}/{meta['name']}"
        ready = next((c["status"] for c in status.get("conditions", []) if c["type"] == "Ready"), "?")
        not_after = parse_time(status.get("notAfter"))
        if ready != "True" or not_after is None or not_after < now:
            report("FAIL", f"certificat {name}", f"Ready={ready}, expire {status.get('notAfter')}")
        elif not_after - now < CERT_WARN:
            report("WARN", f"certificat {name}", f"expire le {not_after:%Y-%m-%d}")
    if len(results) == before:
        report("OK", "certificats", f"tous prêts, aucun n'expire avant {CERT_WARN.days} jours")


def check_cronjobs() -> None:
    now = datetime.now(UTC)
    for job in kubectl("get", "cronjobs", "-A")["items"]:
        meta, status = job["metadata"], job.get("status", {})
        name = f"{meta['namespace']}/{meta['name']}"
        last_ok = parse_time(status.get("lastSuccessfulTime"))
        last_run = parse_time(status.get("lastScheduleTime"))
        if last_ok is None:
            report("WARN", f"cronjob {name}", "jamais réussi")
        elif last_run and last_run > last_ok + timedelta(hours=1):
            report("FAIL", f"cronjob {name}", f"dernière exécution en échec ; dernier succès {ago(last_ok)}")
        elif now - last_ok > BACKUP_MAX_AGE:
            report("WARN", f"cronjob {name}", f"dernier succès {ago(last_ok)}")
        else:
            report("OK", f"cronjob {name}", f"dernier succès {ago(last_ok)}")


def check_restarts() -> None:
    now = datetime.now(UTC)
    for pod in kubectl("get", "pods", "-A")["items"]:
        meta = pod["metadata"]
        for container in pod.get("status", {}).get("containerStatuses", []):
            finished = parse_time(
                container.get("lastState", {}).get("terminated", {}).get("finishedAt")
            )
            if finished and now - finished < RECENT:
                report(
                    "WARN",
                    f"redémarrage {meta['namespace']}/{meta['name']}",
                    f"{container['name']} ({container['restartCount']} au total), {ago(finished)}",
                )


def main() -> int:
    node_ip = check_nodes()
    if node_ip is not None:
        check_host(node_ip)
        for check in (check_vault, check_applications, check_secrets, check_certificates,
                      check_cronjobs, check_restarts):
            try:
                check()
            except RuntimeError as error:
                report("FAIL", check.__name__.removeprefix("check_"), str(error))
    width = max(len(c) for _, c, _ in results)
    for level, check, detail in results:
        print(f"{level:5} {check:<{width}}  {detail}")
    return 1 if any(level == "FAIL" for level, _, _ in results) else 0


if __name__ == "__main__":
    sys.exit(main())
