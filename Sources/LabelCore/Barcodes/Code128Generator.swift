import Foundation

/// Code 128 via CoreImage (moteur Apple). On réutilise `Code128.modules` (qui lit les modules
/// produits par `CICode128BarcodeGenerator`) pour rester dans le pipeline « modules → rastérisation
/// à pas entier » commun à tous les codes linéaires. Le texte lisible est la valeur brute, centrée
/// sous les barres.
public struct Code128Generator: BarcodeGenerator {
    public let symbology: BarcodeSymbology = .code128
    private let options: CodeOptions
    public init(options: CodeOptions = .ebp) { self.options = options }

    public func canEncode(_ value: String) -> Bool { Code128.isEncodable(value) }

    public func encode(_ value: String) -> BarcodeSymbol? {
        guard let modules = Code128.modules(for: value) else { return nil }
        let groups = options.showText ? [BarcodeTextGroup(value, .under(0..<modules.count))] : []
        return BarcodeSymbol(symbology: .code128, modules: modules, guardModules: [],
                             textGroups: groups, encodedValue: value)
    }
}
