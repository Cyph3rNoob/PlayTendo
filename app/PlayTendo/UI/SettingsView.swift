import SwiftUI
import UniformTypeIdentifiers

/// Réglages de l'app, rangés en rubriques (`Page`) : Apparence, En jeu, Mode turbo (JIT), En ligne, BIOS et firmwares.
/// iPhone/iPad : un accueil d'une ligne par rubrique, avec son état. Mac : une barre de gauche, plus Clavier et Dossiers.
struct SettingsView: View {
    @AppStorage(PerformanceSettings.key) private var showPerformance = false
    @AppStorage(RumbleSettings.key) private var rumbleEnabled = true
    @AppStorage(N64Settings.rumblePakKey) private var n64RumblePak = false
    /// PS2 : démarrage sans le logo de la console (PS2Settings.fastBoot).
    @AppStorage(PS2Settings.fastBootKey) private var ps2FastBoot = true
    /// DS : serveur du jeu en ligne (DSSettings.WiFiServer).
    @AppStorage(DSSettings.wifiServerKey) private var dsWiFiServer = DSSettings.WiFiServer.kaeru.rawValue
    @EnvironmentObject private var jit: JITManager
    /// Compte RetroAchievements, affiché sur la ligne « En ligne ».
    @ObservedObject private var achievements = Achievements.shared
    @AppStorage(BootSound.enabledKey) private var bootSound = true
    @AppStorage(AppLanguage.key) private var language = AppLanguage.automatic
    @AppStorage(AppTheme.key) private var theme = AppTheme.neon
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var stikDebugInstalled = false
    @State private var vpnConnected = false
    @State private var biosList: [PS2BIOS.Info] = []
    @State private var biosInUse: PS2BIOS.Info?
    @State private var importingBIOS = false
    /// Ce que le sélecteur de fichier importe (un seul sélecteur pour la vue).
    @State private var importKind = ImportKind.ps2BIOS
    @State private var biosBusy = false
    @State private var biosAlert: (title: String, text: String)?
#if PLAYTENDO_VITA
    @State private var vitaFiles: [VitaFirmware.Info] = []
    @State private var vitaHasFirmware = false
    @State private var vitaHasFonts = false
    @State private var vitaBusy = false
#endif

    private enum ImportKind { case ps2BIOS, vitaFirmware }
#if os(macOS)
    /// Mac : rubrique affichée, retenue d'une ouverture à l'autre.
    @AppStorage("pageReglagesMac") private var page = "appearance"
#endif

    var body: some View {
        layout
            .fileImporter(isPresented: $importingBIOS, allowedContentTypes: [.item]) { result in
                guard case .success(let url) = result else { return }
                switch importKind {
                case .ps2BIOS: importBIOS(url)
#if PLAYTENDO_VITA
                case .vitaFirmware: importVitaFirmware(url)
#else
                case .vitaFirmware: break
#endif
                }
            }
            .alert(biosAlert?.title ?? "", isPresented: Binding(get: { biosAlert != nil },
                                                                set: { if !$0 { biosAlert = nil } })) {
                Button("OK") {}
            } message: {
                Text(biosAlert?.text ?? "")
            }
            .onAppear(perform: refreshChecks)
            .onChange(of: language) { _, _ in
                // Tout s'affiche aussitôt dans la nouvelle langue ; le Lisez-moi suit, et les BIOS sont relus.
                Paths.writeReadme()
                refreshBIOS()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshChecks() }
            }
            .tint(Neon.tint)
            .preferredColorScheme(theme.colorScheme)
    }

    /// Rubriques des Réglages : une ligne par rubrique sur l'accueil (iPhone, iPad), une page dans la barre de gauche (Mac).
    private enum Page: String, CaseIterable, Identifiable {
        case appearance, play, turbo, online, keyboard, systemFiles, folders

        var id: String { rawValue }

        var title: String {
            switch self {
            case .appearance: tr("Apparence")
            case .play: tr("En jeu")
            case .turbo: tr("Mode turbo (JIT)")
            case .online: tr("En ligne")
            case .keyboard: tr("Clavier")
            case .systemFiles: tr("BIOS et firmwares")
            case .folders: tr("Dossiers")
            }
        }

        var subtitle: String {
            switch self {
            case .appearance: tr("Langue, thème, son au démarrage")
            case .play: tr("Performances, vibrations, Rumble Pak N64")
            case .turbo: tr("État, activation, ce qu'il faut")
            case .online: EmulatorSession.engineInstalled(for: .nds) ? tr("RetroAchievements, DS en ligne") : "RetroAchievements"
            case .keyboard, .folders: ""
            case .systemFiles: systemFilesSubtitle
            }
        }

        var icon: String {
            switch self {
            case .appearance: "paintpalette"
            case .play: "gamecontroller"
            case .turbo: "bolt"
            case .online: "globe"
            case .keyboard: "keyboard"
            case .systemFiles: "cpu"
            case .folders: "folder"
            }
        }

        /// Ce que contient « BIOS et firmwares », selon les consoles présentes dans l'app.
        private var systemFilesSubtitle: String {
            var vita = false
#if PLAYTENDO_VITA
            vita = EmulatorSession.engineInstalled(for: .vita)
#endif
            let ps2 = EmulatorSession.engineInstalled(for: .ps2)
            if ps2 && vita { return tr("BIOS PS2, firmware PS Vita") }
            return ps2 ? tr("BIOS PS2") : tr("Firmware PS Vita")
        }

        /// BIOS PS2 ou firmware de la PS Vita : seulement si leur console est dans l'app.
        static var hasSystemFiles: Bool {
#if PLAYTENDO_VITA
            if EmulatorSession.engineInstalled(for: .vita) { return true }
#endif
            return EmulatorSession.engineInstalled(for: .ps2)
        }

#if os(iOS)
        static var visible: [Page] { [.appearance, .play, .turbo, .online] + (hasSystemFiles ? [.systemFiles] : []) }
#else
        static var visible: [Page] { [.appearance, .play, .online, .keyboard] + (hasSystemFiles ? [.systemFiles] : []) + [.folders] }
#endif
    }

    /// Ce qu'affiche la ligne d'une rubrique à droite (thème choisi, état du turbo, compte, fichier manquant).
    private func status(of page: Page) -> (text: String, color: Color)? {
        switch page {
        case .appearance: return (theme.label, Neon.dim)
        case .turbo: return (statusTitle, statusColor)
        case .online:
            guard let name = achievements.userName else { return nil }
            return (name, Neon.dim)
        case .systemFiles: return missingSystemFile ? (tr("Manquant"), Neon.magenta) : nil
        case .play, .keyboard, .folders: return nil
        }
    }

    /// Un fichier obligatoire manque : BIOS PS2, ou firmware de la PS Vita (ni installé ni prêt à l'être).
    private var missingSystemFile: Bool {
        if EmulatorSession.engineInstalled(for: .ps2) && biosList.isEmpty { return true }
#if PLAYTENDO_VITA
        if EmulatorSession.engineInstalled(for: .vita) && !vitaHasFirmware && vitaFiles.isEmpty { return true }
#endif
        return false
    }

    /// Les sections d'une rubrique (communes à l'iPhone et au Mac, sauf le mode turbo et les dossiers).
    @ViewBuilder private func sections(of page: Page) -> some View {
        switch page {
        case .appearance:
            languageSection
            bootSection
        case .play:
            playSection
#if os(macOS)
            macTurboSection
#endif
        case .turbo:
#if os(iOS)
            jitSections
#else
            EmptyView()
#endif
        case .online:
            RetroAchievementsSection()
            dsOnlineSection
        case .systemFiles:
            biosSection
#if PLAYTENDO_VITA
            vitaSection
#endif
        case .keyboard, .folders:
            EmptyView()
        }
    }

#if os(iOS)
    private var layout: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Page.visible) { page in
                        NavigationLink(value: page) { pageRow(page) }
                    }
                }
            }
            // Thème changé : la liste est refaite avec ses nouvelles couleurs.
            .id(theme)
            .navigationTitle(tr("Réglages"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Page.self) { page in
                List { sections(of: page) }
                    .id(theme)
                    .navigationTitle(page.title)
                    .navigationBarTitleDisplayMode(.inline)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .task {
                // LocalDevVPN peut se connecter pendant que les réglages sont ouverts.
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    vpnConnected = JITManager.isLocalDevVPNConnected
                }
            }
        }
    }

    /// Ligne d'une rubrique sur l'accueil : icône, titre, ce qu'elle contient, et son état à droite.
    private func pageRow(_ page: Page) -> some View {
        HStack(spacing: 12) {
            Image(systemName: page.icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Neon.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(page.title)
                Text(page.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let status = status(of: page) {
                Text(status.text)
                    .font(.subheadline)
                    .foregroundStyle(status.color)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var jitSections: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: statusIcon)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(statusColor)
                    .neonGlow(statusColor, radius: 6)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle).font(.headline)
                    if let detail = statusDetail {
                        Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)

            Picker(tr("Activation"), selection: $jit.method) {
                ForEach(JITManager.Method.allCases) { method in
                    Text(method.label).tag(method)
                }
            }

            if jit.method != .off && !jit.isActive {
                Button {
                    Task { try? await jit.activate() }
                } label: {
                    Label(tr("Activer maintenant"), systemImage: "bolt.fill")
                }
                .disabled(isActivating)
            }
        } header: {
            Text(tr("Mode turbo (JIT)"))
        } footer: {
            Text(tr("Accélère la PSP, la PS2, la GameCube, la Wii et la 3DS (sans lui, la PS2, la GameCube, la Wii et la 3DS sont injouables). Il s'active une fois par ouverture de PlayTendo, tout seul au lancement d'un de ces jeux, et reste actif jusqu'à la fermeture de l'app."))
        }

        if jit.method == .stikDebug {
            Section {
                Requirement(text: tr("StikDebug installé"), done: stikDebugInstalled)
                Requirement(text: tr("Ton fichier de jumelage importé dans StikDebug"), done: jit.hasWorked ? true : nil)
                // Le VPN ne sert qu'au moment de l'activation : turbo actif, son absence n'est pas une erreur.
                Requirement(text: tr("LocalDevVPN connecté (en Wi-Fi de préférence)"),
                            done: vpnConnected ? true : (jit.isActive ? nil : false))
                Requirement(text: tr("Mode développeur activé (Réglages › Confidentialité et sécurité)"), done: jit.hasWorked ? true : nil)
            } header: {
                Text(tr("Ce qu'il faut"))
            } footer: {
                Text(tr("Au lancement d'un jeu PSP, PS2, GameCube, Wii ou 3DS, StikDebug s'ouvre quelques secondes puis te ramène dans PlayTendo. LocalDevVPN ne sert qu'à ce moment-là. PlayTendo ne peut pas lire le fichier de jumelage ni le mode développeur : leurs cases se cochent dès qu'un turbo a réussi."))
            }
        }
    }
#else
    /// Mac : une barre de gauche (les rubriques) et la page choisie, au style des réglages de macOS.
    private var layout: some View {
        HStack(spacing: 0) {
            List(selection: Binding(get: { currentPage }, set: { if let choice = $0 { page = choice.rawValue } })) {
                ForEach(Page.visible) { item in
                    HStack {
                        Label(item.title, systemImage: item.icon)
                        Spacer(minLength: 4)
                        // Seul un fichier manquant est signalé dans la barre (la place y est comptée).
                        if item == .systemFiles, let status = status(of: item) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(status.color)
                                .help(status.text)
                        }
                    }
                    .tag(item)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 200)

            Divider()

            VStack(spacing: 0) {
                let current = currentPage
                Text(current.title)
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 2)
                macPage(current)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack {
                    Spacer()
                    Button("OK") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                }
                .padding(12)
            }
        }
        // Thème changé : les pages sont refaites avec leurs nouvelles couleurs.
        .id(theme)
        .frame(minWidth: 760, idealWidth: 820, minHeight: 540, idealHeight: 640)
    }

    /// Page retenue ; une ancienne valeur (« general », « games ») ou une rubrique masquée ramène à la première.
    private var currentPage: Page {
        guard let saved = Page(rawValue: page), Page.visible.contains(saved) else { return .appearance }
        return saved
    }

    @ViewBuilder private func macPage(_ current: Page) -> some View {
        switch current {
        case .keyboard:
            KeyboardSettingsPage()
        case .folders:
            Form {
                Section {
                    LabeledContent(tr("Dossier des jeux")) {
                        Button(tr("Afficher dans le Finder")) {
                            NSWorkspace.shared.activateFileViewerSelecting([Paths.games])
                        }
                    }
                    LabeledContent {
                        Button(tr("Ouvrir")) { NSWorkspace.shared.open(Paths.documents) }
                    } label: {
                        Text(tr("Dossier PlayTendo"))
                        Text(tr("Jeux, BIOS, sauvegardes"))
                    }
                } footer: {
                    Text(tr("Les jeux posés dans le dossier Jeux apparaissent dans la bibliothèque, comme ceux ajoutés avec le bouton +."))
                }
            }
            .formStyle(.grouped)
        default:
            Form { sections(of: current) }
                .formStyle(.grouped)
        }
    }

    /// Mac : état du mode turbo, dans « En jeu » (il s'active tout seul, rien à régler).
    @ViewBuilder private var macTurboSection: some View {
        if GameSystem.allCases.contains(where: { JITManager.benefits($0) && EmulatorSession.engineInstalled(for: $0) }) {
            Section {
                LabeledContent(tr("Mode turbo (JIT)")) {
                    Label(jit.isActive ? tr("Actif") : statusTitle, systemImage: jit.isActive ? "bolt.fill" : statusIcon)
                        .foregroundStyle(statusColor)
                }
            } footer: {
                Text(tr("Sur Mac, le mode turbo s'active tout seul : rien à installer."))
            }
        }
    }
#endif

    private var languageSection: some View {
        Section {
            Picker(tr("Langue"), selection: $language) {
                ForEach(AppLanguage.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            Picker(tr("Thème"), selection: $theme) {
                ForEach(AppTheme.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
        } footer: {
#if os(iOS)
            Text(tr("Automatique : la langue de l'iPhone (le français s'il passe avant l'anglais, sinon l'anglais)."))
#else
            Text(tr("Automatique : la langue du Mac (le français s'il passe avant l'anglais, sinon l'anglais)."))
#endif
        }
    }

    /// BIOS PS2 : seulement si la PS2 est dans l'app.
    @ViewBuilder private var biosSection: some View {
        if EmulatorSession.engineInstalled(for: .ps2) {
            Section {
                if biosList.isEmpty {
                    Requirement(text: tr("Aucun BIOS PS2"), done: false)
                }
                ForEach(biosList) { bios in
                    let used = bios.fileName == biosInUse?.fileName
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bios.fileName)
                                .font(.subheadline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text([bios.summary ?? tr("Version inconnue"), used ? tr("utilisé par la PS2") : nil]
                                    .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(used ? Neon.cyan : Neon.dim)
                        }
                    } icon: {
                        Image(systemName: used ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(used ? Color.green : Neon.dim)
                    }
                }
                Button {
                    importKind = .ps2BIOS
                    importingBIOS = true
                } label: {
                    if biosBusy {
                        Label(tr("Import…"), systemImage: "hourglass")
                    } else {
                        Label(tr("Importer un BIOS PS2…"), systemImage: "square.and.arrow.down")
                    }
                }
                .disabled(biosBusy)
            } header: {
                Text(tr("BIOS PS2"))
            } footer: {
                Text(tr("Obligatoire pour la PS2. Choisis le BIOS de ta console (fichier de 4 Mo, souvent « SCPH-… », n'importe quel nom ; dans un .zip, .7z ou .rar aussi) : PlayTendo vérifie que c'en est bien un et le range dans le dossier BIOS. PlayTendo n'en fournit aucun."))
            }
            Section {
                Toggle(isOn: $ps2FastBoot) {
                    Label(tr("Démarrage rapide"), systemImage: "hare.fill")
                }
            } footer: {
                Text(tr("Les jeux PS2 démarrent sans le logo ni le son de la console. Désactive-le si un jeu refuse de démarrer."))
            }
        }
    }

#if PLAYTENDO_VITA
    /// PS Vita : ce que la mémoire de la console contient, les fichiers .PUP du dossier BIOS et l'import d'un nouveau
    /// (seulement si la PS Vita est dans l'app).
    @ViewBuilder private var vitaSection: some View {
        if EmulatorSession.engineInstalled(for: .vita) {
            Section {
                if vitaHasFirmware {
                    Requirement(text: tr("Firmware installé dans la console"), done: true)
                } else if vitaFiles.isEmpty {
                    Requirement(text: tr("Firmware manquant : importe PSVUPDAT.PUP"), done: false)
                } else {
                    Requirement(text: tr("Firmware : installé au prochain jeu PS Vita"), done: nil)
                }
                if vitaHasFonts {
                    Requirement(text: tr("Polices installées dans la console"), done: true)
                } else {
                    Requirement(text: tr("Polices absentes (facultatives : certains textes peuvent manquer)"), done: nil)
                }
                ForEach(vitaFiles) { file in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.fileName)
                                .font(.subheadline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text([file.version.map { tr("Version \($0)") } ?? tr("Version inconnue"), vitaStatus(of: file)]
                                    .joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(file.installed ? Neon.cyan : Neon.dim)
                        }
                    } icon: {
                        Image(systemName: file.installed ? "checkmark.circle.fill" : "doc")
                            .foregroundStyle(file.installed ? Color.green : Neon.dim)
                    }
                }
                Button {
                    importKind = .vitaFirmware
                    importingBIOS = true
                } label: {
                    if vitaBusy {
                        Label(tr("Import…"), systemImage: "hourglass")
                    } else {
                        Label(tr("Importer un fichier .PUP…"), systemImage: "square.and.arrow.down")
                    }
                }
                .disabled(vitaBusy)
            } header: {
                Text("PS Vita")
            } footer: {
                Text(tr("PSVUPDAT.PUP (le firmware, obligatoire) et PSP2UPDAT.PUP (les polices, conseillées) sont les mises à jour officielles de la console. PlayTendo vérifie le fichier, le range dans le dossier BIOS et l'installe au lancement d'un jeu PS Vita. PlayTendo n'en fournit aucun."))
            }
        }
    }

    /// « installé », « au prochain jeu PS Vita », ou « pas nécessaire » si la console a déjà firmware et polices.
    private func vitaStatus(of file: VitaFirmware.Info) -> String {
        if file.installed { return tr("installé") }
        return vitaHasFirmware && vitaHasFonts ? tr("pas nécessaire") : tr("au prochain jeu PS Vita")
    }
#endif

    /// Pendant la partie : affichage des performances, vibrations de la manette (et Rumble Pak de la N64). Le retour en
    /// arrière est dans le menu pause seulement (toujours là, sur les consoles qui savent reculer).
    private var playSection: some View {
        Section {
            Toggle(isOn: $showPerformance) {
                Label(tr("Afficher les performances"), systemImage: "gauge.with.dots.needle.33percent")
            }
            Toggle(isOn: $rumbleEnabled) {
                Label(tr("Vibrations de la manette"), systemImage: "water.waves")
            }
            Toggle(isOn: $n64RumblePak) {
                Label(tr("N64 : Rumble Pak au lieu du Controller Pak"), systemImage: "gamecontroller")
            }
            .disabled(!rumbleEnabled)
        } footer: {
#if os(iOS)
            Text(tr("Performances : images par seconde et vitesse du jeu, processeur et mémoire utilisés, batterie et chaleur de l'appareil (iOS ne donne ni la carte graphique ni la température en degrés)."))
            Text(tr("Vibrations : N64 (avec le Rumble Pak, qui prend la place du Controller Pak où certains jeux sauvegardent ; pris au prochain lancement), PS1, PS2, GameCube, Wii, et cartouches Game Boy et GBA à vibreur. Avec une manette qui sait vibrer (PlayStation, Xbox récentes)."))
#else
            Text(tr("Performances : images par seconde et vitesse du jeu, processeur, carte graphique et mémoire utilisés, et chaleur du Mac."))
            Text(tr("Vibrations : N64 (avec le Rumble Pak, qui prend la place du Controller Pak où certains jeux sauvegardent ; pris au prochain lancement), PS1, PS2, GameCube, Wii, et cartouches Game Boy et GBA à vibreur. Avec une manette qui sait vibrer (PlayStation, Xbox récentes)."))
#endif
        }
    }

    /// DS : jeu en ligne par des serveurs qui remplacent la Connexion Wi-Fi Nintendo (seulement si la DS est dans l'app).
    @ViewBuilder private var dsOnlineSection: some View {
        if EmulatorSession.engineInstalled(for: .nds) {
            Section {
                Picker(selection: $dsWiFiServer) {
                    ForEach(DSSettings.WiFiServer.allCases) { server in
                        Text(server.label).tag(server.rawValue)
                    }
                } label: {
                    Label(tr("Serveur"), systemImage: "wifi")
                }
            } header: {
                Text(tr("Nintendo DS en ligne"))
            } footer: {
                Text(tr("Échanges et combats Pokémon, Mario Kart DS… La Connexion Wi-Fi Nintendo a fermé en 2014 : des serveurs de passionnés la remplacent. Dans le jeu, va dans « Connexion Wi-Fi Nintendo » et connecte-toi comme sur une vraie DS. Kaeru WFC marche avec les Pokémon ; si un jeu ne se connecte pas (erreur 20100…), essaie un autre serveur. Pris en compte au prochain jeu lancé."))
            }
        }
    }

    private var bootSection: some View {
        Section {
            Toggle(tr("Son au démarrage"), isOn: $bootSound)
        } header: {
            Text(tr("Démarrage"))
        } footer: {
#if os(iOS)
            Text(tr("Joué avec l'animation d'ouverture de PlayTendo. Muet en mode silencieux, comme le son des jeux."))
#else
            Text(tr("Joué avec l'animation d'ouverture de PlayTendo."))
#endif
        }
    }

    private func refreshChecks() {
        stikDebugInstalled = jit.isStikDebugInstalled
        vpnConnected = JITManager.isLocalDevVPNConnected
        refreshBIOS()
    }

    private func refreshBIOS() {
        biosList = PS2BIOS.installed()
        biosInUse = PS2BIOS.inUse(among: biosList)
#if PLAYTENDO_VITA
        vitaFiles = VitaFirmware.files()
        vitaHasFirmware = VitaFirmware.hasFirmware
        vitaHasFonts = VitaFirmware.hasFonts
#endif
    }

    /// Vérifie et range le fichier choisi (hors du fil principal : une archive peut prendre un moment), puis le dit.
    private func importBIOS(_ url: URL) {
        biosBusy = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { PS2BIOS.importFile(url) }.value
            biosBusy = false
            refreshBIOS()
            switch result {
            case .added(let info):
                var text = tr("« \(info.fileName) » (\(info.summary ?? tr("version inconnue"))) est rangé dans le dossier BIOS.")
                if let used = biosInUse, used.fileName != info.fileName {
                    text += tr(" La PS2 garde pour l'instant « \(used.fileName) ».")
                }
                biosAlert = (tr("BIOS PS2 ajouté"), text)
            case .alreadyThere(let name):
                biosAlert = (tr("Déjà là"), tr("Ce BIOS est déjà dans le dossier BIOS (« \(name) »). Rien n'a été ajouté."))
            case .notBIOS:
                biosAlert = (tr("Ce n'est pas un BIOS PS2"),
                             tr("Un BIOS PS2 est un fichier de 4 Mo (8 Mo pour certains modèles) copié depuis ta console. Rien n'a été ajouté."))
            case .failed(let message):
                biosAlert = (tr("Import impossible"), message)
            }
        }
    }

#if PLAYTENDO_VITA
    /// Vérifie et range le .PUP choisi (hors du fil principal : plus de 100 Mo à copier), puis le dit.
    private func importVitaFirmware(_ url: URL) {
        vitaBusy = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { VitaFirmware.importFile(url) }.value
            vitaBusy = false
            refreshBIOS()
            switch result {
            case .added(let info):
                let version = info.version ?? tr("version inconnue")
                biosAlert = (tr("Fichier .PUP ajouté"),
                             vitaHasFirmware && vitaHasFonts
                                ? tr("« \(info.fileName) » (\(version)) est rangé dans le dossier BIOS. La console a déjà son firmware et ses polices : il ne sera pas installé.")
                                : tr("« \(info.fileName) » (\(version)) est rangé dans le dossier BIOS. Il s'installera au prochain lancement d'un jeu PS Vita."))
            case .alreadyThere(let name):
                biosAlert = (tr("Déjà là"), tr("Ce fichier est déjà dans le dossier BIOS (« \(name) »). Rien n'a été ajouté."))
            case .notPUP:
                biosAlert = (tr("Ce n'est pas un fichier .PUP"),
                             tr("Un fichier .PUP est une mise à jour officielle de la PS Vita (PSVUPDAT.PUP, PSP2UPDAT.PUP). Rien n'a été ajouté."))
            case .failed(let message):
                biosAlert = (tr("Import impossible"), message)
            }
        }
    }
#endif

    private var isActivating: Bool {
        if case .activating = jit.status { true } else { false }
    }

    private var statusTitle: String {
        if jit.isActive { return tr("Actif") }
        switch jit.status {
        case .activating: return tr("Activation…")
        case .failed: return tr("Échec de l'activation")
        default: return jit.method == .off ? tr("Désactivé") : tr("Inactif")
        }
    }

    private var statusDetail: String? {
        if jit.isActive { return tr("Les jeux PSP, PS Vita, PS2, GameCube, Wii et 3DS lancés maintenant en profitent.") }
        switch jit.status {
        case .activating(let step): return step
        case .failed(let message): return message
        default: return jit.method == .off ? tr("Les jeux PSP, PS Vita, PS2, GameCube, Wii et 3DS utilisent l'interpréteur.") : tr("S'activera au prochain de ces jeux.")
        }
    }

    private var statusIcon: String {
        if jit.isActive { return "bolt.fill" }
        if case .failed = jit.status { return "exclamationmark.triangle.fill" }
        return "bolt.slash"
    }

    private var statusColor: Color {
        if jit.isActive { return Neon.cyan }
        if case .failed = jit.status { return Neon.magenta }
        return Neon.dim
    }
}

/// Ligne de la liste « Ce qu'il faut » (coche verte, croix, ou simple puce quand l'app ne peut pas vérifier).
private struct Requirement: View {
    let text: String
    let done: Bool?

    var body: some View {
        Label {
            Text(text).font(.subheadline)
        } icon: {
            switch done {
            case true?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case false?: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case nil: Image(systemName: "circle").foregroundStyle(Neon.dim)
            }
        }
    }
}

/// Jeu en attente du JIT, et la raison de l'échec.
struct JITFailure {
    let game: Game
    let message: String
}

/// Panneau affiché pendant l'activation du JIT, avant le lancement d'un jeu PSP, PS2, GameCube, Wii ou 3DS.
struct JITActivationView: View {
    let status: JITManager.Status
    let onSkip: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Neon.cyan)
                    .neonGlow(Neon.cyan, radius: 12)
                Text(tr("MODE TURBO"))
                    .font(.display(18, weight: 900))
                    .tracking(3)
                    .foregroundStyle(Neon.text)
                HStack(spacing: 10) {
                    ProgressView().tint(Neon.cyan)
                    Text(stepText)
                        .font(Neon.mono(13, weight: .semibold))
                        .foregroundStyle(Neon.dim)
                }
                Button(action: onSkip) {
                    Text(tr("JOUER SANS JIT"))
                        .font(.display(12, weight: 800))
                        .tracking(1.5)
                        .foregroundStyle(Neon.magenta)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .overlay(Chamfer(cut: 8).stroke(Neon.magenta.opacity(0.7), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .padding(28)
            .background(Chamfer(cut: 18).fill(Neon.panel))
            .overlay(Chamfer(cut: 18).stroke(LinearGradient(colors: [Neon.cyan, Neon.magenta],
                                                            startPoint: .topLeading, endPoint: .bottomTrailing),
                                             lineWidth: 1.5))
            .neonGlow(Neon.cyan, radius: 10)
            .padding(32)
        }
    }

    private var stepText: String {
        if case .activating(let step) = status { return step }
        return tr("Activation…")
    }
}
