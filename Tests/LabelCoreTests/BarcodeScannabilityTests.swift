import XCTest
@testable import LabelCore

/// Garde-fou de scannabilité : vérifie que le verdict correspond au module obtenu après
/// rastérisation entière, pour les largeurs de cellule réelles de l'app (base 5890, 384 pt).
final class BarcodeScannabilityTests: XCTestCase {

    // Largeurs réelles (base 5890, scale 1 : 1 pt = 1 px), cf. computeLineRows du renderer.
    private let fullWidthPx = 384 - 2 * 12                 // 360
    private let twoColWidthPx = (384 - 2 * 12) / 2 - 6     // 174

    func testEAN13FullWidthIsReliable() {
        // 360 px / (95 + 20) = 3 px/module → fiable.
        let a = BarcodeScannability.assess(cellWidthPx: fullWidthPx, barsHeightPx: 42, symbology: .ean13)
        XCTAssertEqual(a.level, .reliable)
        XCTAssertEqual(a.modulePx, 3)
    }

    func testEAN13TwoColumnsIsRisky() {
        // 174 px / 115 = 1 px/module → risqué (c'est le cas « des fois ça passe pas »).
        let a = BarcodeScannability.assess(cellWidthPx: twoColWidthPx, barsHeightPx: 42, symbology: .ean13)
        XCTAssertEqual(a.level, .risky)
        XCTAssertEqual(a.modulePx, 1)
    }

    func testEAN8TwoColumnsIsReliable() {
        // EAN-8 (67 modules) : 174 / 87 = 2 px/module → fiable même en deux colonnes.
        let a = BarcodeScannability.assess(cellWidthPx: twoColWidthPx, barsHeightPx: 42, symbology: .ean8)
        XCTAssertEqual(a.level, .reliable)
        XCTAssertEqual(a.modulePx, 2)
    }

    func testShortBarsDowngradeToRisky() {
        // Module fiable mais barres trop courtes → risqué.
        let a = BarcodeScannability.assess(cellWidthPx: fullWidthPx, barsHeightPx: 10, symbology: .ean13)
        XCTAssertEqual(a.level, .risky)
    }

    func testTooNarrowIsUnreadable() {
        // Largeur insuffisante pour poser un seul module + quiet zones.
        let a = BarcodeScannability.assess(cellWidthPx: 50, barsHeightPx: 42, symbology: .ean13)
        XCTAssertEqual(a.level, .unreadable)
        XCTAssertEqual(a.modulePx, 0)
    }

    func testMinCellWidthMatchesReliableThreshold() {
        // À la largeur minimale annoncée, l'évaluation doit être fiable (hauteur suffisante).
        let minW = BarcodeScannability.minCellWidthPx(for: .ean13)
        XCTAssertEqual(minW, (95 + 20) * 2)
        let a = BarcodeScannability.assess(cellWidthPx: minW, barsHeightPx: 42, symbology: .ean13)
        XCTAssertEqual(a.level, .reliable)
    }

    func testModuleCountOverrideUsesRealLength() {
        // Avec un moduleCount réel plus court, le verdict s'améliore.
        let a = BarcodeScannability.assess(cellWidthPx: twoColWidthPx, barsHeightPx: 42,
                                           symbology: .code128, moduleCount: 60)
        // 174 / 80 = 2 px/module → fiable.
        XCTAssertEqual(a.level, .reliable)
    }
}
