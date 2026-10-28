# Runbook — reconstruire la plateforme

> **BROUILLON — JAMAIS EXÉCUTÉ.** Ordre reconstitué le 2026-10-27 à partir
> des README et du code ; aucune étape n'a été rejouée de bout en bout. Le
> premier exercice réel est prévu à l'arrivée d'une machine vierge (temps 1
> du [plan fleet-manager](../plans/fleet-manager.md)). Chaque écart constaté
> pendant l'exercice corrige ce document.

Deux cas, signalés à chaque étape :

- **vierge** : nouveau cluster, sans données à récupérer ;
- **avec données** : restauration après la perte du NucBox. Aujourd'hui
  **impossible en grande partie** : ni Vault, ni la CA, ni etcd, ni les bases
  ne sont sauvegardés hors du disque du NucBox (voir
  [registre des secrets](../secrets.md), section 5, et
  [ADR-014](../adr/ADR-014-secrets-for-rebuild.md)).

Légende : 👤 opérateur (secrets, sudo, comptes externes) ; 🤖 agent possible
(lecture, `plan`, `apply` après accord). Fin de chaque étape : la vérification
indiquée, puis `./hack/status.py` dès que l'API répond.

## 0. Avant de commencer

- 👤 Avoir hors ligne : clés d'unseal et root token de Vault ; copie de la
  CA interne (si P3 de l'ADR-014 est en place, sinon voir étape 4).
- 👤 Freebox : bail DHCP statique `192.168.1.253` pour la nouvelle machine,
  plage DHCP limitée à `.2`-`.200` (MetalLB utilise `.240`-`.250`),
  redirection 80/443 → `192.168.1.240` ([platform-overview](../platform-overview.md)).
- Lire l'[incident des coupures réseau](../incidents/2026-10-nucbox-link-drops.md) :
  appliquer ses remédiations retenues dès l'étape 1.

## 1. Hôte (Ansible)

- 👤 Ubuntu 26.04 installé, accès SSH.
- 👤 `bootstrap/ansible` : inventaire local, puis
  `ansible-playbook playbook.yml --check --diff -K`, puis sans `--check`
  ([bootstrap](../../bootstrap/README.md)). **Première exécution réelle de ce
  playbook** : noter tout écart.
- 👤 Confiance dans la CA interne pour containerd :
  `features/delivery/registry/ansible/playbook.yml` ([registry](../../features/delivery/registry/README.md)).
  Si la CA a changé (étape 4), le relancer avec le nouveau certificat.

## 2. Cluster (kubeadm, Calico) — manuel

- 👤 `kubeadm init --pod-network-cidr=10.244.0.0/16` (**jamais** le défaut
  Calico `192.168.0.0/16`, qui englobe le LAN : [runbook Calico](calico-pod-cidr-migration.md)).
- 👤 Calico v3.28.0, `CALICO_IPV4POOL_CIDR=10.244.0.0/16`.
- Nœud unique : il porte la marque control-plane ; les features la tolèrent
  (`tolerate_control_plane_taint`).
- Vérifier : `kubectl get nodes` → `Ready` ; pods `kube-system` `Running`.

## 3. Socle (Terraform)

- 🤖 Répertoire d'état : un **nouveau** state pour un nouveau cluster est
  normal ; pour un cluster existant, ne jamais appliquer depuis un state vide
  sans `plan` relu ([ADR-005](../adr/ADR-005-terraform-state.md)).
- 🤖 `infrastructure/environments/homelab` : `terraform.tfvars` depuis
  l'exemple (non commité), `KUBECONFIG` explicite.
- 🤖 **Deux temps**, imposés par les CRD de cert-manager
  ([cert-manager](../../features/security/cert-manager/README.md)) :
  1. `plan` puis `apply -target=module.cert_manager.helm_release.cert_manager` ;
  2. **avant** le second temps, si la CA est restaurée : recréer le Secret
     `cert-manager/homelab-root-ca` depuis la copie hors ligne (étape 4) ;
  3. `plan` (relu, accord) puis `apply` complet : MetalLB, local-path, Vault,
     Traefik, cert-manager et la CA, ArgoCD et son Application racine.
- Vérifier : `kubectl get clusterissuer` (`homelab-ca` prêt), IP MetalLB
  attribuées, `kubectl -n argocd get application root`.

## 4. CA interne

| Cas | Action |
|---|---|
| Copie hors ligne disponible | 👤 Recréer le Secret avant le second temps de l'étape 3 : cert-manager reprend la CA existante, rien ne change pour les postes |
| Pas de copie (situation actuelle) | Une **nouvelle** CA est générée. 🤖 Mettre à jour `docs/homelab-root-ca.crt`, les empreintes des scripts clients (`hack/check-ca-fingerprint.sh` le vérifie) et le `caBundle` du `ClusterSecretStore`. 👤 Réinstaller le certificat sur chaque poste et relancer le playbook de confiance de l'étape 1 |

## 5. Vault — manuel

- 👤 **Vierge** : `vault operator init` puis unseal ([vault](../../features/security/vault/README.md),
  étapes 2-3). Ranger clés et root token hors ligne.
- 👤 **Avec données** : restaurer le dernier instantané (si P2 de l'ADR-014
  est en place), puis unseal avec les **anciennes** clés.
- 👤 Configuration (vierge seulement) : moteur `kv-v2` sur `secret/`, auth
  Kubernetes, rôle `external-secrets` ([external-secrets](../../features/security/external-secrets/README.md)) ;
  policy **appliquée depuis le fichier** `features/security/vault/policies/external-secrets.hcl`.
- Vérifier : `vault status` (`Sealed false`).

## 6. Secrets

- 👤 **Vierge** : créer chaque secret du [registre](../secrets.md),
  section 2, avec la procédure indiquée pour chacun ; réémettre chez les
  tiers ce qui l'exige (clé privée de la GitHub App, clés de déploiement).
  Si P1 de l'ADR-014 est en place, External Secrets génère seul les secrets
  « générés ».
- **Avec données** : les secrets viennent de l'instantané de Vault (étape 5).
- Vérifier : `kubectl get clustersecretstore vault` prêt.

## 7. Applications (ArgoCD)

- L'Application racine (étape 3) crée les autres. Synchronisation
  **automatique** pour les features, **manuelle** pour les applications
  business ([ADR-008](../adr/ADR-008-gitops-layout.md)) : 👤 « Sync » d'inner-riddle,
  puis de fact-check.
- Dépendances : Garage (`object-storage`) avant fact-check ; Keycloak avant
  inner-riddle ; registre avant toute application (images).
- **Avec données** : restaurer les bases (dump PostgreSQL de Keycloak,
  sauvegarde d'inner-riddle) **avant** le premier démarrage de
  l'application. Aujourd'hui ces sauvegardes sont sur le disque perdu.
- Vérifier : `./hack/status.py` sans `FAIL`.

## 8. Accès externes

- 👤 DNS (`auth.cybermimic.com`, `inner-riddle.cybermimic.com`) vers l'IP
  publique ; redirection Freebox (étape 0).
- Vérifier : certificats Let's Encrypt émis (`kubectl get certificates -A`),
  pages publiques joignables depuis l'extérieur.

## Ce qui manque pour qu'un « avec données » soit possible

| Manque | Où c'est traité |
|---|---|
| Sauvegarde hors disque de Vault | ADR-014, P2 |
| Copie de la CA | ADR-014, P3 |
| Instantané etcd | À décider (sauvegardes) |
| Dumps des bases hors disque | À décider (sauvegardes, via Garage) |
| Copie de l'état Terraform | À décider (sauvegardes) |
| Exercice réel de ce runbook | Arrivée d'une machine vierge |
