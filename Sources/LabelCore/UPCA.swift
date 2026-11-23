import Foundation

public enum UPCAError: Error, Equatable {
    case invalidLength
    case nonDigit
    case invalidChecksum
}

/// Encodeur UPC-A : 11 chiffres de données + 1 chiffre de contrôle (12 au total).
/// UPC-A est structurellement un EAN-13 préfixé par un `0` : les modules sont donc ceux de
/// l'EAN-13 `"0" + upca`. On réutilise `EAN13.modules` pour garantir un code identique à ce que
/// lit une douchette, et on ne gère ici que la checksum propre à UPC-A et le découpage lisible
/// (1er chiffre | 5 chiffres | 5 chiffres | dernier chiffre), hors zone de barres aux extrémités.
public enum UPCA {
    public static func checksum(for elevenDigits: String) throws -> Int {
        guard elevenDigits.count == 11 else { throw UPCAError.invalidLength }
        guard elevenDigits.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { throw UPCAError.nonDigit }
        // Poids 3 sur positions paires (0,2,…,10), 1 sur impaires.
        let sum = elevenDigits.utf8.enumerated().reduce(0) { total, item in
            total + Int(item.element - 48) * (item.offset.isMultiple(of: 2) ? 3 : 1)
        }
        return (10 - sum % 10) % 10
    }

    /// Renvoie les 12 chiffres UPC-A complétés (checksum calculée ou vérifiée).
    public static func completed(_ input: String) throws -> String {
        guard input.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { throw UPCAError.nonDigit }
        if input.count == 11 { return input + String(try checksum(for: input)) }
        guard input.count == 12 else { throw UPCAError.invalidLength }
        guard Int(String(input.last!)) == (try checksum(for: String(input.prefix(11)))) else { throw UPCAError.invalidChecksum }
        return input
    }

    /// 95 modules (identiques à l'EAN-13 `"0" + upca`); true = barre noire.
    public static func modules(for input: String) throws -> [Bool] {
        let upca = try completed(input)
        return try EAN13.modules(for: "0" + upca)
    }

    /// Les gardes sont celles d'un EAN-13 (même grille de 95 modules).
    public static var guardModules: Set<Int> { EAN13.guardModules }
}
