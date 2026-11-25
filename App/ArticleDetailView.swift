import SwiftUI
import UIKit

/// Fiche d'un article EBP, en deux onglets au niveau de l'article :
///  - **Produit** : les infos récupérées (lecture seule), TTC en gros + HT en petit (écran only).
///  - **Impression** : l'écran d'impression soigné (carte imprimante, présentation graphique,
///    aperçu live, quantité, bouton Imprimer) — fourni par `ContentView`, qui possède tout le
///    moteur d'impression et les feuilles associées.
struct ArticleDetailView<Impression: View, Sheets: View>: View {
    let product: MappedProduct
    /// Contenu de l'onglet Impression, construit par l'hôte (ContentView).
    @ViewBuilder let impression: () -> Impression
    /// Modales de l'onglet (imprimante, présentation) attachées sur la vue présentée.
    @ViewBuilder let sheets: () -> Sheets

    @State private var tab = 0

    private var label: ProductLabel { product.label }

    var body: some View {
        Group {
            if tab == 0 { productTab } else { impression() }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            // Sélecteur d'onglet épinglé en haut, hors du Form : laisse le Form (onglet Produit)
            // gérer sa propre hauteur de scroll, sans étirement de sa première section.
            Picker("", selection: $tab) {
                Text(NSLocalizedString("Produit", comment: "Product tab")).tag(0)
                    .accessibilityIdentifier("onglet-produit")
                Text(NSLocalizedString("Impression", comment: "Printing tab")).tag(1)
                    .accessibilityIdentifier("onglet-impression")
            }
            .pickerStyle(.segmented)
            .padding()
            .background(.bar)
        }
        .navigationTitle(label.name.isEmpty ? NSLocalizedString("Article", comment: "Article") : label.name)
        .navigationBarTitleDisplayMode(.inline)
        .background(sheets())   // porte les .sheet de l'onglet Impression (présentées depuis cette vue)
    }

    // MARK: - Onglet Produit (lecture seule)

    private var productTab: some View {
        Form {
            Section(NSLocalizedString("Produit", comment: "Product")) {
                copyableRow(NSLocalizedString("Libellé", comment: "Name"),
                            value: label.name.isEmpty ? "—" : label.name,
                            copyValue: label.name)
                if !label.productReference.isEmpty {
                    copyableRow(NSLocalizedString("Référence", comment: "Reference"), value: label.productReference)
                }
                if !label.shelfReference.isEmpty {
                    copyableRow(NSLocalizedString("Rayon", comment: "Shelf"), value: label.shelfReference)
                }
                if !label.category.isEmpty {
                    copyableRow(NSLocalizedString("Famille", comment: "Family"), value: label.category)
                }
                eanRow
            }

            Section(NSLocalizedString("Prix", comment: "Price")) {
                LabeledContent {
                    Text(label.price.isEmpty ? "—" : "\(label.price) \(label.currency.symbol)")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)
                } label: { Text("TTC").font(.body) }
                .copyOnLongPress(label.price)
                if let ht = product.priceExclVat {
                    LabeledContent {
                        Text("\(ht) \(label.currency.symbol)")
                            .font(.body.weight(.medium)).foregroundStyle(.primary)
                    } label: { Text("HT").font(.body) }
                    .copyOnLongPress(ht)
                }
                if let vat = product.details.vatAmount {
                    LabeledContent {
                        Text("\(vat) \(label.currency.symbol)")
                            .font(.body.weight(.medium)).foregroundStyle(.primary)
                    } label: { Text(vatLabel).font(.body) }
                    .copyOnLongPress(vat)
                } else if let rate = product.details.vatRatePercent {
                    LabeledContent {
                        Text("\(rate) %").font(.body.weight(.medium)).foregroundStyle(.primary)
                    } label: { Text(NSLocalizedString("TVA", comment: "VAT")).font(.body) }
                    .copyOnLongPress(rate)
                }
            }

            stockSection
            logisticsSection
            managementSection
        }
    }

    /// Ligne lecture seule dont la valeur se copie par appui long (menu contextuel iOS).
    /// `copyValue` permet de copier une valeur différente de celle affichée (ex. libellé réel
    /// plutôt que « — » quand il est vide) ; par défaut on copie la valeur affichée.
    @ViewBuilder
    private func copyableRow(_ title: String, value: String, copyValue: String? = nil) -> some View {
        LabeledContent(title, value: value)
            .copyOnLongPress(copyValue ?? value)
    }

    /// Libellé « TVA » avec le taux entre parenthèses quand il est connu (ex. « TVA (20 %) »).
    private var vatLabel: String {
        if let rate = product.details.vatRatePercent {
            return String(format: NSLocalizedString("TVA (%@ %%)", comment: "VAT with rate"), rate)
        }
        return NSLocalizedString("TVA", comment: "VAT")
    }

    @ViewBuilder
    private var stockSection: some View {
        let d = product.details
        if d.realStock != nil || d.virtualStock != nil {
            Section(NSLocalizedString("Stock", comment: "Stock")) {
                if let real = d.realStock {
                    copyableRow(NSLocalizedString("Stock réel", comment: "Real stock"), value: real)
                }
                if let virtual = d.virtualStock {
                    copyableRow(NSLocalizedString("Stock disponible", comment: "Available stock"), value: virtual)
                }
            }
        }
    }

    @ViewBuilder
    private var logisticsSection: some View {
        let d = product.details
        if d.unitId != nil || d.weight != nil || d.volume != nil {
            Section(NSLocalizedString("Logistique", comment: "Logistics")) {
                if let unit = d.unitId {
                    copyableRow(NSLocalizedString("Unité de vente", comment: "Sale unit"), value: unit)
                }
                if let weight = d.weight {
                    copyableRow(NSLocalizedString("Poids", comment: "Weight"), value: weight)
                }
                if let volume = d.volume {
                    copyableRow(NSLocalizedString("Volume", comment: "Volume"), value: volume)
                }
            }
        }
    }

    @ViewBuilder
    private var managementSection: some View {
        let d = product.details
        if d.supplierId != nil || d.subFamilyId != nil || d.isActive != nil {
            Section(NSLocalizedString("Gestion", comment: "Management")) {
                if let supplier = d.supplierId {
                    copyableRow(NSLocalizedString("Fournisseur", comment: "Supplier"), value: supplier)
                }
                if let subFamily = d.subFamilyId {
                    copyableRow(NSLocalizedString("Sous-famille", comment: "Sub-family"), value: subFamily)
                }
                if let active = d.isActive {
                    LabeledContent(NSLocalizedString("État", comment: "State")) {
                        Label(active ? NSLocalizedString("Actif", comment: "Active")
                                     : NSLocalizedString("Inactif", comment: "Inactive"),
                              systemImage: active ? "checkmark.circle.fill" : "pause.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(active ? .green : .secondary)
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var eanRow: some View {
        if !label.ean.isEmpty {
            LabeledContent {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(label.ean).font(.body.monospaced())
                    if product.eanWasInvalid {
                        Label(NSLocalizedString("Code-barres non valide", comment: "Invalid barcode"),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
            } label: { Text(NSLocalizedString("Code-barres", comment: "Barcode")) }
            .copyOnLongPress(label.ean)
        }
    }
}

// MARK: - Copier par appui long

private extension View {
    /// Rend une ligne copiable par appui long : menu contextuel iOS avec « Copier »,
    /// qui place `value` dans le presse-papiers et déclenche un retour haptique léger.
    /// N'attache rien si `value` est vide (rien d'utile à copier).
    @ViewBuilder
    func copyOnLongPress(_ value: String) -> some View {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self
        } else {
            self.contextMenu {
                Button {
                    UIPasteboard.general.string = value
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Label(NSLocalizedString("Copier", comment: "Copy value"), systemImage: "doc.on.doc")
                }
            }
        }
    }
}
