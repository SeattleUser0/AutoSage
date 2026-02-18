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

    public init(registry: ToolRegistry = .default, idGenerator: RequestIDGenerator = RequestIDGenerator()) {
        self.registry = registry
        self.idGenerator = idGenerator
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
        default:
            let payload = ["error": "not_found", "message": "Unknown route."]
            return jsonResponse(payload, status: 404)
        }
    }

    private func handleResponses(_ request: HTTPRequest) -> HTTPResponse {
        guard let body = request.body else {
            return jsonResponse(["error": "invalid_request", "message": "Missing body."], status: 400)
        }
        do {
            let decoder = JSONDecoder()
            let req = try decoder.decode(ResponsesRequest.self, from: body)
            let model = req.model ?? "autosage-0.1"
            if let toolName = requestedToolName(from: req.toolChoice), let tool = registry.tool(named: toolName) {
                let result = tool.run(input: nil)
                let output: [ResponseOutputItem] = [
                    ResponseOutputItem(type: "tool_call", role: nil, content: nil, toolName: toolName, result: nil),
                    ResponseOutputItem(type: "tool_result", role: nil, content: nil, toolName: toolName, result: result)
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
            return jsonResponse(["error": "invalid_request", "message": "Failed to decode JSON."], status: 400)
        }
    }

    private func handleChatCompletions(_ request: HTTPRequest) -> HTTPResponse {
        guard let body = request.body else {
            return jsonResponse(["error": "invalid_request", "message": "Missing body."], status: 400)
        }
        do {
            let decoder = JSONDecoder()
            let req = try decoder.decode(ChatCompletionsRequest.self, from: body)
            let model = req.model ?? "autosage-0.1"
            if let toolName = requestedToolName(from: req.toolChoice), let tool = registry.tool(named: toolName) {
                let result = tool.run(input: nil)
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
                    toolResults: [result]
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
            return jsonResponse(["error": "invalid_request", "message": "Failed to decode JSON."], status: 400)
        }
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

    private func jsonResponse(_ value: [String: String], status: Int) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: data)
    }
}
