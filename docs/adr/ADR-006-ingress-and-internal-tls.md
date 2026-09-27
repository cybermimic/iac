# ADR-006 — Ingress (Traefik) et TLS interne (CA cert-manager)

## Contexte

Les services de plateforme (Vault, puis ArgoCD, monitoring…) doivent être
joignables depuis le LAN en HTTPS, derrière une seule IP stable fournie
par MetalLB (`networking/metallb`), plutôt que via des `kubectl
port-forward` ou une IP LoadBalancer par service.

Le cluster n'est pas exposé sur Internet : aucun port n'est ouvert sur le
routeur, et il n'y a pas de nom de domaine public dédié.

## Problème

1. Choisir un contrôleur d'entrée HTTP(S).
2. Choisir comment émettre des certificats TLS pour des noms internes au
   LAN, sans exposition Internet.

## Décision

1. **Traefik** (chart Helm officiel `traefik/traefik`) comme contrôleur
   d'ingress, exposé via un Service `LoadBalancer` MetalLB sur une IP LAN
   fixe. Il sert l'API `Ingress` standard (IngressClass `traefik`, classe
   par défaut) et ses CRDs `IngressRoute`/`Middleware`.
2. **CA interne gérée par cert-manager** (feature `security/cert-manager`,
   étape suivante) : cert-manager génère une autorité de certification
   racine propre au homelab et signe les certificats des services. Le
   certificat de cette CA est importé une fois dans les navigateurs/OS des
   postes clients. Les noms (ex. `*.homelab.lan`) sont résolus par
   `/etc/hosts` ou le DNS du routeur vers l'IP de l'ingress.

## Alternatives considérées

- **ingress-nginx** : rejeté — projet retiré par Kubernetes SIG Network
  (fin de maintenance mars 2026), plus de correctifs de sécurité.
- **Envoy Gateway** (Gateway API) : techniquement plus moderne, mais plus
  lourd (~150-300 Mi RAM contre ~50-100 Mi) et plus de concepts
  (GatewayClass, Gateway, HTTPRoute) pour un besoin encore simple. Traefik
  sait aussi servir Gateway API : une migration reste possible sans
  changer de contrôleur (provider `kubernetesGateway`, désactivé pour
  l'instant).
- **Let's Encrypt (DNS-01) sur un vrai domaine** : certificats reconnus
  partout, mais nécessite un domaine public et un token API DNS à gérer
  comme secret. Disproportionné tant que tout reste interne au LAN ;
  cert-manager permettra de basculer plus tard sans changer d'outil.
- **HTTP sans TLS** : rejeté comme cible (Vault doit passer en TLS), toléré
  uniquement entre le déploiement de l'ingress et celui de cert-manager.

## Conséquences

- Une IP LAN de la plage MetalLB est réservée à l'ingress
  (`ingress_load_balancer_ip`), à déclarer dans le DNS du routeur ou dans
  `/etc/hosts` des postes clients.
- Tant que cert-manager n'est pas déployé, Traefik répond en HTTPS avec
  son certificat auto-signé par défaut (avertissement navigateur attendu).
- Le certificat de la CA interne devra être distribué manuellement aux
  postes clients — c'est une donnée publique, pas un secret ; la clé
  privée de la CA, elle, ne quitte jamais le cluster.
- Upgrade Traefik : Helm ne met pas à jour les CRDs d'un chart ; la
  procédure d'upgrade (README de la feature) les applique explicitement
  avant de monter la version du chart.
