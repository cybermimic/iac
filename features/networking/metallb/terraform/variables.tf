variable "namespace" {
  description = "Namespace où MetalLB est installé"
  type        = string
  default     = "metallb-system"
}

variable "chart_version" {
  description = "Version du chart Helm MetalLB (toujours explicite, jamais latest)"
  type        = string
  default     = "0.14.9"
}

variable "ip_range" {
  description = "Plage d'IP LAN allouée aux Services LoadBalancer (ex: 192.168.1.240-192.168.1.250). Doit être en dehors de la plage DHCP du routeur."
  type        = string
}

variable "tolerate_control_plane_taint" {
  description = <<-EOT
    Ajoute une toleration control-plane au controller MetalLB. Nécessaire tant
    que le cluster est single-node (le control-plane porte le taint
    node-role.kubernetes.io/control-plane:NoSchedule et rien ne peut y être
    schedulé sans toleration explicite). À repasser à false une fois un nœud
    worker dédié ajouté au cluster.
  EOT
  type        = bool
  default     = true
}
