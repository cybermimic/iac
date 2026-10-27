# Incident octobre 2026 — Coupures du lien Ethernet du NucBox, API Kubernetes en boucle

**Statut : diagnostiqué, remédiation à décider** (rapport du 2026-10-27,
établi en lecture seule : journaux du noyau, du kubelet et de NetworkManager).

## Résumé

`kube-apiserver` affichait **995 redémarrages**, `calico-kube-controllers`
**1583**. Ce n'est pas un problème de Kubernetes : le **lien Ethernet physique
du NucBox tombe**, NetworkManager retire alors son adresse `192.168.1.253`,
et l'API server — sondé sur cette adresse — est redémarré en boucle par le
kubelet jusqu'au retour du lien. Plusieurs coupures ont duré des heures,
dont une de près de **3 jours** : la plateforme entière, y compris les
services publics (inner-riddle, Keycloak), était alors hors ligne.

## Chronologie (heure locale)

19 coupures du lien enregistrées par le noyau en octobre (`igc 0000:03:00.0
enp3s0: NIC Link is Down`), dont 13 de quelques secondes. Les plus longues :

| Début de la coupure | Durée |
|---|---|
| 18/10 17:11 | 15 min |
| 20/10 23:11 | ~21 h |
| 21/10 20:11 | 1 h 30 |
| 21/10 21:41 | ~15 h |
| 22/10 16:19 | 9 min |
| 22/10 16:43 | **~69 h**, jusqu'au 25/10 vers 13:40 |

Coupures par jour : 2/10 (2), 7/10, 12/10, 18/10 (5), 19/10, 20/10 (4),
21/10 (2), 22/10 (3) — **en hausse depuis le 18**. Le journal ne remonte pas
avant octobre.

Le dernier redémarrage de `kube-apiserver` (25/10, 13:34-13:38) coïncide
avec la fin de la coupure de 69 h. Stable depuis.

## Mécanisme

1. Le lien tombe (`NIC Link is Down`).
2. NetworkManager passe l'interface en `unavailable` (`reason
   'carrier-changed'`), abandonne le bail DHCP : **l'adresse 192.168.1.253
   disparaît**.
3. Les sondes de `kube-apiserver` visent `https://192.168.1.253:6443/livez`
   (`network is unreachable`) : le kubelet le redémarre, puis l'espace en
   `CrashLoopBackOff` (jusqu'à **5 min** entre deux essais).
4. Au retour du lien, l'adresse revient, mais l'API peut rester absente
   jusqu'à 5 min de plus à cause de ce délai ; les contrôleurs qui en
   dépendent (Calico) redémarrent à leur tour.

Même une coupure de 3 secondes coûte donc plusieurs minutes d'API
indisponible.

## Causes

| Constat | Détail |
|---|---|
| Carte réseau | Intel **I226-V** (rev 04), pilote `igc`, noyau 7.0.0-34. Les coupures de lien de cette famille (I225/I226) sont un problème connu, lié selon les cas au pilote, au micrologiciel, à la gestion d'énergie PCIe (ASPM) ou au partenaire de lien |
| Économie d'énergie Ethernet (EEE) | **Déjà désactivée** (`ethtool --show-eee`) : pas la cause |
| Lien négocié | 1000 Mb/s ; partenaire de lien : la Freebox, sans switch d'après [platform-overview](../platform-overview.md) (à confirmer) |
| Coupures longues | **Cause inconnue** : câble débranché, Freebox éteinte ou en mise à jour, absence ? À confirmer par l'opérateur |

## Questions pour l'opérateur

1. Les coupures du 20/10 au 25/10 sont-elles volontaires (absence,
   déménagement de matériel, Freebox éteinte) ?
2. Le journal de la Freebox (Freebox OS → état du réseau) montre-t-il des
   redémarrages ou des coupures de port aux mêmes heures ?
3. Le câble est-il récent, en Cat5e ou mieux, et branché directement sur la
   Freebox ?

## Remédiations proposées (à décider)

Aucune n'est appliquée. Ce sont des réglages d'hôte : rôle Ansible
([ADR-001](../adr/ADR-001-terraform-scope.md)), exécuté par l'opérateur (`-K`).

| # | Action | Effet | Coût / risque |
|---|---|---|---|
| R1 | **Garder l'adresse pendant une coupure** : NetworkManager, réglage par interface `ignore-carrier=yes` pour `enp3s0` (fichier dans `/etc/NetworkManager/conf.d/`). Vérifié dans la documentation de la version installée (1.54.3) : « permet à toute connexion active, statique ou dynamique, de rester active quand le lien est perdu » | Une coupure courte ne fait plus disparaître l'IP : l'API server n'est plus redémarré, il reprend dès le retour du lien | Faible ; à tester une fois (débrancher 10 s le câble) |
| R2 | **Sondes de l'API server sur `127.0.0.1`** au lieu de l'IP du nœud, par un *patch* kubeadm (pas en modifiant le manifeste à la main : écrasé à la prochaine montée de version) | L'API server n'est plus tué par une coupure réseau | Moyen : touche le plan de contrôle ; à faire avec une montée de version kubeadm ou une reconfiguration planifiée |
| R3 | **Traiter la cause physique** : autre câble, autre port de la Freebox ; puis le switch 2,5 GbE prévu ([plan fleet-manager](../plans/fleet-manager.md)) change de partenaire de lien | Moins de coupures | Matériel |
| R4 | Si les coupures persistent : désactiver ASPM pour la carte (contournement courant pour I225/I226), après R3 | Moins de coupures si l'ASPM est en cause | Paramètre noyau, redémarrage |
| R5 | **Être prévenu** : alerte sur perte de lien et sur API indisponible (observabilité, à choisir) ; en attendant, `hack/status.sh` | Plus de panne de 3 jours découverte par hasard | Voir les options d'observabilité |

Recommandation : **R1 et R3 d'abord** (peu coûteux, effet immédiat), R5 dès
que l'outil d'observabilité est choisi, R2 et R4 seulement si nécessaire.

## Actions

| Action | Statut |
|---|---|
| Diagnostic (journaux noyau, kubelet, NetworkManager) | Fait (2026-10-27) |
| Réponses de l'opérateur aux questions ci-dessus | À faire |
| Choix des remédiations | À faire |
