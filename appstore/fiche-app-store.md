# PlayTendo — fiche App Store (à copier dans App Store Connect)

Préparée le 2026-11-15 pour la version App Store (`zsh scripts/build_appstore.sh`) : NES, SNES, N64, GB/GBC, GBA, DS,
3DS, PS1, PSP, sans turbo ; gratuite avec pubs, achat « Retirer les pubs » à 5,99 €.

Règle d'Apple à garder en tête (guideline 2.3.7) : pas de marque qui n'est pas à nous dans le **nom**, le
**sous-titre** ni les **mots-clés**. Les noms de consoles restent permis dans la **description**, pour dire ce que
l'app fait (comme Delta ou RetroArch).

---

## Informations de l'app

| Champ | Contenu |
|---|---|
| Nom (30 caractères max.) | `PlayTendo` |
| Sous-titre (30 max.) | FR : `Tes jeux rétro, une seule app` · EN : `All your retro games, one app` |
| Catégorie principale | Divertissement (Entertainment) — comme Delta ; secondaire : Jeux › Arcade |
| Identifiant (bundle ID) | `com.playtendo.app` |
| Achat intégré | `com.playtendo.app.removeads` (voir plus bas) |
| URL de confidentialité | `https://playtendo.me/confidentialite/` |
| URL d'assistance | `https://playtendo.me` |
| Copyright | `2026 PlayTendo` |

### Mots-clés (100 caractères max., séparés par des virgules, sans espace)

FR : `émulateur,retro,rétro,jeux,manette,console,8-bit,16-bit,arcade,classique,sauvegarde,portable,pixel`

EN : `emulator,retro,classic,games,controller,console,8-bit,16-bit,arcade,handheld,save,pixel,gaming`

### Texte promotionnel (170 max., modifiable sans nouvelle version)

FR : `Une seule bibliothèque pour tes jeux rétro, avec jaquettes, sauvegardes, retour arrière et manettes. Gratuit.`

EN : `One library for your retro games, with box art, save states, rewind and controller support. Free.`

---

## Description — français

```
PlayTendo réunit tes jeux rétro dans une seule bibliothèque, belle et simple.

Ajoute tes propres jeux (fichiers, .zip, .7z, .rar) : PlayTendo les reconnaît, trouve leur jaquette et les range par console. Un toucher, et tu joues.

CONSOLES
• NES, Super NES, Nintendo 64
• Game Boy, Game Boy Color, Game Boy Advance
• Nintendo DS et Nintendo 3DS
• PlayStation et PlayStation Portable

POUR JOUER
• Sauvegardes rapides, reprise automatique là où tu t'étais arrêté
• Retour arrière et avance rapide
• Manettes Bluetooth (PlayStation, Xbox, Switch, Backbone, Razer Kishi…) et boutons tactiles réglables
• Résolution augmentée et lissage pour la N64, la DS, la 3DS, la PlayStation et la PSP
• Filtres d'image : net, lissé, CRT, LCD
• Câble link Game Boy entre deux appareils proches
• Codes de triche
• Succès RetroAchievements

BIBLIOTHÈQUE
• Jaquettes en 3D, fiches des jeux, favoris, recherche
• Quatre thèmes : Néon, Rétro 8-bit, Minimal sombre, Pixel Art
• En français et en anglais

GRATUIT
PlayTendo est gratuit, avec des pubs discrètes : jamais pendant une partie. Un achat unique les retire pour toujours, sur tous tes appareils.

IMPORTANT
Aucun jeu ni BIOS n'est fourni : utilise uniquement des copies de jeux que tu possèdes. PlayTendo n'est affilié ni à Nintendo ni à Sony.

PlayTendo s'appuie sur des moteurs libres (licences GPL, MPL) : la liste et leurs licences sont dans l'app, rubrique À propos.
```

## Description — anglais

```
PlayTendo brings your retro games together in one simple, good-looking library.

Add your own games (files, .zip, .7z, .rar): PlayTendo recognizes them, finds their box art and sorts them by console. One tap and you're playing.

CONSOLES
• NES, Super NES, Nintendo 64
• Game Boy, Game Boy Color, Game Boy Advance
• Nintendo DS and Nintendo 3DS
• PlayStation and PlayStation Portable

PLAY
• Save states, automatic resume right where you left off
• Rewind and fast-forward
• Bluetooth controllers (PlayStation, Xbox, Switch, Backbone, Razer Kishi…) and customizable touch controls
• Higher resolution and smoothing for N64, DS, 3DS, PlayStation and PSP
• Image filters: sharp, smooth, CRT, LCD
• Game Boy link cable between two nearby devices
• Cheat codes
• RetroAchievements

LIBRARY
• 3D box art, game details, favorites, search
• Four themes: Neon, Retro 8-bit, Minimal Dark, Pixel Art
• In English and French

FREE
PlayTendo is free, with unobtrusive ads: never during play. A one-time purchase removes them forever, on all your devices.

IMPORTANT
No games or BIOS files are included: only use copies of games you own. PlayTendo is not affiliated with Nintendo or Sony.

PlayTendo is built on open-source engines (GPL, MPL licenses): the list and their licenses are in the app, under About.
```

---

## Achat intégré « Retirer les pubs »

| Champ | Contenu |
|---|---|
| Type | Non consommable |
| Nom de référence (interne) | `Retirer les pubs` |
| ID produit | `com.playtendo.app.removeads` (exactement, c'est celui du code) |
| Prix | 5,99 € en France (pays de référence États-Unis : 4,99 $, palier équivalent) |
| Nom affiché FR / EN | `Retirer les pubs` / `Remove ads` |
| Description FR | `Retire toutes les pubs de PlayTendo, pour toujours, sur tous tes appareils.` |
| Description EN | `Removes all ads from PlayTendo, forever, on all your devices.` |
| Capture pour l'examen | Réglages › « PlayTendo sans pubs » (la rubrique avec le bouton et le prix) |
| Partage familial | Au choix (oui = un achat pour toute la famille) |

---

## Confidentialité de l'app (questionnaire « App Privacy »)

PlayTendo lui-même ne collecte rien ; les réponses viennent du kit de pubs de Google (AdMob), d'après la page de Google
« Data disclosure » pour l'App Store (à relire au moment de remplir : Google la met à jour).

**Collectez-vous des données ?** Oui (par un partenaire : Google AdMob).

| Type de donnée | Utilisation | Liée à l'identité ? | Sert au suivi ? |
|---|---|---|---|
| Localisation approximative (déduite de l'adresse IP) | Publicité tierce, analyse | Non | Oui |
| Identifiant de l'appareil (identifiant publicitaire, si le suivi est autorisé) | Publicité tierce, analyse | Non | Oui |
| Données publicitaires (pubs vues, touchées) | Publicité tierce, analyse | Non | Oui |
| Interactions avec le produit | Publicité tierce, analyse | Non | Oui |
| Données de plantage | Publicité tierce, analyse | Non | Non |
| Données de performance | Publicité tierce, analyse | Non | Non |
| Autres données de diagnostic | Publicité tierce, analyse | Non | Non |

Rien d'autre : pas de nom, d'e-mail, de contacts, de photos, de paiement (l'achat passe par Apple), d'historique de
navigation. Les jeux et sauvegardes ne quittent pas l'appareil.

---

## Classification par âge

Questionnaire : tout à « Aucun » / « Non » (pas de violence, de contenu sexuel, de jeux d'argent, d'accès web libre ni
de contenu créé par les utilisateurs dans l'app elle-même). Les pubs étant réglées sur « 12 ans et plus » au maximum,
choisir la classe d'âge qui couvre ce niveau si le questionnaire le demande (probablement **13+** dans les classes
d'Apple de 2025 : 4+, 9+, 13+, 16+, 18+). À vérifier sur le questionnaire au moment de le remplir.

---

## Chiffrement (export)

Déjà réglé dans l'app (`ITSAppUsesNonExemptEncryption` = NO : seulement le HTTPS d'Apple). App Store Connect ne
posera pas la question.

---

## Notes pour l'examinateur d'Apple (App Review)

```
PlayTendo is a multi-system emulator (guideline 4.7). It does not include, download or link to any game, BIOS or ROM: users add their own legally obtained game files through the Files app or the "+" button.

How to test:
1. Download the free, open-source Game Boy homebrew game "Tobu Tobu Girl" by Tangram Games: https://tangramgames.itch.io/tobutobugirl (click "Download Now", then "No thanks, just take me to the downloads", and download the game file; PlayTendo accepts both .gb and .zip).
2. In PlayTendo, tap "+" (top right), choose the downloaded file.
3. The game appears in the library; tap it, then tap Play.

The app is free with AdMob ads (banner in the library, interstitial when leaving a game, never during play). The "Remove ads" non-consumable purchase is in Settings (gear icon) › "PlayTendo without ads", together with "Restore purchases".

No just-in-time compilation (JIT) is used: all engines run in interpreter mode.
PlayTendo's source code is public under GPL-3.0: https://github.com/Cyph3rNoob/PlayTendo
No account is required. RetroAchievements sign-in (Settings › Online) is optional and uses the user's own retroachievements.org account.
```

---

## Captures d'écran à fournir

| Appareil | Taille | Où les prendre |
|---|---|---|
| iPhone 6,9 pouces (obligatoire) | 1320 × 2868 (portrait) ou 2868 × 1320 (paysage) | Simulateur « iPhone 17 Pro Max » (⌘S dans le simulateur) |
| iPad 13 pouces (obligatoire, l'app tourne sur iPad) | 2064 × 2752 ou 2752 × 2064 | Simulateur « iPad Pro 13 pouces » |

3 à 10 par appareil. Conseillé, dans l'ordre :
1. La bibliothèque pleine de jaquettes (thème Néon).
2. Un jeu en paysage avec les boutons tactiles.
3. Un jeu DS ou 3DS (deux écrans).
4. Le menu pause (sauvegarde, retour arrière, filtres).
5. Une fiche de jeu.
6. Les thèmes (Rétro 8-bit ou Pixel Art).

Attention : uniquement des jeux que tu as le droit de montrer. Les jaquettes et écrans de jeux du commerce sont à leurs
éditeurs ; Apple refuse parfois des captures montrant des jeux Nintendo. Le plus sûr : des homebrews gratuits, ou des
captures où la bibliothèque est floutée/recadrée.
