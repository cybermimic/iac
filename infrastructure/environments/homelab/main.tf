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

  # Propre IP LAN + TLS par Vault lui-même (ADR-009) : dépendances
  # explicites sur MetalLB (IP) et la CA interne (certificat).
  load_balancer_ip    = var.vault_load_balancer_ip
  storage_backend     = var.vault_storage_backend
  cluster_issuer_name = module.cert_manager.cluster_issuer_name
  depends_on          = [module.metallb]
}

module "ingress" {
  source = "../../../features/networking/ingress/terraform"

  load_balancer_ip  = var.ingress_load_balancer_ip
  public_namespaces = var.public_namespaces

  # Dépend de MetalLB : sans IPAddressPool, le Service LoadBalancer de
  # Traefik resterait <pending> et le helm_release (wait = true) échouerait.
  depends_on = [module.metallb]
}

module "cert_manager" {
  source = "../../../features/security/cert-manager/terraform"

  # La CA interne ne peut signer que pour ce domaine (name constraint).
  domain = var.homelab_domain

  # Let's Encrypt (applications publiques) : challenge servi par l'ingress
  # public, dépendance explicite via son output.
  acme_email                = var.acme_email
  public_ingress_class_name = module.ingress.ingress_class_name
}

module "argocd" {
  source = "../../../features/delivery/argocd/terraform"

  # Propre IP LAN + TLS par argocd-server (ADR-009) : dépendances
  # explicites sur MetalLB (IP) et la CA interne (certificat).
  load_balancer_ip    = var.argocd_load_balancer_ip
  cluster_issuer_name = module.cert_manager.cluster_issuer_name
  depends_on          = [module.metallb]
}
