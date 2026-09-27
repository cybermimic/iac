variable "kubeconfig_path" {
  description = <<-EOT
    Chemin vers le kubeconfig du cluster cible. Pas de valeur par défaut et
    jamais de chemin utilisateur codé en dur ici : fournir explicitement via
    TF_VAR_kubeconfig_path (ex: TF_VAR_kubeconfig_path=$KUBECONFIG terraform plan).
  EOT
  type        = string
}

variable "metallb_ip_range" {
  description = "Plage d'IP LAN pour MetalLB (ex: 192.168.1.240-192.168.1.250), hors plage DHCP du routeur."
  type        = string
}

variable "ingress_load_balancer_ip" {
  description = "IP LAN fixe de l'ingress Traefik (ex: 192.168.1.240), dans la plage metallb_ip_range."
  type        = string
}

variable "homelab_domain" {
  description = "Zone DNS interne du homelab (voir ADR-007). Tous les services sont publiés sous *.<homelab_domain>."
  type        = string
  default     = "homelab.lan"
}

variable "lan_dns_load_balancer_ip" {
  description = "IP LAN fixe du DNS du homelab (ex: 192.168.1.241), dans la plage metallb_ip_range."
  type        = string
}

variable "lan_dns_upstream_servers" {
  description = "DNS vers lesquels le DNS du homelab transfère tout ce qui n'est pas *.<homelab_domain> (ex: [\"192.168.1.254\"], le routeur)."
  type        = list(string)
}
