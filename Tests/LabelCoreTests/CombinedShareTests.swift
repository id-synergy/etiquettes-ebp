import XCTest
@testable import LabelCore

final class CombinedShareTests: XCTestCase {

    private func sampleTemplate(named name: String = "Rayon promo") -> LabelTemplate {
        LabelTemplate(name: name, lines: [
            .full(TemplateCell(content: .designation, style: CellStyle(alignH: .center, size: .l))),
            .full(TemplateCell(content: .codeBarres, style: CellStyle(size: .m)))
        ])
    }

    private func samplePrinter() -> PrinterSettingsPayload {
        var p = PrinterSettingsPayload(brand: .netum)
        p.netum = NetumOptions()
        p.copies = 3
        return p
    }

    // MARK: - Round-trip du bundle

    func testBundleRoundTripKeepsBothParts() throws {
        let bundle = CombinedSharePayload(templates: [sampleTemplate(named: "A"), sampleTemplate(named: "B")],
                                          printer: samplePrinter())
        let data = bundle.encoded()
        guard case .success(let decoded) = CombinedSharePayload.decode(data) else {
            return XCTFail("le bundle doit se décoder")
        }
        XCTAssertEqual(decoded.templates.count, 2)
        XCTAssertEqual(decoded.printer?.brand, .netum)
        XCTAssertEqual(decoded.printer?.copies, 3)
    }

    func testBundleTemplatesAreUnlocked() throws {
        // Un preset verrouillé passé dans un bundle doit devenir un modèle perso éditable.
        let locked = LabelTemplatePresets.default
        XCTAssertTrue(locked.isLocked)
        let bundle = CombinedSharePayload(templates: [locked], printer: nil)
        XCTAssertEqual(bundle.templates.first?.isLocked, false)
    }

    func testBundleWithOnlyTemplates() throws {
        let bundle = CombinedSharePayload(templates: [sampleTemplate()], printer: nil)
        guard case .success(let decoded) = CombinedSharePayload.decode(bundle.encoded()) else {
            return XCTFail("bundle sans réglages doit rester valide")
        }
        XCTAssertEqual(decoded.templates.count, 1)
        XCTAssertNil(decoded.printer?.brand)
    }

    func testEmptyBundleRejected() {
        let empty = CombinedSharePayload(templates: [], printer: nil)
        XCTAssertEqual(CombinedSharePayload.decode(empty.encoded()), .failure(.empty))
    }

    // MARK: - Import universel (routage par kind)

    func testAnyDecodeRoutesBundle() throws {
        let data = CombinedSharePayload(templates: [sampleTemplate()], printer: samplePrinter()).encoded()
        guard case .success(.bundle(let b)) = AnySharePayload.decode(data) else {
            return XCTFail("un bundle doit être routé vers .bundle")
        }
        XCTAssertEqual(b.templates.count, 1)
        XCTAssertEqual(b.printer?.brand, .netum)
    }

    func testAnyDecodeRoutesTemplates() throws {
        let data = TemplateSharePayload(templates: [sampleTemplate()]).encoded()
        guard case .success(.templates(let t)) = AnySharePayload.decode(data) else {
            return XCTFail("des modèles doivent être routés vers .templates")
        }
        XCTAssertEqual(t.templates.count, 1)
    }

    func testAnyDecodeRoutesPrinter() throws {
        let data = samplePrinter().encoded()
        guard case .success(.printer(let p)) = AnySharePayload.decode(data) else {
            return XCTFail("des réglages doivent être routés vers .printer")
        }
        XCTAssertEqual(p.brand, .netum)
    }

    func testAnyDecodeRejectsNonJSON() {
        XCTAssertEqual(AnySharePayload.decode(Data("pas du json".utf8)), .failure(.notJSON))
    }

    func testAnyDecodeFromQRString() throws {
        let raw = String(decoding: TemplateSharePayload(templates: [sampleTemplate()]).encoded(), as: UTF8.self)
        guard case .success(.templates) = AnySharePayload.decode(fromQRString: raw) else {
            return XCTFail("décodage depuis une chaîne QR attendu")
        }
    }
}

extension AnySharePayload: Equatable {
    public static func == (lhs: AnySharePayload, rhs: AnySharePayload) -> Bool {
        switch (lhs, rhs) {
        case (.templates(let a), .templates(let b)): return a == b
        case (.printer(let a), .printer(let b)): return a == b
        case (.bundle(let a), .bundle(let b)): return a == b
        default: return false
        }
    }
}
