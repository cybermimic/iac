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
# TLS interne désactivé pour cette première version : trafic ClusterIP
# uniquement, pas d'exposition hors cluster tant qu'ingress+cert-manager
# n'existent pas. À durcir plus tard (voir README, section Troubleshooting).

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
}

resource "kubernetes_namespace" "vault" {
  metadata {
    name = var.namespace
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

  values = [
    yamlencode({
      injector = {
        enabled = false # pas d'injection de sidecar en v1 — voir ADR-003, ESO est le pont retenu
      }

      server = {
        standalone = {
          enabled = true
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

# Publication de Vault (UI + API) sur le LAN via l'ingress, en HTTPS avec un
# certificat de la CA interne (voir ADR-006). Le TLS est terminé par
# Traefik : entre Traefik et le pod, le trafic reste en HTTP dans le cluster
# (listener Vault tls_disable = 1).
resource "kubernetes_ingress_v1" "vault" {
  count = var.ingress_host == null ? 0 : 1

  metadata {
    name      = "vault"
    namespace = kubernetes_namespace.vault.metadata[0].name
    annotations = {
      "cert-manager.io/cluster-issuer" = var.cluster_issuer_name
    }
  }

  spec {
    ingress_class_name = var.ingress_class_name

    tls {
      hosts       = [var.ingress_host]
      secret_name = "vault-tls"
    }

    rule {
      host = var.ingress_host
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              # Service créé par le chart : nom = nom de la release.
              name = helm_release.vault.name
              port {
                number = 8200
              }
            }
          }
        }
      }
    }
  }
}
