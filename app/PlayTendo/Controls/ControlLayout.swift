import UIKit

enum ControlElement: Hashable {
    case dpad
    case face(PTButton)
    case shoulder(PTButton)
    case small(PTButton)
    /// Stick analogique gauche (N64, PSP).
    case stick
    /// Bouton C jaune de la N64, transmis au moteur par le stick analogique droit.
    case cButton(CDirection)
    case menu
}

enum CDirection: CaseIterable {
    case up, down, left, right
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

    /// `controllerConnected` : une manette est branchée — en portrait, la DS garde alors ses grands écrans
    /// (en paysage, ils sont toujours grands), et les boutons tactiles se superposent aux écrans.
    /// `hideTouchControls` : la manette est en cours d'utilisation, seuls les boutons disparaissent.
    /// `fillScreen` (PSP en paysage) : l'image prend toute la hauteur de l'écran et les boutons
    /// passent par-dessus.
    static func make(scheme: ControlScheme, aspect: CGFloat, bounds: CGRect, safe: UIEdgeInsets,
                     controllerConnected: Bool, hideTouchControls: Bool,
                     dual: DualScreenOptions = DualScreenOptions(), fillScreen: Bool = false) -> ControlLayout {
        let usable = bounds.inset(by: safe)
        guard usable.width > 0, usable.height > 0, aspect > 0 else { return ControlLayout() }
        var layout = ControlLayout()
        let portrait = bounds.height >= bounds.width
        let menuSize: CGFloat = 38
        let dualScreen = scheme.usesTouchScreen

        let narrowShoulders = scheme.hasSecondShoulders || scheme.isNintendo64
        let shoulderSize = CGSize(width: narrowShoulders ? 70 : 92, height: 38)
        let smallSize = CGSize(width: 78, height: 30)
        var cluster: CGFloat
        var dpadCenter: CGPoint
        var faceCenter: CGPoint
        // Consoles à stick : deux commandes l'une sous l'autre à gauche. N64 : le stick, puis une
        // petite croix ; PSP : la croix, puis le stick.
        let analog = scheme.hasAnalogStick
        let secondaryRatio: CGFloat = scheme.isNintendo64 ? 0.55 : 0.72
        var secondaryCenter = CGPoint.zero
        var faceSize: CGFloat = 0
        var verticalFace = false

        if portrait {
            if dualScreen {
                layout.placeDualScreens(in: usable, portrait: true,
                                        maxStackHeight: usable.height * (controllerConnected ? 1 : 0.70),
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
            var centerY = (middleTop + middleBottom) / 2
            if analog {
                let gap: CGFloat = 10
                cluster = max(90, min(172, (middleBottom - middleTop - gap) / (1 + secondaryRatio), area.width * 0.43))
                let total = cluster * (1 + secondaryRatio) + gap
                centerY = (middleTop + middleBottom) / 2 - total / 2 + cluster / 2
                secondaryCenter = CGPoint(x: area.minX + 14 + cluster / 2,
                                          y: centerY + cluster / 2 + gap + cluster * secondaryRatio / 2)
            } else {
                cluster = max(96, min(172, middleBottom - middleTop, area.width * 0.43))
            }
            dpadCenter = CGPoint(x: area.minX + 14 + cluster / 2, y: centerY)
            faceCenter = CGPoint(x: area.maxX - 14 - cluster / 2, y: centerY)

            layout.controls.append(PlacedControl(element: .menu,
                                                 frame: CGRect(x: area.midX - menuSize / 2, y: topRow,
                                                               width: menuSize, height: menuSize), label: ""))
            layout.addShoulders(scheme: scheme, size: shoulderSize, top: topRow,
                                left: area.minX + 14, right: area.maxX - 14, stacked: false)
            if scheme.hasSelect {
                layout.controls.append(PlacedControl(element: .small(.select),
                                                     frame: CGRect(x: area.midX - 8 - smallSize.width, y: bottomRow,
                                                                   width: smallSize.width, height: smallSize.height),
                                                     label: "SELECT"))
            }
            layout.controls.append(PlacedControl(element: .small(.start),
                                                 frame: CGRect(x: scheme.hasSelect ? area.midX + 8 : area.midX - smallSize.width / 2,
                                                               y: bottomRow, width: smallSize.width, height: smallSize.height),
                                                 label: "START"))
        } else {
            cluster = max(110, min(dualScreen || scheme == .psp ? 150 : 168, usable.height * 0.42))
            if dualScreen {
                // Grands écrans sur toute la largeur, avec ou sans manette (choix de l'utilisateur,
                // 2026-10-06) : les boutons tactiles passent par-dessus, en semi-transparent, et un
                // bouton visible a priorité sur l'écran tactile qu'il recouvre.
                layout.placeDualScreens(in: usable, portrait: false, maxStackHeight: 0, centered: true, dual: dual)
            } else {
                var height = fillScreen ? bounds.height : usable.height
                var width = height * aspect
                // Consoles à stick : une bande d'au moins 128 points de chaque côté pour les commandes
                // (en plein écran, seulement l'encoche à éviter).
                let side = fillScreen ? max(safe.left, safe.right)
                    : analog ? max(150, max(safe.left, safe.right) + 128) : 150
                let maxWidth = bounds.width - 2 * side
                if width > maxWidth {
                    width = maxWidth
                    height = width / aspect
                }
                let centerY = fillScreen ? bounds.midY : usable.midY
                layout.gameRect = CGRect(x: bounds.midX - width / 2, y: centerY - height / 2,
                                         width: width, height: height)
            }

            let leftPanel = CGRect(x: usable.minX, y: usable.minY, width: max(0, layout.gameRect.minX - usable.minX),
                                   height: usable.height)
            let rightPanel = CGRect(x: layout.gameRect.maxX, y: usable.minY,
                                    width: max(0, usable.maxX - layout.gameRect.maxX), height: usable.height)
            var centerY = usable.minY + usable.height * 0.6
            if analog {
                // Les blocs tiennent dans la bande libre à côté de l'image, sans la recouvrir
                // (mais jamais sous 120 points, pour rester faciles à viser).
                if !fillScreen {
                    cluster = max(120, min(cluster, min(leftPanel.width, rightPanel.width) - 8))
                }
                // Sous les gâchettes de gauche (L, et Z pour la N64), au-dessus de SELECT.
                let gap: CGFloat = 8
                let leftShoulderRows: CGFloat = narrowShoulders ? 2 : 1
                let columnTop = usable.minY + 10 + leftShoulderRows * shoulderSize.height + (leftShoulderRows - 1) * 8 + 8
                let columnBottom = usable.maxY - 6 - (scheme.hasSelect ? smallSize.height + 6 : 0)
                cluster = max(90, min(cluster, (columnBottom - columnTop - gap) / (1 + secondaryRatio)))
                let total = cluster * (1 + secondaryRatio) + gap
                centerY = (columnTop + columnBottom) / 2 - total / 2 + cluster / 2
                secondaryCenter = CGPoint(x: max(leftPanel.midX, usable.minX + cluster / 2 + 6),
                                          y: centerY + cluster / 2 + gap + cluster * secondaryRatio / 2)
            }
            dpadCenter = CGPoint(x: max(leftPanel.midX, usable.minX + cluster / 2 + 6), y: centerY)
            faceCenter = CGPoint(x: min(rightPanel.midX, usable.maxX - cluster / 2 - 6), y: centerY)
            if scheme.isNintendo64 {
                // Boutons C au-dessus de A et B : ils profitent de toute la hauteur libre entre R
                // et START, et restent assez gros malgré la bande étroite.
                let top = usable.minY + 10 + shoulderSize.height + 8
                let bottom = usable.maxY - 6 - smallSize.height - 6
                faceSize = min(rightPanel.width / 0.7, (bottom - top) / 1.1, 200)
                faceCenter = CGPoint(x: min(rightPanel.midX, usable.maxX - faceSize * 0.33 - 6),
                                     y: (top + bottom) / 2 + faceSize * 0.05)
                verticalFace = true
            }

            layout.addShoulders(scheme: scheme, size: shoulderSize, top: usable.minY + 10,
                                left: usable.minX + 6, right: usable.maxX - 6, stacked: true)
            let smallY = usable.maxY - smallSize.height - 6
            if scheme.hasSelect {
                layout.controls.append(PlacedControl(element: .small(.select),
                                                     frame: CGRect(x: dpadCenter.x - smallSize.width / 2, y: smallY,
                                                                   width: smallSize.width, height: smallSize.height),
                                                     label: "SELECT"))
            }
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
        func square(_ center: CGPoint, _ size: CGFloat) -> CGRect {
            CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        }
        if analog {
            let secondarySize = cluster * secondaryRatio
            let (primary, secondary): (ControlElement, ControlElement) = scheme.isNintendo64 ? (.stick, .dpad) : (.dpad, .stick)
            layout.controls.append(PlacedControl(element: primary, frame: square(dpadCenter, cluster), label: ""))
            layout.controls.append(PlacedControl(element: secondary, frame: square(secondaryCenter, secondarySize), label: ""))
        } else {
            layout.controls.append(PlacedControl(element: .dpad, frame: square(dpadCenter, cluster), label: ""))
        }
        layout.addFaceButtons(scheme: scheme, center: faceCenter, size: faceSize > 0 ? faceSize : cluster,
                              vertical: verticalFace)
        if hideTouchControls {
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
        if scheme.isNintendo64 {
            // La gâchette Z, à côté de L (sous L en paysage). Le moteur la lit sur L2.
            let frame = stacked
                ? CGRect(x: left, y: top + size.height + 8, width: size.width, height: size.height)
                : CGRect(x: left + size.width + 8, y: top, width: size.width, height: size.height)
            controls.append(PlacedControl(element: .shoulder(.l2), frame: frame, label: "Z"))
        }
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

    /// `vertical` (N64 en paysage) : boutons C en haut, A et B en dessous.
    private mutating func addFaceButtons(scheme: ControlScheme, center: CGPoint, size: CGFloat, vertical: Bool) {
        func place(_ button: PTButton, _ dx: CGFloat, _ dy: CGFloat, _ radius: CGFloat, _ label: String) {
            controls.append(PlacedControl(element: .face(button),
                                          frame: CGRect(x: center.x + dx * size - radius, y: center.y + dy * size - radius,
                                                        width: radius * 2, height: radius * 2),
                                          label: label))
        }
        if scheme.isNintendo64 {
            // Comme sur la manette : A (gros) en bas, B à sa gauche, les quatre boutons C en losange
            // en haut à droite. Sur le RetroPad, A N64 = B et B N64 = Y.
            if vertical {
                place(.b, 0.17, 0.32, size * 0.15, "A")
                place(.y, -0.20, 0.20, size * 0.13, "B")
            } else {
                place(.b, -0.04, 0.27, size * 0.15, "A")
                place(.y, -0.30, 0.04, size * 0.13, "B")
            }
            let diamond = vertical ? CGPoint(x: center.x, y: center.y - 0.30 * size)
                                   : CGPoint(x: center.x + 0.24 * size, y: center.y - 0.16 * size)
            let offset = size * 0.17
            let radius = size * (vertical ? 0.10 : 0.095)
            let directions: [(CDirection, CGFloat, CGFloat)] = [(.up, 0, -1), (.down, 0, 1), (.left, -1, 0), (.right, 1, 0)]
            for (direction, dx, dy) in directions {
                let x = diamond.x + dx * offset
                let y = diamond.y + dy * offset
                controls.append(PlacedControl(element: .cButton(direction),
                                              frame: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2),
                                              label: "C"))
            }
        } else if scheme.hasFourFaceButtons {
            let radius = size * 0.19
            let ps = scheme.usesPlayStationSymbols
            place(.x, 0, -0.30, radius, ps ? "△" : "X")
            place(.a, 0.30, 0, radius, ps ? "○" : "A")
            place(.b, 0, 0.30, radius, ps ? "✕" : "B")
            place(.y, -0.30, 0, radius, ps ? "□" : "Y")
        } else {
            let radius = size * 0.21
            place(.b, -0.21, 0.11, radius, "B")
            place(.a, 0.21, -0.11, radius, "A")
        }
    }
}
