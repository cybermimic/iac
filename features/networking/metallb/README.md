# networking/metallb

## Objectif

Fournit des IP LAN routables (`type: LoadBalancer`) aux Services Kubernetes
sur un cluster bare-metal, via MetalLB en mode L2 (ARP).

## Dépendances

Aucune — c'est la première feature réseau, prérequis pour `networking/ingress`.

## Ressources approximatives

CPU/RAM négligeables (~50m CPU / 50Mi RAM à eux deux pour `controller` et
`speaker`). Compatible avec la contrainte 16 Go RAM du cluster actuel.

## Inputs

| Variable | Description | Défaut |
|---|---|---|
| `namespace` | Namespace d'installation | `metallb-system` |
| `chart_version` | Version du chart Helm | `0.14.9` |
| `ip_range` | Plage d'IP LAN pour les LoadBalancer (hors plage DHCP du routeur) | — (requis) |
| `tolerate_control_plane_taint` | Ajoute une toleration control-plane (cluster single-node) | `true` |

## Outputs

`namespace`, `ip_range`.

## Installation

```bash
cd infrastructure/environments/homelab
TF_VAR_kubeconfig_path=$KUBECONFIG terraform init
TF_VAR_kubeconfig_path=$KUBECONFIG terraform plan
TF_VAR_kubeconfig_path=$KUBECONFIG terraform apply
```

## Historique

Une ancienne installation manuelle (manifeste brut `v0.14.8`, cassée) a
été remplacée par ce module Terraform/Helm. MetalLB est aujourd'hui
entièrement géré par Terraform (release Helm + `IPAddressPool` +
`L2Advertisement`) — ne plus appliquer de manifeste MetalLB à la main.

## Upgrade

Monter `chart_version`, `terraform plan` puis `apply`. Le chart gère les
migrations de CRDs.

## Rollback

`terraform apply` avec l'ancienne valeur de `chart_version`, ou
`terraform destroy -target=module.metallb` en dernier recours (coupe tous
les Services LoadBalancer le temps de la réinstallation).

## Troubleshooting

- `speaker` bloqué en `ContainerCreating` → vérifier que le secret
  `memberlist` existe (`kubectl -n metallb-system get secret memberlist`).
- `controller` bloqué en `Pending` → vérifier les tolerations vs les taints
  du/des nœuds (`kubectl describe node <node> | grep -A3 Taints`).
