// PS Vita : compilé seulement avec PLAYTENDO_VITA (par défaut dans scripts/build_app.sh).
#if PLAYTENDO_VITA
import Foundation

/// Firmware de la PS Vita (Réglages › PS Vita) : les fichiers .PUP du dossier BIOS avec leur version, ce que la mémoire
/// de la console contient déjà, et l'import d'un nouveau .PUP dans BIOS. L'installation se fait au lancement d'un jeu
/// PS Vita (`EmulatorSession.prepareVita`), comme pour un .PUP copié à la main.
enum VitaFirmware {
    struct Info: Identifiable, Equatable, Sendable {
        let url: URL
        /// « 3.74 », ou nil si l'en-tête ne la donne pas.
        let version: String?
        /// Déjà installé dans la mémoire de la console (`VitaGame.wasInstalled`).
        let installed: Bool

        var id: String { url.lastPathComponent }
        var fileName: String { url.lastPathComponent }
    }

    enum ImportResult: Sendable {
        case added(Info)
        /// Le même fichier (même contenu) est déjà dans BIOS, sous ce nom.
        case alreadyThere(String)
        case notPUP
        case failed(String)
    }

    /// Fichiers .PUP du dossier BIOS, dans l'ordre où ils sont installés (le firmware PSVUPDAT.PUP d'abord).
    static func files() -> [Info] {
        VitaGame.firmwareFiles().map { Info(url: $0, version: version(of: $0), installed: VitaGame.wasInstalled($0)) }
    }

    /// Version de la console écrite dans l'en-tête du .PUP : octets 0x10 à 0x13, en BCD (03 74 → « 3.74 ») ; Vita3K
    /// la lit au même endroit (pup.cpp).
    static func version(of url: URL) -> String? {
        guard let data = GameIdentifier.read(url, offset: 0x10, count: 4), data.count == 4 else { return nil }
        let major = data[data.startIndex + 3], minor = data[data.startIndex + 2]
        guard major > 0 else { return nil }
        return String(format: "%X.%02X", major, minor)
    }

    /// Firmware déjà dans la mémoire de la console (dossier vs0 non vide, comme Vita3K : app.cpp get_firmware_state), et
    /// installation pas coupée en route.
    static var hasFirmware: Bool { hasContent("vs0") && !installWasInterrupted }
    /// Polices déjà dans la mémoire de la console (dossier sa0 non vide).
    static var hasFonts: Bool { hasContent("sa0") && !installWasInterrupted }

    /// Vita3K installe un .PUP directement dans la mémoire de la console (vs0 en dernier) : coupée en route (app
    /// fermée), la console se croirait à jour avec un firmware incomplet. Ce fichier est posé avant l'installation et
    /// retiré une fois le firmware en place ; tant qu'il est là, firmware et polices sont réinstallés au prochain jeu
    /// (EmulatorSession.prepareVita, audit du 2026-10-20).
    private static var installMarker: URL { Paths.vitaEngine.appendingPathComponent("installation-firmware-en-cours") }

    static var installWasInterrupted: Bool { FileManager.default.fileExists(atPath: installMarker.path) }

    static func setInstallInProgress(_ inProgress: Bool) {
        if inProgress {
            try? FileManager.default.createDirectory(at: Paths.vitaEngine, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: installMarker.path, contents: nil)
        } else {
            try? FileManager.default.removeItem(at: installMarker)
        }
    }

    private static func hasContent(_ name: String) -> Bool {
        let folder = Paths.vitaEngine.appendingPathComponent("vita/\(name)", isDirectory: true)
        return !((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty
    }

    // MARK: Import

    /// Range dans BIOS le .PUP choisi par l'utilisateur (nom gardé). Rien n'est copié si ce n'en est pas un ou s'il est
    /// déjà là.
    static func importFile(_ url: URL) -> ImportResult {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard VitaGame.isFirmware(url) else { return .notPUP }
        for existing in VitaGame.firmwareFiles() where sameContent(existing, url) {
            return .alreadyThere(existing.lastPathComponent)
        }
        // Extension .PUP ajoutée si besoin : le moteur ne regarde que ces fichiers.
        var name = url.lastPathComponent
        if (name as NSString).pathExtension.lowercased() != "pup" { name += ".PUP" }
        let target = uniqueURL(for: name)
        do {
            try FileManager.default.createDirectory(at: Paths.bios, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: target)
        } catch {
            try? FileManager.default.removeItem(at: target)
            return .failed(error.localizedDescription)
        }
        let info = Info(url: target, version: version(of: target), installed: false)
        PTLogLine("Vita : \(info.fileName) importé dans BIOS (version \(info.version ?? "inconnue"))")
        return .added(info)
    }

    /// Même taille puis même contenu, lu par morceaux de 4 Mo (un .PUP fait plus de 100 Mo).
    private static func sameContent(_ lhs: URL, _ rhs: URL) -> Bool {
        let size = { (url: URL) in (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1 }
        guard size(lhs) == size(rhs), size(lhs) > 0,
              let first = try? FileHandle(forReadingFrom: lhs), let second = try? FileHandle(forReadingFrom: rhs)
        else { return false }
        defer {
            try? first.close()
            try? second.close()
        }
        while true {
            let a = (try? first.read(upToCount: 4 << 20)) ?? nil
            let b = (try? second.read(upToCount: 4 << 20)) ?? nil
            if a != b { return false }
            if a == nil || a?.isEmpty == true { return true }
        }
    }

    /// « nom.PUP », ou « nom 2.PUP »… si un autre fichier porte déjà ce nom.
    private static func uniqueURL(for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var url = Paths.bios.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = Paths.bios.appendingPathComponent("\(base) \(number).\(ext)")
            number += 1
        }
        return url
    }
}
#endif
