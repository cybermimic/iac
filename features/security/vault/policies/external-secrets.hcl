# Policy Vault « external-secrets » : lecture des secrets par External Secrets
# Operator, un chemin par feature ou application consommatrice. Un seul rôle
# Kubernetes auth (external-secrets) sert tout le cluster.
#
# CE FICHIER EST LA RÉFÉRENCE. Ne jamais réécrire la policy à la main :
# modifier ce fichier (PR), comparer avec la policy réelle, puis l'appliquer
# depuis lui (features/security/external-secrets/README.md). Un oubli de
# chemin lors d'une réécriture à la main a cassé 4 ExternalSecret pendant 18 h
# le 2026-10-19.
#
# Une policy n'est pas un secret : elle peut vivre dans ce repo public.

path "secret/data/inner-riddle/*"    { capabilities = ["read"] }
path "secret/data/registry/*"        { capabilities = ["read"] }
path "secret/data/actions-runners/*" { capabilities = ["read"] }
path "secret/data/argocd/*"          { capabilities = ["read"] }
path "secret/data/keycloak/*"        { capabilities = ["read"] }
path "secret/data/object-storage/*"  { capabilities = ["read"] }
path "secret/data/fact-check/*"      { capabilities = ["read"] }
