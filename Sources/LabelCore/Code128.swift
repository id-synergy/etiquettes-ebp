import Foundation
import CoreImage

/// Encodeur Code 128 via CoreImage (`CICode128BarcodeGenerator`), lu sous forme de MODULES
/// linéaires (true = barre noire), comme EAN-13/EAN-8/Code 39 et le QR. On évite ainsi de
/// maintenir à la main les 107 motifs et la checksum modulo 103 du Code 128 : CoreImage encode,
/// on relit la colonne de pixels produite.
///
/// CoreImage ajoute une quiet zone (`inputQuietSpace`, min imposé) autour du code. On la met au
/// minimum et on la retire ensuite en rognant les modules blancs de bord : le moteur de rendu
/// ajoute déjà sa propre marge, comme pour les autres symbologies.
public enum Code128 {
    public static func isEncodable(_ value: String) -> Bool {
        // Code 128 (jeux A/B/C) couvre l'ASCII imprimable 0–127. On reste conservateur.
        return !value.isEmpty && value.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value < 128 }
    }

    /// Modules du code (true = barre noire), quiet zone de bord retirée. `nil` si non encodable
    /// ou si CoreImage échoue.
    public static func modules(for value: String) -> [Bool]? {
        guard isEncodable(value), let data = value.data(using: .ascii),
              let filter = CIFilter(name: "CICode128BarcodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        // Quiet space minimal accepté par le générateur (le moteur ajoute sa marge ensuite).
        filter.setValue(1.0, forKey: "inputQuietSpace")
        guard let output = filter.outputImage else { return nil }

        let extent = output.extent
        let width = Int(extent.width.rounded())
        let height = Int(extent.height.rounded())
        guard width > 0, height > 0 else { return nil }

        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let cgImage = context.createCGImage(output, from: extent) else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let bitmap = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: width * 4, space: colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        bitmap.interpolationQuality = .none
        bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Une seule rangée suffit (code linéaire : colonnes identiques). On lit la rangée du milieu.
        let midRow = height / 2
        var row = [Bool](repeating: false, count: width)
        for x in 0..<width {
            let p = (midRow * width + x) * 4
            let luma = Int(pixels[p]) * 299 + Int(pixels[p + 1]) * 587 + Int(pixels[p + 2]) * 114
            row[x] = luma < 160_000
        }

        // Retire la quiet zone : modules blancs en tête et en queue.
        guard let first = row.firstIndex(of: true), let last = row.lastIndex(of: true) else { return nil }
        return Array(row[first...last])
    }
}
