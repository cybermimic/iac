output "namespace" {
  value = kubernetes_namespace.ingress.metadata[0].name
}

output "ingress_class_name" {
  description = "IngressClass à référencer dans les Ingress (classe par défaut du cluster)"
  value       = local.ingress_class_name
}

output "load_balancer_ip" {
  description = "IP LAN de l'ingress, cible des enregistrements DNS / /etc/hosts"
  value       = var.load_balancer_ip
}
