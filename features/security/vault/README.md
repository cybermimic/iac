# security/vault

## Objectif

Vault comme source de vérité pour les secrets de plateforme et
applicatifs, en mode standalone avec storage backend `file` sur un volume
persistant (pas de backend externe). `ha.enabled = false` : Raft
n'apporte de valeur qu'en HA multi-replica, hors scope pour un cluster
single-node. Voir [ADR-003](../../../docs/adr/ADR-003-secret-management.md).

## Dépendances

- `storage/local-path` — la StorageClass doit exister avant Vault (volume
  de données persistant).

## Ressources approximatives

~100-500m CPU, 128-512Mi RAM (voir variables `requests_*`/`limits_*`), 1Gi
de stockage par défaut (`data_volume_size`). Un seul pod (standalone,
`ha.enabled = false`) — cohérent avec un cluster single-node à 16 Go RAM.

## Inputs / Outputs

Voir `terraform/variables.tf` et `terraform/outputs.tf`.

## Ce que ce module fait — et ne fait PAS

Terraform déploie uniquement le **serveur Vault scellé** (Helm chart
officiel `hashicorp/vault`, mode standalone). Il ne fait **jamais** :

- `vault operator init`
- `vault operator unseal`
- créer des policies, des auth methods, ou tout autre secret

Automatiser ces étapes forcerait le root token et les unseal keys à
transiter par le state Terraform ou par les logs de la session qui
l'exécute — exactement ce que ce repo interdit (voir
[ADR-003](../../../docs/adr/ADR-003-secret-management.md)). Ces opérations
restent manuelles, exécutées directement par un humain sur son terminal,
jamais via un outil tiers ou une IA qui verrait passer ces secrets.

## 1. Installation

Fait partie de `infrastructure/environments/homelab` comme les autres
features (voir son README). Résultat : un pod Vault `Running` mais
**scellé** (`Sealed: true`) — normal et attendu, aucune donnée n'est
accessible avant l'étape 2/3.

## 2. Initialisation (`vault operator init`)

À faire une seule fois, dans le terminal de l'opérateur humain :

```bash
kubectl -n vault exec -it vault-0 -- vault operator init -key-shares=5 -key-threshold=3
```

Affiche 5 unseal keys et le root token. **Ne jamais les coller dans un
fichier du repo, un chat, un ticket, ou tout autre canal non chiffré.**
Options recommandées pour homelab :

- gestionnaire de mots de passe (1Password, Bitwarden, etc.) ;
- ou copie chiffrée hors ligne (ex. `age`/GPG) sur un support séparé du
  cluster lui-même (sinon perte du disque = perte des clés ET des
  données).

## 3. Unseal (`vault operator unseal`)

Après chaque redémarrage du pod Vault (le scellement est en mémoire) :

```bash
kubectl -n vault exec -it vault-0 -- vault operator unseal   # x3, avec 3 des 5 clés
```

Pour un homelab single-node, l'auto-unseal (KMS cloud, Transit d'un autre
Vault) est disproportionné — l'unseal manuel reste acceptable tant qu'il y
a un seul opérateur.

## 4. Policies

Une fois unsealed et authentifié (`vault login` avec le root token, à
n'utiliser que pour le setup initial — créer ensuite un compte
nominatif) :

```bash
vault policy write <nom> <fichier.hcl>
```

Aucune policy n'est encore définie dans ce repo — à ajouter au fur et à
mesure des besoins réels (ne pas anticiper des policies sans consommateur
concret).

## 5. Auth methods

Prévu : Kubernetes auth method (voir section 6). D'autres méthodes
(userpass, GitHub) à activer seulement si un besoin réel apparaît.

## 6. Intégration Kubernetes

Deux approches possibles pour connecter les workloads à Vault, pas encore
implémentées :

- **Kubernetes auth method** natif de Vault (les pods s'authentifient
  avec leur ServiceAccount token).
- **External Secrets Operator** (retenu comme candidat principal, voir
  [ADR-003](../../../docs/adr/ADR-003-secret-management.md)) — pont entre
  Vault et les Secrets Kubernetes, évite de dupliquer des secrets à la
  main.

À faire dans une itération dédiée, une fois Vault initialisé et un
premier secret réel à y stocker.

## 7. Rotation

Pas encore de politique de rotation automatisée. À minima : changer le
root token pour un token à durée de vie limitée après le setup initial
(`vault token revoke <root-token>` une fois des comptes nominatifs créés).

## 8. Backup / Recovery

- **Storage `file`** : pas de commande `vault operator raft snapshot` (ça
  n'existe qu'avec le backend Raft). La sauvegarde consiste à copier le
  contenu du volume `/vault/data` du pod (`kubectl cp`) pendant un arrêt
  du service, ou via un `VolumeSnapshot` si le provisioner le supporte un
  jour (`local-path-provisioner` ne le supporte pas actuellement). À
  automatiser plus tard (CronJob + stockage objet une fois
  `storage/object-storage` disponible). Pas encore fait.
- **Unseal keys** : perdues = cluster Vault définitivement inaccessible
  (pas de backdoor). Sauvegarde hors du cluster obligatoire (voir étape 2).
- Restauration : restaurer le contenu de `/vault/data` sur un volume vide
  avant le premier démarrage du pod, puis unseal normalement (étape 3).

## Upgrade

Monter `chart_version` après lecture du changelog Vault (les upgrades
majeurs de Vault peuvent nécessiter une procédure spécifique) —
`terraform plan` puis `apply`.

## Rollback

Revenir à l'ancienne valeur de `chart_version`. Le volume de données n'est
pas affecté par un rollback du chart seul.

## Troubleshooting

- Pod `Running` mais `vault status` indique `Sealed: true` → normal, voir
  étape 3.
- TLS interne désactivé dans cette version — à durcir dès qu'un ingress
  avec cert-manager existe (voir `features/networking/ingress`, pas encore
  implémenté).
