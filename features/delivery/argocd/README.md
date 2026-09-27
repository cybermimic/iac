# delivery/argocd

## Objectif

ArgoCD, moteur GitOps de la plateforme ([ADR-002](../../../docs/adr/ADR-002-gitops-with-argocd.md)) :
à terme, source de vérité des workloads (features de plateforme et
applications business référencées depuis leurs propres repos).

**Cette première version installe ArgoCD seul, sans aucune
`Application`.** La structure GitOps (quel repo/chemin ArgoCD suit, « app
of apps » ou `ApplicationSet`, quelles features basculent de Terraform
vers ArgoCD) est une décision à prendre à part, puis à acter (ADR).

## Accès

**`https://argocd.homelab.lan`**, depuis tout le LAN, via l'ingress
Traefik avec un certificat de la CA interne (secret `argocd-server-tls`,
renouvelé par cert-manager). TLS terminé par Traefik
(`server.insecure = true` côté ArgoCD, sinon boucle de redirection).

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

- `networking/ingress` et `security/cert-manager` — publication HTTPS
  (inputs `ingress_class_name` et `cluster_issuer_name`, passés depuis
  leurs outputs dans `infrastructure/environments/homelab/main.tf`).
- `networking/lan-dns` — résolution de `argocd.homelab.lan` (wildcard).
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
| `hostname` | Nom publié | — (requis, `argocd.homelab.lan` au niveau env) |
| `ingress_class_name` | IngressClass | — (requis, output de `networking/ingress`) |
| `cluster_issuer_name` | ClusterIssuer du certificat | — (requis, output de `security/cert-manager`) |
| `tolerate_control_plane_taint` | Toleration control-plane pour tous les pods (single-node) | `true` |

## Outputs

`namespace`, `url`.

## Installation

Assemblée dans `infrastructure/environments/homelab` : `terraform plan`
(créations dans `module.argocd` uniquement) puis `apply`.

Vérification :

```bash
kubectl -n argocd get pods                          # tous Running
kubectl -n argocd get ingress,certificate           # certificat READY True
```

puis, depuis un poste du LAN où la CA est installée :
`https://argocd.homelab.lan` → écran de connexion, sans avertissement.

## Upgrade

Lire les release notes ArgoCD et du chart (les majeures du chart peuvent
changer la structure des values), monter `chart_version`, `terraform
plan` puis `apply`. Les CRDs suivent (gérées par le chart).

## Rollback

`terraform apply` avec l'ancienne `chart_version`. Les CRDs (et donc les
Applications) sont conservées (`crds.keep = true`).

## Troubleshooting

- Boucle de redirection / `ERR_TOO_MANY_REDIRECTS` → `server.insecure`
  n'est pas actif (le TLS doit être terminé par Traefik seul).
- Application en `ComparisonError` / repo inaccessible → vérifier
  l'accès sortant des pods (`kubectl -n argocd logs deploy/argocd-repo-server`).
- Mot de passe admin perdu : le réinitialiser en suivant la procédure
  officielle (`argocd admin` + mise à jour du secret `argocd-secret`), par
  l'humain.
