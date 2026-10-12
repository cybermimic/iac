# ADR-010 — Registre d'images

**Statut : Acceptée** (2026-10-12) — Zot, publié par IP (voir « Décision »).

## Contexte

Les applications business (d'abord inner-riddle) doivent être déployées
depuis des images versionnées. L'opérateur veut un registre **dans le
homelab** plutôt qu'un registre hébergé (GHCR, Docker Hub).

Contraintes : 16 Go de RAM sur un nœud unique, stockage `local-path`,
publication HTTPS par l'ingress interne et la CA interne, aucun secret dans
Git ([ADR-003](ADR-003-secret-management.md)).

## Options

| Option | RAM | Pour | Contre |
|---|---|---|---|
| **A. Zot (recommandé)** | ~50-150 Mi | Registre OCI natif (images, charts Helm OCI, signatures), binaire unique, authentification htpasswd, nettoyage et rétention intégrés, interface web optionnelle ; projet CNCF | Moins répandu que Distribution |
| B. Distribution (`registry`) | ~20-50 Mi | La référence historique, minimal | Pas d'interface ; le ramasse-miettes exige de passer le registre en lecture seule ; pas de rétention par règles |
| C. Harbor | ~1,5-2,5 Gi | Complet : projets, rôles, analyse de vulnérabilités, réplication | 6 à 8 pods, base PostgreSQL et Redis : disproportionné pour un nœud de 16 Go |

## Décision proposée

**Zot**, feature `delivery/registry` (gérée par ArgoCD si l'ADR-008 est
adoptée, sinon Terraform comme le socle) :

- publié sur `https://registry.homelab.lan` par l'ingress **interne**
  (jamais public), certificat de la CA interne ;
- volume `local-path` (20 Gi au départ) ; rétention : garder les N
  dernières versions par dépôt, ramasse-miettes quotidien ;
- authentification htpasswd : un compte d'écriture (CI) et un compte de
  lecture (cluster). Le fichier htpasswd vient de Vault par External
  Secrets ;
- les pods tirent les images avec un `imagePullSecret` (compte de
  lecture), lui aussi fourni par External Secrets.

Confiance dans la CA interne :

- **containerd sur le NucBox** doit faire confiance à « Homelab Root CA »
  pour tirer depuis `registry.homelab.lan`. Installation dans le magasin de
  confiance du système (`/usr/local/share/ca-certificates/`) puis
  redémarrage de containerd, par un playbook Ansible
  (`features/delivery/registry/ansible/`, exécuté par l'opérateur avec
  `-K`) — configuration d'hôte, donc hors Terraform
  ([ADR-001](ADR-001-terraform-scope.md)).
- Les postes qui poussent des images (développement, runners) font de même
  pour Docker (scripts `security/cert-manager/clients`).

## Conséquences

- Dépend de `security/external-secrets` (htpasswd et pull secret), de
  `networking/metallb` (IP `192.168.1.242`) et de `security/cert-manager`.
- Le registre n'est joignable que depuis le LAN : la CI GitHub hébergée ne
  peut pas y publier. Publication automatique = runners dans le cluster
  ([ADR-011](ADR-011-ci-runners.md)) ; en attendant, publication manuelle
  depuis un poste du LAN.
- Les images et le registre partagent le disque du NucBox : perdre le
  disque, c'est perdre les images (reconstructibles depuis Git par
  étiquette).

## Décision

**Zot**, accepté le 2026-10-12, avec un changement par rapport à la
proposition : sans DNS local ([ADR-007](ADR-007-lan-dns.md) abandonné) et
avec Traefik réservé au public ([ADR-009](ADR-009-public-exposure.md)), le
registre **n'a pas d'Ingress** :

- publié sur **`https://192.168.1.242`** par un `Service` `LoadBalancer`
  (MetalLB), Zot terminant lui-même le TLS avec un certificat de la CA
  interne contenant l'IP ; jamais redirigé par la Freebox, donc jamais
  public ;
- les références d'images deviennent
  `192.168.1.242/inner-riddle/{backend,frontend}:X.Y.Z` ;
- containerd (NucBox) et Docker (runners, postes) font confiance à la CA
  interne pour cette adresse (playbook Ansible pour le NucBox, comme
  prévu) ;
- le reste est inchangé : `local-path` 20 Gi, rétention + ramasse-miettes,
  htpasswd (compte d'écriture pour la CI, de lecture pour le cluster) et
  pull secret fournis par Vault + External Secrets ; feature
  `delivery/registry` livrée par ArgoCD ([ADR-008](ADR-008-gitops-layout.md)).
