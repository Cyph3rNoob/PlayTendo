import SwiftUI
import UIKit

/// Calque des boutons tactiles. Gère le multi-touch (plusieurs boutons à la fois),
/// le glissement d'un bouton à l'autre et, pour la DS, l'écran tactile.
final class TouchControlsView: UIView {
    var layout = ControlLayout() { didSet { if layout != oldValue { setNeedsDisplay() } } }
    var scheme: ControlScheme = .nes { didSet { setNeedsDisplay() } }
    var onButton: ((PTButton, Bool) -> Void)?
    var onPointer: ((CGPoint, Bool) -> Void)?
    var onMenu: (() -> Void)?
    /// Appelé quand on touche l'écran ailleurs que sur le bouton menu.
    var onTouchDown: (() -> Void)?

    private enum TouchRole {
        case buttons(Set<PTButton>)
        case pointer
        case menu
    }

    private var touches: [ObjectIdentifier: TouchRole] = [:]
    private var pressed: Set<PTButton> = []
    private var menuHighlighted = false
    private let haptics = UIImpactFeedbackGenerator(style: .light)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        haptics.prepare()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Toucher

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let point = touch.location(in: self)
            let id = ObjectIdentifier(touch)
            if let menu = layout.controls.first(where: { $0.element == .menu }),
               menu.frame.insetBy(dx: -8, dy: -8).contains(point) {
                self.touches[id] = .menu
                menuHighlighted = true
                setNeedsDisplay()
            } else if let touchScreen = layout.touchScreen, touchScreen.frame.contains(point),
                      !self.touches.values.contains(where: { if case .pointer = $0 { true } else { false } }) {
                self.touches[id] = .pointer
                sendPointer(point, pressed: true)
            } else {
                self.touches[id] = .buttons(buttons(at: point))
                onTouchDown?()
            }
        }
        update()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let point = touch.location(in: self)
            let id = ObjectIdentifier(touch)
            switch self.touches[id] {
            case .buttons:
                self.touches[id] = .buttons(buttons(at: point))
            case .pointer:
                sendPointer(point, pressed: true)
            default:
                break
            }
        }
        update()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, cancelled: true)
    }

    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            switch self.touches[id] {
            case .menu:
                menuHighlighted = false
                setNeedsDisplay()
                let point = touch.location(in: self)
                if !cancelled, let menu = layout.controls.first(where: { $0.element == .menu }),
                   menu.frame.insetBy(dx: -16, dy: -16).contains(point) {
                    onMenu?()
                }
            case .pointer:
                sendPointer(touch.location(in: self), pressed: false)
            default:
                break
            }
            self.touches[id] = nil
        }
        update()
    }

    /// Relâche tout (changement d'orientation, mise en pause…).
    func releaseAll() {
        touches.removeAll()
        update()
        onPointer?(.zero, false)
    }

    /// Le doigt reste « dans » l'écran tactile même s'il en sort en glissant. La position est
    /// convertie dans l'image complète du jeu (les deux écrans empilés), que le moteur attend.
    private func sendPointer(_ point: CGPoint, pressed: Bool) {
        guard let touchScreen = layout.touchScreen, touchScreen.frame.width > 0, touchScreen.frame.height > 0 else { return }
        let frame = touchScreen.frame
        let u = min(max((point.x - frame.minX) / frame.width, 0), 0.999)
        let v = min(max((point.y - frame.minY) / frame.height, 0), 0.999)
        let source = touchScreen.source
        onPointer?(CGPoint(x: source.minX + u * source.width, y: source.minY + v * source.height), pressed)
    }

    private func update() {
        var now = Set<PTButton>()
        for role in touches.values {
            if case .buttons(let set) = role { now.formUnion(set) }
        }
        guard now != pressed else { return }
        let added = now.subtracting(pressed)
        for button in pressed.subtracting(now) { onButton?(button, false) }
        for button in added { onButton?(button, true) }
        if !added.isEmpty { haptics.impactOccurred(intensity: 0.6) }
        pressed = now
        setNeedsDisplay()
    }

    private func buttons(at point: CGPoint) -> Set<PTButton> {
        // L, R, Start et Select passent en priorité : la zone élargie de la croix ne doit
        // pas les recouvrir (c'était le cas sur la disposition compacte de la DS).
        for control in layout.controls {
            switch control.element {
            case .shoulder(let button), .small(let button):
                if control.frame.insetBy(dx: -8, dy: -4).contains(point) { return [button] }
            default:
                continue
            }
        }

        var result = Set<PTButton>()
        for control in layout.controls {
            switch control.element {
            case .dpad:
                let frame = control.frame
                guard frame.insetBy(dx: -28, dy: -28).contains(point) else { continue }
                let dx = point.x - frame.midX
                let dy = point.y - frame.midY
                guard hypot(dx, dy) > frame.width * 0.09 else { continue }
                var angle = atan2(dy, dx) * 180 / .pi
                if angle < 0 { angle += 360 }
                let sector = Int((angle + 22.5) / 45) % 8
                let directions: [[PTButton]] = [
                    [.right], [.right, .down], [.down], [.down, .left],
                    [.left], [.left, .up], [.up], [.up, .right],
                ]
                result.formUnion(directions[sector])
            case .face(let button):
                let center = CGPoint(x: control.frame.midX, y: control.frame.midY)
                if hypot(point.x - center.x, point.y - center.y) < layout.faceRadius * 1.15 {
                    result.insert(button)
                }
            case .shoulder, .small, .menu:
                break
            }
        }
        if result.isEmpty {
            // Tolérance : le bouton de face le plus proche s'il est presque touché.
            let faces = layout.controls.compactMap { control -> (PTButton, CGFloat)? in
                guard case .face(let button) = control.element else { return nil }
                return (button, hypot(point.x - control.frame.midX, point.y - control.frame.midY))
            }
            if let nearest = faces.min(by: { $0.1 < $1.1 }), nearest.1 < layout.faceRadius * 1.45 {
                result.insert(nearest.0)
            }
        }
        return result
    }

    // MARK: Dessin

    private let fill = UIColor(white: 1, alpha: 0.13)
    private let fillPressed = UIColor(white: 1, alpha: 0.38)
    private let stroke = UIColor(white: 1, alpha: 0.32)
    private let text = UIColor(white: 1, alpha: 0.88)

    override func draw(_ rect: CGRect) {
        for control in layout.controls {
            switch control.element {
            case .dpad: drawDPad(control.frame)
            case .face(let button): drawFace(control, button: button)
            case .shoulder(let button): drawPill(control, pressed: pressed.contains(button), radius: 12, fontSize: 15)
            case .small(let button): drawPill(control, pressed: pressed.contains(button), radius: control.frame.height / 2, fontSize: 11)
            case .menu: drawMenu(control.frame)
            }
        }
    }

    private func drawDPad(_ frame: CGRect) {
        let arm = frame.width * 0.34
        let c = CGPoint(x: frame.midX, y: frame.midY)
        let h = arm / 2
        let r = frame.width / 2
        let path = UIBezierPath()
        path.move(to: CGPoint(x: c.x - h, y: c.y - r))
        path.addLine(to: CGPoint(x: c.x + h, y: c.y - r))
        path.addLine(to: CGPoint(x: c.x + h, y: c.y - h))
        path.addLine(to: CGPoint(x: c.x + r, y: c.y - h))
        path.addLine(to: CGPoint(x: c.x + r, y: c.y + h))
        path.addLine(to: CGPoint(x: c.x + h, y: c.y + h))
        path.addLine(to: CGPoint(x: c.x + h, y: c.y + r))
        path.addLine(to: CGPoint(x: c.x - h, y: c.y + r))
        path.addLine(to: CGPoint(x: c.x - h, y: c.y + h))
        path.addLine(to: CGPoint(x: c.x - r, y: c.y + h))
        path.addLine(to: CGPoint(x: c.x - r, y: c.y - h))
        path.addLine(to: CGPoint(x: c.x - h, y: c.y - h))
        path.close()
        path.lineJoinStyle = .round
        path.lineWidth = 1.5
        fill.setFill()
        path.fill()
        stroke.setStroke()
        path.stroke()

        let arms: [(PTButton, CGRect, CGFloat)] = [
            (.up, CGRect(x: c.x - h, y: c.y - r, width: arm, height: r - h), -.pi / 2),
            (.down, CGRect(x: c.x - h, y: c.y + h, width: arm, height: r - h), .pi / 2),
            (.left, CGRect(x: c.x - r, y: c.y - h, width: r - h, height: arm), .pi),
            (.right, CGRect(x: c.x + h, y: c.y - h, width: r - h, height: arm), 0),
        ]
        for (button, armRect, angle) in arms {
            if pressed.contains(button) {
                fillPressed.setFill()
                UIBezierPath(rect: armRect).fill()
            }
            // Petite flèche au bout de chaque branche.
            let tip = CGPoint(x: c.x + cos(angle) * r * 0.78, y: c.y + sin(angle) * r * 0.78)
            let size = arm * 0.22
            let arrow = UIBezierPath()
            arrow.move(to: CGPoint(x: tip.x + cos(angle) * size, y: tip.y + sin(angle) * size))
            arrow.addLine(to: CGPoint(x: tip.x + cos(angle + 2.3) * size, y: tip.y + sin(angle + 2.3) * size))
            arrow.addLine(to: CGPoint(x: tip.x + cos(angle - 2.3) * size, y: tip.y + sin(angle - 2.3) * size))
            arrow.close()
            UIColor(white: 1, alpha: 0.55).setFill()
            arrow.fill()
        }
    }

    private func drawFace(_ control: PlacedControl, button: PTButton) {
        let frame = control.frame
        let circle = UIBezierPath(ovalIn: frame)
        (pressed.contains(button) ? fillPressed : fill).setFill()
        circle.fill()
        circle.lineWidth = 1.5
        stroke.setStroke()
        circle.stroke()

        if scheme == .playStation {
            drawPlayStationSymbol(button, in: frame)
        } else {
            drawLabel(control.label, in: frame, size: frame.height * 0.42, weight: .bold)
        }
    }

    private func drawPlayStationSymbol(_ button: PTButton, in frame: CGRect) {
        let s = frame.width * 0.26
        let c = CGPoint(x: frame.midX, y: frame.midY)
        let path: UIBezierPath
        let color: UIColor
        switch button {
        case .x: // triangle
            path = UIBezierPath()
            path.move(to: CGPoint(x: c.x, y: c.y - s))
            path.addLine(to: CGPoint(x: c.x + s * 0.95, y: c.y + s * 0.65))
            path.addLine(to: CGPoint(x: c.x - s * 0.95, y: c.y + s * 0.65))
            path.close()
            color = UIColor(red: 0.30, green: 0.85, blue: 0.70, alpha: 1)
        case .a: // rond
            path = UIBezierPath(ovalIn: CGRect(x: c.x - s, y: c.y - s, width: s * 2, height: s * 2))
            color = UIColor(red: 1.0, green: 0.42, blue: 0.45, alpha: 1)
        case .b: // croix
            path = UIBezierPath()
            path.move(to: CGPoint(x: c.x - s, y: c.y - s))
            path.addLine(to: CGPoint(x: c.x + s, y: c.y + s))
            path.move(to: CGPoint(x: c.x + s, y: c.y - s))
            path.addLine(to: CGPoint(x: c.x - s, y: c.y + s))
            color = UIColor(red: 0.50, green: 0.70, blue: 1.0, alpha: 1)
        default: // carré
            path = UIBezierPath(rect: CGRect(x: c.x - s * 0.85, y: c.y - s * 0.85, width: s * 1.7, height: s * 1.7))
            color = UIColor(red: 0.95, green: 0.55, blue: 0.85, alpha: 1)
        }
        path.lineWidth = max(2, frame.width * 0.06)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.withAlphaComponent(0.9).setStroke()
        path.stroke()
    }

    private func drawPill(_ control: PlacedControl, pressed isPressed: Bool, radius: CGFloat, fontSize: CGFloat) {
        let path = UIBezierPath(roundedRect: control.frame, cornerRadius: radius)
        (isPressed ? fillPressed : fill).setFill()
        path.fill()
        path.lineWidth = 1.5
        stroke.setStroke()
        path.stroke()
        drawLabel(control.label, in: control.frame, size: fontSize, weight: .semibold)
    }

    private func drawMenu(_ frame: CGRect) {
        let circle = UIBezierPath(ovalIn: frame)
        (menuHighlighted ? fillPressed : fill).setFill()
        circle.fill()
        circle.lineWidth = 1.5
        stroke.setStroke()
        circle.stroke()
        let config = UIImage.SymbolConfiguration(pointSize: frame.height * 0.4, weight: .semibold)
        if let image = UIImage(systemName: "line.3.horizontal", withConfiguration: config)?
            .withTintColor(text, renderingMode: .alwaysOriginal) {
            image.draw(at: CGPoint(x: frame.midX - image.size.width / 2, y: frame.midY - image.size.height / 2))
        }
    }

    private func drawLabel(_ label: String, in frame: CGRect, size: CGFloat, weight: UIFont.Weight) {
        var font = UIFont.systemFont(ofSize: size, weight: weight)
        if let rounded = font.fontDescriptor.withDesign(.rounded) {
            font = UIFont(descriptor: rounded, size: size)
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: text, .kern: size < 13 ? 1.0 : 0]
        let string = NSAttributedString(string: label, attributes: attributes)
        let bounds = string.size()
        string.draw(at: CGPoint(x: frame.midX - bounds.width / 2, y: frame.midY - bounds.height / 2))
    }
}

/// Pont SwiftUI → UIKit pour le calque des boutons.
struct TouchControls: UIViewRepresentable {
    let layout: ControlLayout
    let scheme: ControlScheme
    let session: EmulatorSession
    let onMenu: () -> Void
    var onTouchDown: () -> Void = {}

    func makeUIView(context: Context) -> TouchControlsView {
        let view = TouchControlsView()
        view.onButton = { [session] button, pressed in session.setButton(button, pressed: pressed) }
        view.onPointer = { [session] point, pressed in session.setPointer(x: point.x, y: point.y, pressed: pressed) }
        return view
    }

    func updateUIView(_ view: TouchControlsView, context: Context) {
        view.scheme = scheme
        view.layout = layout
        view.onMenu = onMenu
        view.onTouchDown = onTouchDown
    }
}
