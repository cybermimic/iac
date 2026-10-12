# ArgoCD (voir ADR-002, ADR-008) : installé par Terraform, avec l'Application
# racine (app-of-apps) qui suit gitops/apps/.
#
# Publication (ADR-009) : propre IP LAN (Service LoadBalancer, MetalLB) et
# TLS terminé par argocd-server lui-même, avec un certificat de la CA
# interne dans le secret argocd-server-tls (nom attendu par ArgoCD). Pas
# d'Ingress : Traefik est réservé au public, et cette IP n'est jamais
# redirigée par la Freebox.
# - Dex (SSO) et le contrôleur de notifications désactivés : pas de
#   consommateur pour l'instant (compte admin local uniquement).
# - Mot de passe admin initial : généré par ArgoCD dans le secret
#   argocd-initial-admin-secret, lu par l'humain uniquement (README), jamais
#   par Terraform ni versionné.

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = var.namespace
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.chart_version

  create_namespace = false

  wait    = true
  timeout = 600

  values = [
    yamlencode({
      global = {
        # URL publiée par ArgoCD (liens, callbacks) : l'IP, pas de DNS local.
        domain = var.load_balancer_ip
        tolerations = var.tolerate_control_plane_taint ? [
          {
            key      = "node-role.kubernetes.io/control-plane"
            operator = "Exists"
            effect   = "NoSchedule"
          }
        ] : []
      }

      # CRDs gérées par le chart (mises à jour aux upgrades) et conservées
      # si la release est supprimée — sinon toutes les Applications seraient
      # effacées avec.
      crds = {
        install = true
        keep    = true
      }

      dex = {
        enabled = false
      }

      notifications = {
        enabled = false
      }

      server = {
        service = {
          type = "LoadBalancer"
          annotations = {
            "metallb.io/loadBalancerIPs" = var.load_balancer_ip
          }
        }
      }
    })
  ]
}

# Certificat d'argocd-server, signé par la CA interne. Uniquement l'IP : la
# CA ne peut signer que des noms DNS sous homelab.lan (name constraint).
# Créé après la release (depends_on) : la mise à jour de la release retire
# l'ancien Ingress, dont le certificat visait le même secret.
resource "kubernetes_manifest" "server_tls" {
  depends_on = [helm_release.argocd]

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "argocd-server"
      namespace = kubernetes_namespace.argocd.metadata[0].name
    }
    spec = {
      # Nom de secret imposé : argocd-server le relit à chaud.
      secretName  = "argocd-server-tls"
      ipAddresses = [var.load_balancer_ip]
      issuerRef = {
        group = "cert-manager.io"
        kind  = "ClusterIssuer"
        name  = var.cluster_issuer_name
      }
    }
  }

  wait {
    condition {
      type   = "Ready"
      status = "True"
    }
  }
}

# App-of-apps (ADR-008) : seule Application créée par Terraform. Elle suit
# gitops/apps/ de ce repo — chaque fichier de ce dossier est une Application
# à part (une feature ou une app business), ajoutée/retirée par une PR sur
# ce repo, sans nouveau `terraform apply`.
resource "kubernetes_manifest" "root_app" {
  depends_on = [helm_release.argocd]

  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"

    metadata = {
      name      = "root"
      namespace = kubernetes_namespace.argocd.metadata[0].name
    }

    spec = {
      project = "default"

      source = {
        repoURL        = var.root_app_repo_url
        targetRevision = var.root_app_repo_revision
        path           = var.root_app_path

        directory = {
          recurse = true
        }
      }

      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = kubernetes_namespace.argocd.metadata[0].name
      }

      syncPolicy = {
        automated = {
          selfHeal = true
          # Pas de prune (ADR-008) : retirer un fichier de gitops/apps/ ne
          # supprime pas l'Application correspondante tant qu'on n'a pas
          # confiance, feature par feature.
        }
      }
    }
  }
}
