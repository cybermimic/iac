# Vue d'ensemble — ce qui tourne et comment ça s'articule

Page d'explication de la plateforme **telle qu'elle est configurée
aujourd'hui** (2026-09-27). Elle ne remplace pas les README des features
(détail, upgrade, rollback, troubleshooting) ni les ADR (le pourquoi) :
elle relie les morceaux entre eux. À mettre à jour à chaque nouvelle
feature.

## 1. Le matériel et le réseau

Une seule machine, `NucBoxG3-Plus` (Ubuntu 26.04, 16 Go RAM), branchée sur
le LAN d'une Freebox Pop (Freebox OS 4.13), qui fait routeur, DHCP et DNS
amont.

### Plan d'adressage

| Plage / adresse | Qui | Configuré où |
|---|---|---|
| `192.168.1.0/24` | LAN domestique | Freebox |
| `192.168.1.2` – `.200` | Adresses distribuées par le DHCP de la Freebox | Freebox → DHCP |
| `192.168.1.253` | NucBox (bail DHCP **statique**) | Freebox → DHCP → Baux statiques |
| `2a01:e0a:818:4440:e251:d8ff:fe1c:4928` | IPv6 globale du NucBox (stable : dérivée de sa carte réseau + préfixe fixe de la ligne Free) | Automatique (SLAAC) |
| `192.168.1.254` | Freebox (passerelle, DNS amont) | — |
| `192.168.1.240` – `.250` | Réservé à MetalLB (IP des Services `LoadBalancer`), **hors** plage DHCP | Terraform (`metallb_ip_range`) |
| `192.168.1.240` | Ingress Traefik — porte d'entrée HTTP(S) de tous les services | Terraform (`ingress_load_balancer_ip`) |
| `192.168.1.241` – `.250` | Libres | — |
| `10.244.0.0/16` | IP des pods (Calico) — invisibles depuis le LAN | Calico (voir [runbook](runbooks/calico-pod-cidr-migration.md)) |
| `10.96.0.0/12` | IP internes des Services Kubernetes (`ClusterIP`) | kubeadm |

Règle à retenir : **rien de Kubernetes ne doit chevaucher le LAN**. C'était
le cas au départ (pods en `192.168.0.0/16`) et ça coupait les pods du LAN
— corrigé, voir le runbook.

## 2. Le chemin d'une requête

Exemple : un navigateur du LAN ouvre `https://vault.homelab.lan`.

```
 Navigateur (PC, téléphone…)
   │
   │ 1. « Quelle est l'IP de vault.homelab.lan ? »
   │    (le DNS lui a été donné par le DHCP / l'IPv6 de la Freebox)
   ▼
 DNS du homelab — pod lan-dns (CoreDNS), sur 192.168.1.253:53
   │    *.homelab.lan  → répond 192.168.1.240 (wildcard, aucun nom à déclarer)
   │    tout le reste  → transmis à la Freebox (192.168.1.254)
   │
   │ 2. connexion HTTP(S) vers 192.168.1.240
   ▼
 MetalLB (speaker) — répond en ARP « 192.168.1.240, c'est le NucBox »
   │
   ▼
 Traefik (pod, namespace traefik) — lit le nom demandé (Host / SNI)
   │    et choisit le service correspondant (Ingress / IngressRoute)
   │
   ▼
 Service Kubernetes → pod de l'application (ex. vault-0)
```

État actuel de cette chaîne : les étapes DNS → MetalLB → Traefik
fonctionnent depuis tout le LAN. **Aucun service n'est encore publié**
derrière Traefik (il répond `404`) et le HTTPS utilise un certificat
auto-signé : c'est l'objet de `security/cert-manager`, étape suivante.

## 3. Les composants

| Composant | Rôle | Namespace | Géré par | Détail |
|---|---|---|---|---|
| Kubernetes 1.36 (kubeadm), containerd, Calico v3.28 | Le cluster lui-même, single-node | `kube-system` | Installation manuelle initiale (playbook `bootstrap/` écrit mais jamais exécuté) | [bootstrap](../bootstrap/README.md) |
| MetalLB | Donne des IP du LAN aux Services `LoadBalancer` et les annonce en ARP | `metallb-system` | Terraform | [networking/metallb](../features/networking/metallb/README.md) |
| local-path-provisioner | Volumes persistants sur le disque du NucBox (StorageClass par défaut `local-path`, fichiers sous `/opt/local-path-provisioner`) | `local-path-storage` | Terraform | [storage/local-path](../features/storage/local-path/README.md) |
| Vault | Coffre à secrets (initialisé, 1 Gi de données sur `local-path`) | `vault` | Terraform (serveur) + humain (init / unseal) | [security/vault](../features/security/vault/README.md) |
| Traefik | Ingress : porte d'entrée HTTP(S) unique, `192.168.1.240` | `traefik` | Terraform | [networking/ingress](../features/networking/ingress/README.md) |
| CoreDNS « lan-dns » | DNS de tout le LAN (`*.homelab.lan` + relais vers la Freebox) | `lan-dns` | Terraform + réglages Freebox | [networking/lan-dns](../features/networking/lan-dns/README.md) |

Les pods « système » (apiserver, etcd, calico-node, kube-proxy, speaker
MetalLB, lan-dns) utilisent directement le réseau du NucBox
(`hostNetwork`) ; les autres ont une IP en `10.244.x.x`.

## 4. Où est configuré quoi

La plateforme n'est pas entièrement dans Terraform. Il y a quatre
endroits, à connaître avant de modifier quoi que ce soit :

| Endroit | Contenu | Comment on le change |
|---|---|---|
| **Ce repo → Terraform** (`infrastructure/environments/homelab` + `features/*/terraform`) | Tout ce qui tourne dans Kubernetes au-dessus du socle : MetalLB, local-path, Vault, Traefik, lan-dns | Modifier le repo → synchroniser vers le répertoire d'état → `plan` → `apply` (voir [operations.md](operations.md)) |
| **Répertoire d'état** `/home/hoarauv/.homelab-platform-state/` sur le NucBox | Le `terraform.tfstate` qui fait autorité + `terraform.tfvars` (valeurs propres au réseau : plages IP, adresses du DNS) | Jamais à la main, sauf `terraform.tfvars` ([ADR-005](adr/ADR-005-terraform-state.md)) |
| **La Freebox** (`http://192.168.1.254`) | Plage DHCP, bail statique du NucBox, DNS distribués (IPv4 : `192.168.1.253` ; IPv6 forcé : IPv6 du NucBox) | Interface web Freebox OS, mode avancé — documenté dans [lan-dns](../features/networking/lan-dns/README.md) |
| **Le NucBox (hôte)** | Paquets Kubernetes/containerd, réseau Calico, DNS propre du NucBox (utilise directement la Freebox, NetworkManager) | Manuel pour l'instant ; cible : playbook Ansible `bootstrap/` ([ADR-001](adr/ADR-001-terraform-scope.md)) |

Et ce qui n'est **jamais** dans le repo : les clés d'unseal et le root
token Vault (chez l'opérateur humain), le kubeconfig, tout secret
([ADR-003](adr/ADR-003-secret-management.md)).

## 5. Dépendances entre les briques

```
MetalLB ──► Traefik (IP .240) ──► lan-dns (le wildcard pointe vers Traefik)
                  │
                  └──► (bientôt) cert-manager ──► services en HTTPS (Vault…)
local-path ──► Vault (volume de données)
Freebox (DHCP/DNS) ──► lan-dns ──► tout le LAN
```

Elles sont explicites dans `infrastructure/environments/homelab/main.tf`
(passage d'outputs en inputs, ou `depends_on` commenté).

## 6. Ce qu'il faut savoir au quotidien

- **Après un redémarrage du NucBox** :
  1. le LAN n'a **pas de DNS** tant que le pod `lan-dns` n'est pas relancé
     (en général moins d'une minute après le démarrage de Kubernetes) ;
  2. **Vault est scellé** : faire l'unseal (3 clés sur 5) — voir
     [security/vault](../features/security/vault/README.md), section 3.
- **NucBox en panne durable** : rendre le DNS à la Freebox (Rollback
  d'urgence de [lan-dns](../features/networking/lan-dns/README.md)), sinon
  plus aucun appareil ne navigue.
- **Vérifier depuis un autre poste du LAN**, jamais seulement depuis le
  NucBox : une IP MetalLB répond toujours depuis le nœud lui-même, même
  quand elle est injoignable du reste du réseau (piège déjà rencontré).
- **Avant tout changement Terraform** : `plan` depuis le répertoire d'état,
  jamais d'`apply` sans l'avoir lu ([operations.md](operations.md)).

## 7. Ressources consommées (ordre de grandeur)

Environ 2,5-3 Go de RAM utilisés sur 16 Go (Kubernetes lui-même compris).
Les features ajoutées jusqu'ici pèsent peu : MetalLB ~50 Mi, local-path
~30 Mi, Vault 128-512 Mi, Traefik ~50-100 Mi, lan-dns ~30 Mi.

## 8. Dette connue

Tenue à jour dans [operations.md](operations.md) (sections « Limitations
connues », « DNS du LAN », « Calico ») : pas de backend Terraform distant, bootstrap Ansible jamais
exécuté, Vault sans TLS (en cours), réglage DNS du NucBox non porté dans
Ansible, incohérence volontaire du `cluster-cidr` (Calico), clé SSH
partagée GitHub/NucBox.
