import Foundation

public enum EAN8Error: Error, Equatable {
    case invalidLength
    case nonDigit
    case invalidChecksum
}

/// Encodeur EAN-8 : 7 chiffres de données + 1 chiffre de contrôle, 67 modules.
/// Structure : garde début `101`, 4 chiffres de gauche (codes impairs L), garde centrale `01010`,
/// 4 chiffres de droite (codes R), garde fin `101`. Pas de parité variable (contrairement à EAN-13).
public enum EAN8 {
    private static let leftOdd = ["0001101", "0011001", "0010011", "0111101", "0100011", "0110001", "0101111", "0111011", "0110111", "0001011"]
    private static let right = ["1110010", "1100110", "1101100", "1000010", "1011100", "1001110", "1010000", "1000100", "1001000", "1110100"]

    public static func checksum(for sevenDigits: String) throws -> Int {
        guard sevenDigits.count == 7 else { throw EAN8Error.invalidLength }
        guard sevenDigits.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { throw EAN8Error.nonDigit }
        // Poids 3 sur les positions paires (0,2,4,6), 1 sur les impaires — inverse d'EAN-13.
        let sum = sevenDigits.utf8.enumerated().reduce(0) { total, item in
            total + Int(item.element - 48) * (item.offset.isMultiple(of: 2) ? 3 : 1)
        }
        return (10 - sum % 10) % 10
    }

    public static func completed(_ input: String) throws -> String {
        guard input.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { throw EAN8Error.nonDigit }
        if input.count == 7 { return input + String(try checksum(for: input)) }
        guard input.count == 8 else { throw EAN8Error.invalidLength }
        guard Int(String(input.last!)) == (try checksum(for: String(input.prefix(7)))) else { throw EAN8Error.invalidChecksum }
        return input
    }

    /// Exactly 67 modules; true means a black bar.
    public static func modules(for input: String) throws -> [Bool] {
        let ean = try completed(input)
        let digits = ean.utf8.map { Int($0 - 48) }
        var bits = "101"
        for index in 0...3 { bits += leftOdd[digits[index]] }
        bits += "01010"
        for index in 4...7 { bits += right[digits[index]] }
        bits += "101"
        return bits.map { $0 == "1" }
    }

    /// Positions (index de module, 0…66) des barres de GARDE : début `101` (0-2),
    /// centrale `01010` (31-35), fin `101` (64-66).
    public static let guardModules: Set<Int> = {
        var set = Set<Int>()
        set.formUnion(0...2)
        set.formUnion(31...35)
        set.formUnion(64...66)
        return set
    }()
}
