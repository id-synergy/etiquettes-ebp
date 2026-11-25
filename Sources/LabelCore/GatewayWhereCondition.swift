import Foundation

/// Construit le paramètre `WhereCondition` (filtre générique EBP) envoyé à la gateway
/// pour rechercher des articles. Fonction pure et isolée : si la syntaxe exacte du filtre
/// EBP diffère, c'est le seul endroit à corriger (et un seul test à ajuster).
///
/// Syntaxe utilisée (OData-like, telle que documentée côté EBP) :
///   contains(Caption,'<mot>') or contains(Id,'<mot>') or contains(BarCode,'<mot>') or contains(DesComClear,'<mot>')
public enum GatewayWhereCondition {

    /// Champs interrogés par la recherche texte libre, dans l'ordre d'essai.
    /// Caption = libellé, Id = référence, BarCode = code-barres (EAN), DesComClear = description.
    private static let searchFields = ["Caption", "Id", "BarCode", "DesComClear"]

    /// Condition de recherche libre sur le libellé, la référence, le code-barres et la description.
    ///
    /// Multi-termes : la saisie est découpée en mots ; CHAQUE mot doit apparaître dans au moins
    /// un des champs (les mots sont combinés en « and », les champs en « or »). Ainsi « bosch 12 »
    /// ne remonte que les articles dont un champ contient « bosch » ET un champ contient « 12 ».
    /// Retourne nil pour une saisie vide.
    public static func search(_ text: String) -> String? {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map { String($0) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }

        let perWord = words.map { word -> String in
            let safe = escape(word)
            let clauses = searchFields.map { "contains(\($0),'\(safe)')" }
            return clauses.joined(separator: " or ")
        }
        // Un seul mot : on garde la condition « à plat » (pas de parenthèses superflues),
        // pour rester compatible avec l'ancienne forme et lisible dans les logs.
        if perWord.count == 1 { return perWord[0] }
        return perWord.map { "(\($0))" }.joined(separator: " and ")
    }

    /// Filtre d'égalité sur la famille.
    public static func family(_ familyId: String) -> String? {
        let id = familyId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        return "FamilyId eq '\(escape(id))'"
    }

    /// Filtre d'égalité sur la sous-famille.
    public static func subFamily(_ subFamilyId: String) -> String? {
        let id = subFamilyId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        return "SubFamilyId eq '\(escape(id))'"
    }

    /// N'inclure que les articles actifs (ActiveState = 0 chez EBP : 0 = actif).
    public static func activeOnly() -> String { "ActiveState eq 0" }

    /// N'inclure que les articles en stock (RealStock > 0).
    public static func inStock() -> String { "RealStock gt 0" }

    /// Recherche par code-barres exact (scan EAN/QR). Retourne nil si vide.
    public static func barcode(_ code: String) -> String? {
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return "BarCode eq '\(escape(value))'"
    }

    /// Prix de vente TTC ≥ valeur.
    public static func priceAtLeast(_ value: Decimal) -> String {
        "SalePriceVatIncluded ge \(number(value))"
    }

    /// Prix de vente TTC ≤ valeur.
    public static func priceAtMost(_ value: Decimal) -> String {
        "SalePriceVatIncluded le \(number(value))"
    }

    /// Formate un décimal pour la syntaxe de filtre (point décimal, pas de séparateur de milliers).
    private static func number(_ value: Decimal) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.maximumFractionDigits = 8
        return f.string(from: value as NSDecimalNumber) ?? "\(value)"
    }

    /// Compose plusieurs conditions avec « and », en ignorant les nils.
    /// Chaque sous-condition est parenthésée pour préserver la priorité.
    public static func and(_ parts: [String?]) -> String? {
        let present = parts.compactMap { $0 }.filter { !$0.isEmpty }
        guard !present.isEmpty else { return nil }
        if present.count == 1 { return present[0] }
        return present.map { "(\($0))" }.joined(separator: " and ")
    }

    /// Échappe les apostrophes pour la syntaxe de filtre (doublage, convention OData).
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
