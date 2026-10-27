# ADR-013 — Niveaux de stockage et allumage des machines à la demande (fleet-manager)

**Statut : Acceptée** (2026-10-27) pour les principes. Le matériel, les
moyens d'allumage de chaque machine et le support `frozen` restent à
choisir (voir « Décisions reportées »).

## Contexte

- fact-check archive les données publiques brutes : 100-250 Go la première
  année, puis 50-150 Go par an (estimation non mesurée, voir son
  `docs/adr/ADR-001-data-and-provenance.md`). Le NucBox n'a que ~40 Go
  utilisables avant le seuil d'extension (voir [operations.md](../operations.md)).
- Une partie de ces données n'existera bientôt plus qu'ici : les documents
  retirés par leur source (statut `discontinued`).
- L'ajout de machines est envisagé. L'opérateur veut qu'elles ne tournent
  **que lorsqu'on en a besoin** : éteintes par défaut, allumées
  automatiquement (paquet magique Wake-on-LAN ou autre moyen), puis
  rééteintes.
- Le besoin n'est pas propre à fact-check : toute application ou feature
  qui produit des données à garder longtemps (sauvegardes Vault, archives)
  est concernée.
- [ADR-004](ADR-004-storage-architecture.md) : Garage pour le stockage
  objet, nœuds de stockage distincts des nœuds de calcul au passage
  multi-nœud.

## Décisions

### 1. Quatre niveaux de stockage et un statut

| Niveau | Machine | Contenu typique | Délai d'accès |
|---|---|---|---|
| **hot** | Allumée en permanence, NVMe | Bases, index, données récentes | immédiat |
| **warm** | Allumée en permanence, disque de grande capacité | Données anciennes encore consultées | secondes |
| **cold** | **Éteinte par défaut**, allumée à la demande | Copie complète des archives | minutes (démarrage) |
| **frozen** | Support déconnecté, idéalement hors site | Copie complète, rafraîchie périodiquement | heures à jours, intervention humaine |

**`discontinued` est un statut, pas un niveau** : une donnée dont nous
détenons peut-être la seule copie. Elle doit exister au moins en `warm`,
`cold` **et** `frozen`, et n'est jamais purgée.

### 2. Un service maison : fleet-manager

Code dans le dépôt privé
[`cybermimic/fleet-manager`](https://github.com/cybermimic/fleet-manager),
déployé par ArgoCD comme une application ([ADR-008](ADR-008-gitops-layout.md)).
Deux composants :

| Composant | Rôle |
|---|---|
| **Alimentation** | Allume une machine par le moyen qui lui est propre, attend qu'elle réponde, l'éteint proprement quand plus personne n'en a besoin |
| **Niveaux** | Tient le catalogue (quel objet, quelle empreinte, sur quels niveaux, vérifié quand), copie entre niveaux, vérifie l'empreinte après copie, ne supprime une copie qu'une fois les copies requises vérifiées |

**Contrat entre les deux : le bail.** Un client demande « la machine X
pendant 30 minutes ». L'alimentation allume la machine si besoin, et ne
l'éteint qu'une fois **tous** les baux expirés, plus un délai d'inactivité.
Le composant Niveaux est le premier client ; d'autres pourront suivre.

**Partage des catalogues.** fleet-manager sait **où** se trouve chaque
objet. Les applications gardent leur propre catalogue de **ce que** sont
leurs données (pour fact-check : documents sources et traçabilité) et
déclarent, par objet, le nombre de copies requis par niveau. Une
application ne connaît jamais l'emplacement physique d'un objet.

Transport : `rclone` (copie entre stockages S3 et SFTP, vérification par
empreinte), plutôt qu'un format propre qui enfermerait les données.

### 3. Répartition entre les dépôts

| Dépôt | Contient |
|---|---|
| `cybermimic/fleet-manager` | Le code, ses tests, ses images, son chart Helm, sa CI (runners ARC, dépôt privé — [ADR-011](ADR-011-ci-runners.md)) |
| `cybermimic/iac` (ce repo) | Cette ADR ; la feature qui déploie fleet-manager (`Application` ArgoCD, `ExternalSecret`) ; le rôle Ansible des machines gérées (Wake-on-LAN de la carte réseau, compte dédié, stockage de la machine `cold`) |

Aucun code de fleet-manager dans ce repo, comme pour toute application.

### 4. Une machine éteinte par défaut reste hors du cluster de stockage

Un cluster Garage dont un nœud est éteint fonctionne en mode dégradé. Une
machine `cold` est donc **un hôte hors de Kubernetes**, configuré par
Ansible ([ADR-001](ADR-001-terraform-scope.md) : la configuration d'hôte
ne passe jamais par Terraform), avec son propre stockage indépendant du
Garage `hot`/`warm` (instance Garage séparée ou simple cible SFTP, à
choisir).

Les machines de **calcul** sont un cas différent : un nœud Kubernetes peut
être éteint s'il est vidé avant (`drain`) et ne porte aucun volume local.
Piste à évaluer dans une ADR séparée quand un nœud de calcul arrivera :
laisser `cluster-autoscaler` décider quand ajouter ou retirer un nœud
selon les pods en attente, en mode fournisseur externe (`externalgrpc`),
fleet-manager se chargeant seulement d'allumer et d'éteindre. Ce mode
existe toujours en 2026 ; son évolution (découpage du projet en
fournisseurs séparés, proposé début 2026) reste à suivre.

### 5. Allumage : un pilote par machine

Chaque machine gérée déclare son moyen d'allumage :

| Moyen | Allumage | Points d'attention |
|---|---|---|
| Wake-on-LAN (paquet magique) | Paquet UDP diffusé sur le LAN | Carte réseau et BIOS compatibles, Wake-on-LAN activé par Ansible ; la diffusion doit partir du réseau de l'hôte (pod en `hostNetwork` ou petit agent sur un hôte), pas d'un pod sur le réseau Calico |
| Prise connectée + « allumage au retour du courant » dans le BIOS | Remise sous tension | N'importe quelle machine ; ne couper la prise qu'après une extinction propre confirmée |
| Gestion à distance intégrée (Intel AMT/vPro, IPMI) | Commande réseau | Seulement sur certaines machines ; interface à isoler du reste du LAN |

Un échec d'allumage est signalé et n'est pas réessayé indéfiniment.

### 6. Extinction : une exception accordée au seul fleet-manager

Aujourd'hui, aucune machine du parc n'a de sudo sans mot de passe. Cette
ADR accorde **une seule exception**, limitée à l'extinction et à
fleet-manager :

- sur chaque machine gérée, un compte dédié `fleet-manager`, créé par
  Ansible ;
- sa clé SSH n'autorise qu'une commande (`command="sudo systemctl
  poweroff"` dans `authorized_keys`, plus `no-pty`, `no-port-forwarding`) ;
- une seule ligne `sudoers` pour ce compte, limitée à
  `/usr/bin/systemctl poweroff` ;
- la clé privée vit dans Vault (`secret/fleet-manager/ssh`), lue par
  External Secrets ([ADR-003](ADR-003-secret-management.md)).

Garde-fous :

- fleet-manager n'agit que sur une **liste explicite** de machines,
  déclarée dans la configuration de la feature ; le NucBox (plan de
  contrôle) n'y figure **jamais** ;
- il n'éteint une machine qu'une fois tous ses baux expirés, les copies en
  cours terminées et vérifiées, et, pour un nœud Kubernetes, après un
  `drain` réussi.

## Décisions reportées

- **Matériel** des niveaux `warm` et `cold`, et nombre de machines (voir
  l'estimation de capacité et les seuils d'[operations.md](../operations.md)).
- **Moyen d'allumage** de chaque machine, selon le matériel choisi.
- **Stockage de la machine `cold`** : instance Garage indépendante ou cible
  SFTP.
- **Support `frozen`** (disque hors ligne, second site), fréquence de
  rafraîchissement, test de restauration.
- **Noms des niveaux** : `hot` / `warm` / `cold` / `frozen` proposés,
  alignés sur l'usage courant ; à confirmer à l'usage.
- **Alertes** : pas encore d'observabilité sur la plateforme ; les échecs
  (allumage, copie, vérification) n'ont pour l'instant que les journaux.

## Alternatives considérées

- **`git-annex`** : conçu pour répertorier des fichiers sur des stockages
  multiples, dont des disques hors ligne, avec un nombre minimal de
  copies. Rejeté : un outil de plus à maîtriser, métadonnées dans un dépôt
  Git à éprouver sur des millions de fichiers, et un second catalogue à
  côté de ceux des applications.
- **Fonctions de cycle de vie du stockage objet** : Garage ne place pas un
  bucket sur un nœud choisi et ne déplace pas, à notre connaissance, les
  objets d'une classe de stockage à une autre ; et aucun stockage ne sait
  allumer une machine.
- **Tout laisser allumé** : plus simple, mais coût électrique, bruit et
  usure de machines qui servent quelques minutes par jour ; contraire au
  souhait de l'opérateur.
- **Allumage manuel par un humain** : acceptable pour `frozen` seulement.

## Conséquences

- Nouveau dépôt privé `cybermimic/fleet-manager` (créé le 2026-10-27).
- Nouveau chemin Vault `secret/fleet-manager/*` à ajouter à la policy
  `external-secrets` (lue d'abord, réécrite avec **tous** les chemins
  existants).
- Le rôle Ansible des machines gérées sera la première exécution réelle du
  bootstrap Ansible, jamais lancé jusqu'ici (mot de passe `-K` saisi par
  un humain).
- La conception de fact-check renvoie à cette ADR pour les niveaux et le
  déplacement des données ; elle ne garde que ses besoins (statut
  `discontinued`, copies requises).
