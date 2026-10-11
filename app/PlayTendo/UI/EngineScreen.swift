import SwiftUI

/// Image de la PS2 ou de la GameCube/Wii : la vue Metal du moteur, dans laquelle il dessine lui-même (avec
/// ses propres bandes noires selon le format du jeu). La même vue sert à toutes les parties d'un moteur : elle
/// est posée dans un conteneur et retirée quand l'écran de jeu se ferme.
#if os(iOS)
struct EngineScreen: UIViewRepresentable {
    let renderView: UIView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        container.clipsToBounds = true
        container.isUserInteractionEnabled = false
        renderView.removeFromSuperview()
        renderView.frame = container.bounds
        renderView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(renderView)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {}

    static func dismantleUIView(_ container: UIView, coordinator: ()) {
        for view in container.subviews { view.removeFromSuperview() }
    }
}
#else
struct EngineScreen: NSViewRepresentable {
    let renderView: NSView

    func makeNSView(context: Context) -> NSView {
        let container = PassThroughView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.layer?.masksToBounds = true
        renderView.removeFromSuperview()
        renderView.frame = container.bounds
        renderView.autoresizingMask = [.width, .height]
        container.addSubview(renderView)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {}

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        for view in container.subviews { view.removeFromSuperview() }
    }
}

/// Vue qui laisse passer la souris à ce qui est dessous (clavier et souris sont lus par l'écran de jeu).
final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif
