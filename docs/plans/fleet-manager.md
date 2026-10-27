# Plan — machines gérées par fleet-manager

**Statut : temps 1 en attente d'achat** (2026-10-27) — l'opérateur
signale quand le matériel du temps 1 est acheté. Décisions dans
[ADR-013](../adr/ADR-013-storage-tiers-and-power.md) ; code dans le dépôt
privé [`cybermimic/fleet-manager`](https://github.com/cybermimic/fleet-manager).

Les achats se font **en deux temps**, chacun déclenché par un besoin
réel des applications, pas par anticipation. Prix indicatifs relevés en
octobre 2026, en pleine pénurie de mémoire : à revérifier au moment
d'acheter.

## Critères communs aux machines gérées

À vérifier sur la fiche du modèle exact :

1. Wake-on-LAN depuis l'état **éteint** (option BIOS ; désactiver « ErP » /
   « Deep Sleep », qui coupe la carte réseau).
2. Intel **AMT** : processeur vPro **et** chipset série Q **et** carte
   réseau Intel (I219-LM). Exemples : Lenovo ThinkCentre M920q / M90q, HP
   EliteDesk 800 G4/G5 Mini, Dell OptiPlex 7060/7070 Micro (versions
   vPro). Contre-exemples : M720q, M70q (pas de chipset Q).
3. Rallumage au retour du courant (option BIOS), pour le pilote « prise ».
4. Démarrage sans écran ni clavier, extinction ACPI propre.
5. RAM déjà installée (reconditionné), vu le prix actuel de la mémoire.

Points à contrôler à l'achat d'un M920q :

- processeur **i5-8500T, i5-8600T ou i7-8700T** (vPro) ; les i3 et Pentium
  n'ont pas AMT ;
- pour la machine A, le **support 2,5" et sa nappe SATA** : souvent absents
  des unités vendues sans disque, à demander ou à acheter à part ;
- carte réseau Intel I219-LM (nécessaire à AMT) : à confirmer sur la fiche
  PSREF de Lenovo.

Les deux machines sont **du même modèle** : un seul rôle Ansible, un seul
comportement BIOS/AMT, pièces interchangeables.

## Temps 1 — stockage `cold`

**Déclencheur** : décision de l'opérateur, pour démarrer fleet-manager
en parallèle de fact-check (dont le premier connecteur, étape 6 du
[plan fact-check](fact-check.md), fournira les premières données à
déplacer).

| Achat | Détail | Prix indicatif |
|---|---|---|
| Switch | Zyxel **XMG1915-10E** : 8 × 2,5 GbE + 2 SFP+, administrable (smart), VLAN 802.1Q, sans ventilateur | ~170-230 € |
| Machine A (`cold`) | Lenovo ThinkCentre **M920q** Tiny reconditionné, **i5-8500T** (vPro), 16 Go, NVMe système 256 Go + **SSD SATA 2,5" 2 To** (Samsung 870 EVO `MZ-77E2T0B/EU` ou Crucial MX500 `CT2000MX500SSD1`) | ~200-250 € + ~150-200 € |
| Prise connectée | **Shelly Plug S Gen3** : Wi-Fi, fonctionne en local sans cloud, mesure de consommation | ~25 € |
| *Optionnel* : disque `frozen` | Disque USB 4 To (WD Elements Portable `WDBU6Y0040BBK` ou Seagate Expansion Portable `STKM4000400`), branché à la main | ~110 € |

Total : **~550-700 €** (~660-810 € avec le disque `frozen`).

Travaux (🤖 = agent, 👤 = opérateur) :

0. 🤖 **Seconde recherche avant achat** (prix et disponibilité du moment) :
   - confirmer sur la fiche PSREF Lenovo du M920q la carte réseau
     I219-LM, et que l'AMT du modèle accepte une étiquette VLAN ;
   - confirmer le nombre de VLAN et le firmware à jour du XMG1915-10E ;
   - confirmer l'API locale (HTTP/RPC) de la Shelly Plug S Gen3 et sa
     compatibilité avec Matter activé ou non ;
   - comparer avec un équivalent HP EliteDesk 800 G4 Mini / Dell OptiPlex
     7060 Micro si le M920q est rare ou cher.
1. 👤 Switch en place, VLAN d'administration pour AMT, réservations DHCP
   sur la Freebox.
2. 👤 BIOS de la machine A (Wake-on-LAN, AMT, rallumage au retour du
   courant).
3. 🤖 Rôle Ansible des machines gérées (Wake-on-LAN, compte
   `fleet-manager` à commande forcée, ligne `sudoers`) ; 👤 exécution
   (`-K`) — première exécution réelle du bootstrap Ansible — puis
   `kubeadm join`.
4. 🤖 fleet-manager v0 : baux, pilotes Wake-on-LAN / AMT / prise, extinction
   après `cordon`, instance Garage `cold` sur le nœud A (*taint*
   `fleet-manager/tier=cold:NoSchedule`).
5. 🤖 Premier client : copie des exports mensuels et des documents
   `discontinued` de fact-check vers `cold`, avec vérification d'empreinte.

**Critères de sortie** :

- la machine A s'allume par les trois moyens et reste éteinte par défaut ;
- un export mensuel de fact-check est copié et vérifié sur `cold`, puis
  la machine s'éteint seule ;
- l'allumage mensuel (certificat du kubelet, vérification des disques)
  tourne ;
- consommation mesurée : éteinte, au repos, en copie.

### Préparation (avant réception)

**Adresses** (hors plage DHCP `.2`-`.200` et hors MetalLB `.240`-`.250`,
voir [platform-overview.md](../platform-overview.md)) :

| Adresse | Qui | Configuré où |
|---|---|---|
| `192.168.1.251` | `fleet-cold-01` (machine A) | Freebox → baux statiques |
| `192.168.1.252` | `fleet-compute-01` (machine B, temps 2) | Freebox → baux statiques |
| `192.168.1.239` | Switch, interface d'administration | Switch (IP fixe) |
| `192.168.1.238` | Prise Shelly | Freebox → baux statiques |

**VLAN d'administration (AMT)**, proposé, à valider à la réception :

- VLAN `10`, sous-réseau `10.10.10.0/24` (ne chevauche ni les pods
  `10.244.0.0/16` ni les Services `10.96.0.0/12`), **sans routeur ni
  DHCP** : adresses fixes, injoignable depuis le reste du LAN et
  d'Internet ;
- AMT de `fleet-cold-01` en `10.10.10.251`, de `fleet-compute-01` en
  `10.10.10.252` (même dernier octet que sur le LAN) ;
- le NucBox rejoint ce VLAN par une sous-interface (`10.10.10.253`,
  configurée par Ansible) : le composant Alimentation de fleet-manager,
  qui tourne sur le réseau de l'hôte pour le Wake-on-LAN, l'atteint
  directement ;
- ports du switch : Freebox en VLAN 1 seul ; NucBox et machines gérées en
  VLAN 1 non étiqueté + VLAN 10 étiqueté ;
- si l'AMT du M920q n'accepte pas d'étiquette VLAN : AMT reste sur le
  LAN, mot de passe fort, et l'isolation est reportée.

**Secrets à ranger dans Vault** (opérateur, valeurs jamais dans Git ni
dans un chat ; policy `external-secrets` lue d'abord, réécrite avec tous
les chemins existants) :

| Chemin (`secret/…`) | Propriétés | Quand |
|---|---|---|
| `fleet-manager/ssh` | `ssh_private_key` (clé du compte `fleet-manager`, commande forcée) | étape 3 |
| `fleet-manager/amt-fleet-cold-01` | `username`, `password` | étape 2 |
| `fleet-manager/shelly` | `password` (authentification locale de la prise) | étape 1 |

**BIOS de chaque machine** (noms d'options Lenovo à confirmer sur place) :

- mettre à jour le BIOS et le firmware Intel ME (AMT a eu des failles
  corrigées par firmware) ;
- *After Power Loss* : **Power On** ;
- *Wake on LAN* : **Automatic** (ou *Primary*) ;
- *Enhanced Power Saving Mode* (ou équivalent ErP) : **Disabled**, sinon
  la carte réseau est coupée à l'arrêt ;
- démarrage sans clavier ni écran, sans arrêt sur erreur ;
- mot de passe BIOS (gestionnaire de mots de passe de l'opérateur).

**AMT** (menu MEBx, `Ctrl+P` au démarrage) : changer le mot de passe par
défaut, activer l'accès réseau, IP fixe et VLAN ci-dessus, désactiver ce
qui ne sert pas (redirection IDE/USB).

**Switch** : mettre à jour le firmware, changer le mot de passe
d'administration, IP fixe, VLAN ci-dessus.

**Prise Shelly** : mettre à jour le firmware, désactiver le cloud, activer
l'authentification locale, état au retour du courant : **allumée** (la
machine redémarre, fleet-manager la rééteint faute de bail).

**Ansible** : ajouter `fleet-cold-01` au `hosts.yml` local (ignoré par
git), groupe `k8s_nodes`.

## Registre des machines

À remplir à la réception, puis à reporter dans
[platform-overview.md](../platform-overview.md) à la mise en service. Pas
de numéro de série ni de mot de passe ici (repo public) ; une adresse MAC
n'est pas un secret.

| Nom | Rôle | Modèle (type) | CPU | RAM | Disques | MAC LAN | IP LAN | IP AMT | Allumage validé | Mise en service |
|---|---|---|---|---|---|---|---|---|---|---|
| `fleet-cold-01` | `cold`, nœud Kubernetes (*taint* `fleet-manager/tier=cold`) | M920q (à relever) | i5-8500T (à confirmer) | 16 Go | NVMe 256 Go + SSD 2 To | — | `192.168.1.251` | `10.10.10.251` | — | — |
| `fleet-compute-01` | calcul à la demande (temps 2) | M920q (à relever) | — | 32 Go | NVMe 512 Go-1 To | — | `192.168.1.252` | `10.10.10.252` | — | — |
| switch | cœur du réseau du cluster | Zyxel XMG1915-10E | — | — | — | — | `192.168.1.239` | — | — | — |
| prise | pilote « prise » de `fleet-cold-01` | Shelly Plug S Gen3 | — | — | — | — | `192.168.1.238` | — | — | — |

## Temps 2 — calcul à la demande

**Déclencheur** : les deux conditions à la fois :

- les critères de sortie du temps 1 sont remplis ;
- fact-check approche un seuil d'extension d'[operations.md](../operations.md)
  (RAM disponible < 2 Gi ou disque > 75 %), typiquement avec ses sources
  suivantes, la recherche plein texte ou Metabase.

| Achat | Détail | Prix indicatif |
|---|---|---|
| Machine B | Lenovo ThinkCentre **M920q** Tiny, **i5-8500T** (vPro), **32 Go** (2 × 16 Go, le maximum du modèle), NVMe 512 Go-1 To | ~250-350 € |

Travaux :

1. 🤖 ADR « nœud de calcul à la demande » : `cluster-autoscaler` en mode
   `externalgrpc` ou baux fleet-manager seuls.
2. 👤 BIOS, Ansible (`-K`), `kubeadm join`.
3. 🤖 Pilote d'extinction après `drain`, intégration à la décision retenue.

**Choix à faire à ce moment-là** : le POC n'a pas de machine `warm`
(allumée en permanence, gros disque). Si les mesures du temps 1 montrent
que le NucBox manque de disque toujours accessible, la machine B peut
servir de nœud `warm` allumé en permanence (avec un SSD de grande
capacité) plutôt que de calcul à la demande.

## Budget total

**~800-1 050 €** sur les deux temps, hors disque `frozen`.
