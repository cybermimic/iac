# ADR-012 — Fournisseur d'identité (Keycloak)

**Statut : Acceptée** (2026-10-19).

## Contexte

inner-riddle (application business publique, [ADR-009](ADR-009-public-exposure.md))
authentifie aujourd'hui ses utilisateurs par des comptes déclarés dans sa
configuration (hash bcrypt dans Vault). L'opérateur veut :

- gérer les utilisateurs et leurs comptes (mot de passe, double
  authentification, sessions) dans un fournisseur d'identité, plus dans
  l'application ;
- **Keycloak**, réutilisable plus tard par d'autres applications, chacune
  dans son realm ;
- inner-riddle d'abord ; le SSO des outils internes (ArgoCD, Vault, Zot)
  viendra peut-être plus tard.

Côté application (dépôt inner-riddle, D-58 / D-59) : flux OIDC
*authorization code* + PKCE mené par le backend (client confidentiel), droits
par carte stockés dans l'application. Keycloak ne porte que l'identité.

Contraintes : nœud unique de 16 Go, Traefik réservé au public avec liste
explicite de namespaces, services internes par IP avec la CA interne,
secrets dans Vault via External Secrets, nouvelles features par ArgoCD
([ADR-008](ADR-008-gitops-layout.md)).

## Exposition : la question centrale

La page de connexion doit être **publique** : la thérapeute se connecte
depuis l'extérieur. La console d'administration, elle, ne doit **jamais**
l'être.

Keycloak sait servir l'administration sur une autre adresse
(`hostname-admin`). Proposition :

| Adresse | Sert | Publiée par |
|---|---|---|
| `https://auth.cybermimic.com` | pages de connexion et de compte des realms publics : chemins `/realms/<realm>` listés un par un, et `/resources` | Traefik (namespace `keycloak` ajouté à `public_namespaces`), certificat Let's Encrypt |
| `https://192.168.1.245:8443` | console d'administration et realm `master` | `Service` `LoadBalancer` (MetalLB), certificat de la CA interne |

Publier un nouveau realm sur Internet = ajouter son chemin à l'Ingress :
une décision visible en revue, comme `public_namespaces`. `/realms/master`
et `/admin` ne sont jamais routés par Traefik.

## Options de déploiement

| Option | RAM | Pour | Contre |
|---|---|---|---|
| **A. Opérateur Keycloak officiel (recommandé)** | opérateur ~100 Mi + Keycloak ~600-800 Mi | Maintenu par le projet Keycloak ; CRD `Keycloak` (configuration, hostnames, TLS, montées de version) | Deux composants ; l'import de realm de l'opérateur (`KeycloakRealmImport`) ne fait que créer, jamais mettre à jour |
| B. Chart Helm `codecentric/keycloakx` | Keycloak ~600-800 Mi | Un seul chart, très utilisé | Chart communautaire ; configuration plus verbeuse |
| C. Manifestes écrits à la main | Keycloak ~600-800 Mi | Tout est visible | Montées de version et options à maintenir soi-même |

Base de données (Keycloak exige une vraie base en production) :

| Option | RAM | Pour | Contre |
|---|---|---|---|
| **PostgreSQL simple (recommandé)** : un `StatefulSet` `postgres` officiel, volume `local-path` 5 Gi, `pg_dump` quotidien par `CronJob` | ~100-200 Mi | Évident, sans opérateur | Pas de haute disponibilité (inutile sur un nœud unique) |
| Opérateur CloudNativePG | ~100 Mi + instance | Sauvegardes et restauration gérées | Un opérateur de plus, sauvegardes pensées pour un stockage objet absent |

Configuration des realms :

| Option | Pour | Contre |
|---|---|---|
| **keycloak-config-cli (recommandé)** : `Job` ArgoCD qui applique des fichiers de realm versionnés ici, de façon idempotente | Les realms, clients et rôles sont dans Git, relus en PR | Un outil de plus (image `adorsys/keycloak-config-cli`, version alignée sur Keycloak) |
| Console d'administration à la main, procédure documentée | Rien à installer | Dérive invisible, rien à relire |
| Terraform (provider `keycloak`) | Déclaratif | Contraire à [ADR-001](ADR-001-terraform-scope.md) (Terraform limité à Kubernetes/Helm) |

## Décision proposée

- Feature `security/keycloak`, livrée par ArgoCD : **opérateur officiel +
  PostgreSQL simple + keycloak-config-cli**, versions épinglées.
- Exposition : tableau ci-dessus. Namespace `keycloak` ajouté à
  `public_namespaces`. IP `192.168.1.245` pour l'administration.
- Realms :
  - `master` : administration de Keycloak seulement, compte admin
    initial créé par l'opérateur humain puis protégé par 2FA ;
  - **un realm par application ou famille d'applications**, d'abord
    `inner-riddle` : ses utilisateurs, ses clients et ses pages de connexion
    sont isolés de ceux des futures applications. Si plusieurs applications
    doivent partager les mêmes comptes, elles partagent un realm (décision à
    prendre application par application) ;
  - realm `inner-riddle` : inscription libre désactivée (les comptes sont
    créés par l'opérateur), politique de mot de passe, 2FA TOTP proposée,
    client confidentiel `inner-riddle` (redirection
    `https://inner-riddle.cybermimic.com/api/auth/callback` uniquement).
- Secrets (Vault → External Secrets) : mot de passe de la base, compte
  admin initial, secret du client `inner-riddle` (lu aussi par
  l'application), identifiants SMTP.
- **E-mails** (mot de passe oublié, vérification d'adresse) : un relais
  SMTP est nécessaire. Sans lui, l'opérateur réinitialise les mots de passe
  depuis la console, et chacun change le sien depuis sa console de compte.
  Le fournisseur SMTP reste à choisir (offre e-mail OVH du domaine, ou
  service transactionnel).

## Conséquences

- Empreinte : ~1 Gi de RAM au repos (Keycloak, opérateur, PostgreSQL),
  5 Gi de disque.
- Keycloak arrêté : plus de nouvelle connexion. Les sessions déjà ouvertes
  dans inner-riddle continuent (cookie propre à l'application) jusqu'à leur
  expiration.
- Nouvelle surface publique : pages de connexion. Protection contre la
  force brute de Keycloak activée (verrouillage temporaire du compte).
- Les utilisateurs et leurs mots de passe vivent dans PostgreSQL, sur le
  disque du NucBox : sauvegarde `pg_dump` sur le même disque, même limite
  que les autres données tant qu'il n'y a pas de stockage objet.
- Un futur SSO des outils internes (ArgoCD, Vault) passerait par un realm
  dédié, servi sur l'adresse LAN seulement.
- Le realm `master` a sa propre `frontendUrl` pointée sur l'adresse admin
  (`https://192.168.1.245:8443`) : sans ça, Keycloak construit ses URLs
  OIDC (connexion de la console, 3p-cookies) avec le `hostname` public,
  qui n'expose pas `master`, et la console reste bloquée au chargement
  (rencontré le 2026-10-20, voir le README de la feature).

## Décision

La proposition est retenue telle quelle, avec les précisions suivantes :

- **Comptes** : créés par l'opérateur dans la console Keycloak.
  Inscription libre désactivée. Pas de compte de service de gestion des
  utilisateurs pour l'instant ; l'invitation depuis l'application viendra
  plus tard (ticket côté inner-riddle).
- **Rôles de realm** : **aucun**. Les droits (D-59, par carte : le
  créateur d'une carte en est le patient, celui avec qui elle est
  partagée en est le thérapeute) vivent dans l'application, pas dans
  Keycloak — lui donner des rôles métier reviendrait à donner à
  inner-riddle des droits d'administration sur Keycloak. Keycloak ne
  porte que l'identité (D-58).
- **Précision (2026-10-29) : aucun rôle métier, ni de realm ni de client,
  pour toutes les applications de la plateforme.** Chaque application
  stocke ses droits dans sa base et les donne elle-même (inner-riddle :
  partage d'une carte, droit de suggérer, D-59 et D-72 ; fact-check :
  ADR-003 de son dépôt). Les actions d'exploitation restent en ligne de
  commande dans le pod, protégées par l'accès au cluster. Le rôle client
  `reader` d'inner-riddle n'est pas déclaré dans le realm et sera retiré
  de l'application (IR-065).
- **E-mails** : aucun relais SMTP pour l'instant. Changement de mot de
  passe et 2FA par chaque utilisateur depuis sa console de compte
  Keycloak (lien déjà prévu dans l'application, IR-045) ; réinitialisation
  par l'opérateur depuis la console d'administration. Une feature « boîte
  mail » (domaine `cybermimic.com`, MX déjà chez OVH, SPF en place) est
  prévue plus tard pour lever cette limite.

Ce que l'application inner-riddle attend de cette feature (déjà prêt côté
chart, IR-045) : realm `inner-riddle`, client confidentiel `inner-riddle`
(redirection exacte `https://inner-riddle.cybermimic.com/api/auth/callback`,
post-logout `https://inner-riddle.cybermimic.com/`), émetteur
`https://auth.cybermimic.com/realms/inner-riddle`, secret du client dans
Vault (`inner-riddle/auth`, clé `oidc_client_secret`, même
`ExternalSecret` que `session_secret`). La bascule de
`gitops/apps/inner-riddle.yaml` (`auth.mode: oidc` + `oidc.*`) se fait
seulement une fois le realm et les comptes réels en place — un
changement distinct de celui-ci.
