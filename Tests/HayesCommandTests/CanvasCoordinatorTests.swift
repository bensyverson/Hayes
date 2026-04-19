import Foundation
@testable import HayesCommand
import Testing

@Suite("CanvasCoordinator")
@MainActor
struct CanvasCoordinatorTests {
    @Test("setScript stores the script verbatim")
    func setScript() {
        let coordinator = CanvasCoordinator()
        coordinator.setScript("layers = [];")
        #expect(coordinator.jsScript == "layers = [];")
    }

    @Test("editScript replaces the first occurrence only")
    func editScriptFirstOccurrence() throws {
        let coordinator = CanvasCoordinator()
        coordinator.setScript("const color = 'red';\nconst accent = 'red';")
        try coordinator.editScript(old: "'red'", new: "'blue'")
        #expect(coordinator.jsScript == "const color = 'blue';\nconst accent = 'red';")
    }

    @Test("render writes a non-empty PNG at the target URL")
    func renderWritesPNG() throws {
        let coordinator = CanvasCoordinator()
        coordinator.setScript("""
        layers = [{
          name: "bg",
          render(ctx, params, scene) {
            ctx.fillStyle = "#ff0000";
            ctx.fillRect(0, 0, scene.viewport.width, scene.viewport.height);
          }
        }];
        """)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hayes-render-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try coordinator.render(to: tmp)
        let data = try Data(contentsOf: tmp)
        #expect(data.count > 0)
        // PNG magic: 89 50 4E 47
        #expect(data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
    }
}
