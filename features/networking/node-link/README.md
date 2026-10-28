# networking/node-link

## Objectif

Remédiation **R1** de l'[incident d'octobre 2026](../../../docs/incidents/2026-10-nucbox-link-drops.md) :
quand le lien Ethernet d'un nœud tombe, NetworkManager retire son adresse
IP ; l'API Kubernetes, sondée sur cette IP, redémarre alors en boucle, et
même une coupure de 3 s coûte plusieurs minutes d'indisponibilité.

Ce playbook demande à NetworkManager de **garder la connexion active, donc
l'IP, pendant une perte de lien** : réglage par interface `ignore-carrier`
(vérifié dans la documentation de NetworkManager 1.54.3, la version
installée : « permet à toute connexion active, statique ou dynamique, de
rester active quand le lien est perdu »).

Il ne supprime pas les coupures elles-mêmes (remédiation R3 : câble, port) :
il évite qu'une coupure courte se transforme en panne de l'API.

| Fichier | Rôle |
|---|---|
| `ansible/playbook.yml` | Dépose `/etc/NetworkManager/conf.d/90-homelab-node-link.conf`, recharge la configuration, vérifie qu'elle est lue |

## Dépendances

- Nœuds Ubuntu gérés par NetworkManager (cas du NucBox : `netplan`, rendu
  NetworkManager), groupe d'inventaire `k8s_nodes`.
- Aucune autre feature.

## Ressources approximatives

Aucune : un fichier de configuration.

## Inputs / Outputs

| Variable (par machine, inventaire local) | Rôle |
|---|---|
| `node_link_interface` | Interface qui porte l'IP du nœud (`enp3s0` sur le NucBox) |

Sortie : `NetworkManager --print-config` montre `ignore-carrier=yes` pour
cette interface.

## Installation (opérateur)

```bash
cd bootstrap/ansible
ansible-playbook ../../features/networking/node-link/ansible/playbook.yml --check --diff -K
ansible-playbook ../../features/networking/node-link/ansible/playbook.yml -K
```

**Changement à distance** : avant de modifier quoi que ce soit, le playbook
programme sur la machine un **retour arrière automatique dans 10 minutes**
(`systemd-run`), applique le réglage, vérifie qu'il peut encore joindre la
machine, et seulement alors annule le retour arrière. Si le réglage coupait
la machine du réseau, elle revient seule à l'état d'avant. Si le playbook
échoue en cours de route, le retour arrière s'exécute aussi : relancer le
playbook une fois la cause comprise.

Le playbook **recharge** la configuration (`nmcli general reload conf`) mais
ne **redémarre pas** NetworkManager : un redémarrage peut lui-même couper le
réseau. La documentation prévient que certains réglages ne s'appliquent
qu'au redémarrage du service ; d'où le test ci-dessous.

**Test (à faire une fois, moment calme)** : sur le NucBox, débrancher le
câble 10 secondes, puis :

```bash
ip -4 addr show enp3s0          # l'IP 192.168.1.253 doit être restée
journalctl -u NetworkManager -S "-5min" | grep enp3s0   # pas de « no lease »
kubectl -n kube-system get pod kube-apiserver-nucboxg3-plus   # RESTARTS inchangé
```

Si l'IP a disparu : le réglage n'est pas encore actif, il le sera au
prochain redémarrage planifié du NucBox (ou de NetworkManager, à un moment
choisi) ; refaire alors le test.

## Upgrade

Relire le passage `ignore-carrier` de `man NetworkManager.conf` à chaque
montée de version majeure de NetworkManager (réglage déjà déprécié une fois
sous sa forme globale `main.ignore-carrier`).

## Rollback

```bash
sudo rm /etc/NetworkManager/conf.d/90-homelab-node-link.conf
sudo nmcli general reload conf
```

## Troubleshooting

| Symptôme | Cause probable | Action |
|---|---|---|
| Le playbook échoue sur l'interface | `node_link_interface` absente ou mal orthographiée | `ip -o link` sur la machine |
| La vérification échoue (`ignore-carrier=yes` absent) | Fichier ignoré, autre fichier de `conf.d` qui le contredit | `NetworkManager --print-config` |
| L'IP disparaît encore au test | Réglage pas encore appliqué au périphérique | Voir Installation, après le test |
