# PiP iPhone : correction candidate, à valider sur appareil

Base : `1054fb56ed862dd4c77a51dfabf14f22480a9da8` (branche expérimentale).
Branche de travail : `fix/ios-pip-persistent-session`. Ne pas fusionner dans develop avant les essais iPhone.

## Constats vérifiés dans les sources

- `LibMPV.pause()` lançait un fondu asynchrone après avoir rendu la main. Attendre 225 ms ne garantissait pas la pause réelle.
- `closePlayer()` appelait `stop()`, qui signalait la fin de lecture à Jellyfin et effaçait le modèle utilisé pour restaurer la lecture. Une navigation ne doit pas terminer la session PiP.
- Le démarrage AVKit pouvait précéder la fin du seek et la disponibilité de la première image.
- La restauration native répondait `true` sans demander à Flutter de rouvrir le lecteur.
- La restauration Dart ne vérifiait pas si l'utilisateur avait changé de vidéo.
- Le verrouillage au retour de l'application considérait uniquement MPV, mis en pause pendant le PiP.

Ces défauts sont démontrables. Ils ne prouvent pas à eux seuls la cause de tous les arrêts observés en arrière-plan. Il manque les événements AVKit et un essai sur l'iPhone concerné.

## Changements

Le transfert réserve l'audio avant de demander une pause MPV réelle, sans fondu ni délai fixe. Un échec rend la lecture à MPV. Les doubles demandes sont refusées. AVPlayer demande explicitement la poursuite en arrière-plan et attend le seek et la première image avant de démarrer le PiP. La temporisation de 15 secondes reste uniquement une limite d'échec réseau/décodage.

Après confirmation AVKit, le lecteur Flutter est minimisé. Ses commandes de mini-lecteur sont masquées pendant le PiP natif. Le bouton de restauration iOS demande réellement la réouverture du lecteur. Une nouvelle vidéo arrête d'abord l'ancien PiP sans restaurer son ancienne position. Le mode automatique reste désactivé sur iOS.

La surface conserve le ratio `presentationSize`, y compris en portrait. Aucun recadrage des pixels encodés n'est effectué. iOS contrôle les dimensions finales de sa fenêtre PiP. `resizeAspect` ne retire pas les bandes noires déjà encodées.

## Limites et architecture

AVPlayer peut alimenter AVKit directement ; MPV fournit une texture Flutter qui ne devient pas automatiquement une source PiP. Une solution AVSampleBufferDisplayLayer nécessiterait un véritable pipeline de décodage, timestamps, audio et commandes de lecture. Aucun nouveau composant ni changement de licence n'est introduit ici.

Cette correction conserve l'URL existante. La compatibilité de MPV ne garantit pas celle d'AVPlayer : MKV, certains codecs, sous-titres externes et sélection des pistes nécessitent encore des essais et éventuellement un profil HLS/transcodage Jellyfin dédié. La sélection MPV des pistes et les sous-titres Flutter ne sont pas transférés au lecteur Apple. Aucun transcodage nouveau n'est implémenté dans cette correction.

Le mode `audio` est déjà déclaré dans Info.plist. `NSAllowsLocalNetworking` ne garantit pas l'accès à toute adresse HTTP ou tout certificat TLS. Un échec d'accès/format doit rendre la main à MPV. Le code ne journalise pas les URLs ni les jetons du NAS.

Référence officielle à consulter : https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-in-a-standard-player . L'accès à developer.apple.com a été refusé par le proxy lors de cette intervention ; cette documentation n'a donc pas pu être vérifiée en direct.

## Installation et essais

Dans GitHub, ouvrir Actions → « iOS - IPA pour Feather » et choisir une exécution de `fix/ios-pip-persistent-session`. Attendre la réussite des tests ET de la compilation. Dans Artifacts, télécharger `Fladder-Feather-iOS`. Extraire le ZIP dans Fichiers, importer `Fladder-Feather-unsigned.ipa` dans Feather et signer avec votre certificat habituel. Installer par-dessus Fladder avec le même identifiant d'application. Ne pas désinstaller la version existante.

1. Sans vidéo : revenir à l'accueil iOS. Aucun PiP ne doit apparaître.
2. Lire un MP4 H.264/AAC connu : demander PiP. Vérifier une seule piste sonore et une image animée.
3. Naviguer dans la bibliothèque pendant 60 secondes : la fenêtre et le son doivent continuer.
4. Revenir à l'accueil iOS puis ouvrir une autre application pendant 60 secondes.
5. Mettre en pause/reprendre depuis la fenêtre PiP.
6. Restaurer avec le bouton iOS : vérifier que le lecteur se rouvre au bon moment, sans double audio.
7. Fermer le PiP, revenir à Fladder, vérifier la position et l'état pause/lecture.
8. Lancer une autre vidéo pendant le PiP : aucune ancienne position ne doit être appliquée à la nouvelle vidéo.
9. Essayer un fichier 4:3, un vrai 2.39:1, une vidéo portrait puis un 16:9 avec bandes encodées. Les bandes encodées sont attendues.
10. Essayer vos fichiers habituels, pistes audio et sous-titres. En cas d'échec du démarrage, la lecture normale doit reprendre.

Pour chaque échec, préciser le modèle d'iPhone, la version iOS, l'étape, le format du fichier et si le son continue. Une compilation réussie n'est pas une validation du PiP sur appareil.
