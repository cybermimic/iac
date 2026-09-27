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
| Kubernetes (kubeadm, single-node, Calico) | ✅ En place |
| `networking/metallb` | ✅ Déployé |
| `storage/local-path` | ✅ Déployé, StorageClass par défaut |
| `security/vault` | ✅ Déployé et initialisé — unseal manuel (humain) après chaque redémarrage |
| `networking/ingress`, `delivery/argocd`, `observability/*` | ❌ Pas commencé |
| `security/external-secrets`, `storage/object-storage`, `delivery/registry`, `ai/*` | ❌ Pas commencé |
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
