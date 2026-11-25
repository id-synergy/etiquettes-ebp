import Foundation

/// Abstraction de la session HTTP, pour injecter un stub dans les tests (aucun réseau).
public protocol HTTPSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPSession {}

/// Configuration de connexion à la gateway : URL de base + jeton d'app (`gw_…`).
public struct GatewayConfig: Equatable, Sendable {
    public var baseURL: URL
    public var token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL; self.token = token
    }
}

/// Paramètres de requête des articles (`Items/ItemsExtentedQuery`).
public struct ItemsQuery: Equatable, Sendable {
    public var offset: Int
    public var limit: Int          // ≤ 100
    public var orderBy: String     // requis pour la pagination
    public var orderDescending: Bool  // sens du tri
    public var search: String?     // texte libre → WhereCondition (Caption/Id/BarCode/DesComClear, multi-mots)
    public var familyId: String?
    public var subFamilyId: String?
    public var priceMin: Decimal?  // filtre prix TTC ≥
    public var priceMax: Decimal?  // filtre prix TTC ≤
    public var activeOnly: Bool    // n'inclure que les articles actifs
    public var inStockOnly: Bool   // n'inclure que les articles en stock
    public var noCache: Bool

    public init(offset: Int = 0, limit: Int = 50, orderBy: String = "Id", orderDescending: Bool = false,
                search: String? = nil, familyId: String? = nil, subFamilyId: String? = nil,
                priceMin: Decimal? = nil, priceMax: Decimal? = nil,
                activeOnly: Bool = false, inStockOnly: Bool = false, noCache: Bool = false) {
        self.offset = offset
        self.limit = min(max(limit, 1), 100)
        self.orderBy = orderBy
        self.orderDescending = orderDescending
        self.search = search
        self.familyId = familyId
        self.subFamilyId = subFamilyId
        self.priceMin = priceMin
        self.priceMax = priceMax
        self.activeOnly = activeOnly
        self.inStockOnly = inStockOnly
        self.noCache = noCache
    }
}

/// Une page d'articles, avec sa pagination.
public struct ItemsPage: Equatable, Sendable {
    public let items: [EBPItem]
    public let paging: GatewayPaging?

    public init(items: [EBPItem], paging: GatewayPaging?) {
        self.items = items; self.paging = paging
    }

    /// Reste-t-il des pages à charger ? (une page pleine suggère un suivant)
    public var hasMore: Bool {
        guard let paging else { return false }
        return paging.offset + paging.returned < paging.total
    }
}

/// Client de la gateway EBP. `actor` pour sérialiser le polling de jobs.
/// Gère l'en-tête d'auth, `whoami`, la requête d'articles, et le flux 200 OU 202→jobs→résultat.
public actor GatewayClient {
    private let config: GatewayConfig
    private let session: HTTPSession
    /// Attente entre deux sondages de job (injectable pour des tests instantanés).
    private let sleep: @Sendable (Double) async -> Void
    /// Délai maximal total de polling avant abandon (secondes).
    private let maxPollSeconds: Double

    public init(config: GatewayConfig,
                session: HTTPSession = URLSession.shared,
                maxPollSeconds: Double = 30,
                sleep: @escaping @Sendable (Double) async -> Void = { seconds in
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                }) {
        self.config = config
        self.session = session
        self.maxPollSeconds = maxPollSeconds
        self.sleep = sleep
    }

    // MARK: - API publique

    /// Vérifie le jeton et renvoie le contexte résolu (app, compte, dossier). Pour « Tester la connexion ».
    public func whoami() async throws -> WhoAmI {
        let env: WhoAmI = try await getDecoded("api/v1/whoami", query: [])
        return env
    }

    /// Liste / recherche les articles. FolderId non nécessaire (résolu par le jeton).
    public func items(_ query: ItemsQuery) async throws -> ItemsPage {
        var q: [URLQueryItem] = [
            URLQueryItem(name: "Offset", value: String(query.offset)),
            URLQueryItem(name: "Limit", value: String(query.limit)),
            URLQueryItem(name: "OrderByValue", value: query.orderBy),
        ]
        if query.orderDescending {
            q.append(URLQueryItem(name: "OrderByDirection", value: "Descending"))
        }
        if let whereCondition = GatewayWhereCondition.and([
            query.search.flatMap(GatewayWhereCondition.search),
            query.familyId.flatMap(GatewayWhereCondition.family),
            query.subFamilyId.flatMap(GatewayWhereCondition.subFamily),
            query.priceMin.map(GatewayWhereCondition.priceAtLeast),
            query.priceMax.map(GatewayWhereCondition.priceAtMost),
            query.activeOnly ? GatewayWhereCondition.activeOnly() : nil,
            query.inStockOnly ? GatewayWhereCondition.inStock() : nil,
        ]) {
            q.append(URLQueryItem(name: "WhereCondition", value: whereCondition))
        }
        if query.noCache { q.append(URLQueryItem(name: "noCache", value: "1")) }

        let env: GatewayEnvelope<[EBPItem]> = try await getEnvelope("gescom/api/v1/Items/ItemsExtentedQuery", query: q)
        return ItemsPage(items: env.data, paging: env.paging)
    }

    /// Recherche un article par code-barres exact (scan). Renvoie le premier correspondant,
    /// ou nil si aucun article ne porte ce code. Interroge EBP directement : l'article n'a pas
    /// besoin d'être déjà chargé dans la liste.
    public func itemByBarcode(_ code: String) async throws -> EBPItem? {
        guard let condition = GatewayWhereCondition.barcode(code) else { return nil }
        let q: [URLQueryItem] = [
            URLQueryItem(name: "Offset", value: "0"),
            URLQueryItem(name: "Limit", value: "1"),
            URLQueryItem(name: "OrderByValue", value: "Id"),
            URLQueryItem(name: "WhereCondition", value: condition),
        ]
        let env: GatewayEnvelope<[EBPItem]> = try await getEnvelope("gescom/api/v1/Items/ItemsExtentedQuery", query: q)
        return env.data.first
    }

    // MARK: - Transport

    /// GET renvoyant une enveloppe `{data,…}`, en gérant 200 OU 202→job.
    private func getEnvelope<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> GatewayEnvelope<T> {
        let (data, status) = try await send(path: path, query: query)
        if status == 200 { return try decode(GatewayEnvelope<T>.self, from: data) }
        if status == 202 { return GatewayEnvelope(data: try await resolveJob(accepting: data)) }
        throw GatewayError.decode(status: status, body: data)
    }

    /// GET renvoyant un objet décodé directement (ex. whoami, pas d'enveloppe `data`).
    private func getDecoded<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> T {
        let (data, status) = try await send(path: path, query: query)
        guard status == 200 else { throw GatewayError.decode(status: status, body: data) }
        return try decode(T.self, from: data)
    }

    /// Envoie une requête GET authentifiée, renvoie le corps + le code HTTP.
    private func send(path: String, query: [URLQueryItem]) async throws -> (Data, Int) {
        guard var components = URLComponents(url: config.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw GatewayError.invalidConfig
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw GatewayError.invalidConfig }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (data, status)
        } catch let e as GatewayError {
            throw e
        } catch {
            throw GatewayError.transport(error.localizedDescription)
        }
    }

    /// Décode le 202 puis sonde le job jusqu'à son état terminal, et renvoie le résultat.
    private func resolveJob<T: Decodable>(accepting body: Data) async throws -> T {
        let accepted = try decode(GatewayJobAccepted.self, from: body)
        let interval = accepted.pollIntervalHint ?? 3
        let deadline = Date().addingTimeInterval(maxPollSeconds)

        while Date() < deadline {
            await sleep(interval)
            let (statusData, httpStatus) = try await send(path: "api/v1/jobs/\(accepted.jobId)", query: [])
            guard httpStatus == 200 else { throw GatewayError.decode(status: httpStatus, body: statusData) }
            let jobStatus = try decode(GatewayJobStatus.self, from: statusData)
            guard jobStatus.status.isTerminal else { continue }

            // Récupère le résultat (retry 1× sur 409 « pas encore terminé »).
            for attempt in 0..<2 {
                let (resultData, resultStatus) = try await send(path: "api/v1/jobs/\(accepted.jobId)/result", query: [])
                if resultStatus == 409 { if attempt == 0 { await sleep(interval); continue } else { break } }
                guard resultStatus == 200 else { throw GatewayError.decode(status: resultStatus, body: resultData) }
                let jobResult = try decode(GatewayJobResult<T>.self, from: resultData)
                if jobResult.status == .failed { throw GatewayError.jobFailed(jobResult.errors ?? []) }
                if let value = jobResult.result { return value }
                throw GatewayError.jobFailed(jobResult.errors ?? [])
            }
            break
        }
        throw GatewayError.jobTimedOut
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw GatewayError.decoding(error.localizedDescription) }
    }
}
