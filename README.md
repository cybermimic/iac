# iac — HomeLab Dev Platform

Infrastructure as Code pour la plateforme privée "HomeLab Dev" de Cybermimic.

Ce repository reproduit les **principes** d'une plateforme cloud moderne
(compute, storage, networking, sécurité, observabilité, GitOps) sur un
homelab, sans chercher à reproduire AWS littéralement.

## Ce que contient ce repo

- `bootstrap/` — transforme une machine Ubuntu vierge en machine prête à
  intégrer le cluster (cloud-init, Ansible).
- `infrastructure/` — ressources déclaratives via Terraform (providers
  Kubernetes/Helm uniquement, pas de configuration système générale).
- `features/` — capacités de plateforme (networking, security, storage,
  observability, delivery, ai), déployées via Helm/ArgoCD.
- `docs/adr/` — décisions d'architecture importantes et leur justification.

## Ce que ce repo NE contient PAS

- Le code source des applications business (repos séparés, référencés par
  ArgoCD).
- Des secrets, tokens, kubeconfigs ou clés en clair — voir
  [ADR-003](docs/adr/ADR-003-secret-management.md).

## Si tu es un agent (Claude Code ou autre)

Lire [CLAUDE.md](CLAUDE.md) avant toute modification — c'est le contrat
de règles à respecter sur ce repo (Terraform, secrets, versions,
naming, petites étapes). Lire aussi
[docs/operations.md](docs/operations.md) si tu travailles depuis une
machine différente de celle où le projet a été commencé : accès au
cluster réel, où vit le state Terraform, limitations connues.

## État actuel

Cluster Kubernetes single-node (kubeadm v1.36 + containerd + Calico, pods
en `10.244.0.0/16`) sur
une machine Ubuntu (NucBoxG3-Plus, 16 Go RAM).

| Feature | Statut |
|---|---|
| `networking/metallb` | ✅ Déployé — IP joignables depuis le LAN depuis le 2026-09-27 (annonce L2 corrigée) |
| `storage/local-path` | ✅ Déployé, StorageClass par défaut |
| `security/vault` | ✅ Déployé, initialisé, sur `https://192.168.1.243:8200` (TLS de bout en bout, CA interne) — unseal manuel après chaque redémarrage |
| `bootstrap/ansible` (containerd + kubeadm) | ⚠️ Écrit, validé syntaxiquement, jamais exécuté contre une machine réelle |
| `networking/ingress` (Traefik) | ✅ Ingress **public** sur `192.168.1.240` (classe non par défaut, namespaces autorisés : `inner-riddle`) + Let's Encrypt — ports pas encore redirigés ([ADR-009](docs/adr/ADR-009-public-exposure.md)) |
| `networking/lan-dns` (CoreDNS) | 🗑️ Supprimé le 2026-10-12 ([ADR-007](docs/adr/ADR-007-lan-dns.md) abandonné, [incident](docs/incidents/2026-09-28-lan-dns-outage.md)) |
| `security/cert-manager` (CA interne) | ✅ Déployé — CA « Homelab Root CA » (limitée à `homelab.lan`), ClusterIssuer `homelab-ca` ; CA à installer sur les postes ([certificat](docs/homelab-root-ca.crt)) |
| `delivery/argocd` | ✅ Déployé sur `https://192.168.1.244`, Application racine app-of-apps active ([ADR-008](docs/adr/ADR-008-gitops-layout.md)) |
| `security/external-secrets` | ✅ Déployé par ArgoCD, `ClusterSecretStore` `vault` valide (Vault en TLS sur `192.168.1.243`) |
| `delivery/registry` (Zot) | ⏳ Livré par ArgoCD sur `https://192.168.1.242` — attend les comptes dans Vault et le playbook CA du nœud |
| `observability/*`, `storage/object-storage`, `ai/*` | ❌ Pas commencé |
| Exposition publique (Traefik → public), registre (`delivery/registry`), runners CI (`delivery/actions-runners`) | 📋 Décidé, à implémenter — [ADR-009](docs/adr/ADR-009-public-exposure.md), [ADR-010](docs/adr/ADR-010-container-registry.md), [ADR-011](docs/adr/ADR-011-ci-runners.md) ; ordre et actions : [plan inner-riddle](docs/plans/inner-riddle.md) |

Voir `docs/architecture.md` pour la vision cible, les ADRs (`docs/adr/`)
pour le détail des décisions déjà prises, et
[docs/operations.md](docs/operations.md) pour la suite prévue et les
limitations connues (pas de backend Terraform distant, notamment).

## Démarrage

Commencer par **[docs/platform-overview.md](docs/platform-overview.md)** :
ce qui tourne, le plan d'adressage, le chemin d'une requête et où chaque
chose est configurée. Puis `docs/architecture.md` pour la cible. Chaque
couche (`bootstrap/`, `infrastructure/`, `features/<name>/`) a son propre
README avec objectif, dépendances, installation, upgrade, rollback et
troubleshooting.

## Validation locale

```bash
./hack/test.sh
```
