import XCTest
@testable import LabelCore

final class QRPaginationTests: XCTestCase {

    /// Un gros payload JSON de référence (plusieurs pages garanties).
    private func bigPayload(_ n: Int = 4000) -> Data {
        Data((0..<n).map { UInt8(65 + ($0 % 26)) })
    }

    // MARK: - Découpage

    func testPaginateProducesSeveralPagesWithStableHeader() throws {
        let payload = bigPayload()
        let pages = try XCTUnwrap(QRPagination.paginate(payload, transferID: "AB23"))
        XCTAssertGreaterThan(pages.count, 1, "un payload de 4 Ko doit tenir sur plusieurs pages")
        let sig = QRPagination.signature(of: payload)
        for (i, raw) in pages.enumerated() {
            let page = try assertSuccess(QRPagination.parsePage(raw))
            XCTAssertEqual(page.transferID, "AB23")
            XCTAssertEqual(page.signature, sig)       // signature présente dès la 1re page
            XCTAssertEqual(page.index, i + 1)
            XCTAssertEqual(page.total, pages.count)
        }
    }

    func testEmptyPayloadHasNoPages() {
        XCTAssertNil(QRPagination.paginate(Data()))
    }

    func testEachPageStaysUnderLimit() throws {
        let pages = try XCTUnwrap(QRPagination.paginate(bigPayload(8000)))
        for raw in pages {
            XCTAssertLessThanOrEqual(raw.utf8.count, QRPagination.pageByteLimit)
        }
    }

    // MARK: - Reconstitution

    func testCollectInOrderReconstitutesExactly() throws {
        let payload = bigPayload()
        let pages = try XCTUnwrap(QRPagination.paginate(payload, transferID: "CD34"))
        var collector = QRPageCollector()
        var completed: Data?
        for (i, raw) in pages.enumerated() {
            let page = try assertSuccess(QRPagination.parsePage(raw))
            let result = collector.add(page)
            if i < pages.count - 1 {
                XCTAssertEqual(result, .added(received: i + 1, total: pages.count))
            } else if case .completed(let data) = result {
                completed = data
            } else {
                XCTFail("la dernière page devait compléter, obtenu \(result)")
            }
        }
        XCTAssertEqual(completed, payload)
    }

    func testCollectOutOfOrderStillWorks() throws {
        let payload = bigPayload()
        let pages = try XCTUnwrap(QRPagination.paginate(payload, transferID: "EF45")).shuffled()
        var collector = QRPageCollector()
        var completed: Data?
        for raw in pages {
            let page = try assertSuccess(QRPagination.parsePage(raw))
            if case .completed(let data) = collector.add(page) { completed = data }
        }
        XCTAssertEqual(completed, payload, "les pages doivent se recomposer quel que soit l'ordre de scan")
    }

    func testDuplicatePageIsReported() throws {
        let pages = try XCTUnwrap(QRPagination.paginate(bigPayload(), transferID: "GH56"))
        var collector = QRPageCollector()
        let first = try assertSuccess(QRPagination.parsePage(pages[0]))
        _ = collector.add(first)
        XCTAssertEqual(collector.add(first), .duplicate(received: 1, total: pages.count))
    }

    func testPageFromOtherTransferIsRejected() throws {
        let a = try XCTUnwrap(QRPagination.paginate(bigPayload(), transferID: "AAAA"))
        let b = try XCTUnwrap(QRPagination.paginate(bigPayload(3000), transferID: "BBBB"))
        var collector = QRPageCollector()
        _ = collector.add(try assertSuccess(QRPagination.parsePage(a[0])))
        XCTAssertEqual(collector.add(try assertSuccess(QRPagination.parsePage(b[0]))), .otherTransfer)
    }

    // MARK: - Signature corrompue

    func testCorruptedChunkFailsSignature() throws {
        let payload = bigPayload()
        let pages = try XCTUnwrap(QRPagination.paginate(payload, transferID: "IJ67"))
        // On altère la tranche d'une page tout en gardant l'en-tête (id/sig/total valides).
        var collector = QRPageCollector()
        var sawMismatch = false
        for (i, raw) in pages.enumerated() {
            let toParse = (i == 0) ? corruptBody(of: raw) : raw
            guard case .success(let page) = QRPagination.parsePage(toParse) else { continue }
            if collector.add(page) == .signatureMismatch { sawMismatch = true }
        }
        XCTAssertTrue(sawMismatch, "une page altérée doit faire échouer la vérification de signature")
    }

    /// Remplace la tranche base64url d'une page par une autre tranche valide mais fausse.
    private func corruptBody(of raw: String) -> String {
        var fields = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 6 else { return raw }
        // base64url d'octets différents, même longueur approximative.
        fields[5] = QRPagination.base64url(Data(repeating: 0x7A, count: 24))
        return fields.joined(separator: "|")
    }

    // MARK: - Round-trip bout en bout avec un vrai payload de réglages

    func testPrinterSettingsRoundTripThroughPages() throws {
        var payload = PrinterSettingsPayload(brand: .netum)
        payload.netum = NetumOptions()
        let json = payload.encoded()
        let pages = try XCTUnwrap(QRPagination.paginate(json, transferID: "KL78"))
        var collector = QRPageCollector()
        var completed: Data?
        for raw in pages.shuffled() {
            let page = try assertSuccess(QRPagination.parsePage(raw))
            if case .completed(let data) = collector.add(page) { completed = data }
        }
        let data = try XCTUnwrap(completed)
        guard case .success(let decoded) = PrinterSettingsPayload.decode(data) else {
            return XCTFail("le JSON reconstitué doit redonner un payload valide")
        }
        XCTAssertEqual(decoded.brand, .netum)
    }

    // MARK: - Non-paginé

    func testPlainQRIsNotAPage() {
        XCTAssertEqual(QRPagination.parsePage("{\"version\":1}"), .failure(.notPaginated))
    }

    // MARK: - Helpers

    private func assertSuccess<T, E>(_ result: Result<T, E>, file: StaticString = #filePath,
                                     line: UInt = #line) throws -> T {
        switch result {
        case .success(let value): return value
        case .failure(let error): XCTFail("attendu succès, obtenu \(error)", file: file, line: line); throw error
        }
    }
}
