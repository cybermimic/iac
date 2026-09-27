# DNS du LAN (voir ADR-007) : une instance CoreDNS dédiée, distincte du
# CoreDNS interne du cluster (kube-system/kube-dns, jamais touché ici),
# distribuée à tous les appareils par le routeur (DHCP IPv4 + DNS IPv6).
#
# hostNetwork plutôt qu'une IP MetalLB : le routeur exige aussi une
# adresse IPv6 de DNS, or le cluster est IPv4 uniquement (pas d'IP
# LoadBalancer IPv6 possible). Le pod écoute donc directement sur les
# adresses IPv4/IPv6 du nœud (plugin `bind`), sans passer par un Service.
#
# Ressources Terraform explicites plutôt que le chart coredns/coredns, qui
# ne sait pas faire de hostNetwork.
#
# Deux zones :
# - <domain> (ex: homelab.lan) : tout nom *.<domain> répond l'IP de
#   l'ingress. Pas de liste de noms à maintenir, Traefik route ensuite
#   selon le Host HTTP.
# - "." : tout le reste est transféré au DNS amont (le routeur).

locals {
  bind = "bind ${join(" ", var.listen_addresses)}"

  corefile = <<-EOT
    ${var.domain}.:53 {
        ${local.bind}
        errors
        # Wildcard : <n'importe quoi>.<domain> -> IP de l'ingress.
        template IN A ${var.domain} {
            answer "{{ .Name }} 60 IN A ${var.wildcard_target_ip}"
        }
        # Pas d'IPv6 pour ces noms : réponse vide immédiate plutôt qu'un
        # timeout côté client.
        template IN AAAA ${var.domain} {
            rcode NOERROR
        }
    }
    .:53 {
        ${local.bind}
        errors
        health :${var.health_port}
        ready :${var.ready_port}
        forward . ${join(" ", var.upstream_dns_servers)}
        cache 300
        loop
        reload
        loadbalance
    }
  EOT
}

resource "kubernetes_namespace" "lan_dns" {
  metadata {
    name = var.namespace
  }
}

resource "kubernetes_config_map" "corefile" {
  metadata {
    name      = "lan-dns-corefile"
    namespace = kubernetes_namespace.lan_dns.metadata[0].name
  }

  data = {
    Corefile = local.corefile
  }
}

resource "kubernetes_deployment" "lan_dns" {
  metadata {
    name      = "lan-dns"
    namespace = kubernetes_namespace.lan_dns.metadata[0].name
    labels = {
      "app.kubernetes.io/name" = "lan-dns"
    }
  }

  spec {
    replicas = 1

    # hostNetwork : deux pods ne peuvent pas écouter sur le même port du
    # nœud, l'ancien doit s'arrêter avant que le nouveau démarre.
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = {
        "app.kubernetes.io/name" = "lan-dns"
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name" = "lan-dns"
        }
        annotations = {
          # Redémarre le pod quand le Corefile change (le plugin reload le
          # ferait aussi, mais avec un délai et sans trace côté Kubernetes).
          "checksum/corefile" = sha256(local.corefile)
        }
      }

      spec {
        host_network = true
        dns_policy   = "Default"

        dynamic "toleration" {
          for_each = var.tolerate_control_plane_taint ? [1] : []
          content {
            key      = "node-role.kubernetes.io/control-plane"
            operator = "Exists"
            effect   = "NoSchedule"
          }
        }

        container {
          name  = "coredns"
          image = "coredns/coredns:${var.coredns_version}"
          args  = ["-conf", "/etc/coredns/Corefile"]

          port {
            name           = "dns-udp"
            container_port = 53
            protocol       = "UDP"
          }
          port {
            name           = "dns-tcp"
            container_port = 53
            protocol       = "TCP"
          }

          resources {
            requests = {
              cpu    = var.requests_cpu
              memory = var.requests_memory
            }
            limits = {
              cpu    = var.limits_cpu
              memory = var.limits_memory
            }
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              add  = ["NET_BIND_SERVICE"]
              drop = ["ALL"]
            }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = var.health_port
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          readiness_probe {
            http_get {
              path = "/ready"
              port = var.ready_port
            }
            period_seconds = 5
          }

          volume_mount {
            name       = "corefile"
            mount_path = "/etc/coredns"
            read_only  = true
          }
        }

        volume {
          name = "corefile"
          config_map {
            name = kubernetes_config_map.corefile.metadata[0].name
          }
        }
      }
    }
  }

  # `kubectl rollout restart` pose cette annotation : sans cet ignore,
  # Terraform la retirerait au plan suivant et relancerait le pod pour rien.
  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
    ]
  }
}
