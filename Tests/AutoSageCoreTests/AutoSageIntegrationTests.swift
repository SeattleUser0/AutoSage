import Foundation
import XCTest
@testable import AutoSageCore

private struct LLMToolCallPlan: Sendable {
    let toolName: String
    let stage: String
    let assetPath: String
    let assetContents: String
    let durationMS: Int
}

private struct LLMCompletionPlan: Sendable {
    let acknowledgement: String
    let toolCalls: [LLMToolCallPlan]
}

private protocol LLMClient: Sendable {
    func complete(sessionID: String, prompt: String) async throws -> LLMCompletionPlan
}

private struct MockLLMClient: LLMClient {
    let plan: LLMCompletionPlan

    func complete(sessionID: String, prompt: String) async throws -> LLMCompletionPlan {
        _ = sessionID
        _ = prompt
        return plan
    }
}

private struct MockLLMSessionOrchestrator: SessionOrchestrating {
    let llmClient: any LLMClient

    func orchestrate(sessionID: String, prompt: String, sessionStore: SessionStore) async throws -> SessionOrchestratorResult {
        _ = try await sessionStore.appendUserPrompt(id: sessionID, prompt: prompt)

        let plan = try await llmClient.complete(sessionID: sessionID, prompt: prompt)
        let workspaceURL = try await sessionStore.workspaceURLForSession(id: sessionID)
        let fileManager = FileManager.default

        var events: [SessionStreamEvent] = []
        events.append(.textDelta(delta: plan.acknowledgement))

        for step in plan.toolCalls {
            events.append(.toolCallStart(toolName: step.toolName))

            let assetURL = workspaceURL.appendingPathComponent(step.assetPath)
            try fileManager.createDirectory(
                at: assetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try Data(step.assetContents.utf8).write(to: assetURL, options: .atomic)

            let state = try await sessionStore.applyStateTransition(
                id: sessionID,
                status: "processing",
                stage: step.stage,
                plannedTool: step.toolName,
                assistantMessage: "Executed \(step.toolName).",
                appendAssets: [step.assetPath]
            )
            events.append(.stateUpdate(state: state))
            events.append(.toolCallComplete(toolName: step.toolName, durationMS: step.durationMS))
        }

        let finalStage = plan.toolCalls.last?.stage ?? "chat"
        let finalState = try await sessionStore.applyStateTransition(
            id: sessionID,
            status: "idle",
            stage: finalStage,
            plannedTool: nil,
            assistantMessage: "Pipeline complete.",
            appendAssets: []
        )

        return SessionOrchestratorResult(
            reply: "Completed \(plan.toolCalls.count) deterministic tool call(s).",
            state: finalState,
            events: events
        )
    }
}

private struct SSEEventRecord {
    let name: String
    let payload: [String: JSONValue]
}

private func multipartBody(boundary: String, filename: String, contentType: String, content: String) -> Data {
    let body = """
    --\(boundary)\r
    Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r
    Content-Type: \(contentType)\r
    \r
    \(content)\r
    --\(boundary)--\r
    """
    return Data(body.utf8)
}

private func parseSSEEvents(from data: Data) throws -> [SSEEventRecord] {
    guard let text = String(data: data, encoding: .utf8) else {
        throw AutoSageError(code: "invalid_test_data", message: "SSE stream was not UTF-8 text.")
    }

    var events: [SSEEventRecord] = []
    for block in text.components(separatedBy: "\n\n") {
        let trimmedBlock = block.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBlock.isEmpty {
            continue
        }

        var eventName = "message"
        var dataLines: [String] = []

        for line in trimmedBlock.components(separatedBy: "\n") {
            if line.hasPrefix("event:") {
                eventName = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces))
            }
        }

        if dataLines.isEmpty {
            continue
        }

        let payloadText = dataLines.joined(separator: "\n")
        let payloadData = Data(payloadText.utf8)
        let payloadValue = try JSONCoding.makeDecoder().decode(JSONValue.self, from: payloadData)
        guard case .object(let objectPayload) = payloadValue else {
            throw AutoSageError(code: "invalid_test_data", message: "SSE payload was not a JSON object.")
        }
        events.append(SSEEventRecord(name: eventName, payload: objectPayload))
    }

    return events
}

private func decodeManifest(from payload: [String: JSONValue]) throws -> SessionManifest {
    guard let stateValue = payload["state"] else {
        throw AutoSageError(code: "invalid_test_data", message: "SSE state_update payload missing 'state'.")
    }
    let data = try JSONCoding.makeEncoder().encode(stateValue)
    return try JSONCoding.makeDecoder().decode(SessionManifest.self, from: data)
}

final class AutoSageIntegrationTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        let fileManager = FileManager.default
        for directory in tempDirectories.reversed() {
            if fileManager.fileExists(atPath: directory.path) {
                try? fileManager.removeItem(at: directory)
            }
        }
        tempDirectories.removeAll()
        try super.tearDownWithError()
    }

    private func makeTempBase(prefix: String) throws -> URL {
        let fileManager = FileManager.default
        let url = fileManager.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        tempDirectories.append(url)
        return url
    }

    private func loadFixtureOBJ(named name: String) throws -> String {
        let fixtureURL =
            Bundle.module.url(forResource: name, withExtension: "obj")
            ?? Bundle.module.url(forResource: name, withExtension: "obj", subdirectory: "Fixtures")

        guard let fixtureURL else {
            let topLevel = (Bundle.module.urls(forResourcesWithExtension: "obj", subdirectory: nil) ?? [])
                .map(\.lastPathComponent)
                .sorted()
            let fixturesSubdir = (Bundle.module.urls(forResourcesWithExtension: "obj", subdirectory: "Fixtures") ?? [])
                .map(\.lastPathComponent)
                .sorted()
            throw AutoSageError(
                code: "invalid_test_data",
                message: "Fixture not found: \(name).obj. obj@root=\(topLevel), obj@Fixtures=\(fixturesSubdir)"
            )
        }
        return try String(contentsOf: fixtureURL, encoding: .utf8)
    }

    func testSessionCreationEndpointCreatesWorkspaceFromUploadedOBJ() throws {
        let fileManager = FileManager.default
        let tempBase = try makeTempBase(prefix: "autosage-integration-create")

        let store = SessionStore(baseURL: tempBase, fileManager: fileManager)
        let router = Router(sessionStore: store)
        let cubeOBJ = try loadFixtureOBJ(named: "cube")

        let boundary = "autosage-integration-boundary-\(UUID().uuidString)"
        let request = HTTPRequest(
            method: "POST",
            path: "/v1/sessions",
            body: multipartBody(boundary: boundary, filename: "cube.obj", contentType: "text/plain", content: cubeOBJ),
            headers: ["content-type": "multipart/form-data; boundary=\(boundary)"]
        )

        let response = router.handle(request)
        XCTAssertEqual(response.status, 200)

        let created = try JSONCoding.makeDecoder().decode(SessionCreateResponse.self, from: response.body)
        XCTAssertTrue(created.sessionID.hasPrefix("session_"))
        XCTAssertEqual(created.state.assets, ["input/cube.obj"])

        let workspaceURL = tempBase.appendingPathComponent(created.sessionID, isDirectory: true)
        let manifestURL = workspaceURL.appendingPathComponent("manifest.json")
        XCTAssertTrue(fileManager.fileExists(atPath: manifestURL.path))

        for directory in ["input", "geometry", "mesh", "solve", "render", "logs"] {
            let directoryURL = workspaceURL.appendingPathComponent(directory, isDirectory: true)
            var isDirectory: ObjCBool = false
            XCTAssertTrue(fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
        }

        let uploaded = workspaceURL.appendingPathComponent("input/cube.obj")
        XCTAssertTrue(fileManager.fileExists(atPath: uploaded.path))

        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONCoding.makeDecoder().decode(SessionManifest.self, from: manifestData)
        XCTAssertEqual(manifest.sessionID, created.sessionID)
        XCTAssertEqual(manifest.stage, "created")
    }

    func testSessionChatStreamEmitsDeterministicToolExecutionSequence() throws {
        let fileManager = FileManager.default
        let tempBase = try makeTempBase(prefix: "autosage-integration-stream")

        let llmPlan = LLMCompletionPlan(
            acknowledgement: "Acknowledged request. Running deterministic tools.",
            toolCalls: [
                LLMToolCallPlan(
                    toolName: "dsl_fit_open3d",
                    stage: "geometry_fit",
                    assetPath: "geometry/primitives.json",
                    assetContents: "{\"primitives\":[]}",
                    durationMS: 8
                ),
                LLMToolCallPlan(
                    toolName: "render_pack_vtk",
                    stage: "render",
                    assetPath: "render/isometric_color.png",
                    assetContents: "PNG",
                    durationMS: 11
                )
            ]
        )

        let orchestrator = MockLLMSessionOrchestrator(llmClient: MockLLMClient(plan: llmPlan))
        let store = SessionStore(baseURL: tempBase, fileManager: fileManager)
        let router = Router(sessionStore: store, sessionOrchestrator: orchestrator)

        let initialMesh = try loadFixtureOBJ(named: "cube")
        let createBoundary = "autosage-stream-create-\(UUID().uuidString)"
        let createResponse = router.handle(
            HTTPRequest(
                method: "POST",
                path: "/v1/sessions",
                body: multipartBody(boundary: createBoundary, filename: "input.obj", contentType: "text/plain", content: initialMesh),
                headers: ["content-type": "multipart/form-data; boundary=\(createBoundary)"]
            )
        )
        XCTAssertEqual(createResponse.status, 200)
        let created = try JSONCoding.makeDecoder().decode(SessionCreateResponse.self, from: createResponse.body)

        let chatRequestBody = Data(#"{"prompt":"Analyze geometry and render preview.","stream":true}"#.utf8)
        let streamResponse = router.handle(
            HTTPRequest(
                method: "POST",
                path: "/v1/sessions/\(created.sessionID)/chat?stream=true",
                body: chatRequestBody,
                headers: [
                    "content-type": "application/json",
                    "accept": "text/event-stream"
                ]
            )
        )

        XCTAssertEqual(streamResponse.status, 200)
        XCTAssertEqual(streamResponse.headers["Content-Type"], "text/event-stream")
        XCTAssertNotNil(streamResponse.stream)

        var streamed = Data()
        streamResponse.stream? { chunk in
            streamed.append(chunk)
        }
        XCTAssertFalse(streamed.isEmpty)

        let events = try parseSSEEvents(from: streamed)
        let eventNames = events.map { $0.name }
        XCTAssertEqual(
            eventNames,
            [
                "text_delta",
                "tool_call_start",
                "state_update",
                "tool_call_complete",
                "tool_call_start",
                "state_update",
                "tool_call_complete",
                "agent_done"
            ]
        )

        XCTAssertEqual(events[0].payload["delta"], .string(llmPlan.acknowledgement))
        XCTAssertEqual(events[1].payload["tool_name"], .string("dsl_fit_open3d"))
        XCTAssertEqual(events[3].payload["tool_name"], .string("dsl_fit_open3d"))
        XCTAssertEqual(events[3].payload["duration_ms"], .number(8))

        let firstState = try decodeManifest(from: events[2].payload)
        XCTAssertTrue(firstState.assets.contains("geometry/primitives.json"))

        XCTAssertEqual(events[4].payload["tool_name"], .string("render_pack_vtk"))
        XCTAssertEqual(events[6].payload["tool_name"], .string("render_pack_vtk"))
        XCTAssertEqual(events[6].payload["duration_ms"], .number(11))

        let secondState = try decodeManifest(from: events[5].payload)
        XCTAssertTrue(secondState.assets.contains("geometry/primitives.json"))
        XCTAssertTrue(secondState.assets.contains("render/isometric_color.png"))

        XCTAssertEqual(events[7].payload["status"], .string("completed"))

        let finalManifestResponse = router.handle(
            HTTPRequest(method: "GET", path: "/v1/sessions/\(created.sessionID)", body: nil)
        )
        XCTAssertEqual(finalManifestResponse.status, 200)
        let finalManifest = try JSONCoding.makeDecoder().decode(SessionManifest.self, from: finalManifestResponse.body)
        XCTAssertEqual(finalManifest.status, "idle")
        XCTAssertEqual(finalManifest.stage, "render")
        XCTAssertNil(finalManifest.plannedTool)
        XCTAssertTrue(finalManifest.assets.contains("geometry/primitives.json"))
        XCTAssertTrue(finalManifest.assets.contains("render/isometric_color.png"))

        let renderedAssetResponse = router.handle(
            HTTPRequest(
                method: "GET",
                path: "/v1/sessions/\(created.sessionID)/assets/render/isometric_color.png",
                body: nil
            )
        )
        XCTAssertEqual(renderedAssetResponse.status, 200)
        XCTAssertEqual(renderedAssetResponse.headers["Content-Type"], "image/png")
        XCTAssertEqual(String(data: renderedAssetResponse.body, encoding: .utf8), "PNG")
    }

    func testPublicToolContractEndpointsHealthListAndExecute() throws {
        let router = Router()

        let healthz = router.handle(HTTPRequest(method: "GET", path: "/healthz", body: nil))
        XCTAssertEqual(healthz.status, 200)
        let health = try JSONCoding.makeDecoder().decode(HealthResponse.self, from: healthz.body)
        XCTAssertEqual(health.status, "ok")
        XCTAssertFalse(health.version.isEmpty)

        let toolsResponse = router.handle(HTTPRequest(method: "GET", path: "/v1/tools", body: nil))
        XCTAssertEqual(toolsResponse.status, 200)
        let tools = try JSONCoding.makeDecoder().decode(PublicToolsResponse.self, from: toolsResponse.body)
        XCTAssertFalse(tools.tools.isEmpty)
        XCTAssertEqual(tools.tools.map(\.name), tools.tools.map(\.name).sorted())
        for descriptor in tools.tools {
            XCTAssertFalse(descriptor.version.isEmpty)
            XCTAssertTrue(["stable", "experimental", "deprecated"].contains(descriptor.stability.rawValue))
        }
        guard let echo = tools.tools.first(where: { $0.name == "echo_json" }) else {
            return XCTFail("echo_json not found in /v1/tools output.")
        }
        XCTAssertFalse(echo.description.isEmpty)
        XCTAssertEqual(echo.stability, .stable)
        XCTAssertFalse((echo.examples ?? []).isEmpty)
        if let firstExample = echo.examples?.first {
            XCTAssertFalse(firstExample.title.isEmpty)
            guard case .object(let exampleInput) = firstExample.input else {
                return XCTFail("echo_json example input should be a JSON object.")
            }
            XCTAssertEqual(exampleInput["message"], .string("hello"))
        }
        guard case .object = echo.inputSchema else {
            return XCTFail("echo_json input_schema should be an object.")
        }

        let executeBody = Data(
            """
            {
              "tool": "echo_json",
              "input": {
                "message": "hello",
                "n": 2
              }
            }
            """.utf8
        )
        let executeResponse = router.handle(
            HTTPRequest(
                method: "POST",
                path: "/v1/tools/execute",
                body: executeBody,
                headers: ["content-type": "application/json"]
            )
        )
        XCTAssertEqual(executeResponse.status, 200)

        let toolResult = try JSONCoding.makeDecoder().decode(ToolExecutionResult.self, from: executeResponse.body)
        XCTAssertEqual(toolResult.status, "ok")
        XCTAssertEqual(toolResult.solver, "echo_json")
        XCTAssertEqual(toolResult.exitCode, 0)
        XCTAssertEqual(toolResult.stdout, "")
        XCTAssertEqual(toolResult.stderr, "")
        XCTAssertNotNil(toolResult.output)

        guard case .object(let output)? = toolResult.output else {
            return XCTFail("Expected output object from echo_json execution.")
        }
        XCTAssertEqual(output["message"], .string("hello"))
        XCTAssertEqual(output["repeat"], .stringArray(["hello", "hello"]))
    }

    func testToolsEndpointSupportsStabilityAndTagFiltering() throws {
        let router = Router()

        let stableResponse = router.handle(HTTPRequest(method: "GET", path: "/v1/tools?stability=stable", body: nil))
        XCTAssertEqual(stableResponse.status, 200)
        let stableTools = try JSONCoding.makeDecoder().decode(PublicToolsResponse.self, from: stableResponse.body)
        let stableNames = stableTools.tools.map(\.name)
        XCTAssertEqual(stableNames, ["echo_json", "write_text_artifact"])
        for tool in stableTools.tools {
            XCTAssertEqual(tool.stability, .stable)
            XCTAssertFalse((tool.examples ?? []).isEmpty)
        }

        let taggedResponse = router.handle(HTTPRequest(method: "GET", path: "/v1/tools?tags=artifact,pde", body: nil))
        XCTAssertEqual(taggedResponse.status, 200)
        let taggedTools = try JSONCoding.makeDecoder().decode(PublicToolsResponse.self, from: taggedResponse.body)
        XCTAssertTrue(taggedTools.tools.contains(where: { $0.name == "write_text_artifact" }))
        XCTAssertTrue(taggedTools.tools.contains(where: { $0.tags?.contains("pde") == true }))
        XCTAssertEqual(taggedTools.tools.map(\.name), taggedTools.tools.map(\.name).sorted())
    }

    func testOpenAPISpecEndpointsExposeRequiredPaths() throws {
        let router = Router()

        let yamlResponse = router.handle(HTTPRequest(method: "GET", path: "/openapi.yaml", body: nil))
        XCTAssertEqual(yamlResponse.status, 200)
        XCTAssertEqual(yamlResponse.headers["Content-Type"], "application/yaml")
        XCTAssertEqual(yamlResponse.headers["Cache-Control"], "no-cache")
        let yamlText = try XCTUnwrap(String(data: yamlResponse.body, encoding: .utf8))
        XCTAssertTrue(yamlText.contains("openapi: 3."))

        let jsonResponse = router.handle(HTTPRequest(method: "GET", path: "/openapi.json", body: nil))
        XCTAssertEqual(jsonResponse.status, 200)
        XCTAssertEqual(jsonResponse.headers["Content-Type"], "application/json")
        XCTAssertEqual(jsonResponse.headers["Cache-Control"], "no-cache")

        let jsonObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: jsonResponse.body, options: []) as? [String: Any]
        )
        XCTAssertNotNil(jsonObject["openapi"])

        let paths = try XCTUnwrap(jsonObject["paths"] as? [String: Any])
        let healthz = try XCTUnwrap(paths["/healthz"] as? [String: Any])
        XCTAssertNotNil(healthz["get"])
        let tools = try XCTUnwrap(paths["/v1/tools"] as? [String: Any])
        XCTAssertNotNil(tools["get"])
        let execute = try XCTUnwrap(paths["/v1/tools/execute"] as? [String: Any])
        XCTAssertNotNil(execute["post"])
    }

    func testExecuteEndpointReturnsToolResultContractOnErrors() throws {
        let router = Router()

        let unknownToolBody = Data(#"{"tool":"does.not.exist","input":{}}"#.utf8)
        let response = router.handle(
            HTTPRequest(
                method: "POST",
                path: "/v1/tools/execute",
                body: unknownToolBody,
                headers: ["content-type": "application/json"]
            )
        )
        XCTAssertEqual(response.status, 404)

        let toolResult = try JSONCoding.makeDecoder().decode(ToolExecutionResult.self, from: response.body)
        XCTAssertEqual(toolResult.status, "error")
        XCTAssertEqual(toolResult.solver, "does.not.exist")
        XCTAssertEqual(toolResult.exitCode, 1)
        XCTAssertFalse(toolResult.summary.isEmpty)
        XCTAssertFalse(toolResult.stderr.isEmpty)
        XCTAssertNotNil(toolResult.metrics["error_code"])

        let invalidJSON = router.handle(
            HTTPRequest(
                method: "POST",
                path: "/v1/tools/execute",
                body: Data("{".utf8),
                headers: ["content-type": "application/json"]
            )
        )
        XCTAssertEqual(invalidJSON.status, 400)
        let invalidResult = try JSONCoding.makeDecoder().decode(ToolExecutionResult.self, from: invalidJSON.body)
        XCTAssertEqual(invalidResult.status, "error")
        XCTAssertEqual(invalidResult.solver, "unknown")
        XCTAssertEqual(invalidResult.exitCode, 1)
    }
}
