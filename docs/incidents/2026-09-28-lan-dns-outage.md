# Incident 2026-09-28 — Plus de DNS sur le LAN, puis cluster indisponible

## Résumé

Le matin du 2026-09-28, les appareils du LAN n'avaient plus de résolution
de noms. Le DNS du LAN était alors fourni par le pod `lan-dns` sur le
NucBox (ADR-007). La Freebox a été remise manuellement dans sa
configuration d'origine (DNS = Freebox), ce qui a coupé le lien Ethernet
du NucBox ; le NucBox a ensuite été redémarré brutalement. Le cluster est
revenu seul ~10 minutes après le retour du lien. Décision prise ensuite :
abandonner le DNS du LAN (ADR-007 → abandonné) au profit d'un accès aux
services par IP.

## Chronologie (heure locale)

| Heure | Événement | Source |
|---|---|---|
| 27/09 ~17h | Freebox reconfigurée : DNS du DHCP = NucBox, DNS IPv6 forcé = NucBox | ADR-007 |
| 28/09 06h31 | `unattended-upgrades` met à jour `network-manager` (et le noyau) : NetworkManager redémarre et reprend la connexion à chaud, **sans perte de lien** | `dpkg.log`, journal NetworkManager |
| 06h31 → 10h02 | Aucun redémarrage ni échec de sonde du pod `lan-dns` vu par le kubelet | journal kubelet |
| ~10h00 | Constat utilisateur : le DNS ne fonctionne plus sur le poste | utilisateur |
| ~10h00 | Freebox remise « comme avant » depuis un autre poste | utilisateur |
| **10h02** | **Perte du lien Ethernet du NucBox** (`carrier-changed`), perte de son IP ; `lan-dns` ne peut plus écouter sur ses adresses → `CrashLoopBackOff` | journal NetworkManager, kubelet |
| 10h40 | Redémarrage brutal du NucBox (aucun arrêt propre dans le journal) ; démarrage sur le nouveau noyau `7.0.0-34` | `journalctl --list-boots` |
| 10h45 | Retour du lien Ethernet, bail DHCP `192.168.1.253` | journal NetworkManager |
| 10h41 → 10h49 | etcd et kube-apiserver en `CrashLoopBackOff` (ils écoutent sur `192.168.1.253`, absente jusqu'à 10h45), puis API disponible | journal kubelet |
| ~10h52 | Tous les pods revenus ; Vault scellé (unseal manuel requis) | `kubectl` |

## Causes

- **De 10h02 à 10h52 : établie.** Plus de lien réseau sur le NucBox, donc
  plus de DNS pour tout le LAN (dépendance unique acceptée par ADR-007),
  puis redémarrage du control-plane qui attend l'IP du nœud.
- **Avant 10h02 : non établie.** Côté NucBox, rien d'anormal n'est visible
  (pod `lan-dns` en service, aucune sonde en échec). Le seul événement
  notable est le redémarrage de NetworkManager à 06h31, sans perte de lien.
  Hypothèses non vérifiables a posteriori : effet de ce redémarrage sur les
  sockets liées aux adresses du nœud (plugin CoreDNS `bind`), ou état côté
  Freebox / poste client. Les logs du conteneur (`/var/log/pods`) n'étaient
  lisibles qu'en root et ont été perdus au redémarrage.

## Ce qui a aggravé

- **Point de défaillance unique** : tout le LAN dépendait d'un pod sur une
  machine sans redondance (conséquence explicitement acceptée par ADR-007).
- **Aucune surveillance** : la panne a été découverte par l'utilisateur.
- **Retour lent après une perte d'adresse** : `lan-dns` et le control-plane
  plantent tant que leur adresse d'écoute n'existe pas, avec des délais de
  relance croissants (jusqu'à 5 min).

## Actions

| Action | Statut |
|---|---|
| Freebox remise en configuration d'origine (DNS = Freebox) | Fait (utilisateur) |
| Abandon du DNS du LAN : ADR-007 → abandonné, feature `networking/lan-dns` supprimée | En cours |
| Accès aux services par IP (une IP MetalLB par service) | Prévu |
| Observabilité + alerte (API Kubernetes, services publiés) | À planifier |
| Mises à jour automatiques : les documenter (redémarrage de NetworkManager, noyau à redémarrer) | À faire |
