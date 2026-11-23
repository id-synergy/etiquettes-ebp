import XCTest
@testable import LabelCore

/// Conformité ISO des encodeurs : on compare les modules produits aux motifs NORMÉS, pour un code
/// dont l'encodage est documenté. Si ces tests passent, une douchette lit le code à l'identique
/// d'un code généré par n'importe quel autre outil conforme.
///
/// Références : ISO/IEC 15420 (EAN/UPC), 16388 (Code 39). Les tables L/G/R et de parité sont celles
/// du standard EAN-13.
final class BarcodeISOConformanceTests: XCTestCase {

    private func bits(_ modules: [Bool]) -> String { modules.map { $0 ? "1" : "0" }.joined() }

    // MARK: EAN-13 — motif complet d'un code de référence

    func testEAN13ExactBitPatternReference() throws {
        // Code de référence 4006381333931 (exemple Stabilo, documenté).
        // Premier chiffre 4 → parité LGLLGG pour les 6 chiffres de gauche (0,0,6,3,8,1).
        // Droite (3,3,3,9,3,1) en R-code. Gardes 101 / 01010 / 101.
        let modules = try EAN13.modules(for: "4006381333931")
        let expected =
            "101" +
            "0001101" + "0100111" + "0101111" + "0111101" + "0001001" + "0110011" + // L G L L G G : 0 0 6 3 8 1
            "01010" +
            "1000010" + "1000010" + "1000010" + "1110100" + "1000010" + "1100110" + // R : 3 3 3 9 3 1
            "101"
        XCTAssertEqual(bits(modules), expected)
        XCTAssertEqual(modules.count, 95)
    }

    func testEAN13GuardPositions() throws {
        let m = try EAN13.modules(for: "4006381333931")
        XCTAssertEqual(Array(m[0..<3]).map { $0 }, [true, false, true])           // garde début 101
        XCTAssertEqual(Array(m[45..<50]).map { $0 }, [false, true, false, true, false]) // centrale 01010
        XCTAssertEqual(Array(m[92..<95]).map { $0 }, [true, false, true])          // garde fin 101
    }

    func testEAN13CheckDigitReference() throws {
        // Check digit normé : 400638133393 → 1 ; 590123412345 → 7.
        XCTAssertEqual(try EAN13.checksum(for: "400638133393"), 1)
        XCTAssertEqual(try EAN13.checksum(for: "590123412345"), 7)
    }

    // MARK: EAN-8 — motif complet

    func testEAN8ExactBitPatternReference() throws {
        // Référence 73513537 : gauche 7351 (L-code), droite 3537 (R-code), gardes 101/01010/101.
        let modules = try EAN8.modules(for: "73513537")
        let L = ["0001101","0011001","0010011","0111101","0100011","0110001","0101111","0111011","0110111","0001011"]
        let R = ["1110010","1100110","1101100","1000010","1011100","1001110","1010000","1000100","1001000","1110100"]
        let expected = "101" + L[7]+L[3]+L[5]+L[1] + "01010" + R[3]+R[5]+R[3]+R[7] + "101"
        XCTAssertEqual(bits(modules), expected)
        XCTAssertEqual(modules.count, 67)
    }

    func testEAN8CheckDigitReference() throws {
        // 7351353 → 7 (poids 3,1,3,1,3,1,3).
        XCTAssertEqual(try EAN8.checksum(for: "7351353"), 7)
    }

    // MARK: UPC-A — équivalence EAN-13 préfixé 0

    func testUPCAIsEAN13WithLeadingZero() throws {
        // UPC-A 036000291452 doit produire exactement les modules d'EAN-13 0036000291452.
        let upc = try UPCA.modules(for: "036000291452")
        let ean = try EAN13.modules(for: "0036000291452")
        XCTAssertEqual(bits(upc), bits(ean))
    }

    func testUPCACheckDigitReference() throws {
        // 03600029145 → 2 (exemple UPC documenté).
        XCTAssertEqual(try UPCA.checksum(for: "03600029145"), 2)
    }

    // MARK: Code 39 — start/stop et structure

    func testCode39StartStopAndStructure() throws {
        // "A" encadré par le start/stop *. Chaque caractère = 9 éléments ; 1 espace étroit entre.
        let modules = try Code39.modules(for: "A")
        // Commence et finit par une barre (début du motif de *).
        XCTAssertTrue(modules.first ?? false)
        XCTAssertTrue(modules.last ?? false)
        // 3 caractères (* A *) × 9 éléments, avec 2 espaces inter-caractères : structure non vide.
        XCTAssertGreaterThan(modules.count, 0)
    }

    func testCode39RejectsStar() {
        // Le caractère de start/stop ne doit pas être encodable comme donnée.
        XCTAssertFalse(Code39.isEncodable("A*B"))
    }
}
