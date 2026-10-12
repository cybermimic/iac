# Plan — accueillir inner-riddle sur la plateforme

**Statut : en cours** (mis à jour le 2026-10-12, après acceptation des
ADR-009, 010 et 011 et abandon du DNS local). Chaque étape suit la règle
du repo : code → `plan` relu → `apply` (ou synchronisation ArgoCD) avec
l'accord de l'opérateur.

inner-riddle ([dépôt privé](https://github.com/cybermimic/inner-riddle)) est
la première application business. Son dépôt fournit les images, un chart
Helm (`deploy/chart/`) et son contrat de déploiement (`docs/deployment.md`,
`docs/mise-en-production.md`). Ce repo fournit la plateforme et déclare
l'`Application` ArgoCD, sans jamais copier le code ([ADR-002](../adr/ADR-002-gitops-with-argocd.md)).

**Cible : `https://inner-riddle.cybermimic.com`**, joignable depuis
Internet, certificat Let's Encrypt.

## Décisions qui encadrent le plan

| Sujet | Décision |
|---|---|
| DNS local | Abandonné ([ADR-007](../adr/ADR-007-lan-dns.md), [incident](../incidents/2026-09-28-lan-dns-outage.md)) : services internes accessibles **par IP** |
| Exposition publique | [ADR-009](../adr/ADR-009-public-exposure.md) option D : **un seul Traefik, réservé au public**, sur `192.168.1.240` ; seule IP redirigée par la Freebox |
| Registre | [ADR-010](../adr/ADR-010-container-registry.md) : Zot sur `https://192.168.1.242` |
| CI | [ADR-011](../adr/ADR-011-ci-runners.md) : runners ARC **obligatoires** pour les dépôts privés (tous leurs workflows) ; jamais pour `iac` (public) |
| GitOps | [ADR-008](../adr/ADR-008-gitops-layout.md) : nouvelles features et applications via ArgoCD |

## Plan d'adressage cible

| IP | Usage |
|---|---|
| `192.168.1.240` | Traefik **public** (ports 80/443 redirigés depuis Internet) |
| `192.168.1.241` | libre |
| `192.168.1.242` | Registre Zot |
| `192.168.1.243` | Vault |
| `192.168.1.244` | ArgoCD |
| `192.168.1.245`-`.250` | services internes futurs |

## Ce dont l'application a besoin

| Besoin | Fourni par | Étape |
|---|---|---|
| Namespace `inner-riddle`, 1 pod backend (~128-256 Mi), 1 pod frontend (~32 Mi) | ArgoCD | 7 |
| Volume `ReadWriteOnce` de 1 Gi (SQLite + sauvegardes), stratégie `Recreate` | `storage/local-path` | ✅ |
| `https://inner-riddle.cybermimic.com` depuis Internet | Traefik public + Let's Encrypt | 4, 8 |
| Images `192.168.1.242/inner-riddle/{backend,frontend}:X.Y.Z` | `delivery/registry` | 5 |
| Secret des comptes, pull secret du registre | Vault + `security/external-secrets` | 3 |
| Publication des images à chaque étiquette | `delivery/actions-runners` | 6 |
| Déploiement depuis le dépôt privé | `delivery/argocd` + clé de déploiement | 7 |

Empreinte ajoutée (ordre de grandeur) : Zot ~150 Mi, ESO ~200 Mi (déjà
installé), ARC ~100 Mi au repos (+1-3 Gi pendant un job), inner-riddle
~300 Mi. Compatible avec les ~11 Go disponibles.

## Étapes

Légende : 🤖 = l'agent (code, `plan`, `apply` après accord) ; 👤 =
l'opérateur (secrets, comptes externes, réseau, sudo).

### 1. GitOps — ✅ fait (2026-10-12)

ADR-008 acceptée, `Application` racine appliquée, app-of-apps active sur
`gitops/apps/`.

### 2. Nettoyage DNS et services internes par IP

- ✅ `networking/lan-dns` supprimée (2026-10-12, 3 ressources détruites).
- ✅ Vault sur `https://192.168.1.243:8200` (2026-10-12) : listener en TLS
  (certificat CA interne, IP uniquement), `Service` `LoadBalancer`, Ingress
  retiré ; `ClusterSecretStore` d'External Secrets repointé. Règle la dette
  « Vault en HTTP dans le cluster ».
- 🤖 ArgoCD sur `https://192.168.1.244` : TLS par argocd-server lui-même
  (`server.insecure` retiré), `Service` `LoadBalancer` ; retrait de son
  Ingress.
- ✅ Certificat de la CA interne contenant une IP : accepté malgré la
  contrainte de nom de la CA (elle ne porte que sur les noms DNS ; les IP
  ne sont pas contraintes) — vérifié avec OpenSSL, reste à voir dans le
  navigateur. Durcissement possible plus tard : limiter aussi les IP à la
  plage MetalLB dans la CA (son certificat change alors, à réinstaller une
  fois sur les postes).
- 👤 Unseal de Vault après son redémarrage (changement de listener).

### 3. External Secrets — code déployé, configuration Vault à faire

Déjà en place : `gitops/apps/external-secrets.yaml` (chart 2.12.0) et
`ClusterSecretStore` `vault`, en échec tant que Vault n'est pas configuré.

- 👤 Dans son terminal (le token Vault ne passe jamais par un agent), via
  la CLI du pod (déjà configurée pour `https://127.0.0.1:8200` et la CA
  interne) :

  ```bash
  kubectl -n vault exec -it vault-0 -- sh
  # puis, dans le pod :
  vault login   # token admin, saisie masquée
  vault secrets enable -path=secret kv-v2
  vault auth enable kubernetes
  vault write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc
  vault policy write inner-riddle - <<'HCL'
  path "secret/data/inner-riddle/*" { capabilities = ["read"] }
  HCL
  # Rôle utilisé par le ClusterSecretStore « vault » (role: external-secrets)
  vault write auth/kubernetes/role/external-secrets \
    bound_service_account_names=external-secrets \
    bound_service_account_namespaces=external-secrets \
    policies=inner-riddle ttl=1h
  exit
  ```

  Les politiques des consommateurs suivants (registre, runners, ArgoCD)
  s'ajouteront à ce rôle (`policies=inner-riddle,registry,…`).
  Le détail (rôle exact, politiques des autres consommateurs : registre,
  runners, ArgoCD) est dans `features/security/external-secrets/README.md`.

### 4. Traefik public + Let's Encrypt

- 🤖 `networking/ingress` : IngressClass `traefik` non par défaut, liste
  de namespaces autorisés (`["inner-riddle"]`), provider CRD désactivé,
  exception ACME à la redirection HTTP → HTTPS, journaux d'accès.
- 🤖 `security/cert-manager` : ClusterIssuers `letsencrypt-staging` et
  `letsencrypt` (HTTP-01).
- 👤 Vérifier que la ligne Free a une **IPv4 publique complète**
  (« full-stack ») : Freebox OS → État de la Freebox → Internet, la plage
  de ports doit être `0-65535` ; sinon, la demander dans l'espace abonné
  Free (Ma Freebox → Paramètres avancés → Demander une adresse IP fixe
  V4 full-stack).
- 👤 **DNS chez OVH** (zone `cybermimic.com`, serveurs `ns102.ovh.net`) :
  créer un enregistrement `A` `inner-riddle` → IPv4 publique de la ligne,
  TTL 300 au début. Ne touche pas aux autres enregistrements (le site
  `cybermimic.com` reste où il est). Pas d'enregistrement `CAA` sur le
  domaine : Let's Encrypt est autorisé.
- 👤 **Ne pas encore** rediriger les ports.

### 5. Registre Zot

- 🤖 `delivery/registry` (ArgoCD) : Zot, `https://192.168.1.242`, TLS par
  Zot (certificat CA interne avec l'IP), 20 Gi `local-path`, rétention ;
  htpasswd et pull secret via External Secrets ; playbook Ansible qui
  installe la CA dans le magasin de confiance du NucBox et redémarre
  containerd.
- 👤 Produire les deux comptes htpasswd (écriture CI, lecture cluster) et
  les ranger dans Vault (`secret/registry/htpasswd`, `secret/registry/pull`,
  `secret/registry/push`) ; lancer le playbook (`-K`, `-c local` depuis le
  NucBox) ; installer la CA sur le poste qui testera un premier `docker
  push`.

### 6. Runners ARC

- 🤖 `delivery/actions-runners` (ArgoCD) : contrôleur ARC + scale set
  `inner-riddle`, libellé `homelab`, DinD, `minRunners: 0`,
  `maxRunners: 1`, CA interne approuvée par le Docker du runner.
- 👤 Créer la **GitHub App** de l'organisation `cybermimic` (droits
  minimaux pour les runners), l'installer sur `inner-riddle` uniquement,
  ranger son identifiant, son ID d'installation et sa clé privée dans
  Vault (`secret/actions-runners/github-app`).
- 👤 Dans le dépôt inner-riddle : `runs-on: homelab` pour tous les jobs ;
  variable `REGISTRY` = `192.168.1.242` ; secrets `REGISTRY_USER` /
  `REGISTRY_PASSWORD` (compte d'écriture). Le workflow `Release` publie
  alors à chaque étiquette `vX.Y.Z`.

### 7. Application inner-riddle

- 👤 Générer une **clé de déploiement SSH en lecture seule** pour le dépôt
  inner-riddle (GitHub → Settings → Deploy keys), ranger la clé privée dans
  Vault (`secret/argocd/repo-inner-riddle`) ; ranger les comptes de
  l'application dans `secret/inner-riddle/auth`, propriétés `accounts`
  (une ligne `identifiant:rôle:hash-bcrypt` par compte) et
  `session_secret`, générées avec l'image du backend :
  `inner-riddle hash-password` (saisie sans écho) et
  `inner-riddle new-session-secret` — voir `docs/deployment.md`
  d'inner-riddle.
- 🤖 `ExternalSecret` du dépôt pour ArgoCD (label
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
          image:
            registry: 192.168.1.242
          ingress:
            className: traefik
            clusterIssuer: letsencrypt-staging   # puis letsencrypt (étape 8)
          imagePullSecrets: [{name: registry-pull}]
          persistence:
            storageClass: local-path
          externalSecret:
            enabled: true
            secretStoreRef: {name: vault, kind: ClusterSecretStore}
            remoteKey: inner-riddle/auth   # propriétés « accounts » et « session_secret »
          networkPolicy:
            ingressNamespaces: [traefik]
    destination:
      server: https://kubernetes.default.svc
      namespace: inner-riddle
    syncPolicy:
      syncOptions: [CreateNamespace=true]
      # Synchronisation manuelle : application business (ADR-002, ADR-008).
  ```

  Noms exacts des valeurs : `deploy/chart/README.md` d'inner-riddle (à
  relire au moment d'écrire le fichier). Le namespace peut porter
  `pod-security.kubernetes.io/enforce: restricted`. HSTS est posé par
  l'application : aucun middleware Traefik n'est requis.

### 8. Mise en ligne

Suivie par le ticket IR-043 d'inner-riddle :

1. 🤖/👤 synchroniser l'`Application` ; vérifier depuis le LAN avec
   `curl --resolve inner-riddle.cybermimic.com:443:192.168.1.240` ;
2. 👤 rediriger les ports **80 et 443** de la Freebox vers
   **`192.168.1.240`** uniquement (Freebox OS → Paramètres → Gestion des
   ports) ;
3. 🤖 certificat `letsencrypt-staging` émis → passer à `letsencrypt` ;
4. 👤 depuis l'extérieur (réseau mobile) : application accessible en
   HTTPS valide ; l'IP publique ne sert rien d'autre (essayer
   `curl -k --resolve vault.homelab.lan:443:<IP publique>` → `404`) ;
5. 👤 depuis le LAN : vérifier que `https://inner-riddle.cybermimic.com`
   répond (NAT en épingle de la Freebox) ; sinon entrée `hosts` vers
   `192.168.1.240`.

## Mises à jour de documentation attendues

Avec chaque étape : README de la feature, tableau d'état du README racine,
`docs/architecture.md`, `docs/platform-overview.md` (plan d'adressage,
chemin d'une requête publique), ligne « Stack » de `CLAUDE.md`, dette dans
`docs/operations.md` (sauvegardes sur le même disque, IP du domicile
publiée dans le DNS).
