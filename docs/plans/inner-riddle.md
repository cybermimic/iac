# Plan — accueillir inner-riddle sur la plateforme

**Statut : proposition** (2026-10-12). Rien n'est appliqué ; chaque étape
suit la règle du repo : ADR validée → code → `plan` relu → `apply` par
l'opérateur.

inner-riddle ([dépôt privé](https://github.com/cybermimic/inner-riddle)) est
la première application business. Son dépôt fournit les images, un chart
Helm (`deploy/chart/`) et son contrat de déploiement (`docs/deployment.md`,
`docs/mise-en-production.md`). Ce repo fournit la plateforme et déclare
l'`Application` ArgoCD, sans jamais copier le code ([ADR-002](../adr/ADR-002-gitops-with-argocd.md)).

## Ce dont l'application a besoin

| Besoin | Fourni par | Statut |
|---|---|---|
| Namespace `inner-riddle`, 1 pod backend (~128-256 Mi), 1 pod frontend (~32 Mi) | ArgoCD | — |
| Volume `ReadWriteOnce` de 1 Gi (SQLite + sauvegardes), stratégie `Recreate` | `storage/local-path` | ✅ |
| `https://inner-riddle.cybermimic.com` depuis Internet | `networking/public-ingress` + Let's Encrypt | [ADR-009](../adr/ADR-009-public-exposure.md) proposé |
| Images `registry.homelab.lan/inner-riddle/{backend,frontend}:X.Y.Z` | `delivery/registry` | [ADR-010](../adr/ADR-010-container-registry.md) proposé |
| Secret des comptes (hash bcrypt + rôle), pull secret du registre | Vault + `security/external-secrets` | ESO décidé ([ADR-003](../adr/ADR-003-secret-management.md)), pas installé |
| Publication des images à chaque étiquette | `delivery/actions-runners` | [ADR-011](../adr/ADR-011-ci-runners.md) proposé |
| Déploiement depuis le dépôt privé | `delivery/argocd` + clé de déploiement | code prêt, pas appliqué ; [ADR-008](../adr/ADR-008-gitops-layout.md) proposé |

Empreinte totale ajoutée (ordre de grandeur) : Traefik public ~100 Mi,
Zot ~150 Mi, ESO ~200 Mi, ARC ~100 Mi au repos (+1-3 Gi pendant un job),
ArgoCD ~400 Mi, inner-riddle ~300 Mi. Soit ~1,3 Gi au repos, compatible
avec les ~13 Go libres.

## Étapes

Ordre conseillé ; chaque étape est une PR distincte de ce repo, livrée avec
son README et la mise à jour des tableaux de statut.

### 1. GitOps

- Opérateur : valider l'ADR-008 (ou l'amender), puis `plan` / `apply` de
  `delivery/argocd`.
- Code : `Application` racine (Terraform) qui suit `gitops/apps/`.

### 2. External Secrets

- Code : feature `security/external-secrets` (chart officiel, version
  épinglée), `ClusterSecretStore` `vault` (méthode d'authentification
  `kubernetes`, moteur `kv-v2` monté sur `secret/`).
- Opérateur, dans son terminal (le root token ne passe jamais par un agent) :

  ```bash
  vault secrets enable -path=secret kv-v2
  vault auth enable kubernetes
  vault write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc
  # Une politique en lecture seule par application, par exemple :
  vault policy write inner-riddle - <<'HCL'
  path "secret/data/inner-riddle/*" { capabilities = ["read"] }
  HCL
  vault write auth/kubernetes/role/inner-riddle \
    bound_service_account_names=external-secrets \
    bound_service_account_namespaces=external-secrets \
    policies=inner-riddle ttl=1h
  ```

  Le rôle exact (compte de service lié, une politique par application ou
  un rôle par `SecretStore` de namespace) est tranché dans le README de la
  feature.

### 3. Ingress public (après validation de l'ADR-009)

- Code : `networking/public-ingress`, ClusterIssuers `letsencrypt-staging`
  et `letsencrypt` dans `security/cert-manager`, zone de résolution locale
  facultative dans `networking/lan-dns`.
- Opérateur : vérifier l'IPv4 publique « full-stack » de la ligne Free ;
  créer l'enregistrement `A` `inner-riddle.cybermimic.com` ; **ne pas**
  encore rediriger les ports.

### 4. Registre (après validation de l'ADR-010)

- Code : `delivery/registry` (Zot) + playbook Ansible qui installe la CA
  interne dans le magasin de confiance du NucBox et redémarre containerd.
- Opérateur : produire les deux comptes htpasswd et les ranger dans Vault
  (`secret/registry/htpasswd`, `secret/registry/pull`, `secret/registry/push`) ;
  lancer le playbook (`-K`) ; installer la CA sur le poste qui publiera les
  premières images à la main.

### 5. Runners (après validation de l'ADR-011)

- Code : `delivery/actions-runners` (contrôleur ARC + scale set
  `inner-riddle`, libellé `homelab`).
- Opérateur : créer la GitHub App de l'organisation, ranger son
  identifiant et sa clé privée dans Vault ; dans le dépôt inner-riddle,
  variable `RELEASE_RUNNER` (libellé du scale set) et secrets
  `REGISTRY_USER` / `REGISTRY_PASSWORD` (compte d'écriture du registre).
  Le workflow `Release` d'inner-riddle publie alors à chaque étiquette
  `vX.Y.Z` ; en attendant, `tools/release/publish.sh X.Y.Z` depuis un poste
  du LAN.

### 6. Application inner-riddle

- Opérateur : générer une clé de déploiement SSH **en lecture seule** pour
  le dépôt inner-riddle (GitHub → Settings → Deploy keys), ranger la clé
  privée dans Vault (`secret/argocd/repo-inner-riddle`) ; ranger les
  comptes de l'application dans `secret/inner-riddle/auth`, propriétés
  `accounts` (une ligne `identifiant:rôle:hash-bcrypt` par compte) et
  `session_secret`. Les deux valeurs se génèrent avec l'image du backend :
  `inner-riddle hash-password` (saisie sans écho) et
  `inner-riddle new-session-secret` — voir le `docs/deployment.md`
  d'inner-riddle.
- Code : `ExternalSecret` du dépôt pour ArgoCD (label
  `argocd.argoproj.io/secret-type: repository`), puis
  `gitops/apps/inner-riddle.yaml`, esquisse :

  ```yaml
  apiVersion: argoproj.io/v1alpha1
  kind: Application
  metadata:
    name: inner-riddle
    namespace: argocd
  spec:
    project: default
    source:
      repoURL: git@github.com:cybermimic/inner-riddle.git
      targetRevision: v0.1.0          # version déployée : changer = une PR ici
      path: deploy/chart
      helm:
        valuesObject:
          host: inner-riddle.cybermimic.com
          ingress:
            className: traefik-public
            clusterIssuer: letsencrypt
          imagePullSecrets: [{name: registry-pull}]
          persistence:
            storageClass: local-path
          externalSecret:
            enabled: true
            secretStoreRef: {name: vault, kind: ClusterSecretStore}
            remoteKey: inner-riddle/auth   # propriétés « accounts » et « session_secret »
          networkPolicy:
            ingressNamespaces: [traefik-public]
    destination:
      server: https://kubernetes.default.svc
      namespace: inner-riddle
    syncPolicy:
      syncOptions: [CreateNamespace=true]
      # Synchronisation manuelle : application business (ADR-002, ADR-008).
  ```

  Valeurs complètes : `deploy/chart/README.md` d'inner-riddle (chart
  vérifié par `helm lint` + `kubeconform` en CI, et installé sur un k3s 1.36
  en namespace `restricted`). Le namespace peut porter
  `pod-security.kubernetes.io/enforce: restricted`. HSTS est posé par
  l'application : aucun middleware Traefik n'est requis.

### 7. Mise en ligne

Suivie par le ticket IR-043 d'inner-riddle :

1. synchroniser l'`Application`, vérifier depuis le LAN (résolution locale
   vers `.241`) ;
2. rediriger les ports 80/443 de la Freebox vers `.241`, émettre d'abord
   avec `letsencrypt-staging`, puis `letsencrypt` ;
3. depuis l'extérieur (réseau mobile) : application accessible, noms
   `*.homelab.lan` injoignables via l'IP publique.

## Mises à jour de documentation attendues

Avec chaque étape : README de la feature, tableau d'état du README racine,
`docs/architecture.md`, `docs/platform-overview.md` (plan d'adressage :
`192.168.1.241` → ingress public ; chemin d'une requête publique), ligne
« Stack » de `CLAUDE.md`, dette dans `docs/operations.md` (sauvegardes sur
le même disque, IP du domicile publiée).
