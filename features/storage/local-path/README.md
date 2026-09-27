# storage/local-path

## Objectif

Fournit une `StorageClass` par défaut (`local-path`, provisioning
dynamique sur disque local du nœud) pour tout workload ayant besoin de
stockage persistant — en particulier Vault. Aucune `StorageClass` n'existe
sur le cluster tant que cette feature n'est pas déployée.

## Dépendances

Aucune.

## Ressources approximatives

Négligeables — un seul pod `local-path-provisioner` (~20m CPU / 30Mi RAM),
plus un pod `helper-pod` éphémère à chaque création/suppression de volume.

## Inputs

| Variable | Description | Défaut |
|---|---|---|
| `namespace` | Namespace du provisioner | `local-path-storage` |
| `provisioner_version` | Tag d'image `rancher/local-path-provisioner` | `v0.0.31` |
| `host_path` | Répertoire hôte où les volumes sont créés | `/opt/local-path-provisioner` |
| `set_as_default_storage_class` | Marque la StorageClass par défaut | `true` |
| `tolerate_control_plane_taint` | Toleration control-plane (cluster single-node) | `true` |

## Outputs

`namespace`, `storage_class_name`.

## Écarts par rapport au manifeste upstream

Traduit depuis le manifeste officiel
[`local-path-storage.yaml`](https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.31/deploy/local-path-storage.yaml)
en ressources Terraform typées (pas de `local-exec`, pas de `kubectl apply`
caché). Deux écarts volontaires :

- Toleration control-plane ajoutée au Deployment — sans elle, le pod ne
  schedule pas sur un cluster single-node (même cause que le bug MetalLB,
  voir `features/networking/metallb/README.md`).
- Image `helperPod.yaml` pinnée en `busybox:1.36` — l'upstream la laisse
  sans tag (`latest` implicite), ce que ce repo interdit pour tout
  composant, même éphémère.

## Installation

Voir `infrastructure/environments/homelab/README.md` — cette feature est
assemblée comme les autres via le même `terraform apply`.

## Upgrade

Monter `provisioner_version` après avoir vérifié le changelog upstream —
`terraform plan` avant `apply`.

## Rollback

`terraform apply` avec l'ancienne valeur de `provisioner_version`. Les
volumes déjà provisionnés (fichiers sous `host_path` sur le nœud) ne sont
pas affectés par un rollback du provisioner lui-même.

## Troubleshooting

- PVC bloqué en `Pending` → `volume_binding_mode = WaitForFirstConsumer`
  signifie que le volume n'est créé qu'au scheduling du pod consommateur ;
  vérifier que le pod consommateur lui-même schedule correctement.
- Vérifier que `local-path-provisioner` est bien `Running` :
  `kubectl -n local-path-storage get pods`.
