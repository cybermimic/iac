# compute/fleet-manager

## Objectif

Côté plateforme de **fleet-manager** (dépôt privé
[`cybermimic/fleet-manager`](https://github.com/cybermimic/fleet-manager)),
le service qui allume à la demande les machines éteintes par défaut et
déplace les données entre niveaux de stockage
([ADR-013](../../../docs/adr/ADR-013-storage-tiers-and-power.md)).

Ce dossier ne contient que ce qui touche les **hôtes** :

| Fichier | Rôle |
|---|---|
| `ansible/playbook.yml` | Prépare une machine gérée : Wake-on-LAN actif à chaque démarrage, compte `fleet-manager` limité à l'extinction |

Le déploiement du service lui-même (`Application` ArgoCD, secrets) viendra
quand il aura une persistance et une API (ADR-001 de son dépôt).

## L'exception d'extinction (ADR-013, section 6)

Aucune machine du parc n'a de sudo sans mot de passe, **sauf** cette
exception, limitée à une commande et à un compte :

- compte système `fleet-manager`, sans mot de passe utilisable ;
- sa clé SSH porte `restrict,command="sudo /usr/bin/systemctl poweroff"` :
  quoi que demande le client, seule l'extinction s'exécute ; ni terminal,
  ni redirection ;
- `/etc/sudoers.d/fleet-manager` : une ligne, `NOPASSWD` pour
  `/usr/bin/systemctl poweroff` uniquement (vérifiée par `visudo`) ;
- le playbook **refuse** toute machine du groupe `k8s_control_plane`
  (le NucBox), et toute machine qui porte le manifeste
  `/etc/kubernetes/manifests/kube-apiserver.yaml`, même si l'inventaire est
  incomplet.

Vérifié le 2026-10-27 dans un conteneur Ubuntu 26.04 (`sudo-rs` 0.2.13) :
ligne sudoers acceptée par `visudo`, `sudo -l` limité à l'extinction, toute
autre commande refusée, et une connexion SSH demandant `id` exécute la
commande forcée à la place. Le refus des redirections repose sur
`restrict` (OpenSSH), non testé en conteneur.

## Wake-on-LAN

Le BIOS l'active (voir la préparation dans
[docs/plans/fleet-manager.md](../../../docs/plans/fleet-manager.md)), mais
certains pilotes réseau le désactivent au démarrage du système. L'unité
`fleet-manager-wol.service` le réactive à chaque boot (`ethtool -s <iface>
wol g`). La configuration réseau (netplan) n'est **pas** modifiée : une
erreur couperait l'accès à la machine.

## Dépendances

- Une machine Ubuntu 26.04 joignable en SSH, dans le groupe d'inventaire
  `fleet_managed` (exemple dans `bootstrap/ansible/inventory/hosts.yml.example`).
- Collection `ansible.posix` (`bootstrap/ansible/requirements.yml`).
- La clé privée correspondante, rangée dans Vault par l'opérateur
  (`secret/fleet-manager/ssh`), lue par le service.

## Ressources approximatives

Négligeables : une unité oneshot, un compte, le paquet `ethtool`.

## Inputs / outputs

| Variable (par machine, inventaire local jamais commité) | Rôle |
|---|---|
| `fleet_manager_wol_interface` | Interface câblée (ex. `enp0s31f6`) |
| `fleet_manager_ssh_public_key` | Clé publique du compte `fleet-manager` |

Sortie : une machine que fleet-manager peut réveiller (paquet magique) et
éteindre (`ssh fleet-manager@<machine>`, sans argument utile).

## Installation (opérateur)

```bash
# Clé du compte : la privée va dans Vault, jamais affichée
ssh-keygen -t ed25519 -N "" -C fleet-manager -f ~/fleet-manager-key
kubectl -n vault exec -i vault-0 -- vault kv put secret/fleet-manager/ssh ssh_private_key=- < ~/fleet-manager-key
cat ~/fleet-manager-key.pub   # → fleet_manager_ssh_public_key dans l'inventaire local
shred -u ~/fleet-manager-key && rm ~/fleet-manager-key.pub

cd bootstrap/ansible
ansible-galaxy collection install -r requirements.yml
ansible-playbook ../../features/compute/fleet-manager/ansible/playbook.yml --limit fleet-cold-01 -K
```

Vérification sur la machine :

```bash
systemctl status fleet-manager-wol.service     # active (exited)
sudo ethtool <iface> | grep Wake-on            # Wake-on: g
sudo -l -U fleet-manager                       # (root) NOPASSWD: /usr/bin/systemctl poweroff
```

Puis, depuis le NucBox : `fleet-manager wake <mac>` après extinction.

## Upgrade

Relancer le playbook : il est relançable et ne réécrit que ce qui a changé.

## Rollback

Retirer l'exception sur une machine :

```bash
sudo rm /etc/sudoers.d/fleet-manager
sudo userdel -r fleet-manager
sudo systemctl disable --now fleet-manager-wol.service
sudo rm /etc/systemd/system/fleet-manager-wol.service && sudo systemctl daemon-reload
```

## Troubleshooting

| Symptôme | Cause probable | Action |
|---|---|---|
| Le paquet magique ne réveille pas la machine | BIOS (Wake-on-LAN, « ErP » / « Deep Sleep »), ou `Wake-on: d` | Vérifier le BIOS, `sudo ethtool <iface>` |
| `ssh fleet-manager@…` demande un mot de passe sudo | Ligne sudoers absente ou chemin de `systemctl` différent | `sudo -l -U fleet-manager` ; relancer le playbook |
| Le playbook échoue sur l'assertion | Machine du groupe `k8s_control_plane`, ou variable manquante | Ne jamais gérer le plan de contrôle ; compléter l'inventaire |
