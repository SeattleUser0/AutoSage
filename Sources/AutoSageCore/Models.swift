import Foundation

public struct AutoSageError: Error, Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let details: [String: JSONValue]?

    public init(code: String, message: String, details: [String: JSONValue]? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}

public struct ErrorResponse: Codable, Equatable {
    public let error: AutoSageError

    public init(error: AutoSageError) {
        self.error = error
    }
}

public struct HealthResponse: Codable, Equatable {
    public let status: String
    public let name: String
    public let version: String

    public init(status: String, name: String, version: String) {
        self.status = status
        self.name = name
        self.version = version
    }
}

public struct ToolSpec: Codable, Equatable, Sendable {
    public let type: String?
    public let function: ToolFunction?

    public init(type: String?, function: ToolFunction?) {
        self.type = type
        self.function = function
    }
}

public struct ToolFunction: Codable, Equatable, Sendable {
    public let name: String
    public let description: String?
    public let parameters: JSONValue?

    public init(name: String, description: String?, parameters: JSONValue?) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct InputMessage: Codable, Equatable {
    public let role: String
    public let content: JSONValue

    public init(role: String, content: JSONValue) {
        self.role = role
        self.content = content
    }
}

public struct ChatMessage: Codable, Equatable {
    public let role: String
    public let content: JSONValue

    public init(role: String, content: JSONValue) {
        self.role = role
        self.content = content
    }
}

public struct ResponsesRequest: Codable, Equatable {
    public let model: String?
    public let input: [InputMessage]?
    public let toolChoice: JSONValue?
    public let tools: [ToolSpec]?

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case toolChoice = "tool_choice"
        case tools
    }

    public init(model: String?, input: [InputMessage]?, toolChoice: JSONValue?, tools: [ToolSpec]?) {
        self.model = model
        self.input = input
        self.toolChoice = toolChoice
        self.tools = tools
    }
}

public struct ChatCompletionsRequest: Codable, Equatable {
    public let model: String?
    public let messages: [ChatMessage]?
    public let toolChoice: JSONValue?
    public let tools: [ToolSpec]?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case toolChoice = "tool_choice"
        case tools
    }

    public init(model: String?, messages: [ChatMessage]?, toolChoice: JSONValue?, tools: [ToolSpec]?) {
        self.model = model
        self.messages = messages
        self.toolChoice = toolChoice
        self.tools = tools
    }
}

public struct ResponseTextContent: Codable, Equatable {
    public let type: String
    public let text: String

    public init(type: String, text: String) {
        self.type = type
        self.text = text
    }
}

public struct ResponseOutputItem: Codable, Equatable {
    public let type: String
    public let role: String?
    public let content: [ResponseTextContent]?
    public let toolName: String?
    public let result: JSONValue?

    enum CodingKeys: String, CodingKey {
        case type
        case role
        case content
        case toolName = "tool_name"
        case result
    }

    public init(type: String, role: String?, content: [ResponseTextContent]?, toolName: String?, result: JSONValue?) {
        self.type = type
        self.role = role
        self.content = content
        self.toolName = toolName
        self.result = result
    }
}

public struct ResponsesResponse: Codable, Equatable {
    public let id: String
    public let object: String
    public let model: String
    public let output: [ResponseOutputItem]

    public init(id: String, object: String, model: String, output: [ResponseOutputItem]) {
        self.id = id
        self.object = object
        self.model = model
        self.output = output
    }
}

public struct ToolCallFunction: Codable, Equatable {
    public let name: String
    public let arguments: String

    public init(name: String, arguments: String) {
        self.name = name
        self.arguments = arguments
    }
}

public struct ToolCall: Codable, Equatable {
    public let id: String
    public let type: String
    public let function: ToolCallFunction

    public init(id: String, type: String, function: ToolCallFunction) {
        self.id = id
        self.type = type
        self.function = function
    }
}

public struct ChatCompletionMessage: Codable, Equatable {
    public let role: String
    public let content: String
    public let toolCalls: [ToolCall]?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
    }

    public init(role: String, content: String, toolCalls: [ToolCall]?) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
    }
}

public struct ChatChoice: Codable, Equatable {
    public let index: Int
    public let message: ChatCompletionMessage
    public let finishReason: String

    enum CodingKeys: String, CodingKey {
        case index
        case message
        case finishReason = "finish_reason"
    }

    public init(index: Int, message: ChatCompletionMessage, finishReason: String) {
        self.index = index
        self.message = message
        self.finishReason = finishReason
    }
}

public struct ChatCompletionsResponse: Codable, Equatable {
    public let id: String
    public let object: String
    public let model: String
    public let choices: [ChatChoice]
    public let toolResults: [JSONValue]?

    enum CodingKeys: String, CodingKey {
        case id
        case object
        case model
        case choices
        case toolResults = "tool_results"
    }

    public init(id: String, object: String, model: String, choices: [ChatChoice], toolResults: [JSONValue]?) {
        self.id = id
        self.object = object
        self.model = model
        self.choices = choices
        self.toolResults = toolResults
    }
}

public enum JobRunMode: String, Codable, Equatable, Sendable {
    case async = "async"
    case sync = "sync"
}

public struct CreateJobRequest: Codable, Equatable {
    public let toolName: String
    public let input: JSONValue?
    public let mode: JobRunMode?
    public let waitMS: Int?
    public let limits: ToolExecutionLimits?

    enum CodingKeys: String, CodingKey {
        case toolName = "tool_name"
        case input
        case mode
        case waitMS = "wait_ms"
        case limits
    }

    public init(toolName: String, input: JSONValue?, mode: JobRunMode?, waitMS: Int?, limits: ToolExecutionLimits?) {
        self.toolName = toolName
        self.input = input
        self.mode = mode
        self.waitMS = waitMS
        self.limits = limits
    }
}

public struct CreateJobResponse: Codable, Equatable {
    public let jobID: String
    public let status: JobStatus
    public let job: JobRecord?

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case status
        case job
    }

    public init(jobID: String, status: JobStatus, job: JobRecord? = nil) {
        self.jobID = jobID
        self.status = status
        self.job = job
    }
}

public struct JobArtifactFile: Codable, Equatable, Sendable {
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

public struct JobArtifactsResponse: Codable, Equatable, Sendable {
    public let jobID: String
    public let files: [JobArtifactFile]

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case files
    }

    public init(jobID: String, files: [JobArtifactFile]) {
        self.jobID = jobID
        self.files = files
    }
}

public struct AdminClearJobsResponse: Codable, Equatable, Sendable {
    public let status: String
    public let deletedJobs: Int
    public let reclaimedBytes: Int64
    public let reclaimedHuman: String
    public let sessionsRoot: String
    public let message: String
    public let timestamp: Date

    enum CodingKeys: String, CodingKey {
        case status
        case deletedJobs = "deleted_jobs"
        case reclaimedBytes = "reclaimed_bytes"
        case reclaimedHuman = "reclaimed_human"
        case sessionsRoot = "sessions_root"
        case message
        case timestamp
    }

    public init(
        status: String,
        deletedJobs: Int,
        reclaimedBytes: Int64,
        reclaimedHuman: String,
        sessionsRoot: String,
        message: String,
        timestamp: Date
    ) {
        self.status = status
        self.deletedJobs = deletedJobs
        self.reclaimedBytes = reclaimedBytes
        self.reclaimedHuman = reclaimedHuman
        self.sessionsRoot = sessionsRoot
        self.message = message
        self.timestamp = timestamp
    }
}

public struct AdminLogsResponse: Codable, Equatable, Sendable {
    public let lines: [String]
    public let count: Int
    public let generatedAt: Date

    enum CodingKeys: String, CodingKey {
        case lines
        case count
        case generatedAt = "generated_at"
    }

    public init(lines: [String], count: Int, generatedAt: Date) {
        self.lines = lines
        self.count = count
        self.generatedAt = generatedAt
    }
}

public enum ToolStability: String, Codable, Equatable, Sendable {
    case stable
    case experimental
    case deprecated
}

public struct ToolExample: Codable, Equatable, Sendable {
    public let title: String
    public let input: JSONValue
    public let notes: String?

    public init(title: String, input: JSONValue, notes: String? = nil) {
        self.title = title
        self.input = input
        self.notes = notes
    }
}

public struct PublicToolDescriptor: Codable, Equatable, Sendable {
    public let name: String
    public let version: String
    public let stability: ToolStability
    public let tags: [String]?
    public let examples: [ToolExample]?
    public let description: String
    public let inputSchema: JSONValue

    enum CodingKeys: String, CodingKey {
        case name
        case version
        case stability
        case tags
        case examples
        case description
        case inputSchema = "input_schema"
    }

    public init(
        name: String,
        version: String,
        stability: ToolStability,
        tags: [String]?,
        examples: [ToolExample]?,
        description: String,
        inputSchema: JSONValue
    ) {
        self.name = name
        self.version = version
        self.stability = stability
        self.tags = tags
        self.examples = examples
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct PublicToolsResponse: Codable, Equatable, Sendable {
    public let tools: [PublicToolDescriptor]

    public init(tools: [PublicToolDescriptor]) {
        self.tools = tools
    }
}

public struct ToolExecuteContextRequest: Codable, Equatable, Sendable {
    public let limits: ToolExecutionLimits?

    public init(limits: ToolExecutionLimits?) {
        self.limits = limits
    }
}

public struct ToolExecuteRequest: Codable, Equatable, Sendable {
    public let tool: String
    public let input: JSONValue?
    public let context: ToolExecuteContextRequest?

    public init(tool: String, input: JSONValue?, context: ToolExecuteContextRequest?) {
        self.tool = tool
        self.input = input
        self.context = context
    }
}
