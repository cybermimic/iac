module "metallb" {
  source = "../../../features/networking/metallb/terraform"

  ip_range = var.metallb_ip_range
}

module "local_path_storage" {
  source = "../../../features/storage/local-path/terraform"
}

module "vault" {
  source = "../../../features/security/vault/terraform"

  storage_class_name = module.local_path_storage.storage_class_name
}

module "ingress" {
  source = "../../../features/networking/ingress/terraform"

  load_balancer_ip = var.ingress_load_balancer_ip

  # Dépend de MetalLB : sans IPAddressPool, le Service LoadBalancer de
  # Traefik resterait <pending> et le helm_release (wait = true) échouerait.
  depends_on = [module.metallb]
}

module "lan_dns" {
  source = "../../../features/networking/lan-dns/terraform"

  load_balancer_ip     = var.lan_dns_load_balancer_ip
  domain               = var.homelab_domain
  upstream_dns_servers = var.lan_dns_upstream_servers

  # Dépendance explicite sur l'ingress via son output (tout *.<domain> pointe
  # vers lui), et sur MetalLB pour l'IP LoadBalancer.
  wildcard_target_ip = module.ingress.load_balancer_ip
  depends_on         = [module.metallb]
}
