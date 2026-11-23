import XCTest
@testable import LabelCore

/// Vérifie le contrat des générateurs : encodage correct, refus explicite (nil) quand la valeur
/// ne convient pas, texte ancré sur les bons modules, et respect des options d'apparence.
final class BarcodeGeneratorTests: XCTestCase {

    // MARK: Encodage et refus

    func testEAN13EncodesRealLabel() {
        let symbol = BarcodeFactory.encode("3660619000012", symbology: .ean13)
        XCTAssertNotNil(symbol)
        XCTAssertEqual(symbol?.modules.count, 95)
        XCTAssertEqual(symbol?.encodedValue, "3660619000012")
    }

    func testEAN8RefusesThirteenDigitValue() {
        // Le vrai cas « EAN-8 → QR » : un code à 13 chiffres n'est PAS un EAN-8.
        // Le générateur doit renvoyer nil (refus explicite), pas un code faux.
        XCTAssertNil(BarcodeFactory.encode("3660619000012", symbology: .ean8))
        XCTAssertFalse(BarcodeFactory.canEncode("3660619000012", symbology: .ean8))
    }

    func testUPCARefusesThirteenDigitValue() {
        XCTAssertNil(BarcodeFactory.encode("3660619000012", symbology: .upca))
        XCTAssertFalse(BarcodeFactory.canEncode("3660619000012", symbology: .upca))
    }

    func testEAN8EncodesEightDigitValue() {
        let symbol = BarcodeFactory.encode("20123451", symbology: .ean8)
        XCTAssertNotNil(symbol)
        XCTAssertEqual(symbol?.modules.count, 67)
    }

    func testCode128EncodesAlphanumeric() {
        let symbol = BarcodeFactory.encode("ABC-123", symbology: .code128)
        XCTAssertNotNil(symbol)
        XCTAssertGreaterThan(symbol?.modules.count ?? 0, 0)
    }

    func testCode39RefusesAccents() {
        XCTAssertNil(BarcodeFactory.encode("café", symbology: .code39))
    }

    // MARK: Texte ancré

    func testEAN13TextGroupsAnchoredOnModules() {
        let symbol = BarcodeFactory.encode("3660619000012", symbology: .ean13)!
        // 1er chiffre déporté à gauche du module 0, deux groupes sous les plages gauche/droite,
        // chevron après le module 94.
        XCTAssertEqual(symbol.textGroups.count, 4)
        XCTAssertEqual(symbol.textGroups[0].text, "3")
        XCTAssertEqual(symbol.textGroups[0].anchor, .leftOf(0))
        XCTAssertEqual(symbol.textGroups[1].anchor, .under(3..<45))
        XCTAssertEqual(symbol.textGroups[2].anchor, .under(49..<91))
        XCTAssertEqual(symbol.textGroups[3].text, ">")
    }

    func testEAN8HasNoDeportedFirstDigit() {
        let symbol = BarcodeFactory.encode("20123451", symbology: .ean8)!
        // Deux groupes de 4 + chevron ; aucun chiffre « leftOf » (pas de 1er chiffre déporté).
        XCTAssertFalse(symbol.textGroups.contains { if case .leftOf = $0.anchor { return true }; return false })
        XCTAssertEqual(symbol.textGroups.first?.text, "2012")
    }

    // MARK: Options

    func testHideTextProducesNoGroups() {
        let opts = CodeOptions(showText: false)
        let symbol = BarcodeFactory.encode("3660619000012", symbology: .ean13, options: opts)!
        XCTAssertTrue(symbol.textGroups.isEmpty)
        XCTAssertEqual(symbol.modules.count, 95) // les barres restent
    }

    func testHideChevronAndFirstDigit() {
        let opts = CodeOptions(showText: true, showChevron: false, showFirstDigit: false)
        let symbol = BarcodeFactory.encode("3660619000012", symbology: .ean13, options: opts)!
        XCTAssertFalse(symbol.textGroups.contains { $0.text == ">" })
        XCTAssertFalse(symbol.textGroups.contains { if case .leftOf = $0.anchor { return true }; return false })
        XCTAssertEqual(symbol.textGroups.count, 2) // les deux groupes de 6
    }

    // MARK: Grisage éditeur

    func testEncodableSymbologiesForThirteenDigits() {
        // Un EAN-13 à 13 chiffres n'est encodable qu'en EAN-13, Code 128, Code 39 (pas EAN-8/UPC-A).
        let set = BarcodeFactory.symbologiesEncodable("3660619000012")
        XCTAssertTrue(set.contains(.ean13))
        XCTAssertTrue(set.contains(.code128))
        XCTAssertTrue(set.contains(.code39))
        XCTAssertFalse(set.contains(.ean8))
        XCTAssertFalse(set.contains(.upca))
    }
}
