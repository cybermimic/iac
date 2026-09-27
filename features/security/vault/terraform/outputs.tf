output "namespace" {
  value = kubernetes_namespace.vault.metadata[0].name
}

output "release_name" {
  value = helm_release.vault.name
}
