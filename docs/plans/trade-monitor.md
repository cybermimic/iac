# Plan — application trade-monitor (service interne)

**Statut : prêt à déployer** (2026-11-04). Code, chart et CI dans le dépôt
privé `cybermimic/trade-monitor` (`deploy/chart`, `docs/deployment.md`).

Outil personnel d'aide à l'investissement, un seul utilisateur. **Service
interne** : joignable depuis le LAN et le VPN seulement, jamais depuis
Internet. Pas d'ingress, pas de Keycloak : le réseau est la frontière.

## Ce que la plateforme fournit

| Besoin | Réponse |
|---|---|
| Exposition | `Service` `LoadBalancer` sur **`192.168.1.246`** (MetalLB), port 443 ; nginx du pod frontend termine le TLS ([platform-overview](../platform-overview.md) : une IP par service interne) |
| Certificat | `Certificate` cert-manager du chart, `ipAddresses: [192.168.1.246]`, ClusterIssuer `homelab-ca` (comme Zot) |
| Images | `192.168.1.242/trade-monitor/{backend,frontend}:X.Y.Z`, publiées par la CI à l'étiquette `vX.Y.Z` ; pull secret `registry-pull` ([`gitops/trade-monitor/`](../../gitops/trade-monitor/)) |
| Données | PVC `local-path` 1 Gi (SQLite, cache), conservé à la suppression de la release |
| Sauvegarde | `CronJob` quotidien du chart, copie sur le même volume (comme inner-riddle) ; chaîne hors disque : [ADR-016](../adr/ADR-016-backups.md) |
| CI | Scale set ARC `trade-monitor` (`minRunners: 0`, `maxRunners: 1`) |
| Secret applicatif | `secret/trade-monitor/market-data`, propriété `alpha_vantage_api_key` (facultatif : sans lui, l'application se rabat sur une autre source de cours) |
| Accès ArgoCD au dépôt | `secret/argocd/repo-trade-monitor` (clé de déploiement en lecture seule) |

## Étapes (opérateur)

Commandes **sur le NucBox**, après `kubectl -n vault exec -it vault-0 --
vault login`. Valeurs par l'entrée standard, jamais en argument.

**A. GitHub App des runners — AVANT la fusion de cette PR** (sinon le
listener du scale set `trade-monitor`, synchronisé automatiquement, échoue) :
organisation → Settings → GitHub Apps → l'App des runners → Configure →
*Repository access* → ajouter `trade-monitor`. `github_app_installation_id`
ne change pas (même installation).

**B. Policy Vault** — depuis le fichier versionné, après comparaison
([Modifier la policy](../../features/security/external-secrets/README.md#modifier-la-policy)) :

```bash
diff <(kubectl -n vault exec vault-0 -- vault policy read external-secrets) \
     features/security/vault/policies/external-secrets.hcl
# seule différence attendue : + secret/data/trade-monitor/*
kubectl -n vault exec -i vault-0 -- vault policy write external-secrets - \
  < features/security/vault/policies/external-secrets.hcl
```

**C. Clé de déploiement ArgoCD**

```bash
ssh-keygen -t ed25519 -N "" -C argocd-trade-monitor -f ~/trade-monitor-deploy
cat ~/trade-monitor-deploy.pub   # GitHub : trade-monitor → Settings → Deploy keys, SANS « Allow write access »
kubectl -n vault exec -i vault-0 -- vault kv put secret/argocd/repo-trade-monitor ssh_private_key=- < ~/trade-monitor-deploy
shred -u ~/trade-monitor-deploy && rm ~/trade-monitor-deploy.pub
```

**D. Clé Alpha Vantage (facultative)**

```bash
tr -d '\n\r ' < <fichier de la clé> \
  | kubectl -n vault exec -i vault-0 -- vault kv put secret/trade-monitor/market-data alpha_vantage_api_key=-
```

**E. Secrets du dépôt GitHub** (publication des images) : copie de
`secret/registry/push`, sans l'afficher :

```bash
kubectl -n vault exec vault-0 -- vault kv get -field=username secret/registry/push \
  | gh secret set REGISTRY_USER -R cybermimic/trade-monitor
kubectl -n vault exec vault-0 -- vault kv get -field=password secret/registry/push \
  | gh secret set REGISTRY_PASSWORD -R cybermimic/trade-monitor
```

**F. Fusion de cette PR**, puis vérifier le scale set
(`kubectl -n argocd get application arc-runners-trade-monitor` → Synced,
Healthy). La CI du dépôt trade-monitor démarre alors.

**G. Version `v0.1.0`** : promotion `dev` → `main` et étiquette dans le
dépôt trade-monitor ; attendre le workflow `Release` (images publiées).

**H. Synchronisation manuelle** de l'Application `trade-monitor` dans
ArgoCD, diff relu. Vérifier :

```bash
kubectl -n trade-monitor get pods,certificate,externalsecret   # Running, Ready, SecretSynced
curl -sI https://192.168.1.246/ | head -1                      # HTTP/2 200 (CA interne installée)
```

## Changer de version

`targetRevision` dans [`gitops/apps/trade-monitor.yaml`](../../gitops/apps/trade-monitor.yaml)
(PR), puis synchronisation manuelle. Procédure complète (sauvegarde avant
migration, retour arrière) : `docs/deployment.md` du dépôt applicatif.
