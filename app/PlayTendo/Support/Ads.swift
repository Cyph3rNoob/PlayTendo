#if PLAYTENDO_APPSTORE
import AppTrackingTransparency
import GoogleMobileAds
import SwiftUI
import UIKit
import UserMessagingPlatform

/// Version App Store : pubs AdMob (kits de Google dans libs/googleads, scripts/fetch_googleads.sh). Jamais si l'achat
/// « Retirer les pubs » est fait (`AdFree`), jamais pendant une partie.
/// - Au lancement (`prepare`, après l'animation et la présentation) : fenêtre de consentement de Google (RGPD, en
///   Europe), puis question de suivi d'Apple, puis démarrage du kit.
/// - Bandeau en bas de la bibliothèque (`AdBannerView`).
/// - Pub plein écran en quittant un jeu (`gameEnded`) : pas dans les 2 premières minutes, puis au plus une toutes les
///   5 minutes.
/// - Réglages : « Confidentialité des pubs » quand Google l'exige (`showPrivacyOptions`).
@MainActor
final class Ads: NSObject, ObservableObject, FullScreenContentDelegate {
    static let shared = Ads()

    /// Identifiants des pubs. Ceux du compte AdMob de PlayTendo ne sont pas dans le dépôt : ils viennent de
    /// secrets/admob_banner et secrets/admob_interstitial, mis dans l'Info.plist (PTAdMobBanner,
    /// PTAdMobInterstitial) par scripts/build_appstore.sh, comme l'ID de l'app (GADApplicationIdentifier,
    /// secrets/admob_app_id). Compilation Debug (simulateur, essais), ou identifiants absents : pubs d'essai de
    /// Google, jamais les vraies (cliquer sur ses propres pubs fait fermer le compte AdMob).
    enum Unit {
        private static let testBanner = "ca-app-pub-3940256099942544/2934735716"
        private static let testInterstitial = "ca-app-pub-3940256099942544/4411468910"
#if DEBUG
        static let banner = testBanner
        static let interstitial = testInterstitial
#else
        static let banner = configured("PTAdMobBanner") ?? testBanner
        static let interstitial = configured("PTAdMobInterstitial") ?? testInterstitial

        private static func configured(_ key: String) -> String? {
            guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
                  value.hasPrefix("ca-app-pub-") else { return nil }
            return value
        }
#endif
    }

    private static let firstInterstitialDelay: TimeInterval = 2 * 60
    private static let interstitialGap: TimeInterval = 5 * 60

    /// Kit démarré (consentement obtenu ou inutile) : les pubs peuvent s'afficher.
    @Published private(set) var started = false
    /// Google exige un accès aux choix de confidentialité (Europe) : ligne dans les Réglages.
    @Published private(set) var privacyOptionsRequired = false

    private var preparing = false
    /// Partie en cours (bibliothèque) : ni fenêtre de consentement ni pub par-dessus le jeu.
    var inGame = false
    private let launchDate = Date()
    private var lastInterstitial: Date?
    private var interstitial: InterstitialAd?
    private var loadingInterstitial = false

    /// Pubs à montrer : kit démarré et pas d'achat « Retirer les pubs ».
    var showsAds: Bool { started && !AdFree.shared.isAdFree }

    /// Consentement puis démarrage ; rappelé à chaque retour dans l'app (sans effet une fois démarré).
    func prepare() async {
        guard !started, !preparing, !inGame, !AdFree.shared.isAdFree else { return }
        preparing = true
        defer { preparing = false }
        let parameters = RequestParameters()
#if DEBUG
        // Essais : la fenêtre de consentement européenne s'affiche même hors d'Europe.
        let debug = DebugSettings()
        debug.geography = .EEA
        parameters.debugSettings = debug
#endif
        do {
            try await ConsentInformation.shared.requestConsentInfoUpdate(with: parameters)
            try await ConsentForm.loadAndPresentIfRequired(from: nil)
        } catch {
            PTLogLine("Pubs : consentement non obtenu (\(error.localizedDescription))")
        }
        privacyOptionsRequired = ConsentInformation.shared.privacyOptionsRequirementStatus == .required
        // Question de suivi d'Apple, après celle de Google (comme Google le conseille). Un refus laisse les pubs,
        // simplement moins ciblées.
        if ATTrackingManager.trackingAuthorizationStatus == .notDetermined {
            _ = await ATTrackingManager.requestTrackingAuthorization()
        }
        guard ConsentInformation.shared.canRequestAds else {
            PTLogLine("Pubs : pas encore de consentement, aucune pub demandée")
            return
        }
        guard !AdFree.shared.isAdFree else { return }
        started = true
        // Pubs « 12 ans et plus » au maximum (choisi le 2026-11-15) : rien de choquant ni d'adulte. Les catégories
        // (jeux d'argent, rencontres…) se bloquent dans le compte AdMob, au moment de la publication.
        MobileAds.shared.requestConfiguration.maxAdContentRating = .parentalGuidance
        PTLogLine("Pubs : kit démarré")
        // Le bandeau se charge déjà ; la pub plein écran attend la fin de l'initialisation du kit.
        _ = await MobileAds.shared.start()
        loadInterstitial()
    }

    /// Partie quittée (la partie est déjà refermée) : pub plein écran si le délai est passé.
    func gameEnded() {
        guard showsAds else { return }
        let now = Date()
        guard now.timeIntervalSince(launchDate) >= Self.firstInterstitialDelay,
              now.timeIntervalSince(lastInterstitial ?? .distantPast) >= Self.interstitialGap else { return }
        guard let ad = interstitial else {
            loadInterstitial()
            return
        }
        interstitial = nil
        lastInterstitial = now
        ad.present(from: nil)
    }

    /// Réglages › Confidentialité des pubs : formulaire de Google pour changer ses choix.
    func showPrivacyOptions() {
        Task {
            do {
                try await ConsentForm.presentPrivacyOptionsForm(from: nil)
            } catch {
                PTLogLine("Pubs : choix de confidentialité non affichés (\(error.localizedDescription))")
            }
        }
    }

    private func loadInterstitial() {
        guard showsAds, interstitial == nil, !loadingInterstitial else { return }
        loadingInterstitial = true
        Task {
            defer { loadingInterstitial = false }
            do {
                let ad = try await InterstitialAd.load(with: Unit.interstitial, request: Request())
                ad.fullScreenContentDelegate = self
                interstitial = ad
            } catch {
                PTLogLine("Pubs : pub plein écran non chargée (\(error.localizedDescription))")
            }
        }
    }

    // MARK: FullScreenContentDelegate

    func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        loadInterstitial()
    }

    func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        PTLogLine("Pubs : pub plein écran non affichée (\(error.localizedDescription))")
        loadInterstitial()
    }
}

/// Bandeau en bas de la bibliothèque, format classique (choisi le 2026-11-15 : le « grand » format adaptatif de Google
/// était trop haut) : 320 × 50, ou 728 × 90 quand la largeur le permet (iPad), centré sur une bande de toute la
/// largeur. Rien du tout tant que le kit n'est pas démarré ou si l'achat « Retirer les pubs » est fait.
///
/// La largeur vient d'une zone vide qui prend toute la place proposée ; le bandeau est posé par-dessus, à sa taille
/// fixe. Sinon la vue de Google annonçait une largeur plus grande que l'écran et toute la bibliothèque s'élargissait
/// avec elle (textes coupés des deux côtés, jeux hors de l'écran).
struct AdBannerView: View {
    @ObservedObject private var ads = Ads.shared
    @ObservedObject private var adFree = AdFree.shared
    @State private var width: CGFloat = 0

    var body: some View {
        if ads.started && !adFree.isAdFree {
            let size = width >= cgSize(for: AdSizeLeaderboard).width ? AdSizeLeaderboard : AdSizeBanner
            let bannerSize = cgSize(for: size)
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: bannerSize.height)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .overlay {
                    if width > 0 {
                        BannerRepresentable(adSize: size)
                            .frame(width: bannerSize.width, height: bannerSize.height)
                    }
                }
                .clipped()
                .background(Neon.background)
        }
    }
}

private struct BannerRepresentable: UIViewRepresentable {
    let adSize: AdSize

    func makeUIView(context: Context) -> BannerView {
        let banner = BannerView(adSize: adSize)
        banner.adUnitID = Ads.Unit.banner
        banner.load(Request())
        return banner
    }

    func updateUIView(_ banner: BannerView, context: Context) {
        // Largeur changée (rotation, iPad) : nouveau bandeau à la bonne taille.
        guard !isAdSizeEqualToSize(size1: banner.adSize, size2: adSize) else { return }
        banner.adSize = adSize
        banner.load(Request())
    }

    /// Toujours la taille donnée par SwiftUI, jamais celle que la vue de Google réclame.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: BannerView, context: Context) -> CGSize? {
        let size = cgSize(for: adSize)
        return CGSize(width: proposal.width ?? size.width, height: proposal.height ?? size.height)
    }
}
#endif
