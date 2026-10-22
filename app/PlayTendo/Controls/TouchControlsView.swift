// Boutons tactiles : iPhone et iPad seulement (sur Mac : clavier, souris et manette, MacInputView.swift).
#if os(iOS)
import SwiftUI
import UIKit

/// Ce qu'un doigt peut enfoncer : un bouton de la manette, ou un bouton C (N64).
enum TouchInput: Hashable {
    case button(PTButton)
    case c(CDirection)
}

/// Calque des boutons tactiles. Gère le multi-touch (plusieurs boutons à la fois),
/// le glissement d'un bouton à l'autre, les sticks analogiques et, pour la DS, l'écran tactile.
final class TouchControlsView: UIView {
    var layout = ControlLayout() {
        didSet {
            guard layout != oldValue else { return }
            setNeedsDisplay()
            updateKnob()
        }
    }
    var scheme: ControlScheme = .nes { didSet { setNeedsDisplay() } }
    var onButton: ((PTButton, Bool) -> Void)?
    /// Stick analogique (0 = gauche, 1 = droit) ; x et y de -1 à 1, y vers le bas.
    var onAnalog: ((UInt32, CGFloat, CGFloat) -> Void)?
    var onPointer: ((CGPoint, Bool) -> Void)?
    var onMenu: (() -> Void)?
    /// Bouton ⏪ enfoncé (vrai) ou relâché (faux).
    var onRewind: ((Bool) -> Void)?
    /// Appelé quand on touche l'écran ailleurs que sur le bouton menu.
    var onTouchDown: (() -> Void)?

    private enum TouchRole {
        case inputs(Set<TouchInput>)
        /// Stick 0 (gauche) ou 1 (droit, PS2).
        case stick(Int)
        case pointer
        case menu
        case rewind
    }

    private var touches: [ObjectIdentifier: TouchRole] = [:]
    private var pressed: Set<TouchInput> = []
    /// Position des sticks (gauche, droit), de -1 à 1 sur chaque axe.
    private var stickOffsets: [CGPoint] = [.zero, .zero]
    private var cStick = CGPoint.zero
    private var menuHighlighted = false
    private var rewindHighlighted = false
    private let haptics = UIImpactFeedbackGenerator(style: .light)
    /// Têtes des sticks : des calques à part, déplacés seuls quand le doigt bouge (sans redessiner les boutons).
    private let knobLayers = [CAShapeLayer(), CAShapeLayer()]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        haptics.prepare()
        for knob in knobLayers {
            knob.lineWidth = 1.5
            knob.isHidden = true
            layer.addSublayer(knob)
        }
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
            } else if let rewind = layout.controls.first(where: { $0.element == .rewind }),
                      rewind.frame.insetBy(dx: -8, dy: -8).contains(point) {
                self.touches[id] = .rewind
                rewindHighlighted = true
                setNeedsDisplay()
                haptics.impactOccurred()
                onRewind?(true)
            } else if let index = stickIndex(at: point) {
                self.touches[id] = .stick(index)
                moveStick(index, to: point)
                onTouchDown?()
            } else if case let hit = inputs(at: point), !hit.isEmpty {
                // Un bouton visible passe avant l'écran tactile qu'il recouvre (manette branchée).
                self.touches[id] = .inputs(hit)
                onTouchDown?()
            } else if let touchScreen = layout.touchScreen, touchScreen.frame.contains(point),
                      !self.touches.values.contains(where: { if case .pointer = $0 { true } else { false } }) {
                self.touches[id] = .pointer
                sendPointer(point, pressed: true)
            } else {
                self.touches[id] = .inputs([])
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
            case .inputs:
                self.touches[id] = .inputs(inputs(at: point))
            case .stick(let index):
                moveStick(index, to: point)
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
            case .rewind:
                rewindHighlighted = false
                setNeedsDisplay()
                onRewind?(false)
            case .pointer:
                sendPointer(touch.location(in: self), pressed: false)
            case .stick(let index):
                setStick(index, .zero)
            default:
                break
            }
            self.touches[id] = nil
        }
        update()
    }

    private func stickControl(_ index: Int) -> PlacedControl? {
        layout.controls.first { $0.element == (index == 0 ? .stick : .rightStick) }
    }

    /// Stick saisi par un doigt posé à cet endroit (zone élargie autour du socle), s'il est libre. Un doigt
    /// posé en plein sur un bouton, sur la croix, ou sur L, R, Start, Select, garde ce bouton.
    private func stickIndex(at point: CGPoint) -> Int? {
        guard priorityInputs(at: point).isEmpty, !isDirectlyOnButton(point) else { return nil }
        for index in 0..<2 {
            guard let stick = stickControl(index), stick.frame.insetBy(dx: -20, dy: -20).contains(point),
                  !touches.values.contains(where: { if case .stick(index) = $0 { true } else { false } }) else { continue }
            return index
        }
        return nil
    }

    private func isDirectlyOnButton(_ point: CGPoint) -> Bool {
        layout.controls.contains { control in
            switch control.element {
            case .dpad: control.frame.contains(point)
            case .face, .cButton: hypot(point.x - control.frame.midX, point.y - control.frame.midY) < control.frame.width / 2
            default: false
            }
        }
    }

    /// Le doigt garde le stick même s'il sort du cercle ; la course est limitée au bord.
    private func moveStick(_ index: Int, to point: CGPoint) {
        guard let stick = stickControl(index) else { return }
        let travel = stick.frame.width * Self.stickTravel
        var x = (point.x - stick.frame.midX) / travel
        var y = (point.y - stick.frame.midY) / travel
        let length = hypot(x, y)
        if length > 1 {
            x /= length
            y /= length
        }
        setStick(index, CGPoint(x: x, y: y))
    }

    private func setStick(_ index: Int, _ offset: CGPoint) {
        guard offset != stickOffsets[index] else { return }
        stickOffsets[index] = offset
        onAnalog?(UInt32(index), offset.x, offset.y)
        updateKnob()
    }

    /// Place la tête de chaque stick selon la position du doigt (cachée s'il n'y a pas ce stick à l'écran).
    private func updateKnob() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (index, knob) in knobLayers.enumerated() {
            guard let stick = stickControl(index) else {
                knob.isHidden = true
                continue
            }
            let frame = stick.frame
            let offset = stickOffsets[index]
            let travel = frame.width * Self.stickTravel
            let radius = frame.width * 0.2
            knob.isHidden = false
            knob.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
            knob.path = UIBezierPath(ovalIn: knob.bounds).cgPath
            knob.position = CGPoint(x: frame.midX + offset.x * travel, y: frame.midY + offset.y * travel)
            knob.fillColor = (offset == .zero ? UIColor(white: 0.35, alpha: 0.75) : fillPressed).cgColor
            knob.strokeColor = stroke.cgColor
        }
    }

    /// Distance (en part de la largeur du stick) entre le centre et la position extrême.
    private static let stickTravel: CGFloat = 0.32

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
        var now = Set<TouchInput>()
        for role in touches.values {
            if case .inputs(let set) = role { now.formUnion(set) }
        }
        guard now != pressed else { return }
        let added = now.subtracting(pressed)
        for case .button(let button) in pressed.subtracting(now) { onButton?(button, false) }
        for case .button(let button) in added { onButton?(button, true) }
        if !added.isEmpty { haptics.impactOccurred(intensity: 0.6) }
        pressed = now

        // Boutons C : le moteur N64 les lit sur le stick analogique droit.
        let c = CGPoint(x: (now.contains(.c(.right)) ? 1 : 0) - (now.contains(.c(.left)) ? 1 : 0),
                        y: (now.contains(.c(.down)) ? 1 : 0) - (now.contains(.c(.up)) ? 1 : 0))
        if c != cStick {
            cStick = c
            onAnalog?(1, c.x, c.y)
        }
        setNeedsDisplay()
    }

    /// L, R, Start et Select passent en priorité : la zone élargie de la croix ne doit
    /// pas les recouvrir (c'était le cas sur la disposition compacte de la DS).
    private func priorityInputs(at point: CGPoint) -> Set<TouchInput> {
        for control in layout.controls {
            switch control.element {
            case .shoulder(let button), .small(let button):
                if control.frame.insetBy(dx: -8, dy: -4).contains(point) { return [.button(button)] }
            default:
                continue
            }
        }
        return []
    }

    private func inputs(at point: CGPoint) -> Set<TouchInput> {
        let priority = priorityInputs(at: point)
        if !priority.isEmpty { return priority }

        var result = Set<TouchInput>()
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
                result.formUnion(directions[sector].map { .button($0) })
            case .face, .cButton:
                if let input = Self.roundInput(control.element),
                   hypot(point.x - control.frame.midX, point.y - control.frame.midY) < control.frame.width / 2 * 1.15 {
                    result.insert(input)
                }
            case .shoulder, .small, .stick, .rightStick, .menu, .rewind:
                break
            }
        }
        if result.isEmpty {
            // Tolérance : le bouton rond le plus proche s'il est presque touché.
            let rounds = layout.controls.compactMap { control -> (TouchInput, CGFloat)? in
                guard let input = Self.roundInput(control.element) else { return nil }
                // Distance rapportée au rayon du bouton (les boutons C sont plus petits).
                return (input, hypot(point.x - control.frame.midX, point.y - control.frame.midY) / (control.frame.width / 2))
            }
            if let nearest = rounds.min(by: { $0.1 < $1.1 }), nearest.1 < 1.45 {
                result.insert(nearest.0)
            }
        }
        return result
    }

    private static func roundInput(_ element: ControlElement) -> TouchInput? {
        switch element {
        case .face(let button): .button(button)
        case .cButton(let direction): .c(direction)
        default: nil
        }
    }

    // MARK: Dessin

    // Gris foncé translucide + contour clair : lisible sur fond noir comme sur un écran de jeu clair
    // (quand une manette est branchée, les boutons passent par-dessus les écrans de la DS).
    private let fill = UIColor(white: 0.15, alpha: 0.6)
    private let fillPressed = UIColor(white: 0.55, alpha: 0.65)
    private let stroke = UIColor(white: 1, alpha: 0.38)
    private let text = UIColor(white: 1, alpha: 0.92)

    override func draw(_ rect: CGRect) {
        for control in layout.controls {
            switch control.element {
            case .dpad: drawDPad(control.frame)
            case .face(let button): drawFace(control, button: button)
            case .cButton(let direction): drawCButton(control.frame, direction: direction)
            case .stick: drawStick(control.frame)
            case .rightStick: drawStick(control.frame, tint: scheme.isGameCube ? Self.cStickYellow : nil)
            case .shoulder(let button): drawPill(control, pressed: pressed.contains(.button(button)), radius: 12, fontSize: 15)
            case .small(let button):
                // « − » et « + » de la Wiimote : un seul signe, écrit plus gros.
                drawPill(control, pressed: pressed.contains(.button(button)), radius: control.frame.height / 2,
                         fontSize: control.label.count == 1 ? 18 : 11)
            case .menu: drawMenu(control.frame)
            case .rewind: drawRound(control.frame, symbol: "backward.fill", highlighted: rewindHighlighted)
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
            if pressed.contains(.button(button)) {
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
        (pressed.contains(.button(button)) ? fillPressed : fill).setFill()
        circle.fill()
        circle.lineWidth = 1.5
        stroke.setStroke()
        circle.stroke()

        if scheme.usesPlayStationSymbols {
            drawPlayStationSymbol(button, in: frame)
        } else if scheme.isGameCube {
            // A vert, B rouge, X et Y gris clair, comme sur la manette GameCube.
            let color: UIColor? = switch button {
            case .b: UIColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1)
            case .y: UIColor(red: 1.0, green: 0.38, blue: 0.40, alpha: 1)
            default: nil
            }
            drawLabel(control.label, in: frame, size: frame.height * 0.42, weight: .bold, color: color)
        } else if scheme.isNintendo64 {
            // A bleu, B vert, comme sur la manette N64.
            let color = button == .b ? UIColor(red: 0.45, green: 0.62, blue: 1, alpha: 1)
                                     : UIColor(red: 0.40, green: 0.85, blue: 0.50, alpha: 1)
            drawLabel(control.label, in: frame, size: frame.height * 0.42, weight: .bold, color: color)
        } else {
            drawLabel(control.label, in: frame, size: frame.height * 0.42, weight: .bold)
        }
    }

    /// Bouton C jaune, avec une flèche dans sa direction.
    private func drawCButton(_ frame: CGRect, direction: CDirection) {
        let circle = UIBezierPath(ovalIn: frame)
        (pressed.contains(.c(direction)) ? fillPressed : fill).setFill()
        circle.fill()
        circle.lineWidth = 1.5
        stroke.setStroke()
        circle.stroke()

        let angle: CGFloat = switch direction {
        case .right: 0
        case .down: .pi / 2
        case .left: .pi
        case .up: -.pi / 2
        }
        let c = CGPoint(x: frame.midX, y: frame.midY)
        let size = frame.width * 0.26
        let arrow = UIBezierPath()
        arrow.move(to: CGPoint(x: c.x + cos(angle) * size, y: c.y + sin(angle) * size))
        arrow.addLine(to: CGPoint(x: c.x + cos(angle + 2.4) * size, y: c.y + sin(angle + 2.4) * size))
        arrow.addLine(to: CGPoint(x: c.x + cos(angle - 2.4) * size, y: c.y + sin(angle - 2.4) * size))
        arrow.close()
        UIColor(red: 1, green: 0.84, blue: 0.25, alpha: 0.95).setFill()
        arrow.fill()
    }

    /// Socle rond d'un stick (la tête est un calque à part, voir `updateKnob`).
    /// Jaune du stick C de la GameCube.
    private static let cStickYellow = UIColor(red: 1.0, green: 0.84, blue: 0.25, alpha: 0.9)

    private func drawStick(_ frame: CGRect, tint: UIColor? = nil) {
        let base = UIBezierPath(ovalIn: frame.insetBy(dx: frame.width * 0.04, dy: frame.width * 0.04))
        fill.setFill()
        base.fill()
        base.lineWidth = tint == nil ? 1.5 : 2.5
        (tint ?? stroke).setStroke()
        base.stroke()
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
        drawRound(frame, symbol: "line.3.horizontal", highlighted: menuHighlighted)
    }

    /// Petit bouton rond à symbole : menu, retour en arrière.
    private func drawRound(_ frame: CGRect, symbol: String, highlighted: Bool) {
        let circle = UIBezierPath(ovalIn: frame)
        (highlighted ? fillPressed : fill).setFill()
        circle.fill()
        circle.lineWidth = 1.5
        stroke.setStroke()
        circle.stroke()
        let config = UIImage.SymbolConfiguration(pointSize: frame.height * 0.4, weight: .semibold)
        if let image = UIImage(systemName: symbol, withConfiguration: config)?
            .withTintColor(text, renderingMode: .alwaysOriginal) {
            image.draw(at: CGPoint(x: frame.midX - image.size.width / 2, y: frame.midY - image.size.height / 2))
        }
    }

    private func drawLabel(_ label: String, in frame: CGRect, size: CGFloat, weight: UIFont.Weight, color: UIColor? = nil) {
        var font = UIFont.systemFont(ofSize: size, weight: weight)
        if let rounded = font.fontDescriptor.withDesign(.rounded) {
            font = UIFont(descriptor: rounded, size: size)
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color ?? text, .kern: size < 13 ? 1.0 : 0]
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
        view.onRewind = { [session] on in session.setRewinding(on) }
        view.onAnalog = { [session] stick, x, y in session.setAnalog(stick: stick, x: Float(x), y: Float(y)) }
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
#endif
