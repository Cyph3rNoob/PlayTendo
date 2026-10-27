import Foundation
import SwiftUI

/// Langue de l'interface (Réglages › Apparence) : français ou anglais. « Automatique » suit les langues de l'iPhone (ou
/// celle choisie pour PlayTendo dans les réglages d'iOS) : français s'il passe avant l'anglais, anglais sinon, et pour
/// toute autre langue. Le Journal reste en français.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case automatic = "auto"
    case french = "fr"
    case english = "en"

    var id: String { rawValue }

    static let key = "langue"

    /// Nom dans le choix des Réglages (chaque langue écrite dans sa propre langue).
    var label: String {
        switch self {
        case .automatic: tr("Automatique")
        case .french: "Français"
        case .english: "English"
        }
    }

    /// Choix enregistré.
    static var choice: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .automatic
    }

    /// Vrai si l'interface est affichée en anglais (choix relu à chaque fois : un changement s'applique tout de suite).
    static var isEnglish: Bool {
        switch choice {
        case .automatic: systemPrefersEnglish
        case .french: false
        case .english: true
        }
    }

    /// Langues de l'iPhone (ou celle choisie pour PlayTendo dans les réglages d'iOS, qui relancent alors l'app).
    private static let systemPrefersEnglish: Bool = {
        for language in Locale.preferredLanguages {
            if language.hasPrefix("fr") { return false }
            if language.hasPrefix("en") { return true }
        }
        return true
    }()

    /// Pour les dates et les tailles de fichiers.
    static var locale: Locale { Locale(identifier: isEnglish ? "en_US" : "fr_FR") }

    /// Taille de fichier dans la langue de l'interface (« 1,2 Go » / « 1.2 GB »).
    static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file).locale(locale))
    }
}

extension Text {
    /// Texte traduit qui contient du Markdown (**gras**, [lien](https://…)) : `Text(markdown: tr("…"))`.
    init(markdown text: String) {
        self.init(LocalizedStringKey(text))
    }
}

/// Texte de l'interface, écrit en français dans le code : `tr("Réglages")`, `tr("\(n) jeux")`. En anglais, la traduction
/// est cherchée dans `English.table` sous le texte français où chaque valeur insérée est remplacée par %@
/// (« %@ jeux ») ; la traduction remet les valeurs à leur place (%@ dans l'ordre, ou %1$@, %2$@… pour un autre ordre).
func tr(_ text: Tr) -> String {
    text.resolved
}

/// Message venu du code Objective-C (moteurs, archives, JIT) : phrase fixe, ou « début : détail » dont le début est
/// dans la table sous « début : %@ ». Gardé tel quel s'il est inconnu (les moteurs écrivent souvent en anglais).
func trMessage(_ french: String) -> String {
    guard AppLanguage.isEnglish else { return french }
    if let english = English.table[french] { return english }
    if let separator = french.range(of: " : "),
       let template = English.table[french[..<separator.lowerBound] + " : %@"] {
        return Tr.fill(template, with: [trMessage(String(french[separator.upperBound...]))])
    }
    return french
}

struct Tr: ExpressibleByStringInterpolation, Sendable {
    let key: String
    let values: [String]

    init(stringLiteral value: String) {
        key = value
        values = []
    }

    init(stringInterpolation: Interpolation) {
        key = stringInterpolation.key
        values = stringInterpolation.values
    }

    struct Interpolation: StringInterpolationProtocol {
        var key = ""
        var values: [String] = []

        init(literalCapacity: Int, interpolationCount: Int) {}

        mutating func appendLiteral(_ literal: String) {
            key += literal
        }

        mutating func appendInterpolation<Value>(_ value: Value) {
            key += "%@"
            values.append(String(describing: value))
        }
    }

    var resolved: String {
        let template = AppLanguage.isEnglish ? (English.table[key] ?? Self.missing(key)) : key
        return values.isEmpty ? template : Self.fill(template, with: values)
    }

    /// Texte sans traduction anglaise : gardé en français (noté une fois au Journal en version de test).
    static func missing(_ key: String) -> String {
#if DEBUG
        missingLock.lock()
        let first = missingKeys.insert(key).inserted
        missingLock.unlock()
        if first { PTLogLine("Traduction manquante : « \(key) »") }
#endif
        return key
    }

#if DEBUG
    nonisolated(unsafe) private static var missingKeys = Set<String>()
    private static let missingLock = NSLock()
#endif

    /// Remplace %@ (dans l'ordre) et %N$@ (la Nième valeur) ; tout autre « % » est gardé tel quel.
    static func fill(_ template: String, with values: [String]) -> String {
        var result = ""
        var next = 0
        var index = template.startIndex
        while index < template.endIndex {
            let character = template[index]
            guard character == "%" else {
                result.append(character)
                index = template.index(after: index)
                continue
            }
            let after = template[template.index(after: index)...]
            if after.hasPrefix("@") {
                result += next < values.count ? values[next] : ""
                next += 1
                index = template.index(index, offsetBy: 2)
            } else if let dollar = after.firstIndex(of: "$"), let position = Int(after[after.startIndex..<dollar]),
                      template[template.index(after: dollar)...].hasPrefix("@") {
                result += position >= 1 && position <= values.count ? values[position - 1] : ""
                index = template.index(dollar, offsetBy: 2)
            } else {
                result.append(character)
                index = template.index(after: index)
            }
        }
        return result
    }
}
