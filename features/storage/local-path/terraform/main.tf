# Traduction Terraform du manifeste upstream officiel (typé, plutôt que
# kubernetes_manifest brut) :
# https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.31/deploy/local-path-storage.yaml
# Écarts volontaires par rapport à l'upstream, documentés dans le README :
# toleration control-plane (cluster single-node) et image busybox pinnée
# (l'upstream la laisse sans tag).

resource "kubernetes_namespace" "local_path" {
  metadata {
    name = var.namespace
  }
}

resource "kubernetes_service_account" "provisioner" {
  metadata {
    name      = "local-path-provisioner-service-account"
    namespace = kubernetes_namespace.local_path.metadata[0].name
  }
}

resource "kubernetes_role" "provisioner" {
  metadata {
    name      = "local-path-provisioner-role"
    namespace = kubernetes_namespace.local_path.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "watch", "create", "patch", "update", "delete"]
  }
}

resource "kubernetes_cluster_role" "provisioner" {
  metadata {
    name = "local-path-provisioner-role"
  }

  rule {
    api_groups = [""]
    resources  = ["nodes", "persistentvolumeclaims", "configmaps", "pods", "pods/log"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["persistentvolumes"]
    verbs      = ["get", "list", "watch", "create", "patch", "update", "delete"]
  }

  rule {
    api_groups = [""]
    resources  = ["events"]
    verbs      = ["create", "patch"]
  }

  rule {
    api_groups = ["storage.k8s.io"]
    resources  = ["storageclasses"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding" "provisioner" {
  metadata {
    name      = "local-path-provisioner-bind"
    namespace = kubernetes_namespace.local_path.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.provisioner.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.provisioner.metadata[0].name
    namespace = kubernetes_namespace.local_path.metadata[0].name
  }
}

resource "kubernetes_cluster_role_binding" "provisioner" {
  metadata {
    name = "local-path-provisioner-bind"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.provisioner.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.provisioner.metadata[0].name
    namespace = kubernetes_namespace.local_path.metadata[0].name
  }
}

resource "kubernetes_config_map" "local_path_config" {
  metadata {
    name      = "local-path-config"
    namespace = kubernetes_namespace.local_path.metadata[0].name
  }

  data = {
    "config.json" = jsonencode({
      nodePathMap = [
        {
          node  = "DEFAULT_PATH_FOR_NON_LISTED_NODES"
          paths = [var.host_path]
        }
      ]
    })

    "setup" = <<-EOT
      #!/bin/sh
      set -eu
      mkdir -m 0777 -p "$VOL_DIR"
    EOT

    "teardown" = <<-EOT
      #!/bin/sh
      set -eu
      rm -rf "$VOL_DIR"
    EOT

    "helperPod.yaml" = <<-EOT
      apiVersion: v1
      kind: Pod
      metadata:
        name: helper-pod
      spec:
        priorityClassName: system-node-critical
        tolerations:
          - key: node.kubernetes.io/disk-pressure
            operator: Exists
            effect: NoSchedule
        containers:
        - name: helper-pod
          image: busybox:1.36
          imagePullPolicy: IfNotPresent
    EOT
  }
}

resource "kubernetes_deployment" "provisioner" {
  metadata {
    name      = "local-path-provisioner"
    namespace = kubernetes_namespace.local_path.metadata[0].name
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "local-path-provisioner"
      }
    }

    template {
      metadata {
        labels = {
          app = "local-path-provisioner"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.provisioner.metadata[0].name

        dynamic "toleration" {
          for_each = var.tolerate_control_plane_taint ? [1] : []

          content {
            key      = "node-role.kubernetes.io/control-plane"
            operator = "Exists"
            effect   = "NoSchedule"
          }
        }

        container {
          name              = "local-path-provisioner"
          image             = "rancher/local-path-provisioner:${var.provisioner_version}"
          image_pull_policy = "IfNotPresent"
          command           = ["local-path-provisioner", "--debug", "start", "--config", "/etc/config/config.json"]

          volume_mount {
            name       = "config-volume"
            mount_path = "/etc/config/"
          }

          env {
            name = "POD_NAMESPACE"

            value_from {
              field_ref {
                field_path = "metadata.namespace"
              }
            }
          }

          env {
            name  = "CONFIG_MOUNT_PATH"
            value = "/etc/config/"
          }
        }

        volume {
          name = "config-volume"

          config_map {
            name = kubernetes_config_map.local_path_config.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_storage_class" "local_path" {
  metadata {
    name = "local-path"

    annotations = var.set_as_default_storage_class ? {
      "storageclass.kubernetes.io/is-default-class" = "true"
    } : {}
  }

  storage_provisioner = "rancher.io/local-path"
  volume_binding_mode = "WaitForFirstConsumer"
  reclaim_policy      = "Delete"
}
