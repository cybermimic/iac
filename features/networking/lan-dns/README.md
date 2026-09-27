# networking/lan-dns

## Objectif

Serveur DNS de tout le LAN, distribué par la Freebox (DHCP IPv4 + DNS
IPv6) : tout nom `*.homelab.lan` répond l'IP de l'ingress Traefik, tout le
reste est transféré au DNS de la Freebox. Existe parce que la Freebox ne
sait pas servir d'enregistrements DNS locaux — voir
[ADR-007](../../../docs/adr/ADR-007-lan-dns.md).

C'est une instance CoreDNS **dédiée** (namespace `lan-dns`), sans rapport
avec le DNS interne du cluster (`kube-system/kube-dns`), qui n'est jamais
modifié.

⚠️ **Tout le LAN dépend de ce pod pour résoudre les noms, Internet
compris.** Si le NucBox est arrêté, plus aucun appareil ne résout de nom
tant que le pod n'est pas revenu ou que la Freebox n'est pas remise en
DNS (voir Rollback).

## Fonctionnement

- `hostNetwork` : le pod écoute directement sur l'IPv4 LAN et l'IPv6
  globale du NucBox (plugin CoreDNS `bind`), pas d'IP MetalLB. Raison : la
  Freebox exige une adresse IPv6 de DNS, et le cluster est IPv4 uniquement.
- Ressources Terraform explicites (ConfigMap + Deployment), pas de chart :
  le chart `coredns/coredns` ne sait pas faire de `hostNetwork`.
- Stratégie `Recreate` : deux pods ne peuvent pas écouter sur le même port
  du nœud, l'ancien s'arrête avant que le nouveau démarre (coupure DNS de
  quelques secondes à chaque changement).

## Dépendances

- `networking/ingress` — son `load_balancer_ip` est la cible du wildcard
  (passé en input depuis l'output du module, dans
  `infrastructure/environments/homelab/main.tf`).
- Hors Terraform : bail DHCP statique du NucBox (`192.168.1.253`) sur la
  Freebox, et préfixe IPv6 fixe de la ligne Free (l'IPv6 du NucBox en
  dérive).

## Ressources approximatives

Un pod CoreDNS : requests 20m CPU / 32Mi RAM, limits 200m / 128Mi.
Consommation réelle ~15-30Mi. Pas de stockage. Ports utilisés sur le
NucBox : 53 (UDP/TCP) sur les adresses de `listen_addresses`, 8053
(`/health`) et 8054 (`/ready`).

## Inputs

| Variable | Description | Défaut |
|---|---|---|
| `namespace` | Namespace d'installation | `lan-dns` |
| `coredns_version` | Tag de l'image `coredns/coredns` | `1.14.6` |
| `listen_addresses` | IPv4 LAN + IPv6 globale du NucBox | — (requis) |
| `domain` | Zone interne (`*.<domain>` → ingress) | — (requis, `homelab.lan` au niveau env) |
| `wildcard_target_ip` | IP de l'ingress | — (requis, output de `networking/ingress`) |
| `upstream_dns_servers` | DNS amont pour tout le reste | — (requis, ex. `["192.168.1.254"]`) |
| `health_port` / `ready_port` | Ports HTTP des sondes, sur l'hôte | `8053` / `8054` |
| `requests_*` / `limits_*` | Ressources du pod | voir `variables.tf` |
| `tolerate_control_plane_taint` | Toleration control-plane (single-node) | `true` |

## Outputs

`namespace`, `listen_addresses`, `domain`.

## Installation

Assemblée dans `infrastructure/environments/homelab` (voir son README).
Dans `terraform.tfvars` :

```hcl
lan_dns_listen_addresses = ["192.168.1.253", "2a01:e0a:818:4440:e251:d8ff:fe1c:4928"]
lan_dns_upstream_servers = ["192.168.1.254"]
```

L'IPv6 est celle du NucBox (`ip -6 addr show dev enp3s0 scope global`).

Vérification, **depuis un autre poste du LAN** :

```bash
dig @192.168.1.253 vault.homelab.lan +short     # 192.168.1.240
dig @192.168.1.253 example.com +short           # une IP publique
dig @<ipv6-du-nucbox> vault.homelab.lan +short  # 192.168.1.240
```

Sous Windows : `nslookup vault.homelab.lan 192.168.1.253`.

## Configuration de la Freebox (fait le 2026-09-27)

Freebox OS → Paramètres de la Freebox → Mode avancé :

| Écran | Réglage |
|---|---|
| Réseau local → DHCP → Serveur DNS 1 | `192.168.1.253` (DNS 2 et 3 **vides**) |
| Configuration IPv6 → DNS IPv6 | « Forcer l'utilisation de serveurs DNS IPv6 personnalisés » coché, primaire = IPv6 du NucBox, secondaire **vide** |

Pas de DNS secondaire vers la Freebox : les clients interrogent parfois
le secondaire au hasard, et `*.homelab.lan` échouerait de façon
aléatoire.

Les appareils prennent le nouveau DNS au renouvellement de leur bail
(Windows : `ipconfig /renew`).

## Le NucBox lui-même ne doit PAS utiliser ce DNS

Le NucBox reçoit aussi le DHCP de la Freebox : sans réglage, il
s'interrogerait lui-même. Au redémarrage, avant que le pod soit lancé, il
n'aurait plus de DNS (apt, téléchargement d'images…). Il est donc
configuré pour ignorer les DNS annoncés et utiliser directement la
Freebox (NetworkManager, connexion `netplan-enp3s0`, `sudo`) :

```bash
sudo nmcli con mod netplan-enp3s0 ipv4.ignore-auto-dns yes ipv4.dns 192.168.1.254 ipv6.ignore-auto-dns yes
sudo nmcli con up netplan-enp3s0
resolvectl status enp3s0     # DNS Servers: 192.168.1.254 uniquement
```

À porter dans le playbook Ansible de `bootstrap/` (configuration hôte,
ADR-001) — pas encore fait.

## Upgrade

Monter `coredns_version` après lecture des release notes CoreDNS,
`terraform plan` puis `apply` (coupure DNS de quelques secondes,
stratégie `Recreate`).

## Rollback

**En urgence (NucBox en panne, LAN sans DNS)** : sur la Freebox, remettre
`192.168.1.254` en Serveur DNS 1 du DHCP et décocher « Forcer » dans
Configuration IPv6 → DNS IPv6. Les appareils retrouvent Internet au
renouvellement du bail (ou immédiatement pour l'IPv6) ; seuls les noms
`*.homelab.lan` ne résolvent plus.

**Version** : `terraform apply` avec l'ancienne `coredns_version`.

**Retrait de la feature** : d'abord le rollback Freebox ci-dessus, puis
`terraform destroy -target=module.lan_dns`.

## Troubleshooting

- Plus aucun appareil ne résout de nom → le pod ne tourne pas :
  `kubectl -n lan-dns get pods` ; en attendant, rollback Freebox.
- Pod en `CrashLoopBackOff` avec `bind: address already in use` → un autre
  processus écoute déjà sur le port 53 d'une des `listen_addresses`
  (`sudo ss -lunp | grep ':53 '`).
- Pod en erreur `cannot assign requested address` → une adresse de
  `listen_addresses` n'existe plus sur le NucBox (IPv6 changée ?) : comparer
  avec `ip -6 addr show dev enp3s0 scope global`, corriger `terraform.tfvars`
  **et** le DNS IPv6 de la Freebox.
- `*.homelab.lan` ne résout pas sur un poste mais `dig @192.168.1.253`
  fonctionne → le poste utilise encore l'ancien DNS : renouveler le bail,
  vérifier `Get-DnsClientServerAddress` (Windows) / `resolvectl status`
  (Linux).
- Voir le Corefile servi :
  `kubectl -n lan-dns get configmap lan-dns-corefile -o yaml`.
- Logs : `kubectl -n lan-dns logs deploy/lan-dns`.
