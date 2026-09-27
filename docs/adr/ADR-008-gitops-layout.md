# ADR-008 — Organisation GitOps (ArgoCD)

**Statut : Proposé** (2026-09-27) — à valider par l'opérateur avant toute
implémentation. Rien de ce qui suit n'est encore en place.

## Contexte

[ADR-002](ADR-002-gitops-with-argocd.md) fait d'ArgoCD la source de vérité
des workloads, plateforme et applications business. ArgoCD est prêt à être
installé par Terraform (`delivery/argocd`), sans aucune `Application`.

Aujourd'hui, **tout** ce qui tourne au-dessus du socle Kubernetes est géré
par Terraform : MetalLB, local-path, Vault, Traefik, lan-dns,
cert-manager, ArgoCD lui-même. Il faut décider :

1. comment ArgoCD découvre ce qu'il doit déployer ;
2. ce qui reste dans Terraform et ce qui passe dans ArgoCD ;
3. la politique de synchronisation.

## Options

### 1. Découverte des Applications

| Option | Principe | Pour | Contre |
|---|---|---|---|
| **A. App of apps (recommandé)** | Terraform crée **une** `Application` racine qui suit `gitops/apps/` de ce repo ; chaque fichier de ce dossier est une `Application` (une feature ou une app business) | Explicite : la liste de ce qui est déployé se lit dans un dossier ; ajouter/retirer = ajouter/retirer un fichier ; conforme au principe « évident plutôt qu'automatique » | Un fichier à écrire par Application |
| B. ApplicationSet (générateur de répertoires) | Une `ApplicationSet` crée automatiquement une `Application` par dossier `features/*/*/gitops/` | Zéro déclaration : créer le dossier suffit | Implicite : un dossier créé par erreur est déployé ; plus difficile à suivre pour quelqu'un qui découvre le repo |

### 2. Frontière Terraform / ArgoCD

**Recommandé : un socle Terraform, le reste en ArgoCD.**

- **Reste dans Terraform** (le « socle », nécessaire pour qu'ArgoCD
  lui-même fonctionne et soit joignable, ou porteur d'état sensible) :
  MetalLB, local-path, Traefik, lan-dns, cert-manager, Vault, ArgoCD et
  l'`Application` racine.
- **Passe par ArgoCD** : toutes les **nouvelles** features (observabilité,
  registry, external-secrets…) et les applications business (leur
  `Application` référence leur propre repo / chart, jamais leur code ici).
- Pas de migration des features existantes vers ArgoCD dans un premier
  temps (risque de double gestion Terraform + ArgoCD d'une même
  ressource). À réévaluer feature par feature, une à la fois.

Alternative écartée à ce stade : tout migrer dans ArgoCD sauf ArgoCD
lui-même (plus « pur » GitOps, mais migration risquée de composants qui
fonctionnent, et dépendance circulaire pour ingress/DNS/certificats dont
ArgoCD a besoin).

### 3. Politique de synchronisation

**Recommandé :**

- Features de plateforme : **synchronisation automatique avec
  `selfHeal`**, **sans `prune`** au départ (une suppression dans Git ne
  supprime pas automatiquement la ressource : on active `prune` feature
  par feature quand on a confiance).
- Applications business : **synchronisation manuelle** tant que le
  workflow de promotion dev/staging/prod n'est pas défini (condition déjà
  posée par ADR-002).

## Arborescence proposée

```
gitops/
└── apps/                      # suivi par l'Application racine (Terraform)
    ├── <feature>.yaml         # une Application par feature/app
    └── ...
features/<domaine>/<feature>/
    gitops/                    # manifestes / values de la feature, référencés
                               # par son Application dans gitops/apps/
```

Accès au repo : ce repo est public, ArgoCD le lit sans identifiant. Les
repos business privés demanderont des identifiants (clé de déploiement),
à fournir via Vault + External Secrets (ADR-003), jamais en clair.

## Conséquences (si adopté)

- ADR-002 est précisé : le socle reste géré par Terraform.
- Toute nouvelle feature (à partir de l'observabilité) se livre en ajoutant
  `features/<d>/<f>/gitops/` + `gitops/apps/<f>.yaml`, sans `terraform
  apply`.
- Le README de chaque feature indique qui la gère (Terraform ou ArgoCD).

## Décision

*À compléter après validation.*
