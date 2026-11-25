import Foundation

/// Construit le paramètre `WhereCondition` (filtre générique EBP) envoyé à la gateway
/// pour rechercher des articles. Fonction pure et isolée : si la syntaxe exacte du filtre
/// EBP diffère, c'est le seul endroit à corriger (et un seul test à ajuster).
///
/// Syntaxe utilisée (OData-like, telle que documentée côté EBP) :
///   contains(Caption,'<mot>') or contains(Id,'<mot>')   (+ `BarCode eq '<code>'` si le mot est un code-barres)
///
/// IMPORTANT — champs interrogeables par `contains` (Like) côté EBP :
/// seuls `Caption` (libellé) et `Id` (référence) acceptent `contains`. EBP NE SUPPORTE PAS le
/// `Like` sur `BarCode` (renvoie 502 en partiel, 0 en complet) ni, de façon fiable, sur
/// `DesComClear` (gonfle les résultats au lieu de filtrer). Le code-barres se cherche donc par
/// ÉGALITÉ EXACTE (`BarCode eq '<code>'`), appliquée seulement quand le mot ressemble à un code.
public enum GatewayWhereCondition {

    /// Champs texte interrogés par `contains` (les seuls sûrs côté EBP) : libellé et référence.
    private static let textSearchFields = ["Caption", "Id"]

    /// Un mot ressemble-t-il à un code-barres ? (≥ 6 caractères, uniquement des chiffres).
    /// Au-dessous de 6 chiffres, on ne tente pas l'égalité code-barres : trop de faux positifs
    /// et aucun code EAN/UPC réel n'est si court.
    private static func looksLikeBarcode(_ word: String) -> Bool {
        word.count >= 6 && word.allSatisfy(\.isNumber)
    }

    /// Condition de recherche libre.
    ///
    /// Deux régimes selon la forme du mot :
    ///  - mot qui ressemble à un CODE-BARRES (≥ 6 chiffres) → `BarCode eq '<mot>'` SEUL (égalité
    ///    exacte). On n'ajoute PAS de `contains` dessus : EBP renvoie 502 sur un `contains` dont
    ///    le motif est fait de zéros (ex. `contains(Caption,'000')`), ce qui est le cas des
    ///    codes-barres SRM préfixés de zéros. Un code se cherche de toute façon par égalité.
    ///  - mot texte normal → `contains(Caption,'<mot>') or contains(Id,'<mot>')` (seuls champs sûrs).
    ///
    /// Multi-termes : la saisie est découpée en mots ; CHAQUE mot doit matcher (mots en « and »).
    /// Retourne nil pour une saisie vide.
    public static func search(_ text: String) -> String? {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map { String($0) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }

        let perWord = words.map { word -> String in
            let safe = escape(word)
            if looksLikeBarcode(word) {
                // Code-barres : égalité exacte seule (pas de contains, qui planterait).
                return "BarCode eq '\(safe)'"
            }
            return textSearchFields.map { "contains(\($0),'\(safe)')" }.joined(separator: " or ")
        }
        // Un seul mot : condition « à plat ». Plusieurs mots : chacun parenthésé, reliés par « and ».
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

    /// Filtre d'égalité sur l'unité de vente (UnitId EBP : 'UNIT', 'KG', 'BOIT'…).
    public static func unit(_ unitId: String) -> String? {
        let id = unitId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        return "UnitId eq '\(escape(id))'"
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
