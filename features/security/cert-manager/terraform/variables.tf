variable "namespace" {
  description = "Namespace où cert-manager est installé (c'est aussi là que vit la CA interne : un ClusterIssuer lit ses secrets dans ce namespace)"
  type        = string
  default     = "cert-manager"
}

variable "chart_version" {
  description = "Version du chart Helm jetstack/cert-manager (toujours explicite, jamais latest)"
  type        = string
  default     = "v1.21.2"
}

variable "domain" {
  description = <<-EOT
    Seul domaine pour lequel la CA interne peut signer des certificats
    (name constraint, ex: homelab.lan). Même si la clé de la CA fuyait, elle
    ne permettrait pas de signer un certificat accepté pour un autre domaine.
  EOT
  type        = string
}

variable "ca_common_name" {
  description = "Nom affiché de la CA racine (visible dans les magasins de certificats des postes)"
  type        = string
  default     = "Homelab Root CA"
}

variable "ca_duration" {
  description = <<-EOT
    Durée de validité de la CA racine. Longue volontairement : son
    renouvellement impose de réimporter le nouveau certificat sur tous les
    postes. Les certificats des services, eux, sont courts et renouvelés
    automatiquement.
  EOT
  type        = string
  default     = "87600h" # 10 ans
}

variable "tolerate_control_plane_taint" {
  description = <<-EOT
    Ajoute une toleration control-plane aux pods cert-manager (controller,
    webhook, cainjector, startupapicheck). Nécessaire tant que le cluster est
    single-node. À repasser à false une fois un nœud worker dédié ajouté.
  EOT
  type        = bool
  default     = true
}
