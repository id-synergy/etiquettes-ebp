import Foundation

/// Format d'ÉCHANGE entre téléphones, versionné, pour partager des MODÈLES d'étiquette et des
/// RÉGLAGES d'imprimante. Pur (aucune dépendance UIKit/SwiftUI), donc testable et partagé entre
/// la lib et l'app.
///
/// Le payload s'encode en JSON compact. Deux transports selon la taille :
/// - QR CODE si le JSON tient sous une limite prudente de scannabilité (`qrByteLimit`) ;
/// - FICHIER (.ebplabel / .ebpprinter) partagé via la share sheet (AirDrop…) sinon, ou dès
///   qu'on partage plusieurs modèles à la fois.
///
/// Compat future : le champ `version` est le premier décodé. Une version inconnue est rejetée
/// proprement (`ShareDecodeError.unsupportedVersion`) plutôt que de risquer un décodage partiel.
public enum SharePayload {
    /// Version courante du format d'échange. À incrémenter si la structure change de façon
    /// non rétro-compatible ; les décodeurs refusent toute version strictement supérieure.
    public static let currentVersion = 1

    /// Limite prudente de la charge utile encodable en QR : au-delà, on bascule sur un fichier.
    /// `CIQRCodeGenerator` accepte techniquement jusqu'à ~2,9 Ko, mais le QR devient alors immense
    /// (≈ 150 modules de côté) et illisible à l'écran d'un téléphone. On plafonne donc à une taille
    /// réellement SCANNABLE : 512 octets ≈ un QR de ~73 modules, confortable à viser. Un payload
    /// plus gros (un modèle d'étiquette complet fait ~1,9 Ko) bascule sur le fichier (AirDrop…).
    public static let qrByteLimit = 512

    /// Type de contenu partagé, pour contrôler qu'un fichier reçu correspond bien à ce qu'on
    /// attend (un .ebplabel n'applique pas des réglages imprimante, et inversement).
    public enum Kind: String, Codable, Sendable {
        case templates   // un ou plusieurs modèles d'étiquette
        case printer     // des réglages d'imprimante
        case bundle      // modèles ET réglages réunis (export « tout »)
    }
}

// MARK: - Erreurs de décodage

/// Échec d'import, formulé pour un message clair à l'utilisateur (jamais un crash).
public enum ShareDecodeError: Error, Equatable, Sendable {
    case notJSON                     // contenu illisible (QR d'autre chose, fichier corrompu)
    case unsupportedVersion(Int)     // format produit par une version plus récente de l'app
    case wrongKind                   // un .ebplabel là où on attendait des réglages, ou l'inverse
    case empty                       // aucun modèle / aucun réglage dans le payload
    case malformed(String)           // JSON valide mais structure inattendue
}

// MARK: - Partage de modèles

/// Enveloppe d'échange d'un ou plusieurs MODÈLES d'étiquette.
public struct TemplateSharePayload: Codable, Equatable {
    public var version: Int
    public var kind: SharePayload.Kind
    public var templates: [LabelTemplate]

    public init(templates: [LabelTemplate], version: Int = SharePayload.currentVersion) {
        self.version = version
        self.kind = .templates
        // Un modèle partagé devient TOUJOURS un modèle perso éditable : jamais verrouillé.
        self.templates = templates.map { Self.unlocked($0) }
    }

    /// Un modèle verrouillé (preset) matérialisé en modèle perso éditable pour le partage :
    /// on fige ses lignes de référence et on lève le verrou (l'autre appareil doit pouvoir l'éditer).
    private static func unlocked(_ template: LabelTemplate) -> LabelTemplate {
        guard template.isLocked else { return template }
        return LabelTemplate(id: template.id, name: template.name, isLocked: false,
                             baseArrangement: nil, lines: template.materializedLines())
    }

    /// JSON compact prêt à encoder en QR ou à écrire dans un fichier .ebplabel.
    public func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    /// Décode et VALIDE un payload de modèles. Rejette proprement : non-JSON, version inconnue,
    /// mauvais type, liste vide.
    public static func decode(_ data: Data) -> Result<TemplateSharePayload, ShareDecodeError> {
        decodeValidatingVersion(data, expectedKind: .templates) { (payload: TemplateSharePayload) in
            payload.templates.isEmpty ? .failure(.empty) : .success(payload)
        }
    }

    public static func decode(fromQRString raw: String) -> Result<TemplateSharePayload, ShareDecodeError> {
        guard let data = raw.data(using: .utf8) else { return .failure(.notJSON) }
        return decode(data)
    }
}

// MARK: - Partage de réglages imprimante

/// CONFIG d'imprimante transférable d'un appareil à l'autre : le modèle, le papier, la coupe,
/// la qualité, les réglages thermiques — PAS l'appairage Bluetooth ni l'identité d'une imprimante
/// précise (son UUID BLE, son IP, son alias), qui sont propres à chaque appareil.
///
/// Tous les champs sont optionnels et décodés en tolérant : un appareil qui ne gère pas encore un
/// réglage l'ignore sans faire échouer l'import des autres.
public struct PrinterSettingsPayload: Codable, Equatable, Sendable {
    public var version: Int
    public var kind: SharePayload.Kind

    /// Marque sélectionnée (pocket5890 / brother / netum).
    public var brand: PrinterBrand?
    /// Modèle Brother choisi.
    public var brotherModel: BrotherModel?
    /// Papier Brother (étiquette DK, ruban, feuille, papier personnalisé…).
    public var brotherMedia: BrotherMedia?
    public var brotherCut: BrotherCutOptions?
    public var brotherQuality: BrotherQualityOptions?
    /// Préférence d'interface Brother (ble / wifi) — une préférence, pas une adresse.
    public var brotherConnection: BrotherConnection?
    /// Nombre de copies (Brother).
    public var copies: Int?

    /// Réglages NETUM (papier, coupe, bip, marges, transport…).
    public var netum: NetumOptions?

    /// Réglages thermiques de la Pocket 5890.
    public var pocketDensityValue: UInt8?
    public var pocketLeadingFeedDots: Int?
    public var pocketTrailingFeedDots: Int?
    public var pocketRotate180: Bool?

    public init(version: Int = SharePayload.currentVersion,
                brand: PrinterBrand? = nil,
                brotherModel: BrotherModel? = nil,
                brotherMedia: BrotherMedia? = nil,
                brotherCut: BrotherCutOptions? = nil,
                brotherQuality: BrotherQualityOptions? = nil,
                brotherConnection: BrotherConnection? = nil,
                copies: Int? = nil,
                netum: NetumOptions? = nil,
                pocketDensityValue: UInt8? = nil,
                pocketLeadingFeedDots: Int? = nil,
                pocketTrailingFeedDots: Int? = nil,
                pocketRotate180: Bool? = nil) {
        self.version = version
        self.kind = .printer
        self.brand = brand
        self.brotherModel = brotherModel
        self.brotherMedia = brotherMedia
        self.brotherCut = brotherCut
        self.brotherQuality = brotherQuality
        self.brotherConnection = brotherConnection
        self.copies = copies
        self.netum = netum
        self.pocketDensityValue = pocketDensityValue
        self.pocketLeadingFeedDots = pocketLeadingFeedDots
        self.pocketTrailingFeedDots = pocketTrailingFeedDots
        self.pocketRotate180 = pocketRotate180
    }

    private enum CodingKeys: String, CodingKey {
        case version, kind, brand, brotherModel, brotherMedia, brotherCut, brotherQuality
        case brotherConnection, copies, netum
        case pocketDensityValue, pocketLeadingFeedDots, pocketTrailingFeedDots, pocketRotate180
    }

    /// Décodage tolérant : la version et le type sont stricts, mais chaque réglage absent/illisible
    /// retombe sur nil sans faire échouer les autres.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        kind = (try? c.decode(SharePayload.Kind.self, forKey: .kind)) ?? .printer
        brand = try? c.decodeIfPresent(PrinterBrand.self, forKey: .brand)
        brotherModel = try? c.decodeIfPresent(BrotherModel.self, forKey: .brotherModel)
        brotherMedia = try? c.decodeIfPresent(BrotherMedia.self, forKey: .brotherMedia)
        brotherCut = try? c.decodeIfPresent(BrotherCutOptions.self, forKey: .brotherCut)
        brotherQuality = try? c.decodeIfPresent(BrotherQualityOptions.self, forKey: .brotherQuality)
        brotherConnection = try? c.decodeIfPresent(BrotherConnection.self, forKey: .brotherConnection)
        copies = try? c.decodeIfPresent(Int.self, forKey: .copies)
        netum = try? c.decodeIfPresent(NetumOptions.self, forKey: .netum)
        pocketDensityValue = try? c.decodeIfPresent(UInt8.self, forKey: .pocketDensityValue)
        pocketLeadingFeedDots = try? c.decodeIfPresent(Int.self, forKey: .pocketLeadingFeedDots)
        pocketTrailingFeedDots = try? c.decodeIfPresent(Int.self, forKey: .pocketTrailingFeedDots)
        pocketRotate180 = try? c.decodeIfPresent(Bool.self, forKey: .pocketRotate180)
    }

    /// true s'il reste au moins un réglage à appliquer (sinon l'import n'a rien à faire).
    public var hasAnySetting: Bool {
        brand != nil || brotherModel != nil || brotherMedia != nil || brotherCut != nil
            || brotherQuality != nil || brotherConnection != nil || copies != nil || netum != nil
            || pocketDensityValue != nil || pocketLeadingFeedDots != nil
            || pocketTrailingFeedDots != nil || pocketRotate180 != nil
    }

    /// JSON compact prêt à encoder en QR ou à écrire dans un fichier .ebpprinter.
    public func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    public static func decode(_ data: Data) -> Result<PrinterSettingsPayload, ShareDecodeError> {
        decodeValidatingVersion(data, expectedKind: .printer) { (payload: PrinterSettingsPayload) in
            payload.hasAnySetting ? .success(payload) : .failure(.empty)
        }
    }

    public static func decode(fromQRString raw: String) -> Result<PrinterSettingsPayload, ShareDecodeError> {
        guard let data = raw.data(using: .utf8) else { return .failure(.notJSON) }
        return decode(data)
    }
}

// MARK: - Partage combiné (modèles + réglages)

/// Export « TOUT » : réunit les MODÈLES d'étiquette et les RÉGLAGES d'imprimante dans un seul
/// payload, pour tout transférer en une fois (un QR/fichier, un seul import). Les deux parties sont
/// optionnelles et décodées en tolérant : un bundle sans modèles n'applique que les réglages, et
/// inversement.
public struct CombinedSharePayload: Codable, Equatable {
    public var version: Int
    public var kind: SharePayload.Kind
    public var templates: [LabelTemplate]
    public var printer: PrinterSettingsPayload?

    public init(templates: [LabelTemplate], printer: PrinterSettingsPayload?,
                version: Int = SharePayload.currentVersion) {
        self.version = version
        self.kind = .bundle
        self.templates = templates.map { TemplateSharePayload(templates: [$0]).templates[0] }
        self.printer = printer
    }

    private enum CodingKeys: String, CodingKey { case version, kind, templates, printer }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        kind = (try? c.decode(SharePayload.Kind.self, forKey: .kind)) ?? .bundle
        templates = (try? c.decodeIfPresent([LabelTemplate].self, forKey: .templates)) ?? []
        printer = try? c.decodeIfPresent(PrinterSettingsPayload.self, forKey: .printer)
    }

    /// true si le bundle contient au moins une chose à appliquer.
    public var hasAnything: Bool {
        !templates.isEmpty || (printer?.hasAnySetting ?? false)
    }

    public func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    public static func decode(_ data: Data) -> Result<CombinedSharePayload, ShareDecodeError> {
        decodeValidatingVersion(data, expectedKind: .bundle) { (payload: CombinedSharePayload) in
            payload.hasAnything ? .success(payload) : .failure(.empty)
        }
    }
}

/// Un partage reçu, quel que soit son type : l'import universel route selon le `kind` lu.
public enum AnySharePayload {
    case templates(TemplateSharePayload)
    case printer(PrinterSettingsPayload)
    case bundle(CombinedSharePayload)

    /// Décode un JSON de partage SANS connaître son type à l'avance : lit `kind`, puis décode et
    /// valide la bonne structure. Sert à l'import universel (un seul bouton « Importer »).
    public static func decode(_ data: Data) -> Result<AnySharePayload, ShareDecodeError> {
        guard let header = try? JSONDecoder().decode(ShareEnvelopeHeader.self, from: data) else {
            return .failure(.notJSON)
        }
        switch header.kind {
        case .templates: return TemplateSharePayload.decode(data).map(AnySharePayload.templates)
        case .printer:   return PrinterSettingsPayload.decode(data).map(AnySharePayload.printer)
        case .bundle:    return CombinedSharePayload.decode(data).map(AnySharePayload.bundle)
        case .none:      return .failure(.malformed("type de partage absent"))
        }
    }

    public static func decode(fromQRString raw: String) -> Result<AnySharePayload, ShareDecodeError> {
        guard let data = raw.data(using: .utf8) else { return .failure(.notJSON) }
        return decode(data)
    }
}

// MARK: - Décodage versionné commun

/// En-tête minimal lu AVANT tout : on vérifie la version et le type avant de tenter le décodage
/// complet, pour rejeter proprement un payload d'une version plus récente ou d'un autre type.
private struct ShareEnvelopeHeader: Decodable {
    let version: Int
    let kind: SharePayload.Kind?
}

/// Décode `data` en validant d'abord la version (refus si > version courante) puis le type attendu,
/// avant de décoder le payload complet et d'appliquer une validation finale (`validate`).
private func decodeValidatingVersion<Payload: Decodable>(
    _ data: Data,
    expectedKind: SharePayload.Kind,
    _ validate: (Payload) -> Result<Payload, ShareDecodeError>
) -> Result<Payload, ShareDecodeError> {
    let decoder = JSONDecoder()
    guard let header = try? decoder.decode(ShareEnvelopeHeader.self, from: data) else {
        return .failure(.notJSON)
    }
    guard header.version <= SharePayload.currentVersion, header.version >= 1 else {
        return .failure(.unsupportedVersion(header.version))
    }
    if let kind = header.kind, kind != expectedKind {
        return .failure(.wrongKind)
    }
    guard let payload = try? decoder.decode(Payload.self, from: data) else {
        return .failure(.malformed("structure inattendue"))
    }
    return validate(payload)
}
