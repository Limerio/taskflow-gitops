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

## Composant défaillant et cause racine

- Quel composant a échoué ? Le déploiement canary 2.1.0 a été aborté (`kubectl -n taskflow get rollout taskflow -o yaml` : `abort: true`, `message: RolloutAborted: Rollout aborted update to revision 3`). La cause opérationnelle qui a déclenché l'abort n'est plus disponible : événements et AnalysisRuns absents.
- Pourquoi les probes Kubernetes ne l'ont-elles pas vu ? Les probes `/health` vérifient la santé du conteneur, pas la latence ni le taux d'erreur de `/tasks`. L'analyse de charge aurait mesuré ces seuils, mais elle n'a pas été déclenchée.
- Cause racine : Argo CD suit `apps/taskflow/canary` (Application `taskflow`), alors que `AnalysisTemplate`, `ConfigMap` k6 et le Rollout d'analyse sont rangés sous `apps/taskflow/robustesse`. Le Rollout effectivement suivi (`apps/taskflow/canary/rollout.yaml`) ne référence aucun template d'analyse. Résultat : l'AnalysisRun n'a pas été créé. Les CRD `rollouts.argoproj.io` et `analysistemplates.argoproj.io` sont établies (`v1alpha1`); l'incident n'est pas dû à l'absence des CRD.

Les commandes de diagnostic et leurs sorties enregistrées sont dans [`captures/`](captures/). Aucun AnalysisRun 2.1.0 ou 2.2.0 n'existe dans le cluster actuel; les captures demandées ne peuvent donc pas être produites comme preuves d'exécution. Aucun historique Git ne contient de Rollout 2.2.0.

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
