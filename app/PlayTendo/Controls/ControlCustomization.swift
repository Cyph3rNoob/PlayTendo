import Foundation
import CoreGraphics

/// Boutons sur mesure (iPhone, iPad ; menu pause › Commandes › Modifier les boutons) : déplacement et taille de chaque
/// bloc de boutons, et transparence, pour une console et une orientation. Les déplacements sont en part de l'écran :
/// ils suivent un changement de taille de fenêtre (iPad).
struct ControlCustomization: Codable, Equatable {
    struct Adjustment: Codable, Equatable {
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        var scale: CGFloat = 1
    }

    var groups: [String: Adjustment] = [:]
    /// Opacité des boutons (1 : comme d'habitude).
    var opacity: Double = 1

    static let scaleRange: ClosedRange<CGFloat> = 0.5...1.7
    static let opacityRange: ClosedRange<Double> = 0.15...1

    /// Bloc d'un bouton : ses boutons sont déplacés et agrandis ensemble. Le bouton menu ne bouge pas (il doit
    /// toujours se retrouver).
    static func group(of element: ControlElement) -> String? {
        switch element {
        case .dpad: "dpad"
        case .stick: "stick"
        case .rightStick: "rightStick"
        case .face, .cButton: "face"
        case .shoulder(let button): "shoulder\(button.rawValue)"
        case .small(let button): "small\(button.rawValue)"
        case .menu: nil
        }
    }

    // MARK: Réglages gardés

    /// Une clé par console (Wii : par manette choisie) et par orientation.
    static func key(system: GameSystem, variant: String?, landscape: Bool) -> String {
        "boutonsSurMesure.\(system.rawValue)\(variant.map { ".\($0)" } ?? "").\(landscape ? "paysage" : "portrait")"
    }

    static func load(key: String) -> ControlCustomization {
        guard let data = UserDefaults.standard.data(forKey: key),
              let custom = try? JSONDecoder().decode(ControlCustomization.self, from: data) else { return ControlCustomization() }
        return custom
    }

    static func save(_ custom: ControlCustomization, key: String) {
        if custom == ControlCustomization() {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(custom) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

extension ControlLayout {
    /// Blocs de boutons (pour le mode édition) : nom, cadre englobant, et ce qu'on y lit.
    func controlGroups() -> [(name: String, frame: CGRect, title: String)] {
        var order: [String] = []
        var frames: [String: CGRect] = [:]
        var titles: [String: String] = [:]
        for control in controls {
            guard let group = ControlCustomization.group(of: control.element) else { continue }
            if frames[group] == nil {
                order.append(group)
                frames[group] = control.frame
            } else {
                frames[group] = frames[group]!.union(control.frame)
            }
            if titles[group] == nil {
                titles[group] = switch control.element {
                case .dpad: tr("Croix")
                case .stick: tr("Stick")
                case .rightStick: tr("Stick droit")
                case .face, .cButton: tr("Boutons")
                default: control.label
                }
            }
        }
        return order.map { ($0, frames[$0]!, titles[$0] ?? "") }
    }

    /// Boutons sur mesure : chaque bloc déplacé et agrandi autour de son centre, gardé dans l'écran.
    mutating func apply(_ custom: ControlCustomization, bounds: CGRect) {
        var indices: [String: [Int]] = [:]
        for (index, control) in controls.enumerated() {
            if let group = ControlCustomization.group(of: control.element) { indices[group, default: []].append(index) }
        }
        for (group, members) in indices {
            guard let adjustment = custom.groups[group], adjustment != ControlCustomization.Adjustment() else { continue }
            let union = members.map { controls[$0].frame }.reduce(CGRect.null) { $0.union($1) }
            let scale = min(max(adjustment.scale, ControlCustomization.scaleRange.lowerBound),
                            ControlCustomization.scaleRange.upperBound)
            let size = CGSize(width: union.width * scale, height: union.height * scale)
            let center = CGPoint(
                x: min(max(union.midX + adjustment.dx * bounds.width, bounds.minX + size.width / 2), bounds.maxX - size.width / 2),
                y: min(max(union.midY + adjustment.dy * bounds.height, bounds.minY + size.height / 2), bounds.maxY - size.height / 2))
            for index in members {
                let frame = controls[index].frame
                controls[index] = PlacedControl(element: controls[index].element,
                                                frame: CGRect(x: center.x + (frame.minX - union.midX) * scale,
                                                              y: center.y + (frame.minY - union.midY) * scale,
                                                              width: frame.width * scale, height: frame.height * scale),
                                                label: controls[index].label)
            }
        }
    }
}
