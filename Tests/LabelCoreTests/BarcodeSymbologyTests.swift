import XCTest
@testable import LabelCore

/// Encodeurs des symbologies ajoutées (EAN-8, UPC-A, Code 39) et rétrocompatibilité du modèle de
/// cellule (symbologie + options optionnelles au décodage).
final class BarcodeSymbologyTests: XCTestCase {

    // MARK: EAN-13 (étiquette EBP réelle)

    func testEAN13RealEBPLabel() throws {
        // Code lu sur une étiquette EBP : 3 660338 199615. La checksum doit se vérifier.
        XCTAssertEqual(try EAN13.completed("366033819961"), "3660338199615")
        XCTAssertEqual(try EAN13.modules(for: "3660338199615").count, 95)
    }

    // MARK: EAN-8

    func testEAN8ChecksumAndCompletion() throws {
        XCTAssertEqual(try EAN8.checksum(for: "2012345"), 1)
        XCTAssertEqual(try EAN8.completed("2012345"), "20123451")
        XCTAssertEqual(try EAN8.completed("9638507"), "96385074")
        XCTAssertThrowsError(try EAN8.completed("20123452"))   // mauvaise checksum
        XCTAssertThrowsError(try EAN8.completed("201234A1"))   // non-chiffre
        XCTAssertThrowsError(try EAN8.completed("20123"))      // mauvaise longueur
    }

    func testEAN8Pattern() throws {
        let bits = try EAN8.modules(for: "20123451")
        XCTAssertEqual(bits.count, 67)
        XCTAssertEqual(Array(bits.prefix(3)), [true, false, true])          // garde début
        XCTAssertEqual(Array(bits[31..<36]), [false, true, false, true, false]) // garde centrale
        XCTAssertEqual(Array(bits.suffix(3)), [true, false, true])          // garde fin
    }

    // MARK: UPC-A

    func testUPCAChecksumAndCompletion() throws {
        XCTAssertEqual(try UPCA.checksum(for: "03600029145"), 2)
        XCTAssertEqual(try UPCA.completed("03600029145"), "036000291452")
        XCTAssertThrowsError(try UPCA.completed("036000291453")) // mauvaise checksum
        XCTAssertThrowsError(try UPCA.completed("0360002914A"))  // non-chiffre
    }

    func testUPCAModulesMatchEAN13WithZeroPrefix() throws {
        // UPC-A = EAN-13 préfixé par 0 : mêmes 95 modules, scannable à l'identique.
        let upc = try UPCA.modules(for: "036000291452")
        let ean = try EAN13.modules(for: "0036000291452")
        XCTAssertEqual(upc, ean)
        XCTAssertEqual(upc.count, 95)
    }

    // MARK: Code 39

    func testCode39Encodable() {
        XCTAssertTrue(Code39.isEncodable("ABC-123"))
        XCTAssertTrue(Code39.isEncodable("hello"))       // minuscules acceptées (mises en majuscules)
        XCTAssertFalse(Code39.isEncodable(""))
        XCTAssertFalse(Code39.isEncodable("café"))       // accent non encodable
        XCTAssertFalse(Code39.isEncodable("A*B"))        // * réservé start/stop
    }

    func testCode39ModulesStartStop() throws {
        let bits = try Code39.modules(for: "A")
        // Commence et finit par une barre (motif du caractère `*`).
        XCTAssertTrue(bits.first ?? false)
        XCTAssertTrue(bits.last ?? false)
        XCTAssertFalse(bits.isEmpty)
    }

    func testCode39RejectsUnsupported() {
        XCTAssertThrowsError(try Code39.modules(for: "é"))
        XCTAssertThrowsError(try Code39.modules(for: ""))
    }

    // MARK: Rétrocompatibilité du modèle

    func testTemplateCellDecodesWithoutSymbologyDefaultsToEAN13() throws {
        // Un modèle enregistré AVANT l'ajout des symbologies (sans les clés) doit se décoder avec
        // les défauts : EAN-13 et options « EBP ».
        let cell = try JSONDecoder().decode(TemplateCell.self, from: minimalBarcodeCellJSON())
        XCTAssertEqual(cell.symbology, .ean13)
        XCTAssertEqual(cell.codeOptions, .ebp)
        XCTAssertTrue(cell.codeOptions.showText)
        XCTAssertTrue(cell.codeOptions.showChevron)
        XCTAssertTrue(cell.codeOptions.showFirstDigit)
    }

    func testTemplateCellRoundTripWithSymbology() throws {
        let cell = TemplateCell(content: .codeLibre("ABC123"), codeRendering: .barcode,
                                symbology: .code128,
                                codeOptions: CodeOptions(showText: false, showChevron: false, showFirstDigit: false))
        let data = try JSONEncoder().encode(cell)
        let decoded = try JSONDecoder().decode(TemplateCell.self, from: data)
        XCTAssertEqual(decoded.symbology, .code128)
        XCTAssertEqual(decoded.codeOptions.showChevron, false)
        XCTAssertEqual(decoded.codeOptions.showText, false)
    }

    /// Encode une cellule « code-barres article » puis retire les clés symbology/codeOptions du
    /// JSON pour simuler un ancien enregistrement.
    private func minimalBarcodeCellJSON() throws -> Data {
        let cell = TemplateCell(content: .codeBarres, codeRendering: .barcode)
        var obj = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(cell)) as! [String: Any]
        obj.removeValue(forKey: "symbology")
        obj.removeValue(forKey: "codeOptions")
        return try JSONSerialization.data(withJSONObject: obj)
    }
}
