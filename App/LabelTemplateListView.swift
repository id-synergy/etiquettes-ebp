import SwiftUI

/// Cache de miniatures de MODÈLES, rendu à la demande et idempotent par clé (même pattern
/// anti-spinner que l'écran Présentation). Une clé = modèle + taille + largeur + signature
/// de l'étiquette source. Le rendu UIKit se fait sur le MainActor, toujours terminal.
@MainActor
final class TemplateThumbnailStore: ObservableObject {
    @Published private(set) var images: [String: UIImage] = [:]
    @Published private(set) var failed: Set<String> = []

    /// La clé embarque la signature de l'étiquette source : quand le label change, toutes les
    /// clés changent, les `.task(id:)` des tuiles se relancent et les anciennes entrées
    /// deviennent inertes (jamais relues). Aucun reset impératif n'efface le travail d'une
    /// autre tuile en cours — c'est ce qui laissait les modèles perso bloqués sur un spinner.
    /// La signature de contenu du modèle couvre aussi préfixe/suffixe/placeholder/mode QR.
    nonisolated static func key(for label: ProductLabel, template: LabelTemplate, size: LabelSize, width: Int) -> String {
        template.thumbnailKey(forLabelSignature: label.hashValue, size: size, width: width)
    }

    /// Invalide la miniature d'un modèle précis (après édition de ses zones) : les clés sont
    /// retirées du cache pour forcer un nouveau rendu à la prochaine demande.
    func invalidate(templateID: UUID) {
        images = images.filter { !$0.key.contains(templateID.uuidString) }
        failed = failed.filter { $0.contains(templateID.uuidString) == false }
    }

    /// Pré-remplit le cache de la miniature d'une COPIE à partir de celle de l'original : le
    /// contenu visuel est identique, seule l'UUID (donc la clé) diffère. Évite que la tuile de la
    /// copie reste bloquée sur son spinner si son `.task(id:)` est annulé par la réorganisation de
    /// la liste juste après la duplication (l'image existait, mais la copie ne la retrouvait pas).
    func seedThumbnail(from source: LabelTemplate, to copy: LabelTemplate,
                       label: ProductLabel, size: LabelSize, width: Int) {
        let sourceKey = Self.key(for: label, template: source, size: size, width: width)
        let copyKey = Self.key(for: label, template: copy, size: size, width: width)
        if let image = images[sourceKey] { images[copyKey] = image }
    }

    /// Rendu idempotent par clé : si déjà en cache (succès ou échec), on ne régénère rien ;
    /// sinon on génère et on écrit TOUJOURS un état terminal, dans la foulée.
    ///
    /// On NE cède PAS (`Task.yield`) et on ne teste PAS l'annulation avant d'écrire : le rendu
    /// d'une miniature est court et synchrone. Céder ouvrait une fenêtre où la réorganisation de
    /// la liste (ex. après « Dupliquer ») annulait la tâche juste avant l'écriture ; la tuile
    /// restait alors montée avec la même clé, son `.task(id:)` ne se relançait pas, et le spinner
    /// tournait indéfiniment alors que l'image avait pu être calculée. En écrivant toujours un
    /// état terminal, la tuile sort du spinner dès le premier passage.
    func thumbnail(for label: ProductLabel, template: LabelTemplate, size: LabelSize, width: Int) async {
        let key = Self.key(for: label, template: template, size: size, width: width)
        guard images[key] == nil, !failed.contains(key) else { return }
        let bitmap = try? LabelRenderer.render(label, template: template, size: size, layoutWidth: width)
        let image = bitmap.flatMap(LabelRenderer.preview)
        if let image { images[key] = image } else { failed.insert(key) }
    }
}

/// Écran « Modèles d'étiquette » : presets verrouillés (badge) + modèles perso. Chaque ligne
/// porte un mini-aperçu rendu avec le vrai moteur. Actions : nouveau, dupliquer, supprimer (perso),
/// et choix du modèle courant (coche).
struct LabelTemplateListView: View {
    @ObservedObject var store: LabelTemplateLibraryStore
    @StateObject private var thumbnails = TemplateThumbnailStore()
    /// Étiquette d'exemple pour les aperçus (produit sélectionné ou démo).
    let sampleLabel: ProductLabel
    let size: LabelSize
    let layoutWidth: Int
    /// Modèle actuellement choisi pour l'impression.
    @Binding var selectedTemplateID: UUID
    let onClose: () -> Void

    @State private var editing: LabelTemplate?
    @State private var newName = ""
    @State private var showingNew = false

    /// Modèle en cours de partage (feuille QR/fichier) ; nil = aucune.
    @State private var sharing: LabelTemplate?
    /// Partage de PLUSIEURS modèles : sélection multiple active + modèles cochés.
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var sharingMultiple: [LabelTemplate]?
    /// Import par scan QR.
    @State private var showingImport = false
    /// Message après un import réussi (nombre de modèles ajoutés).
    @State private var importMessage: String?

    private var previewLabel: ProductLabel {
        ((try? EAN13.completed(sampleLabel.ean)) != nil &&
         PriceFormatter.formatted(sampleLabel.price, currency: sampleLabel.currency) != nil)
            ? sampleLabel : ProductLabel()
    }

    var body: some View {
        NavigationStack {
            List {
                Section(NSLocalizedString("Modèles par défaut", comment: "Preset templates section")) {
                    ForEach(LabelTemplatePresets.all) { template in row(template, locked: true) }
                }
                Section(NSLocalizedString("Mes modèles", comment: "Custom templates section")) {
                    if store.custom.isEmpty {
                        Text(NSLocalizedString("Dupliquez un modèle par défaut pour l’adapter.", comment: "No custom templates"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(store.custom) { template in row(template, locked: false) }
                        .onDelete { indexes in
                            for index in indexes { store.delete(id: store.custom[index].id) }
                        }
                }
            }
            .navigationTitle(NSLocalizedString("Modèles", comment: "Templates screen title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if selecting {
                        Button(NSLocalizedString("Annuler", comment: "Cancel")) { endSelection() }
                    } else {
                        Button(NSLocalizedString("Terminé", comment: "Done")) { onClose() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if selecting {
                        Button(NSLocalizedString("Partager", comment: "Share")) { shareSelected() }
                            .disabled(selected.isEmpty)
                    } else {
                        Menu {
                            Button { newName = ""; showingNew = true } label: {
                                Label(NSLocalizedString("Nouveau modèle", comment: "New template"), systemImage: "plus")
                            }
                            Button { showingImport = true } label: {
                                Label(NSLocalizedString("Importer (scanner un QR)", comment: "Import via QR"), systemImage: "qrcode.viewfinder")
                            }
                            Button {
                                selecting = true; selected = []
                            } label: {
                                Label(NSLocalizedString("Partager plusieurs modèles…", comment: "Share several"), systemImage: "square.and.arrow.up.on.square")
                            }
                        } label: {
                            Label(NSLocalizedString("Plus", comment: "More"), systemImage: "ellipsis.circle")
                        }
                    }
                }
            }
            .sheet(item: $editing) { template in
                LabelTemplateEditorView(store: store, thumbnails: thumbnails,
                                        template: template, sampleLabel: previewLabel,
                                        size: size, layoutWidth: layoutWidth,
                                        onSelect: { id in selectedTemplateID = id; editing = nil })
            }
            .sheet(item: $sharing) { template in
                ShareQRView(
                    title: template.name,
                    subtitle: NSLocalizedString("Partagez ce modèle d’étiquette avec un autre téléphone.", comment: "Share one template subtitle"),
                    payload: TemplateSharePayload(templates: [template]).encoded(),
                    fileName: template.name,
                    fileExtension: ShareDocumentType.templateExtension,
                    onClose: { sharing = nil })
            }
            .sheet(isPresented: Binding(get: { sharingMultiple != nil }, set: { if !$0 { sharingMultiple = nil } })) {
                if let models = sharingMultiple {
                    ShareQRView(
                        title: String(format: NSLocalizedString("%d modèles", comment: "N templates"), models.count),
                        subtitle: NSLocalizedString("Plusieurs modèles se partagent par fichier (AirDrop, Messages…).", comment: "Share several subtitle"),
                        payload: TemplateSharePayload(templates: models).encoded(),
                        fileName: NSLocalizedString("Modèles d’étiquette", comment: "Templates file name"),
                        fileExtension: ShareDocumentType.templateExtension,
                        forceFile: true,
                        onClose: { sharingMultiple = nil })
                }
            }
            .sheet(isPresented: $showingImport) {
                ImportScanView(
                    title: NSLocalizedString("Importer un modèle", comment: "Import template title"),
                    hint: NSLocalizedString("Scannez le QR affiché par l’autre téléphone (Modèles → Partager).", comment: "Import template hint"),
                    onScanned: importScanned,
                    onClose: { showingImport = false })
            }
            .alert(NSLocalizedString("Import", comment: "Import alert"),
                   isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
                Button("OK") { importMessage = nil }
            } message: { Text(importMessage ?? "") }
            .alert(NSLocalizedString("Nouveau modèle", comment: "New template"), isPresented: $showingNew) {
                TextField(NSLocalizedString("Nom du modèle", comment: "Template name"), text: $newName)
                Button(NSLocalizedString("Créer", comment: "Create")) {
                    let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let created = store.createBlank(named: name.isEmpty ? NSLocalizedString("Mon modèle", comment: "Default new template name") : name)
                    editing = created
                }
                Button(NSLocalizedString("Annuler", comment: "Cancel"), role: .cancel) { }
            }
        }
    }

    /// Partage les modèles cochés : un seul → feuille QR/fichier simple ; plusieurs → fichier.
    private func shareSelected() {
        let models = store.all.filter { selected.contains($0.id) }
        guard !models.isEmpty else { return }
        endSelection()
        if models.count == 1 { sharing = models[0] } else { sharingMultiple = models }
    }

    private func endSelection() {
        selecting = false
        selected = []
    }

    /// Décode un QR scanné, importe les modèles (dédoublonnés), renvoie le résultat à afficher.
    private func importScanned(_ raw: String) -> ImportOutcome {
        switch TemplateSharePayload.decode(fromQRString: raw) {
        case .success(let payload):
            let ids = store.importTemplates(payload.templates)
            if let first = ids.first { selectedTemplateID = first }
            return .success(String(format: NSLocalizedString("%d modèle(s) importé(s).", comment: "Imported N templates"), ids.count))
        case .failure(let error):
            return .failure(error.userMessage)
        }
    }

    private func row(_ template: LabelTemplate, locked: Bool) -> some View {
        let key = TemplateThumbnailStore.key(for: previewLabel, template: template, size: size, width: layoutWidth)
        let isSelected = selectedTemplateID == template.id
        let isChecked = selected.contains(template.id)
        return HStack(spacing: 12) {
            if selecting {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isChecked ? Color.blue : Color.secondary)
            }
            ZStack {
                Color.white
                if let image = thumbnails.images[key] {
                    Image(uiImage: image).interpolation(.high).resizable()
                        .aspectRatio(CGFloat(layoutWidth) / CGFloat(size.heightDots), contentMode: .fit)
                        .padding(3)
                } else if thumbnails.failed.contains(key) {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                } else {
                    ProgressView().tint(.blue)
                }
            }
            .frame(width: 92, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(.separator), lineWidth: 1))
            .task(id: key) {
                await thumbnails.thumbnail(for: previewLabel, template: template, size: size, width: layoutWidth)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(template.name).font(.headline)
                // Deux pilules jumelles : icône + texte serrés (HStack dédié, pas de Label dont
                // SwiftUI étire l'espace icône↔texte dans une largeur contrainte). « Par défaut »
                // gris, « Sélectionné » bleu. Empilées pour ne jamais se couper au milieu d'un mot.
                VStack(alignment: .leading, spacing: 4) {
                    if locked {
                        badge(NSLocalizedString("Par défaut", comment: "Default badge"),
                              systemImage: "lock.fill",
                              foreground: Color.secondary, background: Color(.tertiarySystemFill))
                    }
                    if isSelected {
                        badge(NSLocalizedString("Sélectionné", comment: "Selected badge"),
                              systemImage: "checkmark.circle.fill",
                              foreground: Color.blue, background: Color.blue.opacity(0.15))
                    }
                }
            }
            Spacer()
            if !selecting {
                Menu {
                    Button { selectedTemplateID = template.id } label: {
                        Label(NSLocalizedString("Choisir ce modèle", comment: "Choose template"), systemImage: "checkmark.circle")
                    }
                    Button { editing = template } label: {
                        Label(locked ? NSLocalizedString("Ouvrir", comment: "Open") : NSLocalizedString("Modifier", comment: "Edit"),
                              systemImage: locked ? "eye" : "pencil")
                    }
                    Button {
                        if let copy = store.duplicate(id: template.id) {
                            // La copie a le même rendu que l'original : on réutilise sa miniature
                            // déjà en cache pour que sa tuile n'apparaisse pas sur un spinner.
                            thumbnails.seedThumbnail(from: template, to: copy, label: previewLabel,
                                                     size: size, width: layoutWidth)
                            editing = copy
                        }
                    } label: {
                        Label(NSLocalizedString("Dupliquer", comment: "Duplicate"), systemImage: "plus.square.on.square")
                    }
                    Button { sharing = template } label: {
                        Label(NSLocalizedString("Partager", comment: "Share"), systemImage: "square.and.arrow.up")
                    }
                    if !locked {
                        Button(role: .destructive) { store.delete(id: template.id) } label: {
                            Label(NSLocalizedString("Supprimer", comment: "Delete"), systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if selecting {
                if isChecked { selected.remove(template.id) } else { selected.insert(template.id) }
            } else {
                selectedTemplateID = template.id
            }
        }
    }

    /// Pilule « icône + libellé » serrés (spacing 4), padding et forme identiques pour les
    /// deux badges → des jumelles cohérentes, juste la couleur change.
    private func badge(_ text: String, systemImage: String,
                       foreground: Color, background: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text).lineLimit(1)
        }
        .font(.caption2.bold())
        .foregroundStyle(foreground)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(background, in: Capsule())
    }
}
