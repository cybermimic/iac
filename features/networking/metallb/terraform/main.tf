resource "kubernetes_namespace" "metallb" {
  metadata {
    name = var.namespace
  }
}

resource "helm_release" "metallb" {
  name       = "metallb"
  namespace  = kubernetes_namespace.metallb.metadata[0].name
  repository = "https://metallb.github.io/metallb"
  chart      = "metallb"
  version    = var.chart_version

  create_namespace = false

  wait    = true
  timeout = 300

  # kubeadm pose le label node.kubernetes.io/exclude-from-external-load-balancers
  # sur les control-planes, et le speaker ignore par défaut les nœuds qui le
  # portent : sur un cluster single-node, plus personne n'annonce les IP en
  # ARP et elles sont injoignables depuis le LAN (joignables uniquement depuis
  # le nœud lui-même, ce qui masque le problème).
  set {
    name  = "speaker.ignoreExcludeLB"
    value = var.ignore_exclude_lb_label
  }

  dynamic "set" {
    for_each = var.tolerate_control_plane_taint ? {
      "controller.tolerations[0].key"      = "node-role.kubernetes.io/control-plane"
      "controller.tolerations[0].operator" = "Exists"
      "controller.tolerations[0].effect"   = "NoSchedule"
    } : {}

    content {
      name  = set.key
      value = set.value
    }
  }
}

# Le chart MetalLB génère lui-même le secret "memberlist" requis par les
# speakers (hook Helm au premier install) — ne pas le créer manuellement ici,
# sous peine de le gérer en double avec des mécanismes différents.

resource "kubernetes_manifest" "ip_pool" {
  depends_on = [helm_release.metallb]

  manifest = {
    apiVersion = "metallb.io/v1beta1"
    kind       = "IPAddressPool"

    metadata = {
      name      = "default-pool"
      namespace = kubernetes_namespace.metallb.metadata[0].name
    }

    spec = {
      addresses = [var.ip_range]
    }
  }
}

resource "kubernetes_manifest" "l2_advert" {
  depends_on = [kubernetes_manifest.ip_pool]

  manifest = {
    apiVersion = "metallb.io/v1beta1"
    kind       = "L2Advertisement"

    metadata = {
      name      = "l2"
      namespace = kubernetes_namespace.metallb.metadata[0].name
    }

    spec = {
      ipAddressPools = ["default-pool"]
    }
  }
}
