output "namespace" {
  value = kubernetes_namespace.local_path.metadata[0].name
}

output "storage_class_name" {
  value = kubernetes_storage_class.local_path.metadata[0].name
}
