import CoreGraphics
import Foundation
import NativeCanvas

/// Minimal canvas state shared between the tool surface and the CLI.
///
/// Holds the current JavaScript source and the target viewport, plus the
/// URL of the most recent rendered PNG. Vendored and trimmed from VibePDF's
/// `DocumentCoordinator` — all SwiftUI overlays, scanning animations, and
/// cursor tracking are dropped; only what `hayes chat` actually needs
/// remains.
@MainActor
final class CanvasCoordinator {
    /// The current canvas JavaScript source, or `nil` if no script has
    /// been written yet.
    var jsScript: String?

    /// Target viewport dimensions for rendering.
    var viewport: CanvasViewport

    /// The URL of the most recent successful render, or `nil`.
    private(set) var lastRenderedPNG: URL?

    /// Creates a new coordinator.
    /// - Parameter viewport: Initial render viewport. Defaults to 1024 × 1024.
    init(viewport: CanvasViewport = CanvasViewport(width: 1024, height: 1024)) {
        self.viewport = viewport
    }

    /// Errors raised by ``editScript(old:new:)``.
    enum EditError: Error, CustomStringConvertible {
        /// There is no script to edit yet.
        case noScript
        /// The `old_string` was not found in the current script.
        case notFound(old: String)

        var description: String {
            switch self {
            case .noScript: "No script loaded yet; call write_script first."
            case let .notFound(old):
                "old_string not found in current script: \(old.prefix(40))…"
            }
        }
    }

    /// Replaces the current script with `source`.
    func setScript(_ source: String) {
        jsScript = source
    }

    /// Returns the current script, or `nil` if none has been written.
    func readScript() -> String? {
        jsScript
    }

    /// Replaces the first occurrence of `old` with `new` in the current script.
    /// - Throws: ``EditError/noScript`` if no script is loaded;
    ///           ``EditError/notFound(old:)`` if `old` is absent.
    func editScript(old: String, new: String) throws {
        guard var script = jsScript else { throw EditError.noScript }
        guard let range = script.range(of: old) else {
            throw EditError.notFound(old: old)
        }
        script.replaceSubrange(range, with: new)
        jsScript = script
    }

    /// Renders the current script to `url` as a PNG.
    ///
    /// Writes atomically so concurrent readers (for example, a browser
    /// refreshing the image) never observe a half-written file.
    ///
    /// - Parameter url: The destination PNG path.
    /// - Returns: The rendered `CGImage`.
    /// - Throws: ``RenderError/noScript`` if no script is loaded;
    ///           ``RenderError/encodingFailed`` if PNG encoding fails;
    ///           any error raised by `CanvasRenderer.render`.
    @discardableResult
    func render(to url: URL) throws -> CGImage {
        guard let source = jsScript, !source.isEmpty else {
            throw RenderError.noScript
        }
        let image = try CanvasRenderer.render(source: source, viewport: viewport, scale: 2)
        guard let data = CanvasRendering.pngData(from: image) else {
            throw RenderError.encodingFailed
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        lastRenderedPNG = url
        return image
    }

    /// Errors raised by ``render(to:)``.
    enum RenderError: Error, CustomStringConvertible {
        /// No script is loaded yet.
        case noScript
        /// PNG encoding of the rendered image failed.
        case encodingFailed

        var description: String {
            switch self {
            case .noScript: "No script loaded yet."
            case .encodingFailed: "Failed to encode rendered canvas as PNG."
            }
        }
    }
}
