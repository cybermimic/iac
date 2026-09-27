# Instructions pour l'agent — homelab-platform

Ce fichier est le contrat que tout agent (Claude Code ou autre) doit
respecter en travaillant sur ce repo. Il condense les règles du projet ;
en cas de doute, les ADR (`docs/adr/`) et `docs/architecture.md` font
foi sur le "pourquoi".

## Principe directeur

En cas de choix entre une solution abstraite/automatique et une solution
un peu plus longue mais évidente : choisir l'évidente. Le système doit
rester compréhensible par un humain qui découvre le repo pour la première
fois.

## Langue

Répondre en **français**. Messages de commit et titres de PR en **anglais**
(Conventional Commits : `feat(vault): …`, `docs: …`, `chore: …`).

## Lire en priorité

| Sujet | Doc |
|---|---|
| Vue d'ensemble / statut | [README.md](README.md) |
| Ce qui tourne, IP, chemin d'une requête, où est configuré quoi | [docs/platform-overview.md](docs/platform-overview.md) |
| Architecture cible | [docs/architecture.md](docs/architecture.md) |
| Faits opérationnels (accès, state, dette) | [docs/operations.md](docs/operations.md) |
| Décisions | [docs/adr/](docs/adr/) |
| Une feature précise | `features/<domaine>/<feature>/README.md` |

## Stack (versions réelles)

Ubuntu 26.04, Kubernetes 1.36.1 (kubeadm), containerd 2.2.2, Calico v3.28.0
(pods `10.244.0.0/16`),
Terraform 1.15.x, Vault 2.0.4 (chart `hashicorp/vault`), Traefik v3.7.13
(chart `traefik/traefik` 41.6.0), CoreDNS LAN 1.14.6 (chart `coredns/coredns`
1.47.1), cert-manager v1.21.2, MetalLB chart
0.14.9, local-path-provisioner v0.0.31.
Mettre à jour cette ligne à chaque montée de version.

## Ne jamais faire

- **Terraform** : pas de `local-exec`/`remote-exec`, pas de script shell
  caché dans un module, pas de credentials/kubeconfig en dur. Terraform ne
  gère que des ressources Kubernetes/Helm — jamais la configuration d'un
  hôte (voir [ADR-001](docs/adr/ADR-001-terraform-scope.md)).
- **Versions** : jamais `latest` pour un composant qui tourne réellement
  (charts Helm, images, paquets APT). Toujours une version explicite,
  épinglée (`apt-mark hold` côté Ansible, `version = "x.y.z"` côté
  Terraform).
- **Secrets** : jamais de mot de passe, token, clé privée, kubeconfig
  sensible, unseal key ou root token Vault dans Git, dans un fichier de ce
  repo, ou dans une réponse de chat. Voir
  [ADR-003](docs/adr/ADR-003-secret-management.md). Si une opération va
  générer un secret (ex. `vault operator init`), documenter la procédure
  mais **ne jamais l'exécuter soi-même** — c'est à l'humain de le faire
  dans son propre terminal.
- **Code applicatif business** : ne jamais copier le code d'une
  application dans ce repo — seulement le contrat de déploiement (chart
  Helm référencé, `Application` ArgoCD). Le code vit dans un repo séparé.
- **Kubectl manuel persistant** : `kubectl apply`/`edit` acceptables pour
  diagnostic/debug/bootstrap exceptionnel documenté, jamais comme méthode
  de changement durable une fois une feature gérée par Terraform/ArgoCD.

## Toujours faire

- **Petites étapes** : avant toute modification importante, inspecter
  l'existant (repo, cluster réel, WIP non commité éventuel sur les
  machines cibles), proposer un plan, implémenter une étape, valider,
  seulement ensuite continuer. Ne jamais tout reconstruire d'un coup si
  quelque chose de fonctionnel existe déjà.
- **Idempotence** : tout bootstrap/playbook/module doit être relançable
  sans casser l'état existant.
- **Validation avant apply** : `terraform fmt -check` + `terraform
  validate` + lecture du `plan` avant tout `apply` sur le cluster réel.
  Un `plan` qui montre une ressource déjà existante comme "à créer" est un
  signal d'alerte (state désynchronisé) — voir
  [ADR-005](docs/adr/ADR-005-terraform-state.md), ne pas appliquer à
  l'aveugle, réconcilier par `terraform import` d'abord.
- **Dépendances de features explicites** : si une feature dépend d'une
  autre (ex. `security/vault` dépend de `storage/local-path`), le
  documenter dans son README et le représenter dans le graphe de modules
  Terraform (`infrastructure/environments/<env>/main.tf`), jamais de
  dépendance implicite non documentée.
- **Documenter chaque feature** : objectif, dépendances, ressources
  approximatives (CPU/RAM/stockage — contrainte 16 Go RAM tant que le
  cluster est single-node), inputs, outputs, installation, upgrade,
  rollback, troubleshooting. Un README de feature incomplet est une
  feature incomplète.
- **Portabilité** : ne jamais supposer un username, hostname, chemin
  personnel (`/home/<user>/...`), interface réseau ou IP fixe non
  configurable. `KUBECONFIG`/`kubeconfig_path` toujours injecté
  explicitement, jamais un `~/.kube/config` implicite codé en dur dans le
  repo.
- **Avant tout commit/push** : faire tourner `./hack/test.sh`, vérifier
  qu'aucun fichier de `.gitignore` (secrets, state, kubeconfig) n'a été
  ajouté par erreur (`git status` après un `git add` large).

## Ne pas inventer

Un choix non acté (ex. contrôleur d'ingress, stack d'observabilité,
outil de registry) n'est **pas** tranché par l'agent : présenter 2-3
options avec leur empreinte RAM et laisser l'humain décider, puis
l'acter dans une ADR avant d'implémenter.

## Posture par défaut sur le cluster

- **Lecture libre** : `kubectl get/describe/logs`, `terraform plan`,
  `vault status` — sans demander.
- **Écriture sur demande explicite uniquement** : `terraform apply`,
  `kubectl apply/delete/edit`, `helm`, tout ce qui modifie le cluster ou
  le répertoire de state. Toujours montrer le `plan` et attendre un OK.
- **Jamais par l'agent** : opérations qui affichent un secret (`vault
  operator init`, `vault login`, lecture de secrets K8s/Vault). Donner la
  commande, l'humain l'exécute dans son propre terminal.
- **Vault après reboot** : pod `vault-0` en `0/1` + `Sealed: true` =
  unseal manuel à faire par l'humain. Ne jamais tenter de "réparer"
  (redéployer, relancer `init`), le signaler et attendre.

## Interaction

- Toujours : état constaté → plan court → une étape → validation →
  étape suivante. Pas de "tout d'un coup".
- Si une permission est refusée : ne pas contourner avec un autre outil ;
  s'arrêter, expliquer, et donner à l'humain la commande exacte à lancer.
- Suppression (fichiers non suivis, branches) : lister ce qui sera
  supprimé et pourquoi avant d'agir ; c'est à l'humain de valider.
- Proposer de mettre à jour le titre/la description d'une PR si le
  travail évolue — seulement après OK explicite (`gh pr edit`).

## Process Git

- **Phase de setup (jusqu'à ce que le POC soit en place)** : commits
  directement sur `main`, pas de branche ni de PR. Une fois le POC en
  place, cette exception disparaît et les règles ci-dessous s'appliquent.
- Hors phase de setup : 1 changement = 1 branche = 1 PR ; `git fetch
  origin` avant de brancher ; jamais de commit direct sur `main`. Nom de
  branche : `<type>/<sujet-court>` (ex. `feat/ingress`,
  `docs/vault-initialized`).
- Remote en SSH (`git@github.com:cybermimic/iac`), pas HTTPS.
- Toute feature livrée met à jour **dans le même changement** : son
  README, le tableau de statut du README racine et `docs/architecture.md`.

## Qualité du code

- Terraform : chaque `variable` a `description` + `type` ; une valeur par
  défaut seulement si elle est raisonnable pour tous ; `outputs.tf` et
  `versions.tf` par module ; pas de logique cachée (`count`/`for_each`
  obscurs, `templatefile` pour contourner un provider).
- Un module par feature, assemblé dans
  `infrastructure/environments/homelab/main.tf` — dépendances passées
  explicitement par outputs → inputs, pas de `depends_on` sans commentaire.
- Commentaires : expliquer le **pourquoi** (contrainte, bug évité), pas le
  quoi.

## Validation

`./hack/test.sh` : un `SKIP` n'est **pas** un `OK`. Signaler explicitement
quels checks n'ont pas tourné. `terraform fmt` vert ≠ `terraform validate`
vert ≠ `plan` propre.

## Naming

- Terraform : `snake_case`.
- Kubernetes : `kebab-case`.
- Ansible : `snake_case`.
- Shell : `kebab-case` ou `snake_case`, cohérent au sein d'un même fichier.

## Structure attendue

```
features/<domaine>/<feature>/
    terraform/   # si la feature a des ressources Terraform propres
    ansible/     # si elle nécessite une configuration hôte
    gitops/      # manifestes/Application ArgoCD (à partir de delivery/argocd)
    README.md    # obligatoire, voir ci-dessus
```

Ne créer que les couches réellement nécessaires — pas de dossier vide par
anticipation.

## Faits opérationnels à connaître (pas des règles, des faits)

Voir [docs/operations.md](docs/operations.md) pour le détail complet
(accès SSH, où vit le state Terraform, limitations connues). Résumé :

- Le cluster réel tourne sur `NucBoxG3-Plus` (192.168.1.253), single-node,
  kubeadm + containerd + Calico.
- Le state Terraform n'a **pas** de backend distant : le répertoire
  d'exécution faisant autorité est `/home/hoarauv/.homelab-platform-state/`
  sur le NucBox, pas ce repo. Ne jamais relancer un `apply` depuis un
  `terraform.tfstate` vide/différent sans vérifier d'abord par un `plan`
  qu'il n'y a pas de drift avec la réalité.
- Aucune machine du parc n'a de sudo sans mot de passe — un agent ne peut
  pas exécuter le playbook Ansible de `bootstrap/` de bout en bout sans
  qu'un humain tape le mot de passe (`-K`).
