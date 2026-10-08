# Postmortem — Analyse k6 absente du canary TaskFlow

> Sans reproche : on cherche ce qui a permis l'erreur, pas qui l'a faite.

| Champ | Valeur |
| --- | --- |
| Date et heure | Abort observé le 2026-10-07 à 13:27:24 UTC; diagnostic établi le 2026-10-08 |
| Version en cause | 2.1.0 (candidate); version stable observée : 2.0.0 |
| PR à l'origine | PR #7, commit `263c4cc` (« Start TaskFlow 2.1.0 canary rollout ») |
| Durée d'exposition | Inconnue; le cluster n'expose pas les heures de début et de fin du trafic candidat |
| Part du trafic touché | Inconnue. Le Rollout ne contient pas de trace de poids effectivement appliqué; quatre pods 2.0.0 sont disponibles au diagnostic |
| Détecté par | État `RolloutAborted` du Rollout (cause technique de l'abort inconnue) |
| Résolu par | Abort Argo Rollouts; le ReplicaSet stable 2.0.0 a repris les 4 réplicas. Git demande toujours 2.1.0 et Argo CD reste Degraded |

## Chronologie

| Heure | Événement |
| --- | --- |
| 2026-10-07 13:26:30 UTC | Le Rollout passe en état non sain (`Rollout is not healthy`). |
| 2026-10-07 13:26:39 UTC | Le Rollout est en pause. |
| 2026-10-07 13:27:24 UTC | Argo Rollouts marque la révision 3 (2.1.0) comme abortée. |
| 2026-10-07 13:27:26 UTC | Le Rollout indique sa disponibilité minimale; quatre réplicas stables sont disponibles. |
| 2026-10-08 | Vérification : CRD présents; aucun AnalysisTemplate, AnalysisRun ou ConfigMap k6 dans `taskflow`. |
| 2026-10-08 10:06:41–10:07:15 UTC | Le service `taskflow-canary` ne vise que le pod `2.0.0` `taskflow-c6cf57bd6-869qg`. |
| 2026-10-08 10:07:10 UTC | k6, lancé contre ce service, mesure le profil de `2.1.0` (p95 304,8 ms, 28,99 % d'erreurs). |
| 2026-10-08 10:07:17 UTC | Le Rollout passe Degraded et rend le service aux pods stables `2.1.0`. |

## Composant défaillant et cause racine

- Quel composant a échoué ? Le déploiement canary 2.1.0 a été aborté (`kubectl -n taskflow get rollout taskflow -o yaml` : `abort: true`, `message: RolloutAborted: Rollout aborted update to revision 3`). La cause opérationnelle qui a déclenché l'abort n'est plus disponible : événements et AnalysisRuns absents.
- Pourquoi les probes Kubernetes ne l'ont-elles pas vu ? Les probes `/health` vérifient la santé du conteneur, pas la latence ni le taux d'erreur de `/tasks`. L'analyse de charge aurait mesuré ces seuils, mais elle n'a pas été déclenchée.
- Cause racine : Argo CD suit `apps/taskflow/canary` (Application `taskflow`), alors que `AnalysisTemplate`, `ConfigMap` k6 et le Rollout d'analyse sont rangés sous `apps/taskflow/robustesse`. Le Rollout effectivement suivi (`apps/taskflow/canary/rollout.yaml`) ne référence aucun template d'analyse. Résultat : l'AnalysisRun n'a pas été créé. Les CRD `rollouts.argoproj.io` et `analysistemplates.argoproj.io` sont établies (`v1alpha1`); l'incident n'est pas dû à l'absence des CRD.

Les commandes de diagnostic et leurs sorties enregistrées sont dans [`captures/`](captures/). Aucun AnalysisRun 2.1.0 ou 2.2.0 n'existe dans le cluster actuel; les captures demandées ne peuvent donc pas être produites comme preuves d'exécution. Aucun historique Git ne contient de Rollout 2.2.0.

## le Rollout ne fonctionne pas

la révision 5 demande l'image `ghcr.io/9m7fjfpv9k-cyber/taskflow:2.0.0` (ReplicaSet `taskflow-c6cf57bd6`). Le contrôleur bascule le sélecteur de `taskflow-canary` sur ce hash. L'EndpointSlice ne contient alors que le pod candidat. Ce pod, digest `sha256:0bb790c9c164121428b31f7fe1a26da56f2c9e1e7c7651a2a50ce621d49f5faf`, répond `200` en 2 ms avec le corps `[]`.

Dans la même fenêtre, le Job k6 `26ab0c50-940f-476e-a687-26d7cc229974.test-de-charge-k6.1` appelle `http://taskflow-canary/tasks` et obtient autre chose :

| Seuil | Exigence | Mesure |
| --- | --- | --- |
| `http_req_duration` | p(95) < 250 ms | p(95) = 304,8 ms, minimum 300,57 ms |
| `http_req_failed` | taux < 2 % | 28,99 % (87 requêtes sur 300) |

Ce profil est celui de `2.1.0` : environ 300 ms et des HTTP 500 `{"detail":"Erreur interne"}`. Aucune requête du test n'a la latence du pod `2.0.0`. L'AnalysisRun `taskflow-c6cf57bd6-5-1` passe en `Failed`, puis le Rollout émet `RolloutAborted` sur la révision 5. À 10:07:17 UTC le service revient sur les pods `taskflow-df976ccb5` (`2.1.0`).

Le Rollout annonce donc un canary vers `2.0.0`, mais le trafic mesuré par l'analyse ne va pas au pod qu'il a sélectionné. Le déploiement est abandonné sur une mesure qui ne porte pas sur la candidate.

## Ce qui a bien fonctionné

- Le contrôleur Argo Rollouts a aborté la révision candidate et conservé quatre réplicas de la version stable 2.0.0.
- Les CRD sont présentes; la vérification des ressources a identifié le décalage de chemin GitOps.

## Actions correctives

| Action | Responsable | Échéance |
| --- | --- | --- |
| Corriger le chemin ou la source Argo CD pour déployer ensemble le Rollout robuste, le template d'analyse, le ConfigMap et le service canary | Équipe | Avant nouvelle tentative |
| Rejouer le scénario 2.1.0, conserver le YAML et les logs de l'AnalysisRun en échec | Équipe | Avant promotion |
| Déployer 2.2.0 après correction et conserver le YAML et les logs de l'AnalysisRun en succès | Équipe | Avant clôture |
| Revert Git vers 2.0.0 si la candidate doit rester abandonnée, puis vérifier Healthy dans Argo CD | Équipe | À faire |
