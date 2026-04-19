import CoreGraphics
import Foundation
import NativeCanvas
import Operator

// MARK: - Tool Inputs

/// Input payload for the `write_script` tool.
struct WriteScriptInput: ToolInput {
    /// The full NativeCanvas JavaScript source to store.
    var script: String

    static let paramDescriptions: [String: String] = [
        "script": "The complete NativeCanvas JavaScript source to write. Must define a `layers` array.",
    ]
}

/// Input payload for the `edit_script` tool.
struct EditScriptInput: ToolInput {
    /// The exact substring to find and replace (first occurrence only).
    var old_string: String
    /// The replacement substring.
    var new_string: String

    static let paramDescriptions: [String: String] = [
        "old_string": "The exact substring to find and replace (first occurrence only).",
        "new_string": "The replacement string.",
    ]
}

// MARK: - CanvasOperable

/// Adapts a ``CanvasCoordinator`` to Operator's tool surface.
///
/// Provides four tools — `read_script`, `write_script`, `edit_script`, and
/// `view_canvas` — the same set VibePDF exposes, with all PDF-specific
/// scanning / cursor / animation behavior stripped. Each `view_canvas`
/// call renders the current script to PNG, writes it atomically to
/// `outputURL`, and returns it to the LLM as an image content part.
final class CanvasOperable: Operable {
    let toolGroup: ToolGroup

    /// Creates a new tool surface.
    /// - Parameters:
    ///   - coordinator: The coordinator holding the current script state.
    ///   - outputURL: The file URL where `view_canvas` writes the rendered PNG.
    init(coordinator: CanvasCoordinator, outputURL: URL) throws {
        let writeScriptTool = try Tool(
            name: "write_script",
            description: "Write or fully replace the NativeCanvas JavaScript script for the composition.",
            input: WriteScriptInput.self
        ) { [weak coordinator] input in
            guard let coordinator else {
                return ToolOutput("Error: coordinator unavailable.")
            }
            await coordinator.setScript(input.script)
            return ToolOutput("Script written successfully.")
        }

        let editScriptTool = try Tool(
            name: "edit_script",
            description: "Make a targeted edit to the current script by replacing the first occurrence of old_string with new_string.",
            input: EditScriptInput.self
        ) { [weak coordinator] input in
            guard let coordinator else {
                return ToolOutput("Error: coordinator unavailable.")
            }
            do {
                try await coordinator.editScript(old: input.old_string, new: input.new_string)
                return ToolOutput("Edit applied successfully.")
            } catch {
                return ToolOutput("Error: \(error.localizedDescription)")
            }
        }

        let readScriptTool = Tool(
            name: "read_script",
            description: "Read the current NativeCanvas JavaScript script. Use this when you need to inspect the existing composition before editing."
        ) { [weak coordinator] in
            guard let coordinator else {
                return ToolOutput("Error: coordinator unavailable.")
            }
            let script = await coordinator.readScript()
            guard let script, !script.isEmpty else {
                return ToolOutput("(no script loaded yet)")
            }
            return ToolOutput(script)
        }

        let viewCanvasTool = Tool(
            name: "view_canvas",
            description: "Render the current script and view the result as an image to verify the output."
        ) { [weak coordinator] in
            await CanvasOperable.viewCanvas(
                coordinator: coordinator,
                outputURL: outputURL
            )
        }

        toolGroup = ToolGroup(
            name: "Canvas",
            tools: [readScriptTool, writeScriptTool, editScriptTool, viewCanvasTool]
        )
    }

    /// Renders the current script and returns it as an image tool output.
    private static func viewCanvas(
        coordinator: CanvasCoordinator?,
        outputURL: URL
    ) async -> ToolOutput {
        guard let coordinator else {
            return ToolOutput("Error: coordinator unavailable.")
        }
        do {
            let image = try await coordinator.render(to: outputURL)
            guard let data = CanvasRendering.pngData(from: image) else {
                return ToolOutput("Failed to encode canvas image.")
            }
            return ToolOutput([
                Operator.ContentPart.image(
                    data: data,
                    mediaType: "image/png",
                    filename: "canvas.png"
                ),
            ])
        } catch {
            return ToolOutput("Render error: \(error.localizedDescription)")
        }
    }
}
