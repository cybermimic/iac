# security/keycloak

## Objectif

Fournisseur d'identité centralisé ([ADR-012](../../../docs/adr/ADR-012-identity-keycloak.md)) :
gère les comptes, mots de passe et 2FA des applications business, en
commençant par inner-riddle. Un realm par application — Keycloak ne porte
que l'identité, jamais les droits métier (D-58/D-59, dans l'application).

## Gérée par ArgoCD, pas par Terraform

`gitops/apps/keycloak.yaml` (ADR-008) — opérateur Keycloak officiel
(manifestes vendorisés, pas de chart) + PostgreSQL + `keycloak-config-cli`.
Exception : `public_namespaces` (Terraform, `networking/ingress`) doit
inclure `keycloak` pour que l'exposition publique fonctionne.

## Dépendances

- `delivery/argocd`, `security/external-secrets` — mots de passe
  PostgreSQL/admin et secret du client OIDC, tous dans Vault.
- `storage/local-path` — volumes PostgreSQL (données + sauvegardes).
- `networking/ingress` — pages de connexion publiques ; variable
  `public_namespaces` à mettre à jour (Terraform, en dehors de ce dossier).
- `security/cert-manager` — certificat Let's Encrypt (public) et CA
  interne (admin).
- Vault configuré par l'opérateur (secrets ci-dessous) avant que quoi que
  ce soit ne devienne fonctionnel.

## Exposition (ADR-012) — la règle à ne jamais casser

| Adresse | Sert | Publié par |
|---|---|---|
| `https://auth.cybermimic.com` | **Seulement** `/realms/inner-riddle` et `/resources` (un chemin par realm, ajouté explicitement) | `ingress-public.yaml` (Traefik public) |
| `https://192.168.1.245:8443` | Console d'administration, realm `master` | `admin-access.yaml` (Service `LoadBalancer`, CA interne) |

`/admin` et `/realms/master` **ne sont jamais** routés par l'ingress
public — l'Ingress de ce dossier ne liste que des chemins explicites,
jamais de wildcard. Ajouter un nouveau realm public = ajouter son chemin
ici, en revue.

Conséquence : le realm `master` a sa propre `frontendUrl` (`gitops/config-cli/realm-master.yaml`)
pointée sur l'adresse admin, sinon Keycloak construit ses URLs OIDC avec
le `hostname` public — qui n'expose pas `master` — et la console
d'administration reste bloquée au chargement (voir Troubleshooting).

## Secrets Vault requis (opérateur, pas l'agent)

Avant que `ClusterSecretStore vault` puisse les lire, dans Vault :

```bash
vault kv put secret/keycloak/postgres username=keycloak password=<généré>
vault kv put secret/keycloak/admin username=admin password=<généré>
vault kv patch secret/inner-riddle/auth oidc_client_secret=<généré>
```

**Et** étendre la policy du rôle Kubernetes auth `external-secrets` à
`secret/data/keycloak/*` — sans ça, les `ExternalSecret` échouent en
`403 permission denied` même si les valeurs ci-dessus existent (rencontré
au premier déploiement, 2026-10-19). Procédure complète :
[security/external-secrets](../external-secrets/README.md), section
« Configuration Vault requise ».

`inner-riddle/auth` existe déjà (clés `accounts`, `session_secret`,
`oidc_client_secret` ajoutée ici) — `vault kv patch`, pas `put`, pour ne
pas écraser les clés existantes. Protéger le compte `admin` par 2FA dès la
première connexion sur `https://192.168.1.245:8443`.

## Ressources approximatives

~700 Mi-1 Gi RAM (opérateur ~100 Mi, Keycloak ~512-800 Mi, PostgreSQL
~128-256 Mi), 10 Gi de stockage (5 Gi données + 5 Gi sauvegardes,
`local-path`). À mesurer après déploiement (budget 16 Go RAM).

## Inputs / Outputs

Pas de variables Terraform (feature ArgoCD). Configuration dans
`gitops/keycloak.yaml` (hostnames, ressources), `gitops/postgres/` (taille
du volume, image), `gitops/config-cli/realm-inner-riddle.yaml` (realm).

## Installation

1. Vault configuré (section ci-dessus).
2. `public_namespaces` mis à jour côté Terraform (`terraform plan` /
   `apply`, voir `infrastructure/environments/homelab/README.md`) — sans
   ça, `ingress-public.yaml` reste sans effet (Traefik ignore les
   namespaces non listés).
3. PR mergée sur `main` → ArgoCD synchronise automatiquement
   (`syncPolicy.automated`).

Vérification :

```bash
kubectl -n argocd get application keycloak        # Synced, Healthy
kubectl -n keycloak get keycloak,statefulset,pods
kubectl -n keycloak get certificate                # keycloak-admin-tls, keycloak-public-tls : READY True
kubectl -n keycloak logs job/keycloak-config-cli   # realm appliqué sans erreur
```

Puis, depuis un poste du LAN avec la CA installée :
`https://192.168.1.245:8443` → console d'administration. Depuis
n'importe où : `https://auth.cybermimic.com/realms/inner-riddle`.

## Upgrade

Keycloak, l'opérateur et ses CRDs partagent une version (ADR-012) :
remplacer les 5 fichiers de `gitops/operator/` par ceux du tag visé
(`https://github.com/keycloak/keycloak-k8s-resources/tree/<version>/kubernetes`),
lire les release notes (changements de schéma de base possibles), `plan`
visuel via `git diff`, laisser ArgoCD synchroniser. Les 4 CRDs sont
exclues de `yamllint` (`.yamllint.yml`) : les copier telles quelles, sans
les reformater. `keycloak-config-cli`
: aligner sa version sur celle de Keycloak.

## Rollback

Revenir aux manifestes de l'opérateur de la version précédente (PR). Les
données (realms, comptes) ne sont pas affectées par un rollback du
serveur seul — elles vivent dans PostgreSQL.

## Troubleshooting

- Console de compte (`https://auth.cybermimic.com/realms/<realm>/account`)
  en erreur « server responded with an invalid status », `POST
  …/openid-connect/token` → `403 {"error":"Invalid origin"}`, et journaux
  `Non-secure context detected … originated from a proxy` → Keycloak ne lit
  pas les en-têtes `X-Forwarded-*` de Traefik et se croit en `http://`.
  Rencontré le 2026-10-20 : le CR porte maintenant `proxy.headers:
  xforwarded` et `proxy-trusted-addresses` limité au CIDR des pods.
  Vérification sans compte : `curl -H "Origin: https://auth.cybermimic.com"
  -d grant_type=authorization_code -d code=bidon -d client_id=account-console
  -d redirect_uri=https://auth.cybermimic.com/realms/inner-riddle/account
  https://auth.cybermimic.com/realms/inner-riddle/protocol/openid-connect/token`
  doit répondre `400 invalid_grant`, pas `403`. Les applications
  confidentielles (inner-riddle) ne sont pas touchées : elles échangent le
  code de serveur à serveur, sans `Origin`.
- Connexion à une application refusée après le retour de Keycloak
  (« la connexion n'a pas abouti »), journaux Keycloak
  `CODE_TO_TOKEN_ERROR … error="invalid_client_credentials"` → le secret
  du client enregistré dans Keycloak n'est pas celui de Vault. Rencontré
  le 2026-10-20 : le realm écrivait `${INNER_RIDDLE_CLIENT_SECRET}`, alors
  que `keycloak-config-cli` attend `$(env:NOM)`. Le texte était donc
  enregistré tel quel comme secret, visible dans ce dépôt public.
  Vérification sans afficher le secret : depuis le pod de l'application,
  un échange de jeton avec un code bidon doit répondre `invalid_grant`
  (secret accepté), pas `unauthorized_client`. Le Job tourne aussi avec
  `IMPORT_CACHE_ENABLED=false`, pour que chaque synchro réapplique les
  valeurs venues de Vault. Après un changement de secret dans Vault, il
  faut une synchro **manuelle** de l'Application `keycloak` : le Job est
  un hook, que la synchro automatique ne relance pas tant qu'aucune autre
  ressource ne change. Il faut ensuite redémarrer le backend de
  l'application, qui ne lit son secret qu'au démarrage.
- Application `keycloak` en `OutOfSync` permanent sur
  `StatefulSet/keycloak-postgres`, alors qu'un `kubectl diff
  --server-side` du manifeste ne montre rien → faux écart de la
  comparaison classique d'ArgoCD : l'API server ajoute `apiVersion`,
  `kind`, `volumeMode` et `status` dans `volumeClaimTemplates`. Rencontré
  le 2026-10-20 ; l'Application porte depuis l'annotation
  `argocd.argoproj.io/compare-options: ServerSideDiff=true`
  (`gitops/apps/keycloak.yaml`). Ne pas ignorer tout
  `volumeClaimTemplates` (`ignoreDifferences`) : un vrai changement de
  taille deviendrait invisible.
- Console d'administration qui charge puis reste bloquée, le navigateur
  demandant `https://auth.cybermimic.com/realms/master/protocol/openid-connect/3p-cookies/step1.html`
  (404, normal — `ingress-public.yaml` ne route que `/realms/inner-riddle`
  et `/resources`) → le realm `master` construit ses URLs OIDC (connexion
  de la console, 3p-cookies) avec le `hostname` public plutôt qu'avec
  l'adresse admin (rencontré le 2026-10-20). Corrigé par
  `gitops/config-cli/realm-master.yaml`
  (`attributes.frontendUrl: https://192.168.1.245:8443`), appliqué
  automatiquement par `keycloak-config-cli` à chaque sync. Si le problème
  revient malgré ce fichier, vérifier à la main :
  `kubectl -n keycloak exec -i keycloak-0 -- /opt/keycloak/bin/kcadm.sh get realms/master`
  (champ `attributes.frontendUrl`).
- `ClusterSecretStore`/secrets en erreur `403 permission denied` → policy
  Vault pas étendue à `secret/data/keycloak/*` (section « Secrets Vault
  requis » ci-dessus).
- Pod `keycloak-operator` en `Pending` (`untolerated taint`) → toleration
  control-plane manquante sur le Deployment vendorisé
  (`gitops/operator/kubernetes.yml`) ; déjà corrigée une fois
  (2026-10-19), à vérifier en premier si une future mise à jour du
  manifeste upstream l'a fait disparaître.
- Pod Keycloak qui ne démarre pas → `kubectl -n keycloak logs
  statefulset/keycloak` ; souvent une erreur de connexion à PostgreSQL
  (mot de passe incohérent entre `keycloak-postgres` et la base déjà
  initialisée — un changement de mot de passe après le premier démarrage
  de PostgreSQL ne met pas à jour le mot de passe **dans** PostgreSQL,
  seulement le secret).
- `keycloak-config-cli` en échec → `kubectl -n keycloak logs
  job/keycloak-config-cli` ; vérifier que `INNER_RIDDLE_CLIENT_SECRET`
  n'est pas vide (`inner-riddle/auth` doit déjà avoir la clé
  `oidc_client_secret` dans Vault avant le premier sync).
- Certificat navigateur non reconnu sur `https://192.168.1.245:8443` → CA
  interne pas installée sur ce poste (voir `security/cert-manager`).
- `Service` admin qui ne sélectionne aucun pod (`kubectl -n keycloak get
  endpoints keycloak-admin` vide) → vérifier les labels réels des pods
  Keycloak (`kubectl -n keycloak get pods --show-labels`) contre le
  `selector` de `admin-access.yaml` ; l'opérateur peut changer ces labels
  d'une version à l'autre, non garanti par la CRD.
