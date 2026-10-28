# ADR-016 — Sauvegardes

**Statut : Acceptée** (2026-10-28) : toutes les recommandations sont
retenues par l'opérateur — Q1 A, Q2 A (`age`), Q3 Garage + disque USB puis
machine `cold` + hors site par disque échangé, Q4 telle que proposée, Q5
contrôle de forme quotidien et restauration trimestrielle.

## Contexte

Mesures du 2026-10-28 (lecture seule) :

| Donnée | Où | Taille | Sauvegarde aujourd'hui | Reconstituable sans sauvegarde ? |
|---|---|---|---|---|
| **etcd** (tous les objets Kubernetes) | `/var/lib/etcd` du NucBox | ~43 Mo | Aucune | Non (sauf à tout redéployer) |
| Vault | volume local-path | quelques Ko | Aucune — traité par l'[ADR-014](ADR-014-secrets-for-rebuild.md), P2 | Non |
| CA interne | Secret `cert-manager/homelab-root-ca` | — | Aucune — ADR-014, P3 | Non |
| Base de Keycloak (comptes, realms) | volume local-path | petite (mesure partielle : dossier lisible par root seulement) | `pg_dump` quotidien, 14 jours, **sur un volume du même disque** | Non |
| Données d'inner-riddle (SQLite) | volume local-path | 3,3 Mo | sauvegarde quotidienne, 14 jours, **sur le même volume que les données** | Non |
| Base de fact-check (catalogue, versions) | prévue (iac #26) | ~60 Mo mesurés en local | Aucune | En partie : les sources retirées et l'historique des versions, non |
| Archive brute de fact-check | Garage (prévu, iac #25) | ~340 Mo/an pour la 1re source | — : niveaux `cold`/`frozen` de l'[ADR-015](ADR-015-storage-tiers-and-power.md) | En partie (`discontinued` : non) |
| État Terraform | `~/.homelab-platform-state` du NucBox | 109 Mo (fournisseurs compris) | Aucune | Péniblement (`terraform import` ressource par ressource) |
| Images du registre | Zot | < 1 Mo | — | **Oui** : reconstruites par la CI depuis les étiquettes |
| Configuration ArgoCD, charts, manifestes | Git | — | GitHub | **Oui** |

**Tout ce qui n'est pas reconstituable vit sur un seul disque**, y compris
les deux sauvegardes existantes. Une panne du NVMe du NucBox perd les
données et leurs sauvegardes ensemble.

Deux faits pèsent sur la conception :

- **etcd n'est pas chiffré au repos** (aucune option de chiffrement sur
  l'API server) : un instantané etcd contient **tous les Secrets
  Kubernetes en clair**. Les dumps d'inner-riddle contiennent des données
  personnelles. Une sauvegarde doit donc être chiffrée **avant** de quitter
  la machine qui la produit.
- Le NucBox perd son lien réseau par moments (incident d'octobre 2026,
  iac #32) : une copie hors du NucBox doit tolérer d'échouer puis de
  reprendre.

## Exigences

1. **Aucune sauvegarde sur le disque qu'elle protège** (règle centrale).
2. **Chiffrées à la source**, la clé de déchiffrement hors du cluster.
3. Au plus **24 h de données perdues** (sauvegardes quotidiennes).
4. **Restaurations testées**, pas seulement des sauvegardes produites.
5. Évident à comprendre : un fichier par sauvegarde, daté, restaurable à la
   main.

## Q1 — Comment produire les sauvegardes

| Option | Principe | Pour | Contre |
|---|---|---|---|
| **A. Dumps applicatifs + instantanés hôte (recommandé)** | Un `CronJob` par base (`pg_dump`, `inner-riddle backup`, instantané `raft` de Vault) ; un timer systemd sur l'hôte (Ansible) pour l'instantané etcd (`etcdctl snapshot save`, certificats de l'hôte) et la copie de l'état Terraform | Chaque sauvegarde est **cohérente** (outil de l'application) ; prolonge les deux `CronJob` existants ; un fichier par sauvegarde | Un `CronJob` par application à écrire |
| B. Velero | Sauvegarde des ressources Kubernetes et des volumes (copie de fichiers) vers S3 | Générique | ~200-300 Mi ; copie de fichiers d'une base en cours d'écriture : incohérente sans crochets ; un outil de plus à comprendre |
| C. restic/kopia sur l'hôte seulement | Copie des dossiers des volumes | Un seul mécanisme | Même problème de cohérence des bases ; ne voit pas les objets Kubernetes |

## Q2 — Comment chiffrer

| Option | Principe | Pour | Contre |
|---|---|---|---|
| **A. `age`, chiffrement asymétrique (recommandé)** | Chaque fichier est chiffré avec la **clé publique** de l'opérateur (versionnée dans ce repo, ce n'est pas un secret) ; la clé privée reste hors ligne | Le cluster peut **écrire** des sauvegardes, jamais les **lire** : un attaquant dans le cluster n'accède pas à l'historique. Même clé que la copie de la CA (ADR-014, P3) | La clé privée devient une racine de confiance (perdue = sauvegardes illisibles) |
| B. Chiffrement intégré de restic | Mot de passe du dépôt | Déduplication, rétention, vérification intégrées | Le mot de passe est **dans le cluster** : qui y entre lit toutes les sauvegardes |
| C. Chiffrement du stockage seulement | Disque ou bucket chiffré | Transparent | Les fichiers circulent en clair ; ne protège pas d'un accès au bucket |

## Q3 — Où copier (règle 3-2-1 : 3 copies, 2 supports, 1 hors site)

| Copie | Support | Protège contre | Quand |
|---|---|---|---|
| 1 | **Garage** (`hot`, bucket `backups`) | Erreur de manipulation, corruption d'un volume — **pas** la perte du disque (même NVMe) | Dès iac #25 |
| 2 | **Hors du NucBox** : en attendant la machine `cold`, un **disque USB** branché au NucBox, copie quotidienne automatique ; puis la machine `cold` (ADR-015) | Perte du disque du NucBox | USB : tout de suite ; `cold` : temps 1 du plan d'achat |
| 3 | **Hors site** : disque `frozen` déposé ailleurs et échangé chaque mois (👤), **ou** stockage objet d'un hébergeur (fichiers déjà chiffrés, quelques centimes par mois à ce volume) | Sinistre (vol, incendie, surtension) | À choisir |

Retenu : copies 1 et 2 dès que possible ; pour la 3, le disque échangé
(aucun tiers).

## Q4 — Rétention et outil de copie

**Recommandé** : fichiers chiffrés nommés `<source>/<AAAA-MM-JJ>.<ext>.age`,
copiés avec `rclone` (déjà retenu par l'ADR-015 pour fleet-manager).
Rétention : 7 quotidiennes, 4 hebdomadaires, 6 mensuelles, par un petit job
de nettoyage fondé sur la date du nom (règle lisible, testable). Volume
aujourd'hui : moins de 1 Go au total.

Alternative : restic (déduplication et rétention intégrées), écartée en Q2
pour son mot de passe présent dans le cluster.

## Q5 — Prouver qu'une restauration marche

- **Chaque mois, automatiquement** : un job restaure le dernier dump de
  chaque base dans une base **temporaire** (même principe que les tests
  d'intégration de fact-check), vérifie qu'elle s'ouvre et contient des
  données, puis la supprime. Échec = `FAIL` dans `hack/status.py`.
  Impossible sans la clé privée, qui reste hors du cluster. Un job ne peut
  vérifier que la **forme** (fichier présent, en-tête `age` valide, taille
  plausible) : `age` chiffre mais ne signe pas, l'intégrité réelle ne se
  prouve qu'en déchiffrant. Deux choix : contrôle de forme automatique, ou
  une **seconde clé** dédiée aux tests de restauration, présente dans le
  cluster (elle affaiblit alors la propriété « le cluster ne peut pas
  relire »). **Recommandé** : contrôle de forme automatique quotidien
  (ligne dans `hack/status.py`) + restauration complète à la main chaque
  trimestre (👤), sur une base temporaire.
- **Une fois par an** : exercice complet du runbook de reconstruction
  (iac #34) sur une machine vierge.

## Ordre de mise en œuvre proposé (si les recommandations sont retenues)

1. 👤 Créer la paire de clés `age` (privée hors ligne, publique dans le
   repo) — partagée avec ADR-014 P3.
2. **etcd et état Terraform** (timer systemd, Ansible) vers le disque USB :
   le plus gros manque, sans dépendance à Garage.
3. Dumps Keycloak et inner-riddle **chiffrés** vers Garage, puis vers l'USB ;
   les sauvegardes sur le même disque disparaissent.
4. Vault (ADR-014, P2) et base de fact-check sur le même modèle.
5. Contrôle de forme quotidien dans `hack/status.py`, restauration
   trimestrielle à la main.
6. Copie 3 (hors site) selon Q3.

## Conséquences

- La clé privée `age` entre au [registre des secrets](../secrets.md) comme
  racine de confiance.
- RAM : négligeable (jobs de quelques secondes). Disque : < 1 Go par copie
  aujourd'hui, croissance surtout via fact-check.
- Les deux sauvegardes existantes changent de destination ; leurs README
  (Keycloak, inner-riddle) sont mis à jour en même temps.
- Pas de chiffrement d'etcd au repos dans cette ADR : sujet distinct (il
  protégerait le disque, pas les sauvegardes, déjà chiffrées par Q2).
