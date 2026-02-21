// SPDX-License-Identifier: MIT
// Deterministic demo tool for API and integration tests.

import Foundation

private struct EchoJSONInput: Codable, Equatable, Sendable {
    let message: String
    let n: Int?
}

public struct EchoJSONTool: Tool {
    public let name: String = "echo_json"
    public let version: String
    public let description: String
    public let jsonSchema: JSONValue = EchoJSONTool.schema

    public init(
        version: String = "1.0.0",
        description: String = "Echoes a message deterministically and optionally repeats it n times."
    ) {
        self.version = version
        self.description = description
    }

    public static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "message": .object([
                "type": .string("string"),
                "description": .string("Message to echo.")
            ]),
            "n": .object([
                "type": .string("integer"),
                "minimum": .number(1),
                "maximum": .number(64),
                "description": .string("Optional repeat count. Defaults to 1.")
            ])
        ]),
        "required": .stringArray(["message"]),
        "additionalProperties": .bool(false)
    ])

    public func run(input: JSONValue?, context: ToolExecutionContext) throws -> JSONValue {
        guard let input else {
            throw AutoSageError(code: "invalid_input", message: "echo_json requires an input object.")
        }
        guard case .object = input else {
            throw AutoSageError(code: "invalid_input", message: "echo_json input must be an object.")
        }

        let decoded = try JSONCoding.makeDecoder().decode(EchoJSONInput.self, from: JSONCoding.makeEncoder().encode(input))
        let message = decoded.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            throw AutoSageError(code: "invalid_input", message: "message must be a non-empty string.")
        }

        let repeatCount = max(1, min(decoded.n ?? 1, 64))
        let repeated = Array(repeating: message, count: repeatCount)
        let payload: JSONValue = .object([
            "message": .string(message),
            "repeat": .stringArray(repeated)
        ])

        let result = ToolExecutionResult(
            status: "ok",
            solver: name,
            summary: "Echoed message \(repeatCount) time(s).",
            stdout: "",
            stderr: "",
            exitCode: 0,
            artifacts: [],
            metrics: [
                "repeat_count": .number(Double(repeatCount)),
                "job_id": .string(context.jobID)
            ],
            output: payload
        )
        return try result.asJSONValue()
    }
}
