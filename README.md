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

Cluster Kubernetes single-node (kubeadm v1.36 + containerd + Calico) sur
une machine Ubuntu (NucBoxG3-Plus, 16 Go RAM).

| Feature | Statut |
|---|---|
| `networking/metallb` | ✅ Déployé et fonctionnel |
| `storage/local-path` | ✅ Déployé, StorageClass par défaut |
| `security/vault` | ✅ Déployé et initialisé — unseal manuel après chaque redémarrage |
| `bootstrap/ansible` (containerd + kubeadm) | ⚠️ Écrit, validé syntaxiquement, jamais exécuté contre une machine réelle |
| `networking/ingress`, `delivery/argocd`, `observability/*`, `security/external-secrets`, `storage/object-storage`, `delivery/registry`, `ai/*` | ❌ Pas commencé |

Voir `docs/architecture.md` pour la vision cible, les ADRs (`docs/adr/`)
pour le détail des décisions déjà prises, et
[docs/operations.md](docs/operations.md) pour la suite prévue et les
limitations connues (pas de backend Terraform distant, notamment).

## Démarrage

Chaque couche (`bootstrap/`, `infrastructure/`, `features/<name>/`) a son
propre README avec objectif, dépendances, installation, upgrade, rollback
et troubleshooting. Commencer par `docs/architecture.md`.

## Validation locale

```bash
./hack/test.sh
```
