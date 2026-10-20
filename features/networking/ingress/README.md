# networking/ingress

## Objectif

**Ingress public** du homelab : Traefik, sur une IP LAN fixe fournie par
MetalLB (`192.168.1.240`), la **seule** IP que la Freebox redirige depuis
Internet (80/443). Il ne sert que les applications publiques ; les
services internes (Vault, ArgoCD…) ont chacun leur propre IP et n'y
passent jamais ([ADR-009](../../../docs/adr/ADR-009-public-exposure.md),
option D ; historique : [ADR-006](../../../docs/adr/ADR-006-ingress-and-internal-tls.md)).

### Garde-fous (une ressource ne devient pas publique par erreur)

- IngressClass `traefik` **non par défaut** : un `Ingress` sans
  `ingressClassName: traefik` n'est pas servi ;
- provider `kubernetesIngress` limité aux namespaces de
  `public_namespaces` (aujourd'hui `inner-riddle`) : un `Ingress` ailleurs
  est ignoré. Liste vide interdite (pour Traefik, vide = tous) ;
- provider `kubernetesCRD` désactivé : les `IngressRoute` n'ont pas de
  classe et seraient toutes servies ;
- Gateway API désactivée.

Publier une application = `ingressClassName: traefik` **et** ajout de son
namespace à `public_namespaces` : deux changements visibles en revue.

## Dépendances

- `networking/metallb` — fournit l'IP du Service `LoadBalancer`
  (`depends_on` explicite dans `infrastructure/environments/homelab/main.tf`).

Utilisé par : `security/cert-manager` (le challenge HTTP-01 des
émetteurs Let's Encrypt est servi par cette classe), puis les applications
publiques (inner-riddle, [plan](../../../docs/plans/inner-riddle.md)).

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
| `public_namespaces` | Seuls namespaces servis (jamais vide) | — (requis, `["inner-riddle"]` au niveau env) |
| `requests_*` / `limits_*` | Ressources du pod | voir `variables.tf` |
| `tolerate_control_plane_taint` | Toleration control-plane (single-node) | `true` |

## Outputs

`namespace`, `ingress_class_name` (`traefik`), `load_balancer_ip`.

## HTTPS

- **Redirection** : tout le HTTP (port 80) est redirigé en permanence
  (301) vers HTTPS (443).
- **Certificats** : **Let's Encrypt** (annotation
  `cert-manager.io/cluster-issuer: letsencrypt-staging` pour valider, puis
  `letsencrypt`), voir [security/cert-manager](../../security/cert-manager/README.md).
  Le challenge HTTP-01 suit la redirection HTTP → HTTPS (Let's Encrypt ne
  vérifie pas le certificat à ce stade). Un nom sans certificat reçoit le
  certificat auto-signé par défaut de Traefik.
- **TLS terminé par Traefik** : entre Traefik et les pods, le trafic reste
  en HTTP à l'intérieur du cluster.
- **Journaux d'accès** activés (`kubectl -n traefik logs deploy/traefik`),
  en-têtes non journalisés.

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
public_namespaces        = ["inner-riddle", "keycloak"]
```

Puis `terraform plan` (doit montrer uniquement des créations dans
`module.ingress`) et `terraform apply`.

Vérification :

```bash
kubectl -n traefik get pods,svc          # pod Running, EXTERNAL-IP = load_balancer_ip
kubectl get ingressclass                 # traefik, SANS « (default) »
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.1.240/   # 404 attendu ; à lancer depuis un AUTRE poste du LAN
```

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

- `values don't meet the specifications of the schema` au `apply` → clé de
  values inconnue du chart (le chart valide ses values) ; ex. les journaux
  d'accès sont `accessLog.enabled` depuis le chart v38, plus
  `logs.access.enabled`.
- Une application publique répond `404` → vérifier que son namespace est
  dans `public_namespaces` et que son Ingress déclare
  `ingressClassName: traefik`.
- Ingress sans `ADDRESS` et Application ArgoCD bloquée en `Progressing`,
  journaux Traefik `Error while updating ingress status … namespace is not
  within watched namespaces` → Traefik essaie de recopier le status de son
  propre Service (`publishedService`, défaut du chart), qui est dans le
  namespace `traefik`, hors de `public_namespaces`. Rencontré le
  2026-10-20 : le module désactive `publishedService` et publie l'IP fixe
  (`ingressEndpoint.ip = load_balancer_ip`). Ne pas ajouter `traefik` à
  `public_namespaces` pour contourner (ADR-009). Le routage n'était pas
  touché, seulement la santé affichée.

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
