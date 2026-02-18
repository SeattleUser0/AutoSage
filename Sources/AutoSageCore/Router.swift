import Foundation

public struct HTTPRequest {
    public let method: String
    public let path: String
    public let body: Data?

    public init(method: String, path: String, body: Data?) {
        self.method = method
        self.path = path
        self.body = body
    }
}

public struct HTTPResponse {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public struct Router {
    public let registry: ToolRegistry
    public let idGenerator: RequestIDGenerator
    public let jobStore: JobStore

    public init(
        registry: ToolRegistry = .default,
        idGenerator: RequestIDGenerator = RequestIDGenerator(),
        jobStore: JobStore? = nil
    ) {
        self.registry = registry
        self.idGenerator = idGenerator
        self.jobStore = jobStore ?? JobStore(idGenerator: idGenerator)
    }

    public func handle(_ request: HTTPRequest) -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/healthz"):
            let response = HealthResponse(status: "ok", name: "AutoSage", version: "0.1.0")
            return jsonResponse(response)
        case ("POST", "/v1/responses"):
            return handleResponses(request)
        case ("POST", "/v1/chat/completions"):
            return handleChatCompletions(request)
        case ("POST", "/v1/jobs"):
            return handleCreateJob(request)
        case ("GET", _):
            if request.path.hasPrefix("/v1/jobs/") {
                return handleGetJob(request)
            }
            return errorResponse(code: "not_found", message: "Unknown route.", status: 404)
        default:
            return errorResponse(code: "not_found", message: "Unknown route.", status: 404)
        }
    }

    private func handleResponses(_ request: HTTPRequest) -> HTTPResponse {
        guard let body = request.body else {
            return errorResponse(
                code: "invalid_request",
                message: "Missing request body.",
                details: ["field": .string("body")]
            )
        }
        do {
            let decoder = JSONDecoder()
            let req = try decoder.decode(ResponsesRequest.self, from: body)
            guard let model = nonEmptyModel(req.model) else {
                return errorResponse(
                    code: "invalid_request",
                    message: "Missing required field: model.",
                    details: ["field": .string("model")]
                )
            }
            if let toolName = requestedToolName(from: req.toolChoice) {
                guard let tool = registry.tool(named: toolName) else {
                    return errorResponse(
                        code: "unknown_tool",
                        message: "Unsupported tool: \(toolName).",
                        details: ["tool_name": .string(toolName)]
                    )
                }
                let execution = executeToolWithJob(tool: tool, toolName: toolName, input: nil)
                let output: [ResponseOutputItem] = [
                    ResponseOutputItem(type: "tool_call", role: nil, content: nil, toolName: toolName, result: nil),
                    ResponseOutputItem(
                        type: "tool_result",
                        role: nil,
                        content: nil,
                        toolName: toolName,
                        result: execution.inlineResult ?? jobReferenceResult(jobID: execution.jobID)
                    )
                ]
                let response = ResponsesResponse(
                    id: idGenerator.nextResponseID(),
                    object: "response",
                    model: model,
                    output: output
                )
                return jsonResponse(response)
            }

            let message = ResponseOutputItem(
                type: "message",
                role: "assistant",
                content: [ResponseTextContent(type: "output_text", text: "AutoSage response stub.")],
                toolName: nil,
                result: nil
            )
            let response = ResponsesResponse(
                id: idGenerator.nextResponseID(),
                object: "response",
                model: model,
                output: [message]
            )
            return jsonResponse(response)
        } catch {
            return errorResponse(
                code: "invalid_request",
                message: "Invalid JSON body.",
                details: ["reason": .string("Failed to decode JSON.")]
            )
        }
    }

    private func handleChatCompletions(_ request: HTTPRequest) -> HTTPResponse {
        guard let body = request.body else {
            return errorResponse(
                code: "invalid_request",
                message: "Missing request body.",
                details: ["field": .string("body")]
            )
        }
        do {
            let decoder = JSONDecoder()
            let req = try decoder.decode(ChatCompletionsRequest.self, from: body)
            guard let model = nonEmptyModel(req.model) else {
                return errorResponse(
                    code: "invalid_request",
                    message: "Missing required field: model.",
                    details: ["field": .string("model")]
                )
            }
            if let toolName = requestedToolName(from: req.toolChoice) {
                guard let tool = registry.tool(named: toolName) else {
                    return errorResponse(
                        code: "unknown_tool",
                        message: "Unsupported tool: \(toolName).",
                        details: ["tool_name": .string(toolName)]
                    )
                }
                let execution = executeToolWithJob(tool: tool, toolName: toolName, input: nil)
                let toolCall = ToolCall(
                    id: idGenerator.nextToolCallID(),
                    type: "function",
                    function: ToolCallFunction(name: toolName, arguments: "{}")
                )
                let message = ChatCompletionMessage(role: "assistant", content: "", toolCalls: [toolCall])
                let choice = ChatChoice(index: 0, message: message, finishReason: "tool_calls")
                let response = ChatCompletionsResponse(
                    id: idGenerator.nextChatCompletionID(),
                    object: "chat.completion",
                    model: model,
                    choices: [choice],
                    toolResults: [execution.inlineResult ?? jobReferenceResult(jobID: execution.jobID)]
                )
                return jsonResponse(response)
            }

            let message = ChatCompletionMessage(role: "assistant", content: "AutoSage chat stub.", toolCalls: nil)
            let choice = ChatChoice(index: 0, message: message, finishReason: "stop")
            let response = ChatCompletionsResponse(
                id: idGenerator.nextChatCompletionID(),
                object: "chat.completion",
                model: model,
                choices: [choice],
                toolResults: nil
            )
            return jsonResponse(response)
        } catch {
            return errorResponse(
                code: "invalid_request",
                message: "Invalid JSON body.",
                details: ["reason": .string("Failed to decode JSON.")]
            )
        }
    }

    private func handleCreateJob(_ request: HTTPRequest) -> HTTPResponse {
        guard let body = request.body else {
            return errorResponse(
                code: "invalid_request",
                message: "Missing request body.",
                details: ["field": .string("body")]
            )
        }

        do {
            let req = try JSONDecoder().decode(CreateJobRequest.self, from: body)
            let toolName = req.toolName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !toolName.isEmpty else {
                return errorResponse(
                    code: "invalid_request",
                    message: "Missing required field: tool_name.",
                    details: ["field": .string("tool_name")]
                )
            }
            guard let tool = registry.tool(named: toolName) else {
                return errorResponse(
                    code: "unknown_tool",
                    message: "Unsupported tool: \(toolName).",
                    details: ["tool_name": .string(toolName)]
                )
            }

            let job = waitForAsync { await jobStore.createJob(toolName: toolName, input: req.input) }
            Task.detached {
                await jobStore.startJob(id: job.id)
                let result = tool.run(input: req.input)
                let summary = Self.resultSummary(from: result)
                await jobStore.completeJob(id: job.id, result: result, summary: summary)
            }
            return jsonResponse(CreateJobResponse(jobID: job.id, status: .queued))
        } catch {
            return errorResponse(
                code: "invalid_request",
                message: "Invalid JSON body.",
                details: ["reason": .string("Failed to decode JSON.")]
            )
        }
    }

    private func handleGetJob(_ request: HTTPRequest) -> HTTPResponse {
        let components = request.path.split(separator: "/")
        guard components.count == 3, components[0] == "v1", components[1] == "jobs" else {
            return errorResponse(code: "not_found", message: "Unknown route.", status: 404)
        }
        let jobID = String(components[2])
        guard let job = waitForAsync({ await jobStore.getJob(id: jobID) }) else {
            return errorResponse(
                code: "not_found",
                message: "Job not found: \(jobID).",
                status: 404,
                details: ["job_id": .string(jobID)]
            )
        }
        return jsonResponse(job)
    }

    private func executeToolWithJob(tool: Tool, toolName: String, input: JSONValue?) -> (jobID: String, inlineResult: JSONValue?) {
        let job = waitForAsync { await jobStore.createJob(toolName: toolName, input: input) }
        let completion = DispatchSemaphore(value: 0)

        Task.detached {
            await jobStore.startJob(id: job.id)
            let result = tool.run(input: input)
            let summary = Self.resultSummary(from: result)
            await jobStore.completeJob(id: job.id, result: result, summary: summary)
            completion.signal()
        }

        if completion.wait(timeout: .now() + .milliseconds(50)) == .success,
           let completed = waitForAsync({ await jobStore.getJob(id: job.id) }),
           completed.status == .succeeded {
            return (job.id, completed.result)
        }
        return (job.id, nil)
    }

    private static func resultSummary(from result: JSONValue) -> String {
        guard case .object(let object) = result,
              case .string(let summary)? = object["summary"],
              !summary.isEmpty else {
            return "Tool execution completed."
        }
        return summary
    }

    private func jobReferenceResult(jobID: String) -> JSONValue {
        .object([
            "status": .string("queued"),
            "job_id": .string(jobID)
        ])
    }

    private func nonEmptyModel(_ model: String?) -> String? {
        guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else {
            return nil
        }
        return model
    }

    private func requestedToolName(from toolChoice: JSONValue?) -> String? {
        guard let toolChoice = toolChoice else { return nil }
        switch toolChoice {
        case .string(let name):
            return name
        case .object(let dict):
            if case .string(let name)? = dict["name"] {
                return name
            }
            if case .object(let functionDict)? = dict["function"], case .string(let name)? = functionDict["name"] {
                return name
            }
            return nil
        default:
            return nil
        }
    }

    private func jsonResponse<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: data)
    }

    private func errorResponse(
        code: String,
        message: String,
        status: Int = 400,
        details: [String: JSONValue]? = nil
    ) -> HTTPResponse {
        let payload = ErrorResponse(error: AutoSageError(code: code, message: message, details: details))
        return jsonResponse(payload, status: status)
    }

    private func waitForAsync<T>(_ operation: @escaping () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var value: T?
        Task {
            value = await operation()
            semaphore.signal()
        }
        semaphore.wait()
        return value!
    }
}
