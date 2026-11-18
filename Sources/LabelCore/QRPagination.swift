import Foundation
import CryptoKit

/// Partage d'un payload d'échange (modèles ou réglages) en PLUSIEURS QR codes, quand il est trop
/// long pour un seul QR scannable. Le JSON complet est découpé en tranches ; chaque tranche
/// devient un QR. Le récepteur scanne toutes les pages (dans n'importe quel ordre), reconstitue le
/// JSON, puis VÉRIFIE qu'il correspond à la signature annoncée dès la première page.
///
/// Pur (aucune dépendance UIKit) : testable et partagé entre la lib et l'app.
///
/// Format d'une page (texte d'un QR), champs séparés par `|` :
///
///     EBPQRP1|<transferID>|<page>|<total>|<sig>|<tranche base64url>
///
/// - `EBPQRP1` : marqueur + version du format paginé (rejet propre d'une version future).
/// - `transferID` : identifiant court d'un transfert, pour ne pas mélanger deux partages.
/// - `page` / `total` : 1…total. Les pages peuvent être scannées dans le désordre.
/// - `sig` : SIGNATURE du JSON complet (SHA-256 tronqué, hex), présente sur CHAQUE page. Permet,
///   dès la première page scannée, de connaître la cible et, à la fin, de vérifier l'intégrité.
/// - tranche : portion du JSON encodée en base64url (sans `=`, sans `+`/`/`, donc sûre en QR).
public enum QRPagination {
    /// Marqueur + version du format de page. Incrémenté si la structure change.
    public static let marker = "EBPQRP1"
    /// Séparateur de champs. Absent du base64url et de l'hex, donc non ambigu.
    static let separator: Character = "|"

    /// Taille max d'une page QR (texte complet, marqueur et en-tête compris). On reste bien sous la
    /// limite scannable d'un QR confortable : une tranche de JSON + ~40 octets d'en-tête.
    public static let pageByteLimit = 480

    /// Signature courte et déterministe du JSON complet : SHA-256 tronqué à 8 octets (16 hex).
    /// Assez pour détecter une page corrompue, un mélange de transferts ou une reconstitution ratée.
    public static func signature(of payload: Data) -> String {
        let digest = SHA256.hash(data: payload)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Émission (découpage)

    /// Découpe `payload` (le JSON complet) en pages QR. Renvoie `nil` si le payload est vide.
    /// `transferID` est généré si non fourni (tests : on peut le figer).
    public static func paginate(_ payload: Data, transferID: String? = nil) -> [String]? {
        guard !payload.isEmpty else { return nil }
        let id = transferID ?? randomTransferID()
        let sig = signature(of: payload)
        let chunks = chunk(payload, headerOverhead: headerOverhead(id: id, signature: sig))
        let total = chunks.count
        return chunks.enumerated().map { index, chunk in
            let body = base64url(chunk)
            return [marker, id, String(index + 1), String(total), sig, body]
                .joined(separator: String(separator))
        }
    }

    /// Taille fixe de l'en-tête d'une page (tout sauf la tranche), pour dimensionner les tranches.
    private static func headerOverhead(id: String, signature: String) -> Int {
        // marker | id | page | total | sig | — on majore page/total à 4 chiffres chacun.
        marker.count + 1 + id.count + 1 + 4 + 1 + 4 + 1 + signature.count + 1
    }

    /// Découpe les octets en tranches dont la version base64url tient sous `pageByteLimit`.
    private static func chunk(_ data: Data, headerOverhead: Int) -> [Data] {
        // base64 fait grossir d'environ 4/3 ; on prend une tranche brute telle que sa version
        // encodée + l'en-tête reste sous la limite. On garde une marge de sécurité.
        let budget = max(16, pageByteLimit - headerOverhead)
        let rawPerPage = max(16, (budget * 3) / 4 - 2)
        var chunks: [Data] = []
        var index = 0
        while index < data.count {
            let end = min(index + rawPerPage, data.count)
            chunks.append(data.subdata(in: index..<end))
            index = end
        }
        return chunks
    }

    private static func randomTransferID() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")   // sans I,O,0,1 ambigus
        return String((0..<4).map { _ in alphabet.randomElement()! })
    }

    // MARK: - base64url

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func dataFromBase64url(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+")
                      .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }

    // MARK: - Réception (une page scannée)

    /// Une page décodée d'un QR : ses métadonnées et sa tranche.
    public struct Page: Equatable {
        public let transferID: String
        public let index: Int      // 1-based
        public let total: Int
        public let signature: String
        public let chunk: Data
    }

    public enum PageError: Error, Equatable {
        case notPaginated          // ce n'est pas un QR de partage paginé (autre QR)
        case malformed             // marqueur présent mais structure cassée
    }

    /// Analyse le texte d'un QR scanné comme une page de partage. `notPaginated` si le QR n'est pas
    /// un partage paginé (l'appelant peut alors essayer de le lire comme un QR simple).
    public static func parsePage(_ raw: String) -> Result<Page, PageError> {
        let fields = raw.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
        guard let first = fields.first, first == marker else { return .failure(.notPaginated) }
        guard fields.count == 6,
              let index = Int(fields[2]), let total = Int(fields[3]),
              index >= 1, total >= 1, index <= total,
              !fields[1].isEmpty, !fields[4].isEmpty,
              let chunk = dataFromBase64url(fields[5]) else {
            return .failure(.malformed)
        }
        return .success(Page(transferID: fields[1], index: index, total: total,
                             signature: fields[4], chunk: chunk))
    }
}

/// Collecte les pages d'UN transfert et reconstitue le JSON quand elles sont toutes là. Verrouille
/// le transfert sur la première page reçue (id + signature + total) : une page d'un autre transfert
/// est signalée, pas silencieusement mélangée.
public struct QRPageCollector {
    public private(set) var transferID: String?
    public private(set) var signature: String?
    public private(set) var total: Int = 0
    private var chunks: [Int: Data] = [:]

    public init() {}

    public enum AddResult: Equatable {
        case added(received: Int, total: Int)        // page acceptée, il en manque encore
        case duplicate(received: Int, total: Int)    // page déjà reçue
        case otherTransfer                           // page d'un AUTRE transfert (id/sig différent)
        case completed(Data)                         // toutes les pages là ET signature vérifiée
        case signatureMismatch                       // tout reçu mais le JSON ne correspond pas à la signature
    }

    /// Nombre de pages déjà reçues, et total attendu (0 tant qu'aucune page).
    public var progress: (received: Int, total: Int) { (chunks.count, total) }

    /// Intègre une page scannée. Au premier appel, fixe l'identité du transfert.
    public mutating func add(_ page: QRPagination.Page) -> AddResult {
        if transferID == nil {
            transferID = page.transferID
            signature = page.signature
            total = page.total
        } else if page.transferID != transferID || page.signature != signature || page.total != total {
            return .otherTransfer
        }
        if chunks[page.index] != nil {
            return .duplicate(received: chunks.count, total: total)
        }
        chunks[page.index] = page.chunk
        guard chunks.count == total else {
            return .added(received: chunks.count, total: total)
        }
        // Toutes les pages sont là : on recompose dans l'ordre et on vérifie la signature.
        var data = Data()
        for i in 1...total {
            guard let chunk = chunks[i] else { return .added(received: chunks.count, total: total) }
            data.append(chunk)
        }
        guard QRPagination.signature(of: data) == signature else { return .signatureMismatch }
        return .completed(data)
    }

    /// Repart de zéro (nouveau transfert, ou après un échec de signature).
    public mutating func reset() {
        transferID = nil; signature = nil; total = 0; chunks = [:]
    }
}
