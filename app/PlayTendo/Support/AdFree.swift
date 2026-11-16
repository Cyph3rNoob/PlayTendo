#if PLAYTENDO_APPSTORE
import StoreKit
import SwiftUI

/// Version App Store : achat unique « Retirer les pubs » (StoreKit 2, produit non consommable `productID`, à créer
/// sous ce nom dans App Store Connect). L'app est gratuite ; cet achat retire les pubs sur tous les appareils du même
/// compte Apple (« Restaurer mes achats »). Les pubs (étape suivante) lisent `isAdFree`.
///
/// L'état vient de StoreKit (`StoreKit.Transaction.currentEntitlements`, relu à chaque lancement : un achat remboursé remet les
/// pubs) ; une copie dans les réglages (`cacheKey`) sert seulement à ne pas montrer une pub pendant cette lecture.
///
/// Simulateur, compilation Debug : l'App Store n'y connaît pas le produit (il n'existe qu'une fois créé dans App Store
/// Connect) ; une boutique d'essai le remplace (`isSimulated`), pour essayer les écrans sans rien payer.
@MainActor
final class AdFree: ObservableObject {
    static let shared = AdFree()

    static let productID = "com.playtendo.app.removeads"
    private static let cacheKey = "pubsRetirees"

    /// Vrai si l'achat est fait : aucune pub.
    @Published private(set) var isAdFree: Bool
    /// Produit lu sur l'App Store (prix dans la monnaie du joueur), nil tant qu'il n'est pas chargé ou si la boutique
    /// est injoignable.
    @Published private(set) var product: Product?
    /// Achat, restauration ou chargement en cours.
    @Published private(set) var busy = false
    /// Vrai une fois la boutique interrogée (sans réponse, le bouton dit qu'elle est injoignable).
    @Published private(set) var storeChecked = false
    /// Message à montrer (achat en attente, erreur, restauration).
    @Published var message: String?

    private var updates: Task<Void, Never>?

    private init() {
        isAdFree = UserDefaults.standard.bool(forKey: Self.cacheKey)
        // Achats faits ailleurs (autre appareil, achat en attente validé, remboursement) : écoutés dès le lancement,
        // comme Apple le demande.
        updates = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                await self?.handle(result)
            }
        }
        Task { await refresh() }
    }

    /// Prix affiché sur le bouton (« 5,99 € »), nil si la boutique ne répond pas.
    var displayPrice: String? {
        if let product { return product.displayPrice }
#if DEBUG && targetEnvironment(simulator)
        return isSimulated ? "5,99 €" : nil
#else
        return nil
#endif
    }

    /// Charge le produit et relit l'achat auprès de StoreKit.
    func refresh() async {
        if product == nil {
            do {
                product = try await Product.products(for: [Self.productID]).first
                if product == nil { PTLogLine("Achat : produit « Retirer les pubs » inconnu de l'App Store") }
            } catch {
                PTLogLine("Achat : boutique injoignable (\(error.localizedDescription))")
            }
            storeChecked = true
        }
#if DEBUG && targetEnvironment(simulator)
        // Le faux achat d'essai reste prioritaire même quand le vrai produit est connu (captures d'écran, essais
        // sans pubs) ; jamais compilé dans la version publiée.
        if isSimulated || UserDefaults.standard.bool(forKey: Self.simulatedKey) {
            setAdFree(UserDefaults.standard.bool(forKey: Self.simulatedKey))
            return
        }
#endif
        var owned = false
        for await result in StoreKit.Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.productID == Self.productID,
               transaction.revocationDate == nil {
                owned = true
            }
        }
        setAdFree(owned)
    }

    func purchase() async {
#if DEBUG && targetEnvironment(simulator)
        if isSimulated {
            UserDefaults.standard.set(true, forKey: Self.simulatedKey)
            setAdFree(true)
            return
        }
#endif
        guard let product, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                await handle(result)
            case .pending:
                message = tr("Achat en attente d'approbation (partage familial ou banque). Les pubs disparaîtront dès qu'il sera validé.")
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            PTLogLine("Achat impossible : \(error.localizedDescription)")
            message = tr("Achat impossible : \(error.localizedDescription)")
        }
    }

    /// « Restaurer mes achats » : redemande les achats du compte Apple à l'App Store.
    func restore() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
#if DEBUG && targetEnvironment(simulator)
        if !isSimulated {
            do { try await AppStore.sync() } catch { return reportRestoreError(error) }
        }
#else
        do { try await AppStore.sync() } catch { return reportRestoreError(error) }
#endif
        await refresh()
        message = isAdFree ? tr("Achat restauré : plus de pubs. Merci !")
                           : tr("Aucun achat « Retirer les pubs » sur ce compte Apple.")
    }

    private func reportRestoreError(_ error: Error) {
        if let storeError = error as? StoreKitError, case .userCancelled = storeError { return }
        PTLogLine("Achat : restauration impossible (\(error.localizedDescription))")
        message = tr("Restauration impossible : \(error.localizedDescription)")
    }

    /// Transaction reçue (achat, achat validé plus tard, remboursement) : vérifiée par StoreKit, puis terminée.
    private func handle(_ result: VerificationResult<StoreKit.Transaction>) async {
        guard case .verified(let transaction) = result else {
            PTLogLine("Achat : transaction non vérifiée, ignorée")
            return
        }
        if transaction.productID == Self.productID {
            setAdFree(transaction.revocationDate == nil)
        }
        await transaction.finish()
    }

    private func setAdFree(_ value: Bool) {
        guard value != isAdFree else { return }
        isAdFree = value
        UserDefaults.standard.set(value, forKey: Self.cacheKey)
        PTLogLine(value ? "Achat : pubs retirées" : "Achat : pubs remises (achat absent ou remboursé)")
    }

#if DEBUG && targetEnvironment(simulator)
    private static let simulatedKey = "pubsRetireesEssai"

    /// Boutique d'essai : simulateur sans le produit de l'App Store.
    var isSimulated: Bool { product == nil }

    /// Essai : annule le faux achat, pour recommencer.
    func resetSimulatedPurchase() {
        UserDefaults.standard.set(false, forKey: Self.simulatedKey)
        setAdFree(false)
    }
#endif
}
#endif
