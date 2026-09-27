variable "namespace" {
  description = "Namespace où Vault est installé"
  type        = string
  default     = "vault"
}

variable "chart_version" {
  description = "Version du chart Helm hashicorp/vault (toujours explicite, jamais latest)"
  type        = string
  default     = "0.34.1"
}

variable "storage_class_name" {
  description = "StorageClass utilisée pour le volume de données Vault (voir features/storage/local-path)"
  type        = string
  default     = "local-path"
}

variable "data_volume_size" {
  description = "Taille du volume persistant pour le backend de stockage file"
  type        = string
  default     = "1Gi"
}

variable "requests_cpu" {
  type    = string
  default = "100m"
}

variable "requests_memory" {
  type    = string
  default = "128Mi"
}

variable "limits_cpu" {
  type    = string
  default = "500m"
}

variable "limits_memory" {
  type    = string
  default = "512Mi"
}

variable "ui_enabled" {
  description = "Active l'UI web Vault (toujours en ClusterIP, pas d'exposition externe tant qu'il n'y a pas d'ingress+TLS)"
  type        = bool
  default     = true
}

variable "tolerate_control_plane_taint" {
  description = <<-EOT
    Ajoute une toleration control-plane au pod Vault. Nécessaire tant que
    le cluster est single-node (même besoin que networking/metallb et
    storage/local-path). À repasser à false une fois un nœud worker dédié
    ajouté.
  EOT
  type        = bool
  default     = true
}
