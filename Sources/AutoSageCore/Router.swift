import Foundation

public struct HTTPRequest {
    public let method: String
    public let path: String
    public let body: Data?
    public let headers: [String: String]

    public init(method: String, path: String, body: Data?, headers: [String: String] = [:]) {
        self.method = method
        self.path = path
        self.body = body
        self.headers = headers
    }
}

public typealias HTTPStreamHandler = (@escaping (Data) -> Void) -> Void

public struct HTTPResponse {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
    public let stream: HTTPStreamHandler?

    public init(status: Int, headers: [String: String] = [:], body: Data = Data(), stream: HTTPStreamHandler? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
        self.stream = stream
    }
}

public struct Router {
    public let registry: ToolRegistry
    public let idGenerator: RequestIDGenerator
    public let jobStore: JobStore
    public let sessionStore: SessionStore
    public let sessionOrchestrator: SessionOrchestrating

    public init(
        registry: ToolRegistry = .default,
        idGenerator: RequestIDGenerator = RequestIDGenerator(),
        jobStore: JobStore? = nil,
        sessionStore: SessionStore? = nil,
        sessionOrchestrator: SessionOrchestrating? = nil
    ) {
        self.registry = registry
        self.idGenerator = idGenerator
        self.jobStore = jobStore ?? JobStore(idGenerator: idGenerator)
        self.sessionStore = sessionStore ?? SessionStore()
        self.sessionOrchestrator = sessionOrchestrator ?? DefaultSessionOrchestrator()
    }

    public func handle(_ request: HTTPRequest) -> HTTPResponse {
        let routePath = pathWithoutQuery(request.path)
        switch (request.method, routePath) {
        case ("GET", "/healthz"):
            let response = HealthResponse(status: "ok", name: "AutoSage", version: "0.1.0")
            return jsonResponse(response)
        case ("GET", "/v1/tools"):
            return handleListTools(request)
        case ("GET", "/admin"):
            return htmlResponse(AdminDashboard.html)
        case ("GET", "/openapi.yaml"):
            return handleOpenAPISpec(filename: "openapi", fileExtension: "yaml", contentType: "application/yaml")
        case ("GET", "/openapi.json"):
            return handleOpenAPISpec(filename: "openapi", fileExtension: "json", contentType: "application/json")
        case ("GET", "/v1/agent/config"):
            return handleAgentConfig()
        case ("GET", "/v1/admin/logs"):
            return handleAdminLogs(request)
        case ("POST", "/v1/admin/clear-jobs"):
            return handleClearJobs()
        case ("POST", "/v1/sessions"):
            return handleCreateSession(request)
        case ("POST", "/v1/responses"):
            return handleResponses(request)
        case ("POST", "/v1/chat/completions"):
            return handleChatCompletions(request)
        case ("POST", "/v1/jobs"):
            return handleCreateJob(request)
        case ("POST", "/v1/tools/execute"):
            return handleExecuteTool(request)
        case ("POST", _):
            if routePath.hasPrefix("/v1/sessions/") {
                return handleSessionsPost(request, routePath: routePath)
            }
            return errorResponse(code: "not_found", message: "Unknown route.", status: 404)
        case ("GET", _):
            if routePath.hasPrefix("/v1/sessions/") {
                return handleSessionsGet(request, routePath: routePath)
            }
            if routePath.hasPrefix("/v1/jobs/") {
                return handleJobsGet(request)
            }
            return errorResponse(code: "not_found", message: "Unknown route.", status: 404)
        default:
            return errorResponse(code: "not_found", message: "Unknown route.", status: 404)
        }
    }

    private func handleAgentConfig() -> HTTPResponse {
        let payload = AgentOrchestratorBootstrap.makeConfig(registry: registry)
        return jsonResponse(payload)
    }

    private func handleOpenAPISpec(filename: String, fileExtension: String, contentType: String) -> HTTPResponse {
        let candidates: [(resource: String, ext: String, subdirectory: String?)] = [
            (filename, fileExtension, nil),
            (filename, fileExtension, "OpenAPI")
        ]
        for candidate in candidates {
            if let url = Bundle.module.url(
                forResource: candidate.resource,
                withExtension: candidate.ext,
                subdirectory: candidate.subdirectory
            ), let data = try? Data(contentsOf: url) {
                return HTTPResponse(
                    status: 200,
                    headers: [
                        "Content-Type": contentType,
                        "Cache-Control": "no-cache"
                    ],
                    body: data
                )
            }
        }
        return errorResponse(
            code: "not_found",
            message: "OpenAPI specification not found.",
            status: 404
        )
    }

    private func handleListTools(_ request: HTTPRequest) -> HTTPResponse {
        let query = queryParameters(request.path)
        let stabilityFilter: ToolStability?
        if let rawStability = query["stability"], !rawStability.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let parsed = ToolStability(rawValue: rawStability.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
                return errorResponse(
                    code: "invalid_request",
                    message: "Invalid stability query value.",
                    status: 400,
                    details: [
                        "field": .string("stability"),
                        "accepted": .stringArray(["stable", "experimental", "deprecated"])
                    ]
                )
            }
            stabilityFilter = parsed
        } else {
            stabilityFilter = nil
        }
        let tagsFilter = query["tags"]?
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []

        let descriptors = registry
            .listTools(stability: stabilityFilter, tags: tagsFilter)
            .map { entry in
                PublicToolDescriptor(
                    name: entry.tool.name,
                    version: entry.metadata.version,
                    stability: entry.metadata.stability,
                    tags: entry.metadata.tags.isEmpty ? nil : entry.metadata.tags,
                    description: entry.tool.description,
                    inputSchema: entry.tool.jsonSchema
                )
            }
        return jsonResponse(PublicToolsResponse(tools: descriptors))
    }

    private func handleExecuteTool(_ request: HTTPRequest) -> HTTPResponse {
        guard let body = request.body else {
            let result = Self.makeErrorToolResult(
                solver: "unknown",
                summary: "Tool execution request is missing a JSON body.",
                stderr: "Missing request body.",
                errorCode: "invalid_request"
            )
            return toolResultResponse(result, status: 400)
        }

        let parsed: ToolExecuteRequest
        do {
            parsed = try JSONCoding.makeDecoder().decode(ToolExecuteRequest.self, from: body)
        } catch {
            let result = Self.makeErrorToolResult(
                solver: "unknown",
                summary: "Tool execution request body is invalid JSON.",
                stderr: "Failed to decode request JSON.",
                errorCode: "invalid_request"
            )
            return toolResultResponse(result, status: 400)
        }

        let toolName = parsed.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !toolName.isEmpty else {
            let result = Self.makeErrorToolResult(
                solver: "unknown",
                summary: "tool must be a non-empty string.",
                stderr: "Missing required field: tool.",
                errorCode: "invalid_request"
            )
            return toolResultResponse(result, status: 400)
        }
        guard let tool = registry.tool(named: toolName) else {
            let result = Self.makeErrorToolResult(
                solver: toolName,
                summary: "Unsupported tool: \(toolName).",
                stderr: "Unsupported tool.",
                errorCode: "unknown_tool"
            )
            return toolResultResponse(result, status: 404)
        }

        let limits = parsed.context?.limits ?? .default
        let store = self.jobStore
        let job = waitForAsync { await store.createJob(toolName: toolName, input: parsed.input, requestBody: body) }
        waitForAsync { await store.startJob(id: job.id) }

        do {
            let rawResult = try Self.runToolForJob(
                tool: tool,
                input: parsed.input,
                jobID: job.id,
                jobStore: store,
                limits: limits
            )
            let normalized = try Self.normalizeToolResult(rawResult, fallbackSolver: toolName)
            let capped = Self.applyExecutionLimits(normalized, limits: limits)
            let value = try capped.asJSONValue()
            waitForAsync { await store.completeJob(id: job.id, result: value, summary: capped.summary) }

            let httpStatus = capped.status.lowercased() == "ok" ? 200 : 500
            return toolResultResponse(capped, status: httpStatus)
        } catch let error as AutoSageError {
            let status = error.code == "invalid_input" ? 400 : 500
            let result = Self.makeErrorToolResult(
                solver: toolName,
                summary: "Tool execution failed.",
                stderr: error.message,
                errorCode: error.code,
                metrics: ["job_id": .string(job.id)]
            )
            waitForAsync { await store.failJob(id: job.id, error: error) }
            return toolResultResponse(result, status: status)
        } catch {
            let result = Self.makeErrorToolResult(
                solver: toolName,
                summary: "Tool execution failed.",
                stderr: "Unexpected error during tool execution.",
                errorCode: "solver_failed",
                metrics: ["job_id": .string(job.id)]
            )
            waitForAsync {
                await store.failJob(
                    id: job.id,
                    error: AutoSageError(code: "solver_failed", message: "Unexpected error during tool execution.")
                )
            }
            return toolResultResponse(result, status: 500)
        }
    }

    private func handleAdminLogs(_ request: HTTPRequest) -> HTTPResponse {
        let query = queryParameters(request.path)
        let requestedLimit = query["limit"].flatMap { Int($0) } ?? 200
        let lines = waitForAsync { await sessionStore.recentAdminLogs(limit: requestedLimit) }
        return jsonResponse(AdminLogsResponse(lines: lines, count: lines.count, generatedAt: Date()))
    }

    private func handleClearJobs() -> HTTPResponse {
        do {
            let summary = try waitForAsyncThrowing {
                try await sessionStore.clearJobs()
            }
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let human = formatter.string(fromByteCount: summary.reclaimedBytes)
            let message = "Cleared \(summary.deletedJobs) session director\(summary.deletedJobs == 1 ? "y" : "ies"), reclaimed \(human)."
            let response = AdminClearJobsResponse(
                status: "ok",
                deletedJobs: summary.deletedJobs,
                reclaimedBytes: summary.reclaimedBytes,
                reclaimedHuman: human,
                sessionsRoot: summary.sessionsRoot,
                message: message,
                timestamp: Date()
            )
            return jsonResponse(response)
        } catch {
            return errorResponse(
                code: "admin_cleanup_failed",
                message: "Failed to clear session jobs.",
                status: 500
            )
        }
    }

    private func handleCreateSession(_ request: HTTPRequest) -> HTTPResponse {
        guard let body = request.body else {
            return errorResponse(
                code: "invalid_request",
                message: "Missing request body.",
                details: ["field": .string("body")]
            )
        }
        guard let contentType = request.headers["content-type"] else {
            return errorResponse(
                code: "invalid_request",
                message: "Missing Content-Type header.",
                details: ["field": .string("content-type")]
            )
        }

        do {
            let upload = try MultipartFormParser.parseFirstFile(data: body, contentType: contentType)
            let manifest = try waitForAsyncThrowing {
                try await sessionStore.createSession(
                    uploadFilename: upload.filename,
                    uploadData: upload.data,
                    uploadContentType: upload.contentType
                )
            }
            return jsonResponse(SessionCreateResponse(sessionID: manifest.sessionID, state: manifest))
        } catch let error as AutoSageError {
            return errorResponse(code: error.code, message: error.message, details: error.details)
        } catch {
            return errorResponse(
                code: "invalid_request",
                message: "Failed to parse multipart upload."
            )
        }
    }

    private func handleSessionsGet(_ request: HTTPRequest, routePath: String) -> HTTPResponse {
        let components = routePath.split(separator: "/")
        guard components.count >= 3, components[0] == "v1", components[1] == "sessions" else {
            return errorResponse(code: "not_found", message: "Unknown route.", status: 404)
        }

        if components.count == 3 {
            return handleGetSession(sessionID: String(components[2]))
        }

        if components.count >= 5, components[3] == "assets" {
            let decodedParts = components.dropFirst(4).map { part in
                String(part).removingPercentEncoding ?? String(part)
            }
            let assetPath = decodedParts.joined(separator: "/")
            return handleGetSessionAsset(sessionID: String(components[2]), assetPath: assetPath)
        }

        return errorResponse(code: "not_found", message: "Unknown route.", status: 404)
    }

    private func handleSessionsPost(_ request: HTTPRequest, routePath: String) -> HTTPResponse {
        let components = routePath.split(separator: "/")
        guard components.count == 4, components[0] == "v1", components[1] == "sessions", components[3] == "chat" else {
            return errorResponse(code: "not_found", message: "Unknown route.", status: 404)
        }
        return handleSessionChat(request, sessionID: String(components[2]))
    }

    private func handleGetSession(sessionID: String) -> HTTPResponse {
        do {
            guard let manifest = try waitForAsyncThrowing({ try await sessionStore.getSession(id: sessionID) }) else {
                return errorResponse(
                    code: "not_found",
                    message: "Session not found: \(sessionID).",
                    status: 404,
                    details: ["session_id": .string(sessionID)]
                )
            }
            return jsonResponse(manifest)
        } catch let error as AutoSageError {
            return errorResponse(code: error.code, message: error.message, details: error.details)
        } catch {
            return errorResponse(code: "invalid_request", message: "Failed to load session.")
        }
    }

    private func handleGetSessionAsset(sessionID: String, assetPath: String) -> HTTPResponse {
        do {
            guard let asset = try waitForAsyncThrowing({ try await sessionStore.readAsset(id: sessionID, assetPath: assetPath) }) else {
                return errorResponse(
                    code: "not_found",
                    message: "Asset not found: \(assetPath).",
                    status: 404,
                    details: [
                        "session_id": .string(sessionID),
                        "asset_path": .string(assetPath)
                    ]
                )
            }
            return HTTPResponse(status: 200, headers: ["Content-Type": asset.mimeType], body: asset.data)
        } catch let error as AutoSageError {
            return errorResponse(code: error.code, message: error.message, details: error.details)
        } catch {
            return errorResponse(code: "invalid_request", message: "Failed to read asset.")
        }
    }

    private func handleSessionChat(_ request: HTTPRequest, sessionID: String) -> HTTPResponse {
        guard let body = request.body else {
            return errorResponse(
                code: "invalid_request",
                message: "Missing request body.",
                details: ["field": .string("body")]
            )
        }

        do {
            let chatRequest = try JSONCoding.makeDecoder().decode(SessionChatRequest.self, from: body)
            let prompt = chatRequest.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else {
                return errorResponse(code: "invalid_request", message: "prompt must be a non-empty string.")
            }
            let wantsStream = chatRequest.stream == true
                || queryParameters(request.path)["stream"]?.lowercased() == "true"
                || queryParameters(request.path)["stream"] == "1"
                || request.headers["accept"]?.lowercased().contains("text/event-stream") == true

            if wantsStream {
                let headers = [
                    "Content-Type": "text/event-stream",
                    "Cache-Control": "no-cache",
                    "X-Accel-Buffering": "no"
                ]
                return HTTPResponse(status: 200, headers: headers, stream: { writer in
                    do {
                        let result = try self.waitForAsyncThrowing {
                            try await self.sessionOrchestrator.orchestrate(
                                sessionID: sessionID,
                                prompt: prompt,
                                sessionStore: self.sessionStore
                            )
                        }
                        for event in result.events {
                            writer(try self.sseData(for: event, sessionID: sessionID))
                        }
                        writer(self.sseData(event: "agent_done", payload: [
                            "status": .string("completed")
                        ]))
                    } catch let error as AutoSageError {
                        writer(self.sseData(event: "error", payload: [
                            "code": .string(error.code),
                            "message": .string(error.message)
                        ]))
                    } catch {
                        writer(self.sseData(event: "error", payload: [
                            "code": .string("internal_error"),
                            "message": .string("Session chat processing failed.")
                        ]))
                    }
                })
            }

            let result = try waitForAsyncThrowing {
                try await sessionOrchestrator.orchestrate(sessionID: sessionID, prompt: prompt, sessionStore: sessionStore)
            }
            let payload = SessionChatResponse(sessionID: sessionID, reply: result.reply, state: result.state)
            return jsonResponse(payload)
        } catch let error as AutoSageError {
            return errorResponse(code: error.code, message: error.message, details: error.details)
        } catch {
            return errorResponse(
                code: "invalid_request",
                message: "Invalid JSON body.",
                details: ["reason": .string("Failed to decode JSON.")]
            )
        }
    }

    private func pathWithoutQuery(_ path: String) -> String {
        String(path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    private func queryParameters(_ path: String) -> [String: String] {
        guard let query = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first else {
            return [:]
        }
        var values: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(pieces.first ?? "").removingPercentEncoding ?? String(pieces.first ?? "")
            guard !key.isEmpty else { continue }
            let value = pieces.count > 1 ? (String(pieces[1]).removingPercentEncoding ?? String(pieces[1])) : ""
            values[key] = value
        }
        return values
    }

    private func jsonValue<T: Encodable>(from value: T) throws -> JSONValue {
        let data = try JSONCoding.makeEncoder().encode(value)
        return try JSONCoding.makeDecoder().decode(JSONValue.self, from: data)
    }

    private func sseData(event: String, payload: [String: JSONValue]) -> Data {
        let payloadValue = JSONValue.object(payload)
        let data = (try? JSONCoding.makeEncoder().encode(payloadValue)) ?? Data("{}".utf8)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return Data("event: \(event)\ndata: \(json)\n\n".utf8)
    }

    private func sseData(for event: SessionStreamEvent, sessionID: String) throws -> Data {
        switch event {
        case .textDelta(let delta):
            return sseData(event: "text_delta", payload: [
                "delta": .string(delta)
            ])
        case .toolCallStart(let toolName):
            return sseData(event: "tool_call_start", payload: [
                "tool_name": .string(toolName)
            ])
        case .toolCallComplete(let toolName, let durationMS):
            return sseData(event: "tool_call_complete", payload: [
                "tool_name": .string(toolName),
                "duration_ms": .number(Double(durationMS))
            ])
        case .stateUpdate(let state):
            return sseData(event: "state_update", payload: [
                "session_id": .string(sessionID),
                "state": try jsonValue(from: state)
            ])
        }
    }

    private struct ToolInvocation {
        let name: String
        let input: JSONValue?
        let argumentsJSONString: String
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
            let req = try JSONCoding.makeDecoder().decode(ResponsesRequest.self, from: body)
            guard let model = nonEmptyModel(req.model) else {
                return errorResponse(
                    code: "invalid_request",
                    message: "Missing required field: model.",
                    details: ["field": .string("model")]
                )
            }
            if let invocation = try requestedToolInvocation(from: req.toolChoice) {
                guard let tool = registry.tool(named: invocation.name) else {
                    return errorResponse(
                        code: "unknown_tool",
                        message: "Unsupported tool: \(invocation.name).",
                        details: ["tool_name": .string(invocation.name)]
                    )
                }
                let execution = executeToolWithJob(tool: tool, toolName: invocation.name, input: invocation.input)
                let output: [ResponseOutputItem] = [
                    ResponseOutputItem(type: "tool_call", role: nil, content: nil, toolName: invocation.name, result: nil),
                    ResponseOutputItem(
                        type: "tool_result",
                        role: nil,
                        content: nil,
                        toolName: invocation.name,
                        result: execution.inlineResult ?? execution.jobReference
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
        } catch let error as AutoSageError {
            return errorResponse(code: error.code, message: error.message, details: error.details)
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
            let req = try JSONCoding.makeDecoder().decode(ChatCompletionsRequest.self, from: body)
            guard let model = nonEmptyModel(req.model) else {
                return errorResponse(
                    code: "invalid_request",
                    message: "Missing required field: model.",
                    details: ["field": .string("model")]
                )
            }
            if let invocation = try requestedToolInvocation(from: req.toolChoice) {
                guard let tool = registry.tool(named: invocation.name) else {
                    return errorResponse(
                        code: "unknown_tool",
                        message: "Unsupported tool: \(invocation.name).",
                        details: ["tool_name": .string(invocation.name)]
                    )
                }
                let execution = executeToolWithJob(tool: tool, toolName: invocation.name, input: invocation.input)
                let toolCall = ToolCall(
                    id: idGenerator.nextToolCallID(),
                    type: "function",
                    function: ToolCallFunction(name: invocation.name, arguments: invocation.argumentsJSONString)
                )
                let message = ChatCompletionMessage(role: "assistant", content: "", toolCalls: [toolCall])
                let choice = ChatChoice(index: 0, message: message, finishReason: "tool_calls")
                let response = ChatCompletionsResponse(
                    id: idGenerator.nextChatCompletionID(),
                    object: "chat.completion",
                    model: model,
                    choices: [choice],
                    toolResults: [execution.inlineResult ?? execution.jobReference]
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
        } catch let error as AutoSageError {
            return errorResponse(code: error.code, message: error.message, details: error.details)
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
            let req = try JSONCoding.makeDecoder().decode(CreateJobRequest.self, from: body)
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

            let limits = req.limits ?? .default
            let store = self.jobStore
            let job = waitForAsync { await store.createJob(toolName: toolName, input: req.input, requestBody: body) }
            startToolJob(tool: tool, input: req.input, jobID: job.id, limits: limits)

            let mode = req.mode ?? .async
            if mode == .sync {
                let waitMS = max(1, min(req.waitMS ?? 5_000, 120_000))
                if let finished = waitForJobCompletion(jobID: job.id, timeoutMS: waitMS) {
                    return jsonResponse(CreateJobResponse(jobID: job.id, status: finished.status, job: finished))
                }
                let status = waitForAsync { await store.getJob(id: job.id)?.status } ?? .queued
                return jsonResponse(CreateJobResponse(jobID: job.id, status: status))
            }

            return jsonResponse(CreateJobResponse(jobID: job.id, status: .queued))
        } catch let error as AutoSageError {
            return errorResponse(code: error.code, message: error.message, details: error.details)
        } catch {
            return errorResponse(
                code: "invalid_request",
                message: "Invalid JSON body.",
                details: ["reason": .string("Failed to decode JSON.")]
            )
        }
    }

    private func handleJobsGet(_ request: HTTPRequest) -> HTTPResponse {
        let components = request.path.split(separator: "/")
        guard components.count >= 3, components[0] == "v1", components[1] == "jobs" else {
            return errorResponse(code: "not_found", message: "Unknown route.", status: 404)
        }
        if components.count == 3 {
            return handleGetJob(jobID: String(components[2]))
        }
        if components.count == 4, components[3] == "artifacts" {
            return handleGetJobArtifacts(jobID: String(components[2]))
        }
        if components.count == 5, components[3] == "artifacts" {
            let encodedName = String(components[4])
            let decodedName = encodedName.removingPercentEncoding ?? encodedName
            return handleGetJobArtifact(jobID: String(components[2]), artifactName: decodedName)
        }
        return errorResponse(code: "not_found", message: "Unknown route.", status: 404)
    }

    private func handleGetJob(jobID: String) -> HTTPResponse {
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

    private func handleGetJobArtifacts(jobID: String) -> HTTPResponse {
        guard let files = waitForAsync({ await jobStore.listArtifacts(id: jobID) }) else {
            return errorResponse(
                code: "not_found",
                message: "Job not found: \(jobID).",
                status: 404,
                details: ["job_id": .string(jobID)]
            )
        }
        return jsonResponse(JobArtifactsResponse(jobID: jobID, files: files))
    }

    private func handleGetJobArtifact(jobID: String, artifactName: String) -> HTTPResponse {
        guard let artifact = waitForAsync({ await jobStore.readArtifact(id: jobID, name: artifactName) }) else {
            return errorResponse(
                code: "not_found",
                message: "Artifact not found: \(artifactName).",
                status: 404,
                details: [
                    "job_id": .string(jobID),
                    "artifact_name": .string(artifactName)
                ]
            )
        }
        return HTTPResponse(
            status: 200,
            headers: ["Content-Type": artifact.mimeType],
            body: artifact.data
        )
    }

    private func executeToolWithJob(tool: Tool, toolName: String, input: JSONValue?) -> (jobID: String, inlineResult: JSONValue?, jobReference: JSONValue) {
        let store = self.jobStore
        let job = waitForAsync { await store.createJob(toolName: toolName, input: input) }
        startToolJob(tool: tool, input: input, jobID: job.id, limits: .default)

        if let finished = waitForJobCompletion(jobID: job.id, timeoutMS: 500) {
            if finished.status == .succeeded {
                return (job.id, finished.result, jobReferenceResult(from: finished))
            }
            return (job.id, nil, jobReferenceResult(from: finished))
        }
        return (job.id, nil, jobReferenceResult(jobID: job.id, status: .running))
    }

    private func startToolJob(
        tool: Tool,
        input: JSONValue?,
        jobID: String,
        limits: ToolExecutionLimits
    ) {
        let store = self.jobStore
        Task.detached {
            await store.startJob(id: jobID)
            do {
                let result = try Self.runToolForJob(
                    tool: tool,
                    input: input,
                    jobID: jobID,
                    jobStore: store,
                    limits: limits
                )
                let normalized = try Self.normalizeToolResult(result, fallbackSolver: tool.name)
                let capped = Self.applyExecutionLimits(normalized, limits: limits)
                let cappedValue = try capped.asJSONValue()
                await store.completeJob(id: jobID, result: cappedValue, summary: capped.summary)
            } catch let error as AutoSageError {
                await store.failJob(id: jobID, error: error)
            } catch {
                await store.failJob(
                    id: jobID,
                    error: AutoSageError(code: "solver_failed", message: "Tool execution failed.")
                )
            }
        }
    }

    private static func runToolForJob(
        tool: Tool,
        input: JSONValue?,
        jobID: String,
        jobStore: JobStore,
        limits: ToolExecutionLimits
    ) throws -> JSONValue {
        let semaphore = DispatchSemaphore(value: 0)
        var directoryURL: URL?
        Task {
            directoryURL = await jobStore.jobDirectoryURL(id: jobID)
            semaphore.signal()
        }
        semaphore.wait()
        guard let jobDirectoryURL = directoryURL else {
            throw AutoSageError(code: "solver_failed", message: "Missing job directory for \(jobID).")
        }
        let context = ToolExecutionContext(jobID: jobID, jobDirectoryURL: jobDirectoryURL, limits: limits)
        return try tool.run(input: input, context: context)
    }

    private func requestedToolInvocation(from toolChoice: JSONValue?) throws -> ToolInvocation? {
        guard let toolChoice = toolChoice else { return nil }
        switch toolChoice {
        case .string(let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return ToolInvocation(name: trimmed, input: nil, argumentsJSONString: "{}")
        case .object(let dict):
            guard !isToolChoiceNone(dict) else { return nil }
            let name = toolName(from: dict)
            guard let name, !name.isEmpty else { return nil }
            let input = try toolInput(from: dict)
            return ToolInvocation(
                name: name,
                input: input,
                argumentsJSONString: try stringifyToolArguments(input)
            )
        default:
            throw AutoSageError(
                code: "invalid_request",
                message: "tool_choice must be a string or object."
            )
        }
    }

    private func isToolChoiceNone(_ dictionary: [String: JSONValue]) -> Bool {
        if case .string(let value)? = dictionary["type"] {
            return value.lowercased() == "none"
        }
        return false
    }

    private func toolName(from dictionary: [String: JSONValue]) -> String? {
        if case .string(let name)? = dictionary["name"] {
            return name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if case .object(let function)? = dictionary["function"],
           case .string(let name)? = function["name"] {
            return name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func toolInput(from dictionary: [String: JSONValue]) throws -> JSONValue? {
        if let direct = dictionary["input"] {
            return try normalizeToolInput(direct)
        }
        if let arguments = dictionary["arguments"] {
            return try normalizeToolInput(arguments)
        }
        if case .object(let function)? = dictionary["function"],
           let functionArguments = function["arguments"] {
            return try normalizeToolInput(functionArguments)
        }
        return nil
    }

    private func normalizeToolInput(_ value: JSONValue) throws -> JSONValue {
        switch value {
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return .object([:])
            }
            guard let data = trimmed.data(using: .utf8) else {
                throw AutoSageError(code: "invalid_request", message: "tool arguments must be valid UTF-8 JSON.")
            }
            do {
                let decoded = try JSONCoding.makeDecoder().decode(JSONValue.self, from: data)
                guard case .object = decoded else {
                    throw AutoSageError(code: "invalid_request", message: "tool arguments must decode to an object.")
                }
                return decoded
            } catch let error as AutoSageError {
                throw error
            } catch {
                throw AutoSageError(code: "invalid_request", message: "tool arguments string must contain valid JSON.")
            }
        case .object:
            return value
        default:
            throw AutoSageError(code: "invalid_request", message: "tool arguments must be an object.")
        }
    }

    private func stringifyToolArguments(_ input: JSONValue?) throws -> String {
        let value = input ?? .object([:])
        let data = try JSONCoding.makeEncoder().encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func jobReferenceResult(jobID: String, status: JobStatus) -> JSONValue {
        .object([
            "status": .string(status.rawValue),
            "job_id": .string(jobID)
        ])
    }

    private func jobReferenceResult(from job: JobRecord) -> JSONValue {
        var payload: [String: JSONValue] = [
            "status": .string(job.status.rawValue),
            "job_id": .string(job.id)
        ]
        if let error = job.error {
            payload["error"] = .object([
                "code": .string(error.code),
                "message": .string(error.message)
            ])
        }
        return .object(payload)
    }

    private func waitForJobCompletion(jobID: String, timeoutMS: Int) -> JobRecord? {
        let timeout = Date().addingTimeInterval(Double(timeoutMS) / 1_000.0)
        while Date() < timeout {
            if let job = waitForAsync({ await jobStore.getJob(id: jobID) }) {
                switch job.status {
                case .succeeded, .failed:
                    return job
                case .queued, .running:
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return nil
    }

    private static func normalizeToolResult(_ value: JSONValue, fallbackSolver: String) throws -> ToolExecutionResult {
        do {
            let data = try JSONCoding.makeEncoder().encode(value)
            var decoded = try JSONCoding.makeDecoder().decode(ToolExecutionResult.self, from: data)
            if decoded.solver.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                decoded = ToolExecutionResult(
                    status: decoded.status,
                    solver: fallbackSolver,
                    summary: decoded.summary,
                    stdout: decoded.stdout,
                    stderr: decoded.stderr,
                    exitCode: decoded.exitCode,
                    artifacts: decoded.artifacts,
                    metrics: decoded.metrics,
                    output: decoded.output
                )
            }
            return decoded
        } catch {
            throw AutoSageError(
                code: "invalid_tool_output",
                message: "Tool output could not be normalized to the ToolResult contract."
            )
        }
    }

    private static func applyExecutionLimits(_ result: ToolExecutionResult, limits: ToolExecutionLimits) -> ToolExecutionResult {
        let cappedStdout = truncateUTF8(result.stdout, maxBytes: limits.maxStdoutBytes)
        let cappedStderr = truncateUTF8(result.stderr, maxBytes: limits.maxStderrBytes)
        let cappedSummary = truncateCharacters(result.summary, maxCharacters: limits.maxSummaryCharacters)

        var artifacts = result.artifacts
        let oversized = artifacts.filter { $0.bytes > limits.maxArtifactBytes }
        if !oversized.isEmpty {
            artifacts.removeAll { $0.bytes > limits.maxArtifactBytes }
        }
        let droppedForCount = max(0, artifacts.count - limits.maxArtifacts)
        if droppedForCount > 0 {
            artifacts = Array(artifacts.prefix(limits.maxArtifacts))
        }

        var metrics = result.metrics
        if cappedStdout.truncatedBytes > 0 {
            metrics["stdout_truncated_bytes"] = .number(Double(cappedStdout.truncatedBytes))
        }
        if cappedStderr.truncatedBytes > 0 {
            metrics["stderr_truncated_bytes"] = .number(Double(cappedStderr.truncatedBytes))
        }
        if cappedSummary.wasTruncated {
            metrics["summary_truncated"] = .bool(true)
        }
        if !oversized.isEmpty {
            metrics["artifacts_removed_oversize"] = .number(Double(oversized.count))
        }
        if droppedForCount > 0 {
            metrics["artifacts_removed_count_cap"] = .number(Double(droppedForCount))
        }

        var summary = cappedSummary.value
        let truncationNotes = [
            cappedStdout.truncatedBytes > 0 ? "stdout truncated" : nil,
            cappedStderr.truncatedBytes > 0 ? "stderr truncated" : nil,
            cappedSummary.wasTruncated ? "summary truncated" : nil,
            !oversized.isEmpty ? "oversize artifacts removed" : nil,
            droppedForCount > 0 ? "artifact count capped" : nil
        ].compactMap { $0 }
        if !truncationNotes.isEmpty {
            let note = " [limits: \(truncationNotes.joined(separator: ", "))]"
            let combined = summary + note
            summary = truncateCharacters(combined, maxCharacters: limits.maxSummaryCharacters).value
        }

        return ToolExecutionResult(
            status: result.status,
            solver: result.solver,
            summary: summary,
            stdout: cappedStdout.value,
            stderr: cappedStderr.value,
            exitCode: result.exitCode,
            artifacts: artifacts,
            metrics: metrics,
            output: result.output
        )
    }

    private static func makeErrorToolResult(
        solver: String,
        summary: String,
        stderr: String,
        errorCode: String,
        metrics: [String: JSONValue] = [:]
    ) -> ToolExecutionResult {
        var mergedMetrics = metrics
        mergedMetrics["error_code"] = .string(errorCode)
        return ToolExecutionResult(
            status: "error",
            solver: solver,
            summary: summary,
            stdout: "",
            stderr: stderr,
            exitCode: 1,
            artifacts: [],
            metrics: mergedMetrics,
            output: nil
        )
    }

    private func toolResultResponse(_ result: ToolExecutionResult, status: Int) -> HTTPResponse {
        jsonResponse(result, status: status)
    }

    private static func truncateUTF8(_ value: String, maxBytes: Int) -> (value: String, truncatedBytes: Int) {
        let bytes = Array(value.utf8)
        guard bytes.count > maxBytes else {
            return (value, 0)
        }

        var prefix = Array(bytes.prefix(maxBytes))
        while !prefix.isEmpty, String(data: Data(prefix), encoding: .utf8) == nil {
            prefix.removeLast()
        }
        let truncated = String(data: Data(prefix), encoding: .utf8) ?? ""
        return (truncated, bytes.count - prefix.count)
    }

    private static func truncateCharacters(_ value: String, maxCharacters: Int) -> (value: String, wasTruncated: Bool) {
        guard value.count > maxCharacters else { return (value, false) }
        let prefix = String(value.prefix(max(0, maxCharacters - 3)))
        return (prefix + "...", true)
    }

    private func nonEmptyModel(_ model: String?) -> String? {
        guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else {
            return nil
        }
        return model
    }

    private func jsonResponse<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let encoder = JSONCoding.makeEncoder()
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

    private func htmlResponse(_ html: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: ["Content-Type": "text/html; charset=utf-8"],
            body: Data(html.utf8)
        )
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

    private func waitForAsyncThrowing<T>(_ operation: @escaping () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var value: T?
        var thrownError: Error?
        Task {
            do {
                value = try await operation()
            } catch {
                thrownError = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let thrownError {
            throw thrownError
        }
        return value!
    }
}
