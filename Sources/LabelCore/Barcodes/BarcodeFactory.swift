import Foundation

/// Point d'entrée unique pour obtenir un code-barres linéaire. Donne le générateur de la symbologie
/// demandée, applique les options EAN/UPC, et dit si une valeur est encodable — sans aucun repli
/// silencieux : le repli (QR) est une décision de l'appelant, explicite.
public enum BarcodeFactory {
    /// Générateur d'une symbologie, configuré avec les options d'apparence (chevron, 1er chiffre).
    public static func generator(for symbology: BarcodeSymbology, options: CodeOptions = .ebp) -> BarcodeGenerator {
        switch symbology {
        case .ean13: return EAN13Generator(options: options)
        case .ean8:  return EAN8Generator(options: options)
        case .upca:  return UPCAGenerator(options: options)
        case .code128: return Code128Generator(options: options)
        case .code39:  return Code39Generator(options: options)
        }
    }

    /// Encode `value` dans `symbology`, ou `nil` si elle n'y entre pas.
    public static func encode(_ value: String, symbology: BarcodeSymbology,
                              options: CodeOptions = .ebp) -> BarcodeSymbol? {
        generator(for: symbology, options: options).encode(value)
    }

    /// Vrai si `value` est encodable dans `symbology` telle quelle. Sert à l'éditeur pour GRISER
    /// les formats qui ne conviennent pas à la valeur de l'article (ex. EAN-8 sur un code à 13
    /// chiffres), au lieu de basculer en QR sans prévenir.
    public static func canEncode(_ value: String, symbology: BarcodeSymbology) -> Bool {
        generator(for: symbology).canEncode(value)
    }

    /// Symbologies capables d'encoder `value`, dans l'ordre d'affichage. Les autres seront grisées.
    public static func symbologiesEncodable(_ value: String) -> Set<BarcodeSymbology> {
        var set = Set<BarcodeSymbology>()
        for s in BarcodeSymbology.allCases where canEncode(value, symbology: s) { set.insert(s) }
        return set
    }
}
