variable "namespace" {
  description = "Namespace où Traefik est installé"
  type        = string
  default     = "traefik"
}

variable "chart_version" {
  description = "Version du chart Helm traefik/traefik (toujours explicite, jamais latest)"
  type        = string
  default     = "41.6.0"
}

variable "load_balancer_ip" {
  description = <<-EOT
    IP LAN fixe du Service LoadBalancer de Traefik. Doit appartenir à la
    plage MetalLB (networking/metallb) et être stable : c'est l'IP vers
    laquelle le DNS du routeur ou /etc/hosts des postes clients pointe.
  EOT
  type        = string
}

variable "requests_cpu" {
  type    = string
  default = "50m"
}

variable "requests_memory" {
  type    = string
  default = "64Mi"
}

variable "limits_cpu" {
  type    = string
  default = "500m"
}

variable "limits_memory" {
  type    = string
  default = "256Mi"
}

variable "tolerate_control_plane_taint" {
  description = <<-EOT
    Ajoute une toleration control-plane au pod Traefik. Nécessaire tant que
    le cluster est single-node (même besoin que networking/metallb,
    storage/local-path et security/vault). À repasser à false une fois un
    nœud worker dédié ajouté.
  EOT
  type        = bool
  default     = true
}
