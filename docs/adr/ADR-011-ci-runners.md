# ADR-011 — Runners GitHub Actions dans le cluster

**Statut : Proposé** (2026-10-12) — à valider par l'opérateur avant toute
implémentation.

## Contexte

Les dépôts de l'organisation utilisent GitHub Actions. Les vérifications
(lint, tests) tournent sur les runners hébergés par GitHub, mais la
**publication des images** vers `registry.homelab.lan`
([ADR-010](ADR-010-container-registry.md)) exige un runner dans le LAN. La
CI d'inner-riddle exécute chaque étape via Docker Compose : le runner doit
fournir Docker.

## Options

| Option | RAM | Pour | Contre |
|---|---|---|---|
| **A. Actions Runner Controller, *runner scale set* en mode Docker-in-Docker (recommandé)** | contrôleur ~50-100 Mi ; runner 0 au repos, ~1-3 Gi pendant un job | Solution officielle GitHub ; runners éphémères (un pod neuf par job) ; mise à zéro au repos ; géré comme les autres features | Le conteneur DinD est privilégié ; plusieurs composants (contrôleur, listener, runners) |
| B. Runner unique en service systemd sur le NucBox (Ansible) | ~100 Mi + jobs | Très simple | Runner persistant sur l'hôte ; l'accès Docker équivaut à root sur le nœud ; état qui s'accumule entre jobs |
| C. Pas de runner : publication manuelle | 0 | Rien à installer | Étape humaine à chaque version, pas de traçabilité CI |

## Décision proposée

**Option A**, feature `delivery/actions-runners` :

- un *runner scale set* par dépôt qui en a besoin (d'abord
  `cybermimic/inner-riddle`), `minRunners: 0`, `maxRunners: 1` (contrainte
  mémoire) ; libellé `homelab` utilisé par `runs-on` ;
- authentification par une **GitHub App** de l'organisation (droits
  minimaux, renouvellement de jeton automatique), clé privée dans Vault,
  matérialisée par External Secrets ;
- **jamais pour un dépôt public** (`cybermimic/iac` compris) : une PR
  venant d'un fork exécuterait du code arbitraire dans le homelab. Le
  groupe de runners est restreint aux dépôts privés listés ;
- les jobs de vérification restent sur les runners GitHub ; seuls les
  jobs qui ont besoin du LAN (publication) ciblent `homelab`.

Option C en transition, tant que A n'est pas en place.

## Conséquences

- Dépend de `security/external-secrets` (clé de la GitHub App) et de la
  confiance dans la CA interne côté DinD (ADR-010).
- Les runners ont accès au réseau du LAN : la politique réseau de leur
  namespace limite les sorties au registre et à Internet.

## Décision

*À compléter après validation.*
