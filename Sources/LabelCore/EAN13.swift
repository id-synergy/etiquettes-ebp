import Foundation

public enum EAN13Error: Error, Equatable {
    case invalidLength
    case nonDigit
    case invalidChecksum
}

public enum EAN13 {
    private static let leftOdd = ["0001101", "0011001", "0010011", "0111101", "0100011", "0110001", "0101111", "0111011", "0110111", "0001011"]
    private static let leftEven = ["0100111", "0110011", "0011011", "0100001", "0011101", "0111001", "0000101", "0010001", "0001001", "0010111"]
    private static let right = ["1110010", "1100110", "1101100", "1000010", "1011100", "1001110", "1010000", "1000100", "1001000", "1110100"]
    private static let parity = ["OOOOOO", "OOEOEE", "OOEEOE", "OOEEEO", "OEOOEE", "OEEOOE", "OEEEOO", "OEOEOE", "OEOEEO", "OEEOEO"]

    public static func checksum(for twelveDigits: String) throws -> Int {
        guard twelveDigits.count == 12 else { throw EAN13Error.invalidLength }
        guard twelveDigits.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { throw EAN13Error.nonDigit }
        let sum = twelveDigits.utf8.enumerated().reduce(0) { total, item in
            total + Int(item.element - 48) * (item.offset.isMultiple(of: 2) ? 1 : 3)
        }
        return (10 - sum % 10) % 10
    }

    public static func completed(_ input: String) throws -> String {
        guard input.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { throw EAN13Error.nonDigit }
        if input.count == 12 { return input + String(try checksum(for: input)) }
        guard input.count == 13 else { throw EAN13Error.invalidLength }
        guard Int(String(input.last!)) == (try checksum(for: String(input.prefix(12)))) else { throw EAN13Error.invalidChecksum }
        return input
    }

    /// Exactly 95 modules; true means a black bar.
    public static func modules(for input: String) throws -> [Bool] {
        let ean = try completed(input)
        let digits = ean.utf8.map { Int($0 - 48) }
        var bits = "101"
        let parityBits = Array(parity[digits[0]].utf8)
        for index in 1...6 {
            bits += (parityBits[index - 1] == 79 ? leftOdd : leftEven)[digits[index]]
        }
        bits += "01010"
        for index in 7...12 { bits += right[digits[index]] }
        bits += "101"
        return bits.map { $0 == "1" }
    }
}
