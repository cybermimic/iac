# storage/backups

## Objectif

Mettre en œuvre l'[ADR-016](../../../docs/adr/ADR-016-backups.md) :
sauvegardes **chiffrées**, **hors du disque qu'elles protègent**.

Première étape, celle de ce dossier : chaque jour à 04:15, sur le nœud de
plan de contrôle,

- un **instantané etcd** (tous les objets Kubernetes, Secrets compris : etcd
  n'est pas chiffré au repos) ;
- l'**état Terraform** (`backup_terraform_state_dir`, sans le dossier
  `.terraform` des fournisseurs) ;

chiffrés avec `age` pour la **clé publique** de l'opérateur, puis écrits sur
un **disque USB** monté (copie 2 de la règle 3-2-1). Le NucBox peut écrire
ces sauvegardes, jamais les relire : la clé privée est hors ligne.

Étapes suivantes de l'ADR (dumps applicatifs chiffrés vers Garage, Vault,
fact-check, copie hors site) : à venir, chacune dans sa feature ou son
application.

| Fichier | Rôle |
|---|---|
| `ansible/playbook.yml` | Installe `age` (paquet épinglé), `etcdctl` (même version qu'etcd, empreinte vérifiée), le script, le service et le timer systemd |
| `ansible/templates/homelab-backup.sh.j2` | Le script : refus si le disque n'est pas monté, instantané, chiffrement, écriture atomique, rétention |
| `age-recipients.txt` | Clé **publique** `age` de l'opérateur (à ajouter, voir Installation) |

## Dépendances

- Le nœud de plan de contrôle (etcd local, certificats `/etc/kubernetes/pki/etcd`),
  groupe d'inventaire `k8s_control_plane`.
- Un disque USB **monté en permanence** (entrée `/etc/fstab` avec `nofail`,
  pour ne pas bloquer le démarrage s'il est absent).
- La clé privée `age` de l'opérateur, hors ligne : sans elle, les sauvegardes
  sont illisibles ([registre des secrets](../../../docs/secrets.md)).

## Ressources approximatives

Quelques secondes par jour. Disque USB : ~45 Mo par jour aujourd'hui (etcd
~43 Mo, état Terraform sans fournisseurs : quelques Mo) ; avec la
rétention (7 + 4 + 6 sauvegardes), moins de 1 Go.

## Inputs / Outputs

| Variable (inventaire local, jamais commité) | Rôle |
|---|---|
| `backup_destination` | Point de montage du disque USB, ex. `/mnt/backup` |
| `backup_terraform_state_dir` | Répertoire d'état Terraform, ex. `/home/<opérateur>/.homelab-platform-state` |

Sorties sur le disque : `etcd/AAAA-MM-JJ.db.age`,
`terraform-state/AAAA-MM-JJ.tar.gz.age`, `last-success` (horodatage UTC du
dernier succès).

## Installation (opérateur)

1. Créer la paire de clés `age`, sur le poste de l'opérateur (pas sur le
   NucBox). La clé privée ne quitte jamais ce poste ni son gestionnaire de
   mots de passe ; c'est aussi la clé de la copie de la CA (ADR-014, P3) :

   ```bash
   age-keygen -o ~/homelab-backup.key        # privée : gestionnaire de mots de passe + copie papier
   age-keygen -y ~/homelab-backup.key        # publique : ligne « age1… »
   ```

2. Mettre la ligne publique dans `features/storage/backups/age-recipients.txt`
   (PR : ce n'est pas un secret).
3. Brancher le disque USB, le formater, le monter en permanence
   (`/etc/fstab`, option `nofail`).
4. Inventaire local : `backup_destination`, `backup_terraform_state_dir`,
   groupe `k8s_control_plane`.
5. `ansible-playbook features/storage/backups/ansible/playbook.yml -K`.

Vérification :

```bash
systemctl list-timers homelab-backup.timer
sudo systemctl start homelab-backup.service && journalctl -u homelab-backup.service -n 5
ls <disque>/etcd <disque>/terraform-state && cat <disque>/last-success
```

**Tester une restauration** (sur le poste de l'opérateur, jamais sur le
NucBox avec la clé privée) :

```bash
age -d -i ~/homelab-backup.key etcd/AAAA-MM-JJ.db.age > etcd.db
etcdutl snapshot status etcd.db        # intégrité de l'instantané
```

## Comportement vérifié

Le 2026-10-28, dans un conteneur Ubuntu 26.04 avec `age` 1.2.1 et un
`etcdctl` factice : refus et aucune écriture si le disque n'est pas monté ;
en-tête `age` présent et déchiffrement identique à l'original ; archive
Terraform sans `.terraform` ; rétention gardant aujourd'hui, J-3, le dernier
dimanche et le dernier premier du mois, supprimant J-8, J-9, J-30, J-40 et
J-200. Le playbook n'a **jamais été exécuté** sur le NucBox.

## Upgrade

`etcdctl` suit la version d'etcd : à chaque montée de version de
Kubernetes, mettre à jour `backup_etcd_version` et `backup_etcd_sha256`
(fichier `SHA256SUMS` de la release etcd), puis relancer le playbook.

## Rollback

```bash
sudo systemctl disable --now homelab-backup.timer
sudo rm /etc/systemd/system/homelab-backup.{service,timer} /usr/local/sbin/homelab-backup
sudo systemctl daemon-reload
```

Les sauvegardes déjà écrites restent sur le disque.

## Troubleshooting

| Symptôme | Cause probable | Action |
|---|---|---|
| `ÉCHEC : … n'est pas un point de montage` | Disque USB débranché ou non monté | Le rebrancher, `sudo mount -a`, relancer le service |
| Playbook arrêté sur la clé publique | `age-recipients.txt` absent ou sans ligne `age1…` | Installation, étapes 1-2 |
| `etcdctl` : `certificate` / `connection refused` | Certificats kubeadm renouvelés ailleurs, ou etcd arrêté | `kubectl -n kube-system get pod etcd-<nœud>` ; chemins `/etc/kubernetes/pki/etcd` |
| `last-success` ancien | Timer arrêté, ou échecs répétés | `systemctl status homelab-backup.timer`, `journalctl -u homelab-backup.service` |
