# Déploie uniquement le serveur Vault (mode standalone). ha.enabled=false
# fait utiliser au chart le storage backend "file" sur le volume persistant
# (dataStorage) — Raft n'apporte de valeur qu'en HA multi-replica, hors
# scope pour un cluster single-node. Init/unseal/policies/auth methods sont
# volontairement hors de
# ce module — voir README.md, section "Bootstrap initial". Faire l'inverse
# (automatiser l'init via Terraform) forcerait le root token et les unseal
# keys à transiter par un state ou des logs, exactement ce que ce repo
# interdit.
#
# Publication (ADR-009) : Vault a sa propre IP LAN (Service LoadBalancer,
# MetalLB) et termine lui-même le TLS (listener en HTTPS) avec un
# certificat de la CA interne. Pas d'Ingress : Traefik est réservé au
# public, et cette IP n'est jamais redirigée par la Freebox.

locals {
  # Le chart hashicorp/vault attend une chaîne YAML brute ici (insérée
  # telle quelle dans le pod template), pas une liste structurée — d'où
  # cette construction via local plutôt qu'un heredoc inline dans le
  # ternaire (non supporté par la syntaxe HCL).
  control_plane_toleration_yaml = <<-EOT
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
  EOT

  tls_secret_name = "vault-listener-tls"
  # Le chart monte extraVolumes de type secret sous /vault/userconfig/<nom>/.
  tls_dir = "/vault/userconfig/${local.tls_secret_name}"

  # Stockage (ADR-014, P2). « raft » permet les instantanés à chaud ; il exige
  # api_addr et cluster_addr même sur un seul nœud. Après la migration, les
  # données « file » d'origine restent dans /vault/data/file (retour arrière),
  # jamais mélangées au dossier raft.
  storage_file   = <<-EOT
    storage "file" {
      path = "/vault/data"
    }
  EOT
  storage_raft   = <<-EOT
    storage "raft" {
      path    = "/vault/data/raft"
      node_id = "vault-0"
    }
    api_addr     = "https://${var.load_balancer_ip}:8200"
    cluster_addr = "https://127.0.0.1:8201"
    # Obligatoire avec raft depuis Vault 2.x (refus de démarrer sinon, vérifié
    # sur 2.0.4) ; HashiCorp recommande de désactiver mlock avec raft.
    disable_mlock = true
  EOT
  storage_config = var.storage_backend == "raft" ? local.storage_raft : local.storage_file
}

resource "kubernetes_namespace" "vault" {
  metadata {
    name = var.namespace
  }
}

# Certificat du listener Vault, signé par la CA interne. Uniquement des IP :
# la CA ne peut signer que des noms DNS sous homelab.lan (name constraint),
# un nom interne Kubernetes (vault.vault.svc) rendrait le certificat
# invalide pour tout client qui vérifie la chaîne. 127.0.0.1 sert à la CLI
# vault dans le pod (VAULT_ADDR du chart).
resource "kubernetes_manifest" "tls" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = local.tls_secret_name
      namespace = kubernetes_namespace.vault.metadata[0].name
    }
    spec = {
      secretName  = local.tls_secret_name
      ipAddresses = [var.load_balancer_ip, "127.0.0.1"]
      issuerRef = {
        group = "cert-manager.io"
        kind  = "ClusterIssuer"
        name  = var.cluster_issuer_name
      }
    }
  }

  # Le pod Vault monte ce secret : attendre qu'il soit émis avant de
  # modifier la release.
  wait {
    condition {
      type   = "Ready"
      status = "True"
    }
  }
}

resource "helm_release" "vault" {
  name       = "vault"
  namespace  = kubernetes_namespace.vault.metadata[0].name
  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault"
  version    = var.chart_version

  create_namespace = false

  wait    = true
  timeout = 300

  depends_on = [kubernetes_manifest.tls]

  values = [
    yamlencode({
      global = {
        # Le chart passe alors VAULT_ADDR / sondes en https.
        tlsDisable = false
      }

      injector = {
        enabled = false # pas d'injection de sidecar en v1 — voir ADR-003, ESO est le pont retenu
      }

      server = {
        standalone = {
          enabled = true
          # Configuration par défaut du chart, avec le listener en TLS.
          config = <<-EOT
            ui = true

            listener "tcp" {
              address         = "[::]:8200"
              cluster_address = "[::]:8201"
              tls_cert_file   = "${local.tls_dir}/tls.crt"
              tls_key_file    = "${local.tls_dir}/tls.key"
            }

            ${trimspace(local.storage_config)}
          EOT
        }

        extraVolumes = [
          { type = "secret", name = local.tls_secret_name }
        ]

        # La CLI vault du pod vérifie le certificat avec la CA interne.
        extraEnvironmentVars = {
          VAULT_CACERT = "${local.tls_dir}/ca.crt"
        }

        service = {
          type = "LoadBalancer"
          annotations = {
            "metallb.io/loadBalancerIPs" = var.load_balancer_ip
          }
        }

        ha = {
          enabled = false
        }

        dataStorage = {
          enabled      = true
          size         = var.data_volume_size
          storageClass = var.storage_class_name
        }

        resources = {
          requests = {
            cpu    = var.requests_cpu
            memory = var.requests_memory
          }
          limits = {
            cpu    = var.limits_cpu
            memory = var.limits_memory
          }
        }

        tolerations = var.tolerate_control_plane_taint ? local.control_plane_toleration_yaml : ""
      }

      ui = {
        enabled     = var.ui_enabled
        serviceType = "ClusterIP"
      }
    })
  ]
}
