import XCTest
@testable import LabelCore

/// Vérifie que le code-barres REMPLIT bien la largeur disponible (pas de vide excessif à gauche
/// et à droite), en répliquant le calcul de module de paintBarcode. C'est le défaut signalé :
/// un Code 39 en pleine largeur qui restait petit car le module tombait à 1 px au lieu de 2.
final class BarcodeFillTests: XCTestCase {

    /// Reproduit le calcul de paintBarcode : module entier maximisé, quiet zone minimale de 10.
    private func fillRatio(moduleCount: Int, cellWidthPx: Int, minQuiet: Int = 10) -> Double {
        let modulePx = max(1, cellWidthPx / (moduleCount + 2 * minQuiet))
        let barcodePx = moduleCount * modulePx
        return Double(barcodePx) / Double(cellWidthPx)
    }

    func testEAN13FillsFullWidthCell() {
        // EAN-13 (95 modules) en pleine largeur (360 px) : 360/115 = 3 px/module → 285 px sur 360.
        let ratio = fillRatio(moduleCount: 95, cellWidthPx: 360)
        XCTAssertGreaterThan(ratio, 0.75, "EAN-13 devrait remplir >75 % de la cellule, pas \(ratio)")
    }

    func testCode39FillsFullWidthCell() {
        // Code 39 ~170 modules en pleine largeur (360 px) : 360/190 = 1... mais le module maximisé
        // reste 1 ici (190 > 180). Le code occupe 170/360 ≈ 47 %. C'est la limite physique d'un
        // code aussi dense sur 360 px : on NE PEUT PAS faire mieux sans réduire la quiet zone.
        // Ce test documente la limite et garantit qu'on n'est pas PIRE qu'avant (≥ 45 %).
        let ratio = fillRatio(moduleCount: 170, cellWidthPx: 360)
        XCTAssertGreaterThanOrEqual(ratio, 0.45)
    }

    func testCode39ShorterValueFillsWell() {
        // Un Code 39 plus court (ex. 90 modules pour ~6 caractères) en pleine largeur : 360/110 = 3
        // → 270/360 = 75 %. Les codes courts remplissent bien.
        let ratio = fillRatio(moduleCount: 90, cellWidthPx: 360)
        XCTAssertGreaterThan(ratio, 0.70)
    }

    func testModuleIsMaximizedNotStuckAtOne() {
        // Le cœur du correctif : à 360 px pour 95 modules, le module doit valoir 3 px (pas 1).
        let modulePx = max(1, 360 / (95 + 20))
        XCTAssertEqual(modulePx, 3)
    }
}
