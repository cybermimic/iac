# infrastructure/environments/homelab

Environnement Terraform racine pour le cluster homelab actuel (single-node,
NucBoxG3-Plus). Assemble les modules de `features/*/terraform/`.

## Objectif

Point d'entrée unique `terraform plan`/`apply` pour l'ensemble des features
de plateforme déployées sur ce cluster.

## Dépendances

- Cluster Kubernetes accessible via un kubeconfig valide.
- Providers Terraform `kubernetes` et `helm` (installés automatiquement par
  `terraform init`).

## Inputs

Voir `variables.tf`. Copier `terraform.tfvars.example` en `terraform.tfvars`
pour les valeurs non sensibles (ex: `metallb_ip_range`). `kubeconfig_path`
ne doit jamais être écrit dans un fichier committé — toujours via
`TF_VAR_kubeconfig_path`.

## Installation

```bash
export TF_VAR_kubeconfig_path=$KUBECONFIG   # ou chemin explicite vers le kubeconfig
cp terraform.tfvars.example terraform.tfvars # puis ajuster metallb_ip_range
terraform init
terraform plan
terraform apply
```

## Upgrade

`terraform plan` avant tout `apply` — vérifier le diff, en particulier sur
les versions de charts Helm (toujours pinnées, jamais `latest`).

## Rollback

Revenir à la révision précédente du repo (`git checkout <rev> -- infrastructure features`)
et rejouer `terraform apply`, ou cibler une ressource précise avec
`terraform apply -target=...` / `terraform destroy -target=...` en dernier
recours.

## Troubleshooting

Voir le README de chaque feature sous `features/*/README.md`.

## État du state Terraform (limitation actuelle, à formaliser)

Aucun backend distant n'est encore configuré — le `terraform.tfstate` est
local, sur le NucBoxG3-Plus (`/home/hoarauv/.homelab-platform-state/`),
synchronisé manuellement depuis ce repo à chaque changement. Ne pas lancer
`terraform apply` depuis un autre répertoire/état sous peine de
désynchronisation. Contexte complet, procédure et trajectoire :
[ADR-005](../../../docs/adr/ADR-005-terraform-state.md) et
[docs/operations.md](../../../docs/operations.md).
