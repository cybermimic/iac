# security/external-secrets

## Objectif

Pont entre Vault et les Secrets Kubernetes (ADR-003) : External Secrets
Operator (ESO) lit des chemins Vault et matérialise des `Secret`
Kubernetes à partir d'`ExternalSecret`, sans jamais dupliquer de secret à
la main.

## Gérée par ArgoCD, pas par Terraform

Première feature livrée après [ADR-008](../../../docs/adr/ADR-008-gitops-layout.md) :
`gitops/apps/external-secrets.yaml` (app-of-apps), pas de `terraform
apply`. Deux sources dans la même `Application` : le chart officiel
(opérateur) et ce dossier `gitops/` (le `ClusterSecretStore`, propre à ce
homelab).

## Dépendances

- `delivery/argocd` — doit être installé et synchroniser `gitops/apps/`.
- `security/vault` — doit être **initialisé et unsealed**, avec le moteur
  KV v2 et la méthode d'auth Kubernetes activés par l'opérateur (jamais
  par ArgoCD ni par un agent, voir [ADR-003](../../../docs/adr/ADR-003-secret-management.md)).

## Ce que ce dépôt fait — et ne fait PAS

Ce repo déploie l'opérateur et le `ClusterSecretStore`. Il ne crée
**jamais** :

- les secrets eux-mêmes dans Vault ;
- la méthode d'auth Kubernetes ni le rôle Vault associé (`vault auth
  enable kubernetes`, `vault write auth/kubernetes/role/...`) ;
- les policies Vault.

Ces opérations restent manuelles, exécutées par l'opérateur dans son
propre terminal — voir "Configuration Vault requise" ci-dessous et
[docs/plans/inner-riddle.md](../../../docs/plans/inner-riddle.md), étape 2.

## Ressources approximatives

~100-200 Mi RAM pour le contrôleur, le webhook et `cert-controller`
(3 pods). Négligeable en CPU au repos.

## Configuration Vault requise (opérateur, pas l'agent)

Tant que ceci n'est pas fait, le `ClusterSecretStore` `vault` reste en
erreur (`kubectl describe clustersecretstore vault`) — normal, pas un bug :

```bash
vault secrets enable -path=secret kv-v2
vault auth enable kubernetes
vault write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc

# Une policy par application consommatrice, par exemple inner-riddle :
vault policy write inner-riddle - <<'HCL'
path "secret/data/inner-riddle/*" { capabilities = ["read"] }
HCL

vault write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=inner-riddle \
  ttl=1h
```

Le rôle `external-secrets` ci-dessus est volontairement générique
(un seul rôle pour commencer) ; à affiner en un rôle par application
(policies distinctes) si plusieurs applications consomment des secrets
différents — décision à prendre quand le deuxième cas se présente, pas
avant (voir `CLAUDE.md`, "Ne pas inventer").

## Inputs / Outputs

Pas de variables Terraform — configuration dans
`gitops/apps/external-secrets.yaml` (version du chart, tolerations) et
`gitops/clustersecretstore.yaml` (adresse Vault, rôle, service account).

## Installation

Rien à lancer : une fois `gitops/apps/external-secrets.yaml` présent sur
`main` et l'Application racine ArgoCD synchronisée, ArgoCD déploie cette
feature automatiquement (`syncPolicy.automated`). Vérifier :

```bash
kubectl -n argocd get application external-secrets
kubectl -n external-secrets get pods
kubectl get clustersecretstore vault
```

## Upgrade

Changer `targetRevision` dans `gitops/apps/external-secrets.yaml` (PR),
ArgoCD synchronise automatiquement (`selfHeal`).

## Rollback

Revenir à l'ancien `targetRevision` (PR). Retirer complètement la
feature : d'abord configurer la Vault côté opérateur si ça doit rester,
sinon supprimer `gitops/apps/external-secrets.yaml` — **pas de `prune`**
(ADR-008), donc supprimer aussi manuellement l'`Application` et ses
ressources : `kubectl -n argocd delete application external-secrets
--cascade=foreground`.

## Troubleshooting

- `ClusterSecretStore` en `InvalidProviderConfig` (`unable to create
  client`, parfois `connection refused`) → Vault scellé
  (`kubectl -n vault exec vault-0 -- vault status`) : unseal par
  l'opérateur, voir `features/security/vault/README.md`.
- `ClusterSecretStore` en erreur `permission denied` → le rôle Vault
  Kubernetes n'est pas configuré ou la policy ne couvre pas le chemin lu :
  revoir la section "Configuration Vault requise" ci-dessus.
- `ExternalSecret` qui ne matérialise pas de `Secret` →
  `kubectl describe externalsecret <nom>` donne la raison exacte.
