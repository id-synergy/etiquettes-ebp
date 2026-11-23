import Foundation

/// Modèle d'étiquette configurable : une PILE DE LIGNES ordonnées. Chaque ligne est pleine
/// largeur (une cellule) ou en deux colonnes (deux cellules). Chaque cellule affiche un
/// contenu (champ de l'article, texte libre, code-barres, date…) avec un style.
///
/// Il remplace le couple figé (LabelSize + LabelArrangement codé en dur). La largeur physique
/// reste 48 mm et la hauteur suit la taille physique (`LabelSize`), toutes deux séparées.
///
/// Deux familles cohabitent :
/// - PRESETS D'USINE (`isLocked == true`) : les six dispositions historiques. Verrouillés,
///   non supprimables, lecture seule. Leur rendu délègue au moteur historique par
///   `LabelArrangement` (pixel-identique à l'existant). Pour les adapter, on les DUPLIQUE.
/// - MODÈLES PERSO (`isLocked == false`) : éditables, rendus par le moteur lignes/colonnes.
public struct LabelTemplate: Codable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    /// true pour un preset d'usine : lecture seule, non supprimable.
    public var isLocked: Bool
    /// Pour un preset d'usine, l'arrangement historique rendu par `LabelRenderer`.
    /// nil pour un modèle perso (rendu par le moteur de lignes).
    public var baseArrangement: LabelArrangement?
    /// Lignes ordonnées : l'ordre détermine l'ordre vertical de rendu (modèles perso).
    public var lines: [TemplateLine]

    public init(id: UUID = UUID(), name: String, isLocked: Bool = false,
                baseArrangement: LabelArrangement? = nil, lines: [TemplateLine] = []) {
        self.id = id
        self.name = name
        self.isLocked = isLocked
        self.baseArrangement = baseArrangement
        self.lines = lines
    }

    private enum CodingKeys: String, CodingKey { case id, name, isLocked, baseArrangement, lines }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        isLocked = try values.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        baseArrangement = try values.decodeIfPresent(LabelArrangement.self, forKey: .baseArrangement)
        lines = try values.decodeIfPresent([TemplateLine].self, forKey: .lines) ?? []
    }

    /// Crée une copie éditable (modèle perso) de ce modèle. Un preset verrouillé est
    /// matérialisé en lignes concrètes pour être modifié librement.
    public func duplicated(named newName: String) -> LabelTemplate {
        LabelTemplate(id: UUID(), name: newName, isLocked: false,
                      baseArrangement: nil, lines: materializedLines())
    }

    /// Les lignes effectives à éditer/rendre : celles du modèle, ou les lignes de référence
    /// dérivées de l'arrangement de base pour un preset d'usine.
    public func materializedLines() -> [TemplateLine] {
        if !lines.isEmpty { return lines }
        if let baseArrangement { return TemplateLine.referenceLines(for: baseArrangement) }
        return TemplateLine.referenceLines(for: .current)
    }

    /// Signature stable du CONTENU rendu du modèle : tout ce qui change le rendu (arrangement de
    /// base, disposition des lignes, et pour chaque cellule : contenu, style, préfixe/suffixe,
    /// placeholder, mode de rendu du code). Sert à bâtir une clé de cache qui se renouvelle dès
    /// qu'une cellule change — y compris une modif qui ne touche pas le nombre de lignes (sinon
    /// la miniature resterait figée : bug d'aperçu déjà rencontré).
    public var contentSignature: Int {
        var hasher = Hasher()
        hasher.combine(baseArrangement)
        for line in lines {
            hasher.combine(line.layout)
            for cell in line.cells {
                hasher.combine(cell.content)
                hasher.combine(cell.style)
                hasher.combine(cell.prefix)
                hasher.combine(cell.suffix)
                hasher.combine(cell.placeholder)
                hasher.combine(cell.codeRendering)
                hasher.combine(cell.symbology)
                hasher.combine(cell.codeOptions)
            }
        }
        return hasher.finalize()
    }

    /// Clé de cache d'une miniature : identité + taille + largeur + signature de l'étiquette
    /// source + signature du contenu du modèle. Pure et testable. Toute modif du modèle OU de
    /// l'étiquette renouvelle la clé → `.task(id:)` relancé, pas de spinner figé ni d'aperçu périmé.
    public func thumbnailKey(forLabelSignature labelSignature: Int, size: LabelSize, width: Int) -> String {
        "\(id.uuidString).\(size.rawValue).\(width).\(labelSignature).\(contentSignature)"
    }
}

/// Une ligne du modèle : pleine largeur (1 cellule) ou deux colonnes (2 cellules).
public struct TemplateLine: Codable, Equatable, Identifiable, Hashable {
    public enum Layout: String, Codable, CaseIterable, Hashable {
        case full, twoColumns
        public var title: String {
            switch self {
            case .full: NSLocalizedString("Pleine largeur", comment: "Line layout")
            case .twoColumns: NSLocalizedString("Deux colonnes", comment: "Line layout")
            }
        }
    }

    public var id: UUID
    public var layout: Layout
    public var cells: [TemplateCell]

    public init(id: UUID = UUID(), layout: Layout = .full, cells: [TemplateCell]) {
        self.id = id
        self.layout = layout
        // Normalise : 1 cellule en pleine largeur, 2 en deux colonnes.
        self.cells = TemplateLine.normalized(cells, for: layout)
    }

    private enum CodingKeys: String, CodingKey { case id, layout, cells }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        layout = try values.decodeIfPresent(Layout.self, forKey: .layout) ?? .full
        let decodedCells = try values.decodeIfPresent([TemplateCell].self, forKey: .cells) ?? []
        cells = TemplateLine.normalized(decodedCells, for: layout)
    }

    /// Garantit le bon nombre de cellules selon la disposition (1 pleine, 2 colonnes).
    static func normalized(_ cells: [TemplateCell], for layout: Layout) -> [TemplateCell] {
        switch layout {
        case .full:
            return [cells.first ?? TemplateCell(content: .vide)]
        case .twoColumns:
            let left = cells.first ?? TemplateCell(content: .vide, style: CellStyle(alignH: .leading))
            let right = cells.dropFirst().first ?? TemplateCell(content: .vide, style: CellStyle(alignH: .trailing))
            return [left, right]
        }
    }

    /// Bascule la disposition d'une ligne en conservant au mieux les cellules.
    public func toggledLayout() -> TemplateLine {
        switch layout {
        case .full:
            let keep = cells.first ?? TemplateCell(content: .vide)
            return TemplateLine(id: id, layout: .twoColumns,
                                cells: [keep, TemplateCell(content: .vide, style: CellStyle(alignH: .trailing))])
        case .twoColumns:
            return TemplateLine(id: id, layout: .full, cells: [cells.first ?? TemplateCell(content: .vide)])
        }
    }

    public static func full(_ cell: TemplateCell) -> TemplateLine {
        TemplateLine(layout: .full, cells: [cell])
    }
    public static func columns(_ left: TemplateCell, _ right: TemplateCell) -> TemplateLine {
        TemplateLine(layout: .twoColumns, cells: [left, right])
    }
}

/// Mode de rendu d'une cellule qui porte un code (code-barres par défaut) : barres EAN-13
/// linéaires, ou QR code. Le QR encode la valeur de la cellule et se redimensionne pour tenir
/// dans sa cellule, comme les barres.
public enum CodeRendering: String, Codable, CaseIterable, Hashable {
    case barcode   // code-barres linéaire (symbologie : voir BarcodeSymbology)
    case qr        // QR code (CoreImage)
    public var title: String {
        switch self {
        case .barcode: NSLocalizedString("Code-barres", comment: "Code rendering")
        case .qr: NSLocalizedString("QR", comment: "Code rendering")
        }
    }
}

/// Symbologie d'un code-barres LINÉAIRE (mode `CodeRendering.barcode`). EAN-13 reste le défaut
/// historique. Les familles EAN/UPC n'encodent que des chiffres et portent une checksum ; Code 128
/// et Code 39 encodent de l'alphanumérique. Une valeur non encodable dans la symbologie choisie
/// bascule proprement en QR au rendu (repli), comme un code libre non-EAN le faisait déjà.
public enum BarcodeSymbology: String, Codable, CaseIterable, Hashable {
    case ean13     // 12 ou 13 chiffres, checksum (historique)
    case ean8      // 7 ou 8 chiffres, checksum
    case upca      // 11 ou 12 chiffres, checksum (EAN-13 à préfixe 0, convention US)
    case code128   // alphanumérique, compact (CoreImage)
    case code39    // alphanumérique, historique industriel

    public var title: String {
        switch self {
        case .ean13: NSLocalizedString("EAN-13", comment: "Barcode symbology")
        case .ean8: NSLocalizedString("EAN-8", comment: "Barcode symbology")
        case .upca: NSLocalizedString("UPC-A", comment: "Barcode symbology")
        case .code128: NSLocalizedString("Code 128", comment: "Barcode symbology")
        case .code39: NSLocalizedString("Code 39", comment: "Barcode symbology")
        }
    }

    /// Vrai pour les symbologies de la famille EAN/UPC : chiffres uniquement, checksum, chiffres
    /// lisibles découpés en groupes sous les barres, gardes allongées, et options `CodeOptions`
    /// pertinentes (chevron, 1er chiffre déporté).
    public var isEANFamily: Bool {
        switch self {
        case .ean13, .ean8, .upca: return true
        case .code128, .code39: return false
        }
    }
}

/// Options d'apparence d'un code-barres linéaire (surtout EAN/UPC). Les défauts reproduisent le
/// rendu d'une étiquette EBP : chevron de marge `>`, 1er chiffre déporté à gauche, chiffres SOUS
/// les barres (un code-barres a toujours son texte dessous — il n'y a pas d'option « au-dessus »).
/// Les options non pertinentes pour une symbologie donnée sont ignorées (ex. le 1er chiffre déporté
/// n'a de sens que pour EAN-13/UPC-A).
public struct CodeOptions: Codable, Equatable, Hashable {
    /// Affiche les chiffres lisibles sous les barres. false = code-barres nu.
    public var showText: Bool
    /// Affiche le chevron `>` (light margin indicator) après la garde de fin (EAN/UPC).
    public var showChevron: Bool
    /// Affiche le 1er chiffre déporté à gauche, hors de la zone de barres (EAN-13/UPC-A).
    public var showFirstDigit: Bool
    /// Fait déborder le code sur TOUTE la largeur de l'étiquette, même quand la ligne est en deux
    /// colonnes : le code gagne en largeur (donc en modules px, donc en fiabilité de lecture).
    /// Utile pour les codes longs (Code 128 / Code 39) à l'étroit dans une demi-colonne.
    public var fullWidth: Bool

    public init(showText: Bool = true, showChevron: Bool = true, showFirstDigit: Bool = true,
                fullWidth: Bool = false) {
        self.showText = showText
        self.showChevron = showChevron
        self.showFirstDigit = showFirstDigit
        self.fullWidth = fullWidth
    }

    /// Défaut « étiquette EBP » (toutes options actives).
    public static let ebp = CodeOptions()

    private enum CodingKeys: String, CodingKey { case showText, showChevron, showFirstDigit, fullWidth }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        showText = try values.decodeIfPresent(Bool.self, forKey: .showText) ?? true
        showChevron = try values.decodeIfPresent(Bool.self, forKey: .showChevron) ?? true
        showFirstDigit = try values.decodeIfPresent(Bool.self, forKey: .showFirstDigit) ?? true
        fullWidth = try values.decodeIfPresent(Bool.self, forKey: .fullWidth) ?? false
    }
}

/// Une cellule : un contenu, son style, et des décorations optionnelles (préfixe/suffixe,
/// placeholder, mode de rendu d'un code).
public struct TemplateCell: Codable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var content: CellContent
    public var style: CellStyle
    /// Texte libre affiché AVANT la valeur rendue (ex. « Réf. »). Vide = aucun.
    public var prefix: String
    /// Texte libre affiché APRÈS la valeur rendue (ex. « kg »). Vide = aucun.
    public var suffix: String
    /// Valeur de repli affichée quand le champ bindé est vide/nul (ex. « — »). Vide = la cellule
    /// reste vide quand la valeur manque.
    public var placeholder: String
    /// Mode de rendu quand le contenu est un code (code-barres par défaut) : linéaire ou QR.
    public var codeRendering: CodeRendering
    /// Symbologie du code-barres linéaire (EAN-13 par défaut). Ignorée en mode QR.
    public var symbology: BarcodeSymbology
    /// Options d'apparence du code-barres linéaire (chevron, 1er chiffre, position des chiffres).
    public var codeOptions: CodeOptions

    public init(id: UUID = UUID(), content: CellContent, style: CellStyle = CellStyle(),
                prefix: String = "", suffix: String = "", placeholder: String = "",
                codeRendering: CodeRendering = .barcode,
                symbology: BarcodeSymbology = .ean13,
                codeOptions: CodeOptions = .ebp) {
        self.id = id
        self.content = content
        self.style = style
        self.prefix = prefix
        self.suffix = suffix
        self.placeholder = placeholder
        self.codeRendering = codeRendering
        self.symbology = symbology
        self.codeOptions = codeOptions
    }

    private enum CodingKeys: String, CodingKey {
        case id, content, style, prefix, suffix, placeholder, codeRendering, symbology, codeOptions
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        content = try values.decode(CellContent.self, forKey: .content)
        style = try values.decodeIfPresent(CellStyle.self, forKey: .style) ?? CellStyle()
        prefix = try values.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        suffix = try values.decodeIfPresent(String.self, forKey: .suffix) ?? ""
        placeholder = try values.decodeIfPresent(String.self, forKey: .placeholder) ?? ""
        codeRendering = try values.decodeIfPresent(CodeRendering.self, forKey: .codeRendering) ?? .barcode
        symbology = try values.decodeIfPresent(BarcodeSymbology.self, forKey: .symbology) ?? .ean13
        codeOptions = try values.decodeIfPresent(CodeOptions.self, forKey: .codeOptions) ?? .ebp
    }

    /// Vrai si cette cellule doit être rendue en QR code (contenu de type code + mode QR).
    public var rendersAsQR: Bool { content.isBarcode && codeRendering == .qr }

    /// Texte final à afficher pour cette cellule, décorations appliquées, à partir de la valeur
    /// brute du champ bindé. Règle : si la valeur est présente → préfixe + valeur + suffixe ;
    /// si elle est absente (nil/vide) → le placeholder SEUL (sans préfixe/suffixe, car il n'a de
    /// sens qu'autour d'une vraie valeur). nil si aucune valeur et aucun placeholder.
    public func decoratedText(for label: ProductLabel, formattedPrice: String?) -> String? {
        let raw = content.text(for: label, formattedPrice: formattedPrice)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw, !raw.isEmpty {
            return prefix + raw + suffix
        }
        let fallback = placeholder.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? nil : fallback
    }

    /// Valeur à encoder dans le code (barres ou QR) d'une cellule de type code : l'EAN de
    /// l'article (`codeBarres`) ou la valeur saisie (`codeLibre`). nil pour tout autre contenu.
    /// Non décorée du préfixe/suffixe : ceux-ci entourent un texte lisible, pas une valeur encodée.
    public func codePayload(for label: ProductLabel) -> String? {
        content.codeValue(for: label)
    }
}

/// Contenu d'une cellule : un champ de l'article, un texte libre, le code-barres, ou vide.
public enum CellContent: Codable, Equatable, Hashable {
    case vide
    case designation      // ProductLabel.name
    case refArticle       // ProductLabel.productReference
    case refRayon         // ProductLabel.shelfReference
    case famille          // ProductLabel.category
    case prixTTC          // ProductLabel.price + currency, avec priceCaption
    case prixHT           // ProductLabel.priceExclVat (SalePriceVatExcluded, formaté monnaie)
    case montantTVA       // ProductLabel.vatAmount (VatAmount, formaté monnaie)
    case stockReel        // ProductLabel.realStock (RealStock, quantité nettoyée)
    case stockDispo       // ProductLabel.virtualStock (VirtualStock, quantité nettoyée)
    case sousFamille      // ProductLabel.subFamily (SubFamilyId)
    case fournisseur      // ProductLabel.supplier (SupplierId)
    case unite            // ProductLabel.unit (UnitId)
    case poids            // ProductLabel.weight (Weight, quantité nettoyée)
    case volume           // ProductLabel.volume (Volume, quantité nettoyée)
    case codeBarres       // ProductLabel.ean (EAN13 ou QR, redimensionné dans la cellule)
    case codeLibre(String) // valeur saisie, rendue en code visuel (EAN13 ou QR selon codeRendering)
    case dateGeneration(String?)  // ProductLabel.generatedAt ; pattern DateFormatter (nil = défaut)
    case texteLibre(String)

    /// Cas « simples » pour alimenter les sélecteurs (date au format par défaut, texte/code vides).
    public static var selectableKinds: [CellContent] {
        [.vide, .designation, .refArticle, .refRayon, .famille,
         .prixTTC, .prixHT, .montantTVA, .stockReel, .stockDispo,
         .sousFamille, .fournisseur, .unite, .poids, .volume,
         .codeBarres, .codeLibre(""), .dateGeneration(nil), .texteLibre("")]
    }

    public var title: String {
        switch self {
        case .vide: NSLocalizedString("Vide", comment: "Cell content")
        case .designation: NSLocalizedString("Désignation", comment: "Cell content")
        case .refArticle: NSLocalizedString("Réf. article", comment: "Cell content")
        case .refRayon: NSLocalizedString("Réf. rayon", comment: "Cell content")
        case .famille: NSLocalizedString("Famille", comment: "Cell content")
        case .prixTTC: NSLocalizedString("Prix TTC", comment: "Cell content")
        case .prixHT: NSLocalizedString("Prix HT", comment: "Cell content")
        case .montantTVA: NSLocalizedString("Montant TVA", comment: "Cell content")
        case .stockReel: NSLocalizedString("Stock réel", comment: "Cell content")
        case .stockDispo: NSLocalizedString("Stock disponible", comment: "Cell content")
        case .sousFamille: NSLocalizedString("Sous-famille", comment: "Cell content")
        case .fournisseur: NSLocalizedString("Fournisseur", comment: "Cell content")
        case .unite: NSLocalizedString("Unité", comment: "Cell content")
        case .poids: NSLocalizedString("Poids", comment: "Cell content")
        case .volume: NSLocalizedString("Volume", comment: "Cell content")
        case .codeBarres: NSLocalizedString("Code-barres article", comment: "Cell content")
        case .codeLibre: NSLocalizedString("Code libre", comment: "Cell content")
        case .dateGeneration: NSLocalizedString("Date de génération", comment: "Cell content")
        case .texteLibre: NSLocalizedString("Texte libre", comment: "Cell content")
        }
    }

    /// true si deux contenus sont du même « genre » (texte/code libre et date ignorent leur valeur).
    public func sameKind(as other: CellContent) -> Bool {
        switch (self, other) {
        case (.texteLibre, .texteLibre), (.dateGeneration, .dateGeneration), (.codeLibre, .codeLibre): return true
        default: return self == other
        }
    }

    /// Le pattern de format de la date (nil si ce n'est pas une cellule date).
    public var dateFormatPattern: String? {
        if case .dateGeneration(let pattern) = self { return pattern }
        return nil
    }
    public var isDate: Bool { if case .dateGeneration = self { return true }; return false }

    /// true pour une cellule de type CODE : le code-barres de l'article (EAN) ou un code libre
    /// saisi. Ces cellules sont rendues graphiquement (barres ou QR) et portent le segment de
    /// choix du type de rendu. Le nom historique est conservé pour ne pas disperser les usages.
    public var isBarcode: Bool {
        switch self { case .codeBarres, .codeLibre: return true; default: return false }
    }

    /// Valeur à encoder dans le code (barres ou QR) pour une cellule de type code : l'EAN de
    /// l'article pour `codeBarres`, la valeur saisie pour `codeLibre`. nil pour tout autre contenu.
    public func codeValue(for label: ProductLabel) -> String? {
        switch self {
        case .codeBarres: return label.ean.trimmingCharacters(in: .whitespacesAndNewlines)
        case .codeLibre(let value): return value.trimmingCharacters(in: .whitespacesAndNewlines)
        default: return nil
        }
    }

    /// Valeur textuelle à afficher (nil pour .vide et les codes — rendus graphiquement —
    /// ou une valeur absente). `formattedPrice` est le prix TTC déjà mis en forme.
    /// Les valeurs EBP (prix HT/TVA, stock, poids, volume…) sont déjà formatées à la source
    /// (`EBPProductMapper`) : aucune valeur brute ne transite ici.
    public func text(for label: ProductLabel, formattedPrice: String?) -> String? {
        func nonEmpty(_ s: String?) -> String? {
            guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return s
        }
        switch self {
        case .vide, .codeBarres, .codeLibre: return nil
        case .designation: return label.name
        case .refArticle: return String(format: NSLocalizedString("Réf. %@", comment: "Product reference on label"), label.productReference)
        case .refRayon: return label.shelfReference
        case .famille: return label.category
        case .prixTTC: return formattedPrice
        case .prixHT: return nonEmpty(label.priceExclVat)
        case .montantTVA: return nonEmpty(label.vatAmount)
        case .stockReel: return nonEmpty(label.realStock)
        case .stockDispo: return nonEmpty(label.virtualStock)
        case .sousFamille: return nonEmpty(label.subFamily)
        case .fournisseur: return nonEmpty(label.supplier)
        case .unite: return nonEmpty(label.unit)
        case .poids: return nonEmpty(label.weight)
        case .volume: return nonEmpty(label.volume)
        case .dateGeneration(let pattern): return label.generatedAtFormatted(pattern: pattern)
        case .texteLibre(let value): return value
        }
    }

    // Codable manuel : {kind: "...", value: "..."?}.
    private enum CodingKeys: String, CodingKey { case kind, value }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(String.self, forKey: .kind)
        switch kind {
        case "designation": self = .designation
        case "refArticle": self = .refArticle
        case "refRayon": self = .refRayon
        case "famille": self = .famille
        case "prixTTC": self = .prixTTC
        case "prixHT": self = .prixHT
        case "montantTVA": self = .montantTVA
        case "stockReel": self = .stockReel
        case "stockDispo": self = .stockDispo
        case "sousFamille": self = .sousFamille
        case "fournisseur": self = .fournisseur
        case "unite": self = .unite
        case "poids": self = .poids
        case "volume": self = .volume
        case "codeBarres": self = .codeBarres
        case "codeLibre": self = .codeLibre(try values.decodeIfPresent(String.self, forKey: .value) ?? "")
        case "dateGeneration": self = .dateGeneration(try values.decodeIfPresent(String.self, forKey: .value))
        case "texteLibre": self = .texteLibre(try values.decodeIfPresent(String.self, forKey: .value) ?? "")
        default: self = .vide
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .vide: try container.encode("vide", forKey: .kind)
        case .designation: try container.encode("designation", forKey: .kind)
        case .refArticle: try container.encode("refArticle", forKey: .kind)
        case .refRayon: try container.encode("refRayon", forKey: .kind)
        case .famille: try container.encode("famille", forKey: .kind)
        case .prixTTC: try container.encode("prixTTC", forKey: .kind)
        case .prixHT: try container.encode("prixHT", forKey: .kind)
        case .montantTVA: try container.encode("montantTVA", forKey: .kind)
        case .stockReel: try container.encode("stockReel", forKey: .kind)
        case .stockDispo: try container.encode("stockDispo", forKey: .kind)
        case .sousFamille: try container.encode("sousFamille", forKey: .kind)
        case .fournisseur: try container.encode("fournisseur", forKey: .kind)
        case .unite: try container.encode("unite", forKey: .kind)
        case .poids: try container.encode("poids", forKey: .kind)
        case .volume: try container.encode("volume", forKey: .kind)
        case .codeBarres: try container.encode("codeBarres", forKey: .kind)
        case .codeLibre(let value):
            try container.encode("codeLibre", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .dateGeneration(let pattern):
            try container.encode("dateGeneration", forKey: .kind)
            try container.encodeIfPresent(pattern, forKey: .value)
        case .texteLibre(let value):
            try container.encode("texteLibre", forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

/// Style d'une cellule : alignements, taille prédéfinie, gras, italique.
public struct CellStyle: Codable, Equatable, Hashable {
    public enum AlignH: String, Codable, CaseIterable, Hashable {
        case leading, center, trailing
        public var title: String {
            switch self {
            case .leading: NSLocalizedString("Gauche", comment: "Horizontal alignment")
            case .center: NSLocalizedString("Centré", comment: "Horizontal alignment")
            case .trailing: NSLocalizedString("Droite", comment: "Horizontal alignment")
            }
        }
    }
    public enum AlignV: String, Codable, CaseIterable, Hashable {
        case top, center, bottom
        public var title: String {
            switch self {
            case .top: NSLocalizedString("Haut", comment: "Vertical alignment")
            case .center: NSLocalizedString("Milieu", comment: "Vertical alignment")
            case .bottom: NSLocalizedString("Bas", comment: "Vertical alignment")
            }
        }
    }
    public enum Size: String, Codable, CaseIterable, Hashable {
        // Ordre croissant (XXS la plus fine → XL la plus grande) : c'est aussi l'ordre affiché.
        case xxs, xs, s, m, l, xl
        public var title: String {
            switch self {
            case .xxs: "XXS"; case .xs: "XS"; case .s: "S"; case .m: "M"; case .l: "L"; case .xl: "XL"
            }
        }
        /// Taille de police de base (points de mise en page 384), avant adaptation à la hauteur.
        /// XXS/XS servent surtout d'interlignes fins sur les lignes vides ; comme tailles de
        /// texte elles restent lisibles (le rendu plancher la police à ~10 points).
        public var fontSize: Int {
            switch self {
            case .xxs: 10; case .xs: 11; case .s: 13; case .m: 18; case .l: 26; case .xl: 36
            }
        }
        /// Hauteur de bande réservée à la ligne (points de mise en page 384) pour cette taille.
        /// Une ligne vide prend cette hauteur : XXS = espace très fin, XS = petit espace.
        public var bandHeight: Int {
            switch self {
            case .xxs: 8; case .xs: 13; case .s: 20; case .m: 27; case .l: 36; case .xl: 48
            }
        }
        /// Hauteur de bande d'une cellule CODE (barres ou QR) pour cette taille. Contrairement au
        /// texte, la taille d'un code pilote sa DIMENSION : plus la taille est grande, plus le code
        /// est haut (barres plus hautes = visée plus facile à la douchette ; QR plus grand). La
        /// largeur d'un code linéaire reste bornée par la cellule, donc la hauteur est le levier de
        /// confort de lecture que la taille contrôle ici.
        public var codeBandHeight: Int {
            switch self {
            case .xxs: 40; case .xs: 48; case .s: 56; case .m: 64; case .l: 84; case .xl: 108
            }
        }
    }

    public var alignH: AlignH
    public var alignV: AlignV
    public var size: Size
    public var bold: Bool
    public var italic: Bool

    public init(alignH: AlignH = .leading, alignV: AlignV = .center,
                size: Size = .m, bold: Bool = true, italic: Bool = false) {
        self.alignH = alignH
        self.alignV = alignV
        self.size = size
        self.bold = bold
        self.italic = italic
    }

    private enum CodingKeys: String, CodingKey { case alignH, alignV, size, bold, italic }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        alignH = try values.decodeIfPresent(AlignH.self, forKey: .alignH) ?? .leading
        alignV = try values.decodeIfPresent(AlignV.self, forKey: .alignV) ?? .center
        size = try values.decodeIfPresent(Size.self, forKey: .size) ?? .m
        bold = try values.decodeIfPresent(Bool.self, forKey: .bold) ?? true
        italic = try values.decodeIfPresent(Bool.self, forKey: .italic) ?? false
    }
}

public extension TemplateLine {
    /// Lignes de référence d'un arrangement historique : point de départ quand on duplique
    /// un preset en modèle perso (approximation éditable). Le preset lui-même reste rendu
    /// pixel-identique par le moteur historique tant qu'il n'est pas dupliqué.
    static func referenceLines(for arrangement: LabelArrangement) -> [TemplateLine] {
        func c(_ content: CellContent, _ size: CellStyle.Size, _ h: CellStyle.AlignH = .leading,
               bold: Bool = true) -> TemplateCell {
            TemplateCell(content: content, style: CellStyle(alignH: h, size: size, bold: bold))
        }
        switch arrangement {
        case .current:
            return [.full(c(.famille, .s)),
                    .full(c(.refRayon, .s)),
                    .full(c(.designation, .l)),
                    .full(c(.codeBarres, .m)),
                    .columns(c(.refArticle, .s), c(.prixTTC, .xl, .trailing))]
        case .priceFirst:
            return [.columns(c(.famille, .s), c(.prixTTC, .xl, .trailing)),
                    .full(c(.refRayon, .s)),
                    .full(c(.designation, .l)),
                    .full(c(.codeBarres, .m)),
                    .full(c(.refArticle, .s, .center))]
        case .columns:
            return [.full(c(.famille, .s)),
                    .full(c(.refRayon, .s)),
                    .columns(c(.designation, .l), c(.prixTTC, .xl, .trailing)),
                    .full(c(.codeBarres, .m)),
                    .full(c(.refArticle, .s, .center))]
        case .barcodeFirst:
            return [.full(c(.famille, .s)),
                    .full(c(.refRayon, .s)),
                    .full(c(.codeBarres, .m)),
                    .full(c(.designation, .l)),
                    .columns(c(.refArticle, .s), c(.prixTTC, .xl, .trailing))]
        case .centered:
            return [.full(c(.famille, .s, .center)),
                    .full(c(.refRayon, .s, .center)),
                    .full(c(.designation, .l, .center)),
                    .full(c(.codeBarres, .m, .center)),
                    .full(c(.refArticle, .s, .center)),
                    .full(c(.prixTTC, .l, .center))]
        case .barcodeLast:
            return [.full(c(.famille, .s)),
                    .full(c(.designation, .l)),
                    .columns(c(.refRayon, .s), c(.prixTTC, .xl, .trailing)),
                    .full(c(.refArticle, .s, .center)),
                    .full(c(.codeBarres, .m))]
        }
    }
}

/// Les six presets d'usine : un par disposition historique. Verrouillés.
public enum LabelTemplatePresets {
    /// UUID stables (dérivés de l'arrangement) : la sélection persiste entre deux lancements
    /// et la migration depuis `labelArrangement` retombe sur le bon preset.
    public static func id(for arrangement: LabelArrangement) -> UUID {
        switch arrangement {
        case .current:      return UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
        case .priceFirst:   return UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!
        case .columns:      return UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!
        case .barcodeFirst: return UUID(uuidString: "00000000-0000-0000-0000-0000000000C4")!
        case .centered:     return UUID(uuidString: "00000000-0000-0000-0000-0000000000C5")!
        case .barcodeLast:  return UUID(uuidString: "00000000-0000-0000-0000-0000000000C6")!
        }
    }

    public static func preset(for arrangement: LabelArrangement) -> LabelTemplate {
        LabelTemplate(id: id(for: arrangement), name: arrangement.title, isLocked: true,
                      baseArrangement: arrangement,
                      lines: TemplateLine.referenceLines(for: arrangement))
    }

    /// Tous les presets, dans l'ordre d'affichage (= ordre des arrangements).
    public static var all: [LabelTemplate] { LabelArrangement.allCases.map { preset(for: $0) } }

    /// Le preset par défaut (disposition rayon actuelle).
    public static var `default`: LabelTemplate { preset(for: .current) }
}
