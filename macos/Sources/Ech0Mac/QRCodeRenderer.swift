import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

enum QRCodeRenderer {
    private static let context = CIContext()

    static func makeImage(from string: String, size: CGFloat = 220) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else {
            return nil
        }

        let scale = size / outputImage.extent.width
        let transformed = outputImage.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )

        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }
}

