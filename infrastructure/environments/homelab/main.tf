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
