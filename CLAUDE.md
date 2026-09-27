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
