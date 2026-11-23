import Foundation

public enum Code39Error: Error, Equatable {
    case emptyValue
    case unsupportedCharacter(Character)
}

/// Encodeur Code 39 (sans checksum, variante la plus courante). Chaque caractère = 9 éléments
/// (5 barres + 4 espaces), dont 3 larges ; un espace inter-caractère (1 module étroit) les sépare.
/// Jeu : 0-9, A-Z, espace, et `- . $ / + %`. Encadré par le caractère de start/stop `*`.
///
/// Les motifs sont décrits en « n » (narrow) / « w » (wide) sur 9 positions, barres et espaces
/// alternés en commençant par une barre. On rend un module étroit = 1 module, large = 2 modules,
/// ce qui donne un ratio 2:1 (lisible par toutes les douchettes).
public enum Code39 {
    // Motif 9 éléments par caractère : B S B S B S B S B (barre/espace alternés).
    private static let patterns: [Character: String] = [
        "0": "nnnwwnwnn", "1": "wnnwnnnnw", "2": "nnwwnnnnw", "3": "wnwwnnnnn",
        "4": "nnnwwnnnw", "5": "wnnwwnnnn", "6": "nnwwwnnnn", "7": "nnnwnnwnw",
        "8": "wnnwnnwnn", "9": "nnwwnnwnn",
        "A": "wnnnnwnnw", "B": "nnwnnwnnw", "C": "wnwnnwnnn", "D": "nnnnwwnnw",
        "E": "wnnnwwnnn", "F": "nnwnwwnnn", "G": "nnnnnwwnw", "H": "wnnnnwwnn",
        "I": "nnwnnwwnn", "J": "nnnnwwwnn", "K": "wnnnnnnww", "L": "nnwnnnnww",
        "M": "wnwnnnnwn", "N": "nnnnwnnww", "O": "wnnnwnnwn", "P": "nnwnwnnwn",
        "Q": "nnnnnnwww", "R": "wnnnnnwwn", "S": "nnwnnnwwn", "T": "nnnnwnwwn",
        "U": "wwnnnnnnw", "V": "nwwnnnnnw", "W": "wwwnnnnnn", "X": "nwnnwnnnw",
        "Y": "wwnnwnnnn", "Z": "nwwnwnnnn",
        "-": "nwnnnnwnw", ".": "wwnnnnwnn", " ": "nwwnnnwnn", "$": "nwnwnwnnn",
        "/": "nwnwnnnwn", "+": "nwnnnwnwn", "%": "nnnwnwnwn", "*": "nwnnwnwnn"
    ]

    /// Caractères encodables (hors `*` de start/stop, réservé).
    public static func isEncodable(_ value: String) -> Bool {
        let upper = value.uppercased()
        return !upper.isEmpty && upper.allSatisfy { $0 != "*" && patterns[$0] != nil }
    }

    /// Modules du code (true = barre noire). Lève si un caractère n'est pas encodable.
    public static func modules(for value: String) throws -> [Bool] {
        let upper = value.uppercased()
        guard !upper.isEmpty else { throw Code39Error.emptyValue }
        var out: [Bool] = []
        let chars = Array("*" + upper + "*")
        for (ci, ch) in chars.enumerated() {
            guard let pattern = patterns[ch] else { throw Code39Error.unsupportedCharacter(ch) }
            // Élément i : barre si i pair, espace si i impair ; étroit = 1 module, large = 2.
            for (ei, e) in pattern.enumerated() {
                let wide = (e == "w")
                let isBar = ei.isMultiple(of: 2)
                let count = wide ? 2 : 1
                out.append(contentsOf: Array(repeating: isBar, count: count))
            }
            // Espace inter-caractère (1 module blanc), sauf après le dernier caractère.
            if ci < chars.count - 1 { out.append(false) }
        }
        return out
    }
}
