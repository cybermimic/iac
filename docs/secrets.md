# Registre des secrets

Inventaire de **tous** les secrets de la plateforme : où ils vivent, qui les
lit, et comment les recréer. Aucune valeur ici, seulement des noms et des
chemins ([ADR-003](adr/ADR-003-secret-management.md)). Tout nouveau secret
est ajouté à ce registre dans le même changement (CLAUDE.md).

État au 2026-10-27, relevé dans les manifestes du repo et la liste des
Secrets du cluster (noms et types seulement, jamais les valeurs).

## Trois natures de secrets

| Nature | Définition | Après une reconstruction |
|---|---|---|
| **Racine** | Protège tout le reste ; détenue par l'opérateur, hors ligne | Jamais régénérée par une machine. Perdue = tout ce qu'elle protège est perdu ou à refaire |
| **Générée** | Valeur aléatoire que personne n'a besoin de connaître | Peut être régénérée sur une infra vierge. **Mais** si des données sont restaurées (base, volume), il faut l'ancienne valeur |
| **Tiers** | Émise par un service extérieur (GitHub, API publiques) | À restaurer d'une sauvegarde, ou à réémettre à la main chez le tiers |

## 1. Racines de confiance (hors Vault)

| Secret | Où | Sauvegarde aujourd'hui | Si perdu |
|---|---|---|---|
| Clés d'unseal et root token de Vault | Opérateur, hors ligne | Chez l'opérateur | Vault et tout son contenu définitivement illisibles |
| **Clé privée de la CA interne** « Homelab Root CA » | Secret Kubernetes `cert-manager/homelab-root-ca` (créé par cert-manager, Terraform `security/cert-manager`) | **Aucune** tant que l'opérateur n'a pas fait l'export chiffré ([procédure](../features/security/cert-manager/README.md#sauvegarder-la-clé-de-la-ca-adr-014-p3)) | Nouvelle CA : `docs/homelab-root-ca.crt` et les empreintes épinglées des scripts clients changent, certificat à réinstaller sur chaque poste |
| PKI du cluster et kubeconfig administrateur | NucBox, `/etc/kubernetes/pki`, `/etc/kubernetes/admin.conf` | Aucune | Nouveau cluster, nouveaux kubeconfigs |
| **Clé privée `age` des sauvegardes** (et de la copie de la CA) | Poste de l'opérateur, gestionnaire de mots de passe + copie papier | Chez l'opérateur | Toutes les sauvegardes chiffrées illisibles ([ADR-016](adr/ADR-016-backups.md)) ; la clé **publique** est dans `features/storage/backups/age-recipients.txt` |
| Clé SSH de l'opérateur (GitHub + NucBox) | Poste de l'opérateur, `~/.ssh/github` | Chez l'opérateur | Accès à refaire (dette connue : une seule clé pour deux usages, voir [operations.md](operations.md)) |

L'état Terraform (`/home/hoarauv/.homelab-platform-state/` sur le NucBox,
[ADR-005](adr/ADR-005-terraform-state.md)) n'est pas un secret en soi, mais
peut contenir des valeurs sensibles rendues par les providers : à traiter
comme tel (non vérifié en détail).

## 2. Secrets dans Vault (`secret/`, kv-v2)

Lus par External Secrets via le rôle `external-secrets`, dont la policy est
versionnée : [`features/security/vault/policies/external-secrets.hcl`](../features/security/vault/policies/external-secrets.hcl).

| Chemin | Propriétés | Nature | Consommateurs | Recréer |
|---|---|---|---|---|
| `inner-riddle/auth` | `session_secret` ; `oidc_client_secret` ; `accounts` (plus lu depuis le mode `oidc`) | Générée | inner-riddle ; `keycloak-config-cli` (même `oidc_client_secret` des deux côtés) | [plan inner-riddle](plans/inner-riddle.md), commandes E ; [Keycloak](../features/security/keycloak/README.md) |
| `registry/push` | `username`, `password` | Générée | Copiés dans les secrets GitHub du dépôt inner-riddle (`REGISTRY_USER`, `REGISTRY_PASSWORD`) | [plan inner-riddle](plans/inner-riddle.md), commandes B |
| `registry/pull` | `username`, `password` | Générée | `registry-pull` (pull secret) des namespaces applicatifs | idem |
| `registry/htpasswd` | `htpasswd` (empreintes bcrypt de push et pull) | Générée, **dérivée** de `registry/push` et `registry/pull` | Zot | idem (les trois ensemble) |
| `actions-runners/github-app` | `github_app_id`, `github_app_installation_id`, `github_app_private_key` | **Tiers** (GitHub App) | ARC, namespace `arc-runners` | Nouvelle clé privée dans GitHub (organisation → GitHub Apps), [plan inner-riddle](plans/inner-riddle.md) commandes D |
| `argocd/repo-inner-riddle` | `ssh_private_key` | **Tiers** : clé générée localement, partie publique enregistrée comme clé de déploiement GitHub | ArgoCD | [plan inner-riddle](plans/inner-riddle.md), commandes C |
| `keycloak/admin` | `username`, `password` | Générée | Keycloak, `keycloak-config-cli` | [Keycloak](../features/security/keycloak/README.md) |
| `keycloak/postgres` | `username`, `password` | Générée, **liée aux données** (base de Keycloak : comptes, realms) | PostgreSQL de Keycloak | idem ; restaurer la base demande l'ancienne valeur |

### Prévus par des PR ouvertes (pas encore dans Vault)

| Chemin | Propriétés | Nature | PR |
|---|---|---|---|
| `object-storage/garage` | `rpc_secret` | Générée | iac #25 |
| `fact-check/s3` | `access_key_id`, `secret_access_key` | Générée, **liée aux données** (clé importée dans Garage) | iac #25 |
| `fact-check/postgres` | `password` (hexadécimal) | Générée, **liée aux données** | iac #26 |
| `argocd/repo-fact-check` | `ssh_private_key` | Tiers (clé de déploiement) | iac #26 |
| `fleet-manager/ssh` | `ssh_private_key` | Générée ; partie publique déployée par Ansible sur les machines gérées | iac #28 |
| `mail/smtp` | `host`, `port`, `starttls`, `ssl`, `username`, `password`, `from`, `from_name` | **Tiers** (compte SMTP du fournisseur, OVH d'abord) | iac #21 (ADR-013, envoi d'e-mails) |

Chaque PR ajoutera aussi son chemin à la policy versionnée (`fact-check/*`,
`object-storage/*`, `fleet-manager/*`).

## 3. Secrets créés par les composants eux-mêmes (hors Vault)

Régénérés automatiquement sur une infra vierge ; rien à faire.

| Secret Kubernetes | Créé par | Remarque |
|---|---|---|
| `argocd/argocd-initial-admin-secret`, `argocd/argocd-secret`, `argocd/argocd-redis` | ArgoCD | Nouveau mot de passe admin ArgoCD après reconstruction |
| `cert-manager/letsencrypt-account-key`, `cert-manager/letsencrypt-staging-account-key` | cert-manager | Nouveau compte Let's Encrypt (limites de débit de Let's Encrypt à garder en tête) |
| `cert-manager/cert-manager-webhook-ca`, `external-secrets/external-secrets-webhook`, `metallb-system/metallb-webhook-cert`, `metallb-system/metallb-memberlist` | Les composants | Internes |
| `*-tls` (`vault-listener-tls`, `zot-tls`, `argocd-server-tls`, `keycloak-*-tls`, `inner-riddle-tls`) | cert-manager (CA interne ou Let's Encrypt) | Réémis seuls, **à condition** que la CA interne soit restaurée (sinon voir section 1) |
| `arc-systems/*-listener-config`, `arc-runners/*-runner-*` | ARC | Jetons d'enregistrement éphémères |

## 4. Secrets hors du cluster

| Où | Secret | Source |
|---|---|---|
| Dépôt GitHub `cybermimic/inner-riddle` | `REGISTRY_USER`, `REGISTRY_PASSWORD` | Copie de `secret/registry/push` |
| Dépôt GitHub `cybermimic/fact-check` (prévu, iac #26) | `REGISTRY_USER`, `REGISTRY_PASSWORD` | Copie de `secret/registry/push` |
| Inventaire Ansible local (`bootstrap/ansible/inventory/hosts.yml`, ignoré par git) | Aucun secret ; mot de passe sudo saisi à chaque exécution (`-K`) | — |

## 5. Ce qu'une reconstruction perdrait aujourd'hui

Vault stocke tout sur un volume local-path (`storage "file"`), **sans
sauvegarde**. Sans le disque du NucBox :

- **perdu sans retour** : la CA interne (section 1), les valeurs liées aux
  données (`keycloak/postgres` : la base de Keycloak resterait inutilisable
  si on la restaurait) ;
- **à réémettre à la main** : la clé privée de la GitHub App, les clés de
  déploiement ArgoCD ;
- **à régénérer à la main**, une quinzaine de `vault kv put` éparpillés dans
  les README : tout le reste de la section 2.

Les options pour automatiser la régénération, sauvegarder Vault et
conserver la CA sont dans l'[ADR-014](adr/ADR-014-secrets-for-rebuild.md)
(proposée, à trancher).
