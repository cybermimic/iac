# ArgoCD (voir ADR-002) : installé par Terraform, publié sur le LAN en
# HTTPS via l'ingress avec un certificat de la CA interne.
#
# Première version volontairement minimale : ArgoCD seul, SANS aucune
# Application. La structure GitOps (quel repo/chemin ArgoCD suit, "app of
# apps", ce qui bascule de Terraform vers ArgoCD) est une décision à part.
#
# - server.insecure : le TLS est terminé par Traefik (comme pour Vault) ;
#   sans ce réglage, argocd-server redirige lui-même en HTTPS et crée une
#   boucle derrière l'ingress.
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
        domain = var.hostname
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

      configs = {
        params = {
          "server.insecure" = true
        }
      }

      dex = {
        enabled = false
      }

      notifications = {
        enabled = false
      }

      server = {
        ingress = {
          enabled          = true
          ingressClassName = var.ingress_class_name
          annotations = {
            "cert-manager.io/cluster-issuer" = var.cluster_issuer_name
          }
          # Certificat dans le secret argocd-server-tls, créé par cert-manager.
          tls = true
        }
      }
    })
  ]
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
