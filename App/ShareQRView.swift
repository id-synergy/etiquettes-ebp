import SwiftUI

/// Feuille de PARTAGE unifiée : on lui donne le payload déjà encodé, son titre, son sous-titre et
/// les infos de fichier (nom + extension). Elle décide du transport :
/// - si le JSON tient sous `SharePayload.qrByteLimit` ET qu'on n'a pas forcé le fichier → QR à
///   l'écran, que l'autre téléphone scanne ;
/// - sinon → bouton « Partager le fichier » qui ouvre la share sheet (AirDrop, Messages…).
///
/// Esthétique Liquid Glass cohérente avec le reste de l'app (carte arrondie, QR sur fond blanc).
struct ShareQRView: View {
    let title: String
    let subtitle: String
    /// Payload JSON déjà encodé (modèles ou réglages).
    let payload: Data
    /// Nom et extension du fichier de repli (.ebplabel / .ebpprinter).
    let fileName: String
    let fileExtension: String
    /// Force le fichier (ex. partage de plusieurs modèles) même si ça tiendrait dans un QR.
    var forceFile = false
    let onClose: () -> Void

    /// QR généré UNE fois (rendu synchrone potentiellement lourd) et mis en cache, jamais recalculé
    /// à chaque passe de `body`. `nil` tant que non généré OU si le payload ne tient pas dans un QR.
    @State private var qrImage: UIImage?
    /// true dès que la tentative de génération est terminée, pour distinguer « pas encore généré »
    /// (on patiente) de « QR impossible » (on montre le repli fichier).
    @State private var qrResolved = false

    /// Le QR est envisageable si on ne force pas le fichier et que ça tient sous la limite. La
    /// génération effective (et donc le passage éventuel au repli fichier) est tranchée dans `.task`.
    private var qrEligible: Bool {
        !forceFile && payload.count <= SharePayload.qrByteLimit
    }

    private func buildQRIfNeeded() {
        guard qrEligible, let text = String(data: payload, encoding: .utf8) else {
            qrImage = nil
            qrResolved = true
            return
        }
        qrImage = QRImageRenderer.image(for: text)
        qrResolved = true
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    VStack(spacing: 8) {
                        Text(title).font(.title2.weight(.bold)).multilineTextAlignment(.center)
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 24).padding(.top, 8)

                    if let qrImage {
                        qrCard(qrImage)
                        Text(NSLocalizedString("Scannez ce QR code depuis l’autre téléphone, via « Importer » dans l’app.", comment: "Share QR hint"))
                            .font(.footnote).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).padding(.horizontal, 32)
                        fileButton(label: NSLocalizedString("Partager par fichier (AirDrop…)", comment: "Share file alt"),
                                   prominent: false)
                    } else if qrResolved {
                        fileCard
                        fileButton(label: NSLocalizedString("Partager le fichier", comment: "Share file"),
                                   prominent: true)
                    } else {
                        ProgressView().padding(.top, 40)
                    }
                }
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(NSLocalizedString("Partager", comment: "Share title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button(NSLocalizedString("Fermer", comment: "Close"), action: onClose) }
            .task { buildQRIfNeeded() }
        }
    }

    private func qrCard(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .interpolation(.none)
            .resizable()
            .scaledToFit()
            .frame(width: 240, height: 240)
            .padding(18)
            .background(.white, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(.separator), lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 12, y: 6)
            .padding(.horizontal, 24)
    }

    private var fileCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.badge.arrow.up")
                .font(.system(size: 44)).foregroundStyle(.tint)
            Text(NSLocalizedString("Trop volumineux pour un QR code", comment: "Too big for QR"))
                .font(.headline)
            Text(NSLocalizedString("Le partage se fait par un fichier à envoyer à l’autre téléphone (AirDrop, Messages…). Il l’ouvre pour importer.", comment: "File share explain"))
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private func fileButton(label: String, prominent: Bool) -> some View {
        let action = {
            guard let url = ShareFileWriter.write(payload, name: fileName, ext: fileExtension) else { return }
            ActivityPresenter.present([url])
        }
        let content = Label(label, systemImage: "square.and.arrow.up")
            .font(.headline)
            .frame(maxWidth: prominent ? .infinity : nil)
            .padding(.vertical, prominent ? 6 : 2)
        Group {
            if prominent {
                Button(action: action) { content }.buttonStyle(.borderedProminent)
            } else {
                Button(action: action) { content }.buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
    }
}
