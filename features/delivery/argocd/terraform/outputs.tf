output "namespace" {
  value = kubernetes_namespace.argocd.metadata[0].name
}

output "url" {
  description = "URL d'ArgoCD sur le LAN"
  value       = "https://${var.hostname}"
}
