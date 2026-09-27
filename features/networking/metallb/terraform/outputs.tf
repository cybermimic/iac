output "namespace" {
  value = kubernetes_namespace.metallb.metadata[0].name
}

output "ip_range" {
  value = var.ip_range
}
