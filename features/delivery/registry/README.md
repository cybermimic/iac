# delivery/registry

## Objectif

Registre d'images OCI du homelab : **Zot**
([ADR-010](../../../docs/adr/ADR-010-container-registry.md)), sur
**`https://192.168.1.242`**. Les applications business y publient leurs
images (CI sur les runners du homelab) et le cluster les y télécharge.
Jamais public : cette IP n'est pas redirigée par la Freebox
([ADR-009](../../../docs/adr/ADR-009-public-exposure.md)).

Livré par **ArgoCD** ([ADR-008](../../../docs/adr/ADR-008-gitops-layout.md)) :
`gitops/apps/registry.yaml` (chart officiel Zot + manifestes de
`gitops/` ici).

## Ce qui est déployé

| Élément | Détail |
|---|---|
| Zot v2.1.22 (chart `zot` 0.1.128) | StatefulSet, 1 réplica, namespace `registry` |
| Service `LoadBalancer` | `192.168.1.242:443` → port 5000 du conteneur |
| TLS | Terminé par Zot ; `Certificate` `zot-tls` de la CA interne, **IP uniquement** |
| Authentification | htpasswd (`ExternalSecret` `zot-htpasswd` ← Vault `secret/registry/htpasswd`) |
| Droits | `ci-push` : lecture + écriture + suppression ; `cluster-pull` : lecture seule ; anonyme : rien |
| Stockage | Volume `local-path` 20 Gi (`/var/lib/registry`) |
| Rétention | 10 dernières versions par dépôt, images sans étiquette supprimées, nettoyage quotidien (délai 24 h) |

La configuration Zot (dans `gitops/apps/registry.yaml`) a été validée
par `zot verify` (v2.1.22) avant d'être livrée.

## Dépendances

- `networking/metallb` — IP `192.168.1.242`.
- `security/cert-manager` — ClusterIssuer `homelab-ca`.
- `security/external-secrets` + Vault — htpasswd (`secret/registry/htpasswd`),
  rangé par l'opérateur ([plan inner-riddle](../../../docs/plans/inner-riddle.md),
  commandes A et B). Sans lui, le pod reste en attente de son secret.
- `storage/local-path` — volume des images.
- **Confiance dans la CA sur chaque nœud** : playbook `ansible/` ci-dessous.

## Ressources approximatives

Requests 50m CPU / 64 Mi, limits 500m / 512 Mi ; ~50-150 Mi au repos.
Disque : 20 Gi réservés sur le NucBox.

## Comptes

| Compte | Usage | Mot de passe |
|---|---|---|
| `ci-push` | CI (workflow `Release` des dépôts privés) | Vault `secret/registry/push`, recopié dans les secrets GitHub du dépôt |
| `cluster-pull` | `imagePullSecret` des applications | Vault `secret/registry/pull`, fourni par External Secrets |

Changer un mot de passe : régénérer le htpasswd et les entrées Vault
(commandes B du plan), External Secrets met le Secret à jour (≤ 1 h, ou
annotation `force-sync`), puis redémarrer Zot (`kubectl -n registry
rollout restart statefulset/registry-zot`).

## Confiance dans la CA interne (nœuds et postes)

containerd doit faire confiance à « Homelab Root CA » pour télécharger
depuis `192.168.1.242`. Playbook (configuration d'hôte,
[ADR-001](../../../docs/adr/ADR-001-terraform-scope.md)) : installe la CA
dans le magasin système et redémarre containerd (les conteneurs en cours
ne sont pas interrompus).

```bash
cd features/delivery/registry/ansible
ansible-playbook -i ../../../../bootstrap/ansible/inventory/hosts.yml playbook.yml -c local --check --diff -K   # dry-run
ansible-playbook -i ../../../../bootstrap/ansible/inventory/hosts.yml playbook.yml -c local -K
```

(`-c local` depuis le NucBox lui-même ; `-K` = mot de passe sudo.)
Postes qui poussent des images à la main : scripts
`security/cert-manager/clients`, puis redémarrer Docker.

## Installation

Livrée par ArgoCD au push sur `main` (Application `registry`,
synchronisation automatique). Vérification :

```bash
kubectl -n argocd get application registry          # Synced, Healthy
kubectl -n registry get externalsecret,certificate   # SecretSynced / READY True
kubectl -n registry get pods,svc                     # Running, EXTERNAL-IP 192.168.1.242
curl --cacert docs/homelab-root-ca.crt https://192.168.1.242/v2/   # 401 attendu (authentification requise)
```

## Upgrade

Lire les release notes de Zot et du chart, monter `targetRevision` dans
`gitops/apps/registry.yaml`, vérifier la configuration avec `zot verify`
de la nouvelle version, PR / commit : ArgoCD synchronise.

## Rollback

Revenir à la révision précédente de `gitops/apps/registry.yaml` (git
revert). Les images (volume) ne sont pas touchées.

## Troubleshooting

- Pod `ContainerCreating` : `kubectl -n registry describe pod` — secret
  `zot-htpasswd` absent (ExternalSecret en erreur : chemin Vault ou
  politique `external-secrets`) ou `zot-tls` pas encore émis.
- `x509: certificate signed by unknown authority` au téléchargement d'une
  image → la CA n'est pas approuvée par containerd sur le nœud : lancer le
  playbook.
- `401` / `403` au `docker push` → compte ou droits (`ci-push` seul peut
  écrire) ; `docker login 192.168.1.242` d'abord.
- Disque plein : vérifier la rétention (`kubectl -n registry logs
  statefulset/registry-zot | grep -i retention`) et la taille du volume.
