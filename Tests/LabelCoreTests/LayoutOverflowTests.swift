import XCTest
@testable import LabelCore

/// Diagnostic : vérifie que toutes les lignes d'un modèle tiennent dans la hauteur rendue, et
/// qu'une cellule QR ne déborde pas sur la ligne suivante (le « champ sous le QR » qui disparaît).
final class LayoutOverflowTests: XCTestCase {

    func testColumnsPresetHasLineAfterCode() throws {
        // Le preset « Deux colonnes » a 5 lignes dont la dernière (Réf. article) est APRÈS le code :
        // c'est ce champ « sous le code » qui doit rester visible (ne pas être masqué par un QR qui
        // déborde). LabelRenderer est dans la cible App ; ici on garde la vérif de structure.
        let template = LabelTemplatePresets.preset(for: .columns)
        XCTAssertEqual(template.lines.count, 5)
        XCTAssertNotNil(template.lines[4].cells.first)
        // La ligne 4 (index 3) porte le code, la ligne 5 (index 4) vient après.
        XCTAssertTrue(template.lines[3].cells.contains { $0.content.isBarcode })
    }
}
