# storage/object-storage

## Objectif

Stockage objet compatible S3 **dans le cluster** : Garage
([ADR-004](../../../docs/adr/ADR-004-storage-architecture.md)), niveau `hot`
des niveaux de stockage ([ADR-015](../../../docs/adr/ADR-015-storage-tiers-and-power.md)).
Premier consommateur : fact-check (fichiers bruts archivés, bucket
`fact-check`).

Livré par **ArgoCD** ([ADR-008](../../../docs/adr/ADR-008-gitops-layout.md)) :

| Fichier | Rôle |
|---|---|
| `gitops/apps/object-storage.yaml` | Chart officiel de Garage (dépôt Garage, étiquette `v2.4.1`, chart 0.10.2), un nœud, `garage.toml` écrit en entier |
| `gitops/externalsecret.yaml` (ici) | Secret RPC depuis Vault |
| `gitops/networkpolicy.yaml` (ici) | API S3 (3900) joignable depuis les namespaces autorisés seulement |

**Interne au cluster** : `Service` ClusterIP, point d'accès
`http://garage.object-storage.svc:3900`, région `garage`. Ni le LAN ni
Internet n'y accèdent.

## Choix de déploiement

- **Chart officiel** pris dans le dépôt de Garage (aucun dépôt Helm publié
  par le projet), épinglé sur l'étiquette de version.
- **Un seul nœud**, `replication_factor = 1` : **aucune redondance**. Une
  perte du disque du NucBox perd les objets ; les sources publiques restent
  re-téléchargeables, sauf ce qui a disparu en amont (niveaux `cold` et
  `frozen` de l'ADR-015, à venir).
- **Secret RPC fourni par Vault** : sans valeur, le chart en génère un via
  `lookup`, qu'ArgoCD n'exécute pas (différence permanente à chaque
  synchronisation).
- **Pas de découverte Kubernetes** (`kubernetesSkipCrd`, `noClusterRole`) :
  ni CRD ni ClusterRole pour un seul nœud. Le chart crée tout de même un
  `Role` limité au namespace, inutilisé.
- **Pas d'`admin_token`** : l'API d'administration (3903) reste fermée ;
  l'administration passe par la CLI dans le pod (`kubectl exec`).
- Images épinglées : `dxflrs/amd64_garage:v2.4.1`, init `busybox:1.38.0`
  (le chart utilise `busybox:stable`, tag flottant). Pod en uid 1000,
  système de fichiers en lecture seule, aucune capacité (testé sous Docker
  avec la même configuration).
- Instantané des métadonnées toutes les 6 h (`metadata_auto_snapshot_interval`).

## Dépendances

- `storage/local-path` : volumes `meta` (1 Gi) et `data` (30 Gi).
- `security/external-secrets` + Vault : `secret/object-storage/garage`
  (`rpc_secret`).
- Consommateurs : chaque namespace autorisé dans `gitops/networkpolicy.yaml`.

## Ressources approximatives

~50-150 Mi de RAM au repos (limite 512 Mi). Disque : la taille réelle des
objets ; local-path ne fait pas respecter les 30 Gi annoncés, la limite
est le disque du NucBox (voir les seuils d'extension dans
[operations.md](../../../docs/operations.md)). Mesure fact-check : ~340 Mo
par an pour sa première source.

## Inputs / outputs

| Entrée | Où |
|---|---|
| Version de Garage et du chart | `targetRevision`, `image.tag` (même valeur) |
| Taille des volumes | `persistence.meta.size`, `persistence.data.size` |
| Namespaces autorisés | `gitops/networkpolicy.yaml` |

| Sortie | Valeur |
|---|---|
| Point d'accès S3 | `http://garage.object-storage.svc:3900`, région `garage` |
| Buckets, clés | Créés à la main (ci-dessous), une clé par application |

## Installation

Toutes les commandes se lancent **sur le NucBox**, par l'opérateur. Aucune
valeur secrète n'est affichée ni passée en clair dans l'historique.

**1. Policy Vault** : lire d'abord, puis réécrire avec **tous** les chemins
existants plus `object-storage` et `fact-check` (incident du 2026-10-19 :
`vault policy write` remplace tout) :

```bash
kubectl -n vault exec vault-0 -- vault policy read external-secrets
# reporter chaque ligne existante, puis ajouter :
#   path "secret/data/object-storage/*" { capabilities = ["read"] }
#   path "secret/data/fact-check/*"     { capabilities = ["read"] }
```

**2. Secret RPC** :

```bash
openssl rand -hex 32 | tr -d '\n' \
  | kubectl -n vault exec -i vault-0 -- vault kv put secret/object-storage/garage rpc_secret=-
```

**3. Fusionner la PR** : ArgoCD synchronise. Vérifier :

```bash
kubectl -n argocd get application object-storage          # Synced, Healthy
kubectl -n object-storage get externalsecret,pods         # SecretSynced, garage-0 Running
```

**4. Layout** (une fois, le nœud n'a pas de rôle au premier démarrage) :

```bash
G="kubectl -n object-storage exec garage-0 -- /garage"
NODE=$($G status | awk '/NO ROLE ASSIGNED/ {print $1}')
$G layout assign -z homelab -c 30G "$NODE"
$G layout apply --version 1
```

**5. Bucket et clé de fact-check**, rangée directement dans Vault. La clé est
générée localement puis importée : seul l'identifiant (non secret) apparaît.
La valeur secrète passe en argument de `kubectl exec` (visible un instant
dans la liste des processus du NucBox, jamais dans l'historique du shell) :

```bash
$G bucket create fact-check
KEY_ID=GK$(openssl rand -hex 12); KEY_SECRET=$(openssl rand -hex 32)
$G key import --yes -n fact-check "$KEY_ID" "$KEY_SECRET"
$G bucket allow --read --write --owner fact-check --key fact-check
printf '%s' "$KEY_SECRET" | kubectl -n vault exec -i vault-0 -- \
  vault kv put secret/fact-check/s3 access_key_id="$KEY_ID" secret_access_key=-
unset KEY_ID KEY_SECRET
```

## Upgrade

Lire les notes de version de Garage (changements de format de métadonnées,
de CLI). Changer `targetRevision` **et** `image.tag` ensemble, relire le
rendu (`helm template` du chart à la nouvelle étiquette avec les valeurs de
l'Application), fusionner. Un seul nœud : l'objet stocké est indisponible
pendant le redémarrage du pod.

## Rollback

Revenir aux valeurs précédentes dans Git. **Attention** : une version plus
récente peut avoir migré les métadonnées ; revenir en arrière demande alors
de restaurer l'instantané des métadonnées (`/mnt/meta/snapshots`). Lire les
notes de version avant toute montée.

## Troubleshooting

| Symptôme | Cause probable | Action |
|---|---|---|
| `garage-0` en `Init` ou `CreateContainerConfigError` | Secret `garage-rpc-secret` absent | `kubectl -n object-storage describe externalsecret garage-rpc-secret` ; chemin Vault et policy (étapes 1-2) |
| Requêtes S3 en erreur 503, `NO ROLE ASSIGNED` | Layout jamais appliqué | Étape 4 |
| Application en `ConnectTimeout` vers `garage.object-storage.svc` | Namespace non autorisé | Ajouter son namespace à `gitops/networkpolicy.yaml` |
| `AccessDenied` | Clé sans droit sur le bucket | `$G bucket info <bucket>` ; `bucket allow` |
