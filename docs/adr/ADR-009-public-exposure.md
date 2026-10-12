# ADR-009 — Exposition publique d'applications

**Statut : Acceptée** (2026-10-12) — option D ci-dessous, retenue par
l'opérateur après l'abandon du DNS local ([ADR-007](ADR-007-lan-dns.md)).

## Contexte

Jusqu'ici, rien n'est joignable depuis Internet ([ADR-006](ADR-006-ingress-and-internal-tls.md)) :
aucun port ouvert sur la Freebox, tous les services sous `*.homelab.lan`
avec la CA interne.

La première application business, **inner-riddle**
([dépôt](https://github.com/cybermimic/inner-riddle)), doit être publiée sur
`https://inner-riddle.cybermimic.com` (domaine possédé par l'opérateur),
pour être utilisée hors du domicile et consultée en lecture seule par un
tiers. L'application gère elle-même l'authentification et les rôles.

## Problème

Le Traefik actuel est la classe d'ingress **par défaut** et sert Vault et
ArgoCD. Traefik route selon l'en-tête `Host` : si la Freebox redirigeait
443 vers `192.168.1.240`, n'importe qui sur Internet pourrait atteindre
`vault.homelab.lan` ou `argocd.homelab.lan` en forgeant cet en-tête. Une
ressource publiée « par erreur » ne doit pas pouvoir devenir publique.

Il faut aussi des certificats reconnus par tous les navigateurs (la CA
interne n'est installée que sur les postes de l'opérateur).

## Options

| Option | Principe | RAM | Pour | Contre |
|---|---|---|---|---|
| **A. Seconde instance Traefik « public » (recommandé)** | Release Helm distincte, IP MetalLB `192.168.1.241`, IngressClass `traefik-public` **non** par défaut, limitée aux namespaces listés ; la Freebox ne redirige que vers `.241` | +50-100 Mi | Isolation par construction : l'instance interne n'est jamais joignable depuis Internet ; une application devient publique par une décision explicite (classe + namespace autorisé) | Une release de plus à maintenir |
| B. Traefik unique, entrypoints séparés | Ports dédiés au public, chaque Ingress interne épinglé sur l'entrypoint interne | 0 | Rien à installer | Par défaut, Traefik attache un routeur à **tous** les entrypoints : une annotation oubliée publie un service interne. Sécurité par discipline, pas par construction |
| C. Cloudflare Tunnel | Agent `cloudflared` sortant, aucun port ouvert | ~30 Mi | Pas d'exposition de l'IP, pas de port ouvert | DNS du domaine chez Cloudflare, dépendance à un tiers qui voit le trafic en clair — écarté par l'opérateur |
| **D. Traefik unique réservé au public, services internes chacun sur sa propre IP (retenu)** | Le Traefik existant (`192.168.1.240`) ne sert plus que les applications publiques ; Vault, ArgoCD, le registre… quittent Traefik et reçoivent chacun une IP MetalLB et terminent eux-mêmes leur TLS (CA interne) ; la Freebox ne redirige que vers `.240` | 0 (retire même des Ingress) | Isolation **par le réseau** : aucune IP interne n'est jamais redirigée, donc injoignable depuis Internet quelle que soit la configuration de Traefik ; cohérent avec l'accès par IP retenu après l'abandon du DNS local | Accès aux outils internes par IP ; chaque service interne consomme une IP de la plage MetalLB (`.240`-`.250`) et gère son propre TLS |

Certificats :

| Option | Pour | Contre |
|---|---|---|
| **Let's Encrypt HTTP-01 (recommandé)** | Aucun secret à gérer (la clé du compte ACME est générée par cert-manager) | Port 80 ouvert ; le certificat n'est obtenu qu'une fois les ports redirigés |
| Let's Encrypt DNS-01 | Certificat obtenu avant l'ouverture ; wildcard possible | Jeton d'API du fournisseur DNS à ranger dans Vault ; dépend du fournisseur |

## Décision proposée (initiale)

Option A + Let's Encrypt HTTP-01 — remplacée par l'option D (voir
« Décision » ci-dessous) : l'option A supposait que les services internes
restent servis par nom derrière le Traefik interne, ce qui n'est plus le
cas sans DNS local.

## Conséquences

- Publier une application = `ingressClassName: traefik` **et** ajouter son
  namespace à la liste autorisée de Traefik : deux changements visibles en
  revue.
- Un service interne n'a **jamais** d'Ingress : il est publié par un
  `Service` `LoadBalancer` sur sa propre IP. Une IP interne n'est jamais
  redirigée par la Freebox.
- La redirection de ports n'est faite qu'au moment de la mise en ligne
  d'une application prête (authentification en place).
- Vérification à faire depuis l'extérieur après ouverture : seule
  l'application publique répond via l'IP publique ; `vault.homelab.lan` &
  co. (s'ils subsistent) renvoient `404`.
- Accès depuis le LAN au nom public : passe par l'IP publique et le NAT en
  épingle (« hairpin ») de la Freebox — à vérifier à la mise en ligne ; à
  défaut, entrée `hosts` vers `192.168.1.240` sur les postes concernés.
- Surface d'attaque nouvelle : l'IP du domicile est publiée dans le DNS.
  Les applications publiques gèrent leur authentification et se protègent
  contre la force brute ; Traefik peut ajouter une limite de débit globale.

## Décision

**Option D + Let's Encrypt HTTP-01**, acceptée le 2026-10-12.

- `networking/ingress` (Traefik existant, `192.168.1.240`) devient
  l'ingress **public** :
  - IngressClass `traefik` **non** par défaut (`isDefaultClass = false`) ;
  - provider `kubernetesIngress` restreint à une liste explicite de
    namespaces (`public_namespaces`, d'abord `["inner-riddle"]`) ;
  - provider `kubernetesCRD` désactivé (les `IngressRoute` n'ont pas de
    classe et seraient toutes servies) ;
  - HTTP → HTTPS sauf le chemin du challenge ACME ; journaux d'accès
    activés.
- Les Ingress de Vault et d'ArgoCD sont retirés ; chaque service interne
  reçoit une IP MetalLB et son propre certificat de la CA interne (IP dans
  le certificat). Plan d'adressage :

  | IP | Usage |
  |---|---|
  | `192.168.1.240` | Traefik — **public** (seule IP redirigée par la Freebox) |
  | `192.168.1.241` | libre (ex-réservation `lan-dns`, jamais utilisée) |
  | `192.168.1.242` | Registre Zot ([ADR-010](ADR-010-container-registry.md)) |
  | `192.168.1.243` | Vault |
  | `192.168.1.244` | ArgoCD |
  | `192.168.1.245`-`.250` | services internes futurs |

- `security/cert-manager` : ClusterIssuers `letsencrypt-staging` et
  `letsencrypt` (ACME HTTP-01, solveur sur la classe `traefik`). Adresse
  e-mail du compte ACME en variable (donnée non secrète).
- Réseau (opérateur) : IPv4 publique complète (« full-stack ») sur la
  ligne Free ; enregistrement `A` de chaque nom public chez OVH (DNS de
  `cybermimic.com`) ; redirection des ports 80 et 443 de la Freebox vers
  `192.168.1.240` uniquement. IPv4 seulement (MetalLB ne fournit pas d'IP
  IPv6).
