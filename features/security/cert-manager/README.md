# security/cert-manager

## Objectif

Émettre et renouveler automatiquement les certificats TLS des services du
homelab, signés par une **CA interne** propre au homelab (voir
[ADR-006](../../../docs/adr/ADR-006-ingress-and-internal-tls.md)). Une
fois le certificat de la CA importé sur un poste, tout
`https://<service>.homelab.lan` y est reconnu sans avertissement.

## Ce que la feature installe

```
ClusterIssuer "selfsigned-bootstrap"   ne sert qu'à signer la racine
  └─ Certificate "homelab-root-ca"     CA racine (ECDSA P-256, 10 ans)
       │                               secret cert-manager/homelab-root-ca
       └─ ClusterIssuer "homelab-ca"   signe les certificats des services
```

- **Name constraint** : la CA ne peut signer que pour `homelab.lan` et ses
  sous-domaines. Comme elle est installée en racine de confiance sur les
  postes, c'est ce qui empêche une fuite de sa clé de servir à usurper
  n'importe quel site (les navigateurs et OS récents appliquent la
  contrainte).
- **Pas de rotation implicite de la clé de la CA** (`rotationPolicy:
  Never`) : une nouvelle clé = une nouvelle CA à réimporter partout.
- **Secrets** : `tls.key` du secret `homelab-root-ca` ne sort jamais du
  cluster. `ca.crt` est public (c'est lui qu'on distribue).

## Dépendances

Aucune feature requise pour fonctionner. Consommateurs :
`networking/ingress` (Traefik sert les certificats), puis chaque service
publié en HTTPS.

## Ressources approximatives

Trois pods (controller, webhook, cainjector) : requests 10m CPU chacun,
64 + 32 + 64 Mi RAM ; consommation mesurée à l'installation ~50 Mi au
total (controller 19, cainjector 17, webhook 10), ~30 mCPU. Un Job
`startupapicheck` éphémère à chaque install/upgrade. Pas de stockage.

## Inputs

| Variable | Description | Défaut |
|---|---|---|
| `namespace` | Namespace (cert-manager + secret de la CA) | `cert-manager` |
| `chart_version` | Version du chart `jetstack/cert-manager` | `v1.21.2` |
| `domain` | Seul domaine signable par la CA | — (requis, `homelab.lan` au niveau env) |
| `ca_common_name` | Nom affiché de la CA | `Homelab Root CA` |
| `ca_duration` | Validité de la CA | `87600h` (10 ans) |
| `tolerate_control_plane_taint` | Tolerations control-plane (single-node) | `true` |

## Outputs

`namespace`, `cluster_issuer_name` (`homelab-ca`), `ca_secret_name`.

## Installation

Les ressources de la CA (`kubernetes_manifest`) exigent que les CRDs
cert-manager existent **au moment du `plan`**. Sur un cluster qui n'a pas
encore cert-manager, deux temps :

```bash
# 1. cert-manager seul (installe les CRDs)
terraform plan  -target=module.cert_manager.helm_release.cert_manager
terraform apply -target=module.cert_manager.helm_release.cert_manager
# 2. le reste (la CA)
terraform plan
terraform apply
```

Vérification :

```bash
kubectl -n cert-manager get pods                       # 3 pods Running
kubectl get clusterissuer                              # selfsigned-bootstrap, homelab-ca : READY True
kubectl -n cert-manager get certificate homelab-root-ca   # READY True
```

## Obtenir un certificat pour un service

Sur un `Ingress` servi par Traefik :

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: homelab-ca
spec:
  tls:
    - hosts: [vault.homelab.lan]
      secretName: vault-tls
```

cert-manager crée le secret `vault-tls` et le renouvelle seul (par défaut
90 jours de validité, renouvelé aux 2/3).

## Installer la CA sur les postes

Le certificat **public** de la CA est versionné :
[`docs/homelab-root-ca.crt`](../../../docs/homelab-root-ca.crt).

| | |
|---|---|
| Sujet | `CN=Homelab Root CA` |
| Validité | 2026-09-27 → 2036-09-24 |
| Empreinte SHA-256 | `89:C0:C5:2E:A0:00:AB:60:C4:DF:40:4F:49:59:38:FE:8D:3F:04:BB:92:E4:66:D2:27:06:10:3D:0B:7A:F6:7C` |
| Contrainte | `Permitted: DNS:homelab.lan` |

**Toujours vérifier l'empreinte avant d'installer** (un certificat racine
installé par erreur donne à son détenteur le pouvoir d'intercepter le
trafic HTTPS du poste). S'il faut le régénérer depuis le cluster (jamais
`tls.key`) :

```bash
kubectl -n cert-manager get secret homelab-root-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > docs/homelab-root-ca.crt
openssl x509 -in docs/homelab-root-ca.crt -noout -fingerprint -sha256
```

Puis sur chaque poste, une fois :

- **Windows** (PowerShell **administrateur**) :

  ```powershell
  certutil -dump homelab-root-ca.crt | findstr /i "sha256"      # comparer l'empreinte
  Import-Certificate -FilePath .\homelab-root-ca.crt -CertStoreLocation Cert:\LocalMachine\Root
  ```

  (ou double-clic → Installer le certificat → Ordinateur local →
  **Autorités de certification racines de confiance**). Chrome et Edge
  utilisent ce magasin ; Firefox aussi par défaut sur Windows. Retrait :
  `certmgr.msc` → Autorités de certification racines de confiance →
  supprimer « Homelab Root CA ».
- **Linux (Ubuntu)** : `sudo cp homelab-root-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates`.
- **Android / iOS** : voir les réglages « Installer un certificat CA » /
  « Réglages > Général > VPN et gestion de l'appareil », puis sur iOS
  activer la confiance totale dans « Informations > Réglages des
  certificats ».

## Upgrade

Lire les release notes cert-manager (les versions mineures peuvent
retirer des champs), monter `chart_version`, `terraform plan` puis
`apply`. Les CRDs suivent (gérées par le chart).

## Rollback

`terraform apply` avec l'ancienne `chart_version`. Les CRDs et les
certificats existants sont conservés. **Ne jamais supprimer le secret
`homelab-root-ca`** : une nouvelle CA serait générée et devrait être
réimportée sur tous les postes.

## Troubleshooting

- `terraform plan` échoue avec « no matches for kind ClusterIssuer » →
  CRDs absentes : faire l'étape 1 de l'installation (`-target`).
- Certificat `READY False` : `kubectl describe certificate <nom> -n <ns>`
  puis `kubectl get certificaterequest -n <ns>` ; logs :
  `kubectl -n cert-manager logs deploy/cert-manager`.
- Navigateur « certificat non reconnu » alors que le certificat est
  `READY` → la CA n'est pas installée sur ce poste, ou pas dans le magasin
  « Autorités de certification racines de confiance ».
- Refus « name constraint violation » → le nom demandé n'est pas sous
  `homelab.lan`.
