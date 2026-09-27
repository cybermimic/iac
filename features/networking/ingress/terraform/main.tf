# Traefik comme contrôleur d'ingress (voir ADR-006), exposé sur une IP LAN
# fixe fournie par MetalLB. Première version volontairement minimale :
# - IngressClass "traefik" par défaut + CRDs IngressRoute/Middleware ;
# - pas de Gateway API (CRDs non installés, provider désactivé) ;
# - dashboard actif mais non exposé (accès par kubectl port-forward) ;
# - HTTP (port 80) redirigé en HTTPS (443) de façon permanente ; chaque
#   service fournit son certificat (cert-manager, CA interne). Un nom sans
#   certificat reçoit le certificat auto-signé par défaut de Traefik.

locals {
  ingress_class_name = "traefik"
}

resource "kubernetes_namespace" "ingress" {
  metadata {
    name = var.namespace
  }
}

resource "helm_release" "traefik" {
  name       = "traefik"
  namespace  = kubernetes_namespace.ingress.metadata[0].name
  repository = "https://traefik.github.io/charts"
  chart      = "traefik"
  version    = var.chart_version

  create_namespace = false

  wait    = true
  timeout = 300

  values = [
    yamlencode({
      service = {
        # Annotation MetalLB (>= 0.13) pour demander une IP précise de la
        # plage, plutôt que spec.loadBalancerIP (déprécié côté Kubernetes).
        annotations = {
          "metallb.io/loadBalancerIPs" = var.load_balancer_ip
        }
      }

      ingressClass = {
        enabled        = true
        isDefaultClass = true
        name           = local.ingress_class_name
      }

      # Tout le HTTP est redirigé vers HTTPS (redirection permanente, 301).
      ports = {
        web = {
          http = {
            redirections = {
              entryPoint = {
                to        = "websecure"
                scheme    = "https"
                permanent = true
              }
            }
          }
        }
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

      tolerations = var.tolerate_control_plane_taint ? [
        {
          key      = "node-role.kubernetes.io/control-plane"
          operator = "Exists"
          effect   = "NoSchedule"
        }
      ] : []
    })
  ]
}
