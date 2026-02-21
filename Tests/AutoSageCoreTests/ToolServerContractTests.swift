import Foundation
import XCTest
@testable import AutoSageCore

private struct NoisyTool: Tool {
    let name: String = "noisy.tool"
    let version: String = "1.0.0"
    let description: String = "Emits long stdout/stderr for limit tests."
    let jsonSchema: JSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false)
    ])

    func run(input: JSONValue?, context: ToolExecutionContext) throws -> JSONValue {
        _ = input
        let result = ToolExecutionResult(
            status: "ok",
            solver: name,
            summary: "Noisy output for truncation testing.",
            stdout: String(repeating: "stdout-", count: 32),
            stderr: String(repeating: "stderr-", count: 24),
            exitCode: 0,
            artifacts: [],
            metrics: ["job_id": .string(context.jobID)],
            output: .object(["ok": .bool(true)])
        )
        return try result.asJSONValue()
    }
}

final class ToolServerContractTests: XCTestCase {
    private func decodeToolResult(from value: JSONValue) throws -> ToolExecutionResult {
        let data = try JSONCoding.makeEncoder().encode(value)
        return try JSONCoding.makeDecoder().decode(ToolExecutionResult.self, from: data)
    }

    func testToolExecutionResultRoundTripJSON() throws {
        let result = ToolExecutionResult(
            status: "ok",
            solver: "echo_json",
            summary: "Echoed message 2 time(s).",
            stdout: "",
            stderr: "",
            exitCode: 0,
            artifacts: [
                ToolArtifact(
                    name: "note.txt",
                    path: "/v1/jobs/job_0001/artifacts/note.txt",
                    mimeType: "text/plain; charset=utf-8",
                    bytes: 4
                )
            ],
            metrics: [
                "elapsed_ms": .number(1),
                "deterministic": .bool(true)
            ],
            output: .object([
                "message": .string("hi"),
                "repeat": .stringArray(["hi", "hi"])
            ])
        )

        let data = try JSONCoding.makeEncoder().encode(result)
        let decoded = try JSONCoding.makeDecoder().decode(ToolExecutionResult.self, from: data)
        XCTAssertEqual(decoded, result)
    }

    func testEchoJSONToolIsDeterministic() throws {
        let fileManager = FileManager.default
        let jobDir = fileManager.temporaryDirectory
            .appendingPathComponent("autosage-echo-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: jobDir) }
        try fileManager.createDirectory(at: jobDir, withIntermediateDirectories: true, attributes: nil)

        let tool = EchoJSONTool()
        let input: JSONValue = .object([
            "message": .string("ping"),
            "n": .number(3)
        ])
        let context = ToolExecutionContext(jobID: "job_echo", jobDirectoryURL: jobDir)

        let first = try tool.run(input: input, context: context)
        let second = try tool.run(input: input, context: context)
        XCTAssertEqual(first, second)

        let decoded = try decodeToolResult(from: first)
        XCTAssertEqual(decoded.status, "ok")
        XCTAssertEqual(decoded.solver, "echo_json")
        XCTAssertEqual(decoded.stdout, "")
        XCTAssertEqual(decoded.stderr, "")
        XCTAssertEqual(decoded.exitCode, 0)
        XCTAssertEqual(decoded.summary, "Echoed message 3 time(s).")

        guard case .object(let output)? = decoded.output else {
            return XCTFail("Expected output object in echo_json result.")
        }
        XCTAssertEqual(output["message"], .string("ping"))
        XCTAssertEqual(output["repeat"], .stringArray(["ping", "ping", "ping"]))
    }

    func testExecuteEndpointAppliesStdoutStderrCapsAndReportsTruncation() throws {
        let registry = ToolRegistry(tools: [NoisyTool()])
        let router = Router(registry: registry)
        let body = Data(
            """
            {
              "tool": "noisy.tool",
              "input": {},
              "context": {
                "limits": {
                  "timeout_ms": 2000,
                  "max_stdout_bytes": 32,
                  "max_stderr_bytes": 24,
                  "max_artifact_bytes": 4096,
                  "max_artifacts": 4,
                  "max_summary_characters": 96
                }
              }
            }
            """.utf8
        )

        let response = router.handle(
            HTTPRequest(
                method: "POST",
                path: "/v1/tools/execute",
                body: body,
                headers: ["content-type": "application/json"]
            )
        )

        XCTAssertEqual(response.status, 200)
        let decoded = try JSONCoding.makeDecoder().decode(ToolExecutionResult.self, from: response.body)
        XCTAssertEqual(decoded.status, "ok")
        XCTAssertEqual(decoded.solver, "noisy.tool")
        XCTAssertLessThanOrEqual(decoded.stdout.utf8.count, 32)
        XCTAssertLessThanOrEqual(decoded.stderr.utf8.count, 24)

        guard case .number(let stdoutTruncated)? = decoded.metrics["stdout_truncated_bytes"] else {
            return XCTFail("stdout_truncated_bytes metric missing.")
        }
        guard case .number(let stderrTruncated)? = decoded.metrics["stderr_truncated_bytes"] else {
            return XCTFail("stderr_truncated_bytes metric missing.")
        }
        XCTAssertGreaterThan(stdoutTruncated, 0)
        XCTAssertGreaterThan(stderrTruncated, 0)
        XCTAssertTrue(decoded.summary.contains("limits:"))
    }
}
