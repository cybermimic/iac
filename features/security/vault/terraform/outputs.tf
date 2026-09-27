output "namespace" {
  value = kubernetes_namespace.vault.metadata[0].name
}

output "url" {
  description = "URL de Vault sur le LAN (null si non publié)"
  value       = var.ingress_host == null ? null : "https://${var.ingress_host}"
}

output "release_name" {
  value = helm_release.vault.name
}
