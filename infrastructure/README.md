# infrastructure

Ressources déclaratives gérées par Terraform : providers Kubernetes/Helm
uniquement. Voir [docs/adr/ADR-001-terraform-scope.md](../docs/adr/ADR-001-terraform-scope.md).

## Structure

```
infrastructure/
└── environments/
    └── homelab/         # seul environnement aujourd'hui ; assemble les
                          # modules de features/*/terraform/
```

Les modules réutilisables vivent dans `features/<domaine>/<feature>/terraform/`.
D'autres environnements (dev/staging/prod) s'ajouteront via variables, pas
via duplication. Le kubeconfig est toujours injecté via
`TF_VAR_kubeconfig_path`, jamais codé en dur.

## Règles

- Pas de `local-exec`/`remote-exec`, pas de script shell embarqué.
- Pas de credentials/kubeconfig en dur dans les fichiers `.tf` ou `.tfvars`
  committés.
- Versions de providers et de charts Helm toujours explicites (jamais
  `latest`).
