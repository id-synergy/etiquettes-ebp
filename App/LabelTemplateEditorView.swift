import SwiftUI

/// Éditeur de modèle : aperçu live en haut (rendu à la demande, idempotent par clé incluant
/// une signature des lignes → se met à jour à chaque changement), liste des LIGNES réordonnables
/// (drag + bascule pleine largeur / deux colonnes), et feuille d'édition par cellule
/// (contenu + style). Un preset verrouillé s'ouvre en lecture seule avec « Dupliquer pour modifier ».
struct LabelTemplateEditorView: View {
    @ObservedObject var store: LabelTemplateLibraryStore
    @ObservedObject var thumbnails: TemplateThumbnailStore
    let sampleLabel: ProductLabel
    let size: LabelSize
    let layoutWidth: Int
    /// Appelé quand l'utilisateur enregistre et choisit ce modèle pour l'impression.
    let onSelect: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Brouillon local édité (copie du modèle ouvert) ; les lignes matérialisées pour un preset.
    @State private var draft: LabelTemplate
    /// Cellule en cours d'édition : (ligne id, cellule id).
    @State private var editingCell: CellRef?
    @State private var liveImage: UIImage?
    @State private var liveFailed = false

    private let isLocked: Bool

    private struct CellRef: Identifiable { let lineID: UUID; let cellID: UUID; var id: String { "\(lineID)-\(cellID)" } }

    init(store: LabelTemplateLibraryStore, thumbnails: TemplateThumbnailStore,
         template: LabelTemplate, sampleLabel: ProductLabel, size: LabelSize,
         layoutWidth: Int, onSelect: @escaping (UUID) -> Void) {
        self.store = store
        self.thumbnails = thumbnails
        self.sampleLabel = sampleLabel
        self.size = size
        self.layoutWidth = layoutWidth
        self.onSelect = onSelect
        self.isLocked = template.isLocked
        var start = template
        if start.lines.isEmpty { start.lines = template.materializedLines() }
        _draft = State(initialValue: start)
    }

    /// Clé de rendu : change à chaque modification du brouillon (via `contentSignature`, qui
    /// couvre contenu, style, préfixe/suffixe, placeholder et mode de rendu du code) → relance
    /// le `.task`. Inclut aussi la signature de l'étiquette source, la taille et la largeur.
    private var liveKey: String {
        draft.thumbnailKey(forLabelSignature: sampleLabel.hashValue, size: size, width: layoutWidth)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                previewHeader
                List {
                    if !isLocked {
                        Section {
                            TextField(NSLocalizedString("Nom du modèle", comment: "Template name"), text: $draft.name)
                                .font(.headline)
                        }
                    }
                    Section(NSLocalizedString("Lignes (ordre d’affichage)", comment: "Lines section")) {
                        ForEach(Array(draft.lines.enumerated()), id: \.element.id) { index, line in
                            lineRow(line, index: index)
                        }
                        .onMove { from, to in draft.lines.move(fromOffsets: from, toOffset: to) }
                        .onDelete { indexes in if !isLocked { draft.lines.remove(atOffsets: indexes) } }
                        .deleteDisabled(isLocked)
                        .moveDisabled(isLocked)
                        if !isLocked {
                            Button {
                                draft.lines.append(.full(TemplateCell(content: .texteLibre(""))))
                            } label: {
                                Label(NSLocalizedString("Ajouter une ligne", comment: "Add line"), systemImage: "plus.circle")
                            }
                        }
                    }
                }
                .environment(\.editMode, .constant(isLocked ? .inactive : .active))
            }
            .navigationTitle(isLocked ? draft.name : NSLocalizedString("Éditer le modèle", comment: "Edit template"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(NSLocalizedString("Fermer", comment: "Close")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isLocked {
                        Button {
                            if let copy = store.duplicate(id: draft.id) {
                                var copy = copy
                                if copy.lines.isEmpty { copy.lines = copy.materializedLines() }
                                draft = copy
                            }
                        } label: {
                            Label(NSLocalizedString("Dupliquer pour modifier", comment: "Duplicate to edit"), systemImage: "plus.square.on.square")
                        }
                    } else {
                        Button(NSLocalizedString("Enregistrer", comment: "Save")) { saveAndChoose() }
                            .fontWeight(.semibold)
                    }
                }
            }
            .sheet(item: $editingCell) { ref in
                cellEditor(lineID: ref.lineID, cellID: ref.cellID)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    // MARK: - Aperçu live

    private var previewHeader: some View {
        VStack(spacing: 6) {
            ZStack {
                Color.white
                if let liveImage {
                    Image(uiImage: liveImage).interpolation(.high).resizable()
                        .aspectRatio(CGFloat(layoutWidth) / CGFloat(size.heightDots), contentMode: .fit)
                        .padding(6)
                } else if liveFailed {
                    Text(NSLocalizedString("Aperçu indisponible pour cet article.", comment: "No preview"))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView().tint(.blue)
                }
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.separator), lineWidth: 1))
            .padding(.horizontal)
            if isLocked {
                Label(NSLocalizedString("Modèle par défaut — lecture seule", comment: "Locked template hint"),
                      systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
        // Idempotent par clé : à chaque modification la clé change et le rendu (sur MainActor,
        // thread-safe) est relancé, aboutissant toujours à un état terminal. On NE cède pas avant
        // de rendre : le rendu est court, et céder ouvrait une fenêtre où une relance annulait la
        // tâche juste après avoir remis l'aperçu à nil, le laissant vide sur un spinner.
        .task(id: liveKey) {
            let bitmap = try? LabelRenderer.render(sampleLabel, template: draft, size: size, layoutWidth: layoutWidth)
            if let image = bitmap.flatMap(LabelRenderer.preview) {
                liveImage = image; liveFailed = false
            } else {
                liveImage = nil; liveFailed = true
            }
        }
    }

    // MARK: - Ligne

    @ViewBuilder
    private func lineRow(_ line: TemplateLine, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(format: NSLocalizedString("Ligne %d", comment: "Line number"), index + 1))
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if !isLocked {
                    Button {
                        draft.lines[index] = line.toggledLayout()
                    } label: {
                        Label(line.layout == .full
                              ? NSLocalizedString("Passer en 2 colonnes", comment: "To two columns")
                              : NSLocalizedString("Passer en pleine largeur", comment: "To full width"),
                              systemImage: line.layout == .full ? "rectangle.split.2x1" : "rectangle")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            HStack(spacing: 8) {
                ForEach(Array(line.cells.enumerated()), id: \.element.id) { _, cell in
                    cellChip(cell)
                        .onTapGesture { if !isLocked { editingCell = CellRef(lineID: line.id, cellID: cell.id) } }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func cellChip(_ cell: TemplateCell) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon(for: cell.content)).font(.footnote).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text(cellTitle(cell)).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(styleSummary(cell.style)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if !isLocked { Image(systemName: "pencil").font(.caption2).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
    }

    private func cellTitle(_ cell: TemplateCell) -> String {
        if case .texteLibre(let v) = cell.content, !v.isEmpty { return "« \(v) »" }
        if case .codeLibre(let v) = cell.content, !v.isEmpty {
            let mode = cell.codeRendering == .qr ? "QR" : NSLocalizedString("Code-barres", comment: "Code rendering")
            return "\(mode) · \(v)"
        }
        return cell.content.title
    }
    private func styleSummary(_ style: CellStyle) -> String {
        var parts = [style.size.title, style.alignH.title]
        if style.bold { parts.append(NSLocalizedString("Gras", comment: "Bold")) }
        if style.italic { parts.append(NSLocalizedString("Italique", comment: "Italic")) }
        return parts.joined(separator: " · ")
    }
    private func icon(for content: CellContent) -> String {
        switch content {
        case .vide: "square.dashed"
        case .designation: "textformat"
        case .refArticle: "number"
        case .refRayon: "square.grid.3x3"
        case .famille: "folder"
        case .prixTTC: "eurosign"
        case .prixHT: "eurosign.circle"
        case .montantTVA: "percent"
        case .stockReel: "shippingbox"
        case .stockDispo: "shippingbox.and.arrow.backward"
        case .sousFamille: "folder.badge.gearshape"
        case .fournisseur: "building.2"
        case .unite: "ruler"
        case .poids: "scalemass"
        case .volume: "cube"
        case .codeBarres: "barcode"
        case .codeLibre: "qrcode"
        case .dateGeneration: "calendar"
        case .texteLibre: "text.quote"
        }
    }

    // MARK: - Feuille d'édition d'une cellule

    @ViewBuilder
    private func cellEditor(lineID: UUID, cellID: UUID) -> some View {
        if let li = draft.lines.firstIndex(where: { $0.id == lineID }),
           let ci = draft.lines[li].cells.firstIndex(where: { $0.id == cellID }) {
            let cellBinding = $draft.lines[li].cells[ci]
            NavigationStack {
                Form {
                    Section(NSLocalizedString("Contenu", comment: "Content")) {
                        Picker(NSLocalizedString("Contenu", comment: "Content"), selection: contentKindBinding(cellBinding)) {
                            ForEach(CellContent.selectableKinds, id: \.title) { kind in
                                Text(kind.title).tag(kind.title)
                            }
                        }
                        if case .texteLibre = cellBinding.wrappedValue.content {
                            TextField(NSLocalizedString("Texte à afficher", comment: "Free text"), text: freeTextBinding(cellBinding))
                        }
                        if case .codeLibre = cellBinding.wrappedValue.content {
                            TextField(NSLocalizedString("Valeur à encoder", comment: "Free code value"), text: freeCodeBinding(cellBinding))
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                    }
                    if cellBinding.wrappedValue.content.isDate {
                        dateFormatSection(cellBinding)
                    }
                    if cellBinding.wrappedValue.content.isBarcode {
                        codeRenderingSection(cellBinding)
                    }
                    if decorationsApply(to: cellBinding.wrappedValue) {
                        decorationsSection(cellBinding)
                    }
                    Section(NSLocalizedString("Taille", comment: "Size")) {
                        Picker(NSLocalizedString("Taille", comment: "Size"), selection: cellBinding.style.size) {
                            ForEach(CellStyle.Size.allCases, id: \.self) { s in Text(s.title).tag(s) }
                        }
                        .pickerStyle(.segmented)
                    }
                    Section(NSLocalizedString("Alignement", comment: "Alignment")) {
                        Picker(NSLocalizedString("Horizontal", comment: "Horizontal alignment"), selection: cellBinding.style.alignH) {
                            ForEach(CellStyle.AlignH.allCases, id: \.self) { a in Text(a.title).tag(a) }
                        }
                        .pickerStyle(.segmented)
                        Picker(NSLocalizedString("Vertical", comment: "Vertical alignment"), selection: cellBinding.style.alignV) {
                            ForEach(CellStyle.AlignV.allCases, id: \.self) { a in Text(a.title).tag(a) }
                        }
                        .pickerStyle(.segmented)
                    }
                    Section {
                        Toggle(NSLocalizedString("Gras", comment: "Bold"), isOn: cellBinding.style.bold)
                        Toggle(NSLocalizedString("Italique", comment: "Italic"), isOn: cellBinding.style.italic)
                    }
                }
                .navigationTitle(NSLocalizedString("Cellule", comment: "Cell editor title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button(NSLocalizedString("Terminé", comment: "Done")) { editingCell = nil } }
            }
        }
    }

    // MARK: - Rendu du code (code-barres / QR) et décorations (préfixe/suffixe/placeholder)

    /// Vrai si la section décorations a du sens pour ce contenu. Exclue pour « Vide » (aucune
    /// valeur) et pour toute cellule de type CODE (le préfixe/suffixe/placeholder entoure un texte
    /// lisible, pas une valeur encodée en barres ou QR).
    private func decorationsApply(to cell: TemplateCell) -> Bool {
        if case .vide = cell.content { return false }
        if cell.content.isBarcode { return false }
        return true
    }

    /// Segment « Code-barres / QR » affiché pour toute cellule de type code (code-barres article
    /// ET code libre). L'aide s'adapte à la source de la valeur encodée.
    @ViewBuilder
    private func codeRenderingSection(_ cell: Binding<TemplateCell>) -> some View {
        let isFree = { if case .codeLibre = cell.wrappedValue.content { return true }; return false }()
        Section(NSLocalizedString("Type de rendu", comment: "Code rendering section")) {
            Picker(NSLocalizedString("Type", comment: "Code rendering type"), selection: cell.codeRendering) {
                ForEach(CodeRendering.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
            }
            .pickerStyle(.segmented)
            Text(codeRenderingHint(qr: cell.wrappedValue.codeRendering == .qr, free: isFree))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func codeRenderingHint(qr: Bool, free: Bool) -> String {
        switch (qr, free) {
        case (false, false): return NSLocalizedString("Code-barres EAN-13 de l’article, chiffres sous les barres.", comment: "Barcode hint article")
        case (true, false): return NSLocalizedString("QR code encodant le code-barres (EAN) de l’article, redimensionné dans la cellule.", comment: "QR hint article")
        case (false, true): return NSLocalizedString("Code-barres EAN-13 de la valeur saisie (si elle forme un EAN valide, sinon QR).", comment: "Barcode hint free")
        case (true, true): return NSLocalizedString("QR code encodant la valeur saisie, redimensionné dans la cellule.", comment: "QR hint free")
        }
    }

    @ViewBuilder
    private func decorationsSection(_ cell: Binding<TemplateCell>) -> some View {
        Section {
            TextField(NSLocalizedString("Préfixe (avant la valeur)", comment: "Prefix field"), text: cell.prefix)
                .autocorrectionDisabled()
            TextField(NSLocalizedString("Suffixe (après la valeur)", comment: "Suffix field"), text: cell.suffix)
                .autocorrectionDisabled()
            TextField(NSLocalizedString("Valeur de repli si vide", comment: "Placeholder field"), text: cell.placeholder)
                .autocorrectionDisabled()
        } header: {
            Text(NSLocalizedString("Préfixe · suffixe · repli", comment: "Decorations section"))
        } footer: {
            Text(NSLocalizedString("Préfixe et suffixe entourent la valeur (ex. « Réf. », « kg »). La valeur de repli s’affiche seule quand le champ est vide.", comment: "Decorations footer"))
        }
    }

    /// Binding sur le « genre » de contenu (par titre, pour piloter le Picker), en conservant
    /// la valeur du texte libre quand on reste sur « Texte libre ».
    private func contentKindBinding(_ cell: Binding<TemplateCell>) -> Binding<String> {
        Binding(
            get: { cell.wrappedValue.content.title },
            set: { title in
                guard let kind = CellContent.selectableKinds.first(where: { $0.title == title }) else { return }
                // Conserver la valeur portée quand on reste sur le même genre (texte libre, date).
                if case .texteLibre = kind, case .texteLibre(let existing) = cell.wrappedValue.content {
                    cell.wrappedValue.content = .texteLibre(existing)
                } else if case .dateGeneration = kind, case .dateGeneration(let existing) = cell.wrappedValue.content {
                    cell.wrappedValue.content = .dateGeneration(existing)
                } else if case .codeLibre = kind, case .codeLibre(let existing) = cell.wrappedValue.content {
                    cell.wrappedValue.content = .codeLibre(existing)
                } else {
                    cell.wrappedValue.content = kind
                }
            }
        )
    }
    private func freeTextBinding(_ cell: Binding<TemplateCell>) -> Binding<String> {
        Binding(
            get: { if case .texteLibre(let v) = cell.wrappedValue.content { return v }; return "" },
            set: { cell.wrappedValue.content = .texteLibre($0) }
        )
    }
    private func freeCodeBinding(_ cell: Binding<TemplateCell>) -> Binding<String> {
        Binding(
            get: { if case .codeLibre(let v) = cell.wrappedValue.content { return v }; return "" },
            set: { cell.wrappedValue.content = .codeLibre($0) }
        )
    }

    // MARK: - Format de la date de génération

    /// Date d'exemple pour l'aperçu du format (fixe → résultat stable et parlant).
    private var dateSample: Date { sampleLabel.generatedAt ?? Date(timeIntervalSince1970: 1_778_000_000) }

    /// Pattern effectif de la cellule date (défaut si nil).
    private func datePattern(_ cell: Binding<TemplateCell>) -> String {
        let p = cell.wrappedValue.content.dateFormatPattern
        return (p?.isEmpty == false) ? p! : LabelDateFormatter.defaultPattern
    }

    @ViewBuilder
    private func dateFormatSection(_ cell: Binding<TemplateCell>) -> some View {
        let current = datePattern(cell)
        Section(NSLocalizedString("Format de la date", comment: "Date format")) {
            // Presets prêts à l'emploi.
            Picker(NSLocalizedString("Format", comment: "Date format preset"), selection: datePresetBinding(cell)) {
                ForEach(LabelDateFormatter.presets) { preset in
                    Text("\(preset.label)  ·  \(LabelDateFormatter.text(for: dateSample, pattern: preset.pattern))")
                        .tag(preset.pattern)
                }
                // Entrée « personnalisé » : le pattern courant s'il ne correspond à aucun preset.
                if !LabelDateFormatter.presets.contains(where: { $0.pattern == current }) {
                    Text(NSLocalizedString("Personnalisé", comment: "Custom date format")).tag(current)
                }
            }
            // Champ format personnalisé en tokens simples (JJ, MM, AAAA, HH, mm, ss).
            VStack(alignment: .leading, spacing: 4) {
                TextField(NSLocalizedString("Format personnalisé", comment: "Custom format field"),
                          text: dateTokensBinding(cell))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Text(String(format: NSLocalizedString("Tokens : JJ MM AAAA HH mm ss  →  %@", comment: "Date tokens help"),
                            LabelDateFormatter.text(for: dateSample, pattern: current)))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Binding du preset (pattern) : écrit directement le pattern sur la cellule date.
    private func datePresetBinding(_ cell: Binding<TemplateCell>) -> Binding<String> {
        Binding(
            get: { datePattern(cell) },
            set: { cell.wrappedValue.content = .dateGeneration($0) }
        )
    }

    /// Binding du champ tokens : l'utilisateur tape « JJ/MM », traduit en pattern DateFormatter.
    private func dateTokensBinding(_ cell: Binding<TemplateCell>) -> Binding<String> {
        Binding(
            get: { LabelDateFormatter.tokens(fromPattern: datePattern(cell)) },
            set: { cell.wrappedValue.content = .dateGeneration(LabelDateFormatter.pattern(fromTokens: $0)) }
        )
    }

    private func saveAndChoose() {
        store.save(draft)
        thumbnails.invalidate(templateID: draft.id)
        onSelect(draft.id)
    }
}
