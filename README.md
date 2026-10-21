<p align="center">
  <img src="art/logo-source.jpg" alt="PlayTendo" width="320">
</p>

# PlayTendo

App d'émulation pour **iPhone, iPad et Mac** : une seule bibliothèque pour les consoles Nintendo et Sony,
de la NES à la PS Vita. App personnelle, installée sur iPhone avec AltStore.

> Aucun jeu ni BIOS n'est fourni : utilise les tiens. App non affiliée à Nintendo ni à Sony.

## Télécharger

Les versions prêtes à installer sont dans **[Releases](../../releases)** :

| Fichier | Pour | Installation |
|---|---|---|
| `PlayTendo.ipa` | iPhone, iPad | AltServer sur le Mac (icône › ⌥ › « Sideload .ipa… ») ou AltStore. Toujours installer **par-dessus** l'ancienne version : supprimer l'app effacerait jeux et sauvegardes. |
| `PlayTendo.dmg` | Mac avec puce Apple (M1 ou plus récent), macOS 14 ou plus | Glisser PlayTendo dans Applications. Si macOS la bloque : Réglages Système › Confidentialité et sécurité › « Ouvrir quand même ». |

## Consoles

| Console | Moteur | Version |
|---|---|---|
| NES | Mesen | 0.9.9 |
| Super Nintendo | bsnes | v115 |
| Nintendo 64 | Mupen64Plus-Next | commit 12edd2c |
| Game Boy, Game Boy Color, Game Boy Advance | mGBA | 0.10.5 |
| Nintendo DS | melonDS DS | 1.4.0 |
| Nintendo 3DS | Azahar | 2126.1.2 |
| GameCube, Wii | Dolphin (DolphiniOS) | 5.0.0b6 |
| PlayStation | PCSX-ReARMed | r26l |
| PlayStation 2 | ARMSX2 iOS | 2.6.0 |
| PlayStation Portable | PPSSPP | v1.20.4 |
| PS Vita (**expérimental**) | Vita3K | build 4135 |

**PS Vita : expérimental.** Le moteur Vita3K n'a pas encore de version stable : certains jeux plantent, s'affichent
mal ou ne démarrent pas. Il faut le firmware de ta console (`PSVUPDAT.PUP`, dans le dossier BIOS) et, sur iPhone,
le mode turbo (StikDebug).

La liste des formats acceptés et des BIOS est dans le fichier **Lisez-moi.txt** que l'app crée dans ses
Documents.

## Compiler

Il faut un Mac avec puce Apple et Xcode.

```bash
zsh scripts/fetch_sources.sh   # télécharge les moteurs aux versions stables
zsh scripts/build_app.sh       # app iPhone → PlayTendo.ipa
zsh scripts/build_mac.sh       # app Mac → PlayTendo-Mac/PlayTendo.dmg
```

Les moteurs déjà compilés sont dans `cores/`. Pour en refaire un : `scripts/build_cores.sh` (moteurs libretro),
`build_ps2.sh`, `build_dolphin.sh`, `build_azahar.sh`, `build_vita3k.sh` (iPhone) et `build_cores_macos.sh` (Mac).

La clé SteamGridDB (jaquettes de secours) va dans `secrets/steamgriddb.key`. Ce dossier n'est jamais envoyé sur
GitHub ; la clé est masquée dans l'app à la compilation.

## Organisation

| Dossier | Contenu |
|---|---|
| `app/` | Projet Xcode et code de l'app (Swift, Objective-C) : un seul projet pour iPhone et Mac |
| `cores/` | Moteurs compilés : `ios/`, `sim/` (simulateur), `mac/`, et leurs fichiers (`assets/`) |
| `ps2/`, `dolphin/`, `vita/`, `ds/` | Code qui relie PlayTendo aux moteurs PS2, GameCube/Wii, PS Vita et DS |
| `libs/` | libarchive (ouverture des .zip, .7z, .rar) |
| `scripts/` | Compilation, retouches des moteurs (`patch_*.py`) et bancs d'essai (`test/`) |
| `art/` | Logo |
| `vitrine/` | Page de présentation |
| `CLAUDE.md` | Notes de travail détaillées (choix, pièges, historique) |

## Licences

Chaque moteur garde sa licence (GPL pour la plupart) ; la liste complète est dans l'app, écran **À propos**.
