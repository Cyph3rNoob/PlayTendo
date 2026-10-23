#if os(iOS)
import SwiftUI

/// Mode édition des boutons sur mesure (menu pause › Commandes › Modifier les boutons), par-dessus le jeu en pause :
/// chaque bloc de boutons se déplace en le faisant glisser et s'agrandit en le pinçant (ou avec TAILLE) ; la
/// transparence vaut pour tous. Les changements se voient tout de suite sur les vrais boutons, dessous.
struct ControlsEditor: View {
    let layout: ControlLayout
    let bounds: CGRect
    @Binding var custom: ControlCustomization
    let onDone: () -> Void
    @State private var selected: String?
    /// Glissement en cours : le réglage et le cadre du bloc au début.
    @State private var dragStart: (adjustment: ControlCustomization.Adjustment, frame: CGRect)?
    @State private var pinchStart: CGFloat?
    /// Panneau en haut de l'image (sinon en bas), pour libérer les boutons qu'il cacherait.
    @State private var panelOnTop = true

    var body: some View {
        let groups = layout.controlGroups()
        ZStack {
            Color.black.opacity(0.2)
                .contentShape(Rectangle())
                .onTapGesture { selected = nil }
            ForEach(groups, id: \.name) { group in
                handle(group, selected: group.name == selected)
            }
            panel(title: groups.first { $0.name == selected }?.title)
        }
        .ignoresSafeArea()
    }

    // MARK: Blocs

    private func handle(_ group: (name: String, frame: CGRect, title: String), selected isSelected: Bool) -> some View {
        Chamfer(cut: 10)
            .fill(Neon.cyan.opacity(isSelected ? 0.16 : 0.05))
            .overlay(Chamfer(cut: 10).stroke(isSelected ? Neon.cyan : Neon.text.opacity(0.55),
                                             style: StrokeStyle(lineWidth: isSelected ? 2 : 1.2, dash: [6, 4])))
            .frame(width: group.frame.width + 12, height: group.frame.height + 12)
            .contentShape(Rectangle())
            .position(x: group.frame.midX, y: group.frame.midY)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStart == nil {
                        selected = group.name
                        dragStart = (custom.groups[group.name] ?? ControlCustomization.Adjustment(), group.frame)
                    }
                    guard let start = dragStart else { return }
                    // Le bloc suit le doigt sans sortir de l'écran (le réglage ne garde pas un déplacement qui le
                    // ferait sortir, sinon il faudrait revenir d'autant avant de le voir bouger).
                    let half = CGSize(width: start.frame.width / 2, height: start.frame.height / 2)
                    let target = CGPoint(
                        x: min(max(start.frame.midX + value.translation.width, bounds.minX + half.width), bounds.maxX - half.width),
                        y: min(max(start.frame.midY + value.translation.height, bounds.minY + half.height), bounds.maxY - half.height))
                    var adjustment = start.adjustment
                    adjustment.dx += (target.x - start.frame.midX) / bounds.width
                    adjustment.dy += (target.y - start.frame.midY) / bounds.height
                    custom.groups[group.name] = adjustment
                }
                .onEnded { _ in dragStart = nil })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { value in
                    selected = group.name
                    let start = pinchStart ?? (custom.groups[group.name]?.scale ?? 1)
                    if pinchStart == nil { pinchStart = start }
                    setScale(start * value.magnification, for: group.name)
                }
                .onEnded { _ in pinchStart = nil })
            .accessibilityLabel(group.title)
    }

    private func setScale(_ scale: CGFloat, for group: String) {
        var adjustment = custom.groups[group] ?? ControlCustomization.Adjustment()
        adjustment.scale = min(max(scale, ControlCustomization.scaleRange.lowerBound), ControlCustomization.scaleRange.upperBound)
        custom.groups[group] = adjustment
    }

    // MARK: Panneau

    private func panel(title: String?) -> some View {
        let area = layout.gameRect.width > 200 ? layout.gameRect : bounds
        let width = min(area.width - 16, 360)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(tr("BOUTONS SUR MESURE"))
                    .font(.display(12, weight: 800))
                    .tracking(1.5)
                    .foregroundStyle(Neon.cyan)
                Spacer()
                Button { withAnimation(.easeInOut(duration: 0.2)) { panelOnTop.toggle() } } label: {
                    Image(systemName: panelOnTop ? "arrow.down.to.line" : "arrow.up.to.line")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Neon.text)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("Déplacer ce panneau"))
            }
            if let selected, let title {
                slider(label: tr("TAILLE") + " · " + title,
                       value: Binding(get: { Double(custom.groups[selected]?.scale ?? 1) },
                                      set: { setScale(CGFloat($0), for: selected) }),
                       range: Double(ControlCustomization.scaleRange.lowerBound)...Double(ControlCustomization.scaleRange.upperBound))
            } else {
                Text(tr("Fais glisser un bloc pour le déplacer, pince-le pour changer sa taille."))
                    .font(.system(size: 13))
                    .foregroundStyle(Neon.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Transparence : 0 % = boutons comme d'habitude.
            slider(label: tr("TRANSPARENCE"),
                   value: Binding(get: { 1 - custom.opacity }, set: { custom.opacity = 1 - $0 }),
                   range: 0...(1 - ControlCustomization.opacityRange.lowerBound))
            HStack(spacing: 8) {
                EditorButton(title: tr("Réinitialiser"), prominent: false) {
                    custom = ControlCustomization()
                    selected = nil
                }
                EditorButton(title: tr("Terminé"), prominent: true, action: onDone)
            }
        }
        .padding(14)
        .frame(width: width)
        .background(Chamfer(cut: 14).fill(Neon.panel.opacity(0.95)))
        .overlay(Chamfer(cut: 14).stroke(Neon.cyan.opacity(0.6), lineWidth: 1))
        .neonGlow(Neon.cyan, radius: 8)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: panelOnTop ? .top : .bottom)
        .padding(.top, panelOnTop ? area.minY + 8 : 0)
        .padding(.bottom, panelOnTop ? 0 : bounds.maxY - area.maxY + 8)
        .offset(x: area.midX - bounds.midX)
    }

    private func slider(label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.display(10, weight: 800))
                    .tracking(1.2)
                    .foregroundStyle(Neon.dim)
                    .lineLimit(1)
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded())) %")
                    .font(Neon.mono(11, weight: .semibold))
                    .foregroundStyle(Neon.cyan)
            }
            Slider(value: value, in: range)
                .tint(Neon.cyan)
        }
    }
}

private struct EditorButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(prominent ? Neon.onAccent : Neon.text)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Chamfer(cut: 9).fill(prominent ? Neon.cyan : Neon.text.opacity(0.07)))
                .overlay(Chamfer(cut: 9).stroke(prominent ? .clear : Neon.text.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
#endif
