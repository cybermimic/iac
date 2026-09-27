# ADR-002 — GitOps avec ArgoCD

## Contexte

La plateforme doit rester reproductible et auditable : l'état désiré des
workloads Kubernetes (plateforme et applications) doit être dérivable de
Git, pas de commandes `kubectl` manuelles accumulées dans le temps.

## Problème

Sans source de vérité unique, la dérive de configuration (config drift)
entre ce qui est déployé et ce qui est documenté devient rapidement
ingérable, en particulier avec plusieurs repos d'applications business
séparés du repo plateforme.

## Décision

ArgoCD est la source de vérité pour les workloads Kubernetes, à la fois
pour les composants de plateforme (`features/`) et pour les applications
business (référencées depuis leurs repos séparés, sans copier leur code
dans `homelab-platform`).

Terraform peut installer/configurer ArgoCD lui-même (bootstrap de la
feature `delivery/argocd`), mais une fois ArgoCD opérationnel, les
changements de configuration applicative passent par GitOps.

`kubectl` reste acceptable pour : diagnostic, debugging, bootstrap initial,
opérations exceptionnelles documentées — jamais pour des changements
persistants.

## Alternatives considérées

- **FluxCD** : équivalent fonctionnel, non retenu — ArgoCD a une UI plus
  mature pour un contexte homelab où un humain unique opère la plateforme.
- **kubectl apply manuel piloté par CI** : rejeté — pas de réconciliation
  continue, dérive silencieuse possible.

## Conséquences

- Toute nouvelle application business doit exposer un chart Helm et être
  déclarée comme `Application`/`ApplicationSet` ArgoCD référençant son
  propre repo.
- Le repo `homelab-platform` définit le contrat de déploiement, jamais le
  code applicatif.
- Un déploiement en production automatique n'est pas activé tant que le
  workflow de promotion (dev/staging/prod) n'est pas explicitement défini.
