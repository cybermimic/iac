variable "namespace" {
  description = "Namespace où le DNS LAN est installé"
  type        = string
  default     = "lan-dns"
}

variable "chart_version" {
  description = "Version du chart Helm coredns/coredns (toujours explicite, jamais latest)"
  type        = string
  default     = "1.47.1"
}

variable "load_balancer_ip" {
  description = <<-EOT
    IP LAN fixe du serveur DNS (UDP+TCP 53), dans la plage MetalLB. C'est
    l'IP à déclarer comme serveur DNS sur les postes clients / le DHCP.
  EOT
  type        = string
}

variable "domain" {
  description = "Zone DNS interne servie par ce DNS (ex: homelab.lan). Tout nom *.<domain> résout vers wildcard_target_ip."
  type        = string
}

variable "wildcard_target_ip" {
  description = "IP vers laquelle pointent tous les noms *.<domain> — l'IP de l'ingress (networking/ingress)."
  type        = string
}

variable "upstream_dns_servers" {
  description = <<-EOT
    Serveurs DNS vers lesquels tout le reste (hors <domain>) est transféré,
    typiquement le DNS du routeur (ex: ["192.168.1.254"]). Pas de valeur par
    défaut : dépend du réseau.
  EOT
  type        = list(string)
}

variable "requests_cpu" {
  type    = string
  default = "20m"
}

variable "requests_memory" {
  type    = string
  default = "32Mi"
}

variable "limits_cpu" {
  type    = string
  default = "200m"
}

variable "limits_memory" {
  type    = string
  default = "128Mi"
}

variable "tolerate_control_plane_taint" {
  description = <<-EOT
    Ajoute une toleration control-plane au pod CoreDNS. Nécessaire tant que
    le cluster est single-node (même besoin que les autres features). À
    repasser à false une fois un nœud worker dédié ajouté.
  EOT
  type        = bool
  default     = true
}
