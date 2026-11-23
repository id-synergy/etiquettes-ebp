import Foundation

/// Générateurs des familles EAN/UPC. Ils s'appuient sur les encodeurs normés existants
/// (`EAN13`, `EAN8`, `UPCA`) pour les modules, et ajoutent le découpage du texte lisible ANCRÉ sur
/// les plages de modules normées — c'est ce qui place les chiffres pile sous les bonnes barres,
/// comme une étiquette EBP. Les plages ci-dessous sont celles du standard EAN/UPC.

/// EAN-13 : 95 modules. Garde début 0–2, gauche 3–44, garde centrale 45–49, droite 50–91,
/// garde fin 92–94. 1er chiffre déporté à gauche des barres ; chevron de marge après la fin.
public struct EAN13Generator: BarcodeGenerator {
    public let symbology: BarcodeSymbology = .ean13
    private let options: CodeOptions
    public init(options: CodeOptions = .ebp) { self.options = options }

    public func canEncode(_ value: String) -> Bool { (try? EAN13.completed(value)) != nil }

    public func encode(_ value: String) -> BarcodeSymbol? {
        guard let ean = try? EAN13.completed(value), let modules = try? EAN13.modules(for: ean) else { return nil }
        var groups: [BarcodeTextGroup] = []
        if options.showText {
            if options.showFirstDigit {
                groups.append(BarcodeTextGroup(String(ean.prefix(1)), .leftOf(0)))
            }
            groups.append(BarcodeTextGroup(String(ean.dropFirst().prefix(6)), .under(3..<45)))
            groups.append(BarcodeTextGroup(String(ean.suffix(6)), .under(49..<91)))
            if options.showChevron {
                groups.append(BarcodeTextGroup(">", .rightOf(94)))
            }
        }
        return BarcodeSymbol(symbology: .ean13, modules: modules, guardModules: EAN13.guardModules,
                             textGroups: groups, encodedValue: ean)
    }
}

/// EAN-8 : 67 modules. Garde début 0–2, gauche 3–30, garde centrale 31–35, droite 36–63,
/// garde fin 64–66. Pas de chiffre déporté (les 8 chiffres vont en deux groupes de 4).
public struct EAN8Generator: BarcodeGenerator {
    public let symbology: BarcodeSymbology = .ean8
    private let options: CodeOptions
    public init(options: CodeOptions = .ebp) { self.options = options }

    public func canEncode(_ value: String) -> Bool { (try? EAN8.completed(value)) != nil }

    public func encode(_ value: String) -> BarcodeSymbol? {
        guard let ean = try? EAN8.completed(value), let modules = try? EAN8.modules(for: ean) else { return nil }
        var groups: [BarcodeTextGroup] = []
        if options.showText {
            groups.append(BarcodeTextGroup(String(ean.prefix(4)), .under(3..<31)))
            groups.append(BarcodeTextGroup(String(ean.suffix(4)), .under(35..<63)))
            if options.showChevron {
                groups.append(BarcodeTextGroup(">", .rightOf(66)))
            }
        }
        return BarcodeSymbol(symbology: .ean8, modules: modules, guardModules: EAN8.guardModules,
                             textGroups: groups, encodedValue: ean)
    }
}

/// UPC-A : mêmes 95 modules qu'un EAN-13 préfixé 0. 1er et dernier chiffre déportés ;
/// groupes de 5 chiffres sous chaque moitié.
public struct UPCAGenerator: BarcodeGenerator {
    public let symbology: BarcodeSymbology = .upca
    private let options: CodeOptions
    public init(options: CodeOptions = .ebp) { self.options = options }

    public func canEncode(_ value: String) -> Bool { (try? UPCA.completed(value)) != nil }

    public func encode(_ value: String) -> BarcodeSymbol? {
        guard let upc = try? UPCA.completed(value), let modules = try? UPCA.modules(for: upc) else { return nil }
        let d = Array(upc)
        var groups: [BarcodeTextGroup] = []
        if options.showText {
            if options.showFirstDigit {
                groups.append(BarcodeTextGroup(String(d[0]), .leftOf(0)))
            }
            groups.append(BarcodeTextGroup(String(d[1...5]), .under(3..<45)))
            groups.append(BarcodeTextGroup(String(d[6...10]), .under(49..<91)))
            if options.showFirstDigit {
                groups.append(BarcodeTextGroup(String(d[11]), .rightOf(94)))
            }
            if options.showChevron {
                groups.append(BarcodeTextGroup(">", .rightOf(94)))
            }
        }
        return BarcodeSymbol(symbology: .upca, modules: modules, guardModules: UPCA.guardModules,
                             textGroups: groups, encodedValue: upc)
    }
}

/// Code 39 : alphanumérique, pas de garde allongée. Le texte lisible est la valeur brute,
/// centrée sous l'ensemble des barres (convention des codes linéaires non-EAN).
public struct Code39Generator: BarcodeGenerator {
    public let symbology: BarcodeSymbology = .code39
    private let options: CodeOptions
    public init(options: CodeOptions = .ebp) { self.options = options }

    public func canEncode(_ value: String) -> Bool { Code39.isEncodable(value) }

    public func encode(_ value: String) -> BarcodeSymbol? {
        guard Code39.isEncodable(value), let modules = try? Code39.modules(for: value) else { return nil }
        let text = value.uppercased()
        let groups = options.showText ? [BarcodeTextGroup(text, .under(0..<modules.count))] : []
        return BarcodeSymbol(symbology: .code39, modules: modules, guardModules: [],
                             textGroups: groups, encodedValue: text)
    }
}
