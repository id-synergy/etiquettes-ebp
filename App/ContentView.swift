import SwiftUI
import PocketPrinter5890Kit

struct ContentView: View {
    @ObservedObject var gateway: GatewaySettings
    @StateObject private var printer = PrinterManager()
    @StateObject private var setup = PrinterSetup()
    @StateObject private var brother = BrotherPrinterService()
    @StateObject private var netum = NetumPrinterService()
    @StateObject private var formatThumbnails = TemplateThumbnailStore()
    @StateObject private var templates = LabelTemplateLibraryStore()
    @StateObject private var history = LabelHistoryStore()
    @StateObject private var viewed = ViewedProductStore()
    /// Lot de produits pour la multi-impression (sélection liste + scan multiple).
    @StateObject private var batch = BatchStore()
    /// Vérifie au démarrage si une version plus récente est sur l'App Store.
    @StateObject private var updateChecker = AppUpdateChecker()
    /// État courant de la file multi-impression, nil hors impression. Piloté par `runBatchQueue`.
    @State private var queueState: PrintQueueMachine.State?
    /// Demande d'ouverture du récap multi-produits (navigation depuis liste/scan).
    @State private var showingBatch = false
    /// Continuation réveillée par la reprise utilisateur (relancer / ignorer / annuler).
    @State private var resumeContinuation: CheckedContinuation<QueueResume, Never>?
    /// Étiquette courante : alimentée par l'article EBP sélectionné (plus de saisie manuelle).
    @State private var label = ProductLabel()
    @State private var showingPrinters = false
    @State private var showingSettings = false
    @State private var showingPresentation = false
    @State private var showingTemplates = false
    @State private var showingHistory = false
    /// Onglet de l'historique : 0 = consultés, 1 = imprimés.
    @State private var historyTab = 0
    /// Produit à rouvrir depuis l'historique (« Reprendre »/« Restaurer ») : la liste pousse sa
    /// fiche quand ce champ devient non-nil, puis le remet à nil.
    @State private var reopenProduct: MappedProduct?
    /// Feuille de partage/import ouverte depuis la section « Partage » des Réglages.
    @State private var settingsShare: SettingsShareSheet?
    @State private var message: String?
    /// Message après l'ouverture d'un fichier .ebplabel / .ebpprinter reçu (AirDrop…).
    @State private var importMessage: String?
    @State private var ebpQuantity = 1
    @AppStorage("labelSize") private var selectedSize = LabelSize.standard.rawValue
    @AppStorage("labelArrangement") private var selectedArrangement = LabelArrangement.current.rawValue
    /// Modèle d'étiquette choisi (preset d'usine ou modèle perso). Remplace le choix de
    /// disposition figée pour le rendu. Persisté par id.
    @AppStorage("labelTemplateID") private var selectedTemplateIDString = ""

    private var labelSize: LabelSize { LabelSize(rawValue: selectedSize) ?? .standard }
    private var labelArrangement: LabelArrangement { LabelArrangement(rawValue: selectedArrangement) ?? .current }

    /// Id du modèle courant, sous forme de Binding pour les écrans de sélection/édition.
    private var selectedTemplateID: Binding<UUID> {
        Binding(
            get: { UUID(uuidString: selectedTemplateIDString) ?? LabelTemplatePresets.default.id },
            set: { selectedTemplateIDString = $0.uuidString }
        )
    }
    /// Le modèle effectivement utilisé pour rendre et imprimer (repli sur le preset par défaut).
    private var currentTemplate: LabelTemplate {
        templates.templateOrDefault(id: UUID(uuidString: selectedTemplateIDString))
    }
    /// Pose la date de génération sur une étiquette, pour que les modèles qui affichent la
    /// date de génération l'impriment. Sans effet visible pour les modèles sans ce champ.
    private func dated(_ label: ProductLabel, at date: Date = Date()) -> ProductLabel {
        var label = label
        label.generatedAt = date
        return label
    }

    private var isBrother: Bool { setup.brand == .brother }
    private var isNetum: Bool { setup.brand == .netum }
    /// 576 points pour les dispositions 80 mm de la NETUM, 384 sinon.
    private var layoutWidth: Int { isNetum ? setup.netum.paper.layoutWidth : LabelRenderer.width }
    private var layoutWidthMM: Int { layoutWidth / 8 }
    /// Prête à recevoir un travail : 5890 connectée, ou Brother choisie avec
    /// une connexion que le modèle accepte.
    private var printerReady: Bool {
        if isNetum { return netum.connected }
        if isBrother {
            guard brother.canPrint, let target = brother.target else { return false }
            return setup.brotherModel.appConnections.contains(target.connection)
        }
        return printer.connected
    }
    private var isPrinting: Bool { isNetum ? netum.isBusy : isBrother ? brother.isBusy : printer.printing }
    private var printedSizeText: String {
        guard isBrother else { return "\(layoutWidthMM) × \(labelSize.heightMillimeters) mm" }
        let area = setup.brotherMedia.printableAreaMM(for: setup.brotherModel)
        let fitted = LabelRasterGeometry.fittedSizeMM(layoutHeight: labelSize.heightDots, area: area)
        return String(format: NSLocalizedString("≈ %.0f × %.0f mm sur %@", comment: "Brother printed size"),
                      fitted.width, fitted.height, setup.brotherModel.title)
    }

    /// Support à longueur libre (rouleau continu) : la longueur imprimable est indéfinie. Alors la
    /// hauteur de l'étiquette suit le contenu. Les imprimantes non-Brother (Netum, 5890) sont des
    /// rouleaux de ticket continus.
    private var isContinuousMedia: Bool {
        guard isBrother else { return true }
        return setup.brotherMedia.printableAreaMM(for: setup.brotherModel).length == nil
    }

    private var bitmap: MonochromeBitmap? {
        try? LabelRenderer.render(dated(label), template: currentTemplate, size: labelSize,
                                  layoutWidth: layoutWidth, continuousMedia: isContinuousMedia)
    }
    /// Date d'exemple FIXE pour les aperçus/miniatures (clés de cache stables) : les modèles
    /// qui affichent la date de génération la montrent sans dériver à chaque rendu.
    private static let previewDate = Date(timeIntervalSince1970: 1_778_000_000)
    private var selectionPreviewLabel: ProductLabel {
        let base = ((try? EAN13.completed(label.ean)) != nil &&
                    PriceFormatter.formatted(label.price, currency: label.currency) != nil) ? label : ProductLabel()
        return dated(base, at: Self.previewDate)
    }
    var body: some View {
        NavigationStack {
            Group {
                if let config = gateway.activeConfig() {
                    ProductListView(config: config,
                                    session: gateway.makeSession(),
                                    batch: batch,
                                    onOpenSettings: { showingSettings = true },
                                    onOpenHistory: { showingHistory = true },
                                    onSelect: { product in
                                        // L'article choisi devient l'étiquette courante → aperçu live.
                                        label = product.label
                                        ebpQuantity = 1
                                        viewed.record(product.label)   // historique de consultation
                                    },
                                    reopen: $reopenProduct,
                                    onOpenBatch: { showingBatch = true },
                                    impression: { product in impressionTab(for: product) },
                                    sheets: { Color.clear })
                } else {
                    ContentUnavailableView(NSLocalizedString("Gateway non configurée", comment: "Gateway not configured"),
                                           systemImage: "gearshape",
                                           description: Text(NSLocalizedString("Appairez la gateway pour charger les articles.", comment: "")))
                }
            }
            // Modales portées par la racine (toujours montée) : l'imprimante et la présentation
            // s'ouvrent aussi bien depuis la fiche article que depuis le bouton des Réglages,
            // alors que la fiche n'est pas forcément à l'écran.
            .navigationDestination(isPresented: $showingBatch) { batchDetail }
            .sheet(isPresented: $showingPrinters) { printerSheet }
            .sheet(isPresented: $showingPresentation) { presentationSheet }
            .sheet(isPresented: $showingTemplates) { templatesSheet }
            .sheet(isPresented: $showingSettings) { settingsSheet }
            .sheet(isPresented: $showingHistory) { historySheet }
            .alert(NSLocalizedString("Impression", comment: "Print alert"), isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            } message: { Text(message ?? "") }
            .alert(NSLocalizedString("Import", comment: "Import alert"),
                   isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
                Button("OK") { importMessage = nil }
            } message: { Text(importMessage ?? "") }
            // Fichier .ebplabel / .ebpprinter reçu (AirDrop, Messages, Fichiers…) : importe son contenu.
            .onOpenURL { url in importMessage = ShareFileImporter.open(url, templates: templates, setup: setup, printer: printer) }
            .onChange(of: netum.jobError) { _, error in
                guard let error else { return }
                message = error
                netum.jobError = nil
            }
            .onChange(of: brother.activity) { old, new in
                if old == .printing, new == .idle, brother.statusIsError { message = brother.status }
            }
            .onAppear {
                if LabelSize(rawValue: selectedSize) == nil { selectedSize = LabelSize.standard.rawValue }
                if LabelArrangement(rawValue: selectedArrangement) == nil { selectedArrangement = LabelArrangement.current.rawValue }
                // Migration : sans modèle choisi, retomber sur le PRESET correspondant à
                // l'ancienne disposition persistée (labelArrangement) → continuité du rendu.
                if UUID(uuidString: selectedTemplateIDString) == nil {
                    selectedTemplateIDString = LabelTemplatePresets.id(for: labelArrangement).uuidString
                }
                setup.supportedLabels = { model in BrotherPrinterService.supportedLabelIndices(for: model) }
                if isNetum { netum.reconnect() } else if !isBrother { printer.reconnect() }
                updateChecker.checkOnce()
            }
            .alert(NSLocalizedString("Mise à jour disponible", comment: "Update available title"),
                   isPresented: Binding(get: { updateChecker.available != nil },
                                        set: { if !$0 { updateChecker.dismiss() } })) {
                Button(NSLocalizedString("Mettre à jour", comment: "Update now")) { updateChecker.openStore() }
                Button(NSLocalizedString("Plus tard", comment: "Later"), role: .cancel) { updateChecker.dismiss() }
            } message: {
                Text(String(format: NSLocalizedString("La version %@ est disponible sur l’App Store.", comment: "Update available message"),
                            updateChecker.available?.version ?? ""))
            }
        }
    }

    /// Onglet « Impression » de la fiche article : l'écran d'impression soigné d'origine
    /// (carte imprimante, présentation graphique, aperçu live), + une carte quantité, + le
    /// bouton Imprimer en direct. Piloté par `label` (l'article sélectionné) → aperçu live.
    private func impressionTab(for product: MappedProduct) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                printerCard
                templateCard
                presentationCard
                previewCard(for: product.label)
                quantityCard
                Button { printCurrentLabel(copies: ebpQuantity) } label: {
                    Label(isPrinting
                          ? NSLocalizedString("Impression…", comment: "Printing progress")
                          : String(format: NSLocalizedString("Imprimer %d étiquette(s)", comment: "Print N labels"), ebpQuantity),
                          systemImage: "printer.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled((try? LabelRenderer.render(product.label, template: currentTemplate, size: labelSize, layoutWidth: layoutWidth)) == nil || isPrinting || !printerReady)
            }
            .onAppear { label = product.label }   // garantit que l'impression utilise cet article
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Multi-impression (récap du lot)

    /// Choix de reprise après une pause (erreur en cours de file).
    private enum QueueResume { case retry, skip, cancel }

    /// Écran récap du lot : réutilise les cartes imprimante/présentation de l'onglet mono-produit
    /// (modèle d'impression choisi une fois pour tout le lot) et affiche la progression / pause.
    private var batchDetail: some View {
        BatchDetailView(
            batch: batch,
            queueState: queueState,
            printerCard: { printerCard },
            presentationCard: { VStack(spacing: 18) { templateCard; presentationCard } },
            preview: { product in
                (try? LabelRenderer.render(dated(product.label), template: currentTemplate,
                                           size: labelSize, layoutWidth: layoutWidth,
                                           continuousMedia: isContinuousMedia))
                    .flatMap(LabelRenderer.preview)
            },
            canPrint: canPrintBatch && !isPrinting,
            onPrintAll: { startBatchQueue() },
            onRetry: { resume(.retry) },
            onSkip: { resume(.skip) },
            onCancel: { resume(.cancel) }
        )
    }

    /// Impression simulée (aucune imprimante réelle, p. ex. dans le simulateur) : permet
    /// d'exercer la file multi-impression de bout en bout en démo. Chaque unité « sort » après
    /// une courte latence. Ne s'active que sans imprimante prête et en simulateur.
    private var demoPrinting: Bool {
        #if targetEnvironment(simulator)
        return !printerReady
        #else
        return false
        #endif
    }

    /// Prêt à lancer le lot : imprimante réelle prête, ou impression simulée (simulateur).
    private var canPrintBatch: Bool { printerReady || demoPrinting }

    /// Lance l'impression séquentielle de tout le lot (produits × quantités), pilotée par la
    /// machine à états `PrintQueueMachine` (idle → printing i/N → paused(k) → done).
    private func startBatchQueue() {
        guard canPrintBatch, !batch.isEmpty else { return }
        var machine = PrintQueueMachine(jobs: batch.makeJobs())
        machine.start()
        queueState = machine.state
        Task { await runBatchQueue(machine) }
    }

    /// Boucle d'orchestration : imprime l'unité visée, attend le résultat, et transmet
    /// succès/échec à la machine. Sur échec, la file passe en pause et attend le choix
    /// utilisateur (relancer / ignorer / annuler) via une continuation.
    @MainActor
    private func runBatchQueue(_ initial: PrintQueueMachine) async {
        var machine = initial

        while case .printing = machine.state {
            guard let current = machine.currentUnit,
                  let product = batch.product(id: current.jobID) else { break }

            let result = await printOneUnit(product.label)
            switch result {
            case .success:
                machine.markPrinted()
                queueState = machine.state
            case .failure(let message):
                machine.markFailed(message: message)
                queueState = machine.state
                // Attend le choix de l'utilisateur (la vue affiche Relancer / Ignorer / Annuler).
                let choice = await withCheckedContinuation { (c: CheckedContinuation<QueueResume, Never>) in
                    resumeContinuation = c
                }
                switch choice {
                case .retry: machine.retry()
                case .skip: machine.skipFailed()
                case .cancel: machine.cancel()
                }
                queueState = machine.state
            }
        }
        queueState = machine.state
        // Impression du lot entièrement réussie (toutes les étiquettes sorties) : on vide le lot.
        // Une annulation ou une étiquette ignorée laisse `printedCount < total` → le lot est
        // conservé pour permettre de réessayer.
        if case .done = machine.state, machine.printedCount == machine.total, machine.total > 0 {
            // Laisse l'utilisateur voir « X étiquette(s) imprimée(s) » un court instant, puis
            // vide le lot et revient à la liste (écran récap sinon vide).
            try? await Task.sleep(for: .seconds(1.2))
            batch.clear()
            showingBatch = false
        }
    }

    /// Réveille la boucle après un choix utilisateur en pause.
    private func resume(_ choice: QueueResume) {
        resumeContinuation?.resume(returning: choice)
        resumeContinuation = nil
    }

    /// Résultat d'une impression unitaire.
    private enum UnitOutcome { case success, failure(String) }

    /// Imprime UNE étiquette et attend sa fin, en réutilisant `submit()` (même moteur que le
    /// mono-produit). Détermine le résultat en observant l'état du service après soumission.
    /// En l'absence d'imprimante réelle prête (simulateur), l'impression est simulée.
    @MainActor
    private func printOneUnit(_ label: ProductLabel) async -> UnitOutcome {
        guard (try? LabelRenderer.render(label, template: currentTemplate, size: labelSize, layoutWidth: layoutWidth)) != nil else {
            return .failure(NSLocalizedString("Article invalide (EAN ou prix).", comment: "Invalid label"))
        }
        // Impression simulée : sortie « à vide » après une courte latence (démo / simulateur).
        if demoPrinting {
            try? await Task.sleep(for: .milliseconds(450))
            return .success
        }
        let entry = PrintedLabel(label: label, size: labelSize, arrangement: labelArrangement,
                                 densityValue: printer.density.rawValue,
                                 leadingFeedDots: printer.leadingFeedDots,
                                 trailingFeedDots: printer.trailingFeedDots,
                                 rotateContent180: printer.rotateContent180,
                                 netum: isNetum ? setup.netum : nil)
        if isNetum {
            netum.jobError = nil
            var queued = false
            do { try submit(label, size: labelSize, template: currentTemplate) { queued = true } }
            catch { return .failure(error.localizedDescription) }
            // Attend la fin du travail (ou une erreur de mise en file).
            await waitWhile { netum.isBusy }
            if let error = netum.jobError { netum.jobError = nil; return .failure(error) }
            if !queued && netum.statusIsError { return .failure(netum.status) }
            history.record(entry)
            return .success
        } else if isBrother {
            var success = false
            do { try submit(label, size: labelSize, template: currentTemplate) { success = true } }
            catch { return .failure(error.localizedDescription) }
            await waitWhile { brother.isBusy }
            if brother.statusIsError && !success { return .failure(brother.status) }
            history.record(entry)
            return .success
        } else {
            // 5890 : feu-et-oublie, pas de signal d'erreur dur. On envoie et on attend la fin.
            // Rouleau ticket continu : la hauteur suit le contenu.
            do {
                let bitmap = try LabelRenderer.render(dated(label), template: currentTemplate,
                                                      size: labelSize, continuousMedia: true)
                printer.print(bitmap)
            } catch { return .failure(error.localizedDescription) }
            await waitWhile { printer.printing }
            history.record(entry)
            return .success
        }
    }

    /// Attend tant que `condition` est vraie, avec une borne de sécurité (20 s) pour ne jamais
    /// bloquer la file si un service ne repasse pas au repos.
    @MainActor
    private func waitWhile(_ condition: @escaping () -> Bool) async {
        // Laisse le service passer à l'état « occupé » avant de surveiller son retour au repos.
        try? await Task.sleep(for: .milliseconds(120))
        let deadline = Date().addingTimeInterval(20)
        while condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    /// Carte imprimante (modèle, statut, batterie, bouton Connecter/Changer). Ouvre la modale imprimante.
    private var printerCard: some View {
        HStack {
            if isNetum {
                Image(systemName: "printer.fill")
                    .font(.title3).foregroundStyle(netum.connected ? .green : .secondary)
                VStack(alignment: .leading) {
                    Text(netum.connected ? (netum.connectedName ?? "NETUM") : NSLocalizedString("NETUM NT-H861", comment: "NETUM card title")).font(.headline)
                    Text(netum.status).font(.subheadline)
                        .foregroundStyle(netum.statusIsError ? .red : .primary)
                    Text(setup.netum.paper.title + " · " + setup.netum.cut.title)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if netum.isBusy { ProgressView(value: netum.progress).frame(width: 44) }
                Button(netum.connected ? NSLocalizedString("Changer", comment: "Change printer") : NSLocalizedString("Connecter", comment: "Connect printer")) { openPrinters() }
            } else if isBrother {
                Image(systemName: "printer.fill")
                    .font(.title3).foregroundStyle(printerReady ? .green : .secondary)
                VStack(alignment: .leading) {
                    Text(String(format: NSLocalizedString("Brother %@", comment: "Brother printer card title"), setup.brotherModel.title)).font(.headline)
                    Text(brother.target?.displayName ?? NSLocalizedString("Aucune imprimante Brother choisie", comment: "Brother status"))
                        .font(.subheadline)
                    if brother.target != nil || brother.status != NSLocalizedString("Aucune imprimante Brother choisie", comment: "Brother status") {
                        Text(brother.status).font(.caption)
                            .foregroundStyle(brother.statusIsError ? .red : .secondary)
                    }
                }
                Spacer()
                if brother.activity == .printing {
                    Button("Annuler", role: .destructive) { brother.cancelPrint() }
                } else if brother.isBusy { ProgressView() }
                Button(brother.target == nil ? NSLocalizedString("Connecter", comment: "Connect printer") : NSLocalizedString("Changer", comment: "Change printer")) { openPrinters() }
            } else {
                Image(systemName: "printer.fill")
                    .font(.title3).foregroundStyle(printer.connected ? .green : .secondary)
                VStack(alignment: .leading) {
                    Text(printer.connected ? printer.displayName : NSLocalizedString("Imprimante", comment: "Printer card title")).font(.headline)
                    Text(printer.status).font(.subheadline)
                    if printer.connected {
                        Label(printer.batteryPercent.map { String(format: NSLocalizedString("Batterie %d %%", comment: "Printer battery"), $0) } ?? NSLocalizedString("Batterie en cours de lecture", comment: "Printer battery"),
                              systemImage: printer.batteryPercent == nil ? "battery.0percent" : "battery.100percent")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(printer.connected ? NSLocalizedString("Changer", comment: "Change printer") : NSLocalizedString("Connecter", comment: "Connect printer")) { openPrinters() }
            }
        }
        .padding(16)
        .modifier(PrintCardStyle())
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { openPrinters() }
        .accessibilityAction(named: Text("Réglages de l’imprimante")) { openPrinters() }
    }

    /// Carte « Modèle d'étiquette » : ouvre la bibliothèque de modèles (presets + perso).
    private var templateCard: some View {
        Button { showingTemplates = true } label: {
            HStack {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.title3).foregroundStyle(.primary)
                VStack(alignment: .leading) {
                    Text(NSLocalizedString("Modèle d’étiquette", comment: "Template card title")).font(.headline)
                    HStack(spacing: 6) {
                        Text(currentTemplate.name).font(.subheadline).foregroundStyle(.secondary)
                        if currentTemplate.isLocked {
                            Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.secondary)
            }
            .padding(16)
            .modifier(PrintCardStyle())
        }
        .buttonStyle(ResponsiveCardStyle())
    }

    /// Carte « Format de l'étiquette » : ouvre le sélecteur de hauteur (LabelSize) à miniatures.
    private var presentationCard: some View {
        Button {
            // Les miniatures sont rendues à la demande par chaque tuile (voir presentationTile),
            // avec un cache persistant par clé : rien à préparer ici.
            showingPresentation = true
        } label: {
            HStack {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.title3).foregroundStyle(.primary)
                VStack(alignment: .leading) {
                    Text(NSLocalizedString("Format de l’étiquette", comment: "Format card title")).font(.headline)
                    Text("\(labelSize.title) (\(printedSizeText))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.secondary)
            }
            .padding(16)
            .modifier(PrintCardStyle())
        }
        .buttonStyle(ResponsiveCardStyle())
    }

    /// Aperçu live de l'étiquette (le bitmap réel qui sera imprimé), rendu depuis l'étiquette donnée.
    private func previewCard(for previewLabel: ProductLabel) -> some View {
        let preview = (try? LabelRenderer.render(dated(previewLabel), template: currentTemplate,
                                                 size: labelSize, layoutWidth: layoutWidth,
                                                 continuousMedia: isContinuousMedia))
        return VStack(alignment: .leading, spacing: 8) {
            Text("APERÇU DE L’ÉTIQUETTE").font(.headline)
            if let preview, let image = LabelRenderer.preview(preview) {
                Image(uiImage: image).interpolation(.high).resizable()
                    .aspectRatio(CGFloat(preview.width) / CGFloat(preview.height), contentMode: .fit)
                    .background(.white)
                    .overlay(Rectangle().stroke(Color(.separator), lineWidth: 1))
                    .accessibilityLabel("Aperçu de l’étiquette à imprimer")
            } else {
                Text(NSLocalizedString("Aperçu indisponible pour cet article.", comment: "No preview"))
                    .frame(maxWidth: .infinity, minHeight: 170)
            }
        }
        .padding(16)
        .modifier(PrintCardStyle())
    }

    /// Petite carte quantité (−/+), juste au-dessus du bouton Imprimer.
    private var quantityCard: some View {
        HStack {
            Image(systemName: "number.square.fill").font(.title3).foregroundStyle(.primary)
            Text(NSLocalizedString("Quantité", comment: "Quantity")).font(.headline)
            Spacer()
            // Boutons −/+ avec la valeur AU MILIEU (un Stepper système ne l'affiche pas entre les deux).
            HStack(spacing: 0) {
                Button { if ebpQuantity > 1 { ebpQuantity -= 1 } } label: {
                    Image(systemName: "minus").frame(width: 44, height: 34).contentShape(Rectangle())
                }
                .disabled(ebpQuantity <= 1)
                Text("\(ebpQuantity)")
                    .font(.headline.monospacedDigit())
                    .frame(minWidth: 40)
                Button { if ebpQuantity < 99 { ebpQuantity += 1 } } label: {
                    Image(systemName: "plus").frame(width: 44, height: 34).contentShape(Rectangle())
                }
                .disabled(ebpQuantity >= 99)
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .modifier(PrintCardStyle())
    }

    /// Imprime la quantité demandée selon la marque : Netum et Brother en natif (copies),
    /// 5890 en séquence (une étiquette par appel, pilotée par la fin de l'impression).
    private func printCurrentLabel(copies: Int = 1) {
        guard printerReady else { return }
        guard (try? LabelRenderer.render(label, template: currentTemplate, size: labelSize, layoutWidth: layoutWidth)) != nil else {
            message = NSLocalizedString("Article invalide (EAN ou prix).", comment: "Invalid label")
            return
        }
        let count = max(1, copies)
        let entry = PrintedLabel(label: label, size: labelSize, arrangement: labelArrangement,
                                 densityValue: printer.density.rawValue,
                                 leadingFeedDots: printer.leadingFeedDots,
                                 trailingFeedDots: printer.trailingFeedDots,
                                 rotateContent180: printer.rotateContent180,
                                 netum: isNetum ? setup.netum : nil)
        if isNetum {
            let previous = setup.netum.copies
            setup.netum.copies = count
            do { try submit(label, size: labelSize, template: currentTemplate) {
                history.record(entry); setup.netum.copies = previous
            } }
            catch { setup.netum.copies = previous; message = error.localizedDescription }
        } else if isBrother {
            let previous = setup.copies
            setup.copies = count
            do { try submit(label, size: labelSize, template: currentTemplate) {
                history.record(entry); setup.copies = previous
            } }
            catch { setup.copies = previous; message = error.localizedDescription }
        } else {
            // 5890 : une étiquette par appel, en séquence.
            do {
                let bitmap = try LabelRenderer.render(dated(label), template: currentTemplate, size: labelSize)
                printCopiesSequentially(bitmap, remaining: count, onFinished: { history.record(entry) })
            } catch { message = error.localizedDescription }
        }
    }

    /// Imprime `remaining` copies du même bitmap sur la 5890, l'une après l'autre.
    /// `PrinterManager.print` s'auto-verrouille (`guard !printing`) : on enchaîne la copie
    /// suivante quand `printer.printing` repasse à false.
    private func printCopiesSequentially(_ bitmap: MonochromeBitmap, remaining: Int, onFinished: @escaping () -> Void) {
        guard remaining > 0 else { onFinished(); return }
        printer.print(bitmap)
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(15)
            while printer.printing && Date() < deadline {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            printCopiesSequentially(bitmap, remaining: remaining - 1, onFinished: onFinished)
        }
    }

    /// Envoie l'étiquette à l'imprimante choisie. La 5890 reçoit le bitmap
    /// de 384 points comme avant ; une Brother reçoit la même mise en page
    /// dessinée hors du fil principal à la résolution de sa tête ; la NETUM
    /// reçoit une disposition 80 mm (576 points) ou celle de la 5890 sur 58 mm.
    /// Envoie l'étiquette selon le MODÈLE choisi (preset → rendu historique, perso → zones).
    /// La date de génération est posée ici pour que les modèles qui l'affichent l'impriment.
    private func submit(_ label: ProductLabel, size: LabelSize, template: LabelTemplate,
                        onQueued: (() -> Void)? = nil) throws {
        let label = dated(label)
        let continuous = isContinuousMedia
        if isNetum {
            // Rouleau ticket continu : la hauteur suit le contenu.
            var bitmap = try LabelRenderer.render(label, template: template, size: size,
                                                  layoutWidth: layoutWidth, continuousMedia: true)
            if setup.netum.rotateContent180 { bitmap = try bitmap.rotated180() }
            netum.print(bitmap: bitmap.bytes, width: bitmap.width, height: bitmap.height,
                        options: setup.netum, onQueued: onQueued)
        } else if isBrother {
            brother.print(job: setup.brotherJob, layoutHeight: size.heightDots, render: { scale in
                try LabelRenderer.grayImage(LabelRenderer.render(label, template: template, size: size,
                                                                 scale: scale, continuousMedia: continuous))
            }, onSuccess: onQueued)
        } else {
            // Imprimante ticket basique (5890) : rouleau continu.
            printer.print(try LabelRenderer.render(label, template: template, size: size,
                                                   continuousMedia: true), onQueued: onQueued)
        }
    }

    /// Rouvre la fiche d'un article à partir de son étiquette (historique). L'historique ne garde
    /// que le `ProductLabel` : on reconstruit un `MappedProduct` minimal (détails complémentaires
    /// absents, repeuplés si l'article est rechargé depuis la gateway). Fermer d'abord l'historique,
    /// puis demander la navigation, pour que la fiche se pousse après la fermeture de la feuille.
    private func reopenDetail(for label: ProductLabel) {
        showingHistory = false
        reopenProduct = MappedProduct(label: label, priceExclVat: nil, eanWasInvalid: false)
    }

    private func restore(_ entry: PrintedLabel) {
        label = entry.label
        selectedSize = entry.size.rawValue
        selectedArrangement = entry.arrangement.rawValue
        if let options = entry.netum {
            // Travail NETUM : ses réglages, sans toucher à ceux de la 5890.
            // Transport Bluetooth gardé tel quel : il dépend de l'appareil.
            var restored = options
            restored.writeWithResponse = setup.netum.writeWithResponse
            restored.packetDelayMS = setup.netum.packetDelayMS
            setup.netum = restored
        } else {
            printer.density = PrintDensity(rawValue: entry.densityValue) ?? .medium
            printer.leadingFeedDots = entry.leadingFeedDots
            printer.trailingFeedDots = entry.trailingFeedDots
            printer.rotateContent180 = entry.rotateContent180
        }
        showingHistory = false
    }

    private func reprint(_ entry: PrintedLabel) {
        guard printerReady else { return }
        restore(entry)
        do {
            _ = try LabelRenderer.render(entry.label, template: currentTemplate, size: entry.size)
            let copy = PrintedLabel(label: entry.label, size: entry.size, arrangement: entry.arrangement,
                                    densityValue: entry.densityValue, leadingFeedDots: entry.leadingFeedDots,
                                    trailingFeedDots: entry.trailingFeedDots,
                                    rotateContent180: entry.rotateContent180,
                                    netum: isNetum ? setup.netum : nil)
            try submit(entry.label, size: entry.size, template: currentTemplate) { history.record(copy) }
        } catch { message = error.localizedDescription }
    }

    private var historySheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $historyTab) {
                    Text(NSLocalizedString("Consultés", comment: "Viewed")).tag(0)
                    Text(NSLocalizedString("Imprimés", comment: "Printed")).tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                if historyTab == 0 { viewedList } else { printedList }
            }
            .navigationTitle(NSLocalizedString("Historique", comment: "History"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button(NSLocalizedString("Fermer", comment: "Close")) { showingHistory = false } }
        }
    }

    /// Historique des articles consultés (fiche ouverte).
    private var viewedList: some View {
        List {
            if viewed.entries.isEmpty {
                ContentUnavailableView(NSLocalizedString("Aucun article consulté", comment: "No viewed product"),
                                       systemImage: "eye",
                                       description: Text(NSLocalizedString("Les articles que vous ouvrez apparaîtront ici.", comment: "")))
            }
            ForEach(viewed.entries) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.label.name).font(.headline)
                    HStack(spacing: 10) {
                        let ref = entry.label.productReference.trimmingCharacters(in: .whitespaces)
                        if !ref.isEmpty { Text(ref).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if !entry.label.price.isEmpty {
                            Text(entry.label.price + " " + entry.label.currency.symbol)
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    Text(entry.viewedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(NSLocalizedString("Reprendre", comment: "Reuse viewed product")) {
                        label = entry.label; ebpQuantity = 1
                        reopenDetail(for: entry.label)
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 2)
                }
                .padding(.vertical, 4)
            }
            .onDelete(perform: viewed.delete)
        }
        .listStyle(.plain)
    }

    /// Historique des étiquettes imprimées.
    private var printedList: some View {
        List {
            if history.entries.isEmpty {
                ContentUnavailableView(NSLocalizedString("Aucune impression enregistrée", comment: "No print"),
                                       systemImage: "printer",
                                       description: Text(NSLocalizedString("Les étiquettes imprimées apparaîtront ici.", comment: "")))
            }
            ForEach(history.entries) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.label.name).font(.headline)
                    Text("\(entry.printedAt.formatted(date: .abbreviated, time: .shortened)) · \(entry.arrangement.title) · \(entry.size.title)")
                        .font(.subheadline).foregroundStyle(.secondary)
                    HStack {
                        Button(NSLocalizedString("Restaurer", comment: "Restore")) {
                            restore(entry)
                            reopenDetail(for: entry.label)
                        }
                            .buttonStyle(.bordered)
                        Button(NSLocalizedString("Réimprimer", comment: "Reprint")) { reprint(entry) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!printerReady || isPrinting)
                    }
                }
                .padding(.vertical, 4)
            }
            .onDelete(perform: history.delete)
        }
        .listStyle(.plain)
    }

    /// Bibliothèque de modèles : presets verrouillés + modèles perso, avec duplication/édition.
    private var templatesSheet: some View {
        LabelTemplateListView(store: templates,
                              sampleLabel: selectionPreviewLabel,
                              size: labelSize, layoutWidth: layoutWidth,
                              selectedTemplateID: selectedTemplateID,
                              onClose: { showingTemplates = false })
    }

    /// Choix du FORMAT (hauteur LabelSize). La disposition relève désormais du MODÈLE.
    private var presentationSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Format").font(.title3.bold())
                    Text(isNetum && layoutWidth == WideLabelLayout.width
                         ? NSLocalizedString("Choisissez la hauteur de la zone imprimée. La largeur est de 72 mm sur rouleau 80 mm.", comment: "Presentation help")
                         : NSLocalizedString("Choisissez la hauteur de la zone imprimée. La largeur reste de 48 mm sur la 5890.", comment: "Presentation help"))
                        .font(.footnote).foregroundStyle(.secondary)
                    VStack(spacing: 12) {
                        ForEach(LabelSize.allCases) { size in
                            Button { selectedSize = size.rawValue } label: {
                                presentationTile(title: size.title, detail: "\(layoutWidthMM) × \(size.heightMillimeters) mm",
                                                 size: size, selected: labelSize == size, fullWidth: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Format")
            .toolbar { Button("Terminé") { showingPresentation = false } }
        }
    }

    private func presentationTile(title: String, detail: String, size: LabelSize,
                                  selected: Bool, fullWidth: Bool = false) -> some View {
        // La miniature de format reflète le MODÈLE courant à la hauteur de la tuile.
        let thumbnailKey = TemplateThumbnailStore.key(for: selectionPreviewLabel, template: currentTemplate, size: size, width: layoutWidth)
        return VStack(alignment: .leading, spacing: 7) {
            ZStack {
                Color.white
                if let image = formatThumbnails.images[thumbnailKey] {
                    Image(uiImage: image).interpolation(.high).resizable()
                        .aspectRatio(CGFloat(layoutWidth) / CGFloat(size.heightDots), contentMode: .fit)
                        .padding(5)
                } else if formatThumbnails.failed.contains(thumbnailKey) {
                    Text("Aperçu indisponible").font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView().tint(.blue)
                }
            }
            // Chaque tuile demande SA propre miniature. `.task(id:)` se (re)lance à l'apparition
            // de la tuile et à chaque changement de clé (format sélectionné, modèle, produit) :
            // une clé non encore résolue est toujours redemandée — plus de spinner permanent.
            .task(id: thumbnailKey) {
                await formatThumbnails.thumbnail(for: selectionPreviewLabel, template: currentTemplate,
                                                 size: size, width: layoutWidth)
            }
            .frame(height: fullWidth ? CGFloat(size.heightDots) * 0.82 : 125)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(.separator), lineWidth: 1))
            HStack {
                Text(title).font(.subheadline.bold()).foregroundStyle(.primary)
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) }
            }
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(selected ? Color.blue.opacity(0.18) : Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.blue : Color.clear, lineWidth: 2))
        .accessibilityLabel("\(title)\(detail.isEmpty ? "" : ", \(detail)")\(selected ? NSLocalizedString(", sélectionné", comment: "Selected tile accessibility suffix") : "")")
    }

    private var printerSheet: some View {
        PrinterSelectionView(printer: printer, setup: setup, brother: brother, netum: netum,
                             canTestPrint: printerReady && !isPrinting,
                             onTestPrint: printTestLabel,
                             onClose: { showingPrinters = false })
    }

    private func openPrinters() {
        if isNetum { netum.scan() } else if !isBrother { printer.scan() }
        showingPrinters = true
    }

    private func printTestLabel() {
        let test = ProductLabel(name: NSLocalizedString("TEST TEXTE 12 18 27", comment: "Calibration label"), category: "5890 · 384 points", shelfReference: NSLocalizedString("RÉF RAYON : 12-04-08", comment: "Calibration label"), productReference: NSLocalizedString("TRAITS | || |||", comment: "Calibration label"), ean: "4006381333931", price: "5,95")
        do {
            try submit(test, size: labelSize, template: currentTemplate)
            showingPrinters = false
        } catch { message = error.localizedDescription }
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("Imprimante") {
                    LabeledContent("Imprimante", value: isNetum ? "NETUM NT-H861" : isBrother
                                   ? String(format: NSLocalizedString("Brother %@", comment: "Brother printer card title"), setup.brotherModel.title)
                                   : "Pocket 5890")
                    Button("Choisir l’imprimante et le papier") {
                        showingSettings = false
                        // Une feuille ne s'ouvre qu'après la fermeture de la précédente.
                        Task { try? await Task.sleep(for: .milliseconds(450)); openPrinters() }
                    }
                }
                Section("Application") {
                    LabeledContent("Langue de l’application", value: Bundle.main.preferredLocalizations.first == "en" ? "English" : "Français")
                    Button("Choisir la langue dans les réglages iPhone", systemImage: "arrow.up.right.square") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                    Text("Le français et l’anglais sont disponibles. iOS applique le choix à toute l’application.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                shareSyncSection
                GatewaySettingsSection(settings: gateway)
            }
            .navigationTitle("Réglages")
            .toolbar { Button("Fermer") { showingSettings = false } }
            .sheet(item: $settingsShare) { sheet in settingsShareSheet(sheet) }
        }
    }

    /// Section « Partage entre téléphones » des Réglages : tout exporter, exports individuels, et un
    /// import universel (scan QR) qui reconnaît modèles, réglages ou export combiné.
    private var shareSyncSection: some View {
        Section {
            Button {
                settingsShare = .exportAll
            } label: {
                Label("Tout exporter (modèles + réglages)", systemImage: "square.and.arrow.up.on.square")
            }
            .disabled(exportableTemplates.isEmpty)
            Button {
                settingsShare = .exportTemplates
            } label: {
                Label("Exporter les modèles d’étiquette", systemImage: "square.and.arrow.up")
            }
            .disabled(templates.all.isEmpty)
            Button {
                settingsShare = .exportPrinter
            } label: {
                Label("Exporter les réglages imprimante", systemImage: "printer")
            }
            Button {
                settingsShare = .importAny
            } label: {
                Label("Importer (scanner un QR)", systemImage: "qrcode.viewfinder")
            }
        } header: {
            Text("Partage entre téléphones")
        } footer: {
            Text("Exportez vos modèles et réglages vers un autre téléphone par AirDrop ou QR code, ou importez-les. L’appairage Bluetooth n’est pas transféré.")
        }
    }

    /// Les modèles perso + tous les presets, exportés comme modèles éditables sur l'autre appareil.
    private var exportableTemplates: [LabelTemplate] { templates.all }

    @ViewBuilder
    private func settingsShareSheet(_ sheet: SettingsShareSheet) -> some View {
        switch sheet {
        case .exportAll:
            let printerPayload = PrinterSettingsSharing.capture(setup: setup, printer: printer)
            let bundle = CombinedSharePayload(templates: exportableTemplates, printer: printerPayload)
            ShareQRView(
                title: NSLocalizedString("Tout exporter", comment: "Export all title"),
                subtitle: String(format: NSLocalizedString("%d modèle(s) et les réglages imprimante.", comment: "Export all subtitle"), exportableTemplates.count),
                payload: bundle.encoded(),
                fileName: NSLocalizedString("Étiquettes EBP — tout", comment: "Export all file name"),
                fileExtension: ShareDocumentType.bundleExtension,
                forceFile: true,
                onClose: { settingsShare = nil })
        case .exportTemplates:
            ShareQRView(
                title: NSLocalizedString("Modèles d’étiquette", comment: "Templates share title"),
                subtitle: String(format: NSLocalizedString("%d modèle(s) à partager.", comment: "Templates share subtitle"), exportableTemplates.count),
                payload: TemplateSharePayload(templates: exportableTemplates).encoded(),
                fileName: NSLocalizedString("Modèles d’étiquette", comment: "Templates file name"),
                fileExtension: ShareDocumentType.templateExtension,
                forceFile: true,
                onClose: { settingsShare = nil })
        case .exportPrinter:
            let payload = PrinterSettingsSharing.capture(setup: setup, printer: printer)
            ShareQRView(
                title: NSLocalizedString("Réglages imprimante", comment: "Printer settings share title"),
                subtitle: PrinterSettingsSharing.summary(for: payload),
                payload: payload.encoded(),
                fileName: NSLocalizedString("Réglages imprimante", comment: "Printer settings file name"),
                fileExtension: ShareDocumentType.printerExtension,
                onClose: { settingsShare = nil })
        case .importAny:
            ImportScanView(
                title: NSLocalizedString("Importer", comment: "Import universal title"),
                hint: NSLocalizedString("Scannez le QR affiché par l’autre téléphone (modèles, réglages ou tout).", comment: "Import universal hint"),
                onScanned: { raw in ShareImporter.importJSON(raw, templates: templates, setup: setup, printer: printer) },
                onClose: { settingsShare = nil })
        }
    }
}

/// Feuille ouverte depuis la section Partage des Réglages.
private enum SettingsShareSheet: String, Identifiable {
    case exportAll, exportTemplates, exportPrinter, importAny
    var id: String { rawValue }
}

private struct ResponsiveCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct PrintCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.background(Color(.secondarySystemGroupedBackground),
                           in: RoundedRectangle(cornerRadius: 14))
    }
}

