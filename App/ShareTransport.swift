import SwiftUI
import UniformTypeIdentifiers

// MARK: - Types de documents partagés (UTI)

/// Types de fichiers d'échange, déclarés comme UTI exportés dans l'Info.plist pour qu'iOS propose
/// l'app à la réception d'un .ebplabel / .ebpprinter (AirDrop, Messages, Fichiers…).
enum ShareDocumentType {
    /// Un ou plusieurs modèles d'étiquette.
    static let template = UTType(exportedAs: "tech.idsynergy.etiquettes-ebp.label", conformingTo: .json)
    /// Des réglages d'imprimante.
    static let printer = UTType(exportedAs: "tech.idsynergy.etiquettes-ebp.printer", conformingTo: .json)
    /// Export combiné : modèles + réglages.
    static let bundle = UTType(exportedAs: "tech.idsynergy.etiquettes-ebp.bundle", conformingTo: .json)

    static let templateExtension = "ebplabel"
    static let printerExtension = "ebpprinter"
    static let bundleExtension = "ebpall"
}

// MARK: - Génération d'une image QR

/// Transforme la grille de modules de `QRCode` (LabelCore) en `UIImage` nette pour l'affichage à
/// l'écran. Chaque module devient un carré plein ; `interpolation(.none)` côté SwiftUI garde les
/// bords francs. Réutilise le moteur QR existant — aucune lib tierce.
enum QRImageRenderer {
    /// Image QR carrée (modules noirs sur fond blanc) pour `string`, ou nil si la génération échoue
    /// (chaîne vide, contenu trop volumineux pour un QR).
    static func image(for string: String, scale: Int = 10) -> UIImage? {
        let grid = QRCode.modules(for: string)
        guard let rows = grid.first?.count, rows > 0, !grid.isEmpty else { return nil }
        let count = grid.count
        let side = count * max(1, scale)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            UIColor.black.setFill()
            let s = CGFloat(max(1, scale))
            for (y, row) in grid.enumerated() {
                for (x, on) in row.enumerated() where on {
                    context.fill(CGRect(x: CGFloat(x) * s, y: CGFloat(y) * s, width: s, height: s))
                }
            }
        }
    }
}

// MARK: - Share sheet iOS

/// Présente la share sheet AirDrop directement en UIKit, sur le contrôleur le plus haut.
///
/// On n'ouvre PAS `UIActivityViewController` via une `.sheet` SwiftUI imbriquée dans une feuille
/// déjà présentée (ShareQRView) : cette imbrication ne présentait pas la share sheet de façon
/// fiable (elle ne s'ouvrait pas, ou se refermait aussitôt). Présenter le contrôleur UIKit sur la
/// vue déjà à l'écran règle le cas, et configure le popover requis sur iPad (sinon : crash).
@MainActor
enum ActivityPresenter {
    static func present(_ items: [Any]) {
        guard let top = topViewController() else { return }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // iPad : une share sheet sans source de popover lève une exception. On l'ancre au centre
        // de la vue présentatrice (aucune vue source précise à ce stade).
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY,
                                        width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
    }

    /// Le contrôleur le plus haut de la scène active (au-dessus des feuilles déjà présentées).
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard var top = scene?.keyWindow?.rootViewController
                ?? scene?.windows.first(where: \.isKeyWindow)?.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}

// MARK: - Écriture d'un fichier d'échange temporaire

/// Écrit le payload encodé dans un fichier temporaire au bon suffixe, pour le passer à la share
/// sheet. Le nom est lisible (sert de nom de fichier chez le destinataire).
enum ShareFileWriter {
    /// Écrit `data` dans un fichier temporaire `<nom>.<ext>` et renvoie son URL, ou nil si l'écriture
    /// échoue. Un fichier du même nom est remplacé (export répété).
    static func write(_ data: Data, name: String, ext: String) -> URL? {
        let safeName = sanitized(name)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(safeName)
            .appendingPathExtension(ext)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Nom de fichier sûr : on retire les séparateurs de chemin et on borne la longueur.
    private static func sanitized(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? NSLocalizedString("Partage", comment: "Default share file name") : trimmed
        let cleaned = base.replacingOccurrences(of: "/", with: "-")
                          .replacingOccurrences(of: ":", with: "-")
        return String(cleaned.prefix(60))
    }
}

// MARK: - Ouverture d'un fichier reçu

/// Importe un fichier .ebplabel / .ebpprinter / .ebpall reçu (AirDrop, Messages, Fichiers…). Le type
/// réel est lu dans le JSON (champ `kind`), pas déduit de l'extension : modèles, réglages ou export
/// combiné sont appliqués par le même import universel. Ne lève jamais : un fichier illisible donne
/// un message, pas un crash.
@MainActor
enum ShareFileImporter {
    static func open(_ url: URL, templates: LabelTemplateLibraryStore,
                     setup: PrinterSetup, printer: PrinterManager) -> String {
        // Un fichier reçu peut être « sécurisé » (hors du conteneur de l'app).
        let needsAccess = url.startAccessingSecurityScopedResource()
        defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url),
              let json = String(data: data, encoding: .utf8) else {
            return NSLocalizedString("Fichier illisible.", comment: "Unreadable file")
        }
        return ShareImporter.importJSON(json, templates: templates, setup: setup, printer: printer).message
    }
}
