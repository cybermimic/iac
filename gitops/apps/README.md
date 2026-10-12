# gitops/apps

Suivi par l'`Application` racine (app-of-apps, Terraform,
`features/delivery/argocd/terraform/main.tf`) — voir
[ADR-008](../../docs/adr/ADR-008-gitops-layout.md).

Un fichier = une `Application` ArgoCD = une feature (à partir de
`security/external-secrets`) ou une application business. Ajouter une
feature à ArgoCD = ajouter un fichier ici, dans la même PR que son code
sous `features/<domaine>/<feature>/gitops/`. Pas de `terraform apply` pour
ça.

Convention de synchronisation (ADR-008) :

- Feature de plateforme : `syncPolicy.automated` avec `selfHeal`, sans
  `prune`.
- Application business : synchronisation manuelle.
