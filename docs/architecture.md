# Architecture cible

## Vision

```
GitHub Organization
        |
   homelab-platform (ce repo)      business repos (app-*)
        |                                 |
        v                                 |
     ArgoCD <----------------------------+
        |
        v
   Kubernetes
        |
   +----+----+----------------+
   |         |                |
Compute   Storage          Platform
                              +-- Vault
                              +-- Registry
                              +-- Monitoring
                              +-- ArgoCD
```

## Séparation des responsabilités

| Couche | Rôle | Technologies |
|---|---|---|
| Bootstrap | Machine Ubuntu vierge → prête pour le cluster | cloud-init, Ansible |
| Infrastructure | Ressources déclaratives | Terraform (providers Kubernetes/Helm) |
| Platform | Composants de plateforme | Helm, ArgoCD |
| Applications | Code métier | Repos Git séparés |

Terraform n'est **pas** un système de configuration Linux générale — ce rôle
revient à Ansible. Voir [ADR-001](adr/ADR-001-terraform-scope.md).

## Concept de feature

Une feature = une capacité de plateforme (pas une application métier),
organisée sous `features/<domaine>/<feature>/`. Une feature ne crée que les
couches (`terraform/`, `ansible/`, `gitops/`, `docs/`) dont elle a réellement
besoin, et documente explicitement ses dépendances envers d'autres features.

## Contrainte ressources

La machine actuelle dispose de 16 Go RAM. Chaque feature documente son
empreinte CPU/RAM/stockage approximative et doit rester mesurée — pas de
déploiement simultané de composants lourds tant que le cluster reste
single-node.

## État d'implémentation

| Étape | Statut |
|---|---|
| Bootstrap Ubuntu → containerd/kubeadm/kubelet | ⚠️ Playbook Ansible écrit (`bootstrap/ansible/`), jamais exécuté pour de vrai (pas de sudo sans mot de passe disponible) — le NucBox actuel a été bootstrapé manuellement avant |
| Kubernetes (kubeadm, single-node, Calico) | ✅ En place — réseau des pods migré en `10.244.0.0/16` le 2026-09-27 ([runbook](runbooks/calico-pod-cidr-migration.md)) |
| `networking/metallb` | ✅ Déployé |
| `storage/local-path` | ✅ Déployé, StorageClass par défaut |
| `security/vault` | ✅ Déployé, initialisé, `https://192.168.1.243:8200` (TLS de bout en bout) — unseal manuel (humain) après chaque redémarrage |
| `networking/ingress` (Traefik) | ✅ Ingress public + Let's Encrypt, ports pas encore redirigés ([ADR-009](adr/ADR-009-public-exposure.md)) |
| `networking/lan-dns` | 🗑️ Supprimé le 2026-10-12 ([ADR-007](adr/ADR-007-lan-dns.md) abandonné) |
| `security/cert-manager` (CA interne) | ✅ Déployé — ClusterIssuer `homelab-ca` |
| `delivery/argocd` | ✅ Déployé, `https://192.168.1.244`, app-of-apps active ([ADR-008](adr/ADR-008-gitops-layout.md)) |
| `security/external-secrets` | ✅ Déployé (ArgoCD), connecté à Vault |
| `delivery/registry` (Zot) | ✅ Livré par ArgoCD, `https://192.168.1.242` |
| `security/keycloak` (fournisseur d'identité) | ⏳ Code prêt (`gitops/apps/keycloak.yaml`), pas encore appliqué — attend la config Vault opérateur ([ADR-012](adr/ADR-012-identity-keycloak.md)) |
| `compute/fleet-manager` (hôtes gérés) | ⏳ Playbook écrit et vérifié (ansible-lint, comportement testé en conteneur), jamais exécuté : attend la machine A ([README](../features/compute/fleet-manager/README.md), [ADR-015](adr/ADR-015-storage-tiers-and-power.md)) |
| `observability/*`, `storage/object-storage`, `ai/*` | ❌ Pas commencé |
| `delivery/actions-runners` (ARC) | ⏳ Livré par ArgoCD, attend la GitHub App ([ADR-011](adr/ADR-011-ci-runners.md)) |
| Multi-node, GPU, lifecycle management | ❌ Pas commencé |

Détail par feature : `features/*/README.md`. Limitations connues et faits
opérationnels pour reprendre le travail : [docs/operations.md](operations.md).

## Évolution prévue

```
machine Ubuntu → bootstrap → Kubernetes → platform services → GitOps →
self-hosted cloud → multi-node → storage dédié → compute pools → GPU/LLM →
lifecycle management (power/WoL)
```

Chaque étape doit fonctionner avant de passer à la suivante — progression
incrémentale et réversible.
