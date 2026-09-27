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
