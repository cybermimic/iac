# ADR-003 — Gestion des secrets

## Contexte

La plateforme manipule des secrets sensibles : credentials Vault (root
token, unseal keys), kubeconfigs, tokens GitHub, mots de passe de base de
données, clés privées.

## Problème

Un homelab est souvent développé et versionné avec le même niveau de
rigueur qu'un projet personnel, ce qui pousse à committer des secrets "par
commodité". Cela devient une fuite dès que le repo est poussé sur un
remote GitHub, même privé.

## Décision

Aucun secret n'est jamais committé en clair dans Git. En particulier,
n'apparaissent jamais dans le repo : mots de passe, tokens, clés privées,
kubeconfigs sensibles, Vault unseal/recovery keys, tokens GitHub.

Mécanismes utilisés selon le contexte :

- **Vault** — source de vérité pour les secrets applicatifs et de
  plateforme une fois bootstrapé (voir feature `security/vault`).
- **External Secrets Operator** — pont entre Vault et les Secrets
  Kubernetes, pour éviter de dupliquer des secrets manuellement.
- **SOPS/Age** — pour les secrets qui doivent malgré tout transiter par
  Git de façon chiffrée (ex. bootstrap avant que Vault existe).
- **Variables d'environnement** — pour les secrets nécessaires à
  l'exécution locale de Terraform/Ansible (jamais dans les fichiers
  `.tfvars` ou `group_vars` committés).

Le bootstrap initial de Vault (installation, initialisation, unseal) est
traité comme une opération distincte et documentée séparément du
déploiement normal — voir `features/security/vault/README.md`.

## Alternatives considérées

- **Secrets en clair dans des fichiers ignorés par git localement** :
  rejeté comme mécanisme principal — trop fragile face à une erreur de
  `.gitignore` ou un `git add -A`.

## Conséquences

- `.gitignore` du repo exclut explicitement les patterns de fichiers de
  secrets courants (kubeconfig, `.env`, clés, etc.) — filet de sécurité,
  pas garantie suffisante à elle seule.
- Pre-commit avec detection de secrets recommandé avant tout push (voir
  `.pre-commit-config.yaml`).
- Tout nouveau composant de plateforme doit documenter comment il reçoit
  ses secrets (Vault, ESO, ou variable d'environnement) avant d'être
  ajouté à `features/`.
