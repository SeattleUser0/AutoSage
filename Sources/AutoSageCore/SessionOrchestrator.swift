import Foundation

public enum SessionStreamEvent: Sendable, Equatable {
    case textDelta(delta: String)
    case toolCallStart(toolName: String)
    case toolCallComplete(toolName: String, durationMS: Int)
    case stateUpdate(state: SessionManifest)
}

public struct SessionOrchestratorResult: Sendable, Equatable {
    public let reply: String
    public let state: SessionManifest
    public let events: [SessionStreamEvent]

    public init(reply: String, state: SessionManifest, events: [SessionStreamEvent]) {
        self.reply = reply
        self.state = state
        self.events = events
    }
}

public protocol SessionOrchestrating: Sendable {
    func orchestrate(sessionID: String, prompt: String, sessionStore: SessionStore) async throws -> SessionOrchestratorResult
}

public struct DefaultSessionOrchestrator: SessionOrchestrating {
    public init() {}

    public func orchestrate(sessionID: String, prompt: String, sessionStore: SessionStore) async throws -> SessionOrchestratorResult {
        _ = try await sessionStore.appendUserPrompt(id: sessionID, prompt: prompt)

        let plannedTool = Self.plannedToolName(for: prompt)
        let stage = Self.stageForPlannedTool(plannedTool)
        let assistantMessage: String
        if let plannedTool {
            assistantMessage = "Planned next tool: \(plannedTool)."
        } else {
            assistantMessage = "Prompt captured. No deterministic tool mapping found."
        }

        let state = try await sessionStore.appendAssistantMessage(
            id: sessionID,
            message: assistantMessage,
            plannedTool: plannedTool,
            stage: stage
        )

        var events: [SessionStreamEvent] = []
        if let plannedTool {
            events.append(.toolCallStart(toolName: plannedTool))
        }
        events.append(.stateUpdate(state: state))
        if let plannedTool {
            events.append(.toolCallComplete(toolName: plannedTool, durationMS: 1))
        }

        let reply = plannedTool == nil
            ? "Request recorded. Awaiting explicit tool instruction."
            : "Request recorded. Planned tool: \(plannedTool!)."

        return SessionOrchestratorResult(reply: reply, state: state, events: events)
    }

    private static func plannedToolName(for prompt: String) -> String? {
        let text = prompt.lowercased()
        if text.contains("repair") || text.contains("watertight") || text.contains("non-manifold") {
            return "mesh_repair_pmp"
        }
        if text.contains("tetra") || text.contains("volume mesh") {
            return "volume_mesh_quartet"
        }
        if text.contains("render") || text.contains("image") || text.contains("view") {
            return "render_pack_vtk"
        }
        if text.contains("cad") || text.contains("step") || text.contains("brep") {
            return "cad_import_truck"
        }
        if text.contains("elasticity") || text.contains("structural") || text.contains("fea") {
            return "fea.solve"
        }
        if text.contains("fluid") || text.contains("flow") || text.contains("cfd") {
            return "cfd.solve"
        }
        if text.contains("circuit") || text.contains("spice") {
            return "circuit_simulate_ngspice"
        }
        return nil
    }

    private static func stageForPlannedTool(_ toolName: String?) -> String {
        switch toolName {
        case "cad_import_truck":
            return "geometry_import"
        case "mesh_repair_pmp":
            return "mesh_repair"
        case "volume_mesh_quartet":
            return "volume_mesh"
        case "render_pack_vtk":
            return "render"
        case "fea.solve", "cfd.solve", "circuits.simulate", "circuit_simulate_ngspice":
            return "solve"
        default:
            return "chat"
        }
    }
}
