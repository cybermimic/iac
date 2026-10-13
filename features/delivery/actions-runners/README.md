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
| `gitops/apps/arc-runners-inner-riddle.yaml` | Scale set `homelab` de `cybermimic/inner-riddle` (`arc-runners`), chart `gha-runner-scale-set` 0.15.0 |
| `gitops/inner-riddle/` (ici) | `ExternalSecret` de la GitHub App, `ConfigMap` de la CA interne, `NetworkPolicy` |

## Fonctionnement

- Au repos : **aucun runner** (`minRunners: 0`), seulement le contrôleur
  et un pod *listener* (connexion longue à GitHub).
- Un job arrive → un pod runner neuf est créé (runner + `dockerd` en
  sidecar privilégié), il exécute le job puis disparaît.
  `maxRunners: 1` : les jobs passent un par un (contrainte mémoire).
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
- Une **GitHub App** de l'organisation, installée sur les seuls dépôts
  autorisés (création : étape 6 du plan).

## Ressources approximatives

Contrôleur + listener : ~50-100 Mi. Pendant un job : 1 runner + dockerd,
~1-3 Gi selon le build. Stockage : `emptyDir` (effacé à la fin du job).

## Ajouter un dépôt (privé) autorisé

1. Installer la GitHub App sur ce dépôt.
2. Copier `gitops/apps/arc-runners-inner-riddle.yaml` (nouveau
   `releaseName`, `githubConfigUrl`, `runnerScaleSetName`) et le dossier
   `gitops/inner-riddle/` ici.
3. Dans le dépôt : variables `CI_RUNNER` / `RELEASE_RUNNER` (selon ses
   workflows) = le `runnerScaleSetName`.

## Vérification

```bash
kubectl -n argocd get application arc-controller arc-runners-inner-riddle   # Synced, Healthy
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
- Job bloqué « Waiting for a runner » → `runs-on` ne correspond pas à
  `homelab` (variables `CI_RUNNER` / `RELEASE_RUNNER` du dépôt).
- `x509: certificate signed by unknown authority` au `docker push` → la
  `ConfigMap` `homelab-ca` n'est pas montée, ou l'adresse du registre
  diffère de `192.168.1.242`.
- Le job n'atteint pas un service du LAN → normal : la `NetworkPolicy`
  ne l'autorise pas (seuls le registre et Internet le sont).
