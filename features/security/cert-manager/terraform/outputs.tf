output "namespace" {
  value = kubernetes_namespace.cert_manager.metadata[0].name
}

output "cluster_issuer_name" {
  description = "ClusterIssuer à référencer pour obtenir un certificat signé par la CA interne (annotation cert-manager.io/cluster-issuer)"
  value       = kubernetes_manifest.homelab_ca_issuer.manifest.metadata.name
}

output "ca_secret_name" {
  description = "Secret (dans var.namespace) qui contient la CA : ca.crt est public et à distribuer aux postes, tls.key ne doit jamais sortir du cluster"
  value       = local.ca_secret_name
}
