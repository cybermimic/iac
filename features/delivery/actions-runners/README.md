# delivery/actions-runners

## Objectif

Runners GitHub Actions **dans le cluster**, pour les dépôts **privés** de
l'organisation ([ADR-011](../../../docs/adr/ADR-011-ci-runners.md)) :
Actions Runner Controller (ARC), mode *runner scale set*, Docker-in-Docker.
Tous les workflows d'un dépôt autorisé y tournent (vérifications,
publication des images dans le registre du homelab).

**Jamais pour un dépôt public** (`cybermimic/iac` compris) : une PR venue
d'un fork exécuterait du code arbitraire sur le NucBox.

Livré par **ArgoCD** ([ADR-008](../../../docs/adr/ADR-008-gitops-layout.md)) :

| Fichier | Rôle |
|---|---|
| `gitops/apps/repositories/arc-oci.yaml` | Déclare à ArgoCD le dépôt OCI public des charts ARC (`ghcr.io`), sans identifiant |
| `gitops/apps/arc-controller.yaml` | Contrôleur ARC (`arc-systems`), chart `gha-runner-scale-set-controller` 0.15.0 |
| `gitops/apps/arc-runners-inner-riddle.yaml` | Scale set `homelab` de `cybermimic/inner-riddle` (`arc-runners`), chart `gha-runner-scale-set` 0.15.0 ; livre aussi les ressources partagées du namespace (ligne suivante) |
| `gitops/apps/arc-runners-fact-check.yaml` | Scale set `fact-check` de `cybermimic/fact-check`, même chart ; `minRunners: 0`, `maxRunners: 1` |
| `gitops/apps/arc-runners-fleet-manager.yaml` | Scale set `fleet-manager` de `cybermimic/fleet-manager`, même chart ; `minRunners: 0`, `maxRunners: 1` |
| `gitops/inner-riddle/` (ici) | Ressources **partagées par tout le namespace** `arc-runners`, malgré le nom du dossier : `ExternalSecret` de la GitHub App, `ConfigMap` de la CA interne, `NetworkPolicy` (`podSelector: {}`) |

## Fonctionnement

- Au repos : **un runner prêt** (`minRunners: 1`), le contrôleur et un
  pod *listener* (connexion longue à GitHub). Sans runner prêt, chaque job
  attendait 6-7 min le démarrage d'un pod neuf.
- Un job arrive → un pod runner neuf est créé (runner + `dockerd` en
  sidecar privilégié), il exécute le job puis disparaît.
  `maxRunners: 2` : deux jobs en parallèle au plus (contrainte mémoire).
- Images épinglées : `ghcr.io/actions/actions-runner:2.338.0`,
  `docker:29.9.0-dind` (le modèle du chart utilise `:latest`, d'où le
  modèle de pod écrit en entier dans l'Application).
- `docker compose` ajouté : l'image `actions-runner` fournit la CLI
  docker et buildx mais **pas compose** (constaté au premier run : `docker:
  unknown command: docker compose`). Un conteneur d'init copie le plugin
  de l'image `docker:29.9.0-cli` (même version que dockerd) dans
  `/usr/local/libexec/docker/cli-plugins` du runner.
- `dockerd` fait confiance à la CA interne **pour le seul registre**
  `192.168.1.242` (`/etc/docker/certs.d/192.168.1.242/ca.crt`).
- `NetworkPolicy` : sorties limitées au DNS du cluster, au registre et à
  Internet ; LAN, pods et services exclus ; aucune entrée.

## Dépendances

- `security/external-secrets` + Vault : `secret/actions-runners/github-app`
  (`github_app_id`, `github_app_installation_id`, `github_app_private_key`),
  rangé par l'opérateur (commandes D du [plan](../../../docs/plans/inner-riddle.md)).
- `delivery/registry` : cible des publications.
- Une **GitHub App** de l'organisation (`cybermimic-homelab-runners`),
  installée sur les seuls dépôts autorisés (création : étape 6 du plan).
  Accès limité le 2026-10-28 à `inner-riddle`, `fact-check` et
  `fleet-manager` (*Only select repositories*) : elle était installée sur
  tous les dépôts, `iac` public compris. Vérifier :
  `gh api orgs/cybermimic/installations --jq '.installations[].repository_selection'`
  → `selected`.

## Ressources approximatives

Contrôleur + un listener par scale set : ~50-100 Mi chacun. Runner prêt au
repos (runner + dockerd) : ~200-300 Mi pour inner-riddle ; aucun pour
fact-check ni fleet-manager (`minRunners: 0`). Pendant un job : ~1-3 Gi par runner selon le build,
deux runners au plus. Stockage : `emptyDir` (effacé à la fin du job).

## Ajouter un dépôt (privé) autorisé

1. Installer la GitHub App sur ce dépôt (GitHub → organisation → Settings →
   GitHub Apps → l'App des runners → Configure → *Repository access*).
2. Copier `gitops/apps/arc-runners-fact-check.yaml` (nouveaux `name`,
   `releaseName`, `githubConfigUrl` **et `runnerScaleSetName`**). Le
   `runnerScaleSetName` nomme l'`AutoscalingRunnerSet` et ses
   `Role`/`ServiceAccount` : il doit être **unique dans le namespace**. Le
   2026-10-28, un second scale set nommé `homelab` a pris le contrôle de
   celui d'inner-riddle et l'a pointé vers un autre dépôt. **Ne pas** copier le dossier
   `gitops/inner-riddle/` : ses ressources sont communes au namespace, deux
   Applications ArgoCD se disputeraient les mêmes objets.
3. Dans le dépôt : `runs-on` = le `runnerScaleSetName` (variable
   `CI_RUNNER` / `RELEASE_RUNNER` selon ses workflows).
4. Mettre à jour les ressources approximatives ci-dessus.

## Vérification

```bash
kubectl -n argocd get application arc-controller arc-runners-inner-riddle arc-runners-fact-check arc-runners-fleet-manager   # Synced, Healthy
kubectl -n arc-runners get externalsecret arc-github-app                    # SecretSynced
kubectl -n arc-systems get pods                                             # contrôleur + listener Running
```

Dans GitHub : dépôt → Settings → Actions → Runners → scale set `homelab`
en ligne. Puis relancer un workflow : un pod apparaît dans `arc-runners`.

## Upgrade

Lire les release notes d'ARC (contrôleur et scale sets doivent être à la
**même version**), monter `targetRevision` dans les deux Applications en
même temps, et les images runner / dind dans le modèle.

## Rollback

Revenir aux révisions précédentes des Applications (git revert).

## Troubleshooting

- Listener absent / `ExternalSecret` en erreur → GitHub App pas encore dans
  Vault, ou politique `external-secrets` sans `secret/data/actions-runners/*`.
- Listener en erreur `401`/`404` → App ID, Installation ID ou clé privée
  incorrects, ou App non installée sur le dépôt.
- `docker: unknown command: docker compose` → le volume
  `docker-cli-plugins` n'est pas monté dans le runner (modèle de pod).
- Job bloqué « Waiting for a runner » → `runs-on` ne correspond pas au
  `runnerScaleSetName` du dépôt (variables `CI_RUNNER` / `RELEASE_RUNNER`).
- Une Application `arc-runners-*` reste OutOfSync et l'`AutoscalingRunnerSet`
  pointe vers un autre dépôt (`spec.githubConfigUrl`) → deux scale sets
  portent le même `runnerScaleSetName`.
- `x509: certificate signed by unknown authority` au `docker push` → la
  `ConfigMap` `homelab-ca` n'est pas montée, ou l'adresse du registre
  diffère de `192.168.1.242`.
- Le job n'atteint pas un service du LAN → normal : la `NetworkPolicy`
  ne l'autorise pas (seuls le registre et Internet le sont).
