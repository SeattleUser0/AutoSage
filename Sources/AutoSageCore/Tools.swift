import Foundation

public struct ToolExecutionLimits: Codable, Equatable, Sendable {
    public let timeoutMS: Int
    public let maxStdoutBytes: Int
    public let maxStderrBytes: Int
    public let maxArtifactBytes: Int
    public let maxArtifacts: Int
    public let maxSummaryCharacters: Int

    enum CodingKeys: String, CodingKey {
        case timeoutMS = "timeout_ms"
        case maxStdoutBytes = "max_stdout_bytes"
        case maxStderrBytes = "max_stderr_bytes"
        case maxArtifactBytes = "max_artifact_bytes"
        case maxArtifacts = "max_artifacts"
        case maxSummaryCharacters = "max_summary_characters"
    }

    public init(
        timeoutMS: Int,
        maxStdoutBytes: Int,
        maxStderrBytes: Int,
        maxArtifactBytes: Int,
        maxArtifacts: Int,
        maxSummaryCharacters: Int
    ) {
        self.timeoutMS = max(1, timeoutMS)
        self.maxStdoutBytes = max(1, maxStdoutBytes)
        self.maxStderrBytes = max(1, maxStderrBytes)
        self.maxArtifactBytes = max(1, maxArtifactBytes)
        self.maxArtifacts = max(1, maxArtifacts)
        self.maxSummaryCharacters = max(16, maxSummaryCharacters)
    }

    public static let `default` = ToolExecutionLimits(
        timeoutMS: 30_000,
        maxStdoutBytes: 1_000_000,
        maxStderrBytes: 1_000_000,
        maxArtifactBytes: 25_000_000,
        maxArtifacts: 64,
        maxSummaryCharacters: 280
    )
}

public struct ToolExecutionContext: Sendable {
    public let jobID: String
    public let jobDirectoryURL: URL
    public let limits: ToolExecutionLimits

    public init(jobID: String, jobDirectoryURL: URL, limits: ToolExecutionLimits = .default) {
        self.jobID = jobID
        self.jobDirectoryURL = jobDirectoryURL
        self.limits = limits
    }
}

public struct ToolArtifact: Codable, Equatable, Sendable {
    public let name: String
    public let path: String
    public let mimeType: String
    public let bytes: Int

    enum CodingKeys: String, CodingKey {
        case name
        case path
        case mimeType = "mime_type"
        case bytes
    }

    public init(name: String, path: String, mimeType: String, bytes: Int) {
        self.name = name
        self.path = path
        self.mimeType = mimeType
        self.bytes = bytes
    }
}

public struct ToolExecutionResult: Codable, Equatable, Sendable {
    public let status: String
    public let solver: String
    public let summary: String
    public let stdout: String
    public let stderr: String
    public let exitCode: Int
    public let artifacts: [ToolArtifact]
    public let metrics: [String: JSONValue]
    public let output: JSONValue?

    enum CodingKeys: String, CodingKey {
        case status
        case solver
        case summary
        case stdout
        case stderr
        case exitCode = "exit_code"
        case artifacts
        case metrics
        case output
    }

    public init(
        status: String,
        solver: String,
        summary: String,
        stdout: String,
        stderr: String,
        exitCode: Int,
        artifacts: [ToolArtifact],
        metrics: [String: JSONValue],
        output: JSONValue?
    ) {
        self.status = status
        self.solver = solver
        self.summary = summary
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.artifacts = artifacts
        self.metrics = metrics
        self.output = output
    }

    public func asJSONValue() throws -> JSONValue {
        let data = try JSONCoding.makeEncoder().encode(self)
        guard case .object(var baseObject) = try JSONCoding.makeDecoder().decode(JSONValue.self, from: data) else {
            throw AutoSageError(code: "internal_error", message: "Failed to encode tool execution result.")
        }
        if case .object(let outputObject)? = output {
            for (key, value) in outputObject where baseObject[key] == nil {
                baseObject[key] = value
            }
        }
        return .object(baseObject)
    }
}

public protocol Tool: Sendable {
    var name: String { get }
    var version: String { get }
    var description: String { get }
    var jsonSchema: JSONValue { get }
    func run(input: JSONValue?, context: ToolExecutionContext) throws -> JSONValue
}

public struct ToolRegistry {
    public let tools: [String: Tool]

    public init(tools: [Tool]) {
        var map: [String: Tool] = [:]
        for tool in tools {
            map[tool.name] = tool
        }
        self.tools = map
    }

    public func tool(named name: String) -> Tool? {
        tools[name]
    }

    public static let `default` = ToolRegistry(tools: [
        FEATool(),
        CFDTool(),
        StokesTool(),
        AdvectionTool(),
        DPGLaplaceTool(),
        CompressibleFlowTool(),
        AcousticsTool(),
        EigenvalueTool(),
        StructuralModalTool(),
        HeatTool(),
        JouleHeatingTool(),
        HyperelasticityTool(),
        ElastodynamicsTool(),
        TransientEMTool(),
        MagnetostaticsTool(),
        ElectrostaticsTool(),
        AMRLaplaceTool(),
        AnisotropicDiffusionTool(),
        FractionalPDETool(),
        SurfacePDETool(),
        ElectromagneticModalTool(),
        ElectromagneticScatteringTool(),
        ElectromagneticsTool(),
        DarcyTool(),
        IncompressibleElasticityTool(),
        VolumeMeshQuartetTool(),
        RenderPackVTKTool(),
        DslFitOpen3DTool(),
        MeshRepairPMPTool(),
        CadImportTruckTool(),
        CircuitSimulateNgspiceTool(),
        CircuitsSimulateTool()
    ])
}

public struct StubSolverTool: Tool {
    public let name: String
    public let version: String
    public let description: String
    public let jsonSchema: JSONValue

    public init(name: String, version: String, description: String, jsonSchema: JSONValue) {
        self.name = name
        self.version = version
        self.description = description
        self.jsonSchema = jsonSchema
    }

    public func run(input: JSONValue?, context: ToolExecutionContext) throws -> JSONValue {
        let cappedValues: [Double] = Array([0.1, 0.2, 0.3, 0.4, 0.5].prefix(10))
        let payload: JSONValue = .object([
            "values": .numberArray(cappedValues)
        ])
        let result = ToolExecutionResult(
            status: "ok",
            solver: name,
            summary: "Stub result for \(name).",
            stdout: "",
            stderr: "",
            exitCode: 0,
            artifacts: [],
            metrics: [
                "elapsed_ms": .number(0),
                "job_id": .string(context.jobID)
            ],
            output: payload
        )
        return try result.asJSONValue()
    }
}
