# Traefik = ingress **public** (ADR-009, option D) sur une IP LAN fixe
# fournie par MetalLB : la seule IP que la Freebox redirige depuis Internet
# (80/443). Les services internes n'y passent jamais : ils ont chacun leur
# propre IP.
#
# Garde-fous, pour qu'une ressource ne devienne pas publique par erreur :
# - IngressClass "traefik" NON par défaut : un Ingress sans classe explicite
#   n'est pas servi ;
# - provider kubernetesIngress limité à une liste explicite de namespaces
#   (public_namespaces) : un Ingress hors de cette liste est ignoré ;
# - provider kubernetesCRD désactivé : les IngressRoute n'ont pas de classe
#   et seraient toutes servies ;
# - Gateway API désactivée (CRDs non installés).
# HTTP redirigé en HTTPS ; le challenge ACME HTTP-01 de Let's Encrypt suit
# cette redirection (le certificat n'est pas vérifié à ce stade). Journaux
# d'accès activés.

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
        isDefaultClass = false
        name           = local.ingress_class_name
      }

      providers = {
        kubernetesCRD = {
          enabled = false
        }
        kubernetesIngress = {
          namespaces = var.public_namespaces
        }
      }

      # Journaux d'accès (chart >= v38 : clé accessLog, plus logs.access).
      accessLog = {
        enabled = true
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
