# Plan — accueillir fact-check sur la plateforme

**Statut : en cours** (2026-10-27) — code et contrat de déploiement prêts, en attente des actions opérateur (étapes 2 à 4). Chaque étape suit la règle du repo :
code → `plan` relu → `apply` (ou synchronisation ArgoCD) avec l'accord de
l'opérateur.

fact-check ([dépôt privé](https://github.com/cybermimic/fact-check), créé
le 2026-10-27) récupère les données publiques des institutions pour les
visualiser et vérifier des affirmations ; chaque information affichée
renvoie à sa source. Sa conception (traçabilité, connecteurs, base de
données, sources) et son contrat de déploiement vivent dans son dépôt
(`docs/adr/ADR-001-data-and-provenance.md`, `docs/deployment.md`). Ce repo
fournit la plateforme et déclare l'`Application` ArgoCD, sans jamais copier
le code ([ADR-002](../adr/ADR-002-gitops-with-argocd.md)).

**Cible : `https://fact-check.cybermimic.com`**, joignable depuis Internet,
certificat Let's Encrypt.

## Décisions qui encadrent le plan

| Sujet | Décision |
|---|---|
| Stockage objet | [ADR-004](../adr/ADR-004-storage-architecture.md) : Garage ; fact-check est le premier consommateur concret qui déclenche `storage/object-storage` |
| Exposition publique | [ADR-009](../adr/ADR-009-public-exposure.md) : Traefik public sur `192.168.1.240`, namespace `fact-check` ajouté à `public_namespaces` |
| CI | [ADR-011](../adr/ADR-011-ci-runners.md) : dépôt privé → runners ARC obligatoires |
| GitOps | [ADR-008](../adr/ADR-008-gitops-layout.md) : nouvelles features et applications via ArgoCD |

Garage sur un seul nœud : `replication_factor = 1`, **aucune redondance**.
L'ajout d'un nœud se fera en étendant le *layout* Garage.

## Ce dont l'application a besoin

D'après son `docs/deployment.md` :

| Besoin | Fourni par | Étape |
|---|---|---|
| Namespace `fact-check`, PostgreSQL de l'application (~200-400 Mi, volume 10 Gi au départ), un `CronJob` par source (~180 Mi pendant ~20 s, mesuré) | ArgoCD + chart de l'application | 4 |
| Bucket S3 `fact-check` | `storage/object-storage` (Garage, ~50-150 Mi) | 3 |
| `https://fact-check.cybermimic.com` depuis Internet | Traefik public + Let's Encrypt, enregistrement DNS | 5 (reportée) |
| Image `192.168.1.242/fact-check/backend:X.Y.Z` | `delivery/registry` | 2 |
| Secrets (base, S3, clés d'API) | Vault + `security/external-secrets` | 3, 4 |
| Publication des images à chaque étiquette | `delivery/actions-runners` | 2 |

Empreinte ajoutée : ~0,6-1 Gi au repos, plus un `CronJob` pendant
l'ingestion. Le disque sera la première limite : voir les seuils
d'extension dans [operations.md](../operations.md#capacité-du-nœud-et-seuils-dextension).

## Secrets à ranger dans Vault (opérateur)

Valeurs **jamais** dans Git ni dans un chat. Procédure identique à
[celle d'inner-riddle](inner-riddle.md#secrets-à-ranger-dans-vault-opérateur)
(valeurs par l'entrée standard, jamais en argument).

| Chemin (`secret/…`, kv-v2) | Propriétés | Consommateur | Étape |
|---|---|---|---|
| `object-storage/garage` | `rpc_secret` | Garage | 3 |
| `fact-check/s3` | `access_key_id`, `secret_access_key` | application, `CronJob` | 3 |
| `fact-check/postgres` | `password` (hexadécimal) | PostgreSQL, application | 4 |
| `argocd/repo-fact-check` | `ssh_private_key` | ArgoCD (dépôt privé) | 4 |
| `fact-check/insee`, `fact-check/piste` | à préciser | connecteurs concernés | 6 |

**Policy** : avant d'ajouter `secret/data/fact-check/*`, lancer
`vault policy read external-secrets` et reporter **tous** les chemins
existants dans le nouveau contenu (incident du 2026-10-19).

## Étapes

Légende : 🤖 = l'agent (code, `plan`, `apply` après accord) ; 👤 =
l'opérateur (secrets, comptes externes, réseau, sudo).

0. ✅ Décisions prises, dépôt `cybermimic/fact-check` créé (privé), conception
   documentée dans le dépôt.
1. 🤖 Ce plan et les seuils d'extension du nœud.
2. **Code de l'application** — 🤖 fact-check #1 (squelette, catalogue,
   archivage D3), #2 (connecteur des scrutins, mesuré sur la vraie source),
   #3 (chart Helm, CI et publication sur les runners du cluster).
   🤖 iac #24 : scale set `homelab` de fact-check. 👤 Installer la GitHub App
   des runners sur le dépôt, puis fusionner.
3. **`storage/object-storage` (Garage)** — 🤖 iac #25. 👤 Policy Vault (lire
   d'abord) et secret RPC avant fusion ; après : layout, bucket et clé
   `fact-check` rangée dans `secret/fact-check/s3` (README de la feature).
4. **Déploiement** — 🤖 iac #26 : `Application` ArgoCD (synchronisation
   manuelle), accès au dépôt, pull secret. 👤 Mot de passe PostgreSQL, clé
   de déploiement, secrets de publication du dépôt (commandes dans la PR),
   étiquette `v0.1.0` une fois fact-check #1-#3 fusionnées, puis « Sync ».
5. **Exposition** — reportée : fact-check n'a encore ni API ni interface.
   Le jour où elle en aura une : 🤖 `fact-check` ajouté à
   `public_namespaces` (`terraform plan` relu, puis `apply` après accord),
   👤 enregistrement DNS `fact-check.cybermimic.com`.
6. Connecteurs suivants, un par un, en surveillant disque et RAM.
