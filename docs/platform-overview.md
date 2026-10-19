# Vue d'ensemble — ce qui tourne et comment ça s'articule

Page d'explication de la plateforme **telle qu'elle est configurée
aujourd'hui** (2026-10-12). Elle ne remplace pas les README des features
(détail, upgrade, rollback, troubleshooting) ni les ADR (le pourquoi) :
elle relie les morceaux entre eux. À mettre à jour à chaque nouvelle
feature.

## 1. Le matériel et le réseau

Une seule machine, `NucBoxG3-Plus` (Ubuntu 26.04, 16 Go RAM), branchée sur
le LAN d'une Freebox Pop (Freebox OS 4.13), qui fait routeur, DHCP et DNS.
**Pas de DNS local** : les services internes s'ouvrent **par leur IP**
([ADR-007](adr/ADR-007-lan-dns.md) abandonné,
[ADR-009](adr/ADR-009-public-exposure.md)).

### Plan d'adressage

| Plage / adresse | Qui | Configuré où |
|---|---|---|
| `192.168.1.0/24` | LAN domestique | Freebox |
| `192.168.1.2` – `.200` | Adresses distribuées par le DHCP de la Freebox | Freebox → DHCP |
| `192.168.1.253` | NucBox (bail DHCP **statique**) | Freebox → DHCP → Baux statiques |
| `192.168.1.254` | Freebox (passerelle, DNS de tout le LAN) | — |
| `192.168.1.240` – `.250` | Réservé à MetalLB (IP des Services `LoadBalancer`), **hors** plage DHCP | Terraform (`metallb_ip_range`) |
| `192.168.1.240` | Traefik — ingress **public** (seule IP redirigée depuis Internet, une fois la redirection faite) ; ne sert que les namespaces de `public_namespaces` | Terraform (`ingress_load_balancer_ip`, `public_namespaces`) |
| `192.168.1.241` | Libre | — |
| `192.168.1.242` | **Registre Zot** — `https://192.168.1.242` ([ADR-010](adr/ADR-010-container-registry.md)) | ArgoCD (`gitops/apps/registry.yaml`) |
| `192.168.1.243` | **Vault** — `https://192.168.1.243:8200` | Terraform (`vault_load_balancer_ip`) |
| `192.168.1.244` | **ArgoCD** — `https://192.168.1.244` | Terraform (`argocd_load_balancer_ip`) |
| `192.168.1.245` | **Keycloak — console d'administration** — `https://192.168.1.245:8443`, jamais sur le nom public ([ADR-012](adr/ADR-012-identity-keycloak.md)) | ArgoCD (`gitops/apps/keycloak.yaml`) |
| `192.168.1.246` – `.250` | Services internes futurs | — |
| `10.244.0.0/16` | IP des pods (Calico) — invisibles depuis le LAN | Calico (voir [runbook](runbooks/calico-pod-cidr-migration.md)) |
| `10.96.0.0/12` | IP internes des Services Kubernetes (`ClusterIP`) | kubeadm |

Règles à retenir :

- **Rien de Kubernetes ne doit chevaucher le LAN** (c'était le cas au
  départ, pods en `192.168.0.0/16` : voir le runbook Calico).
- **Une IP par service interne**, qui termine lui-même son TLS ; **seule
  `192.168.1.240` (Traefik) sera un jour redirigée par la Freebox** : un
  service interne n'est donc jamais joignable depuis Internet, quelle que
  soit la configuration de Traefik.

## 2. Le chemin d'une requête

### Vers un service interne (aujourd'hui)

Exemple : un navigateur du LAN ouvre `https://192.168.1.243:8200` (Vault).

```
 Navigateur (poste du LAN, CA « Homelab Root CA » installée)
   │
   │ 1. connexion TCP vers 192.168.1.243:8200
   ▼
 MetalLB (speaker) — répond en ARP « 192.168.1.243, c'est le NucBox »
   │
   ▼
 Service Kubernetes vault (LoadBalancer) → pod vault-0
   │
   │ 2. TLS terminé par Vault lui-même : certificat signé par la CA
   │    interne, contenant l'IP 192.168.1.243
   ▼
 Vault (UI sous /ui/, API sous /v1/)
```

Même schéma pour ArgoCD (`https://192.168.1.244`, TLS par argocd-server).

### Vers une application publique (prévu, inner-riddle)

```
 Internet → inner-riddle.cybermimic.com (DNS chez OVH → IP publique de la ligne)
   → Freebox : redirection 80/443 → 192.168.1.240
   → Traefik (classe non par défaut, namespaces autorisés seulement)
   → certificat Let's Encrypt → Service → pods inner-riddle
```

Étapes et état : [plan inner-riddle](plans/inner-riddle.md).

## 3. Les composants

| Composant | Rôle | Namespace | Géré par | Détail |
|---|---|---|---|---|
| Kubernetes 1.36 (kubeadm), containerd, Calico v3.28 | Le cluster lui-même, single-node | `kube-system` | Installation manuelle initiale (playbook `bootstrap/` écrit mais jamais exécuté) | [bootstrap](../bootstrap/README.md) |
| MetalLB | Donne des IP du LAN aux Services `LoadBalancer` et les annonce en ARP | `metallb-system` | Terraform | [networking/metallb](../features/networking/metallb/README.md) |
| local-path-provisioner | Volumes persistants sur le disque du NucBox (StorageClass par défaut `local-path`) | `local-path-storage` | Terraform | [storage/local-path](../features/storage/local-path/README.md) |
| cert-manager + CA interne | Émet et renouvelle les certificats TLS des services internes, signés par « Homelab Root CA » ([certificat public](homelab-root-ca.crt) à installer sur les postes) | `cert-manager` | Terraform | [security/cert-manager](../features/security/cert-manager/README.md) |
| Vault | Coffre à secrets, `https://192.168.1.243:8200`, TLS de bout en bout | `vault` | Terraform (serveur) + humain (init / unseal / configuration) | [security/vault](../features/security/vault/README.md) |
| ArgoCD | GitOps, `https://192.168.1.244` ; Application racine qui suit `gitops/apps/` ([ADR-008](adr/ADR-008-gitops-layout.md)) | `argocd` | Terraform | [delivery/argocd](../features/delivery/argocd/README.md) |
| External Secrets | Pont Vault → Secrets Kubernetes (`ClusterSecretStore` `vault`) | `external-secrets` | **ArgoCD** | [security/external-secrets](../features/security/external-secrets/README.md) |
| Zot | Registre d'images, `https://192.168.1.242` (htpasswd via External Secrets) | `registry` | **ArgoCD** | [delivery/registry](../features/delivery/registry/README.md) |
| Actions Runner Controller | Runners GitHub Actions des dépôts privés (scale set `homelab`, DinD, 0 à 1 runner) | `arc-systems`, `arc-runners` | **ArgoCD** | [delivery/actions-runners](../features/delivery/actions-runners/README.md) |
| Traefik | Ingress **public** (classe non par défaut, namespaces autorisés) ; certificats Let's Encrypt | `traefik` | Terraform | [networking/ingress](../features/networking/ingress/README.md) |
| Keycloak | Fournisseur d'identité ; pages de connexion publiques `https://auth.cybermimic.com` (chemins explicites seulement), administration `https://192.168.1.245:8443` ([ADR-012](adr/ADR-012-identity-keycloak.md)) | `keycloak` | **ArgoCD** | [security/keycloak](../features/security/keycloak/README.md) |

Les pods « système » (apiserver, etcd, calico-node, kube-proxy, speaker
MetalLB) utilisent directement le réseau du NucBox (`hostNetwork`) ; les
autres ont une IP en `10.244.x.x`.

## 4. Où est configuré quoi

| Endroit | Contenu | Comment on le change |
|---|---|---|
| **Ce repo → Terraform** (`infrastructure/environments/homelab` + `features/*/terraform`) | Le socle : MetalLB, local-path, cert-manager, Vault, ArgoCD (+ Application racine), Traefik | Modifier le repo → synchroniser vers le répertoire d'état → `plan` → `apply` (voir [operations.md](operations.md)) |
| **Ce repo → ArgoCD** (`gitops/apps/` + `features/*/gitops`) | Tout ce qui est nouveau depuis l'ADR-008 : External Secrets, puis registre, runners, applications | Commit sur `main` : ArgoCD synchronise (automatique pour la plateforme, manuel pour les applications business) |
| **Répertoire d'état** `/home/hoarauv/.homelab-platform-state/` sur le NucBox | Le `terraform.tfstate` qui fait autorité + `terraform.tfvars` (plages IP, IP des services) | Jamais à la main, sauf `terraform.tfvars` ([ADR-005](adr/ADR-005-terraform-state.md)) |
| **Vault** (configuration interne) | Moteur `secret/` (kv-v2), authentification `kubernetes`, politiques, rôle `external-secrets` | Par l'humain, CLI du pod (`kubectl -n vault exec -it vault-0 -- sh`) |
| **La Freebox** (`http://192.168.1.254`) | Plage DHCP, bail statique du NucBox ; plus tard la redirection 80/443 → `.240` | Interface web Freebox OS, mode avancé |
| **OVH** (DNS de `cybermimic.com`) | `inner-riddle.cybermimic.com` → IP publique de la ligne | Espace client OVH |
| **Le NucBox (hôte)** | Paquets Kubernetes/containerd, réseau Calico | Ansible ([ADR-001](adr/ADR-001-terraform-scope.md)) : `bootstrap/ansible` — écrit mais **jamais exécuté**, l'état actuel a été fait à la main |

Ce qui n'est **jamais** dans le repo : les clés d'unseal et le root token
Vault (chez l'opérateur humain), le kubeconfig, tout secret
([ADR-003](adr/ADR-003-secret-management.md)).

## 5. Dépendances entre les briques

```
MetalLB ──► IP LAN de Vault (.243), ArgoCD (.244), Traefik (.240)
cert-manager (CA interne) ──► certificats de Vault et d'ArgoCD
local-path ──► Vault (volume de données)
ArgoCD ──► External Secrets ──► Vault (https://192.168.1.243:8200)
External Secrets ──► Keycloak (mot de passe PostgreSQL, compte admin, secret client inner-riddle)
local-path ──► Keycloak (volume PostgreSQL)
Traefik (ingress public) ──► Keycloak (pages de connexion, auth.cybermimic.com)
```

Elles sont explicites dans `infrastructure/environments/homelab/main.tf`
(passage d'outputs en inputs, ou `depends_on` commenté) et dans les
README des features.

## 6. Ce qu'il faut savoir au quotidien

- **Après un redémarrage du NucBox** : **Vault est scellé** → unseal
  manuel (3 clés sur 5), voir [security/vault](../features/security/vault/README.md),
  section 3. Tant qu'il est scellé, External Secrets ne peut rien lire.
- **Vérifier depuis un autre poste du LAN**, jamais seulement depuis le
  NucBox : une IP MetalLB répond toujours depuis le nœud lui-même, même
  quand elle est injoignable du reste du réseau (piège déjà rencontré).
- **Avant tout changement Terraform** : `plan` depuis le répertoire d'état,
  jamais d'`apply` sans l'avoir lu ([operations.md](operations.md)).
- **Mises à jour automatiques d'Ubuntu** (`unattended-upgrades`, vers
  6h30) : elles peuvent redémarrer NetworkManager (vu le 2026-09-28) ;
  les mises à jour du noyau attendent un redémarrage manuel.

## 7. Ressources consommées (ordre de grandeur)

Environ 3 Go de RAM utilisés sur 16 Go (Kubernetes lui-même compris).
Mesures des features (2026-09-27 / 2026-10-12) : MetalLB ~70 Mi,
local-path ~10 Mi, Vault ~30 Mi, Traefik ~20 Mi, cert-manager ~50 Mi,
ArgoCD ~120 Mi (à vide). Keycloak ajoute ~700 Mi-1 Gi (opérateur +
serveur + PostgreSQL, estimation ADR-012, à mesurer après déploiement).
~10-11 Gi restent disponibles.

## 8. Dette connue

Tenue à jour dans [operations.md](operations.md) (« Limitations connues »,
« DNS », « Calico ») : pas de backend Terraform distant, bootstrap Ansible
jamais exécuté, unseal Vault manuel, incohérence volontaire du
`cluster-cidr` (Calico), clé SSH partagée GitHub/NucBox, pas de
surveillance ni d'alerte.
