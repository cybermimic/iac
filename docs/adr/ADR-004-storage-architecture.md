# ADR-004 — Architecture de stockage

## Contexte

La plateforme a besoin de stockage persistant pour les workloads
Kubernetes (démarrage) et, plus tard, de stockage objet compatible S3 pour
des usages type backups, artefacts, données applicatives.

## Problème

Le cluster est aujourd'hui single-node avec 16 Go de RAM — une stack de
stockage distribué lourde (Ceph, etc.) serait disproportionnée. Il faut
néanmoins choisir dès maintenant une trajectoire de stockage objet qui ne
nécessitera pas de refonte majeure au passage multi-node.

## Décision

- **Court terme** : Local Path Provisioner pour le stockage persistant de
  démarrage (`features/storage/local-path/`).
- **Stockage objet S3-compatible** : Garage est le candidat retenu.
  **MinIO est explicitement exclu.**

## Alternatives considérées

- **MinIO** : rejeté (contrainte explicite du projet).
- **Ceph/Rook** : rejeté pour l'instant — trop lourd pour un cluster
  single-node à 16 Go RAM ; à reconsidérer au passage multi-node avec
  nœuds storage dédiés.
- **NFS provisioner** : possible complément futur pour du stockage
  hot/cold, non retenu comme solution objet S3.

## Conséquences

- Le stockage objet ne sera déployé qu'une fois le besoin réel identifié
  (backups Vault, artefacts registry, etc.) — pas d'installation
  anticipée sans consommateur concret.
- Au passage multi-node, prévoir des nœuds storage dédiés distincts des
  nœuds compute plutôt que de faire évoluer Local Path Provisioner en
  solution distribuée.
