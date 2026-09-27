# bootstrap

Transforme une machine Ubuntu vierge en machine prête à intégrer la
plateforme : containerd configuré, kubelet/kubeadm/kubectl installés et
épinglés. Voir [docs/adr/ADR-001-terraform-scope.md](../docs/adr/ADR-001-terraform-scope.md)
pour la frontière avec Terraform — rien ici ne touche aux ressources
Kubernetes elles-mêmes.

## Dépendances

Aucune — c'est la première couche, prérequis à tout le reste.

## Portée

- `roles/containerd` — modules noyau (`overlay`, `br_netfilter`), sysctl
  réseau requis par Calico, installation du paquet `containerd` (dépôt
  Ubuntu natif, pas de dépôt tiers), génération de la config par défaut si
  absente, activation de `SystemdCgroup = true` (sans quoi kubelet et
  containerd utilisent des cgroup drivers différents et le nœud ne devient
  jamais `Ready`).
- `roles/kubernetes_node` — swap désactivé, dépôt APT `pkgs.k8s.io` épinglé
  sur une série mineure (`kubernetes_node_series`, ex. `1.36`), installation de
  `kubelet`/`kubeadm`/`kubectl`, `apt-mark hold` pour geler la version après
  install.

## Ne fait PAS partie de ce layer

- `kubeadm init` / `kubeadm join` — étape manuelle et délibérée (décide du
  rôle control-plane vs worker), volontairement hors automatisation pour
  l'instant.
- Ressources Kubernetes (namespaces, CRDs, Helm releases) — voir
  `../infrastructure/`.

## Inputs

- `inventory/hosts.yml` (copier depuis `hosts.yml.example`, ignoré par git)
  — définit les machines cibles, `ansible_host`/`ansible_user` par hôte.
- `kubernetes_node_series` (rôle `kubernetes_node`, défaut `1.36`).

## Installation

```bash
cd bootstrap/ansible
ansible-galaxy collection install -r requirements.yml  # collections épinglées
cp inventory/hosts.yml.example inventory/hosts.yml   # puis adapter
ansible-playbook playbook.yml --check --diff -K      # dry-run, demande le mot de passe sudo
ansible-playbook playbook.yml -K                     # exécution réelle
```

`-K` (`--ask-become-pass`) est nécessaire : aucune machine du parc n'a de
sudo sans mot de passe configuré actuellement.

## Upgrade

Monter `kubernetes_node_series` (ex. `1.36` → `1.37`) est un changement de
version mineure Kubernetes à part entière, à traiter avec la procédure
d'upgrade officielle de kubeadm (drain, upgrade control-plane, upgrade
nœuds un par un) — ne pas se contenter de relancer ce playbook sur un
cluster déjà en production.

## Rollback

`apt-mark unhold` puis réinstaller la version précédente épinglée
explicitement, ou restaurer la machine depuis un snapshot si disponible.

## Troubleshooting

- `kubelet` en crashloop après ce playbook mais avant `kubeadm init`/`join`
  → normal, il attend `/etc/kubernetes/kubelet.conf`.
- Nœud jamais `Ready` après `kubeadm init` → vérifier `SystemdCgroup = true`
  dans `/etc/containerd/config.toml` et que `containerd` a bien redémarré.
