output "namespace" {
  value = kubernetes_namespace.vault.metadata[0].name
}

output "url" {
  description = "URL de Vault sur le LAN (UI sous /ui/)"
  value       = "https://${var.load_balancer_ip}:8200"
}

output "release_name" {
  value = helm_release.vault.name
}
