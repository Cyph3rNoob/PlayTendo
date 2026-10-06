import SwiftUI
import UIKit

/// Image de la PS2 : la vue Metal du moteur, dans laquelle il dessine lui-même (avec ses propres bandes
/// noires selon le format du jeu). La même vue sert à toutes les parties : elle est posée dans un conteneur
/// et retirée quand l'écran de jeu se ferme.
struct PS2Screen: UIViewRepresentable {
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
