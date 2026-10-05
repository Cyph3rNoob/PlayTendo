import UIKit

enum ControlElement: Hashable {
    case dpad
    case face(PTButton)
    case shoulder(PTButton)
    case small(PTButton)
    case menu
}

struct PlacedControl {
    let element: ControlElement
    let frame: CGRect
    let label: String
}

/// Un écran affiché : où le dessiner, et quelle partie de l'image du jeu il montre (de 0 à 1).
struct ScreenPlacement: Equatable {
    var frame: CGRect
    var source: CGRect
    var isTouch: Bool
}

/// Taille de l'écran tactile de la DS en paysage.
enum DSTouchSize: String, CaseIterable {
    case small, medium, large

    var label: String {
        switch self {
        case .small: "Petit"
        case .medium: "Moyen"
        case .large: "Grand"
        }
    }

    /// Part de la largeur disponible donnée à l'écran tactile.
    var fraction: CGFloat {
        switch self {
        case .small: 0.25
        case .medium: 0.4
        case .large: 0.5
        }
    }

    var next: DSTouchSize {
        switch self {
        case .small: .medium
        case .medium: .large
        case .large: .small
        }
    }
}

/// Réglages d'affichage des consoles à deux écrans (DS).
struct DualScreenOptions: Equatable {
    var swapped = false
    var touchSize: DSTouchSize = .medium
}

/// Calcule la position des écrans du jeu et des boutons tactiles selon l'écran de l'iPhone.
struct ControlLayout: Equatable {
    /// Zone englobant le ou les écrans du jeu.
    var gameRect: CGRect = .zero
    var screens: [ScreenPlacement] = []
    var controls: [PlacedControl] = []
    var faceRadius: CGFloat = 30

    /// L'écran tactile (DS), s'il y en a un.
    var touchScreen: ScreenPlacement? { screens.first(where: \.isTouch) }

    static let fullImage = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// La DS est rendue avec ses deux écrans l'un au-dessus de l'autre ; chaque moitié est
    /// ensuite affichée où l'on veut.
    static let topScreen = CGRect(x: 0, y: 0, width: 1, height: 0.5)
    static let bottomScreen = CGRect(x: 0, y: 0.5, width: 1, height: 0.5)

    static func == (lhs: ControlLayout, rhs: ControlLayout) -> Bool {
        lhs.gameRect == rhs.gameRect && lhs.screens == rhs.screens
            && lhs.controls.map(\.frame) == rhs.controls.map(\.frame)
    }

    static func make(scheme: ControlScheme, aspect: CGFloat, bounds: CGRect, safe: UIEdgeInsets,
                     gamepad: Bool, dual: DualScreenOptions = DualScreenOptions()) -> ControlLayout {
        let usable = bounds.inset(by: safe)
        guard usable.width > 0, usable.height > 0, aspect > 0 else { return ControlLayout() }
        var layout = ControlLayout()
        let portrait = bounds.height >= bounds.width
        let menuSize: CGFloat = 38
        let dualScreen = scheme.usesTouchScreen

        let shoulderSize = CGSize(width: scheme.hasSecondShoulders ? 70 : 92, height: 38)
        let smallSize = CGSize(width: 78, height: 30)
        var cluster: CGFloat
        var dpadCenter: CGPoint
        var faceCenter: CGPoint

        if portrait {
            if dualScreen {
                layout.placeDualScreens(in: usable, portrait: true, maxStackHeight: usable.height * 0.70,
                                        centered: false, dual: dual)
            } else {
                var width = usable.width
                var height = width / aspect
                let maxHeight = usable.height * 0.55
                if height > maxHeight {
                    height = maxHeight
                    width = height * aspect
                }
                layout.gameRect = CGRect(x: usable.midX - width / 2, y: usable.minY, width: width, height: height)
            }

            let area = CGRect(x: usable.minX, y: layout.gameRect.maxY, width: usable.width,
                              height: usable.maxY - layout.gameRect.maxY)
            let topRow = area.minY + 12
            let bottomRow = area.maxY - 6 - smallSize.height
            let middleTop = topRow + (scheme.hasShoulders ? shoulderSize.height + 6 : menuSize + 2)
            let middleBottom = bottomRow - 6
            cluster = max(96, min(172, middleBottom - middleTop, area.width * 0.43))
            let centerY = (middleTop + middleBottom) / 2
            dpadCenter = CGPoint(x: area.minX + 14 + cluster / 2, y: centerY)
            faceCenter = CGPoint(x: area.maxX - 14 - cluster / 2, y: centerY)

            layout.controls.append(PlacedControl(element: .menu,
                                                 frame: CGRect(x: area.midX - menuSize / 2, y: topRow,
                                                               width: menuSize, height: menuSize), label: ""))
            layout.addShoulders(scheme: scheme, size: shoulderSize, top: topRow,
                                left: area.minX + 14, right: area.maxX - 14, stacked: false)
            layout.controls.append(PlacedControl(element: .small(.select),
                                                 frame: CGRect(x: area.midX - 8 - smallSize.width, y: bottomRow,
                                                               width: smallSize.width, height: smallSize.height),
                                                 label: "SELECT"))
            layout.controls.append(PlacedControl(element: .small(.start),
                                                 frame: CGRect(x: area.midX + 8, y: bottomRow,
                                                               width: smallSize.width, height: smallSize.height),
                                                 label: "START"))
        } else {
            cluster = max(110, min(dualScreen ? 150 : 168, usable.height * 0.42))
            if dualScreen {
                // Les boutons ne doivent jamais recouvrir l'écran tactile : on garde de chaque
                // côté la place d'un bloc de boutons entier.
                let panel = cluster + 16
                let middle = CGRect(x: usable.minX + panel, y: usable.minY,
                                    width: max(0, usable.width - 2 * panel), height: usable.height)
                layout.placeDualScreens(in: middle, portrait: false, maxStackHeight: 0, centered: true, dual: dual)
            } else {
                var height = usable.height
                var width = height * aspect
                let maxWidth = bounds.width - 2 * 150
                if width > maxWidth {
                    width = maxWidth
                    height = width / aspect
                }
                layout.gameRect = CGRect(x: bounds.midX - width / 2, y: usable.midY - height / 2,
                                         width: width, height: height)
            }

            let leftPanel = CGRect(x: usable.minX, y: usable.minY, width: max(0, layout.gameRect.minX - usable.minX),
                                   height: usable.height)
            let rightPanel = CGRect(x: layout.gameRect.maxX, y: usable.minY,
                                    width: max(0, usable.maxX - layout.gameRect.maxX), height: usable.height)
            let centerY = usable.minY + usable.height * 0.6
            dpadCenter = CGPoint(x: max(leftPanel.midX, usable.minX + cluster / 2 + 6), y: centerY)
            faceCenter = CGPoint(x: min(rightPanel.midX, usable.maxX - cluster / 2 - 6), y: centerY)

            layout.addShoulders(scheme: scheme, size: shoulderSize, top: usable.minY + 10,
                                left: usable.minX + 6, right: usable.maxX - 6, stacked: true)
            let smallY = usable.maxY - smallSize.height - 6
            layout.controls.append(PlacedControl(element: .small(.select),
                                                 frame: CGRect(x: dpadCenter.x - smallSize.width / 2, y: smallY,
                                                               width: smallSize.width, height: smallSize.height),
                                                 label: "SELECT"))
            layout.controls.append(PlacedControl(element: .small(.start),
                                                 frame: CGRect(x: faceCenter.x - smallSize.width / 2, y: smallY,
                                                               width: smallSize.width, height: smallSize.height),
                                                 label: "START"))
            layout.controls.append(PlacedControl(element: .menu,
                                                 frame: CGRect(x: bounds.midX - menuSize / 2, y: usable.maxY - menuSize - 4,
                                                               width: menuSize, height: menuSize), label: ""))
        }

        if layout.screens.isEmpty {
            layout.screens = [ScreenPlacement(frame: layout.gameRect, source: fullImage, isTouch: false)]
        }
        layout.controls.append(PlacedControl(element: .dpad,
                                             frame: CGRect(x: dpadCenter.x - cluster / 2, y: dpadCenter.y - cluster / 2,
                                                           width: cluster, height: cluster), label: ""))
        layout.addFaceButtons(scheme: scheme, center: faceCenter, size: cluster)
        if gamepad {
            // Manette utilisée : seuls les boutons tactiles disparaissent. L'image du jeu garde
            // exactement la même place, pour ne pas sauter quand les boutons reviennent.
            layout.controls = layout.controls.filter { $0.element == .menu }
        }
        return layout
    }

    /// DS : place les deux écrans (4:3 chacun) dans `area`. En portrait ils sont empilés ;
    /// en paysage, l'écran principal est à gauche et l'autre à droite, à la taille choisie.
    private mutating func placeDualScreens(in area: CGRect, portrait: Bool, maxStackHeight: CGFloat,
                                           centered: Bool, dual: DualScreenOptions) {
        let mainSource = dual.swapped ? Self.bottomScreen : Self.topScreen
        let otherSource = dual.swapped ? Self.topScreen : Self.bottomScreen
        let first: CGRect
        let second: CGRect
        if portrait {
            var width = area.width
            var height = width * 0.75
            if height * 2 > maxStackHeight {
                height = maxStackHeight / 2
                width = height / 0.75
            }
            let top = centered ? area.midY - height : area.minY
            first = CGRect(x: area.midX - width / 2, y: top, width: width, height: height)
            second = first.offsetBy(dx: 0, dy: height)
        } else {
            let gap: CGFloat = 8
            let available = max(0, area.width - gap)
            var mainWidth = available * (1 - dual.touchSize.fraction)
            var otherWidth = available * dual.touchSize.fraction
            if mainWidth * 0.75 > area.height {
                let shrink = area.height / (mainWidth * 0.75)
                mainWidth *= shrink
                otherWidth *= shrink
            }
            let left = area.midX - (mainWidth + gap + otherWidth) / 2
            first = CGRect(x: left, y: area.midY - mainWidth * 0.375, width: mainWidth, height: mainWidth * 0.75)
            second = CGRect(x: first.maxX + gap, y: area.midY - otherWidth * 0.375,
                            width: otherWidth, height: otherWidth * 0.75)
        }
        screens = [ScreenPlacement(frame: first, source: mainSource, isTouch: mainSource == Self.bottomScreen),
                   ScreenPlacement(frame: second, source: otherSource, isTouch: otherSource == Self.bottomScreen)]
        gameRect = first.union(second)
    }

    private mutating func addShoulders(scheme: ControlScheme, size: CGSize, top: CGFloat,
                                       left: CGFloat, right: CGFloat, stacked: Bool) {
        guard scheme.hasShoulders else { return }
        let ps = scheme.hasSecondShoulders
        controls.append(PlacedControl(element: .shoulder(.l),
                                      frame: CGRect(x: left, y: top, width: size.width, height: size.height),
                                      label: ps ? "L1" : "L"))
        controls.append(PlacedControl(element: .shoulder(.r),
                                      frame: CGRect(x: right - size.width, y: top, width: size.width, height: size.height),
                                      label: ps ? "R1" : "R"))
        guard ps else { return }
        let second: (CGFloat, CGFloat, CGFloat) = stacked
            ? (left, right - size.width, top + size.height + 8)
            : (left + size.width + 8, right - 2 * size.width - 8, top)
        controls.append(PlacedControl(element: .shoulder(.l2),
                                      frame: CGRect(x: second.0, y: second.2, width: size.width, height: size.height),
                                      label: "L2"))
        controls.append(PlacedControl(element: .shoulder(.r2),
                                      frame: CGRect(x: second.1, y: second.2, width: size.width, height: size.height),
                                      label: "R2"))
    }

    private mutating func addFaceButtons(scheme: ControlScheme, center: CGPoint, size: CGFloat) {
        func place(_ button: PTButton, _ dx: CGFloat, _ dy: CGFloat, _ radius: CGFloat, _ label: String) {
            controls.append(PlacedControl(element: .face(button),
                                          frame: CGRect(x: center.x + dx * size - radius, y: center.y + dy * size - radius,
                                                        width: radius * 2, height: radius * 2),
                                          label: label))
        }
        if scheme.hasFourFaceButtons {
            let radius = size * 0.19
            faceRadius = radius
            let ps = scheme == .playStation
            place(.x, 0, -0.30, radius, ps ? "△" : "X")
            place(.a, 0.30, 0, radius, ps ? "○" : "A")
            place(.b, 0, 0.30, radius, ps ? "✕" : "B")
            place(.y, -0.30, 0, radius, ps ? "□" : "Y")
        } else {
            let radius = size * 0.21
            faceRadius = radius
            place(.b, -0.21, 0.11, radius, "B")
            place(.a, 0.21, -0.11, radius, "A")
        }
    }
}
