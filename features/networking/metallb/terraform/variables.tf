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

variable "ignore_exclude_lb_label" {
  description = <<-EOT
    Fait annoncer les IP par le speaker même sur un nœud portant le label
    node.kubernetes.io/exclude-from-external-load-balancers (posé par kubeadm
    sur les control-planes). Nécessaire tant que le cluster est single-node,
    sinon aucune IP LoadBalancer n'est joignable depuis le LAN. À repasser à
    false une fois un nœud worker dédié ajouté.
  EOT
  type        = bool
  default     = true
}
