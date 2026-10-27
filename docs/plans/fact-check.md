# Plan — accueillir fact-check sur la plateforme

**Statut : planifié** (2026-10-27). Chaque étape suit la règle du repo :
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
| Namespace `fact-check`, API + front (~300 Mi), PostgreSQL de l'application (~200-400 Mi, volume 10 Gi au départ) | ArgoCD + chart de l'application | 5 |
| Bucket S3 `fact-check` | `storage/object-storage` (Garage, ~50-150 Mi) | 3 |
| `https://fact-check.cybermimic.com` depuis Internet | Traefik public + Let's Encrypt, enregistrement DNS | 4 |
| Images `192.168.1.242/fact-check/<composant>:X.Y.Z` | `delivery/registry` | 2 |
| Secrets (base, S3, clés d'API) | Vault + `security/external-secrets` | 3, 5 |
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
| `fact-check/s3` | `access_key_id`, `secret_access_key` | application, `CronJob` | 3 |
| `fact-check/postgres` | `password` | PostgreSQL, application | 5 |
| `argocd/repo-fact-check` | `ssh_private_key` | ArgoCD (dépôt privé) | 5 |
| `fact-check/insee`, `fact-check/piste` | à préciser | connecteurs concernés | 6+ |

**Policy** : avant d'ajouter `secret/data/fact-check/*`, lancer
`vault policy read external-secrets` et reporter **tous** les chemins
existants dans le nouveau contenu (incident du 2026-10-19).

## Étapes

Légende : 🤖 = l'agent (code, `plan`, `apply` après accord) ; 👤 =
l'opérateur (secrets, comptes externes, réseau, sudo).

0. ✅ Décisions prises, dépôt `cybermimic/fact-check` créé (privé), conception
   documentée dans le dépôt.
1. 🤖 Ce plan et les seuils d'extension du nœud.
2. **Squelette du dépôt fact-check** — 🤖 structure des connecteurs, chart
   Helm, workflow CI. 👤 Installer la GitHub App des runners sur le dépôt ;
   🤖 scale set dédié (`arc-runners-fact-check`, modèle dans
   `features/delivery/actions-runners/README.md`) et secrets de push du
   registre dans le dépôt.
3. **`storage/object-storage` (Garage)** — 🤖 feature livrée par ArgoCD
   (README complet, version épinglée, volume local-path), bucket
   `fact-check`. 👤 Création de la clé d'accès (la commande affiche le
   secret) et rangement dans `secret/fact-check/s3`.
4. **Exposition** — 🤖 `fact-check` ajouté à `public_namespaces`
   (`terraform plan` relu, puis `apply` après accord). 👤 Enregistrement
   DNS `fact-check.cybermimic.com` vers l'IP publique (comme
   `auth.cybermimic.com`).
5. **Déploiement** — 👤 policy Vault mise à jour, mot de passe PostgreSQL,
   clé de déploiement ArgoCD. 🤖 `Application` ArgoCD, `ExternalSecret`,
   `NetworkPolicy`.
6. **Premier connecteur** (scrutins de l'Assemblée) jusqu'à une première
   page publique où chaque chiffre a son lien vers la source.
7. Connecteurs suivants, un par un, en surveillant disque et RAM.
