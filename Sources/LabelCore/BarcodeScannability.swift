import Foundation

/// Évalue si un code-barres LINÉAIRE rastérisé sortira assez net pour être lu par une douchette.
///
/// Le point qui décide de la lecture n'est PAS la génération des modules (ils sont toujours
/// corrects) mais la rastérisation : sur une tête thermique à ~203 dpi, chaque module doit faire
/// un nombre ENTIER de pixels, et ce nombre doit être assez grand. À 1 pixel/module un EAN-13 est
/// à la limite basse et échoue souvent ; à partir de 2 pixels/module il passe de façon fiable.
/// (Repère : Google ML Kit recommande des barres d'au moins 2 px et une largeur totale ≥ 190 px
/// pour un EAN-13 de 95 modules.)
///
/// Cette évaluation est PURE (aucune dépendance UIKit/CoreImage) : elle reçoit la largeur et la
/// hauteur disponibles de la cellule EN PIXELS d'impression et la symbologie, et dit si le code
/// tiendra au seuil fiable. L'éditeur s'en sert pour alerter quand une cellule est trop étroite.
public enum BarcodeScannability {
    /// Quiet zone de chaque côté, en modules (identique au moteur de rendu : 10 + 10).
    public static let quietZoneModules = 10
    /// Pixels par module au-dessus desquels la lecture est fiable. En dessous (1 px), risquée.
    public static let reliableModulePx = 2
    /// Hauteur de barres minimale conseillée, en pixels (~2,5 mm à 203 dpi).
    public static let minBarsHeightPx = 20

    /// Niveau de confiance de lecture d'un code rastérisé.
    public enum Level: Equatable {
        case reliable    // module ≥ 2 px et hauteur suffisante : passe de façon fiable
        case risky       // module = 1 px, ou barres trop courtes : peut échouer selon la douchette
        case unreadable  // largeur insuffisante pour poser ne serait-ce qu'un module + quiet zones
    }

    /// Résultat d'évaluation : niveau + valeurs mesurées, pour afficher un message utile.
    public struct Assessment: Equatable {
        public let level: Level
        public let modulePx: Int      // pixels par module effectivement obtenus
        public let barsHeightPx: Int  // hauteur de barres en pixels
        public let moduleCount: Int   // nombre de modules de la symbologie (longueur du code)
        public init(level: Level, modulePx: Int, barsHeightPx: Int, moduleCount: Int) {
            self.level = level
            self.modulePx = modulePx
            self.barsHeightPx = barsHeightPx
            self.moduleCount = moduleCount
        }
    }

    /// Évalue un code de `moduleCount` modules dans une cellule de `cellWidthPx` × hauteur de
    /// barres `barsHeightPx` (pixels d'impression). `moduleCount` nil ⇒ longueur typique de la
    /// symbologie (utile avant de connaître la valeur exacte).
    public static func assess(cellWidthPx: Int, barsHeightPx: Int,
                              symbology: BarcodeSymbology, moduleCount: Int? = nil) -> Assessment {
        let count = moduleCount ?? typicalModuleCount(for: symbology)
        let totalModules = count + 2 * quietZoneModules
        // Même calcul entier que paintBarcode : le module est tronqué (floor), min 1.
        let modulePx = max(0, cellWidthPx / totalModules)
        let level: Level
        if modulePx < 1 {
            level = .unreadable
        } else if modulePx < reliableModulePx || barsHeightPx < minBarsHeightPx {
            level = .risky
        } else {
            level = .reliable
        }
        return Assessment(level: level, modulePx: max(0, modulePx),
                          barsHeightPx: barsHeightPx, moduleCount: count)
    }

    /// Largeur de cellule minimale (pixels) pour atteindre le seuil fiable avec cette symbologie.
    public static func minCellWidthPx(for symbology: BarcodeSymbology, moduleCount: Int? = nil) -> Int {
        let count = moduleCount ?? typicalModuleCount(for: symbology)
        return (count + 2 * quietZoneModules) * reliableModulePx
    }

    /// Nombre de modules typique d'une symbologie, pour une estimation avant la valeur réelle.
    /// EAN-13 : 95 ; EAN-8 : 67 ; UPC-A : 95 (EAN-13 préfixé 0). Code 128/39 varient avec la
    /// longueur : on prend une estimation prudente pour ~13 caractères.
    public static func typicalModuleCount(for symbology: BarcodeSymbology) -> Int {
        switch symbology {
        case .ean13, .upca: return 95
        case .ean8: return 67
        case .code128: return 180   // ~11 modules/caractère, ~13 car. + start/stop/checksum
        case .code39: return 170    // 16 modules/caractère (ratio 2:1) × ~13 car. + encadrements
        }
    }
}
