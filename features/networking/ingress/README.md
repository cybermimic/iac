# networking/ingress

## Objectif

Point d'entrée HTTP(S) unique du cluster depuis le LAN : Traefik, exposé
sur une IP fixe fournie par MetalLB. Les services (Vault, ArgoCD…) sont
publiés derrière lui via des `Ingress` (ou `IngressRoute` Traefik) plutôt
qu'avec une IP LoadBalancer chacun. Choix et alternatives :
[ADR-006](../../../docs/adr/ADR-006-ingress-and-internal-tls.md).

## Dépendances

- `networking/metallb` — fournit l'IP du Service `LoadBalancer`
  (`depends_on` explicite dans `infrastructure/environments/homelab/main.tf`).

Features qui en dépendent : toute feature publiée sur le LAN (aujourd'hui
`security/vault`), avec ses certificats fournis par `security/cert-manager`.

## Ressources approximatives

Un pod Traefik : requests 50m CPU / 64Mi RAM, limits 500m / 256Mi (voir
variables). Consommation réelle attendue ~50-100Mi. Pas de stockage
persistant.

## Inputs

| Variable | Description | Défaut |
|---|---|---|
| `namespace` | Namespace d'installation | `traefik` |
| `chart_version` | Version du chart `traefik/traefik` | `41.6.0` (Traefik v3.7.13) |
| `load_balancer_ip` | IP LAN fixe, dans la plage MetalLB | — (requis) |
| `requests_*` / `limits_*` | Ressources du pod | voir `variables.tf` |
| `tolerate_control_plane_taint` | Toleration control-plane (single-node) | `true` |

## Outputs

`namespace`, `ingress_class_name` (`traefik`), `load_balancer_ip`.

## HTTPS

- **Redirection** : tout le HTTP (port 80) est redirigé en permanence
  (301) vers HTTPS (443).
- **Certificats** : fournis par chaque service via cert-manager
  (annotation `cert-manager.io/cluster-issuer: homelab-ca` sur l'Ingress,
  voir [security/cert-manager](../../security/cert-manager/README.md)).
  Un nom sans certificat reçoit le certificat auto-signé par défaut de
  Traefik (avertissement navigateur).
- **TLS terminé par Traefik** : entre Traefik et les pods, le trafic reste
  en HTTP à l'intérieur du cluster.

## Ce qui est volontairement hors de cette version

- **Dashboard exposé** : actif mais accessible uniquement par
  port-forward (voir Troubleshooting) — pas d'exposition sans
  authentification.
- **Gateway API** : provider désactivé, CRDs non installés (voir ADR-006).
- Le chart installe aussi les CRDs `hub.traefik.io` (produit commercial
  Traefik Hub, non utilisé) : inertes, ignorées.

## Installation

Assemblée avec les autres features dans `infrastructure/environments/homelab`
(voir son README). Ajouter dans `terraform.tfvars` :

```hcl
ingress_load_balancer_ip = "192.168.1.240"
```

Puis `terraform plan` (doit montrer uniquement des créations dans
`module.ingress`) et `terraform apply`.

Vérification :

```bash
kubectl -n traefik get pods,svc          # pod Running, EXTERNAL-IP = load_balancer_ip
kubectl get ingressclass                 # traefik (default)
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.1.240/   # 404 attendu ; à lancer depuis un AUTRE poste du LAN
```

## Résolution des noms

Les services seront publiés sous `*.homelab.lan` (ADR-006). Tant qu'il
n'y a pas d'entrée DNS sur le routeur, ajouter les noms utiles dans
`/etc/hosts` des postes clients, pointant vers `load_balancer_ip`.

## Upgrade

Helm **ne met pas à jour les CRDs** d'un chart lors d'un upgrade. Avant
de monter `chart_version` :

1. Lire les release notes du chart (une version majeure = breaking change).
2. Appliquer les CRDs de la nouvelle version (opération exceptionnelle
   documentée, `kubectl` étant la seule voie proposée par l'upstream) :

   ```bash
   helm show crds traefik/traefik --version <nouvelle-version> | kubectl apply --server-side --force-conflicts -f -
   ```

3. Monter `chart_version`, `terraform plan`, puis `apply`.

## Rollback

`terraform apply` avec l'ancienne `chart_version`. Les CRDs plus récentes
restent en place (rétrocompatibles en général). En dernier recours :
`terraform destroy -target=module.ingress` — coupe tout accès HTTP(S) au
cluster le temps de la réinstallation.

## Troubleshooting

- `EXTERNAL-IP` en `<pending>` → IP hors de la plage MetalLB, ou déjà
  attribuée à un autre Service : `kubectl -n traefik describe svc traefik`
  (événements MetalLB).
- IP attribuée mais injoignable depuis le LAN → conflit ARP avec une autre
  machine utilisant la même IP ; vérifier que l'IP est hors plage DHCP du
  routeur.
- Pod `Pending` → toleration control-plane manquante (cluster single-node).
- Dashboard :

  ```bash
  kubectl -n traefik port-forward deploy/traefik 8080:8080
  # puis http://localhost:8080/dashboard/
  ```
