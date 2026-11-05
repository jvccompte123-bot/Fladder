# Commandes films/séries et verrouillage iPhone

Les groupes de commandes disposent de deux rangées lorsque la largeur disponible ne permet pas de conserver leurs zones tactiles séparées. Les commandes de lecture restent au centre ; PiP, audio, sous-titres et options restent accessibles. L'icône PiP conserve son action existante, sans libellé dessous.

Le cadenas ouvert en haut du lecteur verrouille l'orientation affichée et les interactions avec le lecteur. Le sens exact du paysage est lu dans la scène UIKit, puis fixé avec `SystemChrome.setPreferredOrientations`. Aucun capteur de mouvement ni nouvelle dépendance n'est nécessaire. Le bouton est proposé sur iOS.

Pendant le verrouillage, les commandes sont masquées et les gestes du lecteur, le pincement et les boutons de l'épisode suivant sont bloqués. La vidéo et les sous-titres continuent. Le cadenas fermé reste visible à droite ; un appui long déverrouille. Un simple contact affiche le rappel sans déverrouiller. Ce verrou concerne le lecteur, pas les gestes système de l'iPhone.

Le déverrouillage restaure les orientations autorisées dans les réglages du lecteur. Sortir du lecteur rétablit les orientations de l'application, y compris si une demande de verrouillage était encore en cours.

## Vérifications

- Tests de disposition sur des surfaces de 320, 402, 760, 874 et 1440 points : aucune intersection entre les zones tactiles et chaque bouton reste activable.
- Tests de verrouillage : orientation exacte, taps/double taps/glissements/pincements bloqués, appui long, restauration des préférences, échec natif et sortie pendant une demande.
- Tests PiP existants conservés dans le workflow iOS.

À confirmer sur iPhone après installation : démarrer un film ou épisode en paysage dans chaque sens, verrouiller puis tourner le téléphone (y compris à plat), toucher/glisser sur la vidéo, déverrouiller par appui long et vérifier le retour de la rotation autorisée. Vérifier aussi le portrait, la sortie/réouverture du lecteur et le PiP après déverrouillage. Les tests Flutter simulent UIKit ; ils ne remplacent pas cette vérification physique.
