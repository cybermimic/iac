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

## Secrets à ranger dans Vault (opérateur)

Chemins décidés le 2026-10-12, lus par External Secrets (rôle
`external-secrets`). Valeurs **jamais** dans Git ni dans un chat.

| Chemin (`secret/…`, kv-v2) | Propriétés | Consommateur |
|---|---|---|
| `inner-riddle/auth` | `accounts`, `session_secret` | application (noms imposés par son chart) |
| `registry/htpasswd` | `htpasswd` (2 lignes : compte d'écriture + compte de lecture) | Zot |
| `registry/push` | `username`, `password` | référence pour les secrets GitHub du dépôt inner-riddle |
| `registry/pull` | `username`, `password` | `imagePullSecret` du cluster |
| `actions-runners/github-app` | `github_app_id`, `github_app_installation_id`, `github_app_private_key` | ARC (noms imposés par ARC) |
| `argocd/repo-inner-riddle` | `ssh_private_key` | ArgoCD (dépôt privé) |

Toutes les commandes se lancent **sur le NucBox**, avec la CLI du pod
Vault, après s'être connecté une fois :
`kubectl -n vault exec -it vault-0 -- vault login` (le jeton reste dans le
pod jusqu'à son redémarrage). Les valeurs passent par l'entrée standard
(`clé=-`) : jamais en argument, donc jamais dans l'historique.

**A. Politique et rôle (une fois)**

```bash
kubectl -n vault exec -i vault-0 -- vault policy write external-secrets - <<'HCL'
path "secret/data/inner-riddle/*"   { capabilities = ["read"] }
path "secret/data/registry/*"       { capabilities = ["read"] }
path "secret/data/actions-runners/*" { capabilities = ["read"] }
path "secret/data/argocd/*"         { capabilities = ["read"] }
HCL
kubectl -n vault exec vault-0 -- vault write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=external-secrets ttl=1h
```

**B. Registre (étape 5)** — deux comptes à mots de passe aléatoires,
jamais affichés :

```bash
PUSH_PW=$(openssl rand -base64 24); PULL_PW=$(openssl rand -base64 24)
HTP=$( { printf '%s' "$PUSH_PW" | docker run --rm -i httpd:2.4-alpine htpasswd -niB ci-push
         printf '%s' "$PULL_PW" | docker run --rm -i httpd:2.4-alpine htpasswd -niB cluster-pull; } )
printf '%s\n' "$HTP"    | kubectl -n vault exec -i vault-0 -- vault kv put secret/registry/htpasswd htpasswd=-
printf '%s' "$PUSH_PW"  | kubectl -n vault exec -i vault-0 -- vault kv put secret/registry/push username=ci-push password=-
printf '%s' "$PULL_PW"  | kubectl -n vault exec -i vault-0 -- vault kv put secret/registry/pull username=cluster-pull password=-
unset PUSH_PW PULL_PW HTP
```

**C. Clé de déploiement ArgoCD (étape 7)**

```bash
ssh-keygen -t ed25519 -N "" -C argocd-inner-riddle -f ~/inner-riddle-deploy
cat ~/inner-riddle-deploy.pub   # à coller dans GitHub : inner-riddle → Settings → Deploy keys, SANS « Allow write access »
kubectl -n vault exec -i vault-0 -- vault kv put secret/argocd/repo-inner-riddle ssh_private_key=- < ~/inner-riddle-deploy
shred -u ~/inner-riddle-deploy && rm ~/inner-riddle-deploy.pub
```

**D. GitHub App des runners (étape 6)** — après création de l'App
(voir l'étape 6) et téléchargement de sa clé privée `.pem` :

```bash
kubectl -n vault exec -i vault-0 -- vault kv put secret/actions-runners/github-app \
  github_app_id=<App ID> github_app_installation_id=<Installation ID> github_app_private_key=- < ~/Téléchargements/<app>.private-key.pem
shred -u ~/Téléchargements/<app>.private-key.pem
```

**E. Comptes de l'application (étape 7)** — avec l'image du backend
(dépôt inner-riddle cloné sur le NucBox, Docker présent) :

```bash
git clone git@github.com:cybermimic/inner-riddle.git ~/inner-riddle && cd ~/inner-riddle
docker compose run --rm backend inner-riddle hash-password      # une fois par compte ; saisie masquée, affiche le hash
( umask 077; nano ~/ir-accounts )   # une ligne par compte : identifiant:owner|reader:<hash>
kubectl -n vault exec -i vault-0 -- vault kv put secret/inner-riddle/auth accounts=- < ~/ir-accounts
docker compose run --rm -T backend inner-riddle new-session-secret \
  | kubectl -n vault exec -i vault-0 -- vault kv patch secret/inner-riddle/auth session_secret=-
shred -u ~/ir-accounts
```

Vérifier sans afficher les valeurs :
`kubectl -n vault exec vault-0 -- vault kv metadata get secret/inner-riddle/auth`.

## Étapes

Légende : 🤖 = l'agent (code, `plan`, `apply` après accord) ; 👤 =
l'opérateur (secrets, comptes externes, réseau, sudo).

### 1. GitOps — ✅ fait (2026-10-12)

ADR-008 acceptée, `Application` racine appliquée, app-of-apps active sur
`gitops/apps/`.

### 2. Nettoyage DNS et services internes par IP — ✅ fait (2026-10-12)

- ✅ `networking/lan-dns` supprimée (2026-10-12, 3 ressources détruites).
- ✅ Vault sur `https://192.168.1.243:8200` (2026-10-12) : listener en TLS
  (certificat CA interne, IP uniquement), `Service` `LoadBalancer`, Ingress
  retiré ; `ClusterSecretStore` d'External Secrets repointé. Règle la dette
  « Vault en HTTP dans le cluster ».
- ✅ ArgoCD sur `https://192.168.1.244` (2026-10-12) : TLS par
  argocd-server (`server.insecure` retiré), `Service` `LoadBalancer`,
  Ingress retiré.
- ✅ Certificat de la CA interne contenant une IP : accepté malgré la
  contrainte de nom de la CA (elle ne porte que sur les noms DNS ; les IP
  ne sont pas contraintes) — vérifié avec OpenSSL et dans Chrome
  (Windows) pour Vault et ArgoCD. Durcissement possible plus tard : limiter aussi les IP à la
  plage MetalLB dans la CA (son certificat change alors, à réinstaller une
  fois sur les postes).
- ✅ Unseal de Vault après son redémarrage (fait).

### 3. External Secrets — ✅ fait (2026-10-12)

`gitops/apps/external-secrets.yaml` (chart 2.12.0) et `ClusterSecretStore`
`vault` → `https://192.168.1.243:8200` : **`Valid`** depuis que l'opérateur
a configuré Vault (commandes ci-dessous, faites le 2026-10-12).

Suite possible (durcissement) : Vault avertit que le rôle
`external-secrets` n'a pas d'`audience` ; en ajouter une (`vault write
auth/kubernetes/role/external-secrets audience=vault …` + `audiences:
[vault]` dans `serviceAccountRef` du `ClusterSecretStore`) restreindrait les
jetons acceptés à ceux émis pour Vault.

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

### 4. Traefik public + Let's Encrypt — ✅ fait (2026-10-13)

- ✅ `networking/ingress` : IngressClass `traefik` non par défaut,
  namespaces servis `["inner-riddle"]` (liste vide interdite), provider CRD
  désactivé, journaux d'accès. Pas d'exception à la redirection HTTP →
  HTTPS : le challenge HTTP-01 la suit.
- ✅ `security/cert-manager` : ClusterIssuers `letsencrypt-staging` et
  `letsencrypt` (HTTP-01), comptes ACME enregistrés.
- ✅ IPv4 full-stack confirmée par l'opérateur ; enregistrement `A`
  `inner-riddle.cybermimic.com` créé chez OVH.
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

### 5. Registre Zot — ✅ fait (2026-10-13)

- ✅ `delivery/registry` (ArgoCD) : Zot v2.1.22, `https://192.168.1.242`,
  TLS par Zot (certificat CA interne, IP), 20 Gi `local-path`, rétention
  10 versions ; htpasswd via External Secrets ; configuration validée par
  `zot verify`. Playbook Ansible `features/delivery/registry/ansible/`
  (CA dans le magasin de confiance du NucBox + redémarrage de containerd).
  Le pull secret de l'application est livré avec elle (étape 7).
- ✅ Comptes `ci-push` / `cluster-pull` rangés dans Vault (commandes B),
  `ExternalSecret` `zot-htpasswd` synchronisé ; accès anonyme et mauvais
  mot de passe refusés (`401`).
- ✅ Playbook de confiance de la CA lancé sur le NucBox (`-e
  ansible_become_exe=sudo.ws` : sudo-rs, voir `bootstrap/README.md`) ;
  `curl https://192.168.1.242/v2/` sans `--cacert` → `401` (TLS approuvé).

### 6. Runners ARC — code livré (2026-10-13), attend la GitHub App

- ✅ `delivery/actions-runners` (ArgoCD) : contrôleur ARC 0.15.0 + scale
  set `homelab` pour `cybermimic/inner-riddle`, DinD (images épinglées :
  runner 2.338.0, docker 29.9.0-dind), `minRunners: 0`, `maxRunners: 1`,
  CA interne approuvée par dockerd pour `192.168.1.242`, `NetworkPolicy`
  (sorties : DNS, registre, Internet).
- 👤 Créer la **GitHub App** de l'organisation : GitHub → organisation
  `cybermimic` → Settings → Developer settings → GitHub Apps → New GitHub
  App :
  - nom : `cybermimic-homelab-runners` ; Homepage URL :
    `https://github.com/cybermimic` ; **Webhook : décocher « Active »** ;
  - Repository permissions : **Administration : Read and write**,
    **Metadata : Read-only** (rien d'autre) ;
  - « Where can this GitHub App be installed? » : Only on this account ;
  - Create → noter l'**App ID** ; « Generate a private key » (télécharge
    un `.pem`) ;
  - Install App → `cybermimic` → **Only select repositories** →
    `inner-riddle` → l'URL de la page obtenue se termine par
    `/installations/<Installation ID>`.
  Puis ranger l'App dans Vault : commandes **D** ci-dessus.
- 👤 Dans le dépôt inner-riddle → Settings → Secrets and variables →
  Actions (noms lus dans ses workflows `ci.yml` / `release.yml`) :
  - **Variables** : `CI_RUNNER` = `homelab`, `RELEASE_RUNNER` = `homelab`,
    `REGISTRY` = `192.168.1.242` ;
  - **Secrets** : `REGISTRY_USER` = `ci-push`, `REGISTRY_PASSWORD` = le mot
    de passe du compte d'écriture, à afficher dans son propre terminal
    juste pour le coller :
    `kubectl -n vault exec vault-0 -- vault kv get -field=password secret/registry/push`.
  - `maxRunners: 1` : les jobs de la CI passent les uns après les autres.
  Le workflow `Release` publie alors à chaque étiquette `vX.Y.Z`.

### 7. Application inner-riddle — code livré (2026-10-13), attend la version v0.1.0

- ✅ Clé de déploiement en lecture seule ajoutée au dépôt et rangée dans
  Vault : ArgoCD lit le dépôt (seule erreur restante : l'étiquette
  `v0.1.0` n'existe pas encore).
- 👤 (Détail de la procédure, déjà faite) Générer une **clé de déploiement SSH en lecture seule** pour le dépôt
  inner-riddle (GitHub → Settings → Deploy keys), ranger la clé privée dans
  Vault (`secret/argocd/repo-inner-riddle`) ; ranger les comptes de
  l'application dans `secret/inner-riddle/auth`, propriétés `accounts`
  (une ligne `identifiant:rôle:hash-bcrypt` par compte) et
  `session_secret`, générées avec l'image du backend :
  `inner-riddle hash-password` (saisie sans écho) et
  `inner-riddle new-session-secret` — voir `docs/deployment.md`
  d'inner-riddle.
- ✅ Code livré (vérifié par `helm template` du chart d'inner-riddle avec
  ces valeurs) :
  - `gitops/apps/repositories/inner-riddle-repo.yaml` : `ExternalSecret`
    qui fabrique le Secret « repository » d'ArgoCD (clé SSH de
    `secret/argocd/repo-inner-riddle`) ;
  - `gitops/inner-riddle/registry-pull.yaml` : pull secret
    `registry-pull` (`kubernetes.io/dockerconfigjson`, compte
    `cluster-pull`) ;
  - `gitops/apps/inner-riddle.yaml` : Application, `targetRevision:
    v0.1.0`, images `192.168.1.242/inner-riddle/*`, classe `traefik`,
    `letsencrypt-staging`, `local-path`, comptes depuis
    `inner-riddle/auth`, namespace en Pod Security `restricted`,
    **synchronisation manuelle**.
- 👤 Publier la première version : dans le dépôt inner-riddle, étiquette
  `v0.1.0` (la version du chart vaut déjà `0.1.0`) → le workflow `Release`
  tourne sur les runners `homelab` et publie les images dans le registre.
  Tant que l'étiquette n'existe pas, l'Application affiche une erreur de
  comparaison : c'est attendu.

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
