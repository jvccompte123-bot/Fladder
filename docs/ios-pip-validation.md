# PiP iPhone — parcours HLS-2, validation sur appareil requise

Appareil signalé : iPhone 17 Pro, iOS 27.0.1.
Branche : `fix/ios-pip-persistent-session`. Ne pas fusionner dans `develop` avant validation sur iPhone.

## Problèmes identifiés

La capture d'écran montre le guide TV intégré : `VideoPlayerGuideWrapper` réduisait la vidéo à la moitié de la largeur ET de la hauteur de l'écran. Cette surface gardait donc le ratio portrait du téléphone, avec de grandes marges noires. Le bouton ouvrant ce guide n'appelait aucun code PiP. `TvPlayerControls` ne proposait aucun bouton PiP natif. Quitter ce lecteur appelait normalement l'arrêt de la chaîne.

Pour les films, le pont natif reprenait l'URL MPV sans vérifier sa compatibilité AVPlayer. Le profil MPV accepte des conteneurs/codecs qu'Apple ne sait pas forcément lire. Le diagnostic de tous les échecs était réduit à un booléen. La cause exacte de l'échec du film testé ne peut pas être prouvée sans les événements natifs de cet appareil.

## Nouvelle implémentation

- Un bouton **PiP** explicite appelle le même parcours dans les films, la TV et le guide TV sur iOS. Le bouton du guide reste distinct et porte l'infobulle « Guide TV ».
- La réduction du guide iOS utilise les dimensions vidéo disponibles, avec 16:9 comme repli. Elle ne se présente pas comme du PiP.
- Pour les vidéos Jellyfin, le PiP négocie une session HLS H.264/AAC auprès du serveur. La lecture MPV habituelle garde son profil et son URL. Jellyfin peut remuxer les codecs compatibles ou transcoder les autres ; il doit autoriser ces opérations et disposer des ressources nécessaires.
- La version du média et les indices audio/sous-titres sélectionnés sont transmis. Les sous-titres sélectionnés sont incrustés par Jellyfin, puisque l'overlay Flutter/libass n'est pas accessible à AVKit. Le débit est limité au réglage de connexion, avec un plafond de 20 Mbit/s pour ce parcours.
- Pour les films, le manifeste conserve la timeline complète : AVPlayer effectue le seek après `readyToPlay`. Pour la TV en direct, aucun seek n'est demandé, notamment pas vers l'heure du programme EPG.
- Le canal natif est enregistré auprès du moteur Flutter, indépendamment de la présence d'une fenêtre au lancement. La vue source est retrouvée au moment du démarrage.
- La session audio est réservée avant la pause MPV réelle. Le départ PiP attend la première image et `isPictureInPicturePossible`. La limite de 30 secondes est un délai d'échec réseau/préparation, pas une temporisation pour tenter de faire fonctionner AVKit.
- Après `didStartPictureInPicture`, Fladder minimise le lecteur. Revenir en arrière dans le lecteur TV pendant le PiP ne termine plus la session. Une autre vidéo arrête explicitement le PiP précédent.
- La fin ou l'échec du PiP libère uniquement son encodage Jellyfin, identifié par son `PlaySessionId`. Un handle de tuner partagé avec MPV n'est pas fermé. La restauration TV ne tente pas de seek sur le flux live.
- Le mode audio en arrière-plan reste activé. L'accès local est expliqué par `NSLocalNetworkUsageDescription`, et les médias HTTP des serveurs configurés sont autorisés via l'exception ATS dédiée aux médias. La vérification des certificats TLS reste active.
- Un échec affiche un code copiable (version **HLS-2**), sans URL ni jeton. Par exemple `jellyfin_hls_unavailable`, `ios_bridge_missing`, `ios_media_AVFoundationErrorDomain_…` ou `ios_pip_timeout`.

Aucune nouvelle dépendance n'est ajoutée. Le PiP automatique reste désactivé sur iOS.

## Limites

Le ratio natif est celui d'`AVPlayerItem.presentationSize` et AVKit contrôle la taille finale de sa fenêtre. Des bandes noires déjà présentes dans les pixels du média restent dans l'image ; cette correction ne recadre pas automatiquement le contenu. Le guide et le PiP sont deux interfaces différentes.

Les fichiers hors ligne passent directement à AVPlayer et restent limités aux formats Apple. Le NAS et l'iPhone ne sont pas accessibles depuis l'environnement de développement. Des tests Dart et une compilation iOS ne valident donc ni le transcodage de ce NAS, ni la persistance PiP sur iOS 27.0.1.

Sources techniques : le profil utilise l'API PlaybackInfo et les types du client Jellyfin du dépôt. La timeline VOD HLS est également vérifiée dans `Jellyfin.Api/Controllers/DynamicHlsController.cs` du projet Jellyfin. L'accès direct à la documentation Apple est bloqué par le proxy de l'environnement ; ne pas prétendre à une vérification en direct de ses pages.

## Installation et tests

1. Ouvrir l'exécution GitHub Actions correspondant au dernier commit HLS-2 de cette branche. Attendre la réussite de la compilation.
2. Télécharger **Artifacts → Fladder-Feather-iOS**, extraire le ZIP dans Fichiers.
3. Importer l'IPA dans Feather, utiliser le certificat habituel et installer par-dessus Fladder, en conservant l'identifiant de l'application. Ne pas désinstaller l'application existante.
4. Lancer un film et appuyer sur le nouveau bouton portant le texte **PiP**. Si une erreur apparaît, copier son code complet.
5. Après apparition de la vraie fenêtre iOS, naviguer dans la bibliothèque puis revenir à l'accueil iOS pendant au moins 60 secondes. Vérifier image et son.
6. Reprendre/mettre en pause avec les commandes PiP, restaurer le lecteur puis fermer le PiP ; vérifier la position et l'absence de double audio.
7. Refaire le test avec TF1 : utiliser **PiP** dans les commandes de lecture ou dans le guide. Le bouton « Guide TV » seul n'ouvre pas le PiP.
8. Lancer une autre chaîne/vidéo pendant le PiP et vérifier que l'ancien lecteur s'arrête sans appliquer sa position au nouveau.
9. Revenir à l'accueil iOS sans aucune vidéo : aucun PiP ne doit apparaître.
10. Vérifier un vrai 4:3, un vrai 2.39:1 et un 16:9 avec bandes encodées, en distinguant les marges de l'interface et les pixels du film.

En cas d'échec, indiquer le code HLS-2, TV ou film, si l'image démarre, si le son continue et quelle action fait disparaître la fenêtre.
