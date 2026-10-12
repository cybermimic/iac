# delivery/argocd

## Objectif

ArgoCD, moteur GitOps de la plateforme ([ADR-002](../../../docs/adr/ADR-002-gitops-with-argocd.md)) :
à terme, source de vérité des workloads (features de plateforme et
applications business référencées depuis leurs propres repos).

En plus d'ArgoCD lui-même, ce module crée l'**Application racine**
(app-of-apps, [ADR-008](../../../docs/adr/ADR-008-gitops-layout.md),
statut « Acceptée ») qui suit `gitops/apps/` de ce repo. Toute nouvelle
Application (feature ou app business) s'ajoute par un fichier dans ce
dossier, sans nouveau `terraform apply`.

## Accès

**`https://192.168.1.244`**, depuis tout le LAN
([ADR-009](../../../docs/adr/ADR-009-public-exposure.md) : une IP par
service interne, jamais redirigée par la Freebox). `Service`
`LoadBalancer` (MetalLB) ; TLS terminé par **argocd-server lui-même** avec
un certificat de la CA interne (Certificate `argocd-server` → secret
`argocd-server-tls`, nom imposé par ArgoCD, renouvelé par cert-manager).
Le certificat ne contient que l'IP (la CA ne peut signer que des noms DNS
sous `homelab.lan`). `http://` redirige vers `https://`.

Compte : `admin` (local ; Dex/SSO désactivé). Mot de passe initial généré
par ArgoCD dans le secret `argocd-initial-admin-secret` — **à lire par
l'humain uniquement, dans son terminal** (ADR-003) :

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

Puis, une fois connecté : changer le mot de passe (User Info → Update
Password), le ranger dans le gestionnaire de mots de passe, et supprimer
le secret initial :
`kubectl -n argocd delete secret argocd-initial-admin-secret`.

## Dépendances

- `networking/metallb` — IP `load_balancer_ip` (`depends_on` commenté
  dans `infrastructure/environments/homelab/main.tf`).
- `security/cert-manager` — certificat d'argocd-server (input
  `cluster_issuer_name`, passé depuis son output).
- Accès Internet sortant des pods (repo-server clone les repos Git) :
  suppose le réseau des pods hors LAN (voir le runbook Calico).

## Ressources approximatives

Pods : application-controller, repo-server, server, redis,
applicationset-controller. ~300-500 Mi RAM au total à vide, davantage
avec le nombre d'Applications suivies. Pas de stockage persistant (redis
est un cache).

## Inputs

| Variable | Description | Défaut |
|---|---|---|
| `namespace` | Namespace d'installation | `argocd` |
| `chart_version` | Version du chart `argo/argo-cd` | `10.9.2` (ArgoCD v3.5.3) |
| `load_balancer_ip` | IP LAN d'ArgoCD (plage MetalLB) | — (requis, `192.168.1.244` au niveau env) |
| `cluster_issuer_name` | ClusterIssuer du certificat | — (requis, output de `security/cert-manager`) |
| `tolerate_control_plane_taint` | Toleration control-plane pour tous les pods (single-node) | `true` |
| `root_app_repo_url` | Repo suivi par l'Application racine | `https://github.com/cybermimic/iac.git` |
| `root_app_repo_revision` | Branche/tag suivi | `main` |
| `root_app_path` | Chemin des manifestes Application | `gitops/apps` |

## Outputs

`namespace`, `url`.

## Installation

Assemblée dans `infrastructure/environments/homelab` : `terraform plan`
(créations dans `module.argocd` uniquement) puis `apply`.

Vérification :

```bash
kubectl -n argocd get pods                          # tous Running
kubectl -n argocd get svc argocd-server,certificate # EXTERNAL-IP 192.168.1.244, certificat READY True
kubectl -n argocd get application root              # Synced, Healthy
```

puis, depuis un poste du LAN où la CA est installée :
`https://192.168.1.244` → écran de connexion, sans avertissement.

## Upgrade

Lire les release notes ArgoCD et du chart (les majeures du chart peuvent
changer la structure des values), monter `chart_version`, `terraform
plan` puis `apply`. Les CRDs suivent (gérées par le chart).

## Rollback

`terraform apply` avec l'ancienne `chart_version`. Les CRDs (et donc les
Applications) sont conservées (`crds.keep = true`).

## Troubleshooting

- Le navigateur reçoit un certificat qui ne correspond pas au secret
  `argocd-server-tls` (ex. ancien certificat après un changement) →
  argocd-server ne l'a pas rechargé : `kubectl -n argocd rollout restart
  deploy/argocd-server` (constaté lors de la migration du 2026-10-12, le
  certificat ayant été émis juste après le démarrage du pod).
- Application en `ComparisonError` / repo inaccessible → vérifier
  l'accès sortant des pods (`kubectl -n argocd logs deploy/argocd-repo-server`).
- Mot de passe admin perdu : le réinitialiser en suivant la procédure
  officielle (`argocd admin` + mise à jour du secret `argocd-secret`), par
  l'humain.
