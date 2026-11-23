import UIKit
import PocketPrinter5890Kit

/// One native-resolution raster is shared by the preview and BLE print job.
enum LabelRenderer {
    static let width = 384
    static let barcodeModuleDots = 3
    static let quietZoneDots = 30 // 10 modules on each side

    /// Rend un MODÈLE (`LabelTemplate`). Un preset d'usine, ou tout modèle portant un
    /// `baseArrangement`, délègue au rendu historique par `LabelArrangement` (pixel-identique
    /// à l'existant). Un modèle perso (zones libres) passe par le moteur de zones.
    /// `continuousMedia` : support à longueur libre (rouleau continu). L'étiquette prend alors la
    /// hauteur du contenu à la densité du Format, au lieu d'une hauteur imposée. Sans effet sur les
    /// arrangements figés (pensés pour une hauteur donnée).
    static func render(_ label: ProductLabel, template: LabelTemplate, size: LabelSize = .standard,
                       scale: Double = 1, layoutWidth: Int = width,
                       continuousMedia: Bool = false,
                       fixedLayoutHeight: Int? = nil) throws -> MonochromeBitmap {
        if let arrangement = template.baseArrangement {
            return try render(label, size: size, arrangement: arrangement, scale: scale, layoutWidth: layoutWidth)
        }
        // Modèle perso : l'EAN article n'est utilisé que par les cellules « code-barres article ».
        // S'il est invalide, on ne bloque pas tout le rendu (un modèle peut n'avoir qu'un code
        // libre ou aucun code) ; ces cellules basculeront en repli au moment de les peindre.
        let ean = (try? EAN13.completed(label.ean)) ?? ""
        let price = PriceFormatter.formatted(label.price, currency: label.currency) ?? ""
        return try renderLines(label, template: template, ean: ean, price: price,
                               size: size, scale: scale, layoutWidth: layoutWidth,
                               continuousMedia: continuousMedia, fixedLayoutHeight: fixedLayoutHeight)
    }

    /// Hauteur de mise en page (points, base 384 de large) correspondant au RATIO d'une étiquette
    /// prédécoupée de dimensions physiques données. Sert à composer le contenu à la forme réelle de
    /// l'étiquette (sinon un modèle vertical déborderait d'une étiquette horizontale).
    static func fixedLayoutHeight(forLabelWidthMM widthMM: Double, lengthMM: Double,
                                  layoutWidth: Int = width) -> Int? {
        guard widthMM > 0, lengthMM > 0 else { return nil }
        return max(1, Int((Double(layoutWidth) * lengthMM / widthMM).rounded()))
    }

    /// `scale` dessine la même mise en page plus grande, pour une Brother :
    /// le texte est composé à cette résolution, les modules EAN gardent un
    /// nombre entier de points. À 1, c'est exactement le bitmap de la 5890.
    /// `layoutWidth` à 576 choisit les mises en page 80 mm de la NETUM
    /// (`WideLabelLayout`), dessinées à leur taille exacte.
    static func render(_ label: ProductLabel, size: LabelSize = .standard,
                       arrangement: LabelArrangement = .current,
                       scale: Double = 1, layoutWidth: Int = width) throws -> MonochromeBitmap {
        let ean = try EAN13.completed(label.ean)
        guard let price = PriceFormatter.formatted(label.price, currency: label.currency) else { throw LabelError.invalidPrice }
        if layoutWidth == WideLabelLayout.width {
            return try renderWide(label, ean: ean, price: price, layout: .layout(size: size, arrangement: arrangement))
        }
        let geometry = LabelRasterGeometry(layoutHeight: size.heightDots, scale: scale)
        let width = geometry.width
        let height = geometry.height
        var black = try rasterize(width: width, height: height) { context in
            // Coordonnées de mise en page (384 points) mises à l'échelle.
            context.cgContext.scaleBy(x: CGFloat(width) / CGFloat(Self.width),
                                      y: CGFloat(height) / CGFloat(size.heightDots))
            drawComposition(label, ean: ean, price: price, size: size, arrangement: arrangement)
        }
        let modules = try EAN13.modules(for: ean)
        let module = geometry.moduleDots
        let left = geometry.barcodeLeft
        let rows = geometry.rows(barcodeRows(size: size, arrangement: arrangement))
        // Gardes (début/milieu/fin) prolongées À MI-HAUTEUR des chiffres (≈ 9 pt de layout),
        // comme un vrai EAN-13. Les chiffres sont dessinés juste sous les barres par la composition.
        let guardExtraPx = max(1, Int((9.0 * geometry.scale).rounded()))
        let guardBottom = min(height, rows.upperBound + guardExtraPx)
        for (index, on) in modules.enumerated() where on {
            let bottom = EAN13.guardModules.contains(index) ? guardBottom : rows.upperBound
            for y in rows.lowerBound..<bottom {
                for dot in 0..<module {
                    black[y * width + left + index * module + dot] = true
                }
            }
        }
        return try RasterEncoder.encodeBlackPixels(black, width: width, height: height)
    }

    /// Étiquette 80 mm : 576 points, sans mise à l'échelle.
    private static func renderWide(_ label: ProductLabel, ean: String, price: String,
                                   layout: WideLabelLayout) throws -> MonochromeBitmap {
        let width = WideLabelLayout.width
        let height = layout.height
        let reference = String(format: NSLocalizedString("Réf. %@", comment: "Product reference on label"), label.productReference)
        var black = try rasterize(width: width, height: height) { _ in
            for box in layout.boxes {
                let text: String
                switch box.field {
                case .category: text = label.category
                case .shelfReference: text = label.shelfReference
                case .name: text = label.name
                case .reference: text = reference
                case .priceCaption: text = label.priceCaption
                case .price: text = price
                case .eanFirstDigit: text = String(ean.prefix(1))
                case .eanLeftDigits: text = String(ean.dropFirst().prefix(6))
                case .eanRightDigits: text = String(ean.suffix(6))
                }
                let alignment: NSTextAlignment = box.alignment == .left ? .left : box.alignment == .right ? .right : .center
                draw(text, in: CGRect(x: box.x, y: box.y, width: box.width, height: box.height),
                     maxSize: CGFloat(box.fontSize), bold: true, alignment: alignment)
            }
        }
        let modules = try EAN13.modules(for: ean)
        let module = WideLabelLayout.moduleDots
        let rows = layout.barcodeRows
        // Gardes prolongées à mi-hauteur des chiffres (≈ 9 pt, non mis à l'échelle ici).
        let guardBottom = min(height, rows.upperBound + 9)
        for (index, on) in modules.enumerated() where on {
            let bottom = EAN13.guardModules.contains(index) ? guardBottom : rows.upperBound
            for y in rows.lowerBound..<bottom {
                for dot in 0..<module {
                    black[y * width + layout.barcodeLeft + index * module + dot] = true
                }
            }
        }
        return try RasterEncoder.encodeBlackPixels(black, width: width, height: height)
    }

    // MARK: - Moteur de lignes/colonnes (modèles perso)

    /// Rend un modèle perso : une pile de lignes ordonnées (pleine largeur ou deux colonnes),
    /// chaque cellule rendue selon son contenu et son style. Le code-barres est une cellule
    /// normale, redimensionnée pour tenir dans sa cellule (pleine largeur ou demi-colonne).
    /// Le texte est composé en coordonnées de mise en page (384 ou 576 pts) puis mis à l'échelle
    /// comme le chemin historique ; les barres sont peintes sur la grille de pixels finale.
    private static func renderLines(_ label: ProductLabel, template: LabelTemplate, ean: String,
                                    price: String, size: LabelSize, scale: Double,
                                    layoutWidth: Int, continuousMedia: Bool = false,
                                    fixedLayoutHeight: Int? = nil) throws -> MonochromeBitmap {
        let isWide = layoutWidth == WideLabelLayout.width
        let layoutW = isWide ? WideLabelLayout.width : Self.width
        // Le Format (size) règle la DENSITÉ. Trois cas pour la HAUTEUR de l'étiquette :
        //  - continu : la hauteur suit le CONTENU (pas de limite) ;
        //  - prédécoupé (fixedLayoutHeight) : la hauteur est celle de l'étiquette PHYSIQUE (son
        //    ratio), et le contenu doit tenir dedans (sinon il serait coupé) ;
        //  - sinon : la hauteur du Format choisi.
        var (rows, contentHeight) = computeLineRows(template.lines, layoutWidth: layoutW,
                                                    densityHeight: size.heightDots)
        let layoutH: Int
        if continuousMedia {
            layoutH = max(1, contentHeight)
        } else if let fixed = fixedLayoutHeight {
            // Prédécoupé : l'étiquette a une hauteur physique fixe. Si le contenu déborde, on réduit
            // la densité pour qu'il TIENNE (jamais coupé) ; s'il rentre, on garde la densité.
            layoutH = max(1, fixed)
            if contentHeight > layoutH {
                let shrunk = Int(Double(size.heightDots) * Double(layoutH) / Double(contentHeight))
                (rows, contentHeight) = computeLineRows(template.lines, layoutWidth: layoutW,
                                                        densityHeight: max(1, shrunk))
            }
        } else {
            layoutH = size.heightDots
        }

        // Résolution de chaque cellule code, indexée par id de cellule : mode effectif (barres ou
        // QR) et, pour les barres, les chiffres EAN complétés. Un code LIBRE en mode barres n'est
        // encodable que si sa valeur forme un EAN-13 valide ; sinon on bascule en QR (repli).
        var resolved: [UUID: ResolvedCode] = [:]
        for row in rows {
            for placed in row.cells where placed.isBarcode || placed.isQR {
                resolved[placed.cell.id] = resolveCode(placed.cell, label: label, fallbackEAN: ean)
            }
        }

        // Largeur/hauteur finales et échelle layout→pixels.
        let width: Int, height: Int
        let sx: Double, sy: Double
        if isWide {
            width = layoutW; height = layoutH; sx = 1; sy = 1
        } else {
            let geometry = LabelRasterGeometry(layoutHeight: layoutH, scale: scale)
            width = geometry.width; height = geometry.height
            sx = Double(width) / Double(layoutW); sy = Double(height) / Double(layoutH)
        }
        var black = try rasterize(width: width, height: height) { context in
            if !isWide {
                context.cgContext.scaleBy(x: CGFloat(width) / CGFloat(layoutW),
                                          y: CGFloat(height) / CGFloat(layoutH))
            }
            drawLineRows(rows, resolved: resolved, label: label, price: price, layoutWidth: layoutW)
        }
        // Codes de chaque cellule (barres EAN ou QR), convertis en pixels et peints après seuillage.
        for row in rows {
            for placed in row.cells where placed.isBarcode || placed.isQR {
                switch resolved[placed.cell.id] {
                case .qr(let payload):
                    paintQR(&black, payload: payload, width: width, height: height,
                            cellXLayout: placed.x, cellWidthLayout: placed.width,
                            topLayout: placed.barcodeBarsTopLayout, blockHeightLayout: placed.barcodeBarsHeightLayout,
                            sx: sx, sy: sy)
                case .barcode(let symbol):
                    paintBarcode(&black, modules: symbol.modules, guardModules: symbol.guardModules,
                                 width: width, height: height,
                                 cellXLayout: placed.x, cellWidthLayout: placed.width,
                                 topLayout: placed.barcodeBarsTopLayout, barsHeightLayout: placed.barcodeBarsHeightLayout,
                                 sx: sx, sy: sy)
                case .none:
                    break
                }
            }
        }
        return try RasterEncoder.encodeBlackPixels(black, width: width, height: height)
    }

    /// Résolution d'une cellule code : QR (payload) ou barres linéaires. Pour les barres on porte
    /// le `BarcodeSymbol` complet produit par le générateur (modules + gardes + texte déjà ancré).
    private enum ResolvedCode {
        case qr(payload: String)
        case barcode(BarcodeSymbol)
    }

    /// Détermine comment rendre une cellule code. Mode QR → encode la valeur de la cellule
    /// (repli sur l'EAN article). Mode barres → délègue au générateur de la symbologie via
    /// `BarcodeFactory` ; si la valeur n'est pas encodable, repli propre en QR de la valeur saisie.
    private static func resolveCode(_ cell: TemplateCell, label: ProductLabel, fallbackEAN: String) -> ResolvedCode {
        let value = (cell.codePayload(for: label)?.isEmpty == false ? cell.codePayload(for: label)! : fallbackEAN)
        if cell.codeRendering == .qr {
            return .qr(payload: value)
        }
        if let symbol = BarcodeFactory.encode(value, symbology: cell.symbology, options: cell.codeOptions) {
            return .barcode(symbol)
        }
        // Valeur non encodable dans la symbologie : repli propre sur un QR de la valeur saisie.
        return .qr(payload: value)
    }

    /// Une ligne calculée : son `top` et sa hauteur (coordonnées layout) et ses cellules placées.
    private struct LineRow { var top: Int; var height: Int; var cells: [PlacedCell] }
    /// Une cellule placée : rectangle en coordonnées layout + style + repères code/QR.
    /// `isBarcode` = code-barres EAN linéaire ; `isQR` = QR code (CoreImage).
    private struct PlacedCell {
        var cell: TemplateCell
        var x: Int, width: Int
        var isBarcode: Bool
        var isQR: Bool
        var barcodeBarsTopLayout: Int
        var barcodeBarsHeightLayout: Int
    }

    /// Place les lignes verticalement et les cellules horizontalement (coordonnées layout).
    /// `densityHeight` fixe l'échelle de densité (plus grand = plus aéré/gros, via le Format) ;
    /// la hauteur TOTALE réellement occupée est renvoyée à part (`contentHeight`), ce qui permet,
    /// en support continu, de dimensionner l'étiquette sur le contenu plutôt que sur une hauteur
    /// imposée.
    private static func computeLineRows(_ lines: [TemplateLine], layoutWidth: Int,
                                        densityHeight: Int) -> (rows: [LineRow], contentHeight: Int) {
        let heightScale = Double(densityHeight) / 208.0
        let margin = 12
        var rows: [LineRow] = []
        var cursor = Int(6 * heightScale)
        // Largeur de cellule (layout) selon le nombre de colonnes et l'option pleine largeur.
        // La pleine largeur ne concerne QUE les codes-barres LINÉAIRES : un QR est carré, l'étirer
        // à la pleine largeur le rendrait démesuré et masquerait les lignes suivantes.
        func cellLayoutWidth(line: TemplateLine, cell: TemplateCell) -> Int {
            let count = line.cells.count
            let isLinear = cell.content.isBarcode && !cell.rendersAsQR
            if isLinear && cell.codeOptions.fullWidth { return layoutWidth - 2 * margin }
            return count > 1 ? (layoutWidth - 2 * margin) / 2 - 6 : layoutWidth - 2 * margin
        }
        for line in lines {
            // Hauteur de ligne = plus grande bande de ses cellules. Pour une cellule CODE, la
            // taille (XXS→XL) pilote la dimension. Un QR est CARRÉ : la ligne doit réserver son
            // CÔTÉ entier (borné à la largeur de cellule), sinon le QR déborde sur la ligne suivante
            // et masque son contenu (le « champ sous le QR » qui disparaissait).
            let bandBase = line.cells.map { cell -> Int in
                if cell.rendersAsQR {
                    let want = Int(Double(cell.style.size.codeBandHeight) * 1.35)
                    // Le QR ne peut pas être plus large que sa cellule : son côté est borné à elle.
                    return min(want, cellLayoutWidth(line: line, cell: cell))
                }
                return cell.content.isBarcode ? cell.style.size.codeBandHeight : cell.style.size.bandHeight
            }.max() ?? 27
            let rowHeight = Int(Double(bandBase) * heightScale)
            var placed: [PlacedCell] = []
            let count = line.cells.count
            for (index, cell) in line.cells.enumerated() {
                let isQR = cell.rendersAsQR
                let isBar = cell.content.isBarcode && !isQR
                // Option « pleine largeur » : réservée aux codes-barres LINÉAIRES (gagner en
                // largeur = en fiabilité). Un QR carré n'est jamais étiré à la pleine largeur.
                let fullWidth = isBar && cell.codeOptions.fullWidth
                let colWidth: Int
                let x: Int
                if fullWidth {
                    colWidth = layoutWidth - 2 * margin
                    x = margin
                } else {
                    colWidth = count > 1 ? (layoutWidth - 2 * margin) / 2 - 6 : layoutWidth - 2 * margin
                    x = count > 1 && index == 1 ? layoutWidth - margin - colWidth : margin
                }
                // Bloc code en haut de la cellule. Pour un code-barres, on RÉSERVE explicitement la
                // place des chiffres sous les barres (texte ~18 pt + marge des gardes ~9 pt, mis à
                // l'échelle) : les barres prennent le reste de la ligne. Ainsi les chiffres sont
                // toujours visibles, jamais coupés ni débordant sur la ligne suivante. Le QR, lui,
                // n'a pas de texte et occupe presque toute la hauteur.
                let topInset = Int(2 * heightScale)
                let textReserve = Int(27 * heightScale)   // 18 (texte) + 9 (marge gardes)
                let blockHeight: Int
                if isQR {
                    blockHeight = Int(Double(rowHeight) * 0.92)
                } else if isBar {
                    blockHeight = max(1, rowHeight - topInset - textReserve)
                } else {
                    blockHeight = 0
                }
                placed.append(PlacedCell(cell: cell, x: x, width: colWidth, isBarcode: isBar, isQR: isQR,
                                         barcodeBarsTopLayout: cursor + topInset,
                                         barcodeBarsHeightLayout: blockHeight))
            }
            rows.append(LineRow(top: cursor, height: rowHeight, cells: placed))
            cursor += rowHeight
        }
        // Marge basse symétrique à la marge haute (6 pt mis à l'échelle).
        let contentHeight = cursor + Int(6 * heightScale)
        return (rows, contentHeight)
    }

    /// Dessine le texte de toutes les cellules (les codes — barres ou QR — sont peints après
    /// seuillage ; seuls les chiffres sous un code-barres sont du texte dessiné ici).
    private static func drawLineRows(_ rows: [LineRow], resolved: [UUID: ResolvedCode],
                                     label: ProductLabel, price: String, layoutWidth: Int) {
        for row in rows {
            for placed in row.cells {
                if placed.isBarcode || placed.isQR {
                    // Texte lisible d'un code-barres (un QR, choisi ou en repli, n'en affiche pas).
                    if case .barcode(let symbol) = resolved[placed.cell.id] {
                        drawBarcodeText(symbol, x: placed.x, width: placed.width,
                                        barsTop: placed.barcodeBarsTopLayout,
                                        barsHeight: placed.barcodeBarsHeightLayout)
                    }
                    continue
                }
                guard let text = placed.cell.decoratedText(for: label, formattedPrice: price) else { continue }
                let style = placed.cell.style
                let alignment: NSTextAlignment = style.alignH == .leading ? .left : style.alignH == .trailing ? .right : .center
                // Alignement vertical : décale le rectangle de texte dans la bande.
                let fontBand = min(CGFloat(row.height), CGFloat(style.size.bandHeight))
                let dy: CGFloat
                switch style.alignV {
                case .top: dy = 0
                case .center: dy = (CGFloat(row.height) - fontBand) / 2
                case .bottom: dy = CGFloat(row.height) - fontBand
                }
                draw(text, in: CGRect(x: CGFloat(placed.x), y: CGFloat(row.top) + dy,
                                      width: CGFloat(placed.width), height: fontBand),
                     maxSize: CGFloat(style.size.fontSize), bold: style.bold, italic: style.italic,
                     alignment: alignment)
            }
        }
    }

    /// Dessine le texte lisible d'un code-barres à partir des `textGroups` produits par le
    /// générateur : chaque groupe sait déjà où il va (sous une plage de modules, ou déporté à
    /// gauche/droite d'un module). On convertit ces ancres en positions avec EXACTEMENT la même
    /// géométrie que `paintBarcode` : module entier maximisé, code centré dans la cellule. Les
    /// chiffres tombent donc pile sous leurs barres, quelle que soit la largeur — fidèle EBP.
    /// Le texte est TOUJOURS sous les barres (convention universelle des codes-barres).
    private static func drawBarcodeText(_ symbol: BarcodeSymbol, x: Int, width: Int,
                                        barsTop: Int, barsHeight: Int) {
        guard !symbol.textGroups.isEmpty else { return }
        let textY = CGFloat(barsTop + barsHeight) + 9   // sous la pointe des gardes allongées
        let x0 = CGFloat(x)
        let w = CGFloat(width)

        // Géométrie identique à paintBarcode : module entier maximisé, code centré.
        let minQuiet = 10
        let moduleCount = symbol.modules.count
        let modulePx = CGFloat(max(1, Int(w) / (moduleCount + 2 * minQuiet)))
        let barcodePx = CGFloat(moduleCount) * modulePx
        let barsLeft = x0 + (w - barcodePx) / 2
        let digitW = 7 * modulePx   // largeur réservée à un chiffre déporté

        for group in symbol.textGroups {
            let rect: CGRect
            let align: NSTextAlignment
            switch group.anchor {
            case .under(let range):
                let left = barsLeft + CGFloat(range.lowerBound) * modulePx
                let wd = CGFloat(range.count) * modulePx
                rect = CGRect(x: left, y: textY, width: wd, height: 18)
                align = .center
            case .leftOf(let module):
                let anchorX = barsLeft + CGFloat(module) * modulePx
                rect = CGRect(x: anchorX - digitW - modulePx, y: textY, width: digitW, height: 18)
                align = .center
            case .rightOf(let module):
                let anchorX = barsLeft + CGFloat(module + 1) * modulePx
                rect = CGRect(x: anchorX + modulePx, y: textY, width: digitW, height: 18)
                align = .left
            }
            draw(group.text, in: rect, maxSize: 12, bold: true, alignment: align)
        }
    }

    /// Peint les barres d'un code-barres linéaire : code centré DANS la cellule, module entier le
    /// plus grand qui tient (zones de garde comprises), converti en pixels via (sx, sy).
    /// `guardModules` = index des barres à prolonger sous la ligne de données (gardes EAN/UPC) ;
    /// vide pour Code 128/39, qui n'ont pas de gardes allongées.
    private static func paintBarcode(_ black: inout [Bool], modules: [Bool], guardModules: Set<Int>,
                                     width: Int, height: Int,
                                     cellXLayout: Int, cellWidthLayout: Int,
                                     topLayout: Int, barsHeightLayout: Int, sx: Double, sy: Double) {
        guard barsHeightLayout > 0 else { return }
        let cellWidthPx = Int(Double(cellWidthLayout) * sx)
        // Quiet zone minimale (modules) requise de chaque côté : 10 est la cible normative.
        // On MAXIMISE la largeur du module : on prend le plus grand pas entier tel que le code +
        // 2×quiet tienne dans la cellule. Sans ça, l'arrondi entier gaspillait presque la moitié de
        // la largeur (ex. Code 39 à 1 px/module au lieu de 2), d'où un code petit entouré de blanc.
        let minQuiet = 10
        let modulePx = max(1, cellWidthPx / (modules.count + 2 * minQuiet))
        let barcodePx = modules.count * modulePx
        let cellLeftPx = Int(Double(cellXLayout) * sx)
        // La place restante est répartie en marge de chaque côté : la quiet zone réelle est donc
        // ≥ minQuiet modules, et le code est centré.
        let left = cellLeftPx + (cellWidthPx - barcodePx) / 2
        let topPx = Int(Double(topLayout) * sy)
        let barsPx = max(1, Int(Double(barsHeightLayout) * sy))
        let dataBottom = min(height, topPx + barsPx)
        // Gardes prolongées à mi-hauteur des chiffres (≈ 9 pt de layout convertis en pixels).
        let guardBottom = min(height, dataBottom + max(1, Int((9.0 * sy).rounded())))
        for (index, on) in modules.enumerated() where on {
            let bottom = guardModules.contains(index) ? guardBottom : dataBottom
            for y in topPx..<bottom {
                for dot in 0..<modulePx {
                    let px = left + index * modulePx + dot
                    if px >= 0 && px < width { black[y * width + px] = true }
                }
            }
        }
    }

    /// Peint un QR code dans une cellule : grille carrée de modules centrée dans la cellule, le
    /// plus grand module ENTIER qui tient dans le bloc (largeur de cellule × hauteur de bloc).
    /// Monochrome, peint directement sur la grille de pixels finale, comme les barres EAN.
    private static func paintQR(_ black: inout [Bool], payload: String, width: Int, height: Int,
                                cellXLayout: Int, cellWidthLayout: Int,
                                topLayout: Int, blockHeightLayout: Int, sx: Double, sy: Double) {
        guard blockHeightLayout > 0 else { return }
        let grid = QRCode.modules(for: payload)
        let n = grid.count
        guard n > 0 else { return }

        // Espace disponible en pixels. Le QR est carré : sa taille est limitée par la plus petite
        // de DEUX dimensions — la largeur de cellule et la hauteur de SON BLOC (sa ligne). Le bloc
        // est déjà calculé pour tenir dans la ligne, donc le QR ne déborde ni de l'étiquette ni sur
        // la ligne suivante. (On NE le borne PAS à toute la place restante jusqu'au bas : sinon il
        // écraserait les lignes situées après lui, comme la référence sous le code.)
        let topPx = Int(Double(topLayout) * sy)
        let cellWidthPx = Int(Double(cellWidthLayout) * sx)
        let blockHeightPx = max(1, Int(Double(blockHeightLayout) * sy))
        let available = min(cellWidthPx, blockHeightPx)
        let modulePx = max(1, available / n)
        let qrPx = modulePx * n

        // Centré horizontalement dans la cellule, calé en haut du bloc (comme les barres).
        let cellLeftPx = Int(Double(cellXLayout) * sx)
        let left = cellLeftPx + (cellWidthPx - qrPx) / 2

        for (ry, rowModules) in grid.enumerated() {
            for (rx, on) in rowModules.enumerated() where on {
                for dy in 0..<modulePx {
                    let py = topPx + ry * modulePx + dy
                    guard py >= 0, py < height else { continue }
                    for dx in 0..<modulePx {
                        let px = left + rx * modulePx + dx
                        if px >= 0 && px < width { black[py * width + px] = true }
                    }
                }
            }
        }
    }

    /// Dessine sur fond blanc puis seuille chaque point en noir ou blanc.
    private static func rasterize(width: Int, height: Int,
                                  _ drawing: (UIGraphicsImageRendererContext) -> Void) throws -> [Bool] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            drawing(context)
        }
        guard let cgImage = image.cgImage else { throw LabelError.rasterFailure }
        // Read through a known RGBA layout; no resizing or interpolation.
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let bitmapContext = CGContext(data: &rgba, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: width * 4, space: colorSpace,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw LabelError.rasterFailure }
        bitmapContext.interpolationQuality = .none
        bitmapContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var black = [Bool](repeating: false, count: width * height)
        for i in black.indices {
            let p = i * 4
            // Hard threshold keeps the printed output strictly black or white.
            black[i] = (Int(rgba[p]) * 299 + Int(rgba[p + 1]) * 587 + Int(rgba[p + 2]) * 114) < 160_000
        }
        return black
    }

    /// Image en niveaux de gris (noir ou blanc seulement) pour le SDK Brother.
    /// Aucune interpolation : le SDK reçoit les points tels quels.
    static func grayImage(_ bitmap: MonochromeBitmap) throws -> CGImage {
        let gray = try PackedBitmap.grayscale(bitmap.bytes, width: bitmap.width, height: bitmap.height)
        guard let provider = CGDataProvider(data: Data(gray) as CFData),
              let image = CGImage(width: bitmap.width, height: bitmap.height, bitsPerComponent: 8,
                                  bitsPerPixel: 8, bytesPerRow: bitmap.width,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { throw LabelError.rasterFailure }
        return image
    }

    private static func barcodeRows(size: LabelSize, arrangement: LabelArrangement) -> Range<Int> {
        if arrangement == .current {
            switch size {
            case .compact: return 70..<120
            case .standard: return 84..<154
            case .airy: return 103..<195
            case .large: return 139..<267
            }
        }
        let pair: (Int, Int)
        switch arrangement {
        case .priceFirst: pair = (104, 153)
        case .columns: pair = (111, 160)
        case .barcodeFirst: pair = (48, 105)
        case .centered: pair = (81, 127)
        case .barcodeLast: pair = (137, 183)
        case .current: fatalError("Handled above")
        }
        let factor = Double(size.heightDots) / 208.0
        return Int((Double(pair.0) * factor).rounded())..<Int((Double(pair.1) * factor).rounded())
    }

    private static func drawComposition(_ label: ProductLabel, ean: String, price: String,
                                        size: LabelSize, arrangement: LabelArrangement) {
        if arrangement == .current {
            drawCurrent(label, ean: ean, price: price, size: size)
            return
        }
        let scale = CGFloat(size.heightDots) / 208
        let fontScale = min(1 + CGFloat(size.heightDots - 208) / 600, 1.35)
        func put(_ value: String, _ x: CGFloat, _ top: CGFloat, _ width: CGFloat,
                 _ band: CGFloat, _ font: CGFloat, _ alignment: NSTextAlignment = .left) {
            draw(value, in: CGRect(x: x, y: (top * scale).rounded(), width: width,
                                   height: (band * scale).rounded()),
                 maxSize: (font * fontScale).rounded(), bold: true, alignment: alignment)
        }
        func digits(_ top: CGFloat) {
            put(String(ean.prefix(1)), 18, top, 30, 18, 12, .center)
            put(String(ean.dropFirst().prefix(6)), 55, top, 140, 18, 12, .center)
            put(String(ean.suffix(6)), 205, top, 140, 18, 12, .center)
        }
        let reference = String(format: NSLocalizedString("Réf. %@", comment: "Product reference on label"), label.productReference)
        switch arrangement {
        case .priceFirst:
            put(label.category, 12, 7, 205, 16, 12)
            put(label.shelfReference, 12, 24, 210, 16, 11)
            put(price, 225, 7, 147, 40, 34, .right)
            put(label.priceCaption, 221, 49, 151, 18, 13, .right)
            put(label.name, 12, 69, 360, 29, 26)
            digits(155)
            put(reference, 12, 182, 360, 19, 14, .center)
        case .columns:
            put(label.category, 12, 7, 360, 17, 12)
            put(label.shelfReference, 12, 25, 360, 17, 11)
            put(label.name, 12, 54, 195, 42, 23)
            put(price, 220, 48, 152, 40, 34, .right)
            put(label.priceCaption, 215, 89, 157, 17, 12, .right)
            digits(162)
            put(reference, 12, 187, 360, 18, 14, .center)
        case .barcodeFirst:
            put(label.category, 12, 6, 360, 16, 12)
            put(label.shelfReference, 12, 23, 360, 16, 11)
            digits(107)
            put(label.name, 12, 135, 360, 30, 26)
            put(reference, 12, 167, 205, 17, 13)
            put(label.priceCaption, 12, 187, 205, 17, 13)
            put(price, 225, 173, 147, 33, 31, .right)
        case .centered:
            put(label.category, 12, 6, 360, 17, 12, .center)
            put(label.shelfReference, 12, 25, 360, 16, 11, .center)
            put(label.name, 12, 48, 360, 29, 27, .center)
            digits(129)
            put(reference, 12, 149, 360, 17, 13, .center)
            put(label.priceCaption, 12, 166, 360, 17, 13, .center)
            put(price, 12, 183, 360, 24, 26, .center)
        case .barcodeLast:
            put(label.category, 12, 7, 360, 17, 12)
            put(label.name, 12, 26, 360, 30, 27)
            put(label.shelfReference, 12, 60, 360, 17, 11)
            put(label.priceCaption, 12, 84, 205, 17, 14)
            put(price, 221, 75, 151, 41, 35, .right)
            put(reference, 12, 111, 360, 18, 13, .center)
            digits(186)
        case .current: break
        }
    }

    private static func drawCurrent(_ label: ProductLabel, ean: String, price: String, size: LabelSize) {
        let values: (Int, Int, Int, Int, Int, Int, Int, Int, Int, Int, Int, Int)
        switch size {
        case .compact: values = (6, 12, 22, 11, 39, 25, 123, 13, 145, 178, 166, 31)
        case .standard: values = (7, 13, 26, 12, 44, 28, 156, 16, 178, 208, 194, 37)
        case .airy: values = (10, 16, 34, 14, 58, 32, 199, 17, 228, 274, 257, 43)
        case .large: values = (14, 18, 43, 16, 75, 38, 274, 18, 310, 369, 346, 47)
        }
        let v = values
        draw(label.category, in: CGRect(x: 12, y: v.0, width: 360, height: 22), maxSize: CGFloat(v.1), bold: true, alignment: .left)
        draw(label.shelfReference, in: CGRect(x: 12, y: v.2, width: 360, height: 22), maxSize: CGFloat(v.3), bold: true, alignment: .left)
        draw(label.name, in: CGRect(x: 12, y: v.4, width: 360, height: 44), maxSize: CGFloat(v.5), bold: true, alignment: .left)
        draw(String(ean.prefix(1)), in: CGRect(x: 22, y: v.6, width: 27, height: 20), maxSize: CGFloat(v.7), bold: true)
        draw(String(ean.dropFirst().prefix(6)), in: CGRect(x: 58, y: v.6, width: 135, height: 20), maxSize: CGFloat(v.7), bold: true)
        draw(String(ean.suffix(6)), in: CGRect(x: 208, y: v.6, width: 135, height: 20), maxSize: CGFloat(v.7), bold: true)
        draw(String(format: NSLocalizedString("Réf. %@", comment: "Product reference on label"), label.productReference), in: CGRect(x: 12, y: v.8, width: 360, height: 25), maxSize: size == .compact ? 12 : size == .standard ? 14 : size == .airy ? 17 : 19, bold: true)
        draw(label.priceCaption, in: CGRect(x: 12, y: v.9, width: 215, height: 27), maxSize: size == .compact ? 15 : size == .standard ? 19 : size == .airy ? 21 : 22, bold: true, alignment: .left)
        draw(price, in: CGRect(x: 223, y: v.10, width: 149, height: 50), maxSize: CGFloat(v.11), bold: true, alignment: .right)
    }

    static func preview(_ bitmap: MonochromeBitmap) -> UIImage? {
        var rgba = [UInt8](repeating: 255, count: bitmap.width * bitmap.height * 4)
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width {
                let byte = bitmap.bytes[y * bitmap.widthBytes + x / 8]
                let black = byte & UInt8(0x80 >> (x % 8)) != 0
                let offset = (y * bitmap.width + x) * 4
                let value: UInt8 = black ? 0 : 255
                rgba[offset] = value; rgba[offset + 1] = value; rgba[offset + 2] = value
            }
        }
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        guard let image = CGImage(width: bitmap.width, height: bitmap.height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: bitmap.width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: image)
    }

    private static func draw(_ text: String, in rect: CGRect, maxSize: CGFloat, bold: Bool,
                             italic: Bool = false, alignment: NSTextAlignment = .center) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        func font(_ size: CGFloat) -> UIFont {
            var f = bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size)
            if italic, let descriptor = f.fontDescriptor.withSymbolicTraits(bold ? [.traitItalic, .traitBold] : .traitItalic) {
                f = UIFont(descriptor: descriptor, size: size)
            }
            return f
        }
        var size = maxSize
        while size > 10 {
            if (text as NSString).size(withAttributes: [.font: font(size)]).width <= rect.width { break }
            size -= 1
        }
        (text as NSString).draw(in: rect, withAttributes: [.font: font(size), .foregroundColor: UIColor.black, .paragraphStyle: paragraph])
    }
}

enum LabelError: LocalizedError {
    case invalidPrice, rasterFailure
    var errorDescription: String? {
        switch self {
        case .invalidPrice: return NSLocalizedString("Prix invalide", comment: "Invalid price error")
        case .rasterFailure: return NSLocalizedString("Impossible de créer le bitmap", comment: "Rasterization error")
        }
    }
}
