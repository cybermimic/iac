output "namespace" {
  value = kubernetes_namespace.lan_dns.metadata[0].name
}

output "listen_addresses" {
  description = "Adresses du DNS à déclarer dans le routeur (DHCP IPv4 et DNS IPv6)"
  value       = var.listen_addresses
}

output "domain" {
  description = "Zone DNS interne servie (tout *.<domain> pointe vers l'ingress)"
  value       = var.domain
}
