# DNS pour les postes du LAN (voir ADR-007) : une instance CoreDNS dédiée,
# distincte du CoreDNS interne du cluster (kube-system/kube-dns, jamais
# touché ici), exposée sur une IP LAN fixe via MetalLB.
#
# Deux zones :
# - <domain> (ex: homelab.lan) : tout nom *.<domain> répond l'IP de
#   l'ingress. Pas de liste de noms à maintenir, Traefik route ensuite
#   selon le Host HTTP.
# - "." : tout le reste est transféré au DNS du routeur, pour que les
#   postes qui utilisent ce DNS continuent de résoudre Internet.

resource "kubernetes_namespace" "lan_dns" {
  metadata {
    name = var.namespace
  }
}

resource "helm_release" "lan_dns" {
  name       = "lan-dns"
  namespace  = kubernetes_namespace.lan_dns.metadata[0].name
  repository = "https://coredns.github.io/helm"
  chart      = "coredns"
  version    = var.chart_version

  create_namespace = false

  wait    = true
  timeout = 300

  values = [
    yamlencode({
      # Instance "applicative", pas le DNS du cluster : pas de label
      # k8s-app=kube-dns, pas de RBAC (le plugin kubernetes n'est pas utilisé).
      isClusterService = false
      rbac = {
        create = false
      }

      serviceType = "LoadBalancer"
      service = {
        annotations = {
          "metallb.io/loadBalancerIPs" = var.load_balancer_ip
        }
      }

      servers = [
        {
          zones = [{ zone = "${var.domain}.", use_tcp = true }]
          port  = 53
          plugins = [
            { name = "errors" },
            {
              # Wildcard : <n'importe quoi>.<domain> -> IP de l'ingress.
              # {{ .Name }} est une variable du plugin CoreDNS "template"
              # (le chart n'applique pas de templating Helm à ce champ).
              name        = "template"
              parameters  = "IN A ${var.domain}"
              configBlock = "answer \"{{ .Name }} 60 IN A ${var.wildcard_target_ip}\""
            },
            {
              # Pas d'IPv6 pour ces noms : réponse vide immédiate plutôt
              # qu'un timeout côté client.
              name        = "template"
              parameters  = "IN AAAA ${var.domain}"
              configBlock = "rcode NOERROR"
            },
          ]
        },
        {
          zones = [{ zone = ".", use_tcp = true }]
          port  = 53
          plugins = [
            { name = "errors" },
            { name = "health", configBlock = "lameduck 10s" },
            { name = "ready" },
            { name = "forward", parameters = ". ${join(" ", var.upstream_dns_servers)}" },
            { name = "cache", parameters = "300" },
            { name = "loop" },
            { name = "reload" },
            { name = "loadbalance" },
          ]
        },
      ]

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
