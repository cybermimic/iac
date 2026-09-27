variable "namespace" {
  description = "Namespace où le DNS LAN est installé"
  type        = string
  default     = "lan-dns"
}

variable "coredns_version" {
  description = "Tag de l'image coredns/coredns (toujours explicite, jamais latest)"
  type        = string
  default     = "1.14.6"
}

variable "listen_addresses" {
  description = <<-EOT
    Adresses du nœud sur lesquelles le DNS écoute (UDP+TCP 53, hostNetwork) :
    son IPv4 LAN et son IPv6 globale. Ce sont les adresses à déclarer comme
    DNS dans le routeur (DHCP IPv4 et DNS IPv6). Ex:
    ["192.168.1.253", "2a01:e0a:818:4440:e251:d8ff:fe1c:4928"].
  EOT
  type        = list(string)
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

variable "health_port" {
  description = "Port HTTP du endpoint /health (sur le réseau du nœud, doit être libre sur l'hôte)"
  type        = number
  default     = 8053
}

variable "ready_port" {
  description = "Port HTTP du endpoint /ready (sur le réseau du nœud, doit être libre sur l'hôte)"
  type        = number
  default     = 8054
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
