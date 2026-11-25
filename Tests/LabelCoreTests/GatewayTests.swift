import XCTest
@testable import LabelCore

final class GatewayTests: XCTestCase {

    // MARK: - Mapper

    private func makeItem(_ json: String) throws -> EBPItem {
        try JSONDecoder().decode(EBPItem.self, from: Data(json.utf8))
    }

    func testMapperHappyPath() throws {
        let json = #"""
        {
            "Id": " 1 619 P04 220 ",
            "Caption": "CHARBONS BOSCH 1 619 P04 220",
            "DesComClear": "CHARBONS BOSCH 1 619 P04 220",
            "SalePriceVatIncluded": 4.75200000,
            "SalePriceVatExcluded": 3.96000000,
            "BarCode": "0000000550598",
            "ShelfRef": 1,
            "FamilyId": "FAR00004"
        }
        """#
        let mapped = EBPProductMapper.map(try makeItem(json), locale: Locale(identifier: "fr_FR"))
        XCTAssertEqual(mapped.label.name, "CHARBONS BOSCH 1 619 P04 220")
        XCTAssertEqual(mapped.label.price, "4,75")          // TTC arrondi 2 déc.
        XCTAssertEqual(mapped.priceExclVat, "3,96")         // HT, écran only
        XCTAssertEqual(mapped.label.productReference, "1 619 P04 220") // trim
        XCTAssertEqual(mapped.label.shelfReference, "1")
        XCTAssertEqual(mapped.label.category, "FAR00004")
        XCTAssertEqual(mapped.label.currency, .eur)
        XCTAssertEqual(mapped.label.priceCaption, "Prix de vente TTC")
        XCTAssertFalse(mapped.eanWasInvalid)
        XCTAssertEqual(mapped.label.ean, "0000000550598")   // zéros en tête préservés
    }

    func testMapperBadChecksumKeepsRawBarcode() throws {
        // Code 13 chiffres avec clé de contrôle fausse → conservé brut, article non rejeté.
        let json = #"{ "Caption": "Produit X", "BarCode": "0000000550599", "SalePriceVatIncluded": 1.0 }"#
        let mapped = EBPProductMapper.map(try makeItem(json))
        XCTAssertTrue(mapped.eanWasInvalid)
        XCTAssertEqual(mapped.label.ean, "0000000550599")   // brut, non modifié
        XCTAssertEqual(mapped.label.name, "Produit X")      // l'article reste mappé
    }

    func testMapperCompletesTwelveDigitBarcode() throws {
        // 12 chiffres → la clé est calculée et ajoutée.
        let json = #"{ "Caption": "P", "BarCode": "400638133393" }"#
        let mapped = EBPProductMapper.map(try makeItem(json))
        XCTAssertFalse(mapped.eanWasInvalid)
        XCTAssertEqual(mapped.label.ean, "4006381333931")
    }

    func testMapperRounding() throws {
        let up = #"{ "Caption": "P", "SalePriceVatIncluded": 5.95500000 }"#
        XCTAssertEqual(EBPProductMapper.map(try makeItem(up)).label.price, "5,96")
        let down = #"{ "Caption": "P", "SalePriceVatIncluded": 5.94499999 }"#
        XCTAssertEqual(EBPProductMapper.map(try makeItem(down)).label.price, "5,94")
    }

    func testMapperMissingFieldsAreSafe() throws {
        let json = #"{ "Caption": "Juste un libellé", "Id": "REF1" }"#
        let mapped = EBPProductMapper.map(try makeItem(json))
        XCTAssertEqual(mapped.label.name, "Juste un libellé")
        XCTAssertEqual(mapped.label.productReference, "REF1")
        XCTAssertEqual(mapped.label.price, "")
        XCTAssertNil(mapped.priceExclVat)
        XCTAssertEqual(mapped.label.ean, "")
        XCTAssertFalse(mapped.eanWasInvalid)
    }

    func testMapperDetailsVatStockLogistics() throws {
        let json = #"""
        {
            "Caption": "Motoréducteur", "SalePriceVatExcluded": 420.0, "SalePriceVatIncluded": 504.0,
            "VatAmount": 84.0, "RealStock": 5.0, "VirtualStock": 8.0,
            "SupplierId": "FR01066", "UnitId": "UNIT", "Weight": 12.5, "Volume": 0.035,
            "SubFamilyId": "SF001", "ActiveState": 0
        }
        """#
        let d = EBPProductMapper.map(try makeItem(json)).details
        XCTAssertEqual(d.vatAmount, "84,00")
        XCTAssertEqual(d.vatRatePercent, "20")        // 84 / 420 = 20 %
        XCTAssertEqual(d.realStock, "5")
        XCTAssertEqual(d.virtualStock, "8")
        XCTAssertEqual(d.supplierId, "FR01066")
        XCTAssertEqual(d.unitId, "UNIT")
        XCTAssertEqual(d.weight, "12,5")
        XCTAssertEqual(d.volume, "0,035")
        XCTAssertEqual(d.subFamilyId, "SF001")
        XCTAssertEqual(d.isActive, true)
    }

    func testMapperPopulatesLabelAdditionalFields() throws {
        // Les nouveaux champs bindables remontent DANS le label, déjà formatés (jamais la valeur
        // brute EBP) : prix HT/TVA en monnaie, stock/poids/volume en quantités nettoyées, codes
        // tels quels. Les montants arrivent en 8 décimales comme chez EBP.
        let json = #"""
        {
            "Caption": "Motoréducteur", "SalePriceVatExcluded": "420.00000000",
            "SalePriceVatIncluded": "504.00000000", "VatAmount": "84.00000000",
            "RealStock": "5.00000000", "VirtualStock": "8.00000000",
            "SupplierId": "FR01066", "UnitId": "UNIT", "Weight": "12.50000000",
            "Volume": "0.03500000", "SubFamilyId": "SF001"
        }
        """#
        let label = EBPProductMapper.map(try makeItem(json), locale: Locale(identifier: "fr_FR")).label
        XCTAssertEqual(label.priceExclVat, "420,00 €")   // monnaie, pas « 420.00000000 »
        XCTAssertEqual(label.vatAmount, "84,00 €")
        XCTAssertEqual(label.realStock, "5")             // nettoyé des zéros
        XCTAssertEqual(label.virtualStock, "8")
        XCTAssertEqual(label.supplier, "FR01066")        // code tel quel
        XCTAssertEqual(label.unit, "UNIT")
        XCTAssertEqual(label.weight, "12,5")
        XCTAssertEqual(label.volume, "0,035")
        XCTAssertEqual(label.subFamily, "SF001")
    }

    func testMapperAdditionalFieldsNilWhenAbsent() throws {
        let label = EBPProductMapper.map(try makeItem(#"{ "Caption": "P" }"#)).label
        XCTAssertNil(label.priceExclVat)
        XCTAssertNil(label.vatAmount)
        XCTAssertNil(label.realStock)
        XCTAssertNil(label.virtualStock)
        XCTAssertNil(label.supplier)
        XCTAssertNil(label.unit)
        XCTAssertNil(label.weight)
        XCTAssertNil(label.volume)
        XCTAssertNil(label.subFamily)
    }

    func testMapperVatRateFallsBackToTtcMinusHt() throws {
        // Pas de VatAmount : le taux se déduit de (TTC − HT) / HT.
        let json = #"{ "Caption": "P", "SalePriceVatExcluded": 100.0, "SalePriceVatIncluded": 120.0 }"#
        let d = EBPProductMapper.map(try makeItem(json)).details
        XCTAssertNil(d.vatAmount)
        XCTAssertEqual(d.vatRatePercent, "20")
    }

    func testMapperDetailsAbsentAreNil() throws {
        let json = #"{ "Caption": "P" }"#
        let d = EBPProductMapper.map(try makeItem(json)).details
        XCTAssertFalse(d.hasAny)
        XCTAssertNil(d.vatRatePercent)
        XCTAssertNil(d.isActive)
    }

    func testMapperInactiveState() throws {
        let json = #"{ "Caption": "P", "ActiveState": 1 }"#
        XCTAssertEqual(EBPProductMapper.map(try makeItem(json)).details.isActive, false)
    }

    func testMapperZeroWeightVolumeHiddenButZeroVatShown() throws {
        // Poids/volume nuls → masqués (0 = non renseigné en logistique).
        // TVA : un montant explicite, même 0 (article exonéré), reste affiché.
        let json = #"{ "Caption": "P", "SalePriceVatExcluded": 100.0, "SalePriceVatIncluded": 100.0, "VatAmount": 0.0, "Volume": 0.0, "Weight": 0.0 }"#
        let d = EBPProductMapper.map(try makeItem(json)).details
        XCTAssertEqual(d.vatAmount, "0,00")
        XCTAssertEqual(d.vatRatePercent, "0")   // taux 0 % explicite
        XCTAssertNil(d.volume)
        XCTAssertNil(d.weight)
    }

    func testMapperPrefersDesComClearOverCaption() throws {
        let json = #"{ "Caption": "RTF brut", "DesComClear": "Texte propre" }"#
        XCTAssertEqual(EBPProductMapper.map(try makeItem(json)).label.name, "Texte propre")
    }

    func testMapperAcceptsStringAmounts() throws {
        // EBP (et le faux serveur) peuvent renvoyer les montants en chaîne.
        let json = #"{ "Caption": "P", "SalePriceVatIncluded": "504.00000000", "SalePriceVatExcluded": "420.00000000" }"#
        let mapped = EBPProductMapper.map(try makeItem(json))
        XCTAssertEqual(mapped.label.price, "504,00")
        XCTAssertEqual(mapped.priceExclVat, "420,00")
    }

    // MARK: - Enveloppe

    func testEnvelopeListDecoding() throws {
        let json = #"""
        {
            "data": [ { "Id": "A", "Caption": "Article A" }, { "Id": "B", "Caption": "Article B" } ],
            "paging": { "offset": 0, "limit": 100, "total": 2, "returned": 2 },
            "folder": { "id": "1001", "label": "Société Démo" }
        }
        """#
        let env = try JSONDecoder().decode(GatewayEnvelope<[EBPItem]>.self, from: Data(json.utf8))
        XCTAssertEqual(env.data.count, 2)
        XCTAssertEqual(env.paging, GatewayPaging(offset: 0, limit: 100, total: 2, returned: 2))
        XCTAssertEqual(env.folderId, "1001")   // objet {id,label} → id
        XCTAssertNil(env.cached)
    }

    func testEnvelopeCachedFlag() throws {
        let json = #"{ "data": [], "paging": null, "folder": null, "cached": true }"#
        let env = try JSONDecoder().decode(GatewayEnvelope<[EBPItem]>.self, from: Data(json.utf8))
        XCTAssertEqual(env.cached, true)
        XCTAssertTrue(env.data.isEmpty)
    }

    func testEnvelopeSingleObject() throws {
        let json = #"{ "data": { "Id": "A", "Caption": "Seul" } }"#
        let env = try JSONDecoder().decode(GatewayEnvelope<EBPItem>.self, from: Data(json.utf8))
        XCTAssertEqual(env.data.caption, "Seul")
    }

    func testWhoAmIDecoding() throws {
        let json = #"{ "app": "Logiciel tickets", "account": "Atelier Démo", "folder": { "id": "1001", "label": "Société Démo" } }"#
        let who = try JSONDecoder().decode(WhoAmI.self, from: Data(json.utf8))
        XCTAssertEqual(who.app, "Logiciel tickets")
        XCTAssertEqual(who.account, "Atelier Démo")
        XCTAssertEqual(who.folder?.id, "1001")
    }

    // MARK: - Erreurs

    func testErrorDecodingFolderRequired() {
        let body = Data(#"{ "error": "folder_required", "message": "Aucun dossier ciblé" }"#.utf8)
        XCTAssertEqual(GatewayError.decode(status: 400, body: body), .folderRequired("Aucun dossier ciblé"))
    }

    func testErrorDecodingUnauthorized() {
        let body = Data(#"{ "message": "Jeton d'application invalide ou révoqué." }"#.utf8)
        XCTAssertEqual(GatewayError.decode(status: 401, body: body), .unauthorized("Jeton d'application invalide ou révoqué."))
    }

    func testErrorDecodingForbidden() {
        let body = Data(#"{ "message": "Compte EBP indisponible pour ce jeton." }"#.utf8)
        XCTAssertEqual(GatewayError.decode(status: 403, body: body), .forbidden("Compte EBP indisponible pour ce jeton."))
    }

    // MARK: - WhereCondition

    func testWhereConditionSearch() {
        XCTAssertNil(GatewayWhereCondition.search("   "))
        // Un seul mot : interroge les 4 champs (libellé, réf., code-barres, description) en « or ».
        XCTAssertEqual(GatewayWhereCondition.search("bosch"),
                       "contains(Caption,'bosch') or contains(Id,'bosch') or contains(BarCode,'bosch') or contains(DesComClear,'bosch')")
        // Échappement des apostrophes.
        XCTAssertEqual(GatewayWhereCondition.search("l'outil"),
                       "contains(Caption,'l''outil') or contains(Id,'l''outil') or contains(BarCode,'l''outil') or contains(DesComClear,'l''outil')")
    }

    func testWhereConditionSearchMultipleWords() {
        // Multi-mots : chaque mot doit apparaître dans un champ (mots en « and », champs en « or »).
        XCTAssertEqual(GatewayWhereCondition.search("bosch 12"),
                       "(contains(Caption,'bosch') or contains(Id,'bosch') or contains(BarCode,'bosch') or contains(DesComClear,'bosch')) and (contains(Caption,'12') or contains(Id,'12') or contains(BarCode,'12') or contains(DesComClear,'12'))")
        // Espaces multiples / en bordure : ignorés (pas de clause vide).
        XCTAssertEqual(GatewayWhereCondition.search("  bosch   "),
                       "contains(Caption,'bosch') or contains(Id,'bosch') or contains(BarCode,'bosch') or contains(DesComClear,'bosch')")
    }

    func testWhereConditionAnd() {
        XCTAssertNil(GatewayWhereCondition.and([nil, nil]))
        XCTAssertEqual(GatewayWhereCondition.and(["A", nil]), "A")
        XCTAssertEqual(GatewayWhereCondition.and(["A", "B"]), "(A) and (B)")
    }

    func testWhereConditionFamilyAndPrice() {
        XCTAssertEqual(GatewayWhereCondition.family("FAR00004"), "FamilyId eq 'FAR00004'")
        XCTAssertEqual(GatewayWhereCondition.priceAtLeast(Decimal(string: "10.5")!), "SalePriceVatIncluded ge 10.5")
        XCTAssertEqual(GatewayWhereCondition.priceAtMost(Decimal(100)), "SalePriceVatIncluded le 100")
        // Composition famille + fourchette de prix.
        let combined = GatewayWhereCondition.and([
            GatewayWhereCondition.family("FAR00004"),
            GatewayWhereCondition.priceAtLeast(Decimal(10)),
            GatewayWhereCondition.priceAtMost(Decimal(50)),
        ])
        XCTAssertEqual(combined, "(FamilyId eq 'FAR00004') and (SalePriceVatIncluded ge 10) and (SalePriceVatIncluded le 50)")
    }

    func testWhereConditionSubFamilyStockActive() {
        XCTAssertEqual(GatewayWhereCondition.subFamily("SF001"), "SubFamilyId eq 'SF001'")
        XCTAssertNil(GatewayWhereCondition.subFamily("   "))
        XCTAssertEqual(GatewayWhereCondition.activeOnly(), "ActiveState eq 0")
        XCTAssertEqual(GatewayWhereCondition.inStock(), "RealStock gt 0")
        // Composition complète : famille + sous-famille + actif + stock.
        let combined = GatewayWhereCondition.and([
            GatewayWhereCondition.family("FAR00001"),
            GatewayWhereCondition.subFamily("SF001"),
            GatewayWhereCondition.activeOnly(),
            GatewayWhereCondition.inStock(),
        ])
        XCTAssertEqual(combined, "(FamilyId eq 'FAR00001') and (SubFamilyId eq 'SF001') and (ActiveState eq 0) and (RealStock gt 0)")
    }

    func testWhereConditionBarcode() {
        XCTAssertNil(GatewayWhereCondition.barcode("  "))
        XCTAssertEqual(GatewayWhereCondition.barcode("3660619000012"), "BarCode eq '3660619000012'")
        XCTAssertEqual(GatewayWhereCondition.barcode("l'o"), "BarCode eq 'l''o'")
    }

    // MARK: - Jobs (202)

    func testJobAcceptedDecoding() throws {
        let json = #"{ "jobId": "abc-123", "status": "pending", "pollIntervalHint": 3 }"#
        let accepted = try JSONDecoder().decode(GatewayJobAccepted.self, from: Data(json.utf8))
        XCTAssertEqual(accepted.jobId, "abc-123")
        XCTAssertEqual(accepted.status, .pending)
        XCTAssertEqual(accepted.pollIntervalHint, 3)
    }

    func testJobStateTerminal() {
        XCTAssertFalse(JobState.pending.isTerminal)
        XCTAssertFalse(JobState.running.isTerminal)
        XCTAssertTrue(JobState.done.isTerminal)
        XCTAssertTrue(JobState.partial.isTerminal)
        XCTAssertTrue(JobState.failed.isTerminal)
    }

    func testJobResultDoneDecoding() throws {
        let json = #"""
        { "jobId": "j1", "status": "done", "result": [ { "Id": "A", "Caption": "Article A" } ], "errors": null }
        """#
        let res = try JSONDecoder().decode(GatewayJobResult<[EBPItem]>.self, from: Data(json.utf8))
        XCTAssertEqual(res.status, .done)
        XCTAssertEqual(res.result?.count, 1)
        XCTAssertNil(res.errors)
    }

    func testJobResultFailedDecoding() throws {
        let json = #"{ "jobId": "j2", "status": "failed", "result": null, "errors": ["Quota EBP atteint"] }"#
        let res = try JSONDecoder().decode(GatewayJobResult<[EBPItem]>.self, from: Data(json.utf8))
        XCTAssertEqual(res.status, .failed)
        XCTAssertNil(res.result)
        XCTAssertEqual(res.errors, ["Quota EBP atteint"])
    }
}
