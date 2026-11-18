import SwiftUI

/// Feuille d'IMPORT par scan de QR. Gère DEUX cas de façon transparente :
///  - un QR SIMPLE (payload court) : la chaîne décodée part directement à `onScanned` ;
///  - un partage PAGINÉ (plusieurs QR) : on reste en scan continu, on collecte les pages (dans
///    n'importe quel ordre), on affiche la progression, et quand tout est là ET que la signature
///    est vérifiée, on passe le JSON reconstitué au MÊME `onScanned`.
///
/// `onScanned` reçoit donc toujours une chaîne JSON à valider par le parent, qu'elle vienne d'un
/// seul QR ou de la reconstitution de plusieurs pages.
struct ImportScanView: View {
    let title: String
    let hint: String
    /// Reçoit la chaîne JSON (QR simple ou pages reconstituées), renvoie un message de résultat.
    /// Retourne `true` en cas de succès (la feuille se ferme après un court délai).
    let onScanned: (String) -> ImportOutcome
    let onClose: () -> Void

    @State private var outcome: ImportOutcome?
    @State private var handled = false
    /// Collecteur des pages d'un partage paginé. Réinitialisé si l'utilisateur recommence.
    @State private var collector = QRPageCollector()
    /// Progression du partage paginé en cours (0/0 tant qu'aucune page paginée scannée).
    @State private var pagedProgress: (received: Int, total: Int) = (0, 0)
    /// Réarme le scanner après chaque page (recrée la vue → le coordinator rescanne).
    @State private var scanGeneration = 0

    var body: some View {
        NavigationStack {
            ZStack {
                QRScannerView(
                    onFound: { raw in handle(raw) },
                    onError: { message in outcome = .failure(message) }
                )
                .id(scanGeneration)
                .ignoresSafeArea(edges: .bottom)

                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(.white.opacity(0.9), lineWidth: 3)
                    .frame(width: 240, height: 240)
                    .allowsHitTesting(false)

                VStack {
                    Spacer()
                    if pagedProgress.total > 1 {
                        Label(String(format: NSLocalizedString("Pages reçues : %d / %d", comment: "Paged progress"),
                                     pagedProgress.received, pagedProgress.total),
                              systemImage: "square.stack.3d.up")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.blue.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal, 24)
                    }
                    Text(hint)
                        .font(.footnote).foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 24)
                    if let outcome {
                        Label(outcome.message, systemImage: outcome.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(outcome.isSuccess ? .green : .red)
                            .padding(12)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal, 24)
                        if !outcome.isSuccess {
                            Button(NSLocalizedString("Réessayer", comment: "Retry scan")) {
                                self.outcome = nil
                                handled = false
                                collector.reset()
                                pagedProgress = (0, 0)
                                rearm()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    Spacer().frame(height: 40)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("Annuler", comment: "Cancel"), action: onClose)
                }
            }
            // Pendant une collecte paginée en cours, on empêche la fermeture par glissement : un
            // faux geste perdrait les pages déjà scannées. On ferme par « Annuler ».
            .interactiveDismissDisabled(pagedProgress.received > 0 && outcome == nil)
        }
    }

    private func handle(_ raw: String) {
        guard !handled else { return }
        switch QRPagination.parsePage(raw) {
        case .failure(.notPaginated):
            // QR simple : on traite comme avant (réessai possible si le parent refuse).
            finish(with: onScanned(raw), terminal: false)
        case .failure(.malformed):
            // Ressemble à une page mais cassée : on réarme pour laisser l'utilisateur réessayer.
            outcome = .failure(NSLocalizedString("Page illisible. Réessayez.", comment: "Bad page"))
            rearm()
        case .success(let page):
            handlePage(page)
        }
    }

    /// Intègre une page d'un partage paginé et met à jour la progression ou conclut.
    private func handlePage(_ page: QRPagination.Page) {
        switch collector.add(page) {
        case .added(let received, let total), .duplicate(let received, let total):
            pagedProgress = (received, total)
            outcome = nil
            rearm()
        case .otherTransfer:
            outcome = .failure(NSLocalizedString("Cette page vient d’un autre partage. Recommencez.", comment: "Other transfer"))
            collector.reset()
            pagedProgress = (0, 0)
            rearm()
        case .signatureMismatch:
            outcome = .failure(NSLocalizedString("Les pages ne correspondent pas (transfert incomplet ou altéré). Recommencez.", comment: "Signature mismatch"))
            collector.reset()
            pagedProgress = (0, 0)
            rearm()
        case .completed(let data):
            // Toutes les pages reçues et signature vérifiée : on remet le JSON au parent. Si le
            // parent refuse (mauvais type, contenu vide…), l'échec est TERMINAL : le transfert était
            // complet et vérifié, rescanner une page ne ferait que des doublons. L'utilisateur
            // recommence via « Réessayer » (qui réinitialise tout).
            let json = String(decoding: data, as: UTF8.self)
            finish(with: onScanned(json), terminal: true)
        }
    }

    /// Conclut l'import. `terminal` empêche un réessai page-par-page quand le transfert était déjà
    /// complet : « Réessayer » repart alors d'un collecteur vide.
    private func finish(with result: ImportOutcome, terminal: Bool) {
        handled = true
        outcome = result
        if result.isSuccess {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.1))
                onClose()
            }
        } else if terminal {
            // Échec après reconstitution complète : on nettoie pour un nouvel essai propre.
            collector.reset()
            pagedProgress = (0, 0)
            handled = true   // reste figé jusqu'à « Réessayer »
        } else {
            // Échec d'un QR simple : on laisse réessayer directement.
            handled = false
        }
    }

    /// Recrée le scanner pour qu'il lise la page suivante (il se fige après chaque lecture).
    private func rearm() {
        scanGeneration += 1
    }
}

/// Résultat d'un import, avec le message à montrer à l'utilisateur.
struct ImportOutcome {
    let isSuccess: Bool
    let message: String

    static func success(_ message: String) -> ImportOutcome { ImportOutcome(isSuccess: true, message: message) }
    static func failure(_ message: String) -> ImportOutcome { ImportOutcome(isSuccess: false, message: message) }
}

// MARK: - Messages d'erreur d'import

extension ShareDecodeError {
    /// Message clair et court en français pour l'utilisateur.
    var userMessage: String {
        switch self {
        case .notJSON:
            return NSLocalizedString("Ce code ne contient pas de donnée reconnue par l’app.", comment: "Import error notJSON")
        case .unsupportedVersion:
            return NSLocalizedString("Ce partage vient d’une version plus récente de l’app. Mettez l’app à jour.", comment: "Import error version")
        case .wrongKind:
            return NSLocalizedString("Ce partage ne correspond pas à ce qui est attendu ici.", comment: "Import error wrong kind")
        case .empty:
            return NSLocalizedString("Rien à importer dans ce partage.", comment: "Import error empty")
        case .malformed:
            return NSLocalizedString("Partage illisible ou incomplet.", comment: "Import error malformed")
        }
    }
}
