# ADR-007 — DNS du homelab pour les postes du LAN

## Contexte

[ADR-006](ADR-006-ingress-and-internal-tls.md) publie les services derrière
l'ingress Traefik (`192.168.1.240`) sous des noms `*.homelab.lan`. Les
postes du LAN doivent résoudre ces noms.

Le routeur est une Freebox (Freebox OS 4.13, vérifié le 2026-09-27) :
elle ne permet **pas** de créer des enregistrements DNS locaux (ni hôte, ni
wildcard). Elle permet seulement de choisir les serveurs DNS distribués
par son DHCP (IPv4). Elle annonce par ailleurs son propre DNS en IPv6
(`fd0f:ee:b0::1`, via les annonces de routeur), indépendamment du DHCP.

## Décision

Un **CoreDNS dédié** dans le cluster (feature `networking/lan-dns`),
distinct du DNS interne du cluster, exposé en UDP+TCP 53 sur une IP LAN
fixe MetalLB (`192.168.1.241`) :

- `*.homelab.lan` → IP de l'ingress (wildcard : aucun enregistrement à
  ajouter quand un service est publié) ;
- tout le reste → transféré au DNS de la Freebox.

Les postes l'utilisent via une **règle de résolution par domaine**
(`.homelab.lan` → `192.168.1.241` : NRPT sous Windows, `Domains=~homelab.lan`
avec systemd-resolved), **pas** via le DHCP de la Freebox. Constaté sur le
poste Windows : il reçoit aussi le DNS IPv6 de la Freebox
(`fd0f:ee:b0::1`), qui ne connaît pas `homelab.lan` et aurait court-circuité
un DNS distribué par le DHCP IPv4. Détail : README de la feature, section
« Configuration des postes ».

## Alternatives considérées

- **Enregistrements DNS sur la Freebox** : impossible (fonction absente).
- **Fichier hosts sur chaque poste** : aucun composant en plus, mais pas de
  wildcard — une ligne par service et par poste. Rejeté comme cible,
  reste un dépannage acceptable.
- **Pi-hole / AdGuard Home / Blocky** : font la même chose avec une UI et
  du filtrage publicitaire, mais plus lourds (stockage, UI à exposer et
  sécuriser) pour un besoin qui tient en quelques lignes de Corefile.
  Remplaçables plus tard sans changer d'IP.

## Conséquences

- Si le NucBox (ou le pod) est arrêté, seuls les noms `*.homelab.lan` ne
  résolvent plus ; Internet n'est jamais affecté (les postes gardent le DNS
  de la Freebox pour tout le reste).
- Chaque poste qui doit accéder au homelab est configuré une fois. Les
  appareils sans réglage DNS par domaine (téléphones) ne sont pas couverts
  pour l'instant.
- Le domaine `homelab.lan` n'est pas un TLD réservé. Il ne doit jamais être
  utilisé pour autre chose que ce homelab ; `home.arpa` (RFC 8375) reste
  une alternative si un conflit apparaît.
- Seconde IP de la plage MetalLB réservée (`192.168.1.241`).
