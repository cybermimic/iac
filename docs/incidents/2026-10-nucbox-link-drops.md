# Incident octobre 2026 — Coupures du lien Ethernet du NucBox, API Kubernetes en boucle

**Statut : diagnostiqué, remédiations R1 et R3 retenues** (rapport du 2026-10-27,
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
| Coupures longues | **Involontaires** (réponse de l'opérateur, 2026-10-28). Le NucBox n'a pas redémarré (démarré le 29/09) ; le noyau ne journalise **aucune erreur de la carte** (ni réinitialisation ni blocage), seulement des pertes et retours de lien : la piste câble / port de la Freebox est la plus probable. Retours de lien en journée (19:58, 12:43, 16:29, 12:40) : coïncidence, ou intervention involontaire sur place, impossible à trancher d'ici |

## Questions pour l'opérateur

1. Les coupures du 20/10 au 25/10 sont-elles volontaires (absence,
   déménagement de matériel, Freebox éteinte) ?
2. Le journal de la Freebox (Freebox OS → état du réseau) montre-t-il des
   redémarrages ou des coupures de port aux mêmes heures ?
3. Le câble est-il récent, en Cat5e ou mieux, et branché directement sur la
   Freebox ?

## Contraintes (2026-10-28)

L'opérateur **n'a pas d'accès physique** au NucBox pour l'instant, et n'a
rien à y brancher. Conséquences : R3 (câble, port) est **reportée** au
prochain accès ; R1 devient la seule remédiation applicable, **à distance** —
une erreur de configuration réseau rendrait la machine injoignable jusqu'à
une intervention sur place, d'où un filet de sécurité à prévoir (retour
arrière automatique si la machine n'est plus joignable).

## Remédiations proposées

Aucune n'est appliquée. Ce sont des réglages d'hôte : rôle Ansible
([ADR-001](../adr/ADR-001-terraform-scope.md)), exécuté par l'opérateur (`-K`).

| # | Action | Effet | Coût / risque |
|---|---|---|---|
| R1 | **Garder l'adresse pendant une coupure** : NetworkManager, réglage par interface `ignore-carrier=yes` pour `enp3s0` (fichier dans `/etc/NetworkManager/conf.d/`). Vérifié dans la documentation de la version installée (1.54.3) : « permet à toute connexion active, statique ou dynamique, de rester active quand le lien est perdu » | Une coupure courte ne fait plus disparaître l'IP : l'API server n'est plus redémarré, il reprend dès le retour du lien | Faible ; à tester une fois (débrancher 10 s le câble) |
| R2 | **Sondes de l'API server sur `127.0.0.1`** au lieu de l'IP du nœud, par un *patch* kubeadm (pas en modifiant le manifeste à la main : écrasé à la prochaine montée de version) | L'API server n'est plus tué par une coupure réseau | Moyen : touche le plan de contrôle ; à faire avec une montée de version kubeadm ou une reconfiguration planifiée |
| R3 | **Traiter la cause physique** : autre câble, autre port de la Freebox ; puis le switch 2,5 GbE prévu ([plan fleet-manager](../plans/fleet-manager.md)) change de partenaire de lien | Moins de coupures | Matériel |
| R4 | Si les coupures persistent : désactiver ASPM pour la carte (contournement courant pour I225/I226), après R3 | Moins de coupures si l'ASPM est en cause | Paramètre noyau, redémarrage |
| R5 | **Être prévenu** : alerte sur perte de lien et sur API indisponible (observabilité, à choisir) ; en attendant, `hack/status.sh` | Plus de panne de 3 jours découverte par hasard | Voir les options d'observabilité |
| R6 | **Relance automatique de la carte** : un minuteur systemd lit `/sys/class/net/enp3s0/carrier` chaque minute ; lien tombé depuis 5 min → `ip link set` down/up ; 15 min → rechargement du pilote `igc` ; ensuite au plus une tentative par heure. Jamais de redémarrage de la machine (il scellerait Vault) | Rétablissement sans intervention si la carte est bloquée ; surtout **diagnostic** : le journal dira si une relance logicielle suffit (carte → R4) ou non (physique → R3) | Faible : n'agit que lien déjà tombé. Rechargement du pilote à tester une fois sur place avant de l'activer |
| R7 | **Wi-Fi de secours** : la carte Wi-Fi du NucBox rejoint le Wi-Fi existant de la Freebox | Machine joignable pendant une coupure Ethernet (services K8s toujours indisponibles) | Mot de passe Wi-Fi à ranger sur la machine |

Recommandation : **R1 et R3 d'abord** (peu coûteux, effet immédiat), R5 dès
que l'outil d'observabilité est choisi, R2 et R4 seulement si nécessaire.

## Actions

| Action | Statut |
|---|---|
| Diagnostic (journaux noyau, kubelet, NetworkManager) | Fait (2026-10-27) |
| Réponses de l'opérateur : coupures involontaires ; pas d'accès physique pour l'instant | Fait (2026-10-28) |
| Choix des remédiations (2026-10-28) : **R1 et R3 retenues**, R5 avec l'outil d'observabilité, R2 et R4 seulement si les coupures persistent | Fait |
| R1 : playbook `features/networking/node-link` (`ignore-carrier`) | Écrit, à exécuter par l'opérateur |
| R3 : autre câble, autre port de la Freebox | Reportée : pas d'accès physique pour l'instant (accès possible au besoin, l'opérateur se connecte en SSH via VPN) |
| R6 : relance automatique de la carte | Retenue, **reportée** (décision de l'opérateur, 2026-10-28) |
| R7 : Wi-Fi de secours | Écartée pour l'instant (2026-10-28) |
