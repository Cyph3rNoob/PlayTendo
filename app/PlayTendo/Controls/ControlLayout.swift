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

/// Calcule la position de l'image du jeu et des boutons tactiles selon l'écran.
struct ControlLayout: Equatable {
    var gameRect: CGRect = .zero
    var controls: [PlacedControl] = []
    var faceRadius: CGFloat = 30

    static func == (lhs: ControlLayout, rhs: ControlLayout) -> Bool {
        lhs.gameRect == rhs.gameRect && lhs.controls.map(\.frame) == rhs.controls.map(\.frame)
    }

    static func make(scheme: ControlScheme, aspect: CGFloat, bounds: CGRect,
                     safe: UIEdgeInsets, gamepad: Bool) -> ControlLayout {
        let usable = bounds.inset(by: safe)
        guard usable.width > 0, usable.height > 0, aspect > 0 else { return ControlLayout() }
        var layout = ControlLayout()
        let portrait = bounds.height >= bounds.width
        let menuSize: CGFloat = 38

        if gamepad {
            // Manette branchée : l'image prend toute la place, seul le bouton menu reste.
            var width = usable.width
            var height = width / aspect
            if height > usable.height {
                height = usable.height
                width = height * aspect
            }
            layout.gameRect = CGRect(x: usable.midX - width / 2, y: usable.midY - height / 2, width: width, height: height)
            layout.controls = [PlacedControl(element: .menu,
                                             frame: CGRect(x: usable.maxX - menuSize - 8, y: usable.minY + 8,
                                                           width: menuSize, height: menuSize),
                                             label: "")]
            return layout
        }

        let shoulderSize = CGSize(width: scheme.hasSecondShoulders ? 70 : 92, height: 38)
        let smallSize = CGSize(width: 78, height: 30)
        var cluster: CGFloat
        var dpadCenter: CGPoint
        var faceCenter: CGPoint

        if portrait {
            var width = usable.width
            var height = width / aspect
            let maxHeight = usable.height * (scheme == .nintendoDS ? 0.70 : 0.55)
            if height > maxHeight {
                height = maxHeight
                width = height * aspect
            }
            layout.gameRect = CGRect(x: usable.midX - width / 2, y: usable.minY, width: width, height: height)

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
            var height = usable.height
            var width = height * aspect
            let maxWidth = bounds.width - 2 * 150
            if width > maxWidth {
                width = maxWidth
                height = width / aspect
            }
            layout.gameRect = CGRect(x: bounds.midX - width / 2, y: usable.midY - height / 2, width: width, height: height)

            let leftPanel = CGRect(x: usable.minX, y: usable.minY, width: max(0, layout.gameRect.minX - usable.minX),
                                   height: usable.height)
            let rightPanel = CGRect(x: layout.gameRect.maxX, y: usable.minY,
                                    width: max(0, usable.maxX - layout.gameRect.maxX), height: usable.height)
            cluster = max(110, min(168, usable.height * 0.42))
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

        layout.controls.append(PlacedControl(element: .dpad,
                                             frame: CGRect(x: dpadCenter.x - cluster / 2, y: dpadCenter.y - cluster / 2,
                                                           width: cluster, height: cluster), label: ""))
        layout.addFaceButtons(scheme: scheme, center: faceCenter, size: cluster)
        return layout
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
