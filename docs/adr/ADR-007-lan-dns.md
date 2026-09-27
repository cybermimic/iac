# ADR-007 — DNS du homelab pour les postes du LAN

## Contexte

[ADR-006](ADR-006-ingress-and-internal-tls.md) publie les services derrière
l'ingress Traefik (`192.168.1.240`) sous des noms `*.homelab.lan`. Les
appareils du LAN doivent résoudre ces noms.

Le routeur est une Freebox (Freebox OS 4.13, vérifié le 2026-09-27) :

- elle ne permet **pas** de créer des enregistrements DNS locaux (ni hôte,
  ni wildcard) ;
- elle permet de choisir les DNS distribués par son DHCP IPv4 ;
- elle annonce aussi un DNS en IPv6 (par défaut le sien,
  `fd0f:ee:b0::1`, constaté sur un poste Windows), qu'on peut **forcer**
  vers d'autres serveurs, mais uniquement avec des adresses IPv6.

Le cluster est IPv4 uniquement : MetalLB ne peut pas fournir d'IP
LoadBalancer IPv6.

## Décision

Un **CoreDNS dédié** dans le cluster (feature `networking/lan-dns`),
distinct du DNS interne du cluster, **distribué à tout le LAN par la
Freebox** :

- `*.homelab.lan` → IP de l'ingress (wildcard : aucun enregistrement à
  ajouter quand un service est publié) ;
- tout le reste → transféré au DNS de la Freebox ;
- pod en `hostNetwork`, écoutant sur l'IPv4 LAN (`192.168.1.253`, bail
  DHCP statique) et l'IPv6 globale du NucBox (stable : dérivée de sa carte
  réseau et du préfixe fixe de la ligne Free) ;
- Freebox : DNS 1 du DHCP = IPv4 du NucBox, DNS IPv6 forcé = IPv6 du
  NucBox, **aucun secondaire**.

C'est le modèle classique d'un DNS local de réseau domestique (type
Pi-hole) : tous les appareils sont couverts, téléphones compris, sans
réglage par appareil.

## Alternatives considérées

- **Enregistrements DNS sur la Freebox** : impossible (fonction absente).
- **Règle DNS par domaine sur chaque poste** (NRPT Windows,
  `Domains=~homelab.lan` systemd-resolved) vers une IP MetalLB : mis en
  place puis abandonné le même jour — Internet ne dépend pas du NucBox,
  mais réglage manuel par appareil et téléphones non couverts.
- **Vrai nom de domaine public + Let's Encrypt** (wildcard public vers
  `192.168.1.240`) : aucune dépendance au NucBox pour Internet, rien à
  régler sur la Freebox, certificats reconnus partout. Écarté par choix
  (pas de dépendance à un domaine / hébergeur DNS externe) ; reste
  l'option de repli si la dépendance au NucBox devient gênante.
- **IP MetalLB IPv6 / cluster dual-stack** : refonte réseau du cluster
  disproportionnée pour ce seul besoin.
- **Pi-hole / AdGuard Home / Blocky** : font la même chose avec une UI et
  du filtrage publicitaire, mais plus lourds (stockage, UI à exposer et
  sécuriser) pour un besoin qui tient en quelques lignes de Corefile.
  Remplaçables plus tard sur les mêmes adresses.

## Conséquences

- **Tout le LAN dépend du NucBox pour résoudre les noms, Internet
  compris.** NucBox arrêté = plus de navigation pour aucun appareil, tant
  que le pod n'est pas revenu ou que la Freebox n'est pas remise en DNS
  (procédure de rollback d'urgence : README de la feature).
- Pas de DNS secondaire possible vers la Freebox (les clients
  l'interrogeraient au hasard et `*.homelab.lan` échouerait par
  intermittence).
- Le NucBox lui-même ne doit pas utiliser ce DNS (sinon il en dépend au
  démarrage) : il ignore les DNS annoncés et utilise directement la
  Freebox.
- Si le préfixe IPv6 de la ligne change, l'IPv6 du NucBox change : mettre
  à jour `lan_dns_listen_addresses` **et** le DNS IPv6 de la Freebox.
- Le domaine `homelab.lan` n'est pas un TLD réservé. Il ne doit jamais être
  utilisé pour autre chose que ce homelab ; `home.arpa` (RFC 8375) reste
  une alternative si un conflit apparaît.
