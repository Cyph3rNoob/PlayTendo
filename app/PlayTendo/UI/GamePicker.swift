#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Sélecteur de jeux d'iOS qui rouvre le dossier du dernier import (iCloud Drive, Sur mon iPhone…).
/// Le `.fileImporter` de SwiftUI ne laisse pas choisir le dossier de départ : iOS rouvrait toujours le dernier dossier
/// choisi comme dossier (un jeu PS Vita), même après des imports de fichiers faits ailleurs.
struct GamePicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onPick: ([URL]) -> Void

    /// Dossier du dernier import. Une simple adresse suffit : le sélecteur tourne hors de l'app et ouvre ce dossier
    /// lui-même ; s'il n'existe plus, iOS revient à son emplacement habituel.
    static let lastFolderKey = "dossierDernierImport"

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Fichiers, archives et dossiers (jeu PS Vita extrait, dossier de jeux), comme avant.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item, .folder], asCopy: false)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        if let folder = UserDefaults.standard.url(forKey: Self.lastFolderKey) { picker.directoryURL = folder }
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: GamePicker
        init(_ parent: GamePicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            // Dossier qui contient l'élément choisi (pour un dossier Vita choisi : le dossier au-dessus).
            if let first = urls.first {
                UserDefaults.standard.set(first.deletingLastPathComponent(), forKey: GamePicker.lastFolderKey)
            }
            parent.isPresented = false
            parent.onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.isPresented = false
        }
    }
}
#endif
