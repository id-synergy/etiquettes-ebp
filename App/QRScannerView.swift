import SwiftUI
import AVFoundation
import AudioToolbox

/// Scanner de code (caméra). Deux modes :
///  - **simple** (défaut) : lit le premier code, émet un bip, puis se fige (le parent décide).
///  - **continu** (`continuous: true`) : reste actif et rappelle `onFound` à chaque NOUVELLE valeur,
///    sans bip ni fige. Il ne re-signale pas la valeur qu'il est en train de lire (même QR
///    maintenu devant la caméra) : utile pour scanner plusieurs pages à la suite sans que la
///    même page vibre/flashe en boucle. Le parent joue son propre retour sur les pages ACCEPTÉES.
///
/// Par défaut : QR seul (appairage). Pour la recherche article : QR + codes-barres EAN.
struct QRScannerView: UIViewControllerRepresentable {
    let onFound: (String) -> Void
    let onError: (String) -> Void
    var types: [AVMetadataObject.ObjectType] = [.qr]
    /// Reste actif après chaque lecture et déduplique la valeur courante (voir ci-dessus).
    var continuous = false

    /// Types utiles pour retrouver un article : QR + les codes-barres produits courants.
    static let productCodeTypes: [AVMetadataObject.ObjectType] =
        [.qr, .ean13, .ean8, .code128, .code39, .upce]

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound, continuous: continuous) }

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.coordinator = context.coordinator
        controller.onError = onError
        controller.types = types
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let onFound: (String) -> Void
        private let continuous: Bool
        private var handled = false
        /// Dernière valeur déjà signalée : tant que la caméra voit le même code, on ne rappelle pas.
        private var lastValue: String?

        init(onFound: @escaping (String) -> Void, continuous: Bool) {
            self.onFound = onFound
            self.continuous = continuous
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = object.stringValue else { return }

            if continuous {
                // Ne rien faire tant que c'est la même valeur que la dernière lue (QR maintenu).
                guard value != lastValue else { return }
                lastValue = value
                onFound(value)   // le parent décide du retour (bip/vibration) selon l'acceptation
            } else {
                guard !handled else { return }
                handled = true
                AudioServicesPlaySystemSound(1057)   // petit « bip » de confirmation
                onFound(value)
            }
        }
    }
}

/// Contrôleur caméra qui gère la session de capture et l'aperçu.
final class ScannerController: UIViewController {
    weak var coordinator: QRScannerView.Coordinator?
    var onError: ((String) -> Void)?
    var types: [AVMetadataObject.ObjectType] = [.qr]

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        requestAccessAndConfigure()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    private func requestAccessAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    granted ? self?.configure()
                            : self?.onError?(NSLocalizedString("Accès à la caméra refusé.", comment: "Camera denied"))
                }
            }
        default:
            onError?(NSLocalizedString("Accès à la caméra refusé. Activez-le dans Réglages.", comment: "Camera denied"))
        }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            onError?(NSLocalizedString("Caméra indisponible.", comment: "No camera"))
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            onError?(NSLocalizedString("Scanner indisponible.", comment: "No scanner"))
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(coordinator, queue: .main)
        // N'activer que les types réellement supportés par le périphérique (sinon exception).
        let supported = output.availableMetadataObjectTypes
        output.metadataObjectTypes = types.filter(supported.contains)

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        previewLayer = preview

        Task.detached { [session] in session.startRunning() }
    }
}
