# ADR-014 — Secrets et reconstruction de la plateforme

**Statut : Acceptée** (2026-10-28) : toutes les recommandations sont
retenues par l'opérateur — P1 A (générateur External Secrets +
`PushSecret` `IfNotExists`), P2 D1 (stockage `raft` + instantanés),
P3 E1 (copie chiffrée `age` hors ligne de la CA, même clé que les
sauvegardes de l'[ADR-016](ADR-016-backups.md)), P4 F1 (secrets tiers
couverts par les instantanés).

## Contexte

Le [registre des secrets](../secrets.md) montre qu'une reconstruction du
cluster perdrait aujourd'hui :

- **tous les secrets de Vault** : stockage `file` sur un volume local-path
  (vérifié le 2026-10-27 : `Storage Type file`, Vault 2.0.4), sans aucune
  sauvegarde ;
- **la CA interne** : sa clé privée vit dans le Secret
  `cert-manager/homelab-root-ca`, nulle part ailleurs. Son certificat est
  épinglé dans Git (`docs/homelab-root-ca.crt`, `caBundle` du
  `ClusterSecretStore`, scripts clients) ;
- **le savoir-faire** : une quinzaine de `openssl rand | vault kv put`
  manuels répartis dans les README.

[ADR-003](ADR-003-secret-management.md) pose les principes (rien en clair
dans Git, Vault source de vérité, SOPS/age pour le bootstrap) ;
cette ADR décide **comment** une reconstruction retrouve ses secrets.

### Deux reconstructions différentes

| Cas | Exemple | Ce qu'il faut |
|---|---|---|
| **Infra vierge** | Nouveau cluster, données re-téléchargeables | Des secrets **nouveaux** suffisent, à condition d'être cohérents entre eux |
| **Avec données** | Disque du NucBox perdu, bases restaurées | Les **anciennes** valeurs : un mot de passe régénéré ne correspond plus à une base restaurée |

Un seul mécanisme doit couvrir les deux, sinon le second cas sera découvert
le jour de la panne.

### Ce qui ne change pas

Les **racines de confiance** (clés d'unseal et root token de Vault, clé
`age` si elle est adoptée) restent détenues par l'opérateur, hors ligne,
jamais générées ni lues par une machine ou un agent (ADR-003, CLAUDE.md).
L'unseal de Vault reste manuel.

## P1 — Les secrets « générés » (la majorité)

Mots de passe de bases, secret RPC de Garage, clés S3, comptes du registre,
clés SSH internes : personne n'a besoin de les connaître.

| Option | Principe | Pour | Contre |
|---|---|---|---|
| **A. External Secrets : générateur + `PushSecret` (recommandé)** | Dans Git, on déclare « ce secret est une valeur hexadécimale de 32 octets ». External Secrets la génère **une fois** et la pousse dans Vault **seulement si elle n'y est pas déjà** ; les consommateurs lisent Vault comme aujourd'hui | Infra vierge : tout se recrée seul. Avec données : la valeur restaurée dans Vault est gardée, rien n'est écrasé. Aucun secret dans Git, dans l'état Terraform ni dans un terminal. Déjà installé, aucune RAM en plus | La policy d'External Secrets gagne l'**écriture** sur les chemins générés. Un dérivé (htpasswd de Zot, clé importée dans Garage) demande une étape de plus (modèle ou Job) |
| B. Terraform : `random_password` + provider Vault | Terraform génère et écrit dans Vault | Outil connu | Secrets **en clair dans l'état Terraform** (sur le disque du NucBox, sans backend chiffré, ADR-005) ; hors du périmètre de Terraform ([ADR-001](ADR-001-terraform-scope.md)) |
| C. Statu quo | Commandes manuelles documentées | Rien à construire | Une reconstruction = une quinzaine d'opérations à la main, dans le bon ordre |

Vérifié sur la version installée (External Secrets, chart 2.12.0, CRD du
cluster le 2026-10-27) : générateurs `Password` (encodage `hex` possible)
et `SSHKey` (`ed25519`), `refreshPolicy: CreatedOnce` sur
`ExternalSecret`, `updatePolicy: IfNotExists` et `deletionPolicy: None` sur
`PushSecret`.

Chaîne pour un secret généré (option A) :

```
Password (générateur)
  → ExternalSecret « …-generated » (refreshPolicy: CreatedOnce) → Secret local
  → PushSecret (updatePolicy: IfNotExists, deletionPolicy: None) → Vault
  → ExternalSecret habituel (lit Vault) → Secret consommé par l'application
```

Les consommateurs lisent **toujours Vault**, jamais le Secret généré :
après une restauration, c'est la valeur restaurée qui gagne.

## P2 — Sauvegarder Vault

| Option | Principe | Pour | Contre |
|---|---|---|---|
| **D1. Stockage `raft` + instantanés (recommandé)** | Migration `file` → `raft` (`vault operator migrate`, Vault arrêté), puis un `CronJob` prend un instantané (`vault operator raft snapshot save`) et l'envoie dans Garage, puis vers les niveaux `cold` et `frozen` ([ADR-015](ADR-015-storage-tiers-and-power.md)) | Instantané cohérent à chaud ; **inutilisable sans les clés d'unseal** (données chiffrées), donc stockable hors de Vault sans risque ; couvre aussi les secrets « tiers » | Migration d'un composant en production : opération planifiée avec l'opérateur, sauvegarde du volume avant. Le `CronJob` a besoin d'un rôle Kubernetes auth dédié (`vault-backup`), limité à `sys/storage/raft/snapshot` |
| D2. Copie du volume `file` | Copier le dossier de données | Pas de migration | Copie à chaud incohérente ; Vault doit être arrêté (donc rescellé) pour une copie propre |
| D3. Aucune sauvegarde | — | — | Cas « avec données » impossible |

Raft était écarté à l'installation (« n'apporte de valeur qu'en HA ») : les
instantanés sont une seconde raison, apparue depuis.

## P3 — La CA interne

Elle ne peut **pas** être sauvegardée dans Vault : il faut la CA pour
joindre Vault (certificat de Vault signé par elle, `caBundle` du
`ClusterSecretStore`). Elle doit être restaurée **avant** cert-manager et
Vault.

| Option | Principe | Pour | Contre |
|---|---|---|---|
| **E1. Copie chiffrée hors ligne (recommandé)** | Export unique du Secret `homelab-root-ca`, chiffré avec `age` pour la clé de l'opérateur, gardé hors ligne (et, au choix, dans Git sous `sops`). À la reconstruction : déchiffrer, recréer le Secret, puis cert-manager le reprend au lieu d'en générer une nouvelle | La CA et toutes ses empreintes épinglées survivent ; aucun poste client à reconfigurer | Une racine de plus (clé `age`) ; procédure de restauration à tester une fois |
| E2. Accepter une nouvelle CA | Rien à sauvegarder | Simple | À chaque reconstruction : nouveau `docs/homelab-root-ca.crt`, empreintes, `caBundle`, réinstallation sur chaque poste |

La CA est valable dix ans (jusqu'en 2036) : l'export est à faire **une
fois**, puis à chaque renouvellement.

## P4 — Les secrets « tiers »

Clé privée de la GitHub App, clés de déploiement ArgoCD, futures clés d'API
(INSEE, PISTE).

| Option | Principe | Pour | Contre |
|---|---|---|---|
| **F1. Couverts par les instantanés de Vault (recommandé, avec D1)** | Rien de plus | Un seul mécanisme | Dépend de D1 |
| F2. Copie `sops`/`age` dans Git en plus | Un fichier chiffré par secret | Indépendant de Vault | Doublon à tenir à jour ; une fuite de la clé `age` expose tout l'historique |
| F3. Réémission | Nouvelle clé chez le tiers (GitHub l'autorise pour une App et une clé de déploiement) | Rien à stocker | Manuel, et impossible pour un tiers qui ne réémet pas |

Les clés de déploiement ArgoCD peuvent aussi passer en « générées »
(générateur `SSHKey`), la partie publique restant à enregistrer chez GitHub.

## Ordre de reconstruction visé (si A, D1, E1, F1)

1. Bootstrap des hôtes (Ansible) et du socle (Terraform).
2. **Restaurer la CA** (E1) avant le module cert-manager.
3. Vault : `vault operator init` **ou** restauration du dernier instantané,
   puis unseal — par l'opérateur.
4. Infra vierge : appliquer la policy versionnée
   (`features/security/vault/policies/`) et le rôle Kubernetes auth.
5. ArgoCD synchronise ; External Secrets génère ce qui manque dans Vault
   (vierge) ou retrouve les valeurs restaurées (avec données).
6. À la main : seulement les secrets tiers absents de l'instantané.

## Mise en œuvre proposée, par petites étapes

1. P3 (E1) d'abord : le moins coûteux, et la perte la plus douloureuse
   aujourd'hui. Procédure d'export documentée, exécutée par l'opérateur.
2. P1 (A) sur **un** secret pilote pas encore créé : `fact-check/postgres`
   (iac #26). Vérifier `CreatedOnce` et `IfNotExists` en vrai, puis étendre
   secret par secret.
3. P2 (D1) : planifiée avec l'opérateur (sauvegarde du volume, fenêtre
   d'arrêt, unseal), puis le `CronJob` d'instantanés.

## Conséquences (si les recommandations sont retenues)

- La policy d'External Secrets reçoit `create`/`update` sur les seuls
  chemins générés ; ils restent listés dans le fichier de policy versionné.
- Le registre des secrets indique pour chaque secret son mécanisme (généré,
  instantané, hors ligne).
- RAM : rien de notable (un `CronJob` d'instantanés de quelques secondes).
- Les procédures manuelles `openssl rand | vault kv put` disparaissent des
  README au fur et à mesure de la migration.
