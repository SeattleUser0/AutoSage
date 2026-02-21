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

public struct ToolCatalogMetadata: Codable, Equatable, Sendable {
    public let stability: ToolStability
    public let version: String
    public let tags: [String]
    public let examples: [ToolExample]

    public init(
        stability: ToolStability,
        version: String = "1",
        tags: [String] = [],
        examples: [ToolExample] = []
    ) {
        self.stability = stability
        let trimmedVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        self.version = trimmedVersion.isEmpty ? "1" : trimmedVersion
        self.tags = Array(
            Set(
                tags
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
            )
        ).sorted()
        self.examples = examples
            .compactMap { example in
                let title = example.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                let notesTrimmed = example.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedNotes = notesTrimmed?.isEmpty == false ? notesTrimmed : nil
                return ToolExample(title: title, input: example.input, notes: normalizedNotes)
            }
            .sorted { lhs, rhs in
                let lhsTitle = lhs.title.lowercased()
                let rhsTitle = rhs.title.lowercased()
                if lhsTitle == rhsTitle {
                    return lhs.title < rhs.title
                }
                return lhsTitle < rhsTitle
            }
    }
}

public struct ToolRegistration: Sendable {
    public let tool: Tool
    public let metadata: ToolCatalogMetadata

    public init(tool: Tool, metadata: ToolCatalogMetadata) {
        self.tool = tool
        self.metadata = metadata
    }
}

private enum ToolDocumentation {
    static func normalizedDescription(_ raw: String, toolName: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Executes \(toolName) and returns a normalized tool result."
        }
        let lowered = trimmed.lowercased()
        if lowered == "todo" || lowered == "tbd" {
            return "Executes \(toolName) and returns a normalized tool result."
        }
        return trimmed
    }

    static func normalizedSchema(_ raw: JSONValue, toolName: String, toolDescription: String) -> JSONValue {
        guard case .object(let object) = raw else {
            return JSONSchemaBuilder.schemaObject(
                title: toolName,
                description: "Input parameters for \(toolName). No parameters.",
                properties: [:],
                required: []
            )
        }
        return .object(normalizeSchemaObject(object, objectPath: [], toolName: toolName, fallbackDescription: toolDescription))
    }

    private static func normalizeSchemaObject(
        _ schemaObject: [String: JSONValue],
        objectPath: [String],
        toolName: String,
        fallbackDescription: String
    ) -> [String: JSONValue] {
        var normalized = schemaObject

        if asString(normalized["type"]) == nil {
            normalized["type"] = .string("object")
        }
        if isMissingDescription(normalized["description"]) {
            let fallback = objectPath.isEmpty
                ? "Input parameters for \(toolName). \(fallbackDescription)"
                : "Configuration object for \(readablePath(objectPath))."
            normalized["description"] = .string(fallback.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if asObject(normalized["properties"]) == nil {
            normalized["properties"] = .object([:])
        }
        if asArray(normalized["required"]) == nil {
            normalized["required"] = .array([])
        }

        if let properties = asObject(normalized["properties"]) {
            var rewritten: [String: JSONValue] = [:]
            for key in properties.keys.sorted() {
                let path = objectPath + [key]
                guard case .object(let propertyObject) = properties[key] else {
                    rewritten[key] = JSONSchemaBuilder.schemaString(
                        description: "Value for \(readablePath(path))."
                    )
                    continue
                }

                var normalizedProperty = propertyObject
                if isMissingDescription(normalizedProperty["description"]) {
                    normalizedProperty["description"] = .string("Value for \(readablePath(path)).")
                }

                let propertyType = asString(normalizedProperty["type"])?.lowercased()
                if propertyType == "object", let nestedProperties = asObject(normalizedProperty["properties"]) {
                    normalizedProperty["properties"] = .object(
                        normalizeSchemaProperties(
                            nestedProperties,
                            objectPath: path,
                            toolName: toolName
                        )
                    )
                    if asArray(normalizedProperty["required"]) == nil {
                        normalizedProperty["required"] = .array([])
                    }
                } else if propertyType == "array", case .object(let itemsObject)? = normalizedProperty["items"] {
                    var normalizedItems = itemsObject
                    if asString(normalizedItems["type"])?.lowercased() == "object",
                       let itemProperties = asObject(normalizedItems["properties"]) {
                        if isMissingDescription(normalizedItems["description"]) {
                            normalizedItems["description"] = .string("Schema for \(readablePath(path)) items.")
                        }
                        normalizedItems["properties"] = .object(
                            normalizeSchemaProperties(
                                itemProperties,
                                objectPath: path + ["item"],
                                toolName: toolName
                            )
                        )
                        if asArray(normalizedItems["required"]) == nil {
                            normalizedItems["required"] = .array([])
                        }
                        normalizedProperty["items"] = .object(normalizedItems)
                    }
                }

                rewritten[key] = .object(normalizedProperty)
            }
            normalized["properties"] = .object(rewritten)
        }

        return normalized
    }

    private static func normalizeSchemaProperties(
        _ properties: [String: JSONValue],
        objectPath: [String],
        toolName: String
    ) -> [String: JSONValue] {
        var wrapped: [String: JSONValue] = [:]
        for key in properties.keys.sorted() {
            let path = objectPath + [key]
            if case .object(let nestedObject) = properties[key] {
                var normalizedProperty = nestedObject
                if isMissingDescription(normalizedProperty["description"]) {
                    normalizedProperty["description"] = .string("Value for \(readablePath(path)).")
                }

                let propertyType = asString(normalizedProperty["type"])?.lowercased()
                if propertyType == "object", asObject(normalizedProperty["properties"]) != nil {
                    normalizedProperty = normalizeSchemaObject(
                        normalizedProperty,
                        objectPath: path,
                        toolName: toolName,
                        fallbackDescription: "Configuration for \(readablePath(path))."
                    )
                } else if propertyType == "array",
                          case .object(let itemsObject)? = normalizedProperty["items"],
                          asString(itemsObject["type"])?.lowercased() == "object",
                          asObject(itemsObject["properties"]) != nil {
                    var normalizedItems = itemsObject
                    if isMissingDescription(normalizedItems["description"]) {
                        normalizedItems["description"] = .string("Schema for \(readablePath(path)) items.")
                    }
                    normalizedItems = normalizeSchemaObject(
                        normalizedItems,
                        objectPath: path + ["item"],
                        toolName: toolName,
                        fallbackDescription: "Schema for \(readablePath(path)) items."
                    )
                    normalizedProperty["items"] = .object(normalizedItems)
                }
                wrapped[key] = .object(normalizedProperty)
            } else {
                wrapped[key] = JSONSchemaBuilder.schemaString(
                    description: "Value for \(readablePath(path))."
                )
            }
        }
        return wrapped
    }

    private static func readablePath(_ path: [String]) -> String {
        path
            .filter { !$0.isEmpty }
            .map { segment in
                segment
                    .replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: ".", with: " ")
            }
            .joined(separator: " ")
    }

    private static func asObject(_ value: JSONValue?) -> [String: JSONValue]? {
        guard case .object(let object)? = value else { return nil }
        return object
    }

    private static func asString(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value else { return nil }
        return string
    }

    private static func asArray(_ value: JSONValue?) -> [JSONValue]? {
        guard case .array(let array)? = value else { return nil }
        return array
    }

    private static func isMissingDescription(_ value: JSONValue?) -> Bool {
        guard let description = asString(value) else { return true }
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let lowered = trimmed.lowercased()
        return lowered == "todo" || lowered == "tbd"
    }
}

private struct DocumentedTool: Tool {
    private let base: any Tool
    public let name: String
    public let version: String
    public let description: String
    public let jsonSchema: JSONValue

    init(base: any Tool) {
        self.base = base
        self.name = base.name
        self.version = base.version
        let normalizedDescription = ToolDocumentation.normalizedDescription(base.description, toolName: base.name)
        self.description = normalizedDescription
        self.jsonSchema = ToolDocumentation.normalizedSchema(
            base.jsonSchema,
            toolName: base.name,
            toolDescription: normalizedDescription
        )
    }

    func run(input: JSONValue?, context: ToolExecutionContext) throws -> JSONValue {
        try base.run(input: input, context: context)
    }
}

public struct ToolRegistry {
    public let tools: [String: Tool]
    private let metadataByName: [String: ToolCatalogMetadata]

    public init(tools: [Tool]) {
        var map: [String: Tool] = [:]
        var metadata: [String: ToolCatalogMetadata] = [:]
        for tool in tools {
            let documented = DocumentedTool(base: tool)
            map[documented.name] = documented
            metadata[documented.name] = ToolCatalogMetadata(stability: .experimental)
        }
        self.tools = map
        self.metadataByName = metadata
    }

    public init(registrations: [ToolRegistration]) {
        var map: [String: Tool] = [:]
        var metadata: [String: ToolCatalogMetadata] = [:]
        for registration in registrations {
            let documented = DocumentedTool(base: registration.tool)
            map[documented.name] = documented
            metadata[documented.name] = registration.metadata
        }
        self.tools = map
        self.metadataByName = metadata
    }

    public func tool(named name: String) -> Tool? {
        tools[name]
    }

    public func metadata(named name: String) -> ToolCatalogMetadata? {
        metadataByName[name]
    }

    public func listTools(stability: ToolStability? = nil, tags: [String] = []) -> [(tool: Tool, metadata: ToolCatalogMetadata)] {
        let normalizedTags = Set(
            tags
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        return tools.keys.sorted().compactMap { name in
            guard let tool = tools[name], let metadata = metadataByName[name] else {
                return nil
            }
            if let stability, metadata.stability != stability {
                return nil
            }
            if !normalizedTags.isEmpty && Set(metadata.tags).isDisjoint(with: normalizedTags) {
                return nil
            }
            return (tool, metadata)
        }
    }

    public static let `default` = ToolRegistry(registrations: [
        ToolRegistration(
            tool: EchoJSONTool(),
            metadata: ToolCatalogMetadata(
                stability: .stable,
                version: "1",
                tags: ["util", "deterministic"],
                examples: [
                    ToolExample(
                        title: "Echo message twice",
                        input: .object([
                            "message": .string("hello"),
                            "n": .number(2)
                        ]),
                        notes: "Copy input into POST /v1/tools/execute with tool=echo_json."
                    )
                ]
            )
        ),
        ToolRegistration(
            tool: WriteTextArtifactTool(),
            metadata: ToolCatalogMetadata(
                stability: .stable,
                version: "1",
                tags: ["io", "artifact", "deterministic"],
                examples: [
                    ToolExample(
                        title: "Write note artifact",
                        input: .object([
                            "filename": .string("note.txt"),
                            "text": .string("artifact demo")
                        ]),
                        notes: "Produces a text artifact under the current job directory."
                    )
                ]
            )
        ),
        ToolRegistration(tool: FEATool(), metadata: ToolCatalogMetadata(stability: .experimental, version: "1", tags: ["pde", "fea"])),
        ToolRegistration(tool: CFDTool(), metadata: ToolCatalogMetadata(stability: .experimental, version: "1", tags: ["pde", "cfd"])),
        ToolRegistration(tool: StokesTool(), metadata: ToolCatalogMetadata(stability: .experimental, version: "1", tags: ["pde", "cfd"])),
        ToolRegistration(tool: AdvectionTool(), metadata: ToolCatalogMetadata(stability: .experimental, version: "1", tags: ["pde", "cfd"])),
        ToolRegistration(tool: DPGLaplaceTool(), metadata: ToolCatalogMetadata(stability: .experimental, version: "1", tags: ["pde"])),
        ToolRegistration(tool: CompressibleFlowTool(), metadata: ToolCatalogMetadata(stability: .experimental, version: "1", tags: ["pde", "cfd"])),
        ToolRegistration(tool: AcousticsTool(), metadata: ToolCatalogMetadata(stability: .experimental, version: "1", tags: ["pde"])),
        ToolRegistration(tool: EigenvalueTool(), metadata: ToolCatalogMetadata(stability: .experimental, version: "1", tags: ["pde"])),
        ToolRegistration(tool: StructuralModalTool(), metadata: ToolCatalogMetadata(stability: .experimental, version: "1", tags: ["pde", "fea"])),
        ToolRegistration(tool: HeatTool(), metadata: ToolCatalogMetadata(stability: .experimental, version: "1", tags: ["pde"])),
        ToolRegistration(tool: JouleHeatingTool(), metadata: ToolCatalogMetadata(stability: .experimental, version: "1", tags: ["pde", "em"])),
        ToolRegistration(tool: HyperelasticityTool(), metadata: ToolCatalogMetadata(stability: .experimental, version: "1", tags: ["pde", "fea"])),
        ToolRegistration(tool: ElastodynamicsTool(), metadata: ToolCatalogMetadata(stability: .experimental, version: "1", tags: ["pde", "fea"])),
        ToolRegistration(tool: TransientEMTool(), metadata: ToolCatalogMetadata(stability: .experimental, version: "1", tags: ["pde", "em"])),
        ToolRegistration(tool: MagnetostaticsTool(), metadata: ToolCatalogMetadata(stability: .experimental, version: "1", tags: ["pde", "em"])),
        ToolRegistration(tool: ElectrostaticsTool(), metadata: ToolCatalogMetadata(stability: .experimental, version: "1", tags: ["pde", "em"])),
        ToolRegistration(tool: AMRLaplaceTool(), metadata: ToolCatalogMetadata(stability: .experimental, version: "1", tags: ["pde", "mesh"])),
        ToolRegistration(tool: AnisotropicDiffusionTool(), metadata: ToolCatalogMetadata(stability: .experimental, version: "1", tags: ["pde"])),
        ToolRegistration(tool: FractionalPDETool(), metadata: ToolCatalogMetadata(stability: .experimental, version: "1", tags: ["pde"])),
        ToolRegistration(tool: SurfacePDETool(), metadata: ToolCatalogMetadata(stability: .experimental, version: "1", tags: ["pde"])),
        ToolRegistration(tool: ElectromagneticModalTool(), metadata: ToolCatalogMetadata(stability: .experimental, version: "1", tags: ["pde", "em"])),
        ToolRegistration(tool: ElectromagneticScatteringTool(), metadata: ToolCatalogMetadata(stability: .experimental, version: "1", tags: ["pde", "em"])),
        ToolRegistration(tool: ElectromagneticsTool(), metadata: ToolCatalogMetadata(stability: .experimental, version: "1", tags: ["pde", "em"])),
        ToolRegistration(tool: DarcyTool(), metadata: ToolCatalogMetadata(stability: .experimental, version: "1", tags: ["pde", "cfd"])),
        ToolRegistration(tool: IncompressibleElasticityTool(), metadata: ToolCatalogMetadata(stability: .experimental, version: "1", tags: ["pde", "fea"])),
        ToolRegistration(tool: VolumeMeshQuartetTool(), metadata: ToolCatalogMetadata(stability: .experimental, version: "1", tags: ["mesh", "io"])),
        ToolRegistration(tool: RenderPackVTKTool(), metadata: ToolCatalogMetadata(stability: .experimental, version: "1", tags: ["render", "io"])),
        ToolRegistration(tool: DslFitOpen3DTool(), metadata: ToolCatalogMetadata(stability: .experimental, version: "1", tags: ["mesh", "io"])),
        ToolRegistration(tool: MeshRepairPMPTool(), metadata: ToolCatalogMetadata(stability: .experimental, version: "1", tags: ["mesh", "io"])),
        ToolRegistration(tool: CadImportTruckTool(), metadata: ToolCatalogMetadata(stability: .experimental, version: "1", tags: ["cad", "io"])),
        ToolRegistration(tool: CircuitSimulateNgspiceTool(), metadata: ToolCatalogMetadata(stability: .experimental, version: "1", tags: ["circuit", "io"])),
        ToolRegistration(tool: CircuitsSimulateTool(), metadata: ToolCatalogMetadata(stability: .experimental, version: "1", tags: ["circuit"]))
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
