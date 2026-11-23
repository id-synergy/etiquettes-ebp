import Foundation

/// Contrat commun à tous les générateurs de codes-barres LINÉAIRES de l'app.
///
/// Objectif : chaque symbologie est une brique autonome et testée qui, à partir d'une valeur,
/// produit un `BarcodeSymbol` complet (modules + texte lisible DÉJÀ placé sous les bonnes barres).
/// Le moteur de rendu ne connaît plus les particularités de chaque format : il demande un symbole
/// et le pose. Les formats qu'Apple sait générer (Code 128, QR) passent par CoreImage ; les autres
/// (familles EAN/UPC, Code 39) par des tables normées ISO, figées et vérifiées par des tests.
///
/// Un générateur renvoie `nil` quand la valeur n'est pas encodable dans sa symbologie (ex. 13
/// chiffres passés à EAN-8). Le repli éventuel (QR) est décidé par l'appelant, pas en douce ici.
public protocol BarcodeGenerator {
    /// Symbologie produite par ce générateur.
    var symbology: BarcodeSymbology { get }
    /// Vrai si `value` est encodable telle quelle (après complétion de checksum si applicable).
    func canEncode(_ value: String) -> Bool
    /// Encode `value`, ou `nil` si elle n'entre pas dans cette symbologie.
    func encode(_ value: String) -> BarcodeSymbol?
}

/// Un groupe de texte lisible à placer sous les barres, ancré sur une PLAGE DE MODULES.
/// Le rasterizer convertit `moduleRange` en pixels pour centrer le texte pile sous ses barres —
/// c'est ce qui rend le rendu fidèle à une étiquette EBP, quelle que soit la largeur de cellule.
public struct BarcodeTextGroup: Equatable {
    public enum Anchor: Equatable {
        case under(Range<Int>)   // centré sous cette plage de modules (groupes de chiffres)
        case leftOf(Int)         // juste à gauche de ce module (1er chiffre déporté EAN-13/UPC-A)
        case rightOf(Int)        // juste à droite de ce module (dernier chiffre UPC-A, chevron)
    }
    public let text: String
    public let anchor: Anchor
    public init(_ text: String, _ anchor: Anchor) {
        self.text = text
        self.anchor = anchor
    }
}

/// Résultat d'un générateur : tout ce qu'il faut pour peindre le code ET son texte, sans que le
/// rasterizer ait à connaître la symbologie.
public struct BarcodeSymbol: Equatable {
    /// Symbologie d'origine (pour les gardes allongées, le style, etc.).
    public let symbology: BarcodeSymbology
    /// Modules du code (true = barre noire), quiet zone NON incluse (ajoutée au rendu).
    public let modules: [Bool]
    /// Index des modules de garde à prolonger sous la ligne de données (familles EAN/UPC).
    /// Vide pour Code 128 / Code 39.
    public let guardModules: Set<Int>
    /// Groupes de texte lisible, déjà ancrés sur leurs modules. Vide = pas de texte (ex. QR).
    public let textGroups: [BarcodeTextGroup]
    /// Valeur finale encodée (code complété, checksum incluse) — utile pour l'affichage/debug.
    public let encodedValue: String

    public init(symbology: BarcodeSymbology, modules: [Bool], guardModules: Set<Int>,
                textGroups: [BarcodeTextGroup], encodedValue: String) {
        self.symbology = symbology
        self.modules = modules
        self.guardModules = guardModules
        self.textGroups = textGroups
        self.encodedValue = encodedValue
    }
}
