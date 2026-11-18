import Foundation

/// Comparaison de numéros de version façon « marketing » (CFBundleShortVersionString) :
/// une suite de nombres séparés par des points, comparés composant par composant. « 1.10 » est
/// donc PLUS RÉCENT que « 1.9 » (10 > 9), et « 1.1 » équivaut à « 1.1.0 ». Les composants non
/// numériques sont ignorés prudemment (traités comme 0), car ces versions n'en contiennent pas.
///
/// Pur (aucune dépendance) : testable et partagé. Sert à décider si l'App Store propose une version
/// plus récente que celle installée.
public enum AppVersion {
    /// Découpe une version en composants entiers. « 1.2.3 » → [1, 2, 3].
    public static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
    }

    /// Ordre entre deux versions, en complétant la plus courte par des zéros.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let lhs = components(a), rhs = components(b)
        let count = max(lhs.count, rhs.count)
        for i in 0..<count {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// `true` si `storeVersion` est strictement plus récente que `installedVersion`.
    public static func isNewer(_ storeVersion: String, than installedVersion: String) -> Bool {
        compare(storeVersion, installedVersion) == .orderedDescending
    }
}
