# Journal des modifications

Historique **technique** des évolutions de l'app **Étiquettes EBP** (pour les développeurs).
Les **notes publiées sur l'App Store** (orientées utilisateur) sont séparées, dans
`fastlane/metadata/<langue>/release_notes.txt`.

Format inspiré de [Keep a Changelog](https://keepachangelog.com/fr/). Versions selon
[SemVer](https://semver.org/lang/fr/). Version anglaise : [CHANGELOG.md](CHANGELOG.md).

## [1.1] — 2026-11-18

### Ajouté
- **Partage entre téléphones** regroupé dans les Réglages : exporter les modèles d'étiquette et les réglages d'imprimante, ensemble (« Tout exporter ») ou séparément, et un import universel qui reconnaît automatiquement ce qu'il reçoit.
- **Partage par QR code en plusieurs pages** pour les contenus trop longs pour un seul code (utile sans AirDrop). Défilement manuel des pages ; l'appareil récepteur vérifie une signature avant d'appliquer, pour garantir un transfert complet et intègre.
- **Vérification de mise à jour au démarrage** : l'app prévient quand une version plus récente est disponible sur l'App Store.

### Modifié
- **Scan plus fluide** : un code maintenu devant la caméra n'est plus relu en boucle (plus de vibrations répétées). En scan multiple, un article n'est ajouté qu'une fois ; la quantité se règle ensuite dans le lot.
- Pendant un transfert par QR, la feuille ne se ferme plus par glissement accidentel.

### Corrigé
- **Code-barres EAN-13** : une erreur d'encodage empêchait certaines étiquettes d'être lues par les douchettes de caisse.
- **Partage AirDrop** fiabilisé pour les modèles et les réglages imprimante (la feuille de partage ne s'ouvrait pas dans certains cas ; popover géré sur iPad).
- **Historique** : « Reprendre » et « Restaurer » ouvrent la fiche du bon article, rechargée depuis la gateway (stock, HT, TVA à jour).
- **Orientation** : l'iPhone est de nouveau bloqué en portrait ; l'iPad conserve les quatre orientations.

## [1.0] — 2026-11-14

### Ajouté
- Première version publique. Impression d'étiquettes produit depuis une gateway EBP.
- Recherche d'articles, scan de code-barres, fiche article (prix TTC/HT, TVA, stock).
- Modèles d'étiquette (presets + modèles perso), choix du format et de l'imprimante (Pocket 5890, Brother, NETUM).
- Multi-impression par lot, historique des articles consultés et imprimés.
- Mode démonstration hors ligne (données fictives, impression simulée).

[1.1]: https://github.com/id-synergy/etiquettes-ebp/releases/tag/v1.1
[1.0]: https://github.com/id-synergy/etiquettes-ebp/releases/tag/v1.0
