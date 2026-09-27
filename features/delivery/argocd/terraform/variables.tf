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

variable "hostname" {
  description = "Nom DNS sous lequel ArgoCD est publié (ex: argocd.homelab.lan)"
  type        = string
}

variable "ingress_class_name" {
  description = "IngressClass à utiliser (output de networking/ingress)"
  type        = string
}

variable "cluster_issuer_name" {
  description = "ClusterIssuer cert-manager qui signe le certificat (output de security/cert-manager)"
  type        = string
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
