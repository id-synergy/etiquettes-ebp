import SwiftUI

/// Import UNIVERSEL d'un partage reçu (QR simple, QR paginé reconstitué, ou fichier) : on lit le
/// JSON SANS savoir d'avance s'il contient des modèles, des réglages, ou les deux (bundle), puis on
/// applique ce qui s'y trouve. Un seul bouton « Importer » suffit côté UI.
@MainActor
enum ShareImporter {
    /// Applique un JSON de partage et renvoie un message de résultat (pour `ImportScanView`).
    static func importJSON(_ json: String,
                           templates: LabelTemplateLibraryStore,
                           setup: PrinterSetup,
                           printer: PrinterManager) -> ImportOutcome {
        guard let data = json.data(using: .utf8) else {
            return .failure(ShareDecodeError.notJSON.userMessage)
        }
        switch AnySharePayload.decode(data) {
        case .failure(let error):
            return .failure(error.userMessage)
        case .success(let payload):
            return apply(payload, templates: templates, setup: setup, printer: printer)
        }
    }

    /// Applique un payload déjà décodé (fichier ou scan) et compose un message selon ce qui a été fait.
    static func apply(_ payload: AnySharePayload,
                      templates: LabelTemplateLibraryStore,
                      setup: PrinterSetup,
                      printer: PrinterManager) -> ImportOutcome {
        switch payload {
        case .templates(let t):
            let ids = templates.importTemplates(t.templates)
            return .success(templatesMessage(ids.count))
        case .printer(let p):
            PrinterSettingsSharing.apply(p, setup: setup, printer: printer)
            return .success(NSLocalizedString("Réglages imprimante appliqués.", comment: "Printer settings applied"))
        case .bundle(let b):
            var parts: [String] = []
            if !b.templates.isEmpty {
                let ids = templates.importTemplates(b.templates)
                parts.append(templatesMessage(ids.count))
            }
            if let p = b.printer, p.hasAnySetting {
                PrinterSettingsSharing.apply(p, setup: setup, printer: printer)
                parts.append(NSLocalizedString("réglages appliqués", comment: "settings applied part"))
            }
            guard !parts.isEmpty else { return .failure(ShareDecodeError.empty.userMessage) }
            // « 2 modèle(s) importé(s) · réglages appliqués »
            return .success(parts.joined(separator: " · "))
        }
    }

    private static func templatesMessage(_ count: Int) -> String {
        String(format: NSLocalizedString("%d modèle(s) importé(s)", comment: "Imported N templates"), count)
    }
}
