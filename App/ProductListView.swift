import SwiftUI
import AudioToolbox

/// Modèle de recherche d'articles EBP via la gateway : pagination, scroll infini,
/// anti-rebond de la saisie. Les types LabelCore (GatewayClient, EBPItem…) sont in-module.
@MainActor
final class EBPSearchModel: ObservableObject {
    enum Phase: Equatable { case idle, loading, loaded, loadingMore, error(String) }

    /// Critères de tri proposés à l'utilisateur.
    enum SortField: String, CaseIterable, Identifiable {
        case reference, caption, price
        var id: String { rawValue }
        /// Champ EBP correspondant (OrderByValue).
        var ebpField: String {
            switch self {
            case .reference: return "Id"
            case .caption: return "Caption"
            case .price: return "SalePriceVatIncluded"
            }
        }
        var title: String {
            switch self {
            case .reference: return NSLocalizedString("Référence", comment: "Sort by reference")
            case .caption: return NSLocalizedString("Libellé", comment: "Sort by caption")
            case .price: return NSLocalizedString("Prix", comment: "Sort by price")
            }
        }
    }

    @Published var query = ""
    @Published var familyFilter = ""        // id de famille (ex. FAR00004), vide = toutes
    @Published var subFamilyFilter = ""     // id de sous-famille, vide = toutes
    @Published var priceMinText = ""        // prix TTC min (texte, vide = aucun)
    @Published var priceMaxText = ""        // prix TTC max
    @Published var onlyActive = false       // n'afficher que les articles actifs
    @Published var onlyInStock = false      // n'afficher que les articles en stock
    @Published var sortField: SortField = .reference
    @Published var sortDescending = false
    @Published private(set) var items: [EBPItem] = []
    @Published private(set) var phase: Phase = .idle

    /// Un filtre (hors recherche texte et tri) est-il actif ?
    var hasActiveFilters: Bool {
        !familyFilter.trimmingCharacters(in: .whitespaces).isEmpty
            || !subFamilyFilter.trimmingCharacters(in: .whitespaces).isEmpty
            || !priceMinText.trimmingCharacters(in: .whitespaces).isEmpty
            || !priceMaxText.trimmingCharacters(in: .whitespaces).isEmpty
            || onlyActive || onlyInStock
    }

    /// Remet les filtres à zéro. Ne recharge pas : l'appelant déclenche le rechargement
    /// (après fermeture de la feuille) via `reloadNow()`.
    /// Remet les filtres à zéro. Ne recharge pas : l'appelant déclenche le rechargement
    /// (après fermeture de la feuille) via `reloadNow()`.
    func clearFilters() {
        familyFilter = ""; subFamilyFilter = ""; priceMinText = ""; priceMaxText = ""
        onlyActive = false; onlyInStock = false
        sortField = .reference; sortDescending = false
    }

    /// Empreinte des filtres et du tri courants : permet de ne recharger que s'ils ont
    /// réellement changé après la fermeture de la feuille.
    var filtersSignature: String {
        [familyFilter.trimmingCharacters(in: .whitespaces),
         subFamilyFilter.trimmingCharacters(in: .whitespaces),
         priceMinText.trimmingCharacters(in: .whitespaces),
         priceMaxText.trimmingCharacters(in: .whitespaces),
         onlyActive ? "1" : "0", onlyInStock ? "1" : "0",
         sortField.rawValue, sortDescending ? "d" : "a"].joined(separator: "|")
    }

    private func currentQuery(offset: Int) -> ItemsQuery {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let family = familyFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let subFamily = subFamilyFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        return ItemsQuery(offset: offset, limit: pageSize,
                          orderBy: sortField.ebpField, orderDescending: sortDescending,
                          search: term.isEmpty ? nil : term,
                          familyId: family.isEmpty ? nil : family,
                          subFamilyId: subFamily.isEmpty ? nil : subFamily,
                          priceMin: Self.decimal(priceMinText),
                          priceMax: Self.decimal(priceMaxText),
                          activeOnly: onlyActive, inStockOnly: onlyInStock)
    }

    private static func decimal(_ text: String) -> Decimal? {
        let normalized = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty else { return nil }
        return Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
    }

    private let config: GatewayConfig
    private let client: GatewayClient
    private let pageSize = 50
    private var offset = 0
    private var total = 0
    /// La dernière page reçue était-elle pleine ? (critère fiable de « il reste des pages »,
    /// même si EBP ne renvoie pas un `total` exploitable sur de très gros catalogues).
    private var lastPageWasFull = true
    private var searchTask: Task<Void, Never>?
    /// Incrémenté à chaque rechargement complet. Un `loadMore` d'une génération périmée
    /// (filtre changé entre-temps) est ignoré, pour ne pas mélanger deux jeux de résultats.
    private var generation = 0
    /// Clés de ligne déjà présentes, pour dédoublonner les pages qui se chevauchent.
    private var seenRowIDs: Set<String> = []

    init(config: GatewayConfig, session: HTTPSession = URLSession.shared) {
        self.config = config
        self.client = GatewayClient(config: config, session: session)
    }

    /// Reste-t-il des articles à charger ? On continue tant que la dernière page était pleine
    /// (pagination « au fur et à mesure »). Si `total` est connu et fiable, on respecte aussi sa borne.
    private var canLoadMore: Bool {
        guard lastPageWasFull else { return false }
        if total > 0 { return items.count < total }
        return true   // total inconnu/0 : on se fie au remplissage de page
    }

    /// Recharge depuis le début pour la recherche/filtres courants (avec anti-rebond).
    func search(debounced: Bool = true) {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            if debounced { try? await Task.sleep(nanoseconds: 350_000_000) }
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    func reloadNow() { search(debounced: false) }

    /// Rechargement attendu (pour `.refreshable` : pull-to-refresh).
    func refresh() async {
        searchTask?.cancel()
        await reload()
    }

    private func reload() async {
        generation &+= 1
        let gen = generation
        phase = .loading
        offset = 0
        do {
            let page = try await client.items(currentQuery(offset: 0))
            guard !Task.isCancelled, gen == generation else { return }
            // Dédoublonnage par identité de ligne (pages qui se chevauchent).
            var seen = Set<String>()
            let deduped = page.items.filter { seen.insert($0.rowID).inserted }
            items = deduped
            seenRowIDs = seen
            total = page.paging?.total ?? 0
            offset = page.items.count
            lastPageWasFull = page.items.count >= pageSize
            phase = .loaded
        } catch {
            guard !Task.isCancelled, gen == generation else { return }
            phase = .error(Self.message(for: error))
        }
    }

    /// Charge la page suivante (déclenché quand la dernière ligne apparaît).
    func loadMoreIfNeeded(current item: EBPItem) {
        guard phase == .loaded, canLoadMore,
              item == items.last else { return }
        Task { await loadMore() }
    }

    private func loadMore() async {
        guard phase == .loaded, canLoadMore else { return }
        let gen = generation
        phase = .loadingMore
        do {
            let page = try await client.items(currentQuery(offset: offset))
            // Un rechargement complet (filtre changé) a eu lieu entre-temps : page périmée, on ignore.
            guard gen == generation else { return }
            // N'ajoute que les lignes pas encore présentes (pages qui se chevauchent).
            let fresh = page.items.filter { seenRowIDs.insert($0.rowID).inserted }
            items.append(contentsOf: fresh)
            if let t = page.paging?.total, t > 0 { total = t }
            offset += page.items.count
            lastPageWasFull = page.items.count >= pageSize
            phase = .loaded
        } catch {
            guard gen == generation else { return }
            phase = .error(Self.message(for: error))
        }
    }

    /// Recherche un article par code-barres scanné (interroge EBP, même hors liste chargée).
    /// Renvoie le produit mappé, ou nil si aucun article ne porte ce code.
    func lookupBarcode(_ code: String) async throws -> MappedProduct? {
        guard let item = try await client.itemByBarcode(code) else { return nil }
        return EBPProductMapper.map(item)
    }

    static func message(for error: Error) -> String {
        guard let e = error as? GatewayError else { return error.localizedDescription }
        switch e {
        case .unauthorized: return NSLocalizedString("Jeton refusé : vérifiez la configuration dans Réglages.", comment: "")
        case .forbidden(let m): return m.isEmpty ? NSLocalizedString("Compte EBP indisponible.", comment: "") : m
        case .folderRequired: return NSLocalizedString("Aucun dossier ciblé par le jeton.", comment: "")
        case .jobTimedOut: return NSLocalizedString("La gateway met trop de temps à répondre. Réessayez.", comment: "")
        case .jobFailed(let errs): return errs.first ?? NSLocalizedString("La requête a échoué côté EBP.", comment: "")
        case .transport(let m): return String(format: NSLocalizedString("Gateway injoignable : %@", comment: ""), m)
        case .invalidConfig: return NSLocalizedString("Configuration invalide (URL ou jeton).", comment: "")
        case .decoding(let m): return String(format: NSLocalizedString("Réponse illisible : %@", comment: ""), m)
        case .http(let code): return String(format: NSLocalizedString("Erreur HTTP %d.", comment: ""), code)
        case .badRequest(let m): return m.isEmpty ? NSLocalizedString("Requête refusée.", comment: "") : m
        }
    }
}

/// Écran RACINE (app appairée) : liste et recherche des articles EBP. Sélectionner un article
/// pousse sa fiche à onglets Produit / Impression. L'onglet Impression (écran d'impression soigné)
/// est fourni par l'hôte via `impression` ; `onSelect` prévient l'hôte pour alimenter l'étiquette.
struct ProductListView<Impression: View, Sheets: View>: View {
    let config: GatewayConfig
    @ObservedObject var batch: BatchStore
    let onOpenSettings: () -> Void
    let onOpenHistory: () -> Void
    let onSelect: (MappedProduct) -> Void
    /// Demande de rouvrir une fiche depuis l'extérieur (ex. « Reprendre » dans l'historique).
    /// Quand ce binding passe à non-nil, on pousse la fiche de ce produit puis on le remet à nil.
    @Binding var reopen: MappedProduct?
    /// Ouvre le récap du lot (multi-impression).
    let onOpenBatch: () -> Void
    @ViewBuilder let impression: (MappedProduct) -> Impression
    @ViewBuilder let sheets: () -> Sheets

    @StateObject private var model: EBPSearchModel
    @State private var selected: MappedProduct?
    @State private var showingFilters = false
    /// Action de rechargement à exécuter une fois la feuille de filtres refermée
    /// (recharger ne marche pas de façon fiable depuis la feuille qui se démonte).
    @State private var pendingReload: PendingReload?
    @State private var showingScanner = false
    /// Mode sélection multiple : la liste affiche des cases à cocher et une barre d'action.
    @State private var selectionMode = false
    /// Mode scan multiple : chaque scan ajoute au lot (dédoublonnage → +1), sans quitter le scanner.
    @State private var multiScan = false
    /// Message éphémère de confirmation de scan multiple (« … ajouté »).
    @State private var scanFeedback: String?

    private enum PendingReload { case apply, reset }
    @State private var scanLookupInProgress = false
    @State private var scanMessage: String?
    /// Focus des champs de la feuille filtres : on le coupe avant d'appliquer pour forcer les
    /// TextField (clavier décimal, sans touche Entrée) à committer leur valeur au binding.
    @FocusState private var filterFieldFocused: Bool
    /// Empreinte des filtres à l'ouverture de la feuille : on ne recharge à la fermeture que
    /// si elle a changé (évite une requête inutile quand on ferme sans rien modifier).
    @State private var filtersSignatureAtOpen = ""

    init(config: GatewayConfig,
         session: HTTPSession = URLSession.shared,
         batch: BatchStore,
         onOpenSettings: @escaping () -> Void,
         onOpenHistory: @escaping () -> Void,
         onSelect: @escaping (MappedProduct) -> Void,
         reopen: Binding<MappedProduct?>,
         onOpenBatch: @escaping () -> Void,
         @ViewBuilder impression: @escaping (MappedProduct) -> Impression,
         @ViewBuilder sheets: @escaping () -> Sheets) {
        self.config = config
        self.batch = batch
        self.onOpenSettings = onOpenSettings
        self.onOpenHistory = onOpenHistory
        self.onSelect = onSelect
        self._reopen = reopen
        self.onOpenBatch = onOpenBatch
        self.impression = impression
        self.sheets = sheets
        _model = StateObject(wrappedValue: EBPSearchModel(config: config, session: session))
    }

    var body: some View {
        content
            .navigationTitle(NSLocalizedString("Articles EBP", comment: "EBP items"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if selectionMode {
                        Button(NSLocalizedString("Terminer", comment: "Done selecting")) { selectionMode = false }
                    } else {
                        Button { onOpenHistory() } label: { Image(systemName: "clock.arrow.circlepath") }
                            .accessibilityLabel(NSLocalizedString("Historique", comment: "History"))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { selectionMode.toggle() } label: {
                        Image(systemName: selectionMode ? "checklist.checked" : "checklist")
                    }
                    .accessibilityLabel(NSLocalizedString("Sélectionner plusieurs articles", comment: "Select multiple"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Deux entrées de scan explicites : un scan simple (ouvre la fiche) et un
                    // scan multiple (ajoute au lot). Le mode est fixé par l'entrée choisie.
                    Menu {
                        Button {
                            openScanner(multiple: false)
                        } label: {
                            Label(NSLocalizedString("Scanner un article", comment: "Scan one article"),
                                  systemImage: "barcode.viewfinder")
                        }
                        Button {
                            openScanner(multiple: true)
                        } label: {
                            Label(NSLocalizedString("Scan multiple (lot)", comment: "Multi scan into batch"),
                                  systemImage: "square.stack.3d.up")
                        }
                    } label: {
                        Image(systemName: "barcode.viewfinder")
                    }
                    .accessibilityLabel(NSLocalizedString("Scanner un code-barres", comment: "Scan barcode"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { onOpenSettings() } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel(NSLocalizedString("Réglages", comment: "Settings"))
                        .accessibilityIdentifier("reglages")
                }
            }
            .safeAreaInset(edge: .bottom) {
                // Barre basse : recherche + bouton filtre côte à côte, puis récap du lot.
                // Dans un safeAreaInset(.bottom), SwiftUI remonte le bloc au-dessus du clavier :
                // le champ et le bouton filtre restent visibles pendant la saisie.
                VStack(spacing: 0) {
                    batchBar
                    searchBar
                }
            }
            .onChange(of: model.query) { _, _ in model.search() }
            .onAppear { if model.items.isEmpty { model.reloadNow() } }
            .onChange(of: showingFilters) { wasShown, isShown in
                if isShown {
                    // À l'ouverture : mémorise l'état des filtres pour le comparer à la fermeture.
                    filtersSignatureAtOpen = model.filtersSignature
                    return
                }
                guard wasShown else { return }
                let reset = (pendingReload == .reset)
                pendingReload = nil
                // Décalé d'un cycle : laisse les TextField (clavier décimal) committer leur
                // valeur au binding avant de lire l'empreinte et la requête.
                Task { @MainActor in
                    if reset { model.clearFilters() }
                    // Ne recharge que si les filtres ont réellement changé (ou après un reset).
                    if reset || model.filtersSignature != filtersSignatureAtOpen {
                        model.reloadNow()
                    }
                }
            }
            .sheet(isPresented: $showingFilters) { filtersSheet }
            .sheet(isPresented: $showingScanner) { scannerSheet }
            .overlay { if scanLookupInProgress { scanLookupOverlay } }
            .alert(NSLocalizedString("Article introuvable", comment: "Not found"),
                   isPresented: Binding(get: { scanMessage != nil }, set: { if !$0 { scanMessage = nil } })) {
                Button("OK") { scanMessage = nil }
            } message: { Text(scanMessage ?? "") }
            .navigationDestination(item: $selected) { product in
                ArticleDetailView(product: product, impression: { impression(product) }, sheets: sheets)
            }
            // Reprise depuis l'historique : rouvre la fiche du produit demandé. On tente de
            // RECHARGER l'article complet depuis la gateway (via son code-barres) pour retrouver
            // stock, HT et TVA que l'historique ne mémorise pas. Repli sur la version mémorisée si
            // le rechargement échoue (hors-ligne, article introuvable, pas de code-barres).
            .onChange(of: reopen) { _, product in
                guard let product else { return }
                reopen = nil
                Task { await reopenReloading(product) }
            }
    }

    /// Rouvre la fiche d'un produit repris de l'historique en la rafraîchissant depuis la gateway.
    @MainActor
    private func reopenReloading(_ stored: MappedProduct) async {
        let code = stored.label.ean.trimmingCharacters(in: .whitespacesAndNewlines)
        var fresh: MappedProduct?
        if !code.isEmpty {
            scanLookupInProgress = true
            fresh = try? await model.lookupBarcode(code)
            scanLookupInProgress = false
        }
        // La version rechargée garde les détails (stock, HT, TVA) ; sinon on ouvre la version
        // mémorisée, dont la fiche n'affiche que ce que l'étiquette contient.
        let product = fresh ?? stored
        onSelect(product)
        selected = product
    }

    /// Scanner de code-barres / QR. Mode simple : un scan ouvre la fiche. Mode multiple : chaque
    /// scan ajoute l'article au lot (dédoublonnage → +1) sans quitter le scanner.
    private var scannerSheet: some View {
        NavigationStack {
            ZStack {
                // Scan CONTINU : un code-barres maintenu devant la caméra n'est pas relu en boucle.
                // En mode simple la sheet se ferme au premier scan ; en multiple on gère le lot nous-même.
                QRScannerView(
                    onFound: { code in handleScannedCode(code) },
                    onError: { message in showingScanner = false; scanMessage = message },
                    types: QRScannerView.productCodeTypes,
                    continuous: true
                )
                .ignoresSafeArea(edges: .bottom)

                VStack {
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(.white.opacity(0.9), lineWidth: 3)
                        .frame(width: 260, height: 180)
                        .allowsHitTesting(false)
                    if multiScan {
                        VStack(spacing: 6) {
                            Text(String(format: NSLocalizedString("Lot : %d produit(s) · %d étiquette(s)", comment: "Batch progress while scanning"),
                                        batch.count, batch.totalLabels))
                                .font(.subheadline.weight(.semibold))
                            if let feedback = scanFeedback {
                                Text(feedback).font(.caption).foregroundStyle(.green)
                            }
                        }
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding(.top, 24)
                    }
                }
            }
            .navigationTitle(multiScan ? NSLocalizedString("Scan multiple", comment: "Multi scan")
                                       : NSLocalizedString("Scanner un article", comment: "Scan article"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("Fermer", comment: "Close scanner")) { showingScanner = false }
                }
                ToolbarItem(placement: .principal) {
                    Toggle(NSLocalizedString("Scan multiple", comment: "Multi scan toggle"), isOn: $multiScan)
                        .toggleStyle(.button)
                        .font(.subheadline)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if multiScan && !batch.isEmpty {
                        Button(String(format: NSLocalizedString("Lot (%d)", comment: "Open batch from scanner"), batch.count)) {
                            showingScanner = false
                            selectionMode = false
                            onOpenBatch()
                        }
                    }
                }
            }
        }
    }

    private var scanLookupOverlay: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            ProgressView(NSLocalizedString("Recherche de l’article…", comment: "Looking up"))
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    /// Ouvre le scanner dans le mode voulu (simple → ouvre la fiche ; multiple → ajoute au lot).
    /// L'état initial `multiScan` est fixé par l'entrée choisie dans la liste ; le toggle interne
    /// au scanner reste disponible pour basculer en cours de route.
    private func openScanner(multiple: Bool) {
        scanMessage = nil
        scanFeedback = nil
        multiScan = multiple
        showingScanner = true
    }

    /// Code scanné → recherche EBP par code-barres. En mode simple : ouvre la fiche. En mode
    /// multiple : ajoute l'article au lot (une seule fois) et reste sur le scanner.
    private func handleScannedCode(_ code: String) {
        if multiScan {
            handleMultiScan(code)
            return
        }
        acceptedScanFeedback()   // confirmation du scan (le scanner continu ne bipe plus lui-même)
        showingScanner = false
        scanLookupInProgress = true
        Task { @MainActor in
            do {
                if let product = try await model.lookupBarcode(code) {
                    onSelect(product)
                    selected = product
                } else {
                    scanMessage = String(format: NSLocalizedString("Aucun article avec le code-barres %@.", comment: "No item for barcode"), code)
                }
            } catch {
                scanMessage = EBPSearchModel.message(for: error)
            }
            scanLookupInProgress = false
        }
    }

    /// Scan multiple : interroge EBP et ajoute l'article au lot UNE SEULE FOIS. Un article déjà
    /// présent est ignoré en silence (pas de retour, pas de ré-incrément) : pour imprimer plusieurs
    /// exemplaires, on scanne une fois puis on règle la quantité dans le lot. Le scanner reste en
    /// continu et ne relit pas le même code maintenu devant la caméra.
    private func handleMultiScan(_ code: String) {
        Task { @MainActor in
            do {
                if let product = try await model.lookupBarcode(code) {
                    if batch.contains(product) {
                        return   // déjà dans le lot : rien à faire, pas de retour
                    }
                    batch.add(product)
                    let name = product.label.name.isEmpty ? code : product.label.name
                    scanFeedback = String(format: NSLocalizedString("%@ ajouté", comment: "Added scan feedback"), name)
                    acceptedScanFeedback()
                } else {
                    scanFeedback = String(format: NSLocalizedString("Introuvable : %@", comment: "Not found feedback"), code)
                }
            } catch {
                scanFeedback = EBPSearchModel.message(for: error)
            }
        }
    }

    /// Retour sensoriel d'un article ajouté au lot : bip + légère vibration.
    private func acceptedScanFeedback() {
        AudioServicesPlaySystemSound(1057)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Feuille de filtrage et de tri de la liste.
    private var filtersSheet: some View {
        NavigationStack {
            Form {
                Section(NSLocalizedString("Disponibilité", comment: "Availability")) {
                    Toggle(NSLocalizedString("En stock uniquement", comment: "In stock only"), isOn: $model.onlyInStock)
                    Toggle(NSLocalizedString("Articles actifs uniquement", comment: "Active only"), isOn: $model.onlyActive)
                }
                Section(NSLocalizedString("Famille", comment: "Family")) {
                    TextField(NSLocalizedString("Code famille (ex. FAR00004)", comment: "Family code"),
                              text: $model.familyFilter)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($filterFieldFocused)
                    TextField(NSLocalizedString("Code sous-famille (optionnel)", comment: "Sub-family code"),
                              text: $model.subFamilyFilter)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($filterFieldFocused)
                }
                Section(NSLocalizedString("Prix de vente TTC", comment: "Price filter")) {
                    HStack {
                        Text(NSLocalizedString("Min", comment: "Min"))
                        TextField("0", text: $model.priceMinText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .focused($filterFieldFocused)
                        Text("€").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text(NSLocalizedString("Max", comment: "Max"))
                        TextField("—", text: $model.priceMaxText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .focused($filterFieldFocused)
                        Text("€").foregroundStyle(.secondary)
                    }
                }
                Section(NSLocalizedString("Tri", comment: "Sort")) {
                    Picker(NSLocalizedString("Trier par", comment: "Sort by"), selection: $model.sortField) {
                        ForEach(EBPSearchModel.SortField.allCases) { field in
                            Text(field.title).tag(field)
                        }
                    }
                    Toggle(NSLocalizedString("Ordre décroissant", comment: "Descending"), isOn: $model.sortDescending)
                }
                Section {
                    Button(NSLocalizedString("Appliquer", comment: "Apply")) {
                        filterFieldFocused = false   // force le commit des champs (clavier décimal)
                        showingFilters = false
                        pendingReload = .apply
                    }
                    if model.hasActiveFilters {
                        Button(NSLocalizedString("Réinitialiser les filtres", comment: "Reset filters"), role: .destructive) {
                            filterFieldFocused = false
                            showingFilters = false
                            pendingReload = .reset
                        }
                    }
                }
            }
            .navigationTitle(NSLocalizedString("Filtres et tri", comment: "Filters and sort"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button(NSLocalizedString("Fermer", comment: "Close")) { showingFilters = false } }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .loading where model.items.isEmpty:
            ProgressView(NSLocalizedString("Chargement…", comment: "Loading"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message) where model.items.isEmpty:
            ContentUnavailableView {
                Label(NSLocalizedString("Impossible de charger", comment: "Cannot load"), systemImage: "exclamationmark.triangle")
            } description: { Text(message) } actions: {
                Button(NSLocalizedString("Réessayer", comment: "Retry")) { model.reloadNow() }.buttonStyle(.borderedProminent)
            }
        default:
            list
        }
    }

    private var list: some View {
        List {
            if model.items.isEmpty {
                ContentUnavailableView(NSLocalizedString("Aucun article", comment: "No item"),
                                       systemImage: "magnifyingglass",
                                       description: Text(NSLocalizedString("Aucun résultat pour cette recherche.", comment: "")))
            }
            ForEach(model.items, id: \.rowID) { item in
                Button { tap(item) } label: { row(item) }
                    .onAppear { model.loadMoreIfNeeded(current: item) }
            }
            if model.phase == .loadingMore {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .listStyle(.plain)
        .refreshable { await model.refresh() }
        // Rechargement (changement de filtres/tri, reset…) avec une liste déjà affichée :
        // voile de chargement par-dessus la liste précédente, qui reste visible dessous.
        .overlay { if model.phase == .loading { reloadOverlay } }
        .animation(.easeInOut(duration: 0.2), value: model.phase)
    }

    /// Voile semi-transparent + indicateur affiché pendant un rechargement, tant que la liste
    /// courante reste visible dessous (on ne vide pas la liste pendant le chargement).
    private var reloadOverlay: some View {
        ZStack {
            Color(.systemBackground).opacity(0.45).ignoresSafeArea()
            ProgressView(NSLocalizedString("Mise à jour…", comment: "Reloading list"))
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        .transition(.opacity)
        .allowsHitTesting(true)   // bloque les taps sur la liste pendant le rechargement
    }

    private func row(_ item: EBPItem) -> some View {
        HStack(spacing: 12) {
            if selectionMode {
                let inBatch = batch.contains(EBPProductMapper.map(item))
                Image(systemName: inBatch ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(inBatch ? Color.accentColor : Color.secondary)
                    .accessibilityLabel(inBatch ? NSLocalizedString("Sélectionné", comment: "Selected")
                                                : NSLocalizedString("Non sélectionné", comment: "Not selected"))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.caption ?? item.desComClear ?? "—")
                    .font(.headline).foregroundStyle(.primary)
                HStack(spacing: 10) {
                    if let id = item.id?.trimmingCharacters(in: .whitespaces), !id.isEmpty {
                        Text(id).font(.caption).foregroundStyle(.secondary)
                    }
                    if let barcode = item.barCode, !barcode.isEmpty {
                        Text(barcode).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let ttc = item.salePriceVatIncluded {
                        Text(priceText(ttc)).font(.subheadline.weight(.semibold))
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func priceText(_ value: Decimal) -> String {
        var v = value, r = Decimal()
        NSDecimalRound(&r, &v, 2, .plain)
        let f = NumberFormatter(); f.locale = Locale(identifier: "fr_FR")
        f.numberStyle = .decimal; f.minimumFractionDigits = 2; f.maximumFractionDigits = 2
        return (f.string(from: r as NSDecimalNumber) ?? "\(r)") + " €"
    }

    /// Tap sur une ligne : en mode sélection, bascule l'appartenance au lot ; sinon, ouvre la fiche.
    private func tap(_ item: EBPItem) {
        let product = EBPProductMapper.map(item)
        if selectionMode {
            batch.toggle(product)
        } else {
            onSelect(product)    // alimente l'étiquette courante AVANT de pousser la fiche (aperçu live)
            selected = product
        }
    }

    /// Barre de recherche basse : champ de recherche + bouton filtre à droite, côte à côte.
    /// Remplace le `.searchable` natif (qui ne laisse pas poser de bouton à côté du champ) et
    /// désencombre la zone haut-droite. Le bouton filtre ouvre la même feuille de filtres ;
    /// il porte le même indicateur « filtre actif » (icône pleine) que l'ancien bouton de toolbar.
    ///
    /// Liquid Glass : la toolbar et le `.searchable` natifs adoptaient automatiquement le
    /// matériau Liquid Glass d'iOS 26. En reconstruisant la barre à la main, on réapplique
    /// explicitement `glassEffect` (champ en capsule, bouton en cercle) pour garder le même
    /// matériau translucide. Repli `.regularMaterial` sur iOS < 26, comme ailleurs dans l'app.
    /// Pas de fond opaque sur le conteneur : le translucide laisse voir la liste dessous.
    private var searchBar: some View {
        GlassEffectContainerCompat {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(NSLocalizedString("Rechercher (libellé ou référence)", comment: "Search"),
                              text: $model.query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .accessibilityLabel(NSLocalizedString("Effacer la recherche", comment: "Clear search"))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassCapsule()

                Button { showingFilters = true } label: {
                    Image(systemName: model.hasActiveFilters ? "line.3.horizontal.decrease.circle.fill"
                                                              : "line.3.horizontal.decrease.circle")
                        .font(.title2)
                        // Couleur = indicateur d'état : gris quand aucun filtre n'est actif,
                        // teinte d'accent (bleu) quand un filtre est posé. Complète l'icône
                        // pleine/contour portée par hasActiveFilters.
                        .foregroundStyle(model.hasActiveFilters ? Color.accentColor : Color.secondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(NSLocalizedString("Filtres", comment: "Filters"))
                .glassCircle()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// Barre basse : accès au récap du lot (dès qu'il contient un produit). En mode sélection,
    /// rappelle le nombre sélectionné et mène directement à « Imprimer la sélection ». Un bouton
    /// « Annuler la sélection » vide le lot et sort du mode sélection.
    @ViewBuilder
    private var batchBar: some View {
        if !batch.isEmpty {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: "shippingbox.fill").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(String(format: NSLocalizedString("Lot : %d produit(s)", comment: "Batch count"), batch.count))
                            .font(.subheadline.weight(.semibold))
                        Text(String(format: NSLocalizedString("%d étiquette(s)", comment: "Label count"), batch.totalLabels))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { selectionMode = false; onOpenBatch() } label: {
                        Text(selectionMode
                             ? String(format: NSLocalizedString("Imprimer la sélection (%d)", comment: "Print selection"), batch.count)
                             : NSLocalizedString("Voir le lot", comment: "Open batch"))
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(role: .destructive) {
                    batch.clear()
                    selectionMode = false
                } label: {
                    Text(NSLocalizedString("Annuler la sélection", comment: "Clear selection"))
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
            .overlay(Divider(), alignment: .top)
        }
    }
}

// MARK: - Liquid Glass (compat iOS < 26)
//
// Helpers qui appliquent le matériau Liquid Glass d'iOS 26 (glassEffect /
// GlassEffectContainer) aux vues reconstruites à la main, avec un repli
// `.regularMaterial` sur les versions antérieures (deployment target 17.0).

private extension View {
    /// Champ de recherche : matériau Liquid Glass en capsule (repli `.regularMaterial`).
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self.background(.regularMaterial, in: Capsule())
        }
    }

    /// Bouton filtre : matériau Liquid Glass interactif en cercle (repli `.regularMaterial`).
    @ViewBuilder
    func glassCircle() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .circle)
        } else {
            self.background(.regularMaterial, in: Circle())
        }
    }
}

/// Conteneur Liquid Glass : regroupe les éléments translucides pour un rendu cohérent
/// (fusion du matériau) sur iOS 26 ; transparent (passe-plat) sur les versions antérieures.
private struct GlassEffectContainerCompat<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 10) { content() }
        } else {
            content()
        }
    }
}
