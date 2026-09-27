# cert-manager + CA interne du homelab (voir ADR-006).
#
# Chaîne de confiance :
#   ClusterIssuer "selfsigned-bootstrap"  (ne sert qu'à signer la racine)
#     └─ Certificate "homelab-root-ca"    (CA racine, secret du même nom)
#          └─ ClusterIssuer "homelab-ca"  (signe les certificats des services)
#
# La clé privée de la CA ne quitte jamais le cluster (secret
# cert-manager/homelab-root-ca). Seul son certificat public (ca.crt) est
# distribué aux postes clients.
#
# ⚠️ Premier déploiement : les kubernetes_manifest ci-dessous exigent que les
# CRDs cert-manager existent déjà au moment du `plan`. Sur un cluster vierge,
# appliquer d'abord `-target=module.cert_manager.helm_release.cert_manager`
# (voir README, Installation).

locals {
  control_plane_tolerations = var.tolerate_control_plane_taint ? [
    {
      key      = "node-role.kubernetes.io/control-plane"
      operator = "Exists"
      effect   = "NoSchedule"
    }
  ] : []

  ca_secret_name = "homelab-root-ca"
}

resource "kubernetes_namespace" "cert_manager" {
  metadata {
    name = var.namespace
  }
}

resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  namespace  = kubernetes_namespace.cert_manager.metadata[0].name
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = var.chart_version

  create_namespace = false

  wait    = true
  timeout = 300

  values = [
    yamlencode({
      # CRDs gérées par le chart (templates Helm, donc mises à jour aux
      # upgrades) et conservées si la release est supprimée — sinon tous les
      # Certificates/Issuers, et la CA avec, seraient effacés.
      crds = {
        enabled = true
        keep    = true
      }

      resources = {
        requests = { cpu = "10m", memory = "64Mi" }
      }
      tolerations = local.control_plane_tolerations

      webhook = {
        resources   = { requests = { cpu = "10m", memory = "32Mi" } }
        tolerations = local.control_plane_tolerations
      }

      cainjector = {
        resources   = { requests = { cpu = "10m", memory = "64Mi" } }
        tolerations = local.control_plane_tolerations
      }

      startupapicheck = {
        tolerations = local.control_plane_tolerations
      }
    })
  ]
}

resource "kubernetes_manifest" "selfsigned_issuer" {
  depends_on = [helm_release.cert_manager]

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "selfsigned-bootstrap"
    }
    spec = {
      selfSigned = {}
    }
  }
}

resource "kubernetes_manifest" "root_ca" {
  depends_on = [kubernetes_manifest.selfsigned_issuer]

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = local.ca_secret_name
      namespace = kubernetes_namespace.cert_manager.metadata[0].name
    }
    spec = {
      isCA       = true
      commonName = var.ca_common_name
      secretName = local.ca_secret_name
      duration   = var.ca_duration

      privateKey = {
        algorithm = "ECDSA"
        size      = 256
        # Une nouvelle clé = une nouvelle CA à réimporter partout : jamais
        # de rotation implicite.
        rotationPolicy = "Never"
      }

      # La CA ne peut signer que pour *.<domain> (et <domain>).
      nameConstraints = {
        critical = true
        permitted = {
          dnsDomains = [var.domain]
        }
      }

      issuerRef = {
        group = "cert-manager.io"
        kind  = "ClusterIssuer"
        name  = kubernetes_manifest.selfsigned_issuer.manifest.metadata.name
      }
    }
  }
}

resource "kubernetes_manifest" "homelab_ca_issuer" {
  depends_on = [kubernetes_manifest.root_ca]

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "homelab-ca"
    }
    spec = {
      ca = {
        secretName = local.ca_secret_name
      }
    }
  }
}
