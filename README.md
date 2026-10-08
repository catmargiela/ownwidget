# ownwidget

Widgets de bureau pour [Omarchy](https://omarchy.org) (Hyprland + shell Quickshell), pensés pour travailler avec Claude Code et Codex.

- **Agents** : une carte sur le bureau qui suit vos sessions Claude Code / Codex.
- **Projets** : une barre en bas de l'écran pour ouvrir, créer et ranger vos projets de `~/Documents`.

Tout est écrit en QML (plugins du shell Omarchy) avec un petit script Python par widget, sans dépendance externe.

## Agents (`rebenga.agents-desk`)

Carte posée sur le bureau, sous les fenêtres.

- **Sessions actives** : une carte par session Claude Code ou Codex (projet, durée, dernière action). Un clic saute sur le terminal de la session, même sur un autre espace de travail.
- **Alerte** : le cadre clignote quand un agent attend une permission ou votre réponse ; notification avec un bouton « Y aller ».
- **Nouvelle session** : notification « Y aller » à chaque nouvelle session.
- **Activité** : les dernières actions des agents (« édite X », « lance : … »).
- **Limites et statistiques** : jauges de la session 5 h et de la semaine, projection au rythme actuel, tokens du jour, histogramme sur 7 jours (données du plugin `omarchy.agents`).
- **Raccourci** : `collect.py --jump` passe d'un terminal d'agent au suivant (ceux qui vous attendent d'abord).

Le collecteur tourne en continu, lit les transcriptions de Claude Code de façon incrémentale et n'écrit rien sur le disque.
