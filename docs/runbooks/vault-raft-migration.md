# Runbook — migrer le stockage de Vault de `file` vers `raft`

> **Jamais exécuté.** Préparé le 2026-10-28 pour l'[ADR-014](../adr/ADR-014-secrets-for-rebuild.md),
> P2 : le stockage `raft` permet des instantanés cohérents à chaud
> (sauvegardes, [ADR-016](../adr/ADR-016-backups.md)). Toutes les étapes
> sont faites par l'opérateur ; l'agent peut relire le `plan` et vérifier en
> lecture.

**Durée** : ~20 min, Vault indisponible pendant ce temps. Les Secrets
Kubernetes déjà créés par External Secrets restent en place : les
applications continuent de tourner, seules les mises à jour de secrets
échouent le temps de la migration.

**Ce qui a été vérifié avant d'écrire ce runbook** :

- avec `vault_storage_backend = "file"` (défaut), la configuration rendue par
  Terraform est **identique octet pour octet** à l'actuelle : fusionner le
  code ne change rien ;
- la configuration `raft` produite démarre sur `hashicorp/vault:2.0.4`
  (conteneur jetable, non initialisé). Elle exige `disable_mlock` : sans lui,
  Vault 2.0.4 **refuse de démarrer** (découvert pendant ce test, corrigé).

**Ce qui n'a pas été vérifié** : la migration elle-même (`vault operator
migrate`) sur de vraies données. **Recommandé** : la répéter d'abord sur un
Vault factice (conteneur, données jetables), dans ton propre terminal.

## 0. Avant de commencer

- `./hack/status.py` sans `FAIL`, Vault descellé.
- Clés d'unseal à portée de main : ce sont **les mêmes** après la migration.
- Disque de sauvegarde monté et clé publique `age` installée
  ([storage/backups](../../features/storage/backups/README.md)).

## 1. Sauvegarder le volume de Vault (👤, sudo)

Les données de Vault sont chiffrées par Vault lui-même ; la copie est en plus
chiffrée avec `age` :

```bash
PV=$(kubectl -n vault get pvc data-vault-0 -o jsonpath='{.spec.volumeName}')
sudo tar -C /opt/local-path-provisioner -czf - "${PV}_vault_data-vault-0" \
  | age -R /etc/homelab-backup/recipients.txt -o <disque>/vault/avant-raft-$(date +%F).tar.gz.age
```

## 2. Arrêter Vault (👤)

Opération exceptionnelle documentée (`kubectl scale`), défaite à l'étape 4
par Terraform :

```bash
kubectl -n vault scale statefulset vault --replicas=0
kubectl -n vault wait --for=delete pod/vault-0 --timeout=120s
```

> ⚠️ À partir d'ici et jusqu'à l'étape 5, si un Vault démarre et se dit
> **non initialisé**, c'est la migration en cours : **ne jamais lancer
> `vault operator init`**.

## 3. Migrer (👤)

Un pod temporaire monte le volume de Vault : il range les données `file`
dans `file/` (pour qu'elles ne se mélangent jamais au dossier `raft`, et
pour garder un retour arrière), puis copie tout vers `raft/`. La migration
travaille sur les données **chiffrées** : elle n'a besoin d'aucune clé.

```bash
kubectl -n vault apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: vault-migrate
spec:
  restartPolicy: Never
  securityContext: {runAsUser: 100, runAsGroup: 1000, fsGroup: 1000, runAsNonRoot: true}
  tolerations:
    - {key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule}
  containers:
    - name: migrate
      image: hashicorp/vault:2.0.4
      securityContext: {allowPrivilegeEscalation: false}
      command: ["sh", "-ec"]
      args:
        - |
          cd /vault/data
          test ! -e file && test ! -e raft     # jamais deux fois
          mkdir file raft
          mv auth core logical sys file/
          cat > /tmp/migrate.hcl <<'HCL'
          storage_source "file" {
            path = "/vault/data/file"
          }
          storage_destination "raft" {
            path    = "/vault/data/raft"
            node_id = "vault-0"
          }
          cluster_addr = "https://127.0.0.1:8201"
          HCL
          vault operator migrate -config /tmp/migrate.hcl
      volumeMounts:
        - {name: data, mountPath: /vault/data}
  volumes:
    - name: data
      persistentVolumeClaim: {claimName: data-vault-0}
EOF
kubectl -n vault wait --for=jsonpath='{.status.phase}'=Succeeded pod/vault-migrate --timeout=300s
kubectl -n vault logs vault-migrate        # attendu : « Success! All of the keys have been migrated. »
kubectl -n vault delete pod vault-migrate
```

Si le pod échoue : **ne pas continuer**, aller au retour arrière.

## 4. Basculer la configuration (🤖 plan, 👤 accord et apply)

Dans le répertoire d'état Terraform : `vault_storage_backend = "raft"` dans
`terraform.tfvars`, puis :

```bash
terraform plan      # attendu : seule la configuration de Vault (helm_release.vault) change
terraform apply
```

L'`apply` remet le StatefulSet à 1 réplique : `vault-0` démarre avec le
stockage `raft`, **scellé**.

## 5. Desceller et vérifier (👤)

```bash
kubectl -n vault exec -it vault-0 -- vault operator unseal    # x3, les MÊMES clés qu'avant
kubectl -n vault exec vault-0 -- vault status                  # Storage Type raft, Initialized true, Sealed false
kubectl get externalsecret -A                                  # tous Ready (refresh forcé si besoin)
./hack/status.py
```

## Retour arrière (si l'étape 3, 4 ou 5 échoue)

1. `kubectl -n vault scale statefulset vault --replicas=0`.
2. Pod temporaire (même modèle qu'à l'étape 3) qui remet les données en place :
   `cd /vault/data && rm -rf raft && mv file/* . && rmdir file`.
3. `vault_storage_backend = "file"` dans `terraform.tfvars`, `plan`, `apply`.
4. Unseal ; vérifier comme à l'étape 5 (`Storage Type file`).
5. En dernier recours : restaurer l'archive de l'étape 1.

## Après la migration

- Garder `file/` une à deux semaines, puis le supprimer (pod temporaire,
  `rm -rf /vault/data/file`).
- Mettre en place l'instantané quotidien (`vault operator raft snapshot
  save`, rôle Kubernetes auth dédié) : étape suivante de l'ADR-014, P2.
- Mettre à jour `CLAUDE.md` (pile technique) et le README de
  [security/vault](../../features/security/vault/README.md).
