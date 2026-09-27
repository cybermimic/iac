# networking/lan-dns

## Objectif

Serveur DNS pour les postes du LAN : tout nom `*.homelab.lan` répond l'IP
de l'ingress Traefik, tout le reste est transféré au DNS du routeur. Existe
parce que la Freebox ne sait pas servir d'enregistrements DNS locaux —
voir [ADR-007](../../../docs/adr/ADR-007-lan-dns.md).

C'est une instance CoreDNS **dédiée** (namespace `lan-dns`), sans rapport
avec le DNS interne du cluster (`kube-system/kube-dns`), qui n'est jamais
modifié.

## Dépendances

- `networking/metallb` — IP LAN fixe du Service (UDP+TCP 53).
- `networking/ingress` — son `load_balancer_ip` est la cible du wildcard
  (passé en input depuis l'output du module, dans
  `infrastructure/environments/homelab/main.tf`).

## Ressources approximatives

Un pod CoreDNS : requests 20m CPU / 32Mi RAM, limits 200m / 128Mi.
Consommation réelle ~15-30Mi. Pas de stockage.

## Inputs

| Variable | Description | Défaut |
|---|---|---|
| `namespace` | Namespace d'installation | `lan-dns` |
| `chart_version` | Version du chart `coredns/coredns` | `1.47.1` (CoreDNS 1.14.6) |
| `load_balancer_ip` | IP LAN fixe du DNS, dans la plage MetalLB | — (requis) |
| `domain` | Zone interne (`*.<domain>` → ingress) | — (requis, `homelab.lan` au niveau env) |
| `wildcard_target_ip` | IP de l'ingress | — (requis, output de `networking/ingress`) |
| `upstream_dns_servers` | DNS amont pour tout le reste | — (requis, ex. `["192.168.1.254"]`) |
| `requests_*` / `limits_*` | Ressources du pod | voir `variables.tf` |
| `tolerate_control_plane_taint` | Toleration control-plane (single-node) | `true` |

## Outputs

`namespace`, `load_balancer_ip`, `domain`.

## Installation

Assemblée dans `infrastructure/environments/homelab` (voir son README).
Dans `terraform.tfvars` :

```hcl
lan_dns_load_balancer_ip = "192.168.1.241"
lan_dns_upstream_servers = ["192.168.1.254"]
```

Vérification (depuis n'importe quel poste du LAN) :

```bash
dig @192.168.1.241 vault.homelab.lan +short     # 192.168.1.240
dig @192.168.1.241 example.com +short           # une IP publique (transfert au routeur)
dig @192.168.1.241 vault.homelab.lan AAAA +short   # vide, sans délai
```

Sous Windows : `nslookup vault.homelab.lan 192.168.1.241`.

## Configuration des postes

**Règle par domaine sur chaque poste** : seuls les noms `*.homelab.lan`
sont envoyés à `192.168.1.241`, tout le reste continue d'utiliser le DNS
habituel. Le DHCP de la Freebox n'est **pas** modifié (pourquoi : ADR-007
— la Freebox annonce son DNS en IPv6, constaté sur un poste Windows, ce
qui court-circuiterait un DNS distribué par le DHCP IPv4).

**Windows** (PowerShell **administrateur**, une seule fois) :

```powershell
Add-DnsClientNrptRule -Namespace ".homelab.lan" -NameServers "192.168.1.241"
Resolve-DnsName vault.homelab.lan          # -> 192.168.1.240
```

Retrait :
`Get-DnsClientNrptRule | Where-Object Namespace -eq ".homelab.lan" | Remove-DnsClientNrptRule -Force`

**Linux avec systemd-resolved** (`sudo`) — fichier
`/etc/systemd/resolved.conf.d/homelab.conf` :

```ini
[Resolve]
DNS=192.168.1.241
Domains=~homelab.lan
```

puis `sudo systemctl restart systemd-resolved` et
`resolvectl query vault.homelab.lan`.

**Téléphones / appareils sans réglage DNS par domaine** : pas couverts
pour l'instant (ils résolvent Internet normalement, mais pas
`*.homelab.lan`).

## Upgrade

Monter `chart_version` après lecture des release notes du chart,
`terraform plan` puis `apply`. Pas de CRD.

## Rollback

`terraform apply` avec l'ancienne `chart_version`. En dernier recours
`terraform destroy -target=module.lan_dns` — **avant**, retirer
`192.168.1.241` de la configuration DNS des postes / du DHCP, sinon ils
perdent la résolution des noms.

## Troubleshooting

- `EXTERNAL-IP` `<pending>` → IP hors plage MetalLB ou déjà prise :
  `kubectl -n lan-dns describe svc lan-dns-coredns`.
- `*.homelab.lan` ne résout pas sur un poste mais `dig @192.168.1.241`
  fonctionne → le poste n'interroge pas ce DNS (voir « Configuration des
  postes »), vérifier `resolvectl status` (Linux) ou
  `Get-DnsClientServerAddress` (Windows).
- Voir le Corefile réellement servi :
  `kubectl -n lan-dns get configmap lan-dns-coredns -o yaml`.
- Logs : `kubectl -n lan-dns logs deploy/lan-dns-coredns`.
