# ADR-017 — Rapports de CI dans le registre Zot

**Statut : Acceptée** (2026-11-26) — option A, avec les résultats
lisibles dans GitHub (annotations + résumé du run) ; Q1, Q2 et Q3 selon
les recommandations (voir « Décision »).

## Contexte

GitHub alerte sur le dépassement du stockage Actions du compte (500 Mo,
partagés par tous les dépôts privés). Mesures du 2026-11-26 :

| Dépôt | Artefacts | Taille |
|---|---|---|
| inner-riddle | 460 | 727 Mo |
| iac, trade-monitor, fact-check, fleet-manager | 0 | 0 |

Dans inner-riddle, `playwright-report` pèse 719 Mo (122 artefacts), dont
**un seul de 596 Mo** (2026-10-29, branche `feat/ir-061-visite-guidee`) :
Playwright garde trace, vidéo et captures de chaque test en échec
(`retain-on-failure`), et le job `e2e` envoie tout `e2e/artifacts/`. Les
rapports backend et frontend pèsent 8 Mo à eux deux. Conservation : 90
jours (maximum), aucun `retention-days` dans `ci.yml`.

Tous les jobs d'inner-riddle tournent déjà sur les runners du cluster
([ADR-011](ADR-011-ci-runners.md)), qui joignent le registre interne
([ADR-010](ADR-010-container-registry.md)).

## Options

| Option | RAM en plus | Pour | Contre |
|---|---|---|---|
| **A. Zot + ORAS (retenue)** | 0 | Rien à déployer ; Zot stocke tout artefact OCI ; rétention et ramasse-miettes déjà en place ; les runners joignent déjà `192.168.1.242` | Pas de consultation dans le navigateur (`oras pull` puis `playwright show-report` en local) : Zot n'est pas joignable par GitHub (LAN seul, [ADR-009](ADR-009-public-exposure.md)) et ne sert pas de pages web ; partage les 20 Gi du volume Zot |
| B. Stockage S3 (Garage, iac #25) | ~100-300 Mi | Rapport HTML servi directement, lien dans le résumé du run | Dépend d'une feature pas encore livrée ; publication HTTP à prévoir |
| C. nginx + volume | ~20 Mi | Rapports consultables dans le navigateur | Envoi et nettoyage à écrire soi-même |
| (Statu quo) GitHub + `retention-days: 7` | 0 | Lien direct dans l'interface GitHub | Reste soumis au quota : un run très en échec peut encore le dépasser |

## Décision proposée

Option A :

- le job `e2e` d'inner-riddle pousse `e2e/artifacts/` dans
  **`192.168.1.242/inner-riddle/ci-reports:e2e-<run_id>-<run_attempt>`**
  avec la CLI ORAS (v1.4.0, épinglée ; action `oras-project/setup-oras`
  v2.0.4 épinglée), à la place d'`actions/upload-artifact` ;
- **ce qui a cassé se lit dans GitHub**, sans artefact (annotations et
  résumé de run ne comptent pas dans le quota) : le reporter `github` de
  Playwright transforme chaque test en échec en annotation (message,
  fichier, ligne) sur le run et la PR, et l'étape écrit dans le résumé
  du run (`$GITHUB_STEP_SUMMARY`) le décompte des tests (réussis, en
  échec, ignorés) ;
- les traces, vidéos et rapport HTML, utiles seulement pour creuser,
  restent dans Zot ; le résumé du run donne la commande pour les
  récupérer :

  ```bash
  oras pull --ca-file docs/homelab-root-ca.crt \
    192.168.1.242/inner-riddle/ci-reports:e2e-<run_id>-<run_attempt> -o rapport/
  npx playwright show-report rapport/playwright-report
  ```

- **CA interne dans le conteneur runner** : aujourd'hui seul `dockerd`
  (conteneur `dind`) fait confiance à la CA, pour `docker push`. ORAS
  tourne dans le conteneur `runner` : on y monte la `ConfigMap`
  `homelab-ca` existante en `/etc/homelab-ca/ca.crt`, passé à ORAS par
  `--ca-file`. Changement dans `gitops/apps/arc-runners-inner-riddle.yaml`
  (iac) ;
- **rétention dédiée** dans la configuration Zot, placée **avant** la
  règle générale `**` : `*/ci-reports` garde les étiquettes poussées
  depuis moins de 14 jours (`pushedWithin: 336h`), les autres dépôts
  gardent leurs 10 dernières versions. Configuration vérifiée par
  `zot verify` avant livraison ;
- identifiants : les secrets de dépôt existants `REGISTRY_USER` /
  `REGISTRY_PASSWORD` (compte `ci-push`), voir Q2.

Ces rapports ne sont **pas sauvegardés** ([ADR-016](ADR-016-backups.md)) :
ils sont jetables par nature.

## Questions

- **Q1 — Quels rapports passent dans Zot ?** Recommandation : **seul
  Playwright** (99 % du volume) ; les rapports backend et frontend
  (quelques Ko) restent sur GitHub avec `retention-days: 7`, consultables
  en un clic. Alternative : tout dans Zot, pour une seule méthode.
- **Q2 — Quel compte pour pousser ?** Recommandation : **`ci-push`**,
  déjà dans les secrets du dépôt. Il passe ainsi des tags (workflow
  `Release`) à chaque push de branche, alors qu'il a les droits
  d'écriture et de suppression sur tous les dépôts du registre ;
  acceptable tant que le dépôt est privé et qu'un seul humain y pousse.
  Alternative : un compte `ci-reports` limité à `*/ci-reports` (nouvelle
  entrée htpasswd, chemin Vault, secret GitHub : opérations de
  l'opérateur).
- **Q3 — Vidéos Playwright ?** Recommandation : passer `video` à
  `"off"` dans `e2e/playwright.config.ts` (inner-riddle) ; la trace
  contient déjà captures, DOM et réseau de chaque étape. Cela borne la
  taille d'un run en échec ; à défaut, un run comme celui du 2026-10-29
  occupe 600 Mo du volume Zot pendant 14 jours.

## Décision

Acceptée par l'opérateur le 2026-11-26 : option A telle que proposée,
résultats lisibles dans GitHub ; **Q1** seul le rapport Playwright va
dans Zot (backend et frontend restent sur GitHub, `retention-days: 7`) ;
**Q2** compte `ci-push` existant ; **Q3** `video: "off"`.

## Conséquences

- Plus d'alerte de quota liée à Playwright ; le stockage GitHub ne garde
  que des rapports de quelques Ko.
- Consulter un rapport e2e demande ORAS et la CA interne sur le poste
  (scripts `security/cert-manager/clients`), et d'être sur le LAN.
- Le volume Zot (20 Gi) porte images et rapports : à surveiller au début
  (`du` du dépôt `inner-riddle/ci-reports`) et à agrandir si besoin.
- Les autres dépôts (fact-check, trade-monitor…) pourront suivre le même
  schéma, en montant la CA dans leur scale set.
- Hors de cette ADR : supprimer l'artefact GitHub de 596 Mo existant
  (opération ponctuelle, sur accord de l'opérateur).
