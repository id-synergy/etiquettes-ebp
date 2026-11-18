import SwiftUI

/// Vérifie au démarrage si une version plus récente de l'app est disponible sur l'App Store, et
/// propose à l'utilisateur de la mettre à jour. Sans backend : interroge l'API publique iTunes
/// Lookup, compare la version du store à la version installée (comparaison sémantique via
/// `AppVersion`), et expose de quoi présenter une alerte.
///
/// Discret par conception : échoue en SILENCE (hors-ligne, réponse inattendue), ne vérifie qu'une
/// fois par lancement, et ne bloque jamais l'app. Si l'utilisateur répond « Plus tard », la même
/// version n'est plus reproposée (mémorisée dans UserDefaults).
@MainActor
final class AppUpdateChecker: ObservableObject {
    /// Renseigné quand une mise à jour est disponible ET non ignorée : déclenche l'alerte.
    @Published var available: Update?

    struct Update: Equatable {
        let version: String
        let url: URL
    }

    private let bundleID: String
    private let installedVersion: String
    private let session: URLSession
    private var didCheck = false

    private static let ignoredVersionKey = "appUpdate.ignoredVersion"

    init(bundleID: String = Bundle.main.bundleIdentifier ?? "",
         installedVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
         session: URLSession = .shared) {
        self.bundleID = bundleID
        self.installedVersion = installedVersion
        self.session = session
    }

    /// Lance la vérification une seule fois par lancement. À appeler au démarrage.
    func checkOnce() {
        guard !didCheck else { return }
        didCheck = true
        Task { await check() }
    }

    private func check() async {
        guard !bundleID.isEmpty,
              let url = URL(string: "https://itunes.apple.com/lookup?bundleId=\(bundleID)") else { return }
        guard let (data, _) = try? await session.data(from: url),
              let lookup = try? JSONDecoder().decode(ITunesLookup.self, from: data),
              let result = lookup.results.first,
              let storeURL = URL(string: result.trackViewUrl) else { return }

        guard AppVersion.isNewer(result.version, than: installedVersion) else { return }
        // Déjà refusée par l'utilisateur : on ne la repropose pas.
        if UserDefaults.standard.string(forKey: Self.ignoredVersionKey) == result.version { return }
        available = Update(version: result.version, url: storeURL)
    }

    /// « Plus tard » : on retient cette version pour ne plus la reproposer, et on referme l'alerte.
    func dismiss() {
        if let version = available?.version {
            UserDefaults.standard.set(version, forKey: Self.ignoredVersionKey)
        }
        available = nil
    }

    /// « Mettre à jour » : ouvre la fiche App Store.
    func openStore() {
        if let url = available?.url { UIApplication.shared.open(url) }
        available = nil
    }

    private struct ITunesLookup: Decodable {
        let results: [Result]
        struct Result: Decodable {
            let version: String
            let trackViewUrl: String
        }
    }
}
