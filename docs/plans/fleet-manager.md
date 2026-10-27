# Plan — machines gérées par fleet-manager

**Statut : planifié** (2026-10-27). Décisions dans
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

**Déclencheur** : début du développement de fleet-manager, une fois que
fact-check produit des données (premier connecteur en service, étape 6 du
[plan fact-check](fact-check.md)).

| Achat | Détail | Prix indicatif |
|---|---|---|
| Switch | Zyxel **XMG1915-10E** : 8 × 2,5 GbE + 2 SFP+, administrable (smart), VLAN 802.1Q, sans ventilateur | ~170-230 € |
| Machine A (`cold`) | Lenovo ThinkCentre **M920q** Tiny reconditionné, **i5-8500T** (vPro), 16 Go, NVMe système 256 Go + **SSD SATA 2,5" 2 To** (Samsung 870 EVO `MZ-77E2T0B/EU` ou Crucial MX500 `CT2000MX500SSD1`) | ~200-250 € + ~150-200 € |
| Prise connectée | **Shelly Plug S Gen3** : Wi-Fi, fonctionne en local sans cloud, mesure de consommation | ~25 € |
| *Optionnel* : disque `frozen` | Disque USB 4 To (WD Elements Portable `WDBU6Y0040BBK` ou Seagate Expansion Portable `STKM4000400`), branché à la main | ~110 € |

Total : **~550-700 €** (~660-810 € avec le disque `frozen`).

Travaux (🤖 = agent, 👤 = opérateur) :

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
