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
