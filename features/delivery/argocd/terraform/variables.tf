variable "namespace" {
  description = "Namespace où ArgoCD est installé"
  type        = string
  default     = "argocd"
}

variable "chart_version" {
  description = "Version du chart Helm argo/argo-cd (toujours explicite, jamais latest)"
  type        = string
  default     = "10.9.2"
}

variable "load_balancer_ip" {
  description = "IP LAN fixe d'ArgoCD (Service LoadBalancer, plage MetalLB). ArgoCD : https://<ip>."
  type        = string
}

variable "cluster_issuer_name" {
  description = "ClusterIssuer cert-manager qui signe le certificat d'argocd-server (output de security/cert-manager)"
  type        = string
}

variable "root_app_repo_url" {
  description = "Repo Git suivi par l'Application racine (app-of-apps, voir ADR-008)"
  type        = string
  default     = "https://github.com/cybermimic/iac.git"
}

variable "root_app_repo_revision" {
  description = "Branche/tag suivi par l'Application racine"
  type        = string
  default     = "main"
}

variable "root_app_path" {
  description = "Chemin dans le repo contenant les manifestes Application (une par feature/app)"
  type        = string
  default     = "gitops/apps"
}

variable "tolerate_control_plane_taint" {
  description = <<-EOT
    Ajoute une toleration control-plane à tous les pods ArgoCD
    (global.tolerations). Nécessaire tant que le cluster est single-node. À
    repasser à false une fois un nœud worker dédié ajouté.
  EOT
  type        = bool
  default     = true
}
