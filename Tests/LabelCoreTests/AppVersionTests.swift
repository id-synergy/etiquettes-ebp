import XCTest
@testable import LabelCore

final class AppVersionTests: XCTestCase {
    func testEqualVersions() {
        XCTAssertEqual(AppVersion.compare("1.1", "1.1"), .orderedSame)
        XCTAssertEqual(AppVersion.compare("1.1", "1.1.0"), .orderedSame)   // zéros implicites
        XCTAssertEqual(AppVersion.compare("1.0.0", "1"), .orderedSame)
    }

    func testOrdering() {
        XCTAssertTrue(AppVersion.isNewer("1.1", than: "1.0"))
        XCTAssertTrue(AppVersion.isNewer("1.1.1", than: "1.1"))
        XCTAssertTrue(AppVersion.isNewer("2.0", than: "1.9"))
        XCTAssertFalse(AppVersion.isNewer("1.0", than: "1.1"))
        XCTAssertFalse(AppVersion.isNewer("1.1", than: "1.1"))
    }

    /// Le piège classique d'une comparaison de chaînes : "1.10" doit être plus récent que "1.9".
    func testNumericNotLexicographic() {
        XCTAssertTrue(AppVersion.isNewer("1.10", than: "1.9"))
        XCTAssertFalse(AppVersion.isNewer("1.9", than: "1.10"))
        XCTAssertTrue(AppVersion.isNewer("1.2", than: "1.10") == false)
    }

    func testTolerantParsing() {
        XCTAssertEqual(AppVersion.components("1.2.3"), [1, 2, 3])
        XCTAssertEqual(AppVersion.components(""), [])
        // Une version avec du bruit non numérique ne fait pas planter (composant → 0).
        XCTAssertEqual(AppVersion.components("1.0b.2"), [1, 0, 2])
    }
}
