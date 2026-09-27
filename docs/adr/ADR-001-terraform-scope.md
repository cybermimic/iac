# ADR-001 — Scope de Terraform

## Contexte

La plateforme a besoin d'un outil déclaratif pour gérer les ressources
Kubernetes et les releases Helm. Terraform pourrait aussi, techniquement,
piloter la configuration système des machines via `local-exec`/`remote-exec`.

## Problème

Utiliser Terraform à la fois comme gestionnaire de ressources déclaratives
et comme système de configuration Linux général mélange deux modèles
(déclaratif vs impératif/idempotent) et pousse vers des scripts shell
fragiles intégrés dans le state Terraform.

## Décision

Terraform est utilisé uniquement pour :

- les ressources Kubernetes (namespaces, RBAC, CRDs, etc.) ;
- les releases Helm ;
- la configuration de composants de plateforme exposée via un provider ;
- d'éventuelles ressources d'autres providers ajoutés plus tard.

Terraform n'est **jamais** utilisé pour :

- installer des paquets système ;
- configurer kubeadm/kubelet/containerd ;
- exécuter des scripts shell via `local-exec`/`remote-exec`.

Ansible est responsable de tout ce qui touche à la configuration de la
machine hôte (voir `bootstrap/`).

## Alternatives considérées

- **Terraform pour tout** (y compris provisioning machine via provisioners) :
  rejeté — fragile, non idempotent de manière fiable, mélange les
  responsabilités.
- **Pulumi/Crossplane** : non retenu pour l'instant, Terraform + providers
  Kubernetes/Helm suffit au besoin actuel et reste largement documenté.

## Conséquences

- Deux outils à maintenir (Terraform + Ansible) mais avec des frontières
  claires et testables séparément (`terraform validate` / `ansible-lint`).
- Le state Terraform ne contient jamais de kubeconfig en dur — le provider
  Kubernetes/Helm est configuré via variables d'environnement
  (`KUBECONFIG` ou équivalent).
