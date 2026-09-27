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
