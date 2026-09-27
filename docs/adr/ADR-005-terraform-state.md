# ADR-005 — State Terraform : situation actuelle et trajectoire

## Contexte

Le premier déploiement réel (MetalLB) a été fait en exécutant Terraform
depuis un répertoire temporaire (`/tmp`), supprimé juste après l'`apply`.
Le fichier `terraform.tfstate` qui suit ce qui est géré par Terraform a
donc été perdu alors que les ressources, elles, existaient bien sur le
cluster.

## Problème

Un `terraform plan` relancé depuis un state vide a alors proposé de
recréer des ressources déjà existantes (namespace, `helm_release`). Un
`apply` à l'aveugle aurait échoué (conflit "already exists") ou, pire,
aurait pu perturber une ressource déjà fonctionnelle.

## Décision (état actuel — 2026)

1. **Réconciliation immédiate** : les ressources important à préserver
   (namespace, `helm_release`) ont été réintégrées au state via
   `terraform import`, plutôt que recréées à l'aveugle. Les ressources
   bon marché à recréer (CRs `IPAddressPool`/`L2Advertisement`, sans
   consommateur actif) ont été supprimées puis relaissées à Terraform.
2. **State local persistant, hors du repo Git** : en l'absence de backend
   distant, le state vit dans un répertoire dédié sur le NucBox
   (`/home/hoarauv/.homelab-platform-state/`, voir
   [docs/operations.md](../operations.md)), traité comme faisant autorité,
   jamais dans un `/tmp` éphémère.
3. Ce répertoire n'est **pas** un clone Git de ce repo — c'est un miroir
   synchronisé manuellement (`rsync`) du code de `infrastructure/` et
   `features/`. Le `.gitignore` de ce repo exclut déjà `*.tfstate*`.

## Alternatives considérées pour la suite

- **Backend S3-compatible sur `storage/object-storage` (Garage)** —
  candidat naturel une fois cette feature disponible (section 6 du
  contexte projet la prévoit déjà). Nécessite un endpoint S3 fiable et
  des credentials d'accès (à traiter via variables d'environnement,
  jamais en dur).
- **Terraform Cloud / autre SaaS** — écarté pour l'instant : dépendance
  externe non nécessaire pour un homelab single-utilisateur, et introduit
  une dépendance à un service tiers pour piloter une infra qui se veut
  auto-hébergée.
- **Rester en state local durablement** — acceptable tant qu'il n'y a
  qu'un seul opérateur et qu'un seul répertoire d'exécution faisant
  autorité, mais fragile (un `rm -rf` malheureux comme celui qui a motivé
  cette ADR peut se reproduire) et bloquant dès qu'on travaille depuis
  plusieurs machines.

## Conséquences

- Tant que le backend n'est pas migré vers du stockage objet, **toute
  session (humaine ou agent) doit vérifier l'absence de drift par un
  `terraform plan` avant tout `apply`**, et ne jamais initialiser un
  nouveau répertoire de state sans avoir d'abord confirmé qu'aucun autre
  n'est déjà en usage (voir `CLAUDE.md`).
- La migration vers un backend distant est un prérequis explicite avant
  de travailler depuis plusieurs machines en parallèle sans risque de
  conflit de state.
