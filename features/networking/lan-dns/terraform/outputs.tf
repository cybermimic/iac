output "namespace" {
  value = kubernetes_namespace.lan_dns.metadata[0].name
}

output "load_balancer_ip" {
  description = "IP du serveur DNS à configurer sur les postes clients / le DHCP"
  value       = var.load_balancer_ip
}

output "domain" {
  description = "Zone DNS interne servie (tout *.<domain> pointe vers l'ingress)"
  value       = var.domain
}
