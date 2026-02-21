// SPDX-License-Identifier: MIT
// Deterministic artifact-producing demo tool.

import Foundation

private struct WriteTextArtifactInput: Codable, Equatable, Sendable {
    let text: String
    let filename: String?
}

public struct WriteTextArtifactTool: Tool {
    public let name: String = "write_text_artifact"
    public let version: String
    public let description: String
    public let jsonSchema: JSONValue = WriteTextArtifactTool.schema

    public init(
        version: String = "1.0.0",
        description: String = "Writes a small UTF-8 text file into the per-job artifact directory and returns its metadata."
    ) {
        self.version = version
        self.description = description
    }

    public static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "text": .object([
                "type": .string("string"),
                "description": .string("Text content to persist as an artifact.")
            ]),
            "filename": .object([
                "type": .string("string"),
                "description": .string("Optional artifact filename. Defaults to note.txt.")
            ])
        ]),
        "required": .stringArray(["text"]),
        "additionalProperties": .bool(false)
    ])

    public func run(input: JSONValue?, context: ToolExecutionContext) throws -> JSONValue {
        guard let input else {
            throw AutoSageError(code: "invalid_input", message: "write_text_artifact requires an input object.")
        }
        guard case .object = input else {
            throw AutoSageError(code: "invalid_input", message: "write_text_artifact input must be an object.")
        }

        let decoded = try JSONCoding.makeDecoder().decode(
            WriteTextArtifactInput.self,
            from: JSONCoding.makeEncoder().encode(input)
        )

        let filename = sanitizedFilename(decoded.filename ?? "note.txt")
        let data = Data(decoded.text.utf8)
        if data.count > context.limits.maxArtifactBytes {
            throw AutoSageError(
                code: "invalid_input",
                message: "text exceeds max artifact size limit (\(context.limits.maxArtifactBytes) bytes)."
            )
        }

        let artifactURL = context.jobDirectoryURL.appendingPathComponent(filename, isDirectory: false)
        try FileManager.default.createDirectory(
            at: context.jobDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try data.write(to: artifactURL, options: .atomic)

        let routeName = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
        let artifact = ToolArtifact(
            name: filename,
            path: "/v1/jobs/\(context.jobID)/artifacts/\(routeName)",
            mimeType: "text/plain; charset=utf-8",
            bytes: data.count
        )

        let result = ToolExecutionResult(
            status: "ok",
            solver: name,
            summary: "Wrote text artifact \(filename) (\(data.count) bytes).",
            stdout: "",
            stderr: "",
            exitCode: 0,
            artifacts: [artifact],
            metrics: [
                "artifact_bytes": .number(Double(data.count)),
                "job_id": .string(context.jobID)
            ],
            output: .object([
                "filename": .string(filename),
                "bytes": .number(Double(data.count))
            ])
        )
        return try result.asJSONValue()
    }

    private func sanitizedFilename(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "note.txt" }
        if trimmed.contains("/") || trimmed.contains("\\") || trimmed.contains("..") {
            return "note.txt"
        }
        return URL(fileURLWithPath: trimmed).lastPathComponent
    }
}
