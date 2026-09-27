# Runbook — Migration du réseau des pods Calico hors du LAN

Exécuté le 2026-09-27 sur `NucBoxG3-Plus`. Gardé comme référence pour un
futur nœud / une reconstruction du cluster.

## Problème

Le cluster a été initialisé avec le réseau de pods par défaut de Calico,
`192.168.0.0/16`, qui **contient le LAN** `192.168.1.0/24`. Calico ne
traduit pas (pas de NAT sortant) le trafic d'un pod vers une destination
située dans un de ses pools IP : un pod qui parle à une machine du LAN
envoie des paquets avec sa propre IP (`192.168.110.x`), à laquelle la
machine du LAN ne sait pas répondre.

Symptômes constatés :

- aucun pod ne joint la Freebox (`192.168.1.254`), ni aucune machine du
  LAN autre que le nœud lui-même ;
- le DNS du cluster (`kube-dns`) transfère à la Freebox → **aucun pod ne
  résout un nom Internet** (`SERVFAIL`) ;
- `networking/lan-dns` ne peut pas transférer les noms hors
  `homelab.lan`.

Internet (hors DNS) fonctionnait, car traduit normalement.

## Cible

Nouveau pool Calico `10.244.0.0/16` (ne chevauche ni le LAN, ni les
Services `10.96.0.0/12`), NAT sortant activé. Ancien pool supprimé.

## Ce qui n'est volontairement PAS modifié

- `--cluster-cidr` du kube-controller-manager, `podSubnet` de
  `kubeadm-config`, `clusterCIDR` de kube-proxy (tous `192.168.0.0/16`) :
  le CNI utilise `calico-ipam`, qui ignore le `podCIDR` du nœud
  (`192.168.0.0/24`, immuable). Changer `--cluster-cidr` sans ré-intégrer
  le nœud fait échouer le démarrage du contrôleur d'IPAM (le podCIDR du
  nœud serait hors de la plage) et met le controller-manager en boucle de
  redémarrage. Ces valeurs restent donc cohérentes entre elles, et
  simplement inutilisées. Incohérence connue, à solder uniquement à la
  prochaine reconstruction du cluster (voir `bootstrap/README.md`).

## Prérequis

`calicoctl` de la **même version que Calico** (ici v3.28.0), sans
l'installer sur le système :

```bash
curl -sSLo calicoctl https://github.com/projectcalico/calico/releases/download/v3.28.0/calicoctl-linux-amd64
curl -sSL https://github.com/projectcalico/calico/releases/download/v3.28.0/SHA256SUMS | grep 'calicoctl-linux-amd64$'   # comparer avec :
sha256sum calicoctl
chmod +x calicoctl
export DATASTORE_TYPE=kubernetes KUBECONFIG=<chemin-du-kubeconfig>
```

Impact : chaque pod non `hostNetwork` redémarre (coupure de 1-2 min des
services concernés). **Vault redémarre donc se re-scelle : prévoir
l'opérateur humain pour l'unseal.**

## Étapes

1. **Créer le nouveau pool** :

   ```bash
   cat <<'EOF' | ./calicoctl apply -f -
   apiVersion: projectcalico.org/v3
   kind: IPPool
   metadata:
     name: pods-10-244
   spec:
     cidr: 10.244.0.0/16
     ipipMode: Always
     vxlanMode: Never
     natOutgoing: true
     nodeSelector: all()
     blockSize: 26
   EOF
   ```

2. **Désactiver l'ancien pool** (plus aucune nouvelle IP n'y est prise) :

   ```bash
   ./calicoctl patch ippool default-ipv4-ippool -p '{"spec": {"disabled": true}}'
   ```

3. **Redémarrer les pods** qui ont une IP de pod, pour qu'ils en prennent
   une dans le nouveau pool :

   ```bash
   kubectl get pods -A -o wide | grep ' 192\.168\.1[0-9][0-9]\.'   # lister
   # calico-node (hostNetwork) : réattribue l'IP du tunnel IPIP du nœud
   kubectl -n kube-system rollout restart ds/calico-node
   kubectl -n kube-system rollout restart deploy/coredns deploy/calico-kube-controllers
   kubectl -n metallb-system rollout restart deploy/metallb-controller
   kubectl -n local-path-storage rollout restart deploy/local-path-provisioner
   kubectl -n traefik rollout restart deploy/traefik
   kubectl -n lan-dns rollout restart deploy/lan-dns-coredns
   kubectl -n vault delete pod vault-0        # puis unseal (humain)
   ```

4. **Vérifier** que plus aucun pod n'a d'IP dans `192.168.0.0/16`
   (`./calicoctl ipam show` → 0 IP utilisée dans l'ancien pool), puis
   **supprimer l'ancien pool** — tant qu'il existe, même désactivé, Calico
   continue de ne pas traduire le trafic vers le LAN :

   ```bash
   ./calicoctl delete ippool default-ipv4-ippool
   ```

5. **Tester** depuis un pod jetable : résolution `example.com` via le DNS
   du cluster, connexion à `192.168.1.254:80`, puis
   `dig @<dns-du-homelab> example.com` (voir `features/networking/lan-dns`).

## Rollback

Tant que l'étape 4 n'est pas faite : réactiver l'ancien pool
(`"disabled": false`), désactiver `pods-10-244`, redémarrer les pods.
Après l'étape 4 : recréer `default-ipv4-ippool` (`192.168.0.0/16`) à
l'identique, même procédure.
