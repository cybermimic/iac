# infrastructure

Ressources déclaratives gérées par Terraform : providers Kubernetes/Helm
uniquement. Voir [docs/adr/ADR-001-terraform-scope.md](../docs/adr/ADR-001-terraform-scope.md).

## Statut

Squelette — `environments/homelab/` sera ajouté à l'étape suivante, une
fois le provider Kubernetes configuré sans kubeconfig en dur (variable
d'environnement `KUBECONFIG` ou équivalent, jamais de chemin utilisateur
codé en dur).

## Structure prévue

```
infrastructure/
├── modules/            # modules réutilisables
└── environments/
    └── homelab/         # seul environnement aujourd'hui ; dev/staging/prod
                          # s'ajouteront via variables, pas via duplication
```

## Règles

- Pas de `local-exec`/`remote-exec`, pas de script shell embarqué.
- Pas de credentials/kubeconfig en dur dans les fichiers `.tf` ou `.tfvars`
  committés.
- Versions de providers et de charts Helm toujours explicites (jamais
  `latest`).
