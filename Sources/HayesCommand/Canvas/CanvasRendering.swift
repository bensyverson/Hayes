import CoreGraphics
import Foundation
import ImageIO

/// PNG encoding helper shared by the canvas layer.
///
/// Encodes a `CGImage` to PNG via `ImageIO`. Split out of ``CanvasOperable``
/// so both the tool implementation and ``CanvasCoordinator/render(to:)``
/// can reuse it.
enum CanvasRendering {
    /// Returns PNG-encoded bytes for `image`, or `nil` if encoding fails.
    static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.png" as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
