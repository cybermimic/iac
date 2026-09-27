# Operations — reprendre le projet depuis une autre machine

Ce document rassemble les faits pratiques nécessaires pour continuer ce
projet ailleurs que sur la machine où il a été commencé. Il complète
`CLAUDE.md` (règles à respecter) et les README de chaque feature (détail
technique par composant).

## Accéder au cluster

- Machine : `NucBoxG3-Plus`, IP LAN `192.168.1.253`, utilisateur `hoarauv`.
- Le kubeconfig par défaut du user `hoarauv` sur cette machine
  (`~/.kube/config`) fonctionne directement en local sur le NucBox.
- Pour piloter le cluster depuis une autre machine : copier ce
  kubeconfig et le passer explicitement via `KUBECONFIG=...` (ne jamais le
  committer, voir [ADR-003](adr/ADR-003-secret-management.md)).
- Accès SSH : `ssh hoarauv@192.168.1.253`. **Aucune machine du parc n'a de
  sudo sans mot de passe** — toute opération nécessitant root (paquets,
  systemd, fichiers sous `/etc`) doit être lancée par un humain qui tape
  le mot de passe interactivement (`sudo -S`, `ansible-playbook -K`).

## Où vit le state Terraform (important)

Il n'y a **pas de backend distant** configuré (pas de S3/GCS-compatible,
pas de Terraform Cloud) — voir
[ADR-005](adr/ADR-005-terraform-state.md). Le `terraform.tfstate` réel vit
dans un répertoire d'exécution sur le NucBox, séparé du clone Git :

```
/home/hoarauv/.homelab-platform-state/
```

**Procédure pour appliquer un changement** :

1. Modifier le code dans le repo Git (ce clone, ou celui de la machine
   courante).
2. Synchroniser `infrastructure/` et `features/` vers ce répertoire sur
   le NucBox (`rsync`, en excluant `.terraform/`, `.terraform.lock.hcl`
   et `terraform.tfstate*` pour ne pas écraser l'existant).
3. Depuis ce répertoire sur le NucBox : `terraform plan` d'abord,
   toujours. Si le plan montre une ressource qui existe déjà côté cluster
   comme "à créer", **ne pas appliquer** — le state a divergé, réconcilier
   par `terraform import` avant toute chose.
4. `terraform apply` seulement après un plan relu et compris.

Cette situation (pas de backend partagé) est un vrai gap à combler — voir
la piste retenue dans [ADR-005](adr/ADR-005-terraform-state.md). Tant que
ce n'est pas fait, **il ne doit exister qu'un seul répertoire d'exécution
faisant autorité** ; ne jamais lancer `terraform apply` depuis un state
local fraîchement initialisé (`terraform init` dans un nouveau dossier)
sans avoir d'abord vérifié l'absence de drift.

## Ancien travail non versionné (historique, pour mémoire)

Avant la remise à plat de ce repo, un répertoire `/home/hoarauv/iac`
existait sur le NucBox avec du Terraform/Ansible expérimental jamais
committé (branches locales `chore/terraform`, `chore/kubeadm-install`).
Rien n'en a été migré : le script de `chore/kubeadm-install` est remplacé
par le rôle Ansible `bootstrap/ansible/roles/kubernetes_node`, et le reste
(module Vault cassé avec `local-exec` et erreur de syntaxe, scripts
d'installation incomplets) a été volontairement abandonné — ne pas aller
le rechercher comme référence.

## Limitations connues / dette technique

- **Pas de backend Terraform distant** (voir ci-dessus / ADR-005).
- **Bootstrap Ansible jamais exécuté pour de vrai** contre le NucBox
  (écrit et validé syntaxiquement seulement — pas de sudo sans mot de
  passe disponible pendant la session qui l'a écrit). Le cluster actuel a
  été bootstrapé manuellement avant que ce playbook existe.
- **Réutilisation d'une clé SSH GitHub pour l'accès au NucBox** — la même
  clé (`~/.ssh/github`) sert à la fois pour GitHub et pour l'accès SSH au
  NucBox. À séparer proprement (clé dédiée par usage) quand l'occasion se
  présente.
- **TLS de Vault terminé à l'ingress** — `https://vault.homelab.lan` est
  en HTTPS (CA interne), mais entre Traefik et le pod Vault le trafic
  reste en HTTP dans le cluster (single-node). TLS de bout en bout
  (listener Vault en TLS) possible plus tard si le cluster devient
  multi-nœuds.
- **Unseal Vault manuel** — Vault est initialisé, mais se re-scelle à
  chaque redémarrage du pod ou du NucBox : l'unseal reste une opération
  humaine, jamais automatisée (voir `features/security/vault/README.md`,
  section 3). Après un reboot, les services qui dépendent de Vault ne
  fonctionnent pas tant que cet unseal n'est pas fait.

## DNS du LAN — dépendance au NucBox

Depuis le 2026-09-27, la Freebox distribue le DNS du homelab
(`networking/lan-dns`, pod sur le NucBox) à **tout le LAN**. NucBox
arrêté ou pod en panne = plus aucun appareil ne résout de nom. Rollback
d'urgence (sur la Freebox, depuis n'importe quel appareil connecté en
tapant `http://192.168.1.254`) : README de `features/networking/lan-dns`,
section Rollback. Le NucBox lui-même utilise directement la Freebox comme
DNS (sinon il dépendrait de son propre pod au démarrage) — réglage
NetworkManager manuel, **pas encore porté dans Ansible**.

## Calico

- Réseau des pods : pool Calico `10.244.0.0/16` (migré depuis
  `192.168.0.0/16`, qui englobait le LAN et coupait les pods du LAN — voir
  [le runbook](runbooks/calico-pod-cidr-migration.md)).
- **Incohérence connue, volontaire** : `--cluster-cidr` du
  controller-manager, `podSubnet` de `kubeadm-config` et `clusterCIDR` de
  kube-proxy valent encore `192.168.0.0/16`, et le nœud porte le podCIDR
  `192.168.0.0/24`. Inutilisés (le CNI utilise `calico-ipam`), et ne pas
  les modifier sans ré-intégrer le nœud (raison dans le runbook).
- `calicoctl` n'est **pas** installé sur le NucBox. Pour toute opération
  Calico, le récupérer dans **la même version que Calico** (v3.28.0
  aujourd'hui, `kubectl -n kube-system get ds calico-node -o
  jsonpath='{..image}'`) avec vérification du checksum : voir la section
  « Prérequis » du runbook.

## Checklist avant de reprendre le travail sur une nouvelle machine

1. Lire `CLAUDE.md`.
2. Lire ce document.
3. `git log --oneline --all` pour vérifier qu'aucune branche locale
   utile n'a été laissée ailleurs (comme ça a été le cas sur le NucBox).
4. Vérifier l'accès SSH au NucBox et l'existence du répertoire d'état
   Terraform avant tout `plan`/`apply`.
5. `./hack/test.sh` pour confirmer que les outils disponibles localement
   ne remontent pas d'erreur sur le repo tel quel.
