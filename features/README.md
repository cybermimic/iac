# features

Une feature représente une **capacité de plateforme**, pas une application
métier (celles-ci vivent dans des repos séparés, voir racine du repo).

## Statut

Features implémentées : `networking/metallb`, `networking/ingress`,
`storage/local-path`, `security/vault` (statut détaillé : [README racine](../README.md)). Les
suivantes sont créées au fur et à mesure, jamais par anticipation.

## Convention

```
features/<domaine>/<feature>/
    terraform/   # si la feature a des ressources Terraform propres
    ansible/     # si la feature nécessite une configuration hôte
    gitops/      # manifestes/Application ArgoCD
    docs/        # au-delà du README court obligatoire
```

Ne créer que les couches réellement nécessaires à la feature.

Chaque feature doit avoir un `README.md` documentant : objectif,
dépendances (autres features requises), inputs, outputs, installation,
upgrade, rollback, troubleshooting, et une estimation approximative
CPU/RAM/stockage (contrainte : 16 Go RAM sur le cluster actuel).

## Domaines prévus

`networking/`, `security/`, `storage/`, `observability/`, `delivery/`,
`ai/` — voir [docs/architecture.md](../docs/architecture.md).
