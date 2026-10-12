# ADR-009 — Exposition publique d'applications

**Statut : Proposé** (2026-10-12) — à valider par l'opérateur avant toute
implémentation.

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

Certificats :

| Option | Pour | Contre |
|---|---|---|
| **Let's Encrypt HTTP-01 (recommandé)** | Aucun secret à gérer (la clé du compte ACME est générée par cert-manager) | Port 80 ouvert ; le certificat n'est obtenu qu'une fois les ports redirigés |
| Let's Encrypt DNS-01 | Certificat obtenu avant l'ouverture ; wildcard possible | Jeton d'API du fournisseur DNS à ranger dans Vault ; dépend du fournisseur |

## Décision proposée

**Option A + Let's Encrypt HTTP-01.**

- Nouvelle feature `networking/public-ingress` (Terraform, comme
  `networking/ingress` — socle selon [ADR-008](ADR-008-gitops-layout.md)) :
  - IP `192.168.1.241` (variable, dans la plage MetalLB) ;
  - IngressClass `traefik-public`, `isDefaultClass = false` ;
  - provider `kubernetesIngress` restreint à cette classe **et** à une
    liste explicite de namespaces (`public_namespaces`, d'abord
    `["inner-riddle"]`) : double verrou ;
  - provider `kubernetesCRD` désactivé (les `IngressRoute` n'ont pas de
    classe : l'instance publique les servirait toutes) ;
  - CRDs non installées par cette release (déjà fournies par
    `networking/ingress`) ;
  - HTTP → HTTPS, sauf le chemin du challenge ACME ; journaux d'accès
    activés.
- `security/cert-manager` : ClusterIssuers `letsencrypt-staging` et
  `letsencrypt` (ACME HTTP-01, solveur sur la classe `traefik-public`).
  Adresse e-mail du compte ACME en variable (donnée non secrète).
- `networking/lan-dns` : zone supplémentaire facultative pour que les
  postes du LAN résolvent les noms publics vers `.241` directement (sans
  dépendre du NAT en épingle de la Freebox).
- Réseau (opérateur) : IPv4 publique complète (« full-stack ») sur la ligne
  Free ; enregistrement `A` de chaque nom public chez le gestionnaire du
  domaine ; redirection des ports 80 et 443 de la Freebox vers `.241`
  uniquement. IPv4 seulement (MetalLB ne fournit pas d'IP IPv6).

## Conséquences

- Publier une application = choisir `ingressClassName: traefik-public`
  **et** ajouter son namespace à `public_namespaces` : deux changements
  visibles en revue.
- La redirection de ports n'est faite qu'au moment de la mise en ligne
  d'une application prête (authentification en place).
- Vérification à faire depuis l'extérieur après ouverture : les noms
  `*.homelab.lan` ne répondent pas via l'IP publique.
- Surface d'attaque nouvelle : l'IP du domicile est publiée dans le DNS.
  Les applications publiques doivent gérer leur authentification et se
  protéger contre la force brute ; Traefik public peut ajouter une limite
  de débit globale.

## Décision

*À compléter après validation.*
