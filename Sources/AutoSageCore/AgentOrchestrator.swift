import Foundation

public struct AgentSystemMessage: Codable, Equatable, Sendable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public struct AgentErrorRoute: Codable, Equatable, Sendable {
    public let errorCode: String
    public let action: String
    public let actionTool: String?
    public let retryLimit: Int

    enum CodingKeys: String, CodingKey {
        case errorCode = "error_code"
        case action
        case actionTool = "action_tool"
        case retryLimit = "retry_limit"
    }

    public init(errorCode: String, action: String, actionTool: String?, retryLimit: Int) {
        self.errorCode = errorCode
        self.action = action
        self.actionTool = actionTool
        self.retryLimit = retryLimit
    }
}

public struct AgentConfigPayload: Codable, Equatable, Sendable {
    public let agentRole: String
    public let manifestPath: String
    public let pipelineSequence: [String]
    public let escalationErrors: [String]
    public let errorRouting: [AgentErrorRoute]
    public let systemMessage: AgentSystemMessage
    public let messages: [AgentSystemMessage]
    public let tools: [ToolSpec]

    enum CodingKeys: String, CodingKey {
        case agentRole = "agent_role"
        case manifestPath = "manifest_path"
        case pipelineSequence = "pipeline_sequence"
        case escalationErrors = "escalation_errors"
        case errorRouting = "error_routing"
        case systemMessage = "system_message"
        case messages
        case tools
    }

    public init(
        agentRole: String,
        manifestPath: String,
        pipelineSequence: [String],
        escalationErrors: [String],
        errorRouting: [AgentErrorRoute],
        systemMessage: AgentSystemMessage,
        messages: [AgentSystemMessage],
        tools: [ToolSpec]
    ) {
        self.agentRole = agentRole
        self.manifestPath = manifestPath
        self.pipelineSequence = pipelineSequence
        self.escalationErrors = escalationErrors
        self.errorRouting = errorRouting
        self.systemMessage = systemMessage
        self.messages = messages
        self.tools = tools
    }
}

public enum AgentOrchestratorBootstrap {
    public static let manifestPath = "manifest.json"

    public static let pipelineSequence: [String] = [
        "cad_import_truck",
        "mesh_repair_pmp",
        "volume_mesh_quartet",
        "solve",
        "render_pack_vtk"
    ]

    public static let escalationErrors: [String] = [
        "ERR_NON_MANIFOLD_UNRESOLVABLE"
    ]

    public static let errorRouting: [AgentErrorRoute] = [
        AgentErrorRoute(
            errorCode: "ERR_NOT_WATERTIGHT",
            action: "route_surface_mesh_to_repair_then_retry_volume_mesh",
            actionTool: "mesh_repair_pmp",
            retryLimit: 1
        ),
        AgentErrorRoute(
            errorCode: "ERR_INVALID_DX",
            action: "increase_dx_and_retry_volume_mesh",
            actionTool: "volume_mesh_quartet",
            retryLimit: 1
        ),
        AgentErrorRoute(
            errorCode: "ERR_HOLE_TOO_LARGE",
            action: "retry_mesh_repair_with_intersection_resolution_then_retry_volume_mesh",
            actionTool: "mesh_repair_pmp",
            retryLimit: 1
        ),
        AgentErrorRoute(
            errorCode: "ERR_HEADLESS_CONTEXT_FAILED",
            action: "retry_render_with_color_only",
            actionTool: "render_pack_vtk",
            retryLimit: 1
        ),
        AgentErrorRoute(
            errorCode: "ERR_BUFFER_EXTRACTION_FAILED",
            action: "disable_depth_and_normal_buffers_and_retry_render",
            actionTool: "render_pack_vtk",
            retryLimit: 1
        ),
        AgentErrorRoute(
            errorCode: "ERR_POINTCLOUD_GENERATION_FAILED",
            action: "skip_primitive_fitting_and_continue_pipeline",
            actionTool: nil,
            retryLimit: 0
        ),
        AgentErrorRoute(
            errorCode: "ERR_PRIMITIVE_FIT_TIMEOUT",
            action: "relax_ransac_parameters_and_retry_primitive_fitting",
            actionTool: "dsl_fit_open3d",
            retryLimit: 1
        ),
        AgentErrorRoute(
            errorCode: "ERR_NON_MANIFOLD_UNRESOLVABLE",
            action: "stop_and_request_user_intervention",
            actionTool: nil,
            retryLimit: 0
        )
    ]

    public static let systemPrompt = """
You are the orchestration agent for the AutoSage simulation pipeline.

Role:
- Convert raw engineering assets into completed simulation and rendering outputs with no manual handholding.
- Plan and execute tool calls deterministically against AutoSage.

State management:
- Treat manifest.json in the active session workspace as the single source of truth.
- Before every tool call, read manifest.json and decide the next action from recorded state only.
- After every tool call, write back manifest.json with updated stage, input/output artifacts, tool arguments, status, and errors.
- Never assume files exist unless they are present in manifest.json or produced by a tool result.

Pipeline order:
1) CAD Import: cad_import_truck (STEP/B-rep to surface mesh).
2) Mesh Repair: mesh_repair_pmp (topology cleanup, hole filling, decimation).
3) Volume Mesh: volume_mesh_quartet (tet generation).
4) Solve: choose solver tool that matches requested physics (fea.solve, cfd.solve, etc).
5) Render: render_pack_vtk for color/depth/normal outputs.
Optional geometry abstraction: dsl_fit_open3d when requested for primitive extraction.

Deterministic error routing:
- If volume meshing returns ERR_NOT_WATERTIGHT, route mesh to mesh_repair_pmp and retry volume_mesh_quartet once.
- If volume meshing returns ERR_INVALID_DX, increase dx and retry volume_mesh_quartet once.
- If mesh repair returns ERR_HOLE_TOO_LARGE, retry mesh_repair_pmp with conservative settings once, then retry volume meshing.
- If render returns ERR_HEADLESS_CONTEXT_FAILED, retry render_pack_vtk with color-only output.
- If render returns ERR_BUFFER_EXTRACTION_FAILED, disable depth/normal buffers and retry once.
- If primitive fitting returns ERR_POINTCLOUD_GENERATION_FAILED, mark primitive fitting skipped and continue.
- If primitive fitting returns ERR_PRIMITIVE_FIT_TIMEOUT, relax RANSAC settings and retry once.
- If mesh repair returns ERR_NON_MANIFOLD_UNRESOLVABLE, stop and request user intervention.

Autonomy and escalation:
- Do not ask the user for intervention unless the error is ERR_NON_MANIFOLD_UNRESOLVABLE.
- For all other failures, apply deterministic retries/fallbacks and either complete the stage or fail the job with a clear machine-readable manifest update.
- Keep outputs bounded and deterministic; do not emit huge free-form payloads.
"""

    public static func makeConfig(registry: ToolRegistry) -> AgentConfigPayload {
        let toolSpecs = registry.tools.values
            .map {
                ToolSpec(
                    type: "function",
                    function: ToolFunction(
                        name: $0.name,
                        description: $0.description,
                        parameters: $0.jsonSchema
                    )
                )
            }
            .sorted { ($0.function?.name ?? "") < ($1.function?.name ?? "") }

        let systemMessage = AgentSystemMessage(role: "system", content: systemPrompt)
        return AgentConfigPayload(
            agentRole: "orchestration_agent",
            manifestPath: manifestPath,
            pipelineSequence: pipelineSequence,
            escalationErrors: escalationErrors,
            errorRouting: errorRouting,
            systemMessage: systemMessage,
            messages: [systemMessage],
            tools: toolSpecs
        )
    }
}
