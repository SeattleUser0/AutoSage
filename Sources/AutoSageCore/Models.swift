import Foundation

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

public struct ToolSpec: Codable, Equatable {
    public let type: String?
    public let function: ToolFunction?

    public init(type: String?, function: ToolFunction?) {
        self.type = type
        self.function = function
    }
}

public struct ToolFunction: Codable, Equatable {
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
