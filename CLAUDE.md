# PlayTendo — notes techniques

App d'émulation SwiftUI pour iPhone, iPad et Mac (Apple Silicon) : consoles Nintendo et Sony de la NES à la PS Vita,
moteurs libres (libretro + moteurs autonomes intégrés). Ces notes servent à reprendre le code vite : organisation,
fonctionnement de chaque partie, retouches des moteurs, pièges connus. Le README présente le projet.

@notes-privees/CLAUDE-prive.md

## Règles de travail
- Tout le texte affiché passe par `tr("…")` (clé = français). Après tout ajout de texte :
  `python3 scripts/check_translations.py` (manquants, doublons = plantage au lancement, français hors `tr()`).
  Le journal (`Journal.txt`) reste en français.
- Toujours compiler et essayer la version **Release** avant de livrer une IPA (des défauts n'apparaissent qu'en
  Release, voir libco dans « Pièges »).
- Ne jamais enchaîner un script de compilation derrière `| tail` : le code de retour de `tail` masque l'échec.
- `rm -rf` sur une variable : toujours `"${VAR:?}"`.
- Versions des moteurs : dernière version stable vérifiée au moment de l'utiliser ; sinon un commit figé, noté ici.
- Retouches des moteurs : uniquement par les scripts `scripts/patch_*.py` (idempotentes, repérées « PlayTendo »,
  numérotées). Si le texte d'une retouche change : remettre le fichier d'origine (`git -C sources/<moteur> checkout --
  <fichier>`) avant de relancer.
- Aucun jeu, BIOS, firmware ni licence dans le dépôt ni téléchargé par les scripts. Clés de service dans `secrets/`
  (ignoré), jamais affichées ni versionnées.
- Branches : `main` = version principale ; `codex-jit` = variante avec JIT intégré (StikJIT), maintenue à part. Vérifier
  `git branch --show-current` et `git status` avant de compiler ou de commiter.

## Organisation du dépôt
| Dossier | Contenu |
|---|---|
| `app/PlayTendo.xcodeproj` | Projet écrit à la main (dossier synchronisé, objectVersion 77), cibles « PlayTendo » (iOS) et « PlayTendo Mac » |
| `app/PlayTendo/` | Code : `Emulation/`, `Controls/`, `Library/`, `Support/`, `UI/`, `Vendor/rcheevos`, `Resources/` |
| `app/Info.plist`, `Info-Mac.plist` | Hors du dossier synchronisé exprès ; `PlayTendo.entitlements` (increased-memory-limit, get-task-allow) |
| `ps2/`, `dolphin/`, `vita/`, `ds/` | Pilotes des moteurs autonomes et compatibilité OpenGL ES de melonDS |
| `cores/assets/` | Bases de reconnaissance (`Bases/*.tsv`), fichiers PPSSPP — versionnés |
| `cores/ios|sim|mac`, `cores/macos` | Moteurs compilés (ignorés par git, refaits par les scripts) ; `cores/macos/*.dylib` = banc d'essai |
| `libs/libarchive/` | En-têtes versionnés ; bibliothèques par plateforme ignorées |
| `scripts/` | Téléchargement, compilation, retouches (`patch_*.py`), outils, banc d'essai (`test/`), `mac/Lisez-moi.txt` |
| `sources/`, `build/`, `PlayTendo-Mac/`, `*.ipa`, `secrets/`, `notes-privees/` | Ignorés |

La phase « Embed cores » du projet copie `cores/ios` (`cores/sim` pour le simulateur, `cores/mac` sur Mac) dans
`Frameworks` et `cores/assets/*` à la racine de l'app, et signe « - » sur Mac.

## Commandes
- `zsh scripts/fetch_sources.sh` : moteurs aux versions figées (+ libretro-database, MoltenVK, OpenSSL, archives
  vérifiées par SHA-256). Vita3K / OpenSSL / Hello World sauf `PLAYTENDO_VITA=0`.
- Moteurs : `build_cores.sh [noms…]` (libretro iPhone → `cores/ios`, fichiers PPSSPP → `cores/assets/PPSSPP`),
  `make_sim_cores.sh` (retague pour le simulateur avec vtool ; ne touche ni PS2, ni Dolphin, ni Vita),
  `build_cores_macos.sh` (frameworks Mac Versions/A minos 14 + dylib du banc), `build_libarchive.sh [mac]`,
  `build_azahar.sh [mac]`, `build_ps2.sh sim|ios|mac [Debug|Release]`, `build_dolphin.sh sim|ios|mac`,
  `build_vita3k.sh [ios|mac]`.
- App : `zsh scripts/build_app.sh` → `PlayTendo.ipa` (Release, signée ad hoc avec les entitlements, symboles retirés,
  `zip -9`) ; `zsh scripts/build_mac.sh` → `PlayTendo-Mac/PlayTendo.app` + `PlayTendo.dmg`. Vita incluse sauf
  `PLAYTENDO_VITA=0` (les scripts vérifient que VitaCore existe). Les tailles affichées viennent de `stat`.
- `scripts/make_secrets.py` : lancé par Xcode (phase « Clés masquées », avant Sources) → `build/generated/PTSecrets.generated.h`.
- Simulateur (Debug) :
  `xcodebuild -project app/PlayTendo.xcodeproj -target PlayTendo -configuration Debug -sdk iphonesimulator -arch arm64 SYMROOT=$PWD/build/xcode OBJROOT=$PWD/build/xcode/obj CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build`
  puis `xcrun simctl install <udid> build/xcode/Debug-iphonesimulator/PlayTendo.app`. Release : même commande avec
  `-configuration Release` et `build/xcode-simrel`. Debug seulement : PS1 accepte `.exe`, PSP `.elf/.prx` (mini-jeux
  de test) ; paysage forcé par `-PTLandscape` ou fichier `Documents/PTLandscape` (captures restées en portrait :
  point paysage (x, y) = point portrait (y, largeur − x)) ; `Documents/PTSansManette` ignore la manette virtuelle
  « Gamepad » que le simulateur annonce toujours ; `Documents/PTGamepad` simule une manette branchée et utilisée.
- Appareil : journal de l'app `xcrun devicectl device copy from --device <id> --domain-type appDataContainer
  --domain-identifier <bundle id réel> --source Documents/Journal.txt --destination …` (lecture seule) ; rapports de
  plantage `devicectl device info files --domain-type systemCrashLogs` puis `atos -o …dSYM/…/PlayTendo -l <base>`.
- Banc d'essai Mac (consoles libretro sans interface) : `build_cores_macos.sh`, puis (zsh)
  `R=app/PlayTendo/Vendor/rcheevos; clang -fobjc-arc -O1 -DDEBUG=1 -DRC_CLIENT_SUPPORTS_HASH -Wno-implicit-enum-enum-cast -w -I app/PlayTendo/Emulation -I app/PlayTendo/Emulation/Vulkan -I $R/include -I $R/src app/PlayTendo/Emulation/PTCore.m app/PlayTendo/Emulation/PTRumble.m app/PlayTendo/Emulation/PTGLContext.m app/PlayTendo/Emulation/PTJIT.m app/PlayTendo/Emulation/PTVulkanContext.m scripts/test/harness.m ${(f)"$(find $R/src -name '*.c')"} -framework Foundation -framework CoreGraphics -framework ImageIO -framework CoreVideo -framework Metal -framework QuartzCore -framework OpenGL -framework IOSurface -o build/test/harness`
  ; `python3 scripts/test/make_test_roms.py build/test/roms` ; `python3 scripts/test/test_buttons.py` (`--system`,
  `--jit 1`). Options du banc : `--press a:150-200`, sticks `sup/sdown/sleft/sright`, C `cup…`, `--cheat 60:c1|c2
  --find BEEF`, `--device 0x205`, `--achievements <console>`, `--realtime 1`, `PT_LOG_DEBUG=1`.
  Mini-jeux maison : une couleur par bouton (A rouge, B vert, X jaune, Y cyan, L orange, R violet, L2/Z rouge foncé,
  R2 violet foncé, Start blanc, Select gris, Haut rose, Bas marron, Gauche vert foncé, Droite bleu clair, tactile DS
  noir, repos bleu ; N64 C haut/bas/gauche/droite = jaune/cyan/gris/violet foncé ; stick = olive/bleu marine/
  turquoise/saumon). N64 : 4 Ko lancés par le démarrage HLE (0xA4000040), manette par le PIF, écran par le RDP.
  PSP : ELF sans sections, fonctions par NID (`test_save.elf` : vert = écrit et relu). DS : bits 10-15 de KEYINPUT
  masqués, EXTKEYIN recopié en 0x023FF000 par l'ARM7, cache ARM9 coupé, VBlank ARM7 activé (Action Replay).
- Simulateur, rafale de captures : `scripts/test/burst.py <udid> <s> <x> <y> [dossier]` (pixels 1320×2868).

## Moteurs
| Console | Moteur | Version | Notes de compilation |
|---|---|---|---|
| NES | Mesen | 0.9.9 | `Libretro/Makefile platform=ios-arm64`, version-min 15.0, CC/CXX/LD imposés |
| SNES | bsnes | v115 | GNUmakefile corrigé (lien `$(compiler)`), `local=false openmp=false`, libco corrigé, `patch_bsnes.py` (WRAM pour RetroAchievements) |
| N64 | Mupen64Plus-Next | commit 12edd2c | `platform=ios-arm64` ; sed libpng (`fp.h`) et zlib (`fdopen`) ; libco corrigé |
| GB, GBC | Gambatte | commit 7809bb6 | make `platform=ios-arm64` / `osx`, `HAVE_NETWORK=1`, `make clean` avant et après ; `patch_gambatte.py` |
| GBA | mGBA | 0.10.5 | CMake iOS, `BUILD_LIBRETRO`, `CMAKE_POLICY_VERSION_MINIMUM=3.5` |
| DS | melonDS DS | 1.4.0 | `ios.toolchain.cmake PLATFORM=OS64`, `BUILD_AS_SHARED_LIBRARY=ON` ; `patch_melonds.py` (OpenGL ES) ; garder son dossier `_deps` |
| 3DS | Azahar | 2126.1.2 (libretro) | voir « 3DS » |
| GameCube, Wii | DolphiniOS | 5.0.0b6 (pas de stable iOS) | voir « GameCube / Wii » |
| PS1 | PCSX-ReARMed | r26l | `Makefile.libretro platform=ios-arm64`, sans dynarec, GPU NEON |
| PS2 | ARMSX2 iOS | 2.6.0 | voir « PS2 » |
| PSP | PPSSPP | v1.20.4 | CMake `ios.cmake -DLIBRETRO=ON`, cible `ppsspp_libretro` ; `patch_ppsspp_jit.py`, `patch_ppsspp_mac.py` |
| PS Vita | Vita3K | commit 681f695 (build 4135, pas de stable) | voir « PS Vita » |

Le « stable » du buildbot RetroArch est recompilé en continu : ce n'est pas une version figée.

## Cœur de l'app
- `Emulation/PTCore.{h,m}` : hôte libretro en Objective-C (dlopen des frameworks, environnement, options v0/v1/v2,
  entrées atomiques, tampon audio circulaire, journal, rendu matériel). Ordre RetroArch : `retro_set_video_refresh`
  & co **après** `retro_init` (sinon Mesen plante). `PT_ENV` retire le bit expérimental (SET_HW_SHARED_CONTEXT et
  SET_SERIALIZATION_QUIRKS valent alors 44 tous les deux). Options : même pointeur si valeur inchangée, anciennes
  chaînes gardées (`_retiredOptionCStrings`) jusqu'au jeu suivant. Horloge des cartouches (RETRO_MEMORY_RTC) gardée
  après la mémoire de sauvegarde derrière la marque « PTRTC1 ». `fillAchievementMemory:`, `appendDiskAtPath:`,
  `switchToDiskAtIndex:`, `setCheats`, `controllerDevice`, `allowsJIT` (`GET_JIT_CAPABLE`), `prefersVulkan`.
- `Emulation/EmulatorSession.swift` (`@unchecked Sendable`, règles de partage en commentaire) : fil d'émulation
  (chargement, images, commandes), cadence corrigée ±0,5 % selon le tampon audio, SRAM sauvée toutes les 30 s et à la
  pause, moteur protégé par `coreLock`. `autoreleasepool` autour de chaque image, photo et chargement (sans lui, les
  photos du retour arrière s'accumulaient : 3,5 Go). Mesure de lenteur toutes les 10 s (> 2 % d'images en retard →
  ligne « Lenteur »). Garde `isFinite` sur l'horloge (« Horloge recalée »). `requestCoreReload(options:)` : à la
  reprise, sauvegarde en mémoire, moteur rechargé, partie rechargée après la première image (`pendingReloadState`,
  120 essais). `runExternal` sert aux moteurs autonomes (PS2, GameCube/Wii) ; `releaseMemory()` arrête le fil PS2 en
  veille avant une autre console. Arrêt demandé regardé entre les étapes (`stopRequestedNow`, `finishBeforeStart`) ;
  bouton « QUITTER LE JEU » après 3 s de chargement.
- `Emulation/ExternalEngine.swift` : protocole des moteurs autonomes (vue, état, boot, pause, arrêt, entrées,
  sauvegardes, vitesse `setSpeed`, codes `applyCheats`, `gameIdentity`, `prepareBoot(resume:)`/`resumeLoaded`,
  erreur, vignette) ; fonctions facultatives pour rester compatible avec un moteur plus ancien.
- Image : `FrameBuffer.swift` (logiciel → BGRA vImage, ou CVPixelBuffer matériel `.hardware(buffer, flipped)`),
  `GameRenderer.swift` + `Shaders.metal` (sharp-bilinear, rectangle source, retournement, FXAA, filtres 2D).
  Consoles libretro : la MTKView reste en pause (`isPaused`, `enableSetNeedsDisplay = false`) ; `GameRenderer`
  dessine lui-même dans sa `CAMetalLayer` (`nextDrawable`) sur `renderQueue`, appelé par `FrameBuffer.addListener` à
  chaque image, demandes fondues (`renderRequested`), réglages sous verrou (`configure`). **La couche d'une MTKView
  annonce `drawableSize` 0×0** tant que la vue n'a pas dessiné : la taille est lue sur la vue (fil principal :
  `update`, `attach`, `drawableSizeWillChange`) dans `Options.size` et posée sur la couche avant `nextDrawable`.
  Image OpenGL à l'envers : avec deux écrans, prendre la partie à l'endroit symétrique (`y = 1 - source.maxY`).
- `AudioOutput.swift` : relance sur `AVAudioEngineConfigurationChange` ; session `.ambient` (muet en mode silencieux) ;
  pause = son coupé.
- Sauvegardes rapides compressées LZFSE (en-tête « PTZ1 »), gardées brutes si le gain est < 10 % ; anciennes brutes
  lisibles. Vignettes « Continuer ».

### Rendu matériel (OpenGL, Vulkan)
- `PTGLContext` (iPhone) : EAGL OpenGL ES 3, profondeur+stencil, 4 CVPixelBuffer BGRA sur IOSurface. Chemin rapide :
  la texture du framebuffer EST le CVPixelBuffer (CVOpenGLESTextureCache), lue par Metal sans copie. Chaque image est
  marquée (`glFenceSync` + `glFlush`) et l'image **précédente** est rendue (plus de `glFinish`). Si le cache refuse
  (-6683, simulateur) : rendu par copie synchrone (`glReadPixels` + vImage). Contexte créé dans SET_HW_RENDER (640×480
  puis géométrie max), `context_reset` après `retro_load_game` (toujours : sinon Mupen plante à la fermeture),
  `makeCurrent` avant chaque `retro_run`. `GL_BGRA` est dans `OpenGLES/ES3/glext.h` ; `#pragma clang diagnostic` pour
  les avertissements (les en-têtes système sont des modules).
- Mac : CGL OpenGL 4.1 core ; framebuffer ordinaire recopié (`glBlitFramebuffer`, scissor coupé) dans 4 CVPixelBuffer
  IOSurface (`CGLTexImageIOSurface2D`) ; PTCore accepte `RETRO_HW_CONTEXT_OPENGL_CORE` ≤ 4.1 et le préfère sur Mac.
- `PTVulkanContext` (3DS, iPhone et Mac) : dlopen de `MoltenVK.framework`, `VK_NO_PROTOTYPES`, instance créée par
  l'app, périphérique créé par le moteur (négociation v1, `VK_EXT_metal_objects` exigé), interface libretro Vulkan v5
  (file protégée par mutex). L'image du moteur est copiée (`vkCmdBlitImage`) dans une image posée sur l'IOSurface d'un
  CVPixelBuffer (3 tampons, une liste de commandes et une barrière par tampon) ; l'image montrée est la précédente.
  Indices de synchronisation : 2 (masque 0x3) ; `wait_sync_index` attend la copie d'il y a deux images. En-têtes dans
  `Emulation/Vulkan` (Vulkan 1.4 de MoltenVK, `libretro_vulkan.h`).

### Mode turbo (JIT)
- `Emulation/PTJIT.{h,m}` : réserve de code à deux vues (RX + alias RW par `vm_remap`), 352 Mo (`JITManager.poolSize`
  = 32 Mo PSP + 320 Mo PS2 ; la PS2 prend 305 Mo d'un bloc, Dolphin 256 Mo), allocateur par blocs de 16 Ko, `PT_JIT_MAX_BLOCKS` = 4096. Blocs ≤ 1 Mo (`PT_JIT_SMALL`) pris à la fin de
  la réserve, gros au début (sinon les petits blocs permanents de la 3DS coupaient la réserve en deux).
  `PTJITLargestFree`, `PTJITFailureCount`, « réserve pleine » détaille l'occupation. Simulateur et Mac : réserve
  simulée (mmap + vm_remap + mprotect RX), valable sur Mac pour une app signée localement sans hardened runtime
  (une notarisation demanderait `com.apple.security.cs.allow-jit` + MAP_JIT).
- iPhone : `Emulation/JITManager.swift`, méthode « Via StikDebug » (`stikdebug://enable-jit?bundle-id=<id réel>&pid=…
  &script-name=universal.js`, attente de P_TRACED 120 s) ou « Désactivé » (clé `methodeJIT`) ; `benefits` = PSP, PS2,
  GameCube, Wii, 3DS, PS Vita (panneau « Mode turbo » au lancement) ; `requires` = PS Vita (pas de « Jouer sans JIT »).
  LocalDevVPN détecté par une interface utun en 10.7.0.0/16 ; `dernierTurboReussi`. `LSApplicationQueriesSchemes` :
  stikdebug. Filet : Dolphin ne démarre pas sans 256 Mo d'un tenant ; un moteur autonome dont une demande a été
  refusée au démarrage est arrêté (« la mémoire du mode turbo est encore occupée… relance PlayTendo »).
- Moteurs branchés sur la réserve (dlsym `PTJITIsActive/PTJITAlloc/PTJITFree`) : PPSSPP (`CodeBlock`,
  `PlatformIsWXExclusive()` faux), Azahar et Vita3K (oaknut/dynarmic : écriture par `wptr()`, exécution par `ptr()`),
  ARMSX2 (`ARMSX2_PlayTendoSetCodeProvider`), Dolphin (`DolphinPlayTendoSetCodeProvider` + `SetJitType(LuckTXM)`).
  Sans réserve active, chacun reste sur son interpréteur.

## Commandes de jeu
- `Controls/ControlLayout` : positions par console et orientation (`make(controllerConnected:hideTouchControls:
  fillScreen:)`, `makeForWindow` sur Mac). `roomy` = plus petit côté ≥ 500 pt (iPad) : bande latérale ≥ bloc de
  commandes + 16, place du bouton menu en bas. DS/3DS en paysage : grands écrans sur toute la largeur, boutons
  par-dessus, avec ou sans manette ; manette utilisée → seuls les boutons disparaissent, l'image ne bouge pas.
  Zone élargie de la croix : L/R/Start/Select prioritaires.
- `Controls/TouchControlsView` (iOS) : multi-touch, glissement, deux sticks (`TouchRole.stick(index)`), boutons C
  (stick droit ±1), écran tactile et pointeur (`usesPointer`) ; un doigt posé sur un bouton ne saisit pas le stick
  voisin ; tête du stick = `CAShapeLayer` déplacée seule.
- `Controls/GamepadManager` : manettes par position ; manettes Nintendo (« Switch », « Joy-Con », « Nintendo » dans
  `productCategory`/`vendorName`) remises par position (B bas, A droite, Y gauche, X haut), et sur GameCube, Wii, N64
  chaque bouton fait sa lettre (`ControlScheme.nintendoLetters`). Deux manettes dans l'ordre de branchement
  (`ordered`) : 2e = joueur 2 sur NES, SNES, N64, PS1, PS2, GameCube, Wii (`GameSystem.supportsTwoPlayers`) ;
  relâche tout à la déconnexion ; stick gauche ≠ croix sur N64/PSP (`stickMovesDPad`).
- Touches de manette sur mesure (`UI/GamepadMappingView`, `Controls/GamepadMapping.swift`, clé
  `touchesManette.<keyboardID>`) ; NES/SNES/GB/GBA : cible « Retour arrière (maintenu) » = L2.
- Vibrations : tout arrive à `PTRumbleSet(port, fort, faible)` (`Emulation/PTRumble.m`) → Core Haptics de la manette
  (`PadHaptics`, file `hapticQueue`) ; coupées en pause ; réglage `vibrationsManette`. Sources : libretro
  (`PTSetRumble`), PS2 (retouche 9 d'ARMSX2), GameCube/Wiimote (retouche 12 de Dolphin). PS1 = DualShock (0x205) ;
  N64 = Rumble Pak seulement si `rumblePakN64` (le Controller Pak garde les sauvegardes de certains jeux).
- Boutons sur mesure (`UI/ControlsEditor.swift`, iOS) : chaque bloc se déplace, s'agrandit (50–170 %), transparence
  0–85 % ; par console (Wii : par manette) et orientation (`boutonsSurMesure.<console>[.<manette>].portrait|paysage`) ;
  appliqué à la fin de `ControlLayout.make`.
- Mac : `Controls/MacInputView.swift`, clavier par position physique (comme RetroArch : flèches = croix, X = A, Z = B,
  S = X, A = Y, Q = L, W = R, E = L2, R = R2, ↩ = Start, ⌫/Maj droite = Select, Échap = menu ; consoles à stick :
  flèches = stick gauche, T F G H = croix, I J K L = stick droit / C) ; noms selon la disposition (UCKeyTranslate) ;
  clic = écran tactile (DS, 3DS, Vita) ; Wii : la souris vise sans cliquer, clic = A, clic droit = B, ⇥ = HOME.
  `KeyBindings` par `ControlScheme.keyboardID` (GB/GBC partagent ; `touchesClavierConsoles`, menu commun
  `touchesClavierMenu`), ⇧⌃⌥ gauche/droite utilisables, ⌘ réservé ; page Réglages › Clavier (`KeyCapture`,
  conflits annulables) et panneau du menu pause.

## Bibliothèque
- `Library/GameSystem` : consoles, extensions, moteur, options imposées, `detect(url)` pour les formats partagés
  (.iso/.cso/.chd/.pbp : ISO 9660 « PLAYSTATION » + SYSTEM.CNF « BOOT2 » = PS2, « BOOT » = PS1, « PSP GAME » = PSP,
  sinon disque Nintendo ; .chd en unités de 2048 = PS2), `displayOrder`, groupe « GB/C ».
- Reconnaissance (`GameIdentifier`, `GameDatabase`) : CRC32 des cartouches ≤ 96 Mo (NES avec/sans iNES, SNES sans
  en-tête copieur, N64 remis en .z64), identifiants d'en-tête (N64 0x3B, GBA 0xAC, DS 0x0C), SYSTEM.CNF (PS1/PS2),
  UMD_DATA.BIN/PARAM.SFO (PSP, .cso par `CSOReader` qui refuse un fichier abîmé), en-tête des disques Nintendo
  (0, 0x58 RVZ/WIA, 0x200 WBFS, 0x8000 CISO, GCZ 0xB10BC001 ; magic GC 0xC2339F3D en 0x1C, Wii 0x5D1C9EA3 en 0x18),
  code produit NCCH 3DS ; sinon le nom du fichier. Bases `cores/assets/Bases/<CONSOLE>.tsv` par
  `scripts/build_game_db.py` depuis libretro-database v1.22.1 (Redump/No-Intro).
- `GameLibrary` : lecture de `Jeux` (une à la fois : `scanning`, `rescanRequested`), `.m3u`/`.cue` (fichiers cités
  supprimés avec le jeu, sauf ceux cités ailleurs ; chemins absolus, « .. » ou « : » ignorés), BIOS PS2 et .PUP rangés
  dans BIOS (`moveToBIOS` par `replaceItemAt`), noms de sauvegarde uniques (`Paths.assignFileNames`, clé
  `nomsFichiersJeux`), dossiers vides retirés après suppression, `DetectionCache` (`Bibliotheque/consoles.json`,
  chemin + taille + date), liste republiée seulement si elle change.
- Jeux en plusieurs disques (PS1, GameCube) : `groupDiscs` (« (Disc n) », Disk, Disque, CD, « of 3 »), clé
  `discFolderKey` (dossier sans son numéro de disque) ; `Game.discs`, `url` = disque 1.
- Import (`importFiles`, file d'attente, bandeau `ImportProgressView` avec annulation, `ScreenAwake`,
  `beginBackgroundTask`) : `ImportResult` (.added / .alreadyThere / .unsupported) ; même nom + même taille = « déjà
  présent ». Archives par libarchive 3.8.9 + liblzma 5.8.4 (`Support/PTArchive` : .zip/ZIP64, .7z, .rar/.rar5, noms
  UTF-8 sinon DOS 437, `maximumEntrySize`, `O_NOFOLLOW`) — le décodeur deflate d'Apple calait sur les zip TorrentZip.
  Décompression dans `Jeux/.import-<uuid>` (caché) puis : un seul fichier → racine de Jeux, sinon dossier au nom de
  l'archive ; `__MACOSX`/`._…` sautés ; place libre vérifiée avant. Homebrews 3DS : tout fichier rangé sous un
  dossier `3ds/<nom>/…` de l'archive est posé au même chemin sur la carte SD 3DS (toujours réécrit). Dossiers
  (`importFolder`, bouton « + » et glisser-déposer) : `collectFolderContent` (3 niveaux, liens et fichiers cachés
  sautés), jeux Vita extraits et rePatch à part, archives/.pup/.vpk/BIOS par `importFile`, autres jeux copiés sous
  `Jeux/<dossier>/<chemin>` (`PTFileCopy`, clone APFS), fichiers inconnus ignorés. `.cia` refusé avec un message
  (le moteur libretro ne les ouvre pas). Journal « Import : <nom> (<format>, <lieu>) → n fichier(s), x écrits en y s
  (z Mo/s ; calcul w s) ».
- Métadonnées (`GameMetadata`) : `Bibliotheque/infos.json` (clé = chemin dans Jeux, revalidée par taille + date),
  `fiches.json` (« console/nom officiel »), `forgetMissingGames()` au lancement, dernières parties
  (`dernieresParties`), `GameDisplay` découpe « Titre - Sous-titre (Région) ».
- Jaquettes, dans l'ordre : perso (`Jaquettes/Perso/<clé>.png`, appui long › Choisir une jaquette, Photos ou le même
  `fileImporter` que l'import réglé par `coverFileGame`), ScreenScraper, libretro-thumbnails, SteamGridDB.
  - ScreenScraper (`Library/ScreenScraper.swift`) : jeuInfos.php (systemeid, romnom, romtype, taille + CRC), sinon
    jeuRecherche.php (≥ 60 % de mots communs) ; « box-3D » sinon « box-2D », région du nom officiel, 640 px ; une
    demande à la fois (`Gate`), 429 → un nouvel essai, 430/431 → pause 12 h, 401/403/426 → arrêt jusqu'au prochain
    lancement ; aucune adresse au journal (elle contient les identifiants). Fiches (`GameDetails`) : résumé, genres,
    date, éditeur, développeur, joueurs, note ; champs lus un par un. Numéros : NES 3, SNES 4, N64 14, GB 9, GBC 10,
    GBA 12, DS 15, 3DS 17, PS1 57, PS2 58, PSP 61, Vita 62, GameCube 13, Wii 16.
  - libretro : `thumbnails.libretro.com/<console>/Named_Boxarts/<nom>.png` (caractères `&*/:\`<>?\|"` → `_`), autres
    régions en secours, nouvel essai au bout d'une semaine.
  - SteamGridDB (`Library/SteamGridDB.swift`) : autocomplete sur le titre (Jaccard ≥ 60 %), grille portrait la mieux
    notée, téléchargée depuis le CDN, réduite à 512 px.
  - `Library/BoxArt.swift` : boîte 3D fabriquée à partir d'une jaquette plate (CIPerspectiveTransform pour face et
    tranche, Core Text pour la tranche) ; trois styles (fin, épais, couché) aux proportions des boîtes ScreenScraper ;
    bords transparents retirés (`trimmed`) ; même hauteur par console (`BoxArt.aspect`).
- Favoris (`GameMetadata.favorites`, clé `favoris`) et tri (`LibrarySort`, clé `triBibliotheque` : nom, dernière
  partie, ajout récent). `SectionCache` (listes rangées une fois), jaquettes décodées 4 à la fois (`DecodeSlots`),
  cache mémoire ≤ 150 Mo.
- Romhacks (`Library/RomPatch.swift`) : .ips/.bps/.ups dans Jeux = jeu à part (`Game.patchBase`) pour NES, SNES, N64,
  GB/GBC, GBA, DS ; origine BPS/UPS par taille + CRC32 (N64 en .z64, SNES aussi sans en-tête 512), IPS par le nom
  (`Bibliotheque/patchs.json`) ; jeu patché écrit au lancement dans `Caches/RomsPatchees/` ; patch ≤ 256 Mo, jeu
  ≤ 512 Mo, nombres sans débordement.
- Codes de triche (`Library/Cheats.swift`, `UI/CheatsView.swift`, `Bibliotheque/codes.json` par `game.key`) :
  - libretro : `retro_cheat_reset` puis un `retro_cheat_set` par morceau, codes activés seulement. Formats
    (`Cheats.parts`) : Mesen un code par appel en MAJUSCULES ; bsnes en **minuscules** (GG `xxxx-xxxx`, PAR, `=`) ;
    mGBA GB joint par « + » ; paires (GBA, N64, PS1, DS, PSP) jointes par **une seule** espace ; PSP : lignes `_L`
    seulement, `ppsspp_cheats=enabled`. Envoi après la 1re image ; PSP après 300 images (numéro de jeu connu).
  - 3DS : retouche 7 d'Azahar (codes Gateway, une paire par ligne). PS2 : `PTPS2SetCheats` écrit
    `cheats/<numéro>_PlayTendo.pnach` puis `ReloadPatches` (`EnableCheats` forcé). GameCube/Wii :
    `PTDolphinSetCheats(actionReplay, gecko)` (AR chiffrés déchiffrés ; `MAIN_ENABLE_CHEATS` nécessaire à Gecko ;
    codes renvoyés 3 s après le démarrage pour remplacer ceux des GameSettings). Pas de codes pour la Vita.
  - « Codes disponibles » (`Library/CheatLibrary.swift`) : libretro-database `cht/` (liste par l'API GitHub,
    7 jours de cache), INI de Dolphin + codes.rc24.xyz (fins de ligne `\r\n`) ; PS2 : pcsx2_cheats_collection
    (`<SERIAL>_<CRC>.pnach`) puis CheatDevicePS2 (versions US seulement).

## Fonctions de jeu
- Menu pause (`PauseMenu` dans `EmulatorView.swift`) : Reprendre ; Sauvegarder › Charger › Retour arrière › Avance
  rapide (`QuickButton`) ; blocs titrés selon la console (IMAGE, ÉCRANS, DISQUE, COMMANDES, CURSEUR 3D…) ; Recommencer
  + Quitter. Paysage et Mac : panneau à onglets de taille fixe. `pick` (réglage de l'app) / `choose` (option moteur).
  TAILLE pour les consoles à un écran (`pleinEcranPSP`, `pleinEcran2D`) ; FILTRE 2D (`Library/FilterSettings.swift`,
  `filtre.<console>` : net, lissé, CRT, LCD).
- Reprise automatique : `Paths.resumeFile` (« ….reprise.state », jamais écrasée par la sauvegarde rapide) écrite en
  quittant ; libretro : relue par `pendingReloadState` ; PS2/Dolphin : démarrage direct sur la sauvegarde
  (`prepareBoot`). Garde-fou : `….reprise.essai` posé au chargement, retiré après 10 s de jeu ; encore là au lancement
  suivant → reprise renommée `….reprise-ecartee.state` et jeu démarré du début (`resumeCrashedLastTime`).
- Retour arrière (NES, SNES, GB/GBC, GBA, N64, PS1 ; `supportsRewind`) : `RewindBuffer`, photos toutes les `interval`
  images, ~30 s, ≤ 128 Mo ; menu pause, L2 maintenue (consoles 2D), Espace sur Mac. Vitesses ×2 à ×5 par appui long /
  clic droit (`vitesseAvanceRapide` défaut 3, `vitesseRetourArriere` défaut 2) ; moteurs autonomes par `setSpeed`.
- Affichage des performances (`UI/PerformanceOverlay.swift`, `affichagePerformances`) : FPS, vitesse, CPU
  (`task_threads`), mémoire (`phys_footprint`), batterie, état thermique (iOS ne donne ni GPU ni degrés), GPU sur Mac
  (IOAccelerator). Compteurs : `producedFrames`, `PTPS2GetPerformance`, `PTDolphinGetPerformance`, `PTVitaGetFrameCount`.
- Batterie : menu pause ouvert = `ScreenAwake.release(.playing)`, son coupé, image libretro arrêtée.
- RetroAchievements : rcheevos 12.5.0 copié dans `Vendor/rcheevos` par `scripts/vendor_rcheevos.py` (retouches :
  `"libretro.h"`, `RC_CLIENT_SUPPORTS_HASH`). `Emulation/PTAchievements` (rc_client, URLSession, do_frame sur le fil
  d'émulation, mémoire par rc_libretro, empreinte rc_hash : pas de .chd/.pbp/.cso). `Library/Achievements.swift` :
  jeton dans le Trousseau (`AfterFirstUnlockThisDeviceOnly`, jamais le mot de passe), Hardcore (chargement, retour
  arrière, triche coupés ; reprise ignorée), bannières. PS2 (retouche 10 d'ARMSX2) et GameCube/Wii (retouche 13 de
  Dolphin) par le même client ; mémoire PS2 = principale puis scratchpad, Wii = MEM1 puis MEM2 à 0x01800000. Messages
  « version du jeu inconnue » / « pas encore de succès ». Reste : réglages interdits en Hardcore, demande de
  validation Hardcore à l'équipe RA.
- Câble link GB/GBC (`Emulation/LinkCable.swift`, `UI/LinkCableView.swift`) : Network.framework avec
  `includePeerToPeer`, Bonjour `_playtendo-link._tcp` (NSLocalNetworkUsageDescription). Hôte = Gambatte serveur
  (56400, 127.0.0.1 seulement) + PlayTendo branché en local et annoncé ; invité = PlayTendo écoute 127.0.0.1:56401,
  Gambatte client (ip_1…12 = 127000000001) ; « PTLINK1 nom\n » puis « PTLINK1 OK ». États `.request` (l'hôte accepte
  ou refuse, refus auto après 1 min), `.waitingApproval` (75 s), `.linking` (le menu pause se ferme et la partie
  reprend : Gambatte n'ouvre son câble que pendant que le jeu tourne), `.connected`. `cleanName` (contrôles, sens du
  texte, 48 caractères). Bandeau « En attente de l'autre Game Boy » (`waitingForOther`, aucune image depuis 1 s).
  Retouches de Gambatte : 1 boucle locale, 2 SO_REUSEADDR, 3 décrochage toutes les 50 ms de vraie durée + client
  toutes les 2 s + TCP_NODELAY, 4 `NetSerial::idle()` à chaque image (un octet reçu alors que le jeu n'attend aucun
  transfert depuis 10 images reçoit [0xFF, 128], comme un vrai Game Boy). Un Game Boy maître attend la réponse en
  bloquant son fil : ne pas mettre un jeu en pause pendant un échange.
- DS en ligne : melonDS DS déjà compilé avec le réseau ; `DSSettings.WiFiServer` (Kaeru WFC par défaut, Wiimmfi,
  AltWFC, Désactivé ; `serveurWifiDS`) → `melonds_network_mode` + `melonds_firmware_wfc_dns`. Jeu sans fil local DS
  impossible dans melonDS DS.

## Consoles libretro
- Options imposées : melonDS DS `melonds_touch_mode=touch`, curseur coupé, écrans empilés sans espace, affichages
  d'état coupés (`show_current_layout`, `mic_state`, `camera_state`, `lid_state`, `sensor_reading` : renvoyés à chaque
  image, ils remplissaient le journal) ; PCSX-ReARMed `pcsx_rearmed_drc=disabled` ; N64 `cached_interpreter`,
  `gliden64`, `rsp hle` ; PSP `ppsspp_cpu_core=JIT` si réserve active sinon IR, `ppsspp_backend=opengl` (« auto » sur
  Mac), wlan/upnp coupés.
- DS : écrans empilés 256×384 ; l'app dessine chaque moitié (`ScreenPlacement`, `GameScreen(source:)`), toucher
  seulement dans l'écran tactile ; taille de l'écran tactile en paysage (`tailleEcranTactileDS`), inversion
  (`ecransInverses.<game.key>`). RÉSOLUTION x1 = rendu logiciel (`melonds_render_mode=software`, threaded, défaut),
  x2–x4 = OpenGL (`ds/PTGLESCompat`, `ds/shaders`) ; changer recharge le moteur (PTCore ne gère SET_HW_RENDER qu'au
  chargement). **Défaut connu** : en OpenGL, certaines textures 3D sont étirées en traînées (Pokémon Noire) sur
  Apple ; le rendu logiciel est propre.
- N64 (`Library/N64Settings`) : RÉSOLUTION x1–x4 (`43screensize` / `169screensize`), FORMAT 4:3/16:9 (« 16:9
  adjusted »), FXAA à 0 ; options lues au démarrage → `requestCoreReload`. Recompilateur arm64 de Mupen jamais compilé
  pour Apple (`linkage_arm64.S` en syntaxe ELF, x18 réservé).
- PS1 (`Library/PS1Settings`) : RÉSOLUTION x1/x2 (`neon_enhancement`), LISSAGE = FXAA de l'app (`fxaaFragment`).
- PSP (`Library/PSPSettings`) : RÉSOLUTION x1–x4 (`internal_resolution`, x4 = 1920×1088), lissage des textures xBRZ.
  Dossier système recopié au lancement dans `Application Support/Systeme/PPSSPP` (marqueur `.version`). **Carte
  mémoire = `Documents/Sauvegardes`** : un dossier nommé « PSP » activerait STRIP_PSP, qui sur un système sensible à
  la casse crée les dossiers de sauvegarde sans leurs fichiers ; dossiers SAVEDATA vides retirés au lancement.

## 3DS (Azahar)
- Sources : archive officielle `azahar-unified-source-2126.1.2.tar.xz` (SHA-256 vérifiée) ; MoltenVK v1.4.2
  (`MoltenVK-ios.tar` iPhone seulement, `MoltenVK-macos.tar`). `build_azahar.sh` (réglages CI iOS, Ninja,
  `CITRA_WARNINGS_AS_ERRORS=OFF`) → `azahar.framework` + `MoltenVK.framework` ; Mac : réglages de la version macOS,
  la bibliothèque MoltenVK de l'archive doit être signée « - ».
- Vulkan seulement (pas d'OpenGL sur Apple). `GameSystem.n3ds` : .3ds .cci .cxi .3dsx .zcci .zcxi .z3dsx, jeux
  **décryptés** ; options : Vulkan, écrans empilés 400×480, `c_stick`, langue. Dossier `Sauvegardes/3DS/Azahar` (le
  moteur ajoute « Azahar/ ») ; carte SD = `…/sdmc` (`Paths.n3dsSDCard`).
- Menu pause : RÉSOLUTION x1–x3 (x4 sur Mac), LISSAGE (ScaleForce), CURSEUR 3D Baissé/Levé (`citra_factor_3d`, par
  jeu `curseur3D.<game.key>`, relu en pleine partie ; `citra_render_3d` reste off). Homebrews : `sdmc:/3ds/dspfirm.cdc`
  factice posé au lancement (`prepareSoundFirmware` : l'audio HLE ne lit pas son contenu, libctru l'exige).
- Retouches (`patch_azahar.py`) : turbo oaknut/dynarmic dans la réserve (32 Mo par cœur iPhone, MAP_JIT natif sur
  Mac), 6 L3 n'inverse plus les écrans, 7 codes Gateway, 8 `SwitchCache` exige `curr_disk_cache` (un homebrew a le
  numéro 0 : après une reprise, aucun carnet de shaders n'était ouvert → plantage), 9 `UPLOAD_BUFFER_SIZE` 512 → 64 Mo,
  10 `async_shader_compilation`.
- Simulateur impossible (MoltenVK iPhone retagué abandonne dans `vkCreateInstance`).

## PS2 (ARMSX2 iOS 2.6.0)
- Pas libretro : le cœur PCSX2 d'ARMSX2 est emballé en `PS2Core.framework` sans interface ni `main()`.
  `build_ps2.sh sim|ios` (projet CMake/Xcode généré dans `sources/armsx2/platforms/ios/build-ios(-sim)-xcode`,
  `default.metallib` renommé `Metal23.metallib`) ; `build_ps2.sh mac` (natif Ninja, `-DPLAYTENDO_PS2_MAC=ON`, shaders
  `xcrun metal -std=macos-metal2.3`).
- Pilotes : `ps2/PTPS2Host.mm` (iPhone, remplace AppDelegate/SceneDelegate ; garde le fil de console permanent) et
  `ps2/PTPS2HostMac.mm` (calqué sur `pcsx2-sdl/Main.cpp`). Fonctions `PTPS2*` (`Emulation/PTPS2.h`) trouvées par
  dlsym (`PTPS2Engine`). INI `Application Support/Systeme/PS2/PCSX2-iOS.ini` ; BIOS = `Documents/BIOS` (chemin
  absolu réécrit à chaque lancement : le conteneur change à chaque réinstallation) ; cartes mémoire
  `Sauvegardes/PS2/Mcd001.ps2` ; journal `Systeme/PS2/logs/emulog.txt` ; sauvegarde rapide = .p2s.
- Réglages imposés : `InputSources/SDL = false`, `OsdMessagesPos = 0`, `AutomaticLoadLastSaveState = false`, Pad2 =
  DualShock2 ; simulateur : `DisableFramebufferFetch = true` ; Mac : MTVU (`vuThread`). Menu pause : RÉSOLUTION x1–x4
  (`upscale_multiplier`), LISSAGE (FXAA), FORMAT 4:3/16:9 (`EnableWideScreenPatches`, format réel lu par
  `PTPS2GetAspectRatio`) ; manette → plein écran en paysage. Démarrage rapide (`demarrageRapidePS2`). Vignette
  `MTGS::SaveMemorySnapshot`. Numéro de jeu nettoyé (lettres, chiffres, « - », « _ », ≤ 32).
- Retouches (`patch_armsx2.py`) : 5 réserve JIT, 6-7 cible Mac, 8 reprise avant la première image
  (`ARMSX2IOSCompleteGameBoot`), 9 vibrations, 10 RetroAchievements. Turbo : `iPSX2_FORCE_EE_INTERP = !PTJITIsActive()`.
- BIOS PS2 reconnu à son contenu (4 ou 8 Mo, « RESET » + « ROMVER ») : import « + » et fichiers posés dans Jeux
  rangés dans BIOS ; Réglages › BIOS PS2 (`Library/PS2BIOS.swift`, région/version lues dans ROMVER via le ROMDIR,
  BIOS utilisé = `[Filenames] BIOS` de l'INI s'il existe, sinon le premier).

## GameCube / Wii (DolphiniOS 5.0.0b6)
- Bibliothèque CMake `dolphin` de DolphiniOS sans son interface : `build_dolphin.sh sim|ios|mac` (Release, Ninja)
  → `DolphinCore.framework` (avec `Sys`). `-DFMT_CONSTEVAL=` (fmt 10.2.1 ne compile pas avec le clang d'Xcode 26).
- Pilote `dolphin/PTDolphinHost.mm` (iOS et Mac) : vue `PTDolphinView` (MTKView en pause), dossier utilisateur
  `Systeme/Dolphin`, cartes GCI `Sauvegardes/GameCube`, NAND `Sauvegardes/Wii`, profils `Touchscreen.ini`,
  `Logger.ini` réécrit (catégorie DVD coupée, `dolphin.log` renommé `-precedent` à chaque lancement). `MAIN_CPU_CORE`
  JITARM64 si turbo ; `MAIN_CPU_THREAD = true` ; compilation des shaders asynchrone (SkipRendering iPhone,
  UberShaders Mac), `GFX_SHADER_COMPILER_THREADS = -1`. Image : RÉSOLUTION x1–x3 (`GFX_EFB_SCALE`), LISSAGE FXAA,
  16:9 GameCube = `GFX_WIDESCREEN_HACK` **et** `GFX_ASPECT_RATIO = ForceWide` ; format lu par
  `PTDolphinGetAspectRatio`. Vignette par `prepareSnapshot()` avant chaque pause. Fastmem : 8 Go d'un bloc sur
  iPhone (exige `increased-memory-limit`).
- Commandes : manette GameCube (par position) ou Wiimote + Nunchuk (`manetteWii.<game.key>`), pointeur au toucher
  ou au stick droit ; profil Wiimote sans `IMU…`. Deux joueurs : manette 2 / Wiimote 2 branchées seulement quand une
  2e manette est là. Disques : `PTDolphinBootDiscs` + `MAIN_AUTO_DISC_CHANGE`, `PTDolphinChangeDisc`.
- Retouches (`patch_dolphin.py`) : réserve JIT (LuckTXM), FileUtil (`Sys` à côté du moteur), MTLUtil (simulateur :
  pas de framebuffer fetch), 5 fastmem 8 Go, 6 capture, 7-8 Mac, 9 `DOLHostQueueRunSync` par sémaphore (l'ancien
  `Common::Event` sur la pile abîmait la pile de l'appelant), 10 `g_playtendo_state_loaded`, 11 numéro de disque,
  12 vibrations, 13 RetroAchievements. Mac : `PTDolphinShutdown` (Stop, attente, `Core::Shutdown` avec join) appelé à
  la sortie, crochet AfterPresent jamais détruit.

## PS Vita (Vita3K, expérimental)
- `build_vita3k.sh [ios|mac]` : OpenSSL 4.0.3 (`build/openssl-ios|mac`), Ninja, `CMAKE_SYSTEM_PROCESSOR=arm64`,
  `CAPSTONE_BUILD_MACOS_THIN=ON`, `USE_AUDIOUNIT=OFF`, symboles exportés limités (`vita/VitaCore.exports`,
  `-Wl,-dead_strip`) ; garder `sources/vita3k/build-playtendo-*/external/ffmpeg.zip` (téléchargé par CMake).
- Pilote : `vita/PTVitaView.mm` (CAMetalLayer **neuve à chaque partie** : une couche réutilisée par une 2e surface
  Vulkan n'affiche plus rien) et `vita/PTVitaHost.cpp` (calqué sur Android ; `set_vita_fs_path` à chaque ouverture,
  `memory_mapping = "double-buffer"`, `high_accuracy = false`, `disable_surface_sync = true`, résolution 0,5–8,
  manette virtuelle SDL, `PTVitaShutdown` à la sortie, `PTVitaOutputCapture`). Mémoire de la console
  `Systeme/Vita/vita/` (ux0/app, patch, addcont exclus de la sauvegarde iCloud) ; journal `Systeme/Vita/vita3k.log`.
- App : `.vpk` ou dossier avec `sce_sys/param.sfo` ; .PUP rangés dans BIOS, installés au premier lancement
  (`pup-installes.txt` ; marqueur `installation-firmware-en-cours`) ; original retiré de Jeux après installation
  (copie ≥ 90 %) ; DLC/mises à jour (`VitaGame.Kind`, installés après le jeu ; une mise à jour est fusionnée par
  Vita3K dans ux0/app) ; rePatch (`rePatch/<ID>`, retouche 16) ; suppression avec ou sans sauvegardes ;
  `officialName` + région d'après l'identifiant pour les jaquettes, icon0.png en secours ; turbo obligatoire ; pas de
  sauvegarde rapide, avance rapide ni recommencer. `PLAYTENDO_VITA` (réglages du projet
  `PLAYTENDO_VITA_CONDITION`/`_DEFINE`) ; sans Vita, `removeVitaLeftovers` garde `ux0/user` et Sauvegardes/Vita.
- Retouches (`patch_vita3k.py`) : CMake `PLAYTENDO`/`PLAYTENDO_IOS`, Boost.Filesystem compilé directement, OpenSSL
  importé, MoltenVK de l'app, turbo (8 Mo de code par recompilateur), 10 compteur de son, 11 pipeline refusé par
  MoltenVK sauté, 12 messages MoltenVK au journal, 13-14 masque GXM émulé (shader interlock), 15 mémoire mappée
  « double buffer » (sans elle, les écritures mémoire des shaders sont ignorées), 16 rePatch dans psvpfsparser,
  17 `.vpk` : chemins hors du jeu refusés.
- État : jeux simples jouables ; interfaces de certains jeux invisibles (menus Minecraft : cause inconnue après le
  masque) ; Metal exige que chaque entrée du fragment shader soit écrite par le vertex shader.

## Version Mac
- Même projet et même code (`#if os(iOS)` / `#if os(macOS)`), arm64, macOS 14, sans bac à sable, signature « - »
  sans hardened runtime (JIT). `Paths.documents` = `~/Library/Application Support/PlayTendo` (Jeux, BIOS,
  Sauvegardes, Journal, Lisez-moi), `Paths.support` = `…/com.playtendo.mac`. Une fenêtre (1180×780), partie
  par-dessus la bibliothèque, plein écran, glisser-déposer, ⌘O, ⌘, ; la veille est empêchée en partie (IOPMAssertion).
- Ouverture depuis le Finder (`MacAppDelegate.application(_:open:)`, `FinderOpen`, `pendingLaunch`) ;
  `com.playtendo.game` exporté au rang Owner, .iso/.zip/.7z/.rar/.m3u en Alternate. `build_mac.sh` : compilation dans
  `build/xcode-mac.noindex`, `lsregister`, .dmg APFS/ULFO avec `scripts/mac/Lisez-moi.txt` ; prévient si l'app est
  ouverte. `MacAppDelegate.applicationWillTerminate` arrête Dolphin, PS2 et Vita (fonctions facultatives).
- Réglages Mac : feuille 820×640, barre Général / Clavier / Jeux et BIOS. Console sans moteur → « … pas encore
  disponible sur Mac » (`engineInstalled`).
- Pièges Mac : GLideN64 activait l'attribut 9 (barycoords) sans « coverage » → l'OpenGL du Mac refuse tout dessin
  (corrigé par sed) ; PPSSPP n'appelle pas `SetGLCoreContext(true)` (shaders sans `#version`, `patch_ppsspp_mac.py`) ;
  Dolphin : fil d'émulation détruit sans join → std::terminate à la sortie.

## Interface
- Thèmes (`UI/Theme.swift`, `AppTheme` : Néon, Rétro 8-bit, Minimal sombre, Pixel Art ; clé `theme`) : palette
  `Neon` calculée, `Font.display` (Orbitron, Press Start 2P à 0,72×, système arrondie), `Chamfer`, `neonGlow`,
  `CyberBackground`, `LightWaves`, `PixelSunset`. Polices dans `Resources/Fonts` avec licences (`UIAppFonts`).
- Langue (`Support/Language.swift`, `Support/English.swift`, clé `langue`) : `tr()`, `trMessage` pour les messages
  Objective-C, `Text(markdown: tr(…))`, `AppLanguage.bytes`.
- Démarrage : `UI/BootView.swift` (≈ 2 s, toucher pour passer, Réduire les animations) ; son
  `Resources/BootSound.m4a` (`scripts/make_boot_sounds.py`, synthèse maison ; `sonDemarrage`) ; logo
  `art/logo-source.jpg` → `swift scripts/make_icon.swift` / `make_mac_icon.swift`.
- Présentation `UI/WelcomeView.swift` (`WelcomeView.version`, clé `presentationVue`), À propos, Lisez-moi
  (`Paths`, réécrit s'il change, liste les consoles présentes), fiche de jeu `UI/GameDetailView.swift`.

## Sécurité
- Réseau : https partout, sans exception ATS ; `Support/CappedDownload.swift` (https seulement, images ≤ 20 Mo,
  textes ≤ 16 Mo) ; `Support/PinnedTrust.swift` (épinglage des racines pour ScreenScraper et SteamGridDB,
  redirections vers un autre site refusées).
- Clés de service : `secrets/` → `make_secrets.py` (clé permutée + XOR, masque aléatoire à chaque compilation) →
  `Support/PTSecrets.{h,m}` (lectures `volatile`, `memset_s`). Une clé intégrée reste récupérable par quelqu'un de
  déterminé (seul un relais serveur l'éviterait).
- Entrées non fiables : archives (taille annoncée, `O_NOFOLLOW`, « .. » refusés), .vpk (retouche 17), patchs, images
  (> 4096 px décodées réduites, `ImageCoding`), .cue/.m3u, numéro de jeu PS2, noms du câble link, liens symboliques
  dans un dossier Vita importé.

## Journaux
- `Documents/Journal.txt` (`PTLogLine`) : lignes répétées comptées, plein à 4 Mo, session précédente dans
  `Journal-precedent.txt`, `PTLogFlush` en arrière-plan ; écrit en différé (dernières lignes avant un plantage :
  `xcrun simctl spawn <udid> log show --last 5m --predicate 'process == "PlayTendo"' --style compact`).
- Moteurs : `Systeme/PS2/logs/emulog.txt`, `Systeme/Dolphin/Logs/dolphin.log`, `Systeme/Vita/vita3k.log`.

## Pièges rencontrés
- **libco arm64** (Mupen64Plus-Next, bsnes) ne sauvegardait pas d8-d15 → plantage en Release seulement :
  `scripts/patch_libco.py`.
- Réserve JIT coupée en deux par les petits blocs permanents de la 3DS → PS2 et Dolphin sans place : petits blocs à
  la fin de la réserve.
- Chemins absolus gardés par un moteur (Vita3K `pref-path`, dossier BIOS de la PS2) : périmés après une
  réinstallation, à réécrire à chaque lancement.
- Simulateur : Metal refuse le framebuffer fetch (PCSX2 abandonne, Dolphin dessine des surfaces sans texture), le
  MSAA de Dolphin et `.b5g6r5Unorm` ; son GL refuse le partage CVPixelBuffer (-6683). Une app lancée par l'outil
  simulateur ne doit pas être arrêtée par `simctl terminate` (elle se fige).
- Xcode ne retire pas d'une app compilée les fichiers d'une cible supprimée : `build_app.sh` efface l'app avant.
- La chaîne d'outils iOS de Dolphin écrase `CMAKE_SHARED_LINKER_FLAGS` → drapeaux en `_RELEASE`.
- Un `extern` écrit dans une fonction d'un espace de noms déclare un symbole de cet espace (lien impossible) :
  déclaration en tête de fichier.
- bsnes : objets macOS restés dans `obj/` → `make clean target=libretro`.
- SDL est en double (PS2Core et VitaCore) : chaque moteur garde sa copie.
- Symboliser un moteur : `nm -n` sur le .dylib non allégé dans `sources/…` (atos ne trouve pas les fonctions
  cachées), `otool -tv` ; rapports Mac dans `~/Library/Logs/DiagnosticReports/*.ips` (ne pas lancer lldb).
- zsh : un motif sans correspondance arrête la commande ; citer `--include=*.c` ; dans `"$var:..."`, `:a`, `:h`…
  sont des modificateurs (écrire `"${var}:…"`).
- Les catégories vides sont masquées ; GB/GBC classés par extension.
