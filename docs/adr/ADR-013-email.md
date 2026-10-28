# ADR-013 — Envoi d'e-mails (contrat SMTP, OVH d'abord)

**Statut : Proposée** (2026-10-26).

## Contexte

Deux consommateurs ont besoin d'envoyer des e-mails :

- **Keycloak** ([ADR-012](ADR-012-identity-keycloak.md)) : « mot de passe
  oublié », vérification d'adresse. Le realm `inner-riddle` affiche déjà le
  lien « Mot de passe oublié ? » (`resetPasswordAllowed: true`), qui ne
  peut rien envoyer tant qu'aucun relais n'est configuré.
- **inner-riddle** : inviter son thérapeute depuis l'application (ticket
  IR-057 du dépôt inner-riddle).

État constaté du domaine `cybermimic.com` (DNS chez OVH) :

| Enregistrement | Valeur | État |
|---|---|---|
| MX | `mx1/mx2/mx3.mail.ovh.net` | ✅ |
| SPF | `v=spf1 include:mx.ovh.com -all` | ✅ (n'autorise qu'OVH) |
| DKIM | aucun | ❌ à activer |
| DMARC | aucun | ❌ à créer |

Contraintes :

- un MTA auto-hébergé qui livre lui-même est exclu : Free bloque le port 25
  sortant, et une IP résidentielle est mal notée par les filtres anti-spam ;
- l'opérateur veut **OVH pour commencer**, mais **sans qu'aucun
  consommateur ne dépende d'OVH** : changer de fournisseur ne doit toucher
  ni Keycloak ni l'application.

## Options

| | Option | Empreinte | Changer de fournisseur |
|---|---|---|---|
| A | **Contrat SMTP dans Vault** : un secret neutre lu par chaque consommateur | 0 | modifier le secret (+ DNS) |
| B | **Relais SMTP interne** (Postfix, namespace `mail`) : les consommateurs envoient au relais, seul le relais connaît le fournisseur | ~30 Mi, un composant de plus à maintenir et à fermer (jamais de relais ouvert) | modifier la configuration du relais |
| C | Service transactionnel (Brevo, Scaleway TEM…) à la place d'OVH | 0 | — (c'est un fournisseur, pas une abstraction) |

C n'est pas une alternative à A ou B : c'est un fournisseur possible
**derrière** eux, plus tard (meilleure délivrabilité, suivi des envois,
mais les adresses des utilisateurs passent par un tiers de plus).

## Décision proposée

**Option A, fournisseur OVH.** B reste possible plus tard sans toucher aux
consommateurs : il suffira que le contrat pointe vers le relais.

### Le contrat

Un seul chemin Vault, `secret/mail/smtp` (kv-v2), propriétés neutres :

| Propriété | Exemple (OVH) | Rôle |
|---|---|---|
| `host` | `ssl0.ovh.net` | serveur d'envoi |
| `port` | `587` | port de soumission |
| `starttls` | `true` | STARTTLS sur `port` (587) ; `false` avec `ssl=true` pour 465 |
| `ssl` | `false` | TLS implicite (465) |
| `username` | `no-reply@cybermimic.com` | compte d'envoi |
| `password` | — (secret) | mot de passe du compte |
| `from` | `no-reply@cybermimic.com` | adresse d'expéditeur |
| `from_name` | `Inner Riddle` | nom affiché |

Règles :

- chaque consommateur a **son propre `ExternalSecret`** vers ce chemin (un
  Secret Kubernetes est namespacé, comme pour `inner-riddle/auth`) et ne
  contient **aucune** valeur propre à OVH ;
- aucun nom de fournisseur dans les manifestes des consommateurs ni dans le
  code de l'application ;
- changer de fournisseur = nouveau compte chez lui, `vault kv put
  secret/mail/smtp …`, mise à jour SPF/DKIM, puis redémarrage des
  consommateurs (ou attente du `refreshInterval`).

### Consommateurs

- **Keycloak** : bloc `smtpServer` du realm `inner-riddle`, appliqué par
  keycloak-config-cli avec la substitution `$(env:…)` déjà utilisée pour le
  secret du client ; variables injectées dans le Job depuis un
  `ExternalSecret` `mail-smtp` du namespace `keycloak`.
- **inner-riddle** : dans son dépôt, un port d'envoi (`MailSender`) et un
  adaptateur SMTP qui lit des variables d'environnement neutres
  (`SMTP_HOST`, `SMTP_PORT`…) ; le chart les remplit depuis le même chemin
  Vault (IR-057).

### Fournisseur initial : OVH

- Compte d'envoi `no-reply@cybermimic.com` sur l'offre e-mail OVH liée au
  domaine, réservé à l'envoi.
- DKIM : activé dans le manager OVH (enregistrements créés par OVH).
- DMARC : `_dmarc.cybermimic.com` `v=DMARC1; p=none; rua=mailto:<adresse de
  l'opérateur>` d'abord, durci en `p=quarantine` après quelques semaines de
  rapports propres.

## Étapes

Légende : 🤖 = l'agent ; 👤 = l'opérateur.

1. 👤 Valider cette ADR (statut → Acceptée).
2. 👤 Manager OVH : créer `no-reply@cybermimic.com`, activer DKIM, créer
   l'enregistrement DMARC.
3. 👤 Vault : ajouter `secret/data/mail/*` à la policy `external-secrets`
   (lire la policy d'abord et reporter **tous** les chemins existants, voir
   CLAUDE.md), puis ranger le contrat (mot de passe par l'entrée standard,
   jamais en argument).
4. 🤖 Keycloak : `ExternalSecret` `mail-smtp`, variables du Job,
   `smtpServer` du realm ; README de la feature mis à jour.
5. 👤 Test : « Test connection » dans la console d'administration (realm
   `inner-riddle` → Realm settings → Email), puis un « mot de passe oublié »
   réel ; vérifier SPF/DKIM/DMARC `pass` dans les en-têtes reçus.
6. 🤖 inner-riddle : IR-057 (port `MailSender`, adaptateur SMTP, valeurs du
   chart), dans son dépôt.

## Conséquences

- Aucune RAM de plus ; un secret Vault de plus.
- Quotas d'envoi de l'offre OVH : modestes, à vérifier dans le manager ;
  largement suffisants pour quelques comptes. S'ils deviennent gênants :
  option C derrière le même contrat.
- Le compte `no-reply` ne reçoit rien d'utile : les réponses éventuelles
  arrivent dans une boîte que personne ne lit (à rediriger vers l'opérateur
  si besoin).
- Délivrabilité : dépend de DKIM et DMARC (étape 2). Sans eux, les messages
  de Keycloak risquent de finir en indésirables.
