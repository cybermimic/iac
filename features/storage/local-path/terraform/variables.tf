variable "namespace" {
  description = "Namespace où tourne le provisioner"
  type        = string
  default     = "local-path-storage"
}

variable "provisioner_version" {
  description = "Tag d'image rancher/local-path-provisioner (toujours explicite, jamais latest)"
  type        = string
  default     = "v0.0.31"
}

variable "host_path" {
  description = "Répertoire sur le nœud où les volumes sont provisionnés"
  type        = string
  default     = "/opt/local-path-provisioner"
}

variable "set_as_default_storage_class" {
  description = "Marque cette StorageClass comme celle par défaut du cluster"
  type        = bool
  default     = true
}

variable "tolerate_control_plane_taint" {
  description = <<-EOT
    Ajoute une toleration control-plane au provisioner. Nécessaire tant que
    le cluster est single-node (voir features/networking/metallb pour le
    même besoin). À repasser à false une fois un nœud worker dédié ajouté.
  EOT
  type        = bool
  default     = true
}
