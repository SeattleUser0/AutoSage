import Foundation
import XCTest
@testable import AutoSageCore

private struct EchoTool: Tool {
    let name: String = "echo.solve"
    let version: String = "0.1.0"
    let description: String = "Echo tool for tests."
    let jsonSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "alpha": .object(["type": .string("number")])
        ])
    ])

    func run(input: JSONValue?, context: ToolExecutionContext) throws -> JSONValue {
        let payload: JSONValue = .object([
            "echo": input ?? .null
        ])
        let result = ToolExecutionResult(
            status: "ok",
            solver: name,
            summary: "echo",
            stdout: "",
            stderr: "",
            exitCode: 0,
            artifacts: [],
            metrics: ["job_id": .string(context.jobID)],
            output: payload
        )
        return try result.asJSONValue()
    }
}

final class AutoSageCoreTests: XCTestCase {
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

    private func repositoryRootURL() throws -> URL {
        let fileManager = FileManager.default
        var candidate = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        for _ in 0..<8 {
            let package = candidate.appendingPathComponent("Package.swift")
            let openapi = candidate.appendingPathComponent("openapi/openapi.yaml")
            if fileManager.fileExists(atPath: package.path), fileManager.fileExists(atPath: openapi.path) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                break
            }
            candidate = parent
        }
        throw AutoSageError(code: "invalid_test_data", message: "Could not locate repository root for contract tests.")
    }

    private func readTextFile(at relativePath: String) throws -> String {
        let root = try repositoryRootURL()
        let fileURL = root.appendingPathComponent(relativePath)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    private func yamlRootValue(for key: String, in text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("\(key):") {
                let value = line.dropFirst("\(key):".count).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private func yamlInfoValue(for key: String, in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        var inInfo = false
        for line in lines {
            if line.hasPrefix("info:") {
                inInfo = true
                continue
            }
            if inInfo, !line.hasPrefix("  "), !line.trimmingCharacters(in: .whitespaces).isEmpty {
                break
            }
            if inInfo, line.hasPrefix("  \(key):") {
                let value = line.dropFirst("  \(key):".count).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return nil
    }

    private func asObject(_ value: JSONValue?) -> [String: JSONValue]? {
        guard case .object(let object)? = value else { return nil }
        return object
    }

    private func asString(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value else { return nil }
        return string
    }

    private func asArray(_ value: JSONValue?) -> [JSONValue]? {
        guard case .array(let array)? = value else { return nil }
        return array
    }

    private func asBool(_ value: JSONValue?) -> Bool? {
        guard case .bool(let value)? = value else { return nil }
        return value
    }

    private func isMissingDescription(_ value: JSONValue?) -> Bool {
        guard let description = asString(value) else { return true }
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let normalized = trimmed.lowercased()
        return normalized == "todo" || normalized == "tbd"
    }

    private func typeName(for value: JSONValue) -> String {
        switch value {
        case .null:
            return "null"
        case .bool:
            return "boolean"
        case .number(let number):
            return number.rounded() == number ? "integer" : "number"
        case .string:
            return "string"
        case .array:
            return "array"
        case .object:
            return "object"
        }
    }

    private func value(_ value: JSONValue, matchesSchemaType schemaType: String) -> Bool {
        switch schemaType {
        case "string":
            if case .string = value { return true }
            return false
        case "integer":
            if case .number(let number) = value { return number.rounded() == number }
            return false
        case "number":
            if case .number = value { return true }
            return false
        case "boolean":
            if case .bool = value { return true }
            return false
        case "array":
            if case .array = value { return true }
            return false
        case "object":
            if case .object = value { return true }
            return false
        case "null":
            if case .null = value { return true }
            return false
        default:
            return true
        }
    }

    private func schemaValidationIssues(
        input: JSONValue,
        schema: [String: JSONValue],
        path: String = "$"
    ) -> [String] {
        var issues: [String] = []
        guard case .object(let inputObject) = input else {
            return ["\(path): expected object input, got \(typeName(for: input))"]
        }

        let properties = asObject(schema["properties"]) ?? [:]
        let required: [String] = asArray(schema["required"])?.compactMap { entry in
            if case .string(let key) = entry { return key }
            return nil
        } ?? []

        for requiredKey in required where inputObject[requiredKey] == nil {
            issues.append("\(path): missing required key '\(requiredKey)'")
        }

        if asBool(schema["additionalProperties"]) == false {
            for key in inputObject.keys where properties[key] == nil {
                issues.append("\(path): unexpected key '\(key)'")
            }
        }

        for key in inputObject.keys.sorted() {
            guard let propertySchema = asObject(properties[key]),
                  let inputValue = inputObject[key] else {
                continue
            }

            let propertyPath = "\(path).\(key)"
            if let schemaType = asString(propertySchema["type"])?.lowercased(),
               !value(inputValue, matchesSchemaType: schemaType) {
                issues.append(
                    "\(propertyPath): expected \(schemaType), got \(typeName(for: inputValue))"
                )
                continue
            }

            if let propertyType = asString(propertySchema["type"])?.lowercased(), propertyType == "object" {
                issues.append(contentsOf: schemaValidationIssues(
                    input: inputValue,
                    schema: propertySchema,
                    path: propertyPath
                ))
            } else if let propertyType = asString(propertySchema["type"])?.lowercased(),
                      propertyType == "array",
                      case .array(let elements) = inputValue,
                      let itemSchema = asObject(propertySchema["items"]) {
                for (index, element) in elements.enumerated() {
                    if let itemType = asString(itemSchema["type"])?.lowercased(),
                       !value(element, matchesSchemaType: itemType) {
                        issues.append(
                            "\(propertyPath)[\(index)]: expected \(itemType), got \(typeName(for: element))"
                        )
                    }
                }
            }
        }

        return issues
    }

    private func schemaPropertyAuditIssues(
        toolName: String,
        schemaObject: [String: JSONValue],
        objectPath: String,
        allowlist: [String: Set<String>]
    ) -> [String] {
        guard let properties = asObject(schemaObject["properties"]) else { return [] }
        var issues: [String] = []
        let allowedPaths = allowlist[toolName] ?? []

        for key in properties.keys.sorted() {
            let propertyPath = objectPath.isEmpty ? key : "\(objectPath).\(key)"
            guard let propertySchema = asObject(properties[key]) else {
                issues.append("property '\(propertyPath)' schema is not an object")
                continue
            }

            if !allowedPaths.contains(propertyPath) && isMissingDescription(propertySchema["description"]) {
                issues.append("property '\(propertyPath)' missing description")
            }

            let propertyType = asString(propertySchema["type"])?.lowercased()
            if propertyType == "object", asObject(propertySchema["properties"]) != nil {
                issues.append(contentsOf: schemaPropertyAuditIssues(
                    toolName: toolName,
                    schemaObject: propertySchema,
                    objectPath: propertyPath,
                    allowlist: allowlist
                ))
            } else if propertyType == "array",
                      let itemsSchema = asObject(propertySchema["items"]),
                      asString(itemsSchema["type"])?.lowercased() == "object",
                      asObject(itemsSchema["properties"]) != nil {
                issues.append(contentsOf: schemaPropertyAuditIssues(
                    toolName: toolName,
                    schemaObject: itemsSchema,
                    objectPath: "\(propertyPath)[]",
                    allowlist: allowlist
                ))
            }
        }

        return issues
    }

    func testRequestIDGeneratorFormatsAndIncrements() {
        let generator = RequestIDGenerator()
        XCTAssertEqual(generator.nextResponseID(), "resp_0001")
        XCTAssertEqual(generator.nextResponseID(), "resp_0002")
        XCTAssertEqual(generator.nextChatCompletionID(), "chatcmpl_0001")
        XCTAssertEqual(generator.nextChatCompletionID(), "chatcmpl_0002")
        XCTAssertEqual(generator.nextToolCallID(), "call_0001")
        XCTAssertEqual(generator.nextToolCallID(), "call_0002")
        XCTAssertEqual(generator.nextJobID(), "job_0001")
        XCTAssertEqual(generator.nextJobID(), "job_0002")
    }

    func testRequestIDGeneratorProducesUniqueIDsAcrossConcurrentCalls() {
        let generator = RequestIDGenerator()
        let lock = NSLock()
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        var ids: [String] = []
        let iterations = 200

        for _ in 0..<iterations {
            group.enter()
            queue.async {
                let id = generator.nextResponseID()
                lock.lock()
                ids.append(id)
                lock.unlock()
                group.leave()
            }
        }

        group.wait()
        XCTAssertEqual(ids.count, iterations)
        XCTAssertEqual(Set(ids).count, iterations)
        XCTAssertTrue(ids.allSatisfy { $0.hasPrefix("resp_") })
    }

    func testResponsesRequestRoundTrip() throws {
        let request = ResponsesRequest(
            model: "autosage-0.1",
            input: [InputMessage(role: "user", content: .string("hello"))],
            toolChoice: .string("fea.solve"),
            tools: nil
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ResponsesRequest.self, from: data)
        XCTAssertEqual(decoded, request)
    }

    func testChatCompletionsRequestRoundTrip() throws {
        let request = ChatCompletionsRequest(
            model: "autosage-0.1",
            messages: [ChatMessage(role: "user", content: .string("hello"))],
            toolChoice: .string("cfd.solve"),
            tools: nil
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ChatCompletionsRequest.self, from: data)
        XCTAssertEqual(decoded, request)
    }

    func testResponsesResponseRoundTrip() throws {
        let output = ResponseOutputItem(
            type: "message",
            role: "assistant",
            content: [ResponseTextContent(type: "output_text", text: "hi")],
            toolName: nil,
            result: nil
        )
        let response = ResponsesResponse(
            id: "resp_0001",
            object: "response",
            model: "autosage-0.1",
            output: [output]
        )
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(ResponsesResponse.self, from: data)
        XCTAssertEqual(decoded, response)
    }

    func testChatCompletionsResponseRoundTrip() throws {
        let message = ChatCompletionMessage(role: "assistant", content: "hello", toolCalls: nil)
        let choice = ChatChoice(index: 0, message: message, finishReason: "stop")
        let response = ChatCompletionsResponse(
            id: "chatcmpl_0001",
            object: "chat.completion",
            model: "autosage-0.1",
            choices: [choice],
            toolResults: nil
        )
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
        XCTAssertEqual(decoded, response)
    }

    func testCircuitsSimulateInputDecoding() throws {
        let payload = Data(
            """
            {
              "netlist": "V1 in 0 1\\nR1 in out 1000\\nC1 out 0 1e-6",
              "analysis": "tran",
              "probes": ["v(out)", "v(in)"],
              "options": {
                "tran": {"tstop": 0.01, "step": 0.0001}
              }
            }
            """.utf8
        )
        let decoded = try JSONCoding.makeDecoder().decode(CircuitsSimulateInput.self, from: payload)
        XCTAssertEqual(decoded.analysis, .tran)
        XCTAssertEqual(decoded.probes, ["v(out)", "v(in)"])
        XCTAssertEqual(decoded.options?.tran?.tstop, 0.01)
        XCTAssertEqual(decoded.options?.tran?.step, 0.0001)
    }

    func testCircuitsSimulateOutputEncoding() throws {
        let output = CircuitsSimulateOutput(
            status: "ok",
            solver: "ngspice",
            summary: "Simulated tran with 1 probe(s).",
            series: [
                CircuitsSeries(probe: "v(out)", x: [0.0, 1.0], y: [0.0, 0.5])
            ]
        )
        let data = try JSONCoding.makeEncoder().encode(output)
        let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        XCTAssertEqual(json?["status"] as? String, "ok")
        XCTAssertEqual(json?["solver"] as? String, "ngspice")
        XCTAssertNotNil(json?["series"] as? [[String: Any]])
    }

    func testMissingEndFails() throws {
        do {
            _ = try NgSpiceRunner.runNetlist(
                netlist: "* no end\nV1 in 0 1\nR1 in 0 1000",
                timeoutS: 1
            )
            XCTFail("Expected invalid_input failure for missing .end")
        } catch let error as NgSpiceRunnerError {
            XCTAssertEqual(error.code, "invalid_input")
            XCTAssertTrue(error.message.lowercased().contains(".end"))
        }
    }

    func testParsesAsciiRawVectors() throws {
        let raw = """
        Title: AutoSage
        Date: Wed Feb 18 00:00:00 2026
        Plotname: Transient Analysis
        Flags: real
        No. Variables: 2
        No. Points: 3
        Variables:
            0   time    time
            1   v(out)  voltage
        Values:
         0   0.000000e+00
            0.000000e+00
         1   1.000000e-03
            5.000000e-01
         2   2.000000e-03
            7.500000e-01
        """
        let parsed = try NgSpiceRunner.parseASCIIRaw(content: raw)
        XCTAssertEqual(parsed.pointCount, 3)
        XCTAssertEqual(parsed.vectorNames, ["time", "v(out)"])
        XCTAssertEqual(parsed.vectors["time"], [0.0, 0.001, 0.002])
        XCTAssertEqual(parsed.vectors["v(out)"], [0.0, 0.5, 0.75])
    }

    func testHealthzHandler() throws {
        let router = Router()
        let request = HTTPRequest(method: "GET", path: "/healthz", body: nil)
        let response = router.handle(request)
        XCTAssertEqual(response.status, 200)
        let decoded = try JSONDecoder().decode(HealthResponse.self, from: response.body)
        XCTAssertEqual(decoded.status, "ok")
        XCTAssertEqual(decoded.name, "AutoSage")
        XCTAssertEqual(decoded.version, "0.1.0")
    }

    func testAdminPageServesHTML() {
        let router = Router()
        let response = router.handle(HTTPRequest(method: "GET", path: "/admin", body: nil))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["Content-Type"], "text/html; charset=utf-8")

        let html = String(data: response.body, encoding: .utf8) ?? ""
        XCTAssertTrue(html.contains("AutoSage Admin"))
        XCTAssertTrue(html.contains("/v1/admin/clear-jobs"))
    }

    func testAdminClearJobsEndpointDeletesSessionDirectoriesAndReturnsSummary() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-admin-clear-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }
        try fileManager.createDirectory(at: tempBase, withIntermediateDirectories: true, attributes: nil)

        let sessionOne = tempBase.appendingPathComponent("session_one", isDirectory: true)
        let sessionTwo = tempBase.appendingPathComponent("session_two", isDirectory: true)
        let keep = tempBase.appendingPathComponent("cache", isDirectory: true)
        try fileManager.createDirectory(at: sessionOne, withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: sessionTwo, withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: keep, withIntermediateDirectories: true, attributes: nil)
        try Data("abc".utf8).write(to: sessionOne.appendingPathComponent("manifest.json"))
        try Data("defgh".utf8).write(to: sessionTwo.appendingPathComponent("manifest.json"))

        let store = SessionStore(baseURL: tempBase, fileManager: fileManager)
        let router = Router(sessionStore: store)

        let response = router.handle(
            HTTPRequest(
                method: "POST",
                path: "/v1/admin/clear-jobs",
                body: Data("{}".utf8),
                headers: ["content-type": "application/json"]
            )
        )
        XCTAssertEqual(response.status, 200)

        let decoded = try JSONCoding.makeDecoder().decode(AdminClearJobsResponse.self, from: response.body)
        XCTAssertEqual(decoded.status, "ok")
        XCTAssertEqual(decoded.deletedJobs, 2)
        XCTAssertEqual(decoded.sessionsRoot, tempBase.path)
        XCTAssertGreaterThanOrEqual(decoded.reclaimedBytes, 8)

        XCTAssertFalse(fileManager.fileExists(atPath: sessionOne.path))
        XCTAssertFalse(fileManager.fileExists(atPath: sessionTwo.path))
        XCTAssertTrue(fileManager.fileExists(atPath: keep.path))
    }

    func testAdminLogsEndpointReturnsRecentLines() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-admin-logs-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }
        try fileManager.createDirectory(at: tempBase, withIntermediateDirectories: true, attributes: nil)

        let store = SessionStore(baseURL: tempBase, fileManager: fileManager)
        let router = Router(sessionStore: store)

        _ = router.handle(HTTPRequest(method: "POST", path: "/v1/admin/clear-jobs", body: nil))
        let logsResponse = router.handle(HTTPRequest(method: "GET", path: "/v1/admin/logs?limit=50", body: nil))
        XCTAssertEqual(logsResponse.status, 200)

        let decoded = try JSONCoding.makeDecoder().decode(AdminLogsResponse.self, from: logsResponse.body)
        XCTAssertGreaterThan(decoded.count, 0)
        XCTAssertFalse(decoded.lines.isEmpty)
        XCTAssertTrue(decoded.lines.joined(separator: "\n").contains("session"))
    }

    func testCreateSessionFromMultipartInitializesManifestAndWorkspace() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-session-create-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let store = SessionStore(baseURL: tempBase, fileManager: fileManager)
        let router = Router(sessionStore: store)

        let boundary = "autosage-boundary-\(UUID().uuidString)"
        let multipartBody = """
        --\(boundary)\r
        Content-Disposition: form-data; name="file"; filename="beam.step"\r
        Content-Type: application/step\r
        \r
        ISO-10303-21;\r
        HEADER;\r
        ENDSEC;\r
        DATA;\r
        ENDSEC;\r
        END-ISO-10303-21;\r
        --\(boundary)--\r
        """
        let request = HTTPRequest(
            method: "POST",
            path: "/v1/sessions",
            body: Data(multipartBody.utf8),
            headers: ["content-type": "multipart/form-data; boundary=\(boundary)"]
        )
        let response = router.handle(request)
        XCTAssertEqual(response.status, 200)

        let created = try JSONCoding.makeDecoder().decode(SessionCreateResponse.self, from: response.body)
        XCTAssertTrue(created.sessionID.hasPrefix("session_"))
        XCTAssertEqual(created.state.sessionID, created.sessionID)
        XCTAssertEqual(created.state.status, "idle")
        XCTAssertEqual(created.state.stage, "created")
        XCTAssertEqual(created.state.assets, ["input/beam.step"])

        let sessionRoot = tempBase.appendingPathComponent(created.sessionID, isDirectory: true)
        let expectedDirectories = ["input", "geometry", "mesh", "solve", "render", "logs"]
        for directory in expectedDirectories {
            let path = sessionRoot.appendingPathComponent(directory, isDirectory: true).path
            var isDirectory: ObjCBool = false
            XCTAssertTrue(fileManager.fileExists(atPath: path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
        }

        let uploadPath = sessionRoot.appendingPathComponent("input/beam.step").path
        XCTAssertTrue(fileManager.fileExists(atPath: uploadPath))
        let manifestPath = sessionRoot.appendingPathComponent("manifest.json").path
        XCTAssertTrue(fileManager.fileExists(atPath: manifestPath))

        let getResponse = router.handle(HTTPRequest(method: "GET", path: "/v1/sessions/\(created.sessionID)", body: nil))
        XCTAssertEqual(getResponse.status, 200)
        let fetched = try JSONCoding.makeDecoder().decode(SessionManifest.self, from: getResponse.body)
        XCTAssertEqual(fetched.sessionID, created.sessionID)
        XCTAssertEqual(fetched.assets, ["input/beam.step"])
    }

    func testSessionAssetEndpointServesFilesAndBlocksTraversal() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-session-assets-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let store = SessionStore(baseURL: tempBase, fileManager: fileManager)
        let router = Router(sessionStore: store)

        let boundary = "autosage-assets-\(UUID().uuidString)"
        let multipartBody = """
        --\(boundary)\r
        Content-Disposition: form-data; name="file"; filename="model.step"\r
        Content-Type: application/step\r
        \r
        solid model\r
        --\(boundary)--\r
        """
        let createResponse = router.handle(
            HTTPRequest(
                method: "POST",
                path: "/v1/sessions",
                body: Data(multipartBody.utf8),
                headers: ["content-type": "multipart/form-data; boundary=\(boundary)"]
            )
        )
        XCTAssertEqual(createResponse.status, 200)
        let created = try JSONCoding.makeDecoder().decode(SessionCreateResponse.self, from: createResponse.body)

        let workspaceURL = try waitForAsyncThrowing {
            try await store.workspaceURLForSession(id: created.sessionID)
        }
        let renderURL = workspaceURL.appendingPathComponent("render", isDirectory: true)
        try fileManager.createDirectory(at: renderURL, withIntermediateDirectories: true, attributes: nil)
        let previewData = Data([0x89, 0x50, 0x4E, 0x47])
        let previewURL = renderURL.appendingPathComponent("preview.png")
        try previewData.write(to: previewURL, options: .atomic)

        let assetResponse = router.handle(
            HTTPRequest(method: "GET", path: "/v1/sessions/\(created.sessionID)/assets/render/preview.png", body: nil)
        )
        XCTAssertEqual(assetResponse.status, 200)
        XCTAssertEqual(assetResponse.headers["Content-Type"], "image/png")
        XCTAssertEqual(assetResponse.body, previewData)

        let traversalResponse = router.handle(
            HTTPRequest(method: "GET", path: "/v1/sessions/\(created.sessionID)/assets/..%2Fmanifest.json", body: nil)
        )
        XCTAssertEqual(traversalResponse.status, 404)
    }

    func testAgentConfigHandlerReturnsOpenAICompatiblePayload() throws {
        let router = Router()
        let response = router.handle(HTTPRequest(method: "GET", path: "/v1/agent/config", body: nil))
        XCTAssertEqual(response.status, 200)

        let decoded = try JSONCoding.makeDecoder().decode(AgentConfigPayload.self, from: response.body)
        XCTAssertEqual(decoded.agentRole, "orchestration_agent")
        XCTAssertEqual(decoded.manifestPath, "manifest.json")
        XCTAssertEqual(
            decoded.pipelineSequence,
            ["cad_import_truck", "mesh_repair_pmp", "volume_mesh_quartet", "solve", "render_pack_vtk"]
        )
        XCTAssertEqual(decoded.escalationErrors, ["ERR_NON_MANIFOLD_UNRESOLVABLE"])
        XCTAssertTrue(decoded.systemMessage.content.contains("manifest.json"))
        XCTAssertTrue(decoded.systemMessage.content.contains("CAD Import: cad_import_truck"))
        XCTAssertTrue(decoded.systemMessage.content.contains("ERR_NON_MANIFOLD_UNRESOLVABLE"))
        XCTAssertEqual(decoded.systemMessage.role, "system")
        XCTAssertEqual(decoded.messages, [decoded.systemMessage])

        let route = AgentErrorRoute(
            errorCode: "ERR_NOT_WATERTIGHT",
            action: "route_surface_mesh_to_repair_then_retry_volume_mesh",
            actionTool: "mesh_repair_pmp",
            retryLimit: 1
        )
        XCTAssertTrue(decoded.errorRouting.contains(route))

        let toolNames = decoded.tools.compactMap { $0.function?.name }
        XCTAssertEqual(toolNames, toolNames.sorted())
        XCTAssertTrue(toolNames.contains("cad_import_truck"))
        XCTAssertTrue(toolNames.contains("mesh_repair_pmp"))
        XCTAssertTrue(toolNames.contains("volume_mesh_quartet"))
        XCTAssertTrue(toolNames.contains("render_pack_vtk"))
        XCTAssertTrue(decoded.tools.allSatisfy { $0.type == "function" && $0.function != nil })
        XCTAssertTrue(decoded.tools.allSatisfy {
            guard let function = $0.function else { return false }
            guard !function.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            guard function.description != nil else { return false }
            guard case .object = function.parameters else { return false }
            return true
        })
    }

    func testResponsesHandlerUsesIncrementingResponseIDs() throws {
        let router = Router()
        let body = Data(#"{"model":"autosage-0.1"}"#.utf8)

        let first = router.handle(HTTPRequest(method: "POST", path: "/v1/responses", body: body))
        XCTAssertEqual(first.status, 200)
        let firstDecoded = try JSONDecoder().decode(ResponsesResponse.self, from: first.body)
        XCTAssertEqual(firstDecoded.id, "resp_0001")

        let second = router.handle(HTTPRequest(method: "POST", path: "/v1/responses", body: body))
        XCTAssertEqual(second.status, 200)
        let secondDecoded = try JSONDecoder().decode(ResponsesResponse.self, from: second.body)
        XCTAssertEqual(secondDecoded.id, "resp_0002")
    }

    func testChatCompletionsHandlerUsesIncrementingChatAndToolCallIDs() throws {
        let router = Router(registry: ToolRegistry(tools: [EchoTool()]))
        let body = Data(#"{"model":"autosage-0.1","tool_choice":"echo.solve"}"#.utf8)

        let first = router.handle(HTTPRequest(method: "POST", path: "/v1/chat/completions", body: body))
        XCTAssertEqual(first.status, 200)
        let firstDecoded = try JSONDecoder().decode(ChatCompletionsResponse.self, from: first.body)
        XCTAssertEqual(firstDecoded.id, "chatcmpl_0001")
        XCTAssertEqual(firstDecoded.choices.first?.message.toolCalls?.first?.id, "call_0001")

        let second = router.handle(HTTPRequest(method: "POST", path: "/v1/chat/completions", body: body))
        XCTAssertEqual(second.status, 200)
        let secondDecoded = try JSONDecoder().decode(ChatCompletionsResponse.self, from: second.body)
        XCTAssertEqual(secondDecoded.id, "chatcmpl_0002")
        XCTAssertEqual(secondDecoded.choices.first?.message.toolCalls?.first?.id, "call_0002")
    }

    func testResponsesHandlerRejectsInvalidJSON() throws {
        let router = Router()
        let response = router.handle(HTTPRequest(method: "POST", path: "/v1/responses", body: Data("{".utf8)))
        XCTAssertEqual(response.status, 400)

        let decoded = try JSONDecoder().decode(ErrorResponse.self, from: response.body)
        XCTAssertEqual(decoded.error.code, "invalid_request")
    }

    func testResponsesHandlerRejectsMissingModel() throws {
        let router = Router()
        let response = router.handle(HTTPRequest(method: "POST", path: "/v1/responses", body: Data("{}".utf8)))
        XCTAssertEqual(response.status, 400)

        let decoded = try JSONDecoder().decode(ErrorResponse.self, from: response.body)
        XCTAssertEqual(decoded.error.code, "invalid_request")
        XCTAssertEqual(decoded.error.details?["field"], .string("model"))
    }

    func testChatCompletionsHandlerRejectsUnknownTool() throws {
        let router = Router()
        let body = Data(#"{"model":"autosage-0.1","tool_choice":"does.not.exist"}"#.utf8)
        let response = router.handle(HTTPRequest(method: "POST", path: "/v1/chat/completions", body: body))
        XCTAssertEqual(response.status, 400)

        let decoded = try JSONDecoder().decode(ErrorResponse.self, from: response.body)
        XCTAssertEqual(decoded.error.code, "unknown_tool")
        XCTAssertEqual(decoded.error.details?["tool_name"], .string("does.not.exist"))
    }

    func testChatCompletionsToolChoiceObjectParsesArguments() throws {
        let router = Router(registry: ToolRegistry(tools: [EchoTool()]))
        let body = Data(
            """
            {
              "model":"autosage-0.1",
              "tool_choice":{
                "type":"function",
                "function":{
                  "name":"echo.solve",
                  "arguments":"{\\"alpha\\":1}"
                }
              }
            }
            """.utf8
        )

        let response = router.handle(HTTPRequest(method: "POST", path: "/v1/chat/completions", body: body))
        XCTAssertEqual(response.status, 200)
        let decoded = try JSONCoding.makeDecoder().decode(ChatCompletionsResponse.self, from: response.body)
        XCTAssertEqual(decoded.choices.first?.message.toolCalls?.first?.function.name, "echo.solve")

        let toolCallArguments = decoded.choices.first?.message.toolCalls?.first?.function.arguments ?? "{}"
        let argumentsData = Data(toolCallArguments.utf8)
        let argumentsJSON = try JSONCoding.makeDecoder().decode(JSONValue.self, from: argumentsData)
        XCTAssertEqual(argumentsJSON, .object(["alpha": .number(1)]))

        guard let firstResult = decoded.toolResults?.first,
              case .object(let resultObject) = firstResult,
              case .object(let echoObject)? = resultObject["echo"] else {
            return XCTFail("Missing echo payload in tool result.")
        }
        XCTAssertEqual(echoObject["alpha"], .number(1))
    }

    func testParsePort() {
        XCTAssertNil(parsePort(nil))
        XCTAssertNil(parsePort(""))
        XCTAssertNil(parsePort("not-a-number"))
        XCTAssertNil(parsePort("0"))
        XCTAssertNil(parsePort("70000"))
        XCTAssertEqual(parsePort("8081"), 8081)
        XCTAssertEqual(parsePort(" 9090 "), 9090)
    }

    func testRegistryContainsVersionedTools() {
        let registry = ToolRegistry.default
        let names = Set(registry.tools.keys)
        XCTAssertEqual(
            names,
            Set([
                "fea.solve",
                "cfd.solve",
                "stokes.solve",
                "advection.solve",
                "dpg_laplace.solve",
                "compressible.solve",
                "acoustics.solve",
                "eigen.solve",
                "structural_modal.solve",
                "heat.solve",
                "joule_heating.solve",
                "hyperelastic.solve",
                "elastodynamics.solve",
                "transient_em.solve",
                "magnetostatics.solve",
                "electrostatics.solve",
                "amr_laplace.solve",
                "anisotropic.solve",
                "fractional_pde.solve",
                "surface_pde.solve",
                "em_modal.solve",
                "em_scattering.solve",
                "electromagnetics.solve",
                "darcy.solve",
                "incompressible_elasticity.solve",
                "volume_mesh_quartet",
                "render_pack_vtk",
                "dsl_fit_open3d",
                "mesh_repair_pmp",
                "cad_import_truck",
                "circuit_simulate_ngspice",
                "circuits.simulate",
                "echo_json",
                "write_text_artifact"
            ])
        )
        for name in names {
            guard let tool = registry.tool(named: name) else {
                return XCTFail("Missing tool \(name)")
            }
            XCTAssertFalse(tool.version.isEmpty)
            if case .object = tool.jsonSchema {
                // expected
            } else {
                XCTFail("Tool schema for \(name) should be an object.")
            }
        }
    }

    func testAllToolsHaveDescriptionsAndSchemas() {
        let registry = ToolRegistry.default

        // Escape hatch for properties that are intentionally free-form.
        // Keep this as small as possible and justify each entry if added.
        let descriptionAllowlist: [String: Set<String>] = [:]

        var failures: [String] = []
        for toolName in registry.tools.keys.sorted() {
            guard let tool = registry.tool(named: toolName) else {
                failures.append("\(toolName): missing tool registration")
                continue
            }

            if isMissingDescription(.string(tool.description)) {
                failures.append("\(toolName): tool description is missing or placeholder")
            }

            guard let schema = asObject(tool.jsonSchema) else {
                failures.append("\(toolName): schema is not a JSON object")
                continue
            }

            if asString(schema["type"])?.lowercased() != "object" {
                failures.append("\(toolName): top-level schema type must be 'object'")
            }
            if isMissingDescription(schema["description"]) {
                failures.append("\(toolName): top-level schema description is missing")
            }
            if asObject(schema["properties"]) == nil {
                failures.append("\(toolName): top-level schema properties object is missing")
            }
            if asArray(schema["required"]) == nil {
                failures.append("\(toolName): top-level schema required array is missing")
            }

            let propertyIssues = schemaPropertyAuditIssues(
                toolName: toolName,
                schemaObject: schema,
                objectPath: "",
                allowlist: descriptionAllowlist
            )
            failures.append(contentsOf: propertyIssues.map { "\(toolName): \($0)" })
        }

        if !failures.isEmpty {
            XCTFail(
                """
                Tool metadata/schema audit failed (\(failures.count) issue(s)):
                - \(failures.joined(separator: "\n- "))
                """
            )
        }
    }

    func testStableToolsProvideSchemaValidatedExamples() {
        let registry = ToolRegistry.default
        let stableTools = registry.listTools(stability: .stable)
        XCTAssertFalse(stableTools.isEmpty)

        var failures: [String] = []
        for entry in stableTools {
            let toolName = entry.tool.name
            let examples = entry.metadata.examples
            if examples.isEmpty {
                failures.append("\(toolName): stable tool must include at least one example")
                continue
            }
            guard let schema = asObject(entry.tool.jsonSchema) else {
                failures.append("\(toolName): schema is not a JSON object")
                continue
            }

            for (index, example) in examples.enumerated() {
                let title = example.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if title.isEmpty {
                    failures.append("\(toolName): example[\(index)] title must be non-empty")
                }
                let issues = schemaValidationIssues(input: example.input, schema: schema)
                failures.append(contentsOf: issues.map { "\(toolName): example[\(index)] \($0)" })
            }
        }

        if !failures.isEmpty {
            XCTFail(
                """
                Stable tool examples failed validation (\(failures.count) issue(s)):
                - \(failures.joined(separator: "\n- "))
                """
            )
        }
    }

    func testOpenAPIYamlContainsRequiredContractTokens() throws {
        let yaml = try readTextFile(at: "openapi/openapi.yaml")
        XCTAssertTrue(yaml.contains("openapi: 3."), "openapi version marker is missing.")
        XCTAssertTrue(yaml.contains("/healthz:"), "Missing /healthz path.")
        XCTAssertTrue(yaml.contains("/v1/tools:"), "Missing /v1/tools path.")
        XCTAssertTrue(yaml.contains("/v1/tools/execute:"), "Missing /v1/tools/execute path.")
        XCTAssertTrue(yaml.contains("/healthz:\n    get:"), "Missing GET method for /healthz.")
        XCTAssertTrue(yaml.contains("/v1/tools:\n    get:"), "Missing GET method for /v1/tools.")
        XCTAssertTrue(yaml.contains("/v1/tools/execute:\n    post:"), "Missing POST method for /v1/tools/execute.")
        XCTAssertTrue(yaml.contains("#/components/schemas/ToolResult"), "ToolResult schema reference is missing.")
    }

    func testOpenAPIYamlIsOnlyCommittedSpecSource() throws {
        let root = try repositoryRootURL()
        let yamlPath = root.appendingPathComponent("openapi/openapi.yaml").path
        let jsonPath = root.appendingPathComponent("openapi/openapi.json").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: yamlPath))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: jsonPath),
            "Do not commit openapi/openapi.json; openapi/openapi.yaml is the only repository source of truth."
        )
    }

    func testProfessionalFilesHaveReasonableLineLengths() throws {
        let root = try repositoryRootURL()
        let trackedFiles = [
            "Package.swift",
            ".github/workflows/ci.yml",
            "openapi/openapi.yaml",
            "README.md",
            "docs/TOOLS.md"
        ]
        let maxLineLength = 400
        var failures: [String] = []

        for relativePath in trackedFiles {
            let url = root.appendingPathComponent(relativePath)
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                if line.count > maxLineLength {
                    failures.append("\(relativePath):\(index + 1) has \(line.count) chars")
                }
            }
        }

        if !failures.isEmpty {
            XCTFail(
                """
                Found lines over \(maxLineLength) characters:
                - \(failures.joined(separator: "\n- "))
                """
            )
        }
    }

    func testJobStoreLifecycleTransitions() async {
        let store = JobStore(loadFromDisk: false)
        let created = await store.createJob(toolName: "fea.solve", input: .object(["mesh": .string("m1")]))
        XCTAssertEqual(created.status, .queued)
        XCTAssertNil(created.startedAt)
        XCTAssertNil(created.finishedAt)

        await store.startJob(id: created.id)
        let running = await store.getJob(id: created.id)
        XCTAssertEqual(running?.status, .running)
        XCTAssertNotNil(running?.startedAt)

        let result: JSONValue = .object([
            "status": .string("ok"),
            "solver": .string("fea.solve"),
            "summary": .string("done")
        ])
        await store.completeJob(id: created.id, result: result, summary: "done")
        let finished = await store.getJob(id: created.id)
        XCTAssertEqual(finished?.status, .succeeded)
        XCTAssertEqual(finished?.summary, "done")
        XCTAssertEqual(finished?.result, result)
        XCTAssertNotNil(finished?.finishedAt)

        let failed = await store.createJob(toolName: "cfd.solve", input: nil)
        await store.startJob(id: failed.id)
        await store.failJob(id: failed.id, error: AutoSageError(code: "solver_error", message: "Failed"))
        let failedRecord = await store.getJob(id: failed.id)
        XCTAssertEqual(failedRecord?.status, .failed)
        XCTAssertEqual(failedRecord?.error?.code, "solver_error")
        XCTAssertNotNil(failedRecord?.finishedAt)
    }

    func testJobStoreWritesSummaryToRunDirectory() async throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-runs-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let runDirectory = RunDirectory(baseURL: tempBase, fileManager: fileManager)
        let store = JobStore(runDirectory: runDirectory, loadFromDisk: false)

        let job = await store.createJob(toolName: "circuits.simulate", input: .object(["netlist": .string("R1 1 0 100")]))
        await store.startJob(id: job.id)
        await store.completeJob(
            id: job.id,
            result: .object(["status": .string("ok"), "summary": .string("complete")]),
            summary: "complete"
        )

        let summaryURL = tempBase.appendingPathComponent(job.id, isDirectory: true).appendingPathComponent("summary.json")
        XCTAssertTrue(fileManager.fileExists(atPath: summaryURL.path))

        let data = try Data(contentsOf: summaryURL)
        let decoded = try JSONCoding.makeDecoder().decode(JobSummary.self, from: data)
        XCTAssertEqual(decoded.id, job.id)
        XCTAssertEqual(decoded.status, .succeeded)
        XCTAssertEqual(decoded.summary, "complete")
    }

    func testJobStoreWritesRequestAndSummaryArtifacts() async throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-artifacts-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let runDirectory = RunDirectory(baseURL: tempBase, fileManager: fileManager)
        let store = JobStore(runDirectory: runDirectory, loadFromDisk: false)

        let requestBody = Data(#"{"tool_name":"fea.solve","input":{"mesh":"m1"}}"#.utf8)
        let job = await store.createJob(toolName: "fea.solve", input: .object(["mesh": .string("m1")]), requestBody: requestBody)

        let jobDir = tempBase.appendingPathComponent(job.id, isDirectory: true)
        let requestURL = jobDir.appendingPathComponent("request.json")
        let summaryURL = jobDir.appendingPathComponent("summary.json")
        XCTAssertTrue(fileManager.fileExists(atPath: requestURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: summaryURL.path))

        let storedRequest = try Data(contentsOf: requestURL)
        XCTAssertEqual(storedRequest, requestBody)
    }

    func testJobStoreWritesResultArtifact() async throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-result-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let runDirectory = RunDirectory(baseURL: tempBase, fileManager: fileManager)
        let store = JobStore(runDirectory: runDirectory, loadFromDisk: false)

        let job = await store.createJob(toolName: "fea.solve", input: nil)
        await store.startJob(id: job.id)
        let result: JSONValue = .object(["status": .string("ok"), "summary": .string("done")])
        await store.completeJob(id: job.id, result: result, summary: "done")

        let resultURL = tempBase.appendingPathComponent(job.id, isDirectory: true).appendingPathComponent("result.json")
        XCTAssertTrue(fileManager.fileExists(atPath: resultURL.path))

        let data = try Data(contentsOf: resultURL)
        let decoded = try JSONCoding.makeDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, result)
    }

    func testJobRecordUsesISO8601Timestamps() throws {
        let record = JobRecord(
            id: "job_0001",
            toolName: "fea.solve",
            createdAt: Date(timeIntervalSince1970: 0),
            startedAt: nil,
            finishedAt: nil,
            status: .queued,
            summary: nil,
            result: nil,
            error: nil
        )

        let encoder = JSONCoding.makeEncoder()
        let data = try encoder.encode(record)
        let payload = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        let createdAt = payload?["created_at"] as? String
        XCTAssertEqual(createdAt, "1970-01-01T00:00:00.000Z")
    }

    func testJobStoreHydratesFromRunDirectoryAndListsArtifacts() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-hydrate-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let jobID = "job_9001"
        let jobDir = tempBase.appendingPathComponent(jobID, isDirectory: true)
        try fileManager.createDirectory(at: jobDir, withIntermediateDirectories: true, attributes: nil)

        let summary = JobSummary(
            id: jobID,
            toolName: "fea.solve",
            createdAt: Date(timeIntervalSince1970: 10),
            startedAt: Date(timeIntervalSince1970: 11),
            finishedAt: Date(timeIntervalSince1970: 12),
            status: .succeeded,
            summary: "complete"
        )
        let result: JSONValue = .object(["status": .string("ok"), "summary": .string("complete")])

        let encoder = JSONCoding.makeEncoder(prettyPrinted: true)
        let summaryData = try encoder.encode(summary)
        try summaryData.write(to: jobDir.appendingPathComponent("summary.json"), options: .atomic)
        let resultData = try encoder.encode(result)
        try resultData.write(to: jobDir.appendingPathComponent("result.json"), options: .atomic)
        let requestData = Data(#"{"tool_name":"fea.solve"}"#.utf8)
        try requestData.write(to: jobDir.appendingPathComponent("request.json"), options: .atomic)

        let runDirectory = RunDirectory(baseURL: tempBase, fileManager: fileManager)
        let store = JobStore(runDirectory: runDirectory, loadFromDisk: true)

        let loaded = waitForAsync { await store.getJob(id: jobID) }
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.status, .succeeded)
        XCTAssertEqual(loaded?.result, result)

        let router = Router(jobStore: store)
        let getResponse = router.handle(HTTPRequest(method: "GET", path: "/v1/jobs/\(jobID)", body: nil))
        XCTAssertEqual(getResponse.status, 200)
        let decodedJob = try JSONCoding.makeDecoder().decode(JobRecord.self, from: getResponse.body)
        XCTAssertEqual(decodedJob.id, jobID)
        XCTAssertEqual(decodedJob.status, .succeeded)

        let artifactsResponse = router.handle(HTTPRequest(method: "GET", path: "/v1/jobs/\(jobID)/artifacts", body: nil))
        XCTAssertEqual(artifactsResponse.status, 200)
        let artifacts = try JSONCoding.makeDecoder().decode(JobArtifactsResponse.self, from: artifactsResponse.body)
        XCTAssertEqual(artifacts.jobID, jobID)
        let names = artifacts.files.map { $0.name }.sorted()
        XCTAssertEqual(names, ["request.json", "result.json", "summary.json"])
        for artifact in artifacts.files {
            XCTAssertTrue(artifact.path.hasPrefix("/v1/jobs/\(jobID)/artifacts/"))
            XCTAssertFalse(artifact.mimeType.isEmpty)
            XCTAssertGreaterThanOrEqual(artifact.bytes, 0)
        }
    }

    func testJobsEndpointsCreateAndFetch() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-endpoint-runs-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }
        let router = Router(
            registry: ToolRegistry(tools: [EchoTool()]),
            jobStore: JobStore(runDirectory: RunDirectory(baseURL: tempBase, fileManager: fileManager), loadFromDisk: false)
        )
        let createBody = Data(#"{"tool_name":"echo.solve","input":{"alpha":0.01}}"#.utf8)
        let createResponse = router.handle(HTTPRequest(method: "POST", path: "/v1/jobs", body: createBody))
        XCTAssertEqual(createResponse.status, 200)
        let created = try JSONCoding.makeDecoder().decode(CreateJobResponse.self, from: createResponse.body)
        XCTAssertEqual(created.status, .queued)
        XCTAssertTrue(created.jobID.hasPrefix("job_"))

        var fetched: JobRecord?
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            let getResponse = router.handle(HTTPRequest(method: "GET", path: "/v1/jobs/\(created.jobID)", body: nil))
            if getResponse.status == 200 {
                fetched = try JSONCoding.makeDecoder().decode(JobRecord.self, from: getResponse.body)
                if fetched?.status == .succeeded {
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.id, created.jobID)
        XCTAssertTrue([JobStatus.running, .succeeded].contains(fetched?.status ?? .queued))
    }

    func testJobsEndpointSyncModeReturnsCompletedJob() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-sync-runs-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }
        let router = Router(
            registry: ToolRegistry(tools: [EchoTool()]),
            jobStore: JobStore(runDirectory: RunDirectory(baseURL: tempBase, fileManager: fileManager), loadFromDisk: false)
        )
        let createBody = Data(#"{"tool_name":"echo.solve","input":{"alpha":0.01},"mode":"sync","wait_ms":2000}"#.utf8)
        let createResponse = router.handle(HTTPRequest(method: "POST", path: "/v1/jobs", body: createBody))
        XCTAssertEqual(createResponse.status, 200)

        let created = try JSONCoding.makeDecoder().decode(CreateJobResponse.self, from: createResponse.body)
        XCTAssertEqual(created.status, .succeeded)
        XCTAssertEqual(created.job?.status, .succeeded)
        XCTAssertEqual(created.job?.id, created.jobID)
    }

    func testArtifactContentEndpointReturnsFileData() async throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-artifact-data-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let runDirectory = RunDirectory(baseURL: tempBase, fileManager: fileManager)
        let store = JobStore(runDirectory: runDirectory, loadFromDisk: false)
        let router = Router(jobStore: store)

        let job = await store.createJob(toolName: "fea.solve", input: nil)
        let jobDir = tempBase.appendingPathComponent(job.id, isDirectory: true)
        let logURL = jobDir.appendingPathComponent("notes.log")
        try "hello artifact\n".write(to: logURL, atomically: true, encoding: .utf8)

        let response = router.handle(HTTPRequest(method: "GET", path: "/v1/jobs/\(job.id)/artifacts/notes.log", body: nil))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["Content-Type"], "text/plain; charset=utf-8")
        let text = String(data: response.body, encoding: .utf8)
        XCTAssertEqual(text, "hello artifact\n")
    }

    func testJobStoreSeedsIDFromExistingRuns() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-seed-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let existingJobID = "job_0042"
        let existingDir = tempBase.appendingPathComponent(existingJobID, isDirectory: true)
        try fileManager.createDirectory(at: existingDir, withIntermediateDirectories: true, attributes: nil)
        let summary = JobSummary(
            id: existingJobID,
            toolName: "fea.solve",
            createdAt: Date(timeIntervalSince1970: 10),
            startedAt: nil,
            finishedAt: nil,
            status: .queued,
            summary: nil
        )
        let summaryData = try JSONCoding.makeEncoder(prettyPrinted: true).encode(summary)
        try summaryData.write(to: existingDir.appendingPathComponent("summary.json"), options: .atomic)

        let store = JobStore(runDirectory: RunDirectory(baseURL: tempBase, fileManager: fileManager), loadFromDisk: true)
        let created = waitForAsync { await store.createJob(toolName: "fea.solve", input: nil) }
        XCTAssertEqual(created.id, "job_0043")
    }

    func testFEAToolUsesMockedDriverRunnerAndReturnsNormalizedFields() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-fea-mock-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let runner: FEADriverRunner = { driverExecutable, _, resultURL, summaryURL, vtkURL, _, _ in
            XCTAssertEqual(URL(fileURLWithPath: driverExecutable).lastPathComponent, "mfem-driver")
            let summaryPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("Poisson"),
                "energy": .number(12.5),
                "iterations": .number(23),
                "error_norm": .number(0.0001)
            ])
            let resultPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("Poisson"),
                "solver_backend": .string("mfem")
            ])
            let encoder = JSONCoding.makeEncoder(prettyPrinted: true)
            try encoder.encode(summaryPayload).write(to: summaryURL, options: .atomic)
            try encoder.encode(resultPayload).write(to: resultURL, options: .atomic)
            try "vtk placeholder\n".write(to: vtkURL, atomically: true, encoding: .utf8)
            return FEADriverExecutionResult(exitCode: 0, stdout: "mfem stdout", stderr: "", elapsedMS: 15)
        }
        let tool = FEATool(
            driverRunner: runner,
            driverResolver: { "/usr/local/bin/mfem-driver" }
        )
        let context = ToolExecutionContext(jobID: "job_7777", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "solver_class": .string("Poisson"),
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "materials": .array([
                    .object([
                        "attribute": .number(1),
                        "E": .number(1_000_000),
                        "nu": .number(0.25)
                    ])
                ]),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("fixed")
                    ])
                ])
            ])
        ])

        let result = try tool.run(input: input, context: context)
        guard case .object(let object) = result else {
            return XCTFail("Expected JSON object result from FEATool.")
        }
        XCTAssertEqual(object["status"], .string("ok"))
        XCTAssertEqual(object["solver"], .string("mfem"))
        XCTAssertEqual(object["exit_code"], .number(0))
        XCTAssertEqual(object["stdout"], .string("mfem stdout"))
        guard case .array(let artifacts)? = object["artifacts"] else {
            return XCTFail("Expected artifacts array.")
        }
        let names = artifacts.compactMap { value -> String? in
            guard case .object(let object) = value,
                  case .string(let name)? = object["name"] else {
                return nil
            }
            return name
        }
        XCTAssertTrue(names.contains("job_input.json"))
        XCTAssertTrue(names.contains("job_result.json"))
        XCTAssertTrue(names.contains("job_summary.json"))
        XCTAssertTrue(names.contains("solution.vtk"))
    }

    func testFEAToolRejectsInvalidDriverBinaryName() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-fea-invalid-driver-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let tool = FEATool(
            driverRunner: { _, _, _, _, _, _, _ in
                XCTFail("Driver runner should not be called when driver path is invalid.")
                return FEADriverExecutionResult(exitCode: 0, stdout: "", stderr: "", elapsedMS: 0)
            },
            driverResolver: { "/tmp/not-the-driver" }
        )
        let context = ToolExecutionContext(jobID: "job_8888", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "solver_class": .string("Poisson"),
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "materials": .array([
                    .object([
                        "attribute": .number(1),
                        "E": .number(1_000_000),
                        "nu": .number(0.25)
                    ])
                ]),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("fixed")
                    ])
                ])
            ])
        ])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "invalid_configuration")
        }
    }

    func testCFDToolTransformsInputForNavierStokesDriver() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-cfd-mock-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let runner: FEADriverRunner = { driverExecutable, inputURL, resultURL, summaryURL, vtkURL, _, _ in
            XCTAssertEqual(URL(fileURLWithPath: driverExecutable).lastPathComponent, "mfem-driver")

            let payloadData = try Data(contentsOf: inputURL)
            let payload = try JSONCoding.makeDecoder().decode(JSONValue.self, from: payloadData)
            guard case .object(let payloadObject) = payload else {
                XCTFail("Expected object payload")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }

            XCTAssertEqual(payloadObject["solver_class"], .string("NavierStokes"))
            guard case .object(let config)? = payloadObject["config"] else {
                XCTFail("Expected config object")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(config["viscosity"], .number(0.001))
            XCTAssertEqual(config["density"], .number(1.2))
            XCTAssertEqual(config["t_final"], .number(1.0))
            XCTAssertEqual(config["dt"], .number(0.05))
            guard case .array(let boundaries)? = config["bcs"] else {
                XCTFail("Expected bcs")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(boundaries.count, 3)

            let summaryPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("NavierStokes"),
                "energy": .number(1.5),
                "iterations": .number(42),
                "error_norm": .number(0.0)
            ])
            let resultPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("NavierStokes"),
                "solver_backend": .string("mfem")
            ])
            let encoder = JSONCoding.makeEncoder(prettyPrinted: true)
            try encoder.encode(summaryPayload).write(to: summaryURL, options: .atomic)
            try encoder.encode(resultPayload).write(to: resultURL, options: .atomic)
            try "vtk placeholder\n".write(to: vtkURL, atomically: true, encoding: .utf8)
            try "<VTKFile></VTKFile>\n".write(
                to: tempBase.appendingPathComponent("solution.pvd"),
                atomically: true,
                encoding: .utf8
            )
            return FEADriverExecutionResult(exitCode: 0, stdout: "cfd stdout", stderr: "", elapsedMS: 22)
        }

        let tool = CFDTool(driverRunner: runner, driverResolver: { "/usr/local/bin/mfem-driver" })
        let context = ToolExecutionContext(jobID: "job_9991", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "solver_class": .string("NavierStokes"),
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "viscosity": .number(0.001),
                "density": .number(1.2),
                "dt": .number(0.05),
                "t_final": .number(1.0),
                "bcs": .array([
                    .object([
                        "attr": .number(1),
                        "type": .string("inlet"),
                        "velocity": .array([.number(1), .number(0), .number(0)])
                    ]),
                    .object([
                        "attr": .number(2),
                        "type": .string("outlet"),
                        "pressure": .number(0)
                    ]),
                    .object([
                        "attr": .number(3),
                        "type": .string("wall"),
                        "velocity": .array([.number(0), .number(0), .number(0)])
                    ])
                ])
            ])
        ])

        let result = try tool.run(input: input, context: context)
        guard case .object(let object) = result else {
            return XCTFail("Expected object result from CFDTool.")
        }
        XCTAssertEqual(object["status"], .string("ok"))
        XCTAssertEqual(object["solver"], .string("mfem"))
        XCTAssertEqual(object["exit_code"], .number(0))
        guard case .array(let artifacts)? = object["artifacts"] else {
            return XCTFail("Expected artifacts array.")
        }
        let names = artifacts.compactMap { value -> String? in
            guard case .object(let object) = value,
                  case .string(let name)? = object["name"] else {
                return nil
            }
            return name
        }
        XCTAssertTrue(names.contains("solution.pvd"))
    }

    func testCFDToolRejectsUnsupportedBoundaryType() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-cfd-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let tool = CFDTool(
            driverRunner: { _, _, _, _, _, _, _ in
                XCTFail("Driver runner should not be called for invalid input.")
                return FEADriverExecutionResult(exitCode: 0, stdout: "", stderr: "", elapsedMS: 0)
            },
            driverResolver: { "/usr/local/bin/mfem-driver" }
        )
        let context = ToolExecutionContext(jobID: "job_9992", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "viscosity": .number(0.001),
                "density": .number(1.0),
                "dt": .number(0.1),
                "t_final": .number(1.0),
                "bcs": .array([
                    .object([
                        "attr": .number(1),
                        "type": .string("slip")
                    ])
                ])
            ])
        ])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "invalid_input")
        }
    }

    func testAdvectionToolTransformsInputForDriver() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-advection-mock-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let runner: FEADriverRunner = { driverExecutable, inputURL, resultURL, summaryURL, vtkURL, _, _ in
            XCTAssertEqual(URL(fileURLWithPath: driverExecutable).lastPathComponent, "mfem-driver")

            let payloadData = try Data(contentsOf: inputURL)
            let payload = try JSONCoding.makeDecoder().decode(JSONValue.self, from: payloadData)
            guard case .object(let payloadObject) = payload else {
                XCTFail("Expected object payload")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }

            XCTAssertEqual(payloadObject["solver_class"], .string("Advection"))
            guard case .object(let config)? = payloadObject["config"] else {
                XCTFail("Expected config object")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(config["velocity_field"], .array([.number(1.0), .number(0.5), .number(0.0)]))
            XCTAssertEqual(config["dt"], .number(0.01))
            XCTAssertEqual(config["t_final"], .number(5.0))
            guard case .object(let initialCondition)? = config["initial_condition"] else {
                XCTFail("Expected initial_condition object")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(initialCondition["type"], .string("step_function"))
            XCTAssertEqual(initialCondition["radius"], .number(0.5))
            XCTAssertEqual(initialCondition["value"], .number(1.0))
            guard case .array(let bcs)? = config["bcs"] else {
                XCTFail("Expected bcs array")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(bcs.count, 1)

            let summaryPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("Advection"),
                "energy": .number(1.0),
                "iterations": .number(500),
                "error_norm": .number(0.0)
            ])
            let resultPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("Advection"),
                "solver_backend": .string("mfem")
            ])
            let encoder = JSONCoding.makeEncoder(prettyPrinted: true)
            try encoder.encode(summaryPayload).write(to: summaryURL, options: .atomic)
            try encoder.encode(resultPayload).write(to: resultURL, options: .atomic)
            try "vtk placeholder\n".write(to: vtkURL, atomically: true, encoding: .utf8)
            try "<VTKFile></VTKFile>\n".write(
                to: tempBase.appendingPathComponent("solution.pvd"),
                atomically: true,
                encoding: .utf8
            )
            return FEADriverExecutionResult(exitCode: 0, stdout: "advection stdout", stderr: "", elapsedMS: 19)
        }

        let tool = AdvectionTool(driverRunner: runner, driverResolver: { "/usr/local/bin/mfem-driver" })
        let context = ToolExecutionContext(jobID: "job_99920", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "solver_class": .string("Advection"),
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "velocity_field": .array([.number(1.0), .number(0.5), .number(0.0)]),
                "dt": .number(0.01),
                "t_final": .number(5.0),
                "initial_condition": .object([
                    "type": .string("step_function"),
                    "center": .array([.number(0.0), .number(0.0), .number(0.0)]),
                    "radius": .number(0.5),
                    "value": .number(1.0)
                ]),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("inflow"),
                        "value": .number(0.0)
                    ])
                ])
            ])
        ])

        let result = try tool.run(input: input, context: context)
        guard case .object(let object) = result else {
            return XCTFail("Expected object result from AdvectionTool.")
        }
        XCTAssertEqual(object["status"], .string("ok"))
        XCTAssertEqual(object["solver"], .string("mfem"))
        XCTAssertEqual(object["exit_code"], .number(0))
    }

    func testAdvectionToolRejectsUnsupportedBoundaryType() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-advection-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let tool = AdvectionTool(
            driverRunner: { _, _, _, _, _, _, _ in
                XCTFail("Driver runner should not be called for invalid input.")
                return FEADriverExecutionResult(exitCode: 0, stdout: "", stderr: "", elapsedMS: 0)
            },
            driverResolver: { "/usr/local/bin/mfem-driver" }
        )
        let context = ToolExecutionContext(jobID: "job_99921", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "velocity_field": .array([.number(1.0), .number(0.0), .number(0.0)]),
                "dt": .number(0.01),
                "t_final": .number(1.0),
                "initial_condition": .object([
                    "type": .string("step_function"),
                    "center": .array([.number(0.0), .number(0.0), .number(0.0)]),
                    "radius": .number(0.5),
                    "value": .number(1.0)
                ]),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("outflow"),
                        "value": .number(0.0)
                    ])
                ])
            ])
        ])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "invalid_input")
        }
    }

    func testCompressibleToolTransformsInputForDriver() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-compressible-mock-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let runner: FEADriverRunner = { driverExecutable, inputURL, resultURL, summaryURL, vtkURL, _, _ in
            XCTAssertEqual(URL(fileURLWithPath: driverExecutable).lastPathComponent, "mfem-driver")

            let payloadData = try Data(contentsOf: inputURL)
            let payload = try JSONCoding.makeDecoder().decode(JSONValue.self, from: payloadData)
            guard case .object(let payloadObject) = payload else {
                XCTFail("Expected object payload")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }

            XCTAssertEqual(payloadObject["solver_class"], .string("CompressibleEuler"))
            guard case .object(let config)? = payloadObject["config"] else {
                XCTFail("Expected config object")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(config["specific_heat_ratio"], .number(1.4))
            XCTAssertEqual(config["dt"], .number(0.0001))
            XCTAssertEqual(config["t_final"], .number(2.0))
            guard case .object(let initialCondition)? = config["initial_condition"] else {
                XCTFail("Expected initial_condition object")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(initialCondition["type"], .string("shock_tube"))
            XCTAssertEqual(initialCondition["left_state"], .array([.number(1.0), .number(0.0), .number(1.0)]))
            XCTAssertEqual(initialCondition["right_state"], .array([.number(0.125), .number(0.0), .number(0.1)]))

            let summaryPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("CompressibleEuler"),
                "energy": .number(10.0),
                "iterations": .number(150),
                "error_norm": .number(0.0)
            ])
            let resultPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("CompressibleEuler"),
                "solver_backend": .string("mfem")
            ])
            let encoder = JSONCoding.makeEncoder(prettyPrinted: true)
            try encoder.encode(summaryPayload).write(to: summaryURL, options: .atomic)
            try encoder.encode(resultPayload).write(to: resultURL, options: .atomic)
            try "vtk placeholder\n".write(to: vtkURL, atomically: true, encoding: .utf8)
            try "<VTKFile></VTKFile>\n".write(
                to: tempBase.appendingPathComponent("solution.pvd"),
                atomically: true,
                encoding: .utf8
            )
            return FEADriverExecutionResult(exitCode: 0, stdout: "compressible stdout", stderr: "", elapsedMS: 29)
        }

        let tool = CompressibleFlowTool(driverRunner: runner, driverResolver: { "/usr/local/bin/mfem-driver" })
        let context = ToolExecutionContext(jobID: "job_99922", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "solver_class": .string("CompressibleEuler"),
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "specific_heat_ratio": .number(1.4),
                "dt": .number(0.0001),
                "t_final": .number(2.0),
                "initial_condition": .object([
                    "type": .string("shock_tube"),
                    "left_state": .array([.number(1.0), .number(0.0), .number(1.0)]),
                    "right_state": .array([.number(0.125), .number(0.0), .number(0.1)])
                ]),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("slip_wall")
                    ])
                ])
            ])
        ])

        let result = try tool.run(input: input, context: context)
        guard case .object(let object) = result else {
            return XCTFail("Expected object result from CompressibleFlowTool.")
        }
        XCTAssertEqual(object["status"], .string("ok"))
        XCTAssertEqual(object["solver"], .string("mfem"))
        XCTAssertEqual(object["exit_code"], .number(0))
    }

    func testCompressibleToolRejectsUnsupportedBoundaryType() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-compressible-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let tool = CompressibleFlowTool(
            driverRunner: { _, _, _, _, _, _, _ in
                XCTFail("Driver runner should not be called for invalid input.")
                return FEADriverExecutionResult(exitCode: 0, stdout: "", stderr: "", elapsedMS: 0)
            },
            driverResolver: { "/usr/local/bin/mfem-driver" }
        )
        let context = ToolExecutionContext(jobID: "job_99923", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "specific_heat_ratio": .number(1.4),
                "dt": .number(0.0001),
                "t_final": .number(0.1),
                "initial_condition": .object([
                    "type": .string("shock_tube"),
                    "left_state": .array([.number(1.0), .number(0.0), .number(1.0)]),
                    "right_state": .array([.number(0.125), .number(0.0), .number(0.1)])
                ]),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("outflow")
                    ])
                ])
            ])
        ])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "invalid_input")
        }
    }

    func testAcousticsToolTransformsInputForAcousticWaveDriver() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-acoustics-mock-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let runner: FEADriverRunner = { driverExecutable, inputURL, resultURL, summaryURL, vtkURL, _, _ in
            XCTAssertEqual(URL(fileURLWithPath: driverExecutable).lastPathComponent, "mfem-driver")

            let payloadData = try Data(contentsOf: inputURL)
            let payload = try JSONCoding.makeDecoder().decode(JSONValue.self, from: payloadData)
            guard case .object(let payloadObject) = payload else {
                XCTFail("Expected object payload")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(payloadObject["solver_class"], .string("AcousticWave"))

            guard case .object(let config)? = payloadObject["config"] else {
                XCTFail("Expected config object")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(config["wave_speed"], .number(343.0))
            XCTAssertEqual(config["dt"], .number(0.001))
            XCTAssertEqual(config["t_final"], .number(0.5))
            guard case .object(let initialCondition)? = config["initial_condition"] else {
                XCTFail("Expected initial_condition object")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(initialCondition["type"], .string("gaussian_pulse"))
            XCTAssertEqual(initialCondition["amplitude"], .number(1.0))
            XCTAssertEqual(
                initialCondition["center"],
                .array([.number(0.0), .number(0.0), .number(0.0)])
            )
            guard case .array(let boundaries)? = config["bcs"] else {
                XCTFail("Expected bcs array")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(boundaries.count, 1)
            if case .object(let firstBoundary) = boundaries[0] {
                XCTAssertEqual(firstBoundary["type"], .string("rigid_wall"))
                XCTAssertEqual(firstBoundary["attribute"], .number(1))
            } else {
                XCTFail("Expected first boundary object")
            }

            let summaryPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("AcousticWave"),
                "energy": .number(1.5),
                "iterations": .number(14),
                "error_norm": .number(0.0)
            ])
            let resultPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("AcousticWave"),
                "solver_backend": .string("mfem")
            ])
            let encoder = JSONCoding.makeEncoder(prettyPrinted: true)
            try encoder.encode(summaryPayload).write(to: summaryURL, options: .atomic)
            try encoder.encode(resultPayload).write(to: resultURL, options: .atomic)
            try "vtk placeholder\n".write(to: vtkURL, atomically: true, encoding: .utf8)
            try "<VTKFile></VTKFile>\n".write(
                to: tempBase.appendingPathComponent("solution.pvd"),
                atomically: true,
                encoding: .utf8
            )
            return FEADriverExecutionResult(exitCode: 0, stdout: "acoustics stdout", stderr: "", elapsedMS: 17)
        }

        let tool = AcousticsTool(driverRunner: runner, driverResolver: { "/usr/local/bin/mfem-driver" })
        let context = ToolExecutionContext(jobID: "job_99921", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "solver_class": .string("AcousticWave"),
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "wave_speed": .number(343.0),
                "dt": .number(0.001),
                "t_final": .number(0.5),
                "initial_condition": .object([
                    "type": .string("gaussian_pulse"),
                    "amplitude": .number(1.0),
                    "center": .array([.number(0.0), .number(0.0), .number(0.0)])
                ]),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("rigid_wall")
                    ])
                ])
            ])
        ])

        let result = try tool.run(input: input, context: context)
        guard case .object(let object) = result else {
            return XCTFail("Expected object result from AcousticsTool.")
        }
        XCTAssertEqual(object["status"], .string("ok"))
        XCTAssertEqual(object["solver"], .string("mfem"))
        XCTAssertEqual(object["exit_code"], .number(0))
        guard case .array(let artifacts)? = object["artifacts"] else {
            return XCTFail("Expected artifacts array.")
        }
        let names = artifacts.compactMap { value -> String? in
            guard case .object(let object) = value,
                  case .string(let name)? = object["name"] else {
                return nil
            }
            return name
        }
        XCTAssertTrue(names.contains("solution.pvd"))
    }

    func testAcousticsToolRejectsUnsupportedBoundaryType() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-acoustics-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let tool = AcousticsTool(
            driverRunner: { _, _, _, _, _, _, _ in
                XCTFail("Driver runner should not be called for invalid input.")
                return FEADriverExecutionResult(exitCode: 0, stdout: "", stderr: "", elapsedMS: 0)
            },
            driverResolver: { "/usr/local/bin/mfem-driver" }
        )
        let context = ToolExecutionContext(jobID: "job_99922", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "wave_speed": .number(343.0),
                "dt": .number(0.001),
                "t_final": .number(0.5),
                "initial_condition": .object([
                    "type": .string("gaussian_pulse"),
                    "amplitude": .number(1.0),
                    "center": .array([.number(0.0), .number(0.0), .number(0.0)])
                ]),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("absorbing")
                    ])
                ])
            ])
        ])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "invalid_input")
        }
    }

    func testEigenvalueToolTransformsInputForEigenvalueDriver() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-eigen-mock-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let runner: FEADriverRunner = { driverExecutable, inputURL, resultURL, summaryURL, vtkURL, _, _ in
            XCTAssertEqual(URL(fileURLWithPath: driverExecutable).lastPathComponent, "mfem-driver")

            let payloadData = try Data(contentsOf: inputURL)
            let payload = try JSONCoding.makeDecoder().decode(JSONValue.self, from: payloadData)
            guard case .object(let payloadObject) = payload else {
                XCTFail("Expected object payload")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(payloadObject["solver_class"], .string("Eigenvalue"))

            guard case .object(let config)? = payloadObject["config"] else {
                XCTFail("Expected config object")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(config["material_coefficient"], .number(1.0))
            XCTAssertEqual(config["num_eigenmodes"], .number(5))
            guard case .array(let boundaries)? = config["bcs"] else {
                XCTFail("Expected bcs array")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(boundaries.count, 1)
            if case .object(let firstBoundary) = boundaries[0] {
                XCTAssertEqual(firstBoundary["type"], .string("fixed"))
                XCTAssertEqual(firstBoundary["attribute"], .number(1))
            } else {
                XCTFail("Expected first boundary object")
            }

            let summaryPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("Eigenvalue"),
                "energy": .number(3.2),
                "iterations": .number(5),
                "error_norm": .number(0.0)
            ])
            let resultPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("Eigenvalue"),
                "solver_backend": .string("mfem")
            ])
            let encoder = JSONCoding.makeEncoder(prettyPrinted: true)
            try encoder.encode(summaryPayload).write(to: summaryURL, options: .atomic)
            try encoder.encode(resultPayload).write(to: resultURL, options: .atomic)
            try "vtk placeholder\n".write(to: vtkURL, atomically: true, encoding: .utf8)
            try "{ \"eigenvalues\": [3.2, 4.1] }\n".write(
                to: tempBase.appendingPathComponent("eigenvalues.json"),
                atomically: true,
                encoding: .utf8
            )
            return FEADriverExecutionResult(exitCode: 0, stdout: "eigen stdout", stderr: "", elapsedMS: 16)
        }

        let tool = EigenvalueTool(driverRunner: runner, driverResolver: { "/usr/local/bin/mfem-driver" })
        let context = ToolExecutionContext(jobID: "job_99923", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "solver_class": .string("Eigenvalue"),
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "material_coefficient": .number(1.0),
                "num_eigenmodes": .number(5),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("fixed")
                    ])
                ])
            ])
        ])

        let result = try tool.run(input: input, context: context)
        guard case .object(let object) = result else {
            return XCTFail("Expected object result from EigenvalueTool.")
        }
        XCTAssertEqual(object["status"], .string("ok"))
        XCTAssertEqual(object["solver"], .string("mfem"))
        XCTAssertEqual(object["exit_code"], .number(0))
        guard case .array(let artifacts)? = object["artifacts"] else {
            return XCTFail("Expected artifacts array.")
        }
        let names = artifacts.compactMap { value -> String? in
            guard case .object(let object) = value,
                  case .string(let name)? = object["name"] else {
                return nil
            }
            return name
        }
        XCTAssertTrue(names.contains("eigenvalues.json"))
    }

    func testEigenvalueToolRejectsUnsupportedBoundaryType() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-eigen-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let tool = EigenvalueTool(
            driverRunner: { _, _, _, _, _, _, _ in
                XCTFail("Driver runner should not be called for invalid input.")
                return FEADriverExecutionResult(exitCode: 0, stdout: "", stderr: "", elapsedMS: 0)
            },
            driverResolver: { "/usr/local/bin/mfem-driver" }
        )
        let context = ToolExecutionContext(jobID: "job_99924", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "material_coefficient": .number(1.0),
                "num_eigenmodes": .number(5),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("roller")
                    ])
                ])
            ])
        ])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "invalid_input")
        }
    }

    func testStructuralModalToolTransformsInputForDriver() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-structural-modal-mock-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let runner: FEADriverRunner = { driverExecutable, inputURL, resultURL, summaryURL, vtkURL, _, _ in
            XCTAssertEqual(URL(fileURLWithPath: driverExecutable).lastPathComponent, "mfem-driver")

            let payloadData = try Data(contentsOf: inputURL)
            let payload = try JSONCoding.makeDecoder().decode(JSONValue.self, from: payloadData)
            guard case .object(let payloadObject) = payload else {
                XCTFail("Expected object payload")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(payloadObject["solver_class"], .string("StructuralModal"))

            guard case .object(let config)? = payloadObject["config"] else {
                XCTFail("Expected config object")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(config["density"], .number(7800.0))
            XCTAssertEqual(config["youngs_modulus"], .number(200_000_000_000.0))
            XCTAssertEqual(config["poisson_ratio"], .number(0.3))
            XCTAssertEqual(config["num_modes"], .number(10))
            guard case .array(let boundaries)? = config["bcs"] else {
                XCTFail("Expected bcs array")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(boundaries.count, 1)
            if case .object(let firstBoundary) = boundaries[0] {
                XCTAssertEqual(firstBoundary["type"], .string("fixed"))
                XCTAssertEqual(firstBoundary["attribute"], .number(1))
            } else {
                XCTFail("Expected first boundary object")
            }

            let summaryPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("StructuralModal"),
                "energy": .number(25.0),
                "iterations": .number(10),
                "error_norm": .number(0.0)
            ])
            let resultPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("StructuralModal"),
                "solver_backend": .string("mfem")
            ])
            let encoder = JSONCoding.makeEncoder(prettyPrinted: true)
            try encoder.encode(summaryPayload).write(to: summaryURL, options: .atomic)
            try encoder.encode(resultPayload).write(to: resultURL, options: .atomic)
            try "vtk placeholder\n".write(to: vtkURL, atomically: true, encoding: .utf8)
            try "{ \"eigenvalues\": [25.0, 40.0] }\n".write(
                to: tempBase.appendingPathComponent("structural_modes.json"),
                atomically: true,
                encoding: .utf8
            )
            return FEADriverExecutionResult(exitCode: 0, stdout: "structural modal stdout", stderr: "", elapsedMS: 18)
        }

        let tool = StructuralModalTool(driverRunner: runner, driverResolver: { "/usr/local/bin/mfem-driver" })
        let context = ToolExecutionContext(jobID: "job_999241", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "solver_class": .string("StructuralModal"),
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "density": .number(7800.0),
                "youngs_modulus": .number(200_000_000_000.0),
                "poisson_ratio": .number(0.3),
                "num_modes": .number(10),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("fixed")
                    ])
                ])
            ])
        ])

        let result = try tool.run(input: input, context: context)
        guard case .object(let object) = result else {
            return XCTFail("Expected object result from StructuralModalTool.")
        }
        XCTAssertEqual(object["status"], .string("ok"))
        XCTAssertEqual(object["solver"], .string("mfem"))
        XCTAssertEqual(object["exit_code"], .number(0))
        guard case .array(let artifacts)? = object["artifacts"] else {
            return XCTFail("Expected artifacts array.")
        }
        let names = artifacts.compactMap { value -> String? in
            guard case .object(let object) = value,
                  case .string(let name)? = object["name"] else {
                return nil
            }
            return name
        }
        XCTAssertTrue(names.contains("structural_modes.json"))
    }

    func testStructuralModalToolRejectsUnsupportedBoundaryType() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-structural-modal-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let tool = StructuralModalTool(
            driverRunner: { _, _, _, _, _, _, _ in
                XCTFail("Driver runner should not be called for invalid input.")
                return FEADriverExecutionResult(exitCode: 0, stdout: "", stderr: "", elapsedMS: 0)
            },
            driverResolver: { "/usr/local/bin/mfem-driver" }
        )
        let context = ToolExecutionContext(jobID: "job_999242", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "density": .number(7800.0),
                "youngs_modulus": .number(200_000_000_000.0),
                "poisson_ratio": .number(0.3),
                "num_modes": .number(10),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("roller")
                    ])
                ])
            ])
        ])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "invalid_input")
        }
    }

    func testHeatToolTransformsInputForHeatTransferDriver() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-heat-mock-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let runner: FEADriverRunner = { driverExecutable, inputURL, resultURL, summaryURL, vtkURL, _, _ in
            XCTAssertEqual(URL(fileURLWithPath: driverExecutable).lastPathComponent, "mfem-driver")

            let payloadData = try Data(contentsOf: inputURL)
            let payload = try JSONCoding.makeDecoder().decode(JSONValue.self, from: payloadData)
            guard case .object(let payloadObject) = payload else {
                XCTFail("Expected object payload")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(payloadObject["solver_class"], .string("HeatTransfer"))

            guard case .object(let config)? = payloadObject["config"] else {
                XCTFail("Expected config object")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(config["conductivity"], .number(1.0))
            XCTAssertEqual(config["specific_heat"], .number(1.2))
            XCTAssertEqual(config["initial_temperature"], .number(293.15))
            XCTAssertEqual(config["dt"], .number(0.01))
            XCTAssertEqual(config["t_final"], .number(0.5))
            guard case .array(let boundaries)? = config["bcs"] else {
                XCTFail("Expected bcs array")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(boundaries.count, 2)

            let summaryPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("HeatTransfer"),
                "energy": .number(2.5),
                "iterations": .number(11),
                "error_norm": .number(0.0)
            ])
            let resultPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("HeatTransfer"),
                "solver_backend": .string("mfem")
            ])
            let encoder = JSONCoding.makeEncoder(prettyPrinted: true)
            try encoder.encode(summaryPayload).write(to: summaryURL, options: .atomic)
            try encoder.encode(resultPayload).write(to: resultURL, options: .atomic)
            try "vtk placeholder\n".write(to: vtkURL, atomically: true, encoding: .utf8)
            try "<VTKFile></VTKFile>\n".write(
                to: tempBase.appendingPathComponent("solution.pvd"),
                atomically: true,
                encoding: .utf8
            )
            return FEADriverExecutionResult(exitCode: 0, stdout: "heat stdout", stderr: "", elapsedMS: 18)
        }

        let tool = HeatTool(driverRunner: runner, driverResolver: { "/usr/local/bin/mfem-driver" })
        let context = ToolExecutionContext(jobID: "job_9993", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "solver_class": .string("HeatTransfer"),
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "conductivity": .number(1.0),
                "specific_heat": .number(1.2),
                "initial_temperature": .number(293.15),
                "dt": .number(0.01),
                "t_final": .number(0.5),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("fixed_temp"),
                        "value": .number(350.0)
                    ]),
                    .object([
                        "attribute": .number(2),
                        "type": .string("heat_flux"),
                        "value": .number(50.0)
                    ])
                ])
            ])
        ])

        let result = try tool.run(input: input, context: context)
        guard case .object(let object) = result else {
            return XCTFail("Expected object result from HeatTool.")
        }
        XCTAssertEqual(object["status"], .string("ok"))
        XCTAssertEqual(object["solver"], .string("mfem"))
        XCTAssertEqual(object["exit_code"], .number(0))
        guard case .array(let artifacts)? = object["artifacts"] else {
            return XCTFail("Expected artifacts array.")
        }
        let names = artifacts.compactMap { value -> String? in
            guard case .object(let object) = value,
                  case .string(let name)? = object["name"] else {
                return nil
            }
            return name
        }
        XCTAssertTrue(names.contains("solution.pvd"))
    }

    func testHeatToolRejectsUnsupportedBoundaryType() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-heat-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let tool = HeatTool(
            driverRunner: { _, _, _, _, _, _, _ in
                XCTFail("Driver runner should not be called for invalid input.")
                return FEADriverExecutionResult(exitCode: 0, stdout: "", stderr: "", elapsedMS: 0)
            },
            driverResolver: { "/usr/local/bin/mfem-driver" }
        )
        let context = ToolExecutionContext(jobID: "job_9994", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "conductivity": .number(1.0),
                "specific_heat": .number(1.0),
                "initial_temperature": .number(293.15),
                "dt": .number(0.01),
                "t_final": .number(1.0),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("convective"),
                        "value": .number(5.0)
                    ])
                ])
            ])
        ])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "invalid_input")
        }
    }

    func testJouleHeatingToolTransformsInputForDriver() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-joule-heating-mock-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let runner: FEADriverRunner = { driverExecutable, inputURL, resultURL, summaryURL, vtkURL, _, _ in
            XCTAssertEqual(URL(fileURLWithPath: driverExecutable).lastPathComponent, "mfem-driver")

            let payloadData = try Data(contentsOf: inputURL)
            let payload = try JSONCoding.makeDecoder().decode(JSONValue.self, from: payloadData)
            guard case .object(let payloadObject) = payload else {
                XCTFail("Expected object payload")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(payloadObject["solver_class"], .string("JouleHeating"))

            guard case .object(let config)? = payloadObject["config"] else {
                XCTFail("Expected config object")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(config["electrical_conductivity"], .number(5.96e7))
            XCTAssertEqual(config["thermal_conductivity"], .number(400.0))
            XCTAssertEqual(config["heat_capacity"], .number(3.4e6))
            XCTAssertEqual(config["dt"], .number(0.1))
            XCTAssertEqual(config["t_final"], .number(1.0))
            guard case .array(let boundaries)? = config["bcs"] else {
                XCTFail("Expected bcs array")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(boundaries.count, 3)

            let summaryPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("JouleHeating"),
                "energy": .number(12.0),
                "iterations": .number(5),
                "error_norm": .number(0.0)
            ])
            let resultPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("JouleHeating"),
                "solver_backend": .string("mfem")
            ])
            let encoder = JSONCoding.makeEncoder(prettyPrinted: true)
            try encoder.encode(summaryPayload).write(to: summaryURL, options: .atomic)
            try encoder.encode(resultPayload).write(to: resultURL, options: .atomic)
            try "vtk placeholder\n".write(to: vtkURL, atomically: true, encoding: .utf8)
            try "<VTKFile></VTKFile>\n".write(
                to: tempBase.appendingPathComponent("solution.pvd"),
                atomically: true,
                encoding: .utf8
            )
            return FEADriverExecutionResult(exitCode: 0, stdout: "joule stdout", stderr: "", elapsedMS: 15)
        }

        let tool = JouleHeatingTool(driverRunner: runner, driverResolver: { "/usr/local/bin/mfem-driver" })
        let context = ToolExecutionContext(jobID: "job_99945", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "solver_class": .string("joule_heating"),
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "electrical_conductivity": .number(5.96e7),
                "thermal_conductivity": .number(400.0),
                "heat_capacity": .number(3.4e6),
                "dt": .number(0.1),
                "t_final": .number(1.0),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("voltage"),
                        "value": .number(5.0)
                    ]),
                    .object([
                        "attribute": .number(2),
                        "type": .string("ground"),
                        "value": .number(0.0)
                    ]),
                    .object([
                        "attribute": .number(3),
                        "type": .string("fixed_temp"),
                        "value": .number(293.15)
                    ])
                ])
            ])
        ])

        let result = try tool.run(input: input, context: context)
        guard case .object(let object) = result else {
            return XCTFail("Expected object result from JouleHeatingTool.")
        }
        XCTAssertEqual(object["status"], .string("ok"))
        XCTAssertEqual(object["solver"], .string("mfem"))
        XCTAssertEqual(object["exit_code"], .number(0))
        guard case .array(let artifacts)? = object["artifacts"] else {
            return XCTFail("Expected artifacts array.")
        }
        let names = artifacts.compactMap { value -> String? in
            guard case .object(let object) = value,
                  case .string(let name)? = object["name"] else {
                return nil
            }
            return name
        }
        XCTAssertTrue(names.contains("solution.pvd"))
    }

    func testJouleHeatingToolRejectsUnsupportedBoundaryType() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-joule-heating-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let tool = JouleHeatingTool(
            driverRunner: { _, _, _, _, _, _, _ in
                XCTFail("Driver runner should not be called for invalid input.")
                return FEADriverExecutionResult(exitCode: 0, stdout: "", stderr: "", elapsedMS: 0)
            },
            driverResolver: { "/usr/local/bin/mfem-driver" }
        )
        let context = ToolExecutionContext(jobID: "job_99946", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "electrical_conductivity": .number(5.96e7),
                "thermal_conductivity": .number(400.0),
                "heat_capacity": .number(3.4e6),
                "dt": .number(0.1),
                "t_final": .number(1.0),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("convection"),
                        "value": .number(5.0)
                    ]),
                    .object([
                        "attribute": .number(3),
                        "type": .string("fixed_temp"),
                        "value": .number(293.15)
                    ])
                ])
            ])
        ])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "invalid_input")
        }
    }

    func testElectrostaticsToolTransformsInputForElectrostaticsDriver() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-electrostatics-mock-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let runner: FEADriverRunner = { driverExecutable, inputURL, resultURL, summaryURL, vtkURL, _, _ in
            XCTAssertEqual(URL(fileURLWithPath: driverExecutable).lastPathComponent, "mfem-driver")

            let payloadData = try Data(contentsOf: inputURL)
            let payload = try JSONCoding.makeDecoder().decode(JSONValue.self, from: payloadData)
            guard case .object(let payloadObject) = payload else {
                XCTFail("Expected object payload")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(payloadObject["solver_class"], .string("Electrostatics"))

            guard case .object(let config)? = payloadObject["config"] else {
                XCTFail("Expected config object")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(config["permittivity"], .number(8.854e-12))
            XCTAssertEqual(config["charge_density"], .number(0.0))
            guard case .array(let boundaries)? = config["bcs"] else {
                XCTFail("Expected bcs array")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(boundaries.count, 2)

            let summaryPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("Electrostatics"),
                "energy": .number(0.1),
                "iterations": .number(0),
                "error_norm": .number(0.0)
            ])
            let resultPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("Electrostatics"),
                "solver_backend": .string("mfem")
            ])
            let encoder = JSONCoding.makeEncoder(prettyPrinted: true)
            try encoder.encode(summaryPayload).write(to: summaryURL, options: .atomic)
            try encoder.encode(resultPayload).write(to: resultURL, options: .atomic)
            try "vtk placeholder\n".write(to: vtkURL, atomically: true, encoding: .utf8)
            try "<VTKFile></VTKFile>\n".write(
                to: tempBase.appendingPathComponent("solution.pvd"),
                atomically: true,
                encoding: .utf8
            )
            return FEADriverExecutionResult(exitCode: 0, stdout: "electrostatics stdout", stderr: "", elapsedMS: 19)
        }

        let tool = ElectrostaticsTool(driverRunner: runner, driverResolver: { "/usr/local/bin/mfem-driver" })
        let context = ToolExecutionContext(jobID: "job_9995", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "solver_class": .string("Electrostatics"),
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "permittivity": .number(8.854e-12),
                "charge_density": .number(0.0),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("fixed_voltage"),
                        "value": .number(100.0)
                    ]),
                    .object([
                        "attribute": .number(2),
                        "type": .string("surface_charge"),
                        "value": .number(0.0)
                    ])
                ])
            ])
        ])

        let result = try tool.run(input: input, context: context)
        guard case .object(let object) = result else {
            return XCTFail("Expected object result from ElectrostaticsTool.")
        }
        XCTAssertEqual(object["status"], .string("ok"))
        XCTAssertEqual(object["solver"], .string("mfem"))
        XCTAssertEqual(object["exit_code"], .number(0))
        guard case .array(let artifacts)? = object["artifacts"] else {
            return XCTFail("Expected artifacts array.")
        }
        let names = artifacts.compactMap { value -> String? in
            guard case .object(let object) = value,
                  case .string(let name)? = object["name"] else {
                return nil
            }
            return name
        }
        XCTAssertTrue(names.contains("solution.pvd"))
    }

    func testElectrostaticsToolRejectsUnsupportedBoundaryType() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-electrostatics-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let tool = ElectrostaticsTool(
            driverRunner: { _, _, _, _, _, _, _ in
                XCTFail("Driver runner should not be called for invalid input.")
                return FEADriverExecutionResult(exitCode: 0, stdout: "", stderr: "", elapsedMS: 0)
            },
            driverResolver: { "/usr/local/bin/mfem-driver" }
        )
        let context = ToolExecutionContext(jobID: "job_9996", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "permittivity": .number(8.854e-12),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("floating"),
                        "value": .number(100.0)
                    ])
                ])
            ])
        ])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "invalid_input")
        }
    }

    func testAMRLaplaceToolTransformsInputForDriver() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-amr-laplace-mock-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let runner: FEADriverRunner = { driverExecutable, inputURL, resultURL, summaryURL, vtkURL, _, _ in
            XCTAssertEqual(URL(fileURLWithPath: driverExecutable).lastPathComponent, "mfem-driver")

            let payloadData = try Data(contentsOf: inputURL)
            let payload = try JSONCoding.makeDecoder().decode(JSONValue.self, from: payloadData)
            guard case .object(let payloadObject) = payload else {
                XCTFail("Expected object payload")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(payloadObject["solver_class"], .string("AMRLaplace"))

            guard case .object(let config)? = payloadObject["config"] else {
                XCTFail("Expected config object")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(config["coefficient"], .number(1.0))
            XCTAssertEqual(config["source_term"], .number(1.0))
            guard case .object(let amrSettings)? = config["amr_settings"] else {
                XCTFail("Expected amr_settings object")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(amrSettings["max_iterations"], .number(10))
            XCTAssertEqual(amrSettings["max_dofs"], .number(50000))
            XCTAssertEqual(amrSettings["error_tolerance"], .number(1.0e-4))
            guard case .array(let boundaries)? = config["bcs"] else {
                XCTFail("Expected bcs array")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(boundaries.count, 1)

            let summaryPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("AMRLaplace"),
                "energy": .number(0.5),
                "iterations": .number(3),
                "error_norm": .number(9.0e-5)
            ])
            let resultPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("AMRLaplace"),
                "solver_backend": .string("mfem")
            ])
            let encoder = JSONCoding.makeEncoder(prettyPrinted: true)
            try encoder.encode(summaryPayload).write(to: summaryURL, options: .atomic)
            try encoder.encode(resultPayload).write(to: resultURL, options: .atomic)
            try "vtk placeholder\n".write(to: vtkURL, atomically: true, encoding: .utf8)
            try "<VTKFile></VTKFile>\n".write(
                to: tempBase.appendingPathComponent("solution.pvd"),
                atomically: true,
                encoding: .utf8
            )
            try "{ \"solver_backend\": \"pcg_boomeramg\" }\n".write(
                to: tempBase.appendingPathComponent("amr_laplace.json"),
                atomically: true,
                encoding: .utf8
            )
            return FEADriverExecutionResult(exitCode: 0, stdout: "amr stdout", stderr: "", elapsedMS: 31)
        }

        let tool = AMRLaplaceTool(driverRunner: runner, driverResolver: { "/usr/local/bin/mfem-driver" })
        let context = ToolExecutionContext(jobID: "job_99960", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "solver_class": .string("AMRLaplace"),
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "coefficient": .number(1.0),
                "source_term": .number(1.0),
                "amr_settings": .object([
                    "max_iterations": .number(10),
                    "max_dofs": .number(50000),
                    "error_tolerance": .number(1.0e-4)
                ]),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("fixed"),
                        "value": .number(0.0)
                    ])
                ])
            ])
        ])

        let result = try tool.run(input: input, context: context)
        guard case .object(let object) = result else {
            return XCTFail("Expected object result from AMRLaplaceTool.")
        }
        XCTAssertEqual(object["status"], .string("ok"))
        XCTAssertEqual(object["solver"], .string("mfem"))
        XCTAssertEqual(object["exit_code"], .number(0))
        guard case .array(let artifacts)? = object["artifacts"] else {
            return XCTFail("Expected artifacts array.")
        }
        let names = artifacts.compactMap { value -> String? in
            guard case .object(let object) = value,
                  case .string(let name)? = object["name"] else {
                return nil
            }
            return name
        }
        XCTAssertTrue(names.contains("amr_laplace.json"))
    }

    func testAMRLaplaceToolRejectsUnsupportedBoundaryType() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-amr-laplace-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let tool = AMRLaplaceTool(
            driverRunner: { _, _, _, _, _, _, _ in
                XCTFail("Driver runner should not be called for invalid input.")
                return FEADriverExecutionResult(exitCode: 0, stdout: "", stderr: "", elapsedMS: 0)
            },
            driverResolver: { "/usr/local/bin/mfem-driver" }
        )
        let context = ToolExecutionContext(jobID: "job_999600", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "coefficient": .number(1.0),
                "source_term": .number(1.0),
                "amr_settings": .object([
                    "max_iterations": .number(10),
                    "max_dofs": .number(50000),
                    "error_tolerance": .number(1.0e-4)
                ]),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("flux"),
                        "value": .number(1.0)
                    ])
                ])
            ])
        ])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "invalid_input")
        }
    }

    func testDPGLaplaceToolTransformsInputForDriver() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-dpg-laplace-mock-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let runner: FEADriverRunner = { driverExecutable, inputURL, resultURL, summaryURL, vtkURL, _, _ in
            XCTAssertEqual(URL(fileURLWithPath: driverExecutable).lastPathComponent, "mfem-driver")

            let payloadData = try Data(contentsOf: inputURL)
            let payload = try JSONCoding.makeDecoder().decode(JSONValue.self, from: payloadData)
            guard case .object(let payloadObject) = payload else {
                XCTFail("Expected object payload")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(payloadObject["solver_class"], .string("DPGLaplace"))

            guard case .object(let config)? = payloadObject["config"] else {
                XCTFail("Expected config object")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(config["coefficient"], .number(1.0))
            XCTAssertEqual(config["source_term"], .number(1.0))
            XCTAssertEqual(config["order"], .number(2))
            guard case .array(let boundaries)? = config["bcs"] else {
                XCTFail("Expected bcs array")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(boundaries.count, 1)
            if case .object(let firstBoundary) = boundaries[0] {
                XCTAssertEqual(firstBoundary["attribute"], .number(1))
                XCTAssertEqual(firstBoundary["type"], .string("fixed"))
                XCTAssertEqual(firstBoundary["value"], .number(0.0))
            } else {
                XCTFail("Expected boundary object")
            }

            let summaryPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("DPGLaplace"),
                "energy": .number(0.42),
                "iterations": .number(12),
                "error_norm": .number(0.001)
            ])
            let resultPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("DPGLaplace"),
                "solver_backend": .string("mfem")
            ])
            let encoder = JSONCoding.makeEncoder(prettyPrinted: true)
            try encoder.encode(summaryPayload).write(to: summaryURL, options: .atomic)
            try encoder.encode(resultPayload).write(to: resultURL, options: .atomic)
            try "vtk placeholder\n".write(to: vtkURL, atomically: true, encoding: .utf8)
            try "<VTKFile></VTKFile>\n".write(
                to: tempBase.appendingPathComponent("solution.pvd"),
                atomically: true,
                encoding: .utf8
            )
            try "{ \"solver_backend\": \"dpg_normal_equation_pcg\" }\n".write(
                to: tempBase.appendingPathComponent("dpg_laplace.json"),
                atomically: true,
                encoding: .utf8
            )
            return FEADriverExecutionResult(exitCode: 0, stdout: "dpg stdout", stderr: "", elapsedMS: 28)
        }

        let tool = DPGLaplaceTool(driverRunner: runner, driverResolver: { "/usr/local/bin/mfem-driver" })
        let context = ToolExecutionContext(jobID: "job_999601", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "solver_class": .string("dpg_laplace"),
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "coefficient": .number(1.0),
                "source_term": .number(1.0),
                "order": .number(2),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("fixed"),
                        "value": .number(0.0)
                    ])
                ])
            ])
        ])

        let result = try tool.run(input: input, context: context)
        guard case .object(let object) = result else {
            return XCTFail("Expected object result from DPGLaplaceTool.")
        }
        XCTAssertEqual(object["status"], .string("ok"))
        XCTAssertEqual(object["solver"], .string("mfem"))
        XCTAssertEqual(object["exit_code"], .number(0))
        guard case .array(let artifacts)? = object["artifacts"] else {
            return XCTFail("Expected artifacts array.")
        }
        let names = artifacts.compactMap { value -> String? in
            guard case .object(let object) = value,
                  case .string(let name)? = object["name"] else {
                return nil
            }
            return name
        }
        XCTAssertTrue(names.contains("dpg_laplace.json"))
    }

    func testDPGLaplaceToolRejectsUnsupportedBoundaryType() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-dpg-laplace-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let tool = DPGLaplaceTool(
            driverRunner: { _, _, _, _, _, _, _ in
                XCTFail("Driver runner should not be called for invalid input.")
                return FEADriverExecutionResult(exitCode: 0, stdout: "", stderr: "", elapsedMS: 0)
            },
            driverResolver: { "/usr/local/bin/mfem-driver" }
        )
        let context = ToolExecutionContext(jobID: "job_999602", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "coefficient": .number(1.0),
                "source_term": .number(1.0),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("flux"),
                        "value": .number(1.0)
                    ])
                ])
            ])
        ])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "invalid_input")
        }
    }

    func testFractionalPDEToolTransformsInputForDriver() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-fractional-pde-mock-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let runner: FEADriverRunner = { driverExecutable, inputURL, resultURL, summaryURL, vtkURL, _, _ in
            XCTAssertEqual(URL(fileURLWithPath: driverExecutable).lastPathComponent, "mfem-driver")

            let payloadData = try Data(contentsOf: inputURL)
            let payload = try JSONCoding.makeDecoder().decode(JSONValue.self, from: payloadData)
            guard case .object(let payloadObject) = payload else {
                XCTFail("Expected object payload")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(payloadObject["solver_class"], .string("FractionalPDE"))

            guard case .object(let config)? = payloadObject["config"] else {
                XCTFail("Expected config object")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(config["alpha"], .number(0.5))
            XCTAssertEqual(config["num_poles"], .number(10))
            XCTAssertEqual(config["source_term"], .number(1.0))
            guard case .array(let boundaries)? = config["bcs"] else {
                XCTFail("Expected bcs array")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(boundaries.count, 1)

            let summaryPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("FractionalPDE"),
                "energy": .number(0.9),
                "iterations": .number(38),
                "error_norm": .number(0.02)
            ])
            let resultPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("FractionalPDE"),
                "solver_backend": .string("mfem")
            ])
            let encoder = JSONCoding.makeEncoder(prettyPrinted: true)
            try encoder.encode(summaryPayload).write(to: summaryURL, options: .atomic)
            try encoder.encode(resultPayload).write(to: resultURL, options: .atomic)
            try "vtk placeholder\n".write(to: vtkURL, atomically: true, encoding: .utf8)
            try "<VTKFile></VTKFile>\n".write(
                to: tempBase.appendingPathComponent("solution.pvd"),
                atomically: true,
                encoding: .utf8
            )
            try "{ \"solver_backend\": \"fractional_shifted_laplacian_pcg\" }\n".write(
                to: tempBase.appendingPathComponent("fractional_pde.json"),
                atomically: true,
                encoding: .utf8
            )
            return FEADriverExecutionResult(exitCode: 0, stdout: "fractional stdout", stderr: "", elapsedMS: 41)
        }

        let tool = FractionalPDETool(driverRunner: runner, driverResolver: { "/usr/local/bin/mfem-driver" })
        let context = ToolExecutionContext(jobID: "job_999603", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "solver_class": .string("fractional_pde"),
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "alpha": .number(0.5),
                "num_poles": .number(10),
                "source_term": .number(1.0),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("fixed"),
                        "value": .number(0.0)
                    ])
                ])
            ])
        ])

        let result = try tool.run(input: input, context: context)
        guard case .object(let object) = result else {
            return XCTFail("Expected object result from FractionalPDETool.")
        }
        XCTAssertEqual(object["status"], .string("ok"))
        XCTAssertEqual(object["solver"], .string("mfem"))
        XCTAssertEqual(object["exit_code"], .number(0))
        guard case .array(let artifacts)? = object["artifacts"] else {
            return XCTFail("Expected artifacts array.")
        }
        let names = artifacts.compactMap { value -> String? in
            guard case .object(let object) = value,
                  case .string(let name)? = object["name"] else {
                return nil
            }
            return name
        }
        XCTAssertTrue(names.contains("fractional_pde.json"))
    }

    func testFractionalPDEToolRejectsInvalidAlpha() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-fractional-pde-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let tool = FractionalPDETool(
            driverRunner: { _, _, _, _, _, _, _ in
                XCTFail("Driver runner should not be called for invalid input.")
                return FEADriverExecutionResult(exitCode: 0, stdout: "", stderr: "", elapsedMS: 0)
            },
            driverResolver: { "/usr/local/bin/mfem-driver" }
        )
        let context = ToolExecutionContext(jobID: "job_999604", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "alpha": .number(1.0),
                "num_poles": .number(10),
                "source_term": .number(1.0),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("fixed"),
                        "value": .number(0.0)
                    ])
                ])
            ])
        ])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "invalid_input")
        }
    }

    func testAnisotropicDiffusionToolTransformsInputForDriver() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-anisotropic-mock-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let runner: FEADriverRunner = { driverExecutable, inputURL, resultURL, summaryURL, vtkURL, _, _ in
            XCTAssertEqual(URL(fileURLWithPath: driverExecutable).lastPathComponent, "mfem-driver")

            let payloadData = try Data(contentsOf: inputURL)
            let payload = try JSONCoding.makeDecoder().decode(JSONValue.self, from: payloadData)
            guard case .object(let payloadObject) = payload else {
                XCTFail("Expected object payload")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(payloadObject["solver_class"], .string("AnisotropicDiffusion"))

            guard case .object(let config)? = payloadObject["config"] else {
                XCTFail("Expected config object")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(
                config["diffusion_tensor"],
                .array([
                    .number(10.0), .number(0.0), .number(0.0),
                    .number(0.0), .number(2.0), .number(0.0),
                    .number(0.0), .number(0.0), .number(1.0)
                ])
            )
            XCTAssertEqual(config["source_term"], .number(0.0))
            guard case .array(let boundaries)? = config["bcs"] else {
                XCTFail("Expected bcs array")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(boundaries.count, 2)

            let summaryPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("AnisotropicDiffusion"),
                "energy": .number(0.12),
                "iterations": .number(11),
                "error_norm": .number(0.0)
            ])
            let resultPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("AnisotropicDiffusion"),
                "solver_backend": .string("mfem")
            ])
            let encoder = JSONCoding.makeEncoder(prettyPrinted: true)
            try encoder.encode(summaryPayload).write(to: summaryURL, options: .atomic)
            try encoder.encode(resultPayload).write(to: resultURL, options: .atomic)
            try "vtk placeholder\n".write(to: vtkURL, atomically: true, encoding: .utf8)
            try "<VTKFile></VTKFile>\n".write(
                to: tempBase.appendingPathComponent("solution.pvd"),
                atomically: true,
                encoding: .utf8
            )
            try "{ \"solver_backend\": \"pcg_boomeramg\" }\n".write(
                to: tempBase.appendingPathComponent("anisotropic_diffusion.json"),
                atomically: true,
                encoding: .utf8
            )
            return FEADriverExecutionResult(exitCode: 0, stdout: "anisotropic stdout", stderr: "", elapsedMS: 24)
        }

        let tool = AnisotropicDiffusionTool(driverRunner: runner, driverResolver: { "/usr/local/bin/mfem-driver" })
        let context = ToolExecutionContext(jobID: "job_99961", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "solver_class": .string("AnisotropicDiffusion"),
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "diffusion_tensor": .array([
                    .number(10.0), .number(0.0), .number(0.0),
                    .number(0.0), .number(2.0), .number(0.0),
                    .number(0.0), .number(0.0), .number(1.0)
                ]),
                "source_term": .number(0.0),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("fixed"),
                        "value": .number(100.0)
                    ]),
                    .object([
                        "attribute": .number(2),
                        "type": .string("flux"),
                        "value": .number(10.0)
                    ])
                ])
            ])
        ])

        let result = try tool.run(input: input, context: context)
        guard case .object(let object) = result else {
            return XCTFail("Expected object result from AnisotropicDiffusionTool.")
        }
        XCTAssertEqual(object["status"], .string("ok"))
        XCTAssertEqual(object["solver"], .string("mfem"))
        XCTAssertEqual(object["exit_code"], .number(0))
        guard case .array(let artifacts)? = object["artifacts"] else {
            return XCTFail("Expected artifacts array.")
        }
        let names = artifacts.compactMap { value -> String? in
            guard case .object(let object) = value,
                  case .string(let name)? = object["name"] else {
                return nil
            }
            return name
        }
        XCTAssertTrue(names.contains("anisotropic_diffusion.json"))
    }

    func testAnisotropicDiffusionToolRejectsUnsupportedBoundaryType() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-anisotropic-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let tool = AnisotropicDiffusionTool(
            driverRunner: { _, _, _, _, _, _, _ in
                XCTFail("Driver runner should not be called for invalid input.")
                return FEADriverExecutionResult(exitCode: 0, stdout: "", stderr: "", elapsedMS: 0)
            },
            driverResolver: { "/usr/local/bin/mfem-driver" }
        )
        let context = ToolExecutionContext(jobID: "job_99962", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "diffusion_tensor": .array([
                    .number(10.0), .number(0.0), .number(0.0),
                    .number(0.0), .number(2.0), .number(0.0),
                    .number(0.0), .number(0.0), .number(1.0)
                ]),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("robin"),
                        "value": .number(100.0)
                    ])
                ])
            ])
        ])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "invalid_input")
        }
    }

    func testSurfacePDEToolTransformsInputForDriver() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-surface-pde-mock-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let runner: FEADriverRunner = { driverExecutable, inputURL, resultURL, summaryURL, vtkURL, _, _ in
            XCTAssertEqual(URL(fileURLWithPath: driverExecutable).lastPathComponent, "mfem-driver")

            let payloadData = try Data(contentsOf: inputURL)
            let payload = try JSONCoding.makeDecoder().decode(JSONValue.self, from: payloadData)
            guard case .object(let payloadObject) = payload else {
                XCTFail("Expected object payload")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(payloadObject["solver_class"], .string("SurfacePDE"))

            guard case .object(let config)? = payloadObject["config"] else {
                XCTFail("Expected config object")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(config["diffusion_coefficient"], .number(1.0))
            XCTAssertEqual(config["source_term"], .number(1.0))
            XCTAssertEqual(config["is_closed_surface"], .bool(false))
            guard case .array(let boundaries)? = config["bcs"] else {
                XCTFail("Expected bcs array")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(boundaries.count, 1)
            if case .object(let boundary) = boundaries[0] {
                XCTAssertEqual(boundary["type"], .string("fixed"))
            } else {
                XCTFail("Expected boundary object")
            }

            let summaryPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("SurfacePDE"),
                "energy": .number(0.5),
                "iterations": .number(7),
                "error_norm": .number(0.0)
            ])
            let resultPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("SurfacePDE"),
                "solver_backend": .string("mfem")
            ])
            let encoder = JSONCoding.makeEncoder(prettyPrinted: true)
            try encoder.encode(summaryPayload).write(to: summaryURL, options: .atomic)
            try encoder.encode(resultPayload).write(to: resultURL, options: .atomic)
            try "vtk placeholder\n".write(to: vtkURL, atomically: true, encoding: .utf8)
            try "<VTKFile></VTKFile>\n".write(
                to: tempBase.appendingPathComponent("solution.pvd"),
                atomically: true,
                encoding: .utf8
            )
            try "{ \"solver_backend\": \"pcg_boomeramg\" }\n".write(
                to: tempBase.appendingPathComponent("surface_pde.json"),
                atomically: true,
                encoding: .utf8
            )
            return FEADriverExecutionResult(exitCode: 0, stdout: "surface pde stdout", stderr: "", elapsedMS: 21)
        }

        let tool = SurfacePDETool(driverRunner: runner, driverResolver: { "/usr/local/bin/mfem-driver" })
        let context = ToolExecutionContext(jobID: "job_99963", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "solver_class": .string("surface_pde"),
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "diffusion_coefficient": .number(1.0),
                "source_term": .number(1.0),
                "is_closed_surface": .bool(false),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("fixed"),
                        "value": .number(0.0)
                    ])
                ])
            ])
        ])

        let result = try tool.run(input: input, context: context)
        guard case .object(let object) = result else {
            return XCTFail("Expected object result from SurfacePDETool.")
        }
        XCTAssertEqual(object["status"], .string("ok"))
        XCTAssertEqual(object["solver"], .string("mfem"))
        XCTAssertEqual(object["exit_code"], .number(0))
        guard case .array(let artifacts)? = object["artifacts"] else {
            return XCTFail("Expected artifacts array.")
        }
        let names = artifacts.compactMap { value -> String? in
            guard case .object(let object) = value,
                  case .string(let name)? = object["name"] else {
                return nil
            }
            return name
        }
        XCTAssertTrue(names.contains("surface_pde.json"))
    }

    func testSurfacePDEToolRejectsUnsupportedBoundaryType() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-surface-pde-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let tool = SurfacePDETool(
            driverRunner: { _, _, _, _, _, _, _ in
                XCTFail("Driver runner should not be called for invalid input.")
                return FEADriverExecutionResult(exitCode: 0, stdout: "", stderr: "", elapsedMS: 0)
            },
            driverResolver: { "/usr/local/bin/mfem-driver" }
        )
        let context = ToolExecutionContext(jobID: "job_99964", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "diffusion_coefficient": .number(1.0),
                "source_term": .number(1.0),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("flux"),
                        "value": .number(0.0)
                    ])
                ])
            ])
        ])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "invalid_input")
        }
    }

    func testElectromagneticsToolTransformsInputForElectromagneticsDriver() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-electromagnetics-mock-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let runner: FEADriverRunner = { driverExecutable, inputURL, resultURL, summaryURL, vtkURL, _, _ in
            XCTAssertEqual(URL(fileURLWithPath: driverExecutable).lastPathComponent, "mfem-driver")

            let payloadData = try Data(contentsOf: inputURL)
            let payload = try JSONCoding.makeDecoder().decode(JSONValue.self, from: payloadData)
            guard case .object(let payloadObject) = payload else {
                XCTFail("Expected object payload")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(payloadObject["solver_class"], .string("Electromagnetics"))

            guard case .object(let config)? = payloadObject["config"] else {
                XCTFail("Expected config object")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(config["permeability"], .number(1.256e-6))
            XCTAssertEqual(config["kappa"], .number(1.0))
            XCTAssertEqual(
                config["current_density"],
                .array([.number(0.0), .number(1.0), .number(0.0)])
            )
            guard case .array(let boundaries)? = config["bcs"] else {
                XCTFail("Expected bcs array")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(boundaries.count, 1)
            if case .object(let firstBoundary) = boundaries[0] {
                XCTAssertEqual(firstBoundary["type"], .string("perfect_conductor"))
            } else {
                XCTFail("Expected first boundary object")
            }

            let summaryPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("Electromagnetics"),
                "energy": .number(0.2),
                "iterations": .number(9),
                "error_norm": .number(0.0)
            ])
            let resultPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("Electromagnetics"),
                "solver_backend": .string("mfem")
            ])
            let encoder = JSONCoding.makeEncoder(prettyPrinted: true)
            try encoder.encode(summaryPayload).write(to: summaryURL, options: .atomic)
            try encoder.encode(resultPayload).write(to: resultURL, options: .atomic)
            try "vtk placeholder\n".write(to: vtkURL, atomically: true, encoding: .utf8)
            try "<VTKFile></VTKFile>\n".write(
                to: tempBase.appendingPathComponent("solution.pvd"),
                atomically: true,
                encoding: .utf8
            )
            return FEADriverExecutionResult(exitCode: 0, stdout: "electromagnetics stdout", stderr: "", elapsedMS: 21)
        }

        let tool = ElectromagneticsTool(driverRunner: runner, driverResolver: { "/usr/local/bin/mfem-driver" })
        let context = ToolExecutionContext(jobID: "job_9997", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "solver_class": .string("Electromagnetics"),
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "permeability": .number(1.256e-6),
                "kappa": .number(1.0),
                "current_density": .array([.number(0.0), .number(1.0), .number(0.0)]),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("perfect_conductor")
                    ])
                ])
            ])
        ])

        let result = try tool.run(input: input, context: context)
        guard case .object(let object) = result else {
            return XCTFail("Expected object result from ElectromagneticsTool.")
        }
        XCTAssertEqual(object["status"], .string("ok"))
        XCTAssertEqual(object["solver"], .string("mfem"))
        XCTAssertEqual(object["exit_code"], .number(0))
        guard case .array(let artifacts)? = object["artifacts"] else {
            return XCTFail("Expected artifacts array.")
        }
        let names = artifacts.compactMap { value -> String? in
            guard case .object(let object) = value,
                  case .string(let name)? = object["name"] else {
                return nil
            }
            return name
        }
        XCTAssertTrue(names.contains("solution.pvd"))
    }

    func testElectromagneticsToolRejectsUnsupportedBoundaryType() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-electromagnetics-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let tool = ElectromagneticsTool(
            driverRunner: { _, _, _, _, _, _, _ in
                XCTFail("Driver runner should not be called for invalid input.")
                return FEADriverExecutionResult(exitCode: 0, stdout: "", stderr: "", elapsedMS: 0)
            },
            driverResolver: { "/usr/local/bin/mfem-driver" }
        )
        let context = ToolExecutionContext(jobID: "job_9998", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "permeability": .number(1.256e-6),
                "kappa": .number(1.0),
                "current_density": .array([.number(0.0), .number(1.0), .number(0.0)]),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("insulated")
                    ])
                ])
            ])
        ])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "invalid_input")
        }
    }

    func testElectromagneticModalToolTransformsInputForDriver() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-em-modal-mock-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let runner: FEADriverRunner = { driverExecutable, inputURL, resultURL, summaryURL, vtkURL, _, _ in
            XCTAssertEqual(URL(fileURLWithPath: driverExecutable).lastPathComponent, "mfem-driver")

            let payloadData = try Data(contentsOf: inputURL)
            let payload = try JSONCoding.makeDecoder().decode(JSONValue.self, from: payloadData)
            guard case .object(let payloadObject) = payload else {
                XCTFail("Expected object payload")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(payloadObject["solver_class"], .string("ElectromagneticModal"))

            guard case .object(let config)? = payloadObject["config"] else {
                XCTFail("Expected config object")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(config["permittivity"], .number(8.854e-12))
            XCTAssertEqual(config["permeability"], .number(1.256e-6))
            XCTAssertEqual(config["num_modes"], .number(5))
            guard case .array(let boundaries)? = config["bcs"] else {
                XCTFail("Expected bcs array")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(boundaries.count, 1)
            if case .object(let firstBoundary) = boundaries[0] {
                XCTAssertEqual(firstBoundary["type"], .string("perfect_conductor"))
                XCTAssertEqual(firstBoundary["attribute"], .number(1))
            } else {
                XCTFail("Expected first boundary object")
            }

            let summaryPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("ElectromagneticModal"),
                "energy": .number(10.0),
                "iterations": .number(5),
                "error_norm": .number(0.0)
            ])
            let resultPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("ElectromagneticModal"),
                "solver_backend": .string("mfem")
            ])
            let encoder = JSONCoding.makeEncoder(prettyPrinted: true)
            try encoder.encode(summaryPayload).write(to: summaryURL, options: .atomic)
            try encoder.encode(resultPayload).write(to: resultURL, options: .atomic)
            try "vtk placeholder\n".write(to: vtkURL, atomically: true, encoding: .utf8)
            try "{ \"eigenvalues\": [10.0, 22.5] }\n".write(
                to: tempBase.appendingPathComponent("electromagnetic_modes.json"),
                atomically: true,
                encoding: .utf8
            )
            return FEADriverExecutionResult(exitCode: 0, stdout: "em modal stdout", stderr: "", elapsedMS: 20)
        }

        let tool = ElectromagneticModalTool(driverRunner: runner, driverResolver: { "/usr/local/bin/mfem-driver" })
        let context = ToolExecutionContext(jobID: "job_99981", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "solver_class": .string("ElectromagneticModal"),
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "permittivity": .number(8.854e-12),
                "permeability": .number(1.256e-6),
                "num_modes": .number(5),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("perfect_conductor")
                    ])
                ])
            ])
        ])

        let result = try tool.run(input: input, context: context)
        guard case .object(let object) = result else {
            return XCTFail("Expected object result from ElectromagneticModalTool.")
        }
        XCTAssertEqual(object["status"], .string("ok"))
        XCTAssertEqual(object["solver"], .string("mfem"))
        XCTAssertEqual(object["exit_code"], .number(0))
        guard case .array(let artifacts)? = object["artifacts"] else {
            return XCTFail("Expected artifacts array.")
        }
        let names = artifacts.compactMap { value -> String? in
            guard case .object(let object) = value,
                  case .string(let name)? = object["name"] else {
                return nil
            }
            return name
        }
        XCTAssertTrue(names.contains("electromagnetic_modes.json"))
    }

    func testElectromagneticModalToolRejectsUnsupportedBoundaryType() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-em-modal-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let tool = ElectromagneticModalTool(
            driverRunner: { _, _, _, _, _, _, _ in
                XCTFail("Driver runner should not be called for invalid input.")
                return FEADriverExecutionResult(exitCode: 0, stdout: "", stderr: "", elapsedMS: 0)
            },
            driverResolver: { "/usr/local/bin/mfem-driver" }
        )
        let context = ToolExecutionContext(jobID: "job_99982", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "permittivity": .number(8.854e-12),
                "permeability": .number(1.256e-6),
                "num_modes": .number(5),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("insulated")
                    ])
                ])
            ])
        ])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "invalid_input")
        }
    }

    func testElectromagneticScatteringToolTransformsInputForDriver() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-em-scattering-mock-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let runner: FEADriverRunner = { driverExecutable, inputURL, resultURL, summaryURL, vtkURL, _, _ in
            XCTAssertEqual(URL(fileURLWithPath: driverExecutable).lastPathComponent, "mfem-driver")

            let payloadData = try Data(contentsOf: inputURL)
            let payload = try JSONCoding.makeDecoder().decode(JSONValue.self, from: payloadData)
            guard case .object(let payloadObject) = payload else {
                XCTFail("Expected object payload")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(payloadObject["solver_class"], .string("ElectromagneticScattering"))

            guard case .object(let config)? = payloadObject["config"] else {
                XCTFail("Expected config object")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(config["frequency"], .number(2.4e9))
            XCTAssertEqual(config["permittivity"], .number(8.854e-12))
            XCTAssertEqual(config["permeability"], .number(1.256e-6))
            XCTAssertEqual(config["pml_attributes"], .array([.number(99)]))
            guard case .object(let source)? = config["source_current"] else {
                XCTFail("Expected source_current object")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(source["attributes"], .array([.number(2)]))
            XCTAssertEqual(source["J_real"], .array([.number(0.0), .number(1.0), .number(0.0)]))
            XCTAssertEqual(source["J_imag"], .array([.number(0.0), .number(0.0), .number(0.0)]))
            guard case .array(let boundaries)? = config["bcs"] else {
                XCTFail("Expected bcs array")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(boundaries.count, 1)
            if case .object(let boundary) = boundaries[0] {
                XCTAssertEqual(boundary["attribute"], .number(1))
                XCTAssertEqual(boundary["type"], .string("perfect_conductor"))
            } else {
                XCTFail("Expected first boundary object")
            }

            let summaryPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("ElectromagneticScattering"),
                "energy": .number(0.3),
                "iterations": .number(23),
                "error_norm": .number(0.0)
            ])
            let resultPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("ElectromagneticScattering"),
                "solver_backend": .string("mfem")
            ])
            let encoder = JSONCoding.makeEncoder(prettyPrinted: true)
            try encoder.encode(summaryPayload).write(to: summaryURL, options: .atomic)
            try encoder.encode(resultPayload).write(to: resultURL, options: .atomic)
            try "vtk placeholder\n".write(to: vtkURL, atomically: true, encoding: .utf8)
            try "<VTKFile></VTKFile>\n".write(
                to: tempBase.appendingPathComponent("solution.pvd"),
                atomically: true,
                encoding: .utf8
            )
            try "{ \"solver_backend\": \"fgmres_block_ams\" }\n".write(
                to: tempBase.appendingPathComponent("electromagnetic_scattering.json"),
                atomically: true,
                encoding: .utf8
            )
            return FEADriverExecutionResult(exitCode: 0, stdout: "em scattering stdout", stderr: "", elapsedMS: 29)
        }

        let tool = ElectromagneticScatteringTool(
            driverRunner: runner,
            driverResolver: { "/usr/local/bin/mfem-driver" }
        )
        let context = ToolExecutionContext(jobID: "job_99983", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "solver_class": .string("ElectromagneticScattering"),
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "frequency": .number(2.4e9),
                "permittivity": .number(8.854e-12),
                "permeability": .number(1.256e-6),
                "pml_attributes": .array([.number(99)]),
                "source_current": .object([
                    "attributes": .array([.number(2)]),
                    "J_real": .array([.number(0.0), .number(1.0), .number(0.0)]),
                    "J_imag": .array([.number(0.0), .number(0.0), .number(0.0)])
                ]),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("perfect_conductor")
                    ])
                ])
            ])
        ])

        let result = try tool.run(input: input, context: context)
        guard case .object(let object) = result else {
            return XCTFail("Expected object result from ElectromagneticScatteringTool.")
        }
        XCTAssertEqual(object["status"], .string("ok"))
        XCTAssertEqual(object["solver"], .string("mfem"))
        XCTAssertEqual(object["exit_code"], .number(0))
        guard case .array(let artifacts)? = object["artifacts"] else {
            return XCTFail("Expected artifacts array.")
        }
        let names = artifacts.compactMap { value -> String? in
            guard case .object(let object) = value,
                  case .string(let name)? = object["name"] else {
                return nil
            }
            return name
        }
        XCTAssertTrue(names.contains("electromagnetic_scattering.json"))
    }

    func testElectromagneticScatteringToolRejectsUnsupportedBoundaryType() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-em-scattering-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let tool = ElectromagneticScatteringTool(
            driverRunner: { _, _, _, _, _, _, _ in
                XCTFail("Driver runner should not be called for invalid input.")
                return FEADriverExecutionResult(exitCode: 0, stdout: "", stderr: "", elapsedMS: 0)
            },
            driverResolver: { "/usr/local/bin/mfem-driver" }
        )
        let context = ToolExecutionContext(jobID: "job_99984", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "frequency": .number(2.4e9),
                "permittivity": .number(8.854e-12),
                "permeability": .number(1.256e-6),
                "pml_attributes": .array([.number(99)]),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("impedance")
                    ])
                ])
            ])
        ])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "invalid_input")
        }
    }

    func testTransientEMToolTransformsInputForDriver() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-transient-em-mock-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let runner: FEADriverRunner = { driverExecutable, inputURL, resultURL, summaryURL, vtkURL, _, _ in
            XCTAssertEqual(URL(fileURLWithPath: driverExecutable).lastPathComponent, "mfem-driver")

            let payloadData = try Data(contentsOf: inputURL)
            let payload = try JSONCoding.makeDecoder().decode(JSONValue.self, from: payloadData)
            guard case .object(let payloadObject) = payload else {
                XCTFail("Expected object payload")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(payloadObject["solver_class"], .string("TransientMaxwell"))

            guard case .object(let config)? = payloadObject["config"] else {
                XCTFail("Expected config object")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(config["permittivity"], .number(8.854e-12))
            XCTAssertEqual(config["permeability"], .number(1.256e-6))
            XCTAssertEqual(config["conductivity"], .number(0.0))
            XCTAssertEqual(config["dt"], .number(1.0e-11))
            XCTAssertEqual(config["t_final"], .number(1.0e-9))
            guard case .object(let initialCondition)? = config["initial_condition"] else {
                XCTFail("Expected initial_condition object")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(initialCondition["type"], .string("dipole_pulse"))
            XCTAssertEqual(initialCondition["center"], .array([.number(0.0), .number(0.0), .number(0.0)]))
            XCTAssertEqual(initialCondition["polarization"], .array([.number(0.0), .number(0.0), .number(1.0)]))

            let summaryPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("TransientMaxwell"),
                "energy": .number(0.5),
                "iterations": .number(16),
                "error_norm": .number(0.0)
            ])
            let resultPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("TransientMaxwell"),
                "solver_backend": .string("mfem")
            ])
            let encoder = JSONCoding.makeEncoder(prettyPrinted: true)
            try encoder.encode(summaryPayload).write(to: summaryURL, options: .atomic)
            try encoder.encode(resultPayload).write(to: resultURL, options: .atomic)
            try "vtk placeholder\n".write(to: vtkURL, atomically: true, encoding: .utf8)
            try "<VTKFile></VTKFile>\n".write(
                to: tempBase.appendingPathComponent("solution.pvd"),
                atomically: true,
                encoding: .utf8
            )
            return FEADriverExecutionResult(exitCode: 0, stdout: "transient_em stdout", stderr: "", elapsedMS: 24)
        }

        let tool = TransientEMTool(driverRunner: runner, driverResolver: { "/usr/local/bin/mfem-driver" })
        let context = ToolExecutionContext(jobID: "job_99980", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "solver_class": .string("TransientMaxwell"),
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "permittivity": .number(8.854e-12),
                "permeability": .number(1.256e-6),
                "conductivity": .number(0.0),
                "dt": .number(1.0e-11),
                "t_final": .number(1.0e-9),
                "initial_condition": .object([
                    "type": .string("dipole_pulse"),
                    "center": .array([.number(0.0), .number(0.0), .number(0.0)]),
                    "polarization": .array([.number(0.0), .number(0.0), .number(1.0)])
                ]),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("perfect_conductor")
                    ])
                ])
            ])
        ])

        let result = try tool.run(input: input, context: context)
        guard case .object(let object) = result else {
            return XCTFail("Expected object result from TransientEMTool.")
        }
        XCTAssertEqual(object["status"], .string("ok"))
        XCTAssertEqual(object["solver"], .string("mfem"))
        XCTAssertEqual(object["exit_code"], .number(0))
    }

    func testTransientEMToolRejectsUnsupportedBoundaryType() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-transient-em-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let tool = TransientEMTool(
            driverRunner: { _, _, _, _, _, _, _ in
                XCTFail("Driver runner should not be called for invalid input.")
                return FEADriverExecutionResult(exitCode: 0, stdout: "", stderr: "", elapsedMS: 0)
            },
            driverResolver: { "/usr/local/bin/mfem-driver" }
        )
        let context = ToolExecutionContext(jobID: "job_99981", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "permittivity": .number(8.854e-12),
                "permeability": .number(1.256e-6),
                "conductivity": .number(0.0),
                "dt": .number(1.0e-11),
                "t_final": .number(1.0e-9),
                "initial_condition": .object([
                    "type": .string("dipole_pulse"),
                    "center": .array([.number(0.0), .number(0.0), .number(0.0)]),
                    "polarization": .array([.number(0.0), .number(0.0), .number(1.0)])
                ]),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("absorbing")
                    ])
                ])
            ])
        ])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "invalid_input")
        }
    }

    func testMagnetostaticsToolTransformsInputForDriver() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-magnetostatics-mock-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let runner: FEADriverRunner = { driverExecutable, inputURL, resultURL, summaryURL, vtkURL, _, _ in
            XCTAssertEqual(URL(fileURLWithPath: driverExecutable).lastPathComponent, "mfem-driver")

            let payloadData = try Data(contentsOf: inputURL)
            let payload = try JSONCoding.makeDecoder().decode(JSONValue.self, from: payloadData)
            guard case .object(let payloadObject) = payload else {
                XCTFail("Expected object payload")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(payloadObject["solver_class"], .string("Magnetostatics"))

            guard case .object(let config)? = payloadObject["config"] else {
                XCTFail("Expected config object")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(config["permeability"], .number(1.256e-6))
            XCTAssertEqual(config["current_density"], .array([.number(0.0), .number(1000.0), .number(0.0)]))
            guard case .array(let boundaries)? = config["bcs"] else {
                XCTFail("Expected bcs array")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(boundaries.count, 1)
            if case .object(let firstBoundary) = boundaries[0] {
                XCTAssertEqual(firstBoundary["type"], .string("magnetic_insulation"))
            } else {
                XCTFail("Expected first boundary object")
            }

            let summaryPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("Magnetostatics"),
                "energy": .number(0.3),
                "iterations": .number(11),
                "error_norm": .number(0.0)
            ])
            let resultPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("Magnetostatics"),
                "solver_backend": .string("mfem")
            ])
            let encoder = JSONCoding.makeEncoder(prettyPrinted: true)
            try encoder.encode(summaryPayload).write(to: summaryURL, options: .atomic)
            try encoder.encode(resultPayload).write(to: resultURL, options: .atomic)
            try "vtk placeholder\n".write(to: vtkURL, atomically: true, encoding: .utf8)
            try "<VTKFile></VTKFile>\n".write(
                to: tempBase.appendingPathComponent("solution.pvd"),
                atomically: true,
                encoding: .utf8
            )
            return FEADriverExecutionResult(exitCode: 0, stdout: "magnetostatics stdout", stderr: "", elapsedMS: 20)
        }

        let tool = MagnetostaticsTool(driverRunner: runner, driverResolver: { "/usr/local/bin/mfem-driver" })
        let context = ToolExecutionContext(jobID: "job_99982", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "solver_class": .string("Magnetostatics"),
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "permeability": .number(1.256e-6),
                "current_density": .array([.number(0.0), .number(1000.0), .number(0.0)]),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("magnetic_insulation")
                    ])
                ])
            ])
        ])

        let result = try tool.run(input: input, context: context)
        guard case .object(let object) = result else {
            return XCTFail("Expected object result from MagnetostaticsTool.")
        }
        XCTAssertEqual(object["status"], .string("ok"))
        XCTAssertEqual(object["solver"], .string("mfem"))
        XCTAssertEqual(object["exit_code"], .number(0))
    }

    func testMagnetostaticsToolRejectsUnsupportedBoundaryType() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-magnetostatics-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let tool = MagnetostaticsTool(
            driverRunner: { _, _, _, _, _, _, _ in
                XCTFail("Driver runner should not be called for invalid input.")
                return FEADriverExecutionResult(exitCode: 0, stdout: "", stderr: "", elapsedMS: 0)
            },
            driverResolver: { "/usr/local/bin/mfem-driver" }
        )
        let context = ToolExecutionContext(jobID: "job_99983", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "permeability": .number(1.256e-6),
                "current_density": .array([.number(0.0), .number(1000.0), .number(0.0)]),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("perfect_conductor")
                    ])
                ])
            ])
        ])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "invalid_input")
        }
    }

    func testDarcyToolTransformsInputForDarcyFlowDriver() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-darcy-mock-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let runner: FEADriverRunner = { driverExecutable, inputURL, resultURL, summaryURL, vtkURL, _, _ in
            XCTAssertEqual(URL(fileURLWithPath: driverExecutable).lastPathComponent, "mfem-driver")

            let payloadData = try Data(contentsOf: inputURL)
            let payload = try JSONCoding.makeDecoder().decode(JSONValue.self, from: payloadData)
            guard case .object(let payloadObject) = payload else {
                XCTFail("Expected object payload")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(payloadObject["solver_class"], .string("DarcyFlow"))

            guard case .object(let config)? = payloadObject["config"] else {
                XCTFail("Expected config object")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(config["permeability"], .number(1e-12))
            XCTAssertEqual(config["source_term"], .number(0.0))
            guard case .array(let boundaries)? = config["bcs"] else {
                XCTFail("Expected bcs array")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(boundaries.count, 2)
            if case .object(let fixedPressure) = boundaries[0] {
                XCTAssertEqual(fixedPressure["type"], .string("fixed_pressure"))
                XCTAssertEqual(fixedPressure["value"], .number(100_000.0))
            } else {
                XCTFail("Expected fixed pressure boundary object")
            }

            let summaryPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("DarcyFlow"),
                "energy": .number(0.3),
                "iterations": .number(12),
                "error_norm": .number(0.0)
            ])
            let resultPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("DarcyFlow"),
                "solver_backend": .string("mfem")
            ])
            let encoder = JSONCoding.makeEncoder(prettyPrinted: true)
            try encoder.encode(summaryPayload).write(to: summaryURL, options: .atomic)
            try encoder.encode(resultPayload).write(to: resultURL, options: .atomic)
            try "vtk placeholder\n".write(to: vtkURL, atomically: true, encoding: .utf8)
            try "<VTKFile></VTKFile>\n".write(
                to: tempBase.appendingPathComponent("solution.pvd"),
                atomically: true,
                encoding: .utf8
            )
            return FEADriverExecutionResult(exitCode: 0, stdout: "darcy stdout", stderr: "", elapsedMS: 24)
        }

        let tool = DarcyTool(driverRunner: runner, driverResolver: { "/usr/local/bin/mfem-driver" })
        let context = ToolExecutionContext(jobID: "job_9999", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "solver_class": .string("DarcyFlow"),
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "permeability": .number(1e-12),
                "source_term": .number(0.0),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("fixed_pressure"),
                        "value": .number(100_000.0)
                    ]),
                    .object([
                        "attribute": .number(2),
                        "type": .string("no_flow")
                    ])
                ])
            ])
        ])

        let result = try tool.run(input: input, context: context)
        guard case .object(let object) = result else {
            return XCTFail("Expected object result from DarcyTool.")
        }
        XCTAssertEqual(object["status"], .string("ok"))
        XCTAssertEqual(object["solver"], .string("mfem"))
        XCTAssertEqual(object["exit_code"], .number(0))
        guard case .array(let artifacts)? = object["artifacts"] else {
            return XCTFail("Expected artifacts array.")
        }
        let names = artifacts.compactMap { value -> String? in
            guard case .object(let object) = value,
                  case .string(let name)? = object["name"] else {
                return nil
            }
            return name
        }
        XCTAssertTrue(names.contains("solution.pvd"))
    }

    func testDarcyToolRejectsBoundaryWithoutFixedPressure() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-darcy-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let tool = DarcyTool(
            driverRunner: { _, _, _, _, _, _, _ in
                XCTFail("Driver runner should not be called for invalid input.")
                return FEADriverExecutionResult(exitCode: 0, stdout: "", stderr: "", elapsedMS: 0)
            },
            driverResolver: { "/usr/local/bin/mfem-driver" }
        )
        let context = ToolExecutionContext(jobID: "job_10000", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "permeability": .number(1e-12),
                "source_term": .number(0.0),
                "bcs": .array([
                    .object([
                        "attribute": .number(2),
                        "type": .string("no_flow")
                    ])
                ])
            ])
        ])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "invalid_input")
        }
    }

    func testStokesToolTransformsInputForDriver() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-stokes-mock-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let runner: FEADriverRunner = { driverExecutable, inputURL, resultURL, summaryURL, vtkURL, _, _ in
            XCTAssertEqual(URL(fileURLWithPath: driverExecutable).lastPathComponent, "mfem-driver")

            let payloadData = try Data(contentsOf: inputURL)
            let payload = try JSONCoding.makeDecoder().decode(JSONValue.self, from: payloadData)
            guard case .object(let payloadObject) = payload else {
                XCTFail("Expected object payload")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(payloadObject["solver_class"], .string("StokesFlow"))

            guard case .object(let config)? = payloadObject["config"] else {
                XCTFail("Expected config object")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(config["dynamic_viscosity"], .number(0.001))
            XCTAssertEqual(config["body_force"], .array([.number(0.0), .number(-9.81), .number(0.0)]))
            guard case .array(let bcs)? = config["bcs"] else {
                XCTFail("Expected bcs array")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(bcs.count, 2)
            if case .object(let firstBC) = bcs[0] {
                XCTAssertEqual(firstBC["attribute"], .number(1))
                XCTAssertEqual(firstBC["type"], .string("no_slip"))
            } else {
                XCTFail("Expected first stokes boundary object")
            }
            if case .object(let secondBC) = bcs[1] {
                XCTAssertEqual(secondBC["attribute"], .number(2))
                XCTAssertEqual(secondBC["type"], .string("inflow"))
                XCTAssertEqual(secondBC["velocity"], .array([.number(1.0), .number(0.0), .number(0.0)]))
            } else {
                XCTFail("Expected second stokes boundary object")
            }

            let summaryPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("StokesFlow"),
                "energy": .number(0.2),
                "iterations": .number(17),
                "error_norm": .number(0.0)
            ])
            let resultPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("StokesFlow"),
                "solver_backend": .string("mfem")
            ])
            let encoder = JSONCoding.makeEncoder(prettyPrinted: true)
            try encoder.encode(summaryPayload).write(to: summaryURL, options: .atomic)
            try encoder.encode(resultPayload).write(to: resultURL, options: .atomic)
            try "vtk placeholder\n".write(to: vtkURL, atomically: true, encoding: .utf8)
            try "<VTKFile></VTKFile>\n".write(
                to: tempBase.appendingPathComponent("solution.pvd"),
                atomically: true,
                encoding: .utf8
            )
            return FEADriverExecutionResult(exitCode: 0, stdout: "stokes stdout", stderr: "", elapsedMS: 22)
        }

        let tool = StokesTool(driverRunner: runner, driverResolver: { "/usr/local/bin/mfem-driver" })
        let context = ToolExecutionContext(jobID: "job_10001", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "solver_class": .string("StokesFlow"),
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "dynamic_viscosity": .number(0.001),
                "body_force": .array([.number(0.0), .number(-9.81), .number(0.0)]),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("no_slip")
                    ]),
                    .object([
                        "attribute": .number(2),
                        "type": .string("inflow"),
                        "velocity": .array([.number(1.0), .number(0.0), .number(0.0)])
                    ])
                ])
            ])
        ])

        let result = try tool.run(input: input, context: context)
        guard case .object(let object) = result else {
            return XCTFail("Expected object result from StokesTool.")
        }
        XCTAssertEqual(object["status"], .string("ok"))
        XCTAssertEqual(object["solver"], .string("mfem"))
        XCTAssertEqual(object["exit_code"], .number(0))
        guard case .array(let artifacts)? = object["artifacts"] else {
            return XCTFail("Expected artifacts array.")
        }
        let names = artifacts.compactMap { value -> String? in
            guard case .object(let object) = value,
                  case .string(let name)? = object["name"] else {
                return nil
            }
            return name
        }
        XCTAssertTrue(names.contains("solution.pvd"))
    }

    func testStokesToolRejectsInvalidBoundaryType() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-stokes-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let tool = StokesTool(
            driverRunner: { _, _, _, _, _, _, _ in
                XCTFail("Driver runner should not be called for invalid input.")
                return FEADriverExecutionResult(exitCode: 0, stdout: "", stderr: "", elapsedMS: 0)
            },
            driverResolver: { "/usr/local/bin/mfem-driver" }
        )
        let context = ToolExecutionContext(jobID: "job_10002", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "dynamic_viscosity": .number(0.001),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("outlet")
                    ])
                ])
            ])
        ])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "invalid_input")
        }
    }

    func testHyperelasticToolTransformsInputForDriver() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-hyperelastic-mock-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let runner: FEADriverRunner = { driverExecutable, inputURL, resultURL, summaryURL, vtkURL, _, _ in
            XCTAssertEqual(URL(fileURLWithPath: driverExecutable).lastPathComponent, "mfem-driver")

            let payloadData = try Data(contentsOf: inputURL)
            let payload = try JSONCoding.makeDecoder().decode(JSONValue.self, from: payloadData)
            guard case .object(let payloadObject) = payload else {
                XCTFail("Expected object payload")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(payloadObject["solver_class"], .string("Hyperelastic"))

            guard case .object(let config)? = payloadObject["config"] else {
                XCTFail("Expected config object")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(config["shear_modulus"], .number(50_000.0))
            XCTAssertEqual(config["bulk_modulus"], .number(100_000.0))
            XCTAssertEqual(config["body_force"], .array([.number(0.0), .number(-9.81), .number(0.0)]))
            guard case .array(let bcs)? = config["bcs"] else {
                XCTFail("Expected bcs array")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(bcs.count, 2)

            let summaryPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("Hyperelastic"),
                "energy": .number(2.5),
                "iterations": .number(8),
                "error_norm": .number(0.001)
            ])
            let resultPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("Hyperelastic"),
                "solver_backend": .string("mfem")
            ])
            let encoder = JSONCoding.makeEncoder(prettyPrinted: true)
            try encoder.encode(summaryPayload).write(to: summaryURL, options: .atomic)
            try encoder.encode(resultPayload).write(to: resultURL, options: .atomic)
            try "vtk placeholder\n".write(to: vtkURL, atomically: true, encoding: .utf8)
            return FEADriverExecutionResult(exitCode: 0, stdout: "hyperelastic stdout", stderr: "", elapsedMS: 21)
        }

        let tool = HyperelasticityTool(driverRunner: runner, driverResolver: { "/usr/local/bin/mfem-driver" })
        let context = ToolExecutionContext(jobID: "job_9901", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "solver_class": .string("Hyperelastic"),
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "shear_modulus": .number(50_000.0),
                "bulk_modulus": .number(100_000.0),
                "body_force": .array([.number(0.0), .number(-9.81), .number(0.0)]),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("fixed")
                    ]),
                    .object([
                        "attribute": .number(2),
                        "type": .string("traction"),
                        "value": .array([.number(0.0), .number(-1000.0), .number(0.0)])
                    ])
                ])
            ])
        ])

        let result = try tool.run(input: input, context: context)
        guard case .object(let object) = result else {
            return XCTFail("Expected object result from HyperelasticityTool.")
        }
        XCTAssertEqual(object["status"], .string("ok"))
        XCTAssertEqual(object["solver"], .string("mfem"))
        XCTAssertEqual(object["exit_code"], .number(0))
    }

    func testHyperelasticToolRejectsMissingFixedBoundary() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-hyperelastic-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let tool = HyperelasticityTool(
            driverRunner: { _, _, _, _, _, _, _ in
                XCTFail("Driver runner should not be called for invalid input.")
                return FEADriverExecutionResult(exitCode: 0, stdout: "", stderr: "", elapsedMS: 0)
            },
            driverResolver: { "/usr/local/bin/mfem-driver" }
        )
        let context = ToolExecutionContext(jobID: "job_9902", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "shear_modulus": .number(50_000.0),
                "bulk_modulus": .number(100_000.0),
                "bcs": .array([
                    .object([
                        "attribute": .number(2),
                        "type": .string("traction"),
                        "value": .array([.number(0.0), .number(-1000.0), .number(0.0)])
                    ])
                ])
            ])
        ])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "invalid_input")
        }
    }

    func testIncompressibleElasticityToolTransformsInputForDriver() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-incompressible-elasticity-mock-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let runner: FEADriverRunner = { driverExecutable, inputURL, resultURL, summaryURL, vtkURL, _, _ in
            XCTAssertEqual(URL(fileURLWithPath: driverExecutable).lastPathComponent, "mfem-driver")

            let payloadData = try Data(contentsOf: inputURL)
            let payload = try JSONCoding.makeDecoder().decode(JSONValue.self, from: payloadData)
            guard case .object(let payloadObject) = payload else {
                XCTFail("Expected object payload")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(payloadObject["solver_class"], .string("IncompressibleElasticity"))

            guard case .object(let config)? = payloadObject["config"] else {
                XCTFail("Expected config object")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(config["shear_modulus"], .number(50_000.0))
            XCTAssertEqual(config["bulk_modulus"], .number(1.0e9))
            XCTAssertEqual(config["order"], .number(2))
            guard case .array(let bcs)? = config["bcs"] else {
                XCTFail("Expected bcs array")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(bcs.count, 2)

            let summaryPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("IncompressibleElasticity"),
                "energy": .number(1.2),
                "iterations": .number(6),
                "error_norm": .number(0.0)
            ])
            let resultPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("IncompressibleElasticity"),
                "solver_backend": .string("mfem")
            ])
            let encoder = JSONCoding.makeEncoder(prettyPrinted: true)
            try encoder.encode(summaryPayload).write(to: summaryURL, options: .atomic)
            try encoder.encode(resultPayload).write(to: resultURL, options: .atomic)
            try "vtk placeholder\n".write(to: vtkURL, atomically: true, encoding: .utf8)
            return FEADriverExecutionResult(exitCode: 0, stdout: "incompressible elasticity stdout", stderr: "", elapsedMS: 20)
        }

        let tool = IncompressibleElasticityTool(driverRunner: runner, driverResolver: { "/usr/local/bin/mfem-driver" })
        let context = ToolExecutionContext(jobID: "job_99025", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "solver_class": .string("incompressible_elasticity"),
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "shear_modulus": .number(50_000.0),
                "bulk_modulus": .number(1.0e9),
                "order": .number(2),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("fixed")
                    ]),
                    .object([
                        "attribute": .number(2),
                        "type": .string("traction"),
                        "value": .array([.number(0.0), .number(-1000.0), .number(0.0)])
                    ])
                ])
            ])
        ])

        let result = try tool.run(input: input, context: context)
        guard case .object(let object) = result else {
            return XCTFail("Expected object result from IncompressibleElasticityTool.")
        }
        XCTAssertEqual(object["status"], .string("ok"))
        XCTAssertEqual(object["solver"], .string("mfem"))
        XCTAssertEqual(object["exit_code"], .number(0))
    }

    func testIncompressibleElasticityToolRejectsMissingFixedBoundary() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-incompressible-elasticity-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let tool = IncompressibleElasticityTool(
            driverRunner: { _, _, _, _, _, _, _ in
                XCTFail("Driver runner should not be called for invalid input.")
                return FEADriverExecutionResult(exitCode: 0, stdout: "", stderr: "", elapsedMS: 0)
            },
            driverResolver: { "/usr/local/bin/mfem-driver" }
        )
        let context = ToolExecutionContext(jobID: "job_99026", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "shear_modulus": .number(50_000.0),
                "bulk_modulus": .number(1.0e9),
                "bcs": .array([
                    .object([
                        "attribute": .number(2),
                        "type": .string("traction"),
                        "value": .array([.number(0.0), .number(-1000.0), .number(0.0)])
                    ])
                ])
            ])
        ])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "invalid_input")
        }
    }

    func testElastodynamicsToolTransformsInputForDriver() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-elastodynamics-mock-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let runner: FEADriverRunner = { driverExecutable, inputURL, resultURL, summaryURL, vtkURL, _, _ in
            XCTAssertEqual(URL(fileURLWithPath: driverExecutable).lastPathComponent, "mfem-driver")

            let payloadData = try Data(contentsOf: inputURL)
            let payload = try JSONCoding.makeDecoder().decode(JSONValue.self, from: payloadData)
            guard case .object(let payloadObject) = payload else {
                XCTFail("Expected object payload")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }

            XCTAssertEqual(payloadObject["solver_class"], .string("Elastodynamics"))
            guard case .object(let config)? = payloadObject["config"] else {
                XCTFail("Expected config object")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(config["density"], .number(7800.0))
            XCTAssertEqual(config["youngs_modulus"], .number(200_000_000_000.0))
            XCTAssertEqual(config["poisson_ratio"], .number(0.3))
            XCTAssertEqual(config["dt"], .number(0.001))
            XCTAssertEqual(config["t_final"], .number(0.1))
            guard case .object(let initialCondition)? = config["initial_condition"] else {
                XCTFail("Expected initial_condition object")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(initialCondition["displacement"], .array([.number(0.0), .number(0.0), .number(0.0)]))
            XCTAssertEqual(initialCondition["velocity"], .array([.number(0.0), .number(0.0), .number(0.0)]))
            guard case .array(let bcs)? = config["bcs"] else {
                XCTFail("Expected bcs array")
                return FEADriverExecutionResult(exitCode: 1, stdout: "", stderr: "", elapsedMS: 0)
            }
            XCTAssertEqual(bcs.count, 2)

            let summaryPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("Elastodynamics"),
                "energy": .number(2.25),
                "iterations": .number(24),
                "error_norm": .number(0.0)
            ])
            let resultPayload: JSONValue = .object([
                "status": .string("ok"),
                "solver_class": .string("Elastodynamics"),
                "solver_backend": .string("mfem")
            ])
            let encoder = JSONCoding.makeEncoder(prettyPrinted: true)
            try encoder.encode(summaryPayload).write(to: summaryURL, options: .atomic)
            try encoder.encode(resultPayload).write(to: resultURL, options: .atomic)
            try "vtk placeholder\n".write(to: vtkURL, atomically: true, encoding: .utf8)
            return FEADriverExecutionResult(exitCode: 0, stdout: "elastodynamics stdout", stderr: "", elapsedMS: 31)
        }

        let tool = ElastodynamicsTool(driverRunner: runner, driverResolver: { "/usr/local/bin/mfem-driver" })
        let context = ToolExecutionContext(jobID: "job_9903", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "solver_class": .string("Elastodynamics"),
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "density": .number(7800.0),
                "youngs_modulus": .number(200_000_000_000.0),
                "poisson_ratio": .number(0.3),
                "dt": .number(0.001),
                "t_final": .number(0.1),
                "initial_condition": .object([
                    "displacement": .array([.number(0.0), .number(0.0), .number(0.0)]),
                    "velocity": .array([.number(0.0), .number(0.0), .number(0.0)])
                ]),
                "bcs": .array([
                    .object([
                        "attribute": .number(1),
                        "type": .string("fixed")
                    ]),
                    .object([
                        "attribute": .number(2),
                        "type": .string("time_varying_load"),
                        "value": .array([.number(0.0), .number(-1000.0), .number(0.0)]),
                        "frequency": .number(50.0)
                    ])
                ])
            ])
        ])

        let result = try tool.run(input: input, context: context)
        guard case .object(let object) = result else {
            return XCTFail("Expected object result from ElastodynamicsTool.")
        }
        XCTAssertEqual(object["status"], .string("ok"))
        XCTAssertEqual(object["solver"], .string("mfem"))
        XCTAssertEqual(object["exit_code"], .number(0))
    }

    func testElastodynamicsToolRejectsMissingFixedBoundary() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-elastodynamics-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let tool = ElastodynamicsTool(
            driverRunner: { _, _, _, _, _, _, _ in
                XCTFail("Driver runner should not be called for invalid input.")
                return FEADriverExecutionResult(exitCode: 0, stdout: "", stderr: "", elapsedMS: 0)
            },
            driverResolver: { "/usr/local/bin/mfem-driver" }
        )
        let context = ToolExecutionContext(jobID: "job_9904", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "mesh": .object([
                "type": .string("inline_mfem"),
                "data": .string("MFEM mesh v1.0\n...")
            ]),
            "config": .object([
                "density": .number(7800.0),
                "youngs_modulus": .number(200_000_000_000.0),
                "poisson_ratio": .number(0.3),
                "dt": .number(0.001),
                "t_final": .number(0.1),
                "initial_condition": .object([
                    "displacement": .array([.number(0.0), .number(0.0), .number(0.0)]),
                    "velocity": .array([.number(0.0), .number(0.0), .number(0.0)])
                ]),
                "bcs": .array([
                    .object([
                        "attribute": .number(2),
                        "type": .string("time_varying_load"),
                        "value": .array([.number(0.0), .number(-1000.0), .number(0.0)]),
                        "frequency": .number(50.0)
                    ])
                ])
            ])
        ])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "invalid_input")
        }
    }

    func testCadImportTruckToolUsesMockInvokerAndWritesOBJArtifact() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-cad-truck-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }
        try fileManager.createDirectory(at: tempBase, withIntermediateDirectories: true, attributes: nil)

        let inputSTEP = tempBase.appendingPathComponent("input.step")
        try "ISO-10303-21;\nEND-ISO-10303-21;\n".write(to: inputSTEP, atomically: true, encoding: .utf8)

        let tool = CadImportTruckTool(
            invoker: { stepPath, linearDeflection in
                XCTAssertEqual(stepPath, inputSTEP.path)
                XCTAssertEqual(linearDeflection, 0.002)
                return CadTruckMesh(
                    vertices: [
                        0, 0, 0,
                        1, 0, 0,
                        0, 1, 0
                    ],
                    indices: [0, 1, 2],
                    volume: 0.0,
                    surfaceArea: 0.5,
                    bboxMin: [0, 0, 0],
                    bboxMax: [1, 1, 0],
                    watertight: false
                )
            }
        )
        let context = ToolExecutionContext(jobID: "job_5000", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "file_path": .string(inputSTEP.path),
            "linear_deflection": .number(0.002),
            "output_format": .string("obj"),
            "output_file": .string("triangle")
        ])

        let result = try tool.run(input: input, context: context)
        guard case .object(let object) = result else {
            return XCTFail("Expected object result from CadImportTruckTool.")
        }
        XCTAssertEqual(object["status"], .string("ok"))
        XCTAssertEqual(object["solver"], .string("truck"))
        XCTAssertEqual(object["exit_code"], .number(0))

        guard case .object(let output)? = object["output"] else {
            return XCTFail("Expected output payload.")
        }
        XCTAssertEqual(output["format"], .string("obj"))
        XCTAssertEqual(output["triangle_count"], .number(1))
        XCTAssertEqual(output["surface_area"], .number(0.5))
        XCTAssertEqual(output["watertight"], .bool(false))

        guard case .array(let artifacts)? = object["artifacts"],
              artifacts.count == 1,
              case .object(let artifact) = artifacts[0] else {
            return XCTFail("Expected a single artifact.")
        }
        XCTAssertEqual(artifact["name"], .string("triangle.obj"))
        XCTAssertEqual(artifact["mime_type"], .string("text/plain; charset=utf-8"))

        let outputURL = tempBase.appendingPathComponent("triangle.obj")
        XCTAssertTrue(fileManager.fileExists(atPath: outputURL.path))
        let text = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(text.contains("v 0.0 0.0 0.0"))
        XCTAssertTrue(text.contains("f 1 2 3"))
    }

    func testCadImportTruckToolRejectsMissingStepFile() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-cad-truck-missing-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let tool = CadImportTruckTool(
            invoker: { _, _ in
                XCTFail("Invoker should not be called for missing input file.")
                return CadTruckMesh(
                    vertices: [],
                    indices: [],
                    volume: 0,
                    surfaceArea: 0,
                    bboxMin: [0, 0, 0],
                    bboxMax: [0, 0, 0],
                    watertight: false
                )
            }
        )
        let context = ToolExecutionContext(jobID: "job_5001", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "file_path": .string(tempBase.appendingPathComponent("missing.step").path),
            "output_format": .string("obj")
        ])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "invalid_input")
        }
    }

    func testMeshRepairPMPToolUsesMockInvokerAndReturnsArtifacts() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-pmp-repair-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }
        try fileManager.createDirectory(at: tempBase, withIntermediateDirectories: true, attributes: nil)

        let inputMeshURL = tempBase.appendingPathComponent("input.obj")
        try """
        v 0 0 0
        v 1 0 0
        v 0 1 0
        f 1 2 3
        """.write(to: inputMeshURL, atomically: true, encoding: .utf8)

        let tool = MeshRepairPMPTool(
            invoker: { inputPath, repairedPath, decimatedPath, targetFaces, fillHoles, resolveIntersections in
                XCTAssertEqual(inputPath, inputMeshURL.path)
                XCTAssertEqual(targetFaces, 256)
                XCTAssertTrue(fillHoles)
                XCTAssertTrue(resolveIntersections)

                try "repaired mesh".write(
                    to: URL(fileURLWithPath: repairedPath),
                    atomically: true,
                    encoding: .utf8
                )
                try "decimated mesh".write(
                    to: URL(fileURLWithPath: decimatedPath),
                    atomically: true,
                    encoding: .utf8
                )

                return MeshRepairPMPNativeResult(
                    report: MeshRepairPMPDefectReport(
                        initialHoles: 2,
                        initialNonManifoldEdges: 1,
                        initialDegenerateFaces: 3,
                        unresolvedErrors: 0
                    ),
                    errorCode: 0,
                    errorMessage: nil
                )
            }
        )
        let context = ToolExecutionContext(jobID: "job_6001", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "input_path": .string(inputMeshURL.path),
            "target_decimation_faces": .number(256),
            "fill_holes": .bool(true),
            "resolve_intersections": .bool(true)
        ])

        let result: JSONValue = try tool.run(input: input, context: context)
        guard case .object(let object) = result else {
            return XCTFail("Expected object result from MeshRepairPMPTool.")
        }
        XCTAssertEqual(object["status"], .string("ok"))
        XCTAssertEqual(object["solver"], .string("pmp"))
        XCTAssertEqual(object["exit_code"], .number(0))

        guard case .object(let output)? = object["output"] else {
            return XCTFail("Expected output payload.")
        }
        XCTAssertEqual(output["repaired_file"], .string("repaired_mesh.obj"))
        XCTAssertEqual(output["decimated_file"], .string("decimated_mesh.obj"))
        guard case .object(let defectReport)? = output["defect_report"] else {
            return XCTFail("Expected defect_report payload.")
        }
        XCTAssertEqual(defectReport["initial_holes"], .number(2))
        XCTAssertEqual(defectReport["initial_non_manifold_edges"], .number(1))
        XCTAssertEqual(defectReport["initial_degenerate_faces"], .number(3))
        XCTAssertEqual(defectReport["unresolved_errors"], .number(0))

        guard case .array(let artifacts)? = object["artifacts"] else {
            return XCTFail("Expected artifacts.")
        }
        XCTAssertEqual(artifacts.count, 2)
        let names = artifacts.compactMap { value -> String? in
            guard case .object(let artifact) = value,
                  case .string(let name)? = artifact["name"] else {
                return nil
            }
            return name
        }
        XCTAssertTrue(names.contains("repaired_mesh.obj"))
        XCTAssertTrue(names.contains("decimated_mesh.obj"))
    }

    func testMeshRepairPMPToolMapsUnresolvedDefectsToDomainError() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-pmp-unresolved-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }
        try fileManager.createDirectory(at: tempBase, withIntermediateDirectories: true, attributes: nil)

        let inputMeshURL = tempBase.appendingPathComponent("input.obj")
        try "v 0 0 0\n".write(to: inputMeshURL, atomically: true, encoding: .utf8)

        let tool = MeshRepairPMPTool(
            invoker: { _, _, _, _, _, _ in
                MeshRepairPMPNativeResult(
                    report: MeshRepairPMPDefectReport(
                        initialHoles: 0,
                        initialNonManifoldEdges: 3,
                        initialDegenerateFaces: 0,
                        unresolvedErrors: 2
                    ),
                    errorCode: 4,
                    errorMessage: "non-manifold edges remain after repair"
                )
            }
        )
        let context = ToolExecutionContext(jobID: "job_6002", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object(["input_path": .string(inputMeshURL.path)])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "ERR_NON_MANIFOLD_UNRESOLVABLE")
        }
    }

    func testMeshRepairPMPToolMapsHoleFillFailureToDomainError() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-pmp-hole-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }
        try fileManager.createDirectory(at: tempBase, withIntermediateDirectories: true, attributes: nil)

        let inputMeshURL = tempBase.appendingPathComponent("input.obj")
        try "v 0 0 0\n".write(to: inputMeshURL, atomically: true, encoding: .utf8)

        let tool = MeshRepairPMPTool(
            invoker: { _, _, _, _, _, _ in
                MeshRepairPMPNativeResult(
                    report: MeshRepairPMPDefectReport(
                        initialHoles: 1,
                        initialNonManifoldEdges: 0,
                        initialDegenerateFaces: 0,
                        unresolvedErrors: 0
                    ),
                    errorCode: 5,
                    errorMessage: "hole filling failed due to large boundary span"
                )
            }
        )
        let context = ToolExecutionContext(jobID: "job_6003", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "input_path": .string(inputMeshURL.path),
            "fill_holes": .bool(true)
        ])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "ERR_HOLE_TOO_LARGE")
        }
    }

    func testVolumeMeshQuartetToolUsesMockInvokerAndReturnsArtifact() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-quartet-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }
        try fileManager.createDirectory(at: tempBase, withIntermediateDirectories: true, attributes: nil)

        let inputMeshURL = tempBase.appendingPathComponent("input.obj")
        try """
        v 0 0 0
        v 1 0 0
        v 0 1 0
        v 0 0 1
        f 1 2 3
        f 1 4 2
        f 2 4 3
        f 3 4 1
        """.write(to: inputMeshURL, atomically: true, encoding: .utf8)

        let tool = VolumeMeshQuartetTool(
            invoker: { inputPath, outputPath, dx, optimizeQuality, featureAngleThreshold in
                XCTAssertEqual(inputPath, inputMeshURL.path)
                XCTAssertEqual(dx, 0.1)
                XCTAssertTrue(optimizeQuality)
                XCTAssertEqual(featureAngleThreshold, 40.0)
                try "4 vertices\n1 tet\n".write(
                    to: URL(fileURLWithPath: outputPath),
                    atomically: true,
                    encoding: .utf8
                )
                return VolumeMeshQuartetNativeResult(
                    stats: VolumeMeshQuartetStats(
                        nodeCount: 42,
                        tetrahedraCount: 87,
                        worstElementQuality: 0.21
                    ),
                    errorCode: 0,
                    errorMessage: nil
                )
            }
        )
        let context = ToolExecutionContext(jobID: "job_7001", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "input_path": .string(inputMeshURL.path),
            "dx": .number(0.1),
            "optimize_quality": .bool(true),
            "feature_angle_threshold": .number(40.0),
            "output_file": .string("mesh_out")
        ])

        let result = try tool.run(input: input, context: context)
        guard case .object(let object) = result else {
            return XCTFail("Expected object result from VolumeMeshQuartetTool.")
        }
        XCTAssertEqual(object["status"], .string("ok"))
        XCTAssertEqual(object["solver"], .string("quartet"))
        XCTAssertEqual(object["exit_code"], .number(0))

        guard case .object(let output)? = object["output"] else {
            return XCTFail("Expected output payload.")
        }
        XCTAssertEqual(output["output_file"], .string("mesh_out.tet"))
        guard case .object(let stats)? = output["stats"] else {
            return XCTFail("Expected stats payload.")
        }
        XCTAssertEqual(stats["node_count"], .number(42))
        XCTAssertEqual(stats["tetrahedra_count"], .number(87))
        XCTAssertEqual(stats["worst_element_quality"], .number(0.21))

        guard case .array(let artifacts)? = object["artifacts"],
              artifacts.count == 1,
              case .object(let artifact) = artifacts[0] else {
            return XCTFail("Expected one artifact.")
        }
        XCTAssertEqual(artifact["name"], .string("mesh_out.tet"))
        XCTAssertEqual(artifact["mime_type"], .string("application/octet-stream"))

        let outputURL = tempBase.appendingPathComponent("mesh_out.tet")
        XCTAssertTrue(fileManager.fileExists(atPath: outputURL.path))
    }

    func testVolumeMeshQuartetToolMapsNotWatertightError() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-quartet-open-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }
        try fileManager.createDirectory(at: tempBase, withIntermediateDirectories: true, attributes: nil)

        let inputMeshURL = tempBase.appendingPathComponent("open.obj")
        try "v 0 0 0\n".write(to: inputMeshURL, atomically: true, encoding: .utf8)

        let tool = VolumeMeshQuartetTool(
            invoker: { _, _, _, _, _ in
                VolumeMeshQuartetNativeResult(
                    stats: VolumeMeshQuartetStats(nodeCount: 0, tetrahedraCount: 0, worstElementQuality: 0),
                    errorCode: 3,
                    errorMessage: "surface mesh is not watertight"
                )
            }
        )
        let context = ToolExecutionContext(jobID: "job_7002", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object(["input_path": .string(inputMeshURL.path)])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "ERR_NOT_WATERTIGHT")
        }
    }

    func testVolumeMeshQuartetToolMapsInvalidDxError() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-quartet-dx-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }
        try fileManager.createDirectory(at: tempBase, withIntermediateDirectories: true, attributes: nil)

        let inputMeshURL = tempBase.appendingPathComponent("solid.obj")
        try "v 0 0 0\n".write(to: inputMeshURL, atomically: true, encoding: .utf8)

        let tool = VolumeMeshQuartetTool(
            invoker: { _, _, _, _, _ in
                VolumeMeshQuartetNativeResult(
                    stats: VolumeMeshQuartetStats(nodeCount: 0, tetrahedraCount: 0, worstElementQuality: 0),
                    errorCode: 4,
                    errorMessage: "dx is too small for the mesh bounding box"
                )
            }
        )
        let context = ToolExecutionContext(jobID: "job_7003", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object(["input_path": .string(inputMeshURL.path)])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "ERR_INVALID_DX")
        }
    }

    func testRenderPackVTKToolUsesMockInvokerAndReturnsArtifacts() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-vtk-render-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }
        try fileManager.createDirectory(at: tempBase, withIntermediateDirectories: true, attributes: nil)

        let inputMeshURL = tempBase.appendingPathComponent("part.obj")
        try """
        v 0 0 0
        v 1 0 0
        v 0 1 0
        f 1 2 3
        """.write(to: inputMeshURL, atomically: true, encoding: .utf8)

        let tool = RenderPackVTKTool(
            invoker: { inputPath, outputDirectory, width, height, views, outputColor, outputDepth, outputNormal in
                XCTAssertEqual(inputPath, inputMeshURL.path)
                XCTAssertEqual(width, 640)
                XCTAssertEqual(height, 480)
                XCTAssertEqual(views, ["isometric", "front"])
                XCTAssertTrue(outputColor)
                XCTAssertTrue(outputDepth)
                XCTAssertTrue(outputNormal)

                let outputURL = URL(fileURLWithPath: outputDirectory, isDirectory: true)
                let isoColor = outputURL.appendingPathComponent("iso_color.png")
                let isoDepth = outputURL.appendingPathComponent("iso_depth.tiff")
                let isoNormal = outputURL.appendingPathComponent("iso_normal.png")
                let frontColor = outputURL.appendingPathComponent("front_color.png")
                let frontDepth = outputURL.appendingPathComponent("front_depth.tiff")
                let frontNormal = outputURL.appendingPathComponent("front_normal.png")

                try Data([0x89, 0x50, 0x4E, 0x47]).write(to: isoColor, options: .atomic)
                try Data([0x49, 0x49, 0x2A, 0x00]).write(to: isoDepth, options: .atomic)
                try Data([0x89, 0x50, 0x4E, 0x47]).write(to: isoNormal, options: .atomic)
                try Data([0x89, 0x50, 0x4E, 0x47]).write(to: frontColor, options: .atomic)
                try Data([0x49, 0x49, 0x2A, 0x00]).write(to: frontDepth, options: .atomic)
                try Data([0x89, 0x50, 0x4E, 0x47]).write(to: frontNormal, options: .atomic)

                return RenderPackVTKNativeResult(
                    views: [
                        RenderPackVTKNativeViewResult(
                            colorPath: isoColor.path,
                            depthPath: isoDepth.path,
                            normalPath: isoNormal.path
                        ),
                        RenderPackVTKNativeViewResult(
                            colorPath: frontColor.path,
                            depthPath: frontDepth.path,
                            normalPath: frontNormal.path
                        )
                    ],
                    cameraIntrinsics: [
                        [600.0, 0.0, 319.5],
                        [0.0, 600.0, 239.5],
                        [0.0, 0.0, 1.0]
                    ],
                    errorCode: 0,
                    errorMessage: nil
                )
            }
        )

        let context = ToolExecutionContext(jobID: "job_8001", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "input_path": .string(inputMeshURL.path),
            "width": .number(640),
            "height": .number(480),
            "views": .array([.string("isometric"), .string("front")]),
            "output_color": .bool(true),
            "output_depth": .bool(true),
            "output_normal": .bool(true)
        ])

        let result = try tool.run(input: input, context: context)
        guard case .object(let object) = result else {
            return XCTFail("Expected object result from RenderPackVTKTool.")
        }
        XCTAssertEqual(object["status"], .string("ok"))
        XCTAssertEqual(object["solver"], .string("vtk"))
        XCTAssertEqual(object["exit_code"], .number(0))

        guard case .object(let output)? = object["output"] else {
            return XCTFail("Expected output payload.")
        }
        guard case .array(let views)? = output["views"] else {
            return XCTFail("Expected views array.")
        }
        XCTAssertEqual(views.count, 2)

        guard case .array(let intrinsics)? = output["camera_intrinsics"] else {
            return XCTFail("Expected camera_intrinsics.")
        }
        XCTAssertEqual(intrinsics.count, 3)

        guard case .array(let artifacts)? = object["artifacts"] else {
            return XCTFail("Expected artifacts list.")
        }
        XCTAssertEqual(artifacts.count, 6)
    }

    func testRenderPackVTKToolMapsHeadlessContextFailure() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-vtk-headless-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }
        try fileManager.createDirectory(at: tempBase, withIntermediateDirectories: true, attributes: nil)

        let inputMeshURL = tempBase.appendingPathComponent("part.obj")
        try "v 0 0 0\n".write(to: inputMeshURL, atomically: true, encoding: .utf8)

        let tool = RenderPackVTKTool(
            invoker: { _, _, _, _, _, _, _, _ in
                RenderPackVTKNativeResult(
                    views: [],
                    cameraIntrinsics: [[0, 0, 0], [0, 0, 0], [0, 0, 0]],
                    errorCode: 2,
                    errorMessage: "failed to initialize offscreen render window"
                )
            }
        )
        let context = ToolExecutionContext(jobID: "job_8002", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object(["input_path": .string(inputMeshURL.path)])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "ERR_HEADLESS_CONTEXT_FAILED")
        }
    }

    func testRenderPackVTKToolMapsBufferExtractionFailure() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-vtk-buffer-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }
        try fileManager.createDirectory(at: tempBase, withIntermediateDirectories: true, attributes: nil)

        let inputMeshURL = tempBase.appendingPathComponent("part.obj")
        try "v 0 0 0\n".write(to: inputMeshURL, atomically: true, encoding: .utf8)

        let tool = RenderPackVTKTool(
            invoker: { _, _, _, _, _, _, _, _ in
                RenderPackVTKNativeResult(
                    views: [],
                    cameraIntrinsics: [[0, 0, 0], [0, 0, 0], [0, 0, 0]],
                    errorCode: 5,
                    errorMessage: "failed to read depth buffer"
                )
            }
        )
        let context = ToolExecutionContext(jobID: "job_8003", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object(["input_path": .string(inputMeshURL.path)])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "ERR_BUFFER_EXTRACTION_FAILED")
        }
    }

    func testDslFitOpen3DToolUsesMockInvokerAndReturnsPrimitivePayload() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-open3d-fit-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }
        try fileManager.createDirectory(at: tempBase, withIntermediateDirectories: true, attributes: nil)

        let inputMeshURL = tempBase.appendingPathComponent("shape.obj")
        try """
        v 0 0 0
        v 1 0 0
        v 0 1 0
        f 1 2 3
        """.write(to: inputMeshURL, atomically: true, encoding: .utf8)

        let tool = DslFitOpen3DTool(
            invoker: { inputPath, distanceThreshold, ransacN, numIterations in
                XCTAssertEqual(inputPath, inputMeshURL.path)
                XCTAssertEqual(distanceThreshold, 0.02)
                XCTAssertEqual(ransacN, 3)
                XCTAssertEqual(numIterations, 750)
                return DslFitOpen3DNativeResult(
                    primitives: [
                        DslFitOpen3DPrimitive(
                            type: "plane",
                            parameters: [0, 0, 1, -0.25, 0, 0, 0, 0, 0, 0],
                            inlierRatio: 0.62
                        ),
                        DslFitOpen3DPrimitive(
                            type: "sphere",
                            parameters: [0.5, 0.5, 0.5, 0.3, 0, 0, 0, 0, 0, 0],
                            inlierRatio: 0.18
                        ),
                        DslFitOpen3DPrimitive(
                            type: "cylinder",
                            parameters: [0, 0, 0, 0, 0, 1, 0.15, 0, 0, 0],
                            inlierRatio: 0.12
                        )
                    ],
                    unassignedPointsRatio: 0.08,
                    errorCode: 0,
                    errorMessage: nil
                )
            }
        )

        let context = ToolExecutionContext(jobID: "job_9001", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "input_path": .string(inputMeshURL.path),
            "distance_threshold": .number(0.02),
            "ransac_n": .number(3),
            "num_iterations": .number(750)
        ])

        let result = try tool.run(input: input, context: context)
        guard case .object(let object) = result else {
            return XCTFail("Expected object result from DslFitOpen3DTool.")
        }
        XCTAssertEqual(object["status"], .string("ok"))
        XCTAssertEqual(object["solver"], .string("open3d"))
        XCTAssertEqual(object["exit_code"], .number(0))

        guard case .object(let output)? = object["output"] else {
            return XCTFail("Expected output payload.")
        }
        XCTAssertEqual(output["unassigned_points_ratio"], .number(0.08))
        guard case .array(let primitives)? = output["primitives"] else {
            return XCTFail("Expected primitives array.")
        }
        XCTAssertEqual(primitives.count, 3)

        guard case .object(let firstPrimitive) = primitives[0] else {
            return XCTFail("Expected first primitive object.")
        }
        XCTAssertEqual(firstPrimitive["type"], .string("plane"))
        XCTAssertEqual(firstPrimitive["inlier_ratio"], .number(0.62))
        guard case .array(let planeCoefficients)? = firstPrimitive["coefficients"] else {
            return XCTFail("Expected plane coefficients.")
        }
        XCTAssertEqual(planeCoefficients.count, 4)
    }

    func testDslFitOpen3DToolMapsPointCloudGenerationFailure() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-open3d-pcd-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }
        try fileManager.createDirectory(at: tempBase, withIntermediateDirectories: true, attributes: nil)

        let inputMeshURL = tempBase.appendingPathComponent("shape.obj")
        try "v 0 0 0\n".write(to: inputMeshURL, atomically: true, encoding: .utf8)

        let tool = DslFitOpen3DTool(
            invoker: { _, _, _, _ in
                DslFitOpen3DNativeResult(
                    primitives: [],
                    unassignedPointsRatio: 1.0,
                    errorCode: 3,
                    errorMessage: "sampling produced zero points"
                )
            }
        )
        let context = ToolExecutionContext(jobID: "job_9002", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object(["input_path": .string(inputMeshURL.path)])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "ERR_POINTCLOUD_GENERATION_FAILED")
        }
    }

    func testDslFitOpen3DToolMapsPrimitiveFitTimeout() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-open3d-timeout-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }
        try fileManager.createDirectory(at: tempBase, withIntermediateDirectories: true, attributes: nil)

        let inputMeshURL = tempBase.appendingPathComponent("shape.obj")
        try "v 0 0 0\n".write(to: inputMeshURL, atomically: true, encoding: .utf8)

        let tool = DslFitOpen3DTool(
            invoker: { _, _, _, _ in
                DslFitOpen3DNativeResult(
                    primitives: [],
                    unassignedPointsRatio: 1.0,
                    errorCode: 4,
                    errorMessage: "no primitives found after iterations"
                )
            }
        )
        let context = ToolExecutionContext(jobID: "job_9003", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object(["input_path": .string(inputMeshURL.path)])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "ERR_PRIMITIVE_FIT_TIMEOUT")
        }
    }

    func testCircuitsToolUsesMockedRunnerAndReturnsNormalizedFields() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-circuits-mock-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let runner: CircuitsCommandRunner = { _, _, cwd, _, _, _ in
            try "mock log\n".write(to: cwd.appendingPathComponent("ngspice.log"), atomically: true, encoding: .utf8)
            try Data([0x00, 0x01, 0x02]).write(to: cwd.appendingPathComponent("ngspice.raw"), options: .atomic)
            return CircuitsCommandResult(exitCode: 0, stdout: "stdout text", stderr: "stderr text", elapsedMS: 7)
        }
        let tool = CircuitsSimulateTool(commandRunner: runner, ngspiceInstalled: { true })
        let context = ToolExecutionContext(jobID: "job_1111", jobDirectoryURL: tempBase, limits: .default)

        let input: JSONValue = .object([
            "netlist": .string("V1 in 0 DC 1\nR1 in 0 1k\n.end"),
            "control": .array([.string("op"), .string("quit")])
        ])
        let result = try tool.run(input: input, context: context)
        guard case .object(let object) = result else {
            return XCTFail("Expected object result")
        }
        XCTAssertEqual(object["status"], .string("ok"))
        XCTAssertEqual(object["solver"], .string("ngspice"))
        XCTAssertEqual(object["exit_code"], .number(0))
        XCTAssertEqual(object["stdout"], .string("stdout text"))
        XCTAssertEqual(object["stderr"], .string("stderr text"))
        guard case .array(let artifacts)? = object["artifacts"] else {
            return XCTFail("Expected artifacts")
        }
        XCTAssertTrue(artifacts.count >= 3)
        let artifactNames: [String] = artifacts.compactMap { item in
            guard case .object(let obj) = item,
                  case .string(let name)? = obj["name"] else {
                return nil
            }
            return name
        }
        XCTAssertTrue(artifactNames.contains("circuit.cir"))
        XCTAssertTrue(artifactNames.contains("ngspice.log"))
        XCTAssertTrue(artifactNames.contains("ngspice.raw"))
    }

    func testCircuitsToolReturnsMissingDependencyWhenNgspiceUnavailable() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-circuits-missing-dep-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let runner: CircuitsCommandRunner = { _, _, _, _, _, _ in
            XCTFail("Runner should not execute when ngspiceInstalled returns false.")
            return CircuitsCommandResult(exitCode: 0, stdout: "", stderr: "", elapsedMS: 0)
        }

        let tool = CircuitsSimulateTool(commandRunner: runner, ngspiceInstalled: { false })
        let context = ToolExecutionContext(jobID: "job_dep", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "netlist": .string("V1 in 0 DC 1\nR1 in 0 1k\n.end")
        ])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "missing_dependency")
        }
    }

    func testCircuitSimulateNgspiceToolUsesMockInvokerAndWritesArtifact() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-ngspice-ffi-mock-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }
        try fileManager.createDirectory(at: tempBase, withIntermediateDirectories: true, attributes: nil)

        let netlistURL = tempBase.appendingPathComponent("tiny.cir")
        try """
        V1 in 0 DC 1
        R1 in out 1000
        C1 out 0 1e-6
        .end
        """.write(to: netlistURL, atomically: true, encoding: .utf8)

        let tool = CircuitSimulateNgspiceTool(
            invoker: { path, vectors in
                XCTAssertEqual(path, netlistURL.path)
                XCTAssertEqual(vectors, ["time", "v(out)"])
                return NgspiceNativeResult(
                    vectors: [
                        NgspiceNativeVector(name: "time", data: [0.0, 0.001, 0.002]),
                        NgspiceNativeVector(name: "v(out)", data: [0.0, 0.3, 0.6])
                    ],
                    errorCode: 0,
                    errorMessage: nil,
                    stdoutLog: "stdout line",
                    stderrLog: ""
                )
            }
        )

        let context = ToolExecutionContext(jobID: "job_3333", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "netlist_path": .string(netlistURL.path),
            "target_vectors": .array([.string("time"), .string("v(out)")])
        ])

        let result = try tool.run(input: input, context: context)
        guard case .object(let object) = result else {
            return XCTFail("Expected object result.")
        }

        XCTAssertEqual(object["status"], .string("ok"))
        XCTAssertEqual(object["solver"], .string("ngspice_shared"))
        XCTAssertEqual(object["exit_code"], .number(0))
        XCTAssertEqual(object["stdout"], .string("stdout line"))

        guard case .object(let vectors)? = object["vectors"] else {
            return XCTFail("Expected vectors object.")
        }
        XCTAssertEqual(vectors["time"], .numberArray([0.0, 0.001, 0.002]))
        XCTAssertEqual(vectors["v(out)"], .numberArray([0.0, 0.3, 0.6]))

        guard case .array(let artifacts)? = object["artifacts"] else {
            return XCTFail("Expected artifacts array.")
        }
        XCTAssertEqual(artifacts.count, 1)
        guard case .object(let artifact) = artifacts[0] else {
            return XCTFail("Expected artifact object.")
        }
        XCTAssertEqual(artifact["name"], .string("vectors.json"))
    }

    func testCircuitSimulateNgspiceToolRejectsMissingNetlistPath() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-ngspice-ffi-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let tool = CircuitSimulateNgspiceTool(
            invoker: { _, _ in
                XCTFail("Invoker should not run when input file is missing.")
                return NgspiceNativeResult(vectors: [], errorCode: 0, errorMessage: nil, stdoutLog: "", stderrLog: "")
            }
        )

        let context = ToolExecutionContext(jobID: "job_3334", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "netlist_path": .string("/tmp/does-not-exist-anywhere.cir"),
            "target_vectors": .array([.string("time")])
        ])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "invalid_input")
        }
    }

    func testCircuitsToolReturnsErrorOnNonZeroExitWithMockRunner() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-circuits-error-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }

        let runner: CircuitsCommandRunner = { _, _, cwd, _, _, _ in
            try "error line\n".write(to: cwd.appendingPathComponent("ngspice.log"), atomically: true, encoding: .utf8)
            return CircuitsCommandResult(exitCode: 2, stdout: "stdout bad", stderr: "stderr bad", elapsedMS: 5)
        }
        let tool = CircuitsSimulateTool(commandRunner: runner, ngspiceInstalled: { true })
        let context = ToolExecutionContext(jobID: "job_2222", jobDirectoryURL: tempBase, limits: .default)
        let input: JSONValue = .object([
            "netlist": .string("V1 in 0 DC 1\nR1 in 0 1k\n.end")
        ])

        XCTAssertThrowsError(try tool.run(input: input, context: context)) { error in
            guard let autosageError = error as? AutoSageError else {
                return XCTFail("Expected AutoSageError")
            }
            XCTAssertEqual(autosageError.code, "solver_failed")
        }
    }

    func testCircuitsSimulationRunnerWithNgspiceIfAvailable() throws {
        guard CircuitsSimulationRunner.isNgspiceInstalled() else {
            throw XCTSkip("ngspice not installed; skipping integration test.")
        }

        let fileManager = FileManager.default
        let jobDirectory = fileManager.temporaryDirectory.appendingPathComponent("autosage-ngspice-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: jobDirectory) }

        let input: JSONValue = .object([
            "netlist": .string("V1 in 0 PULSE(0 1 0 1n 1n 1m 2m)\nR1 in out 1000\nC1 out 0 1e-6"),
            "analysis": .string("tran"),
            "probes": .array([.string("v(out)")]),
            "options": .object([
                "tran": .object([
                    "tstop": .number(0.01),
                    "step": .number(0.0001)
                ])
            ])
        ])

        let result = try CircuitsSimulationRunner.run(input: input, jobDirectoryURL: jobDirectory)
        let resultData = try JSONCoding.makeEncoder().encode(result)
        let decoded = try JSONCoding.makeDecoder().decode(CircuitsSimulateOutput.self, from: resultData)

        XCTAssertEqual(decoded.status, "ok")
        XCTAssertFalse(decoded.series.isEmpty)
        XCTAssertFalse(decoded.series[0].x.isEmpty)
        XCTAssertFalse(decoded.series[0].y.isEmpty)
    }

    func testParametricCSGNodeDecodesDifferenceExampleAST() throws {
        let payload = """
        {
          "type": "difference",
          "target": {
            "type": "imported_mesh",
            "path": "geometry/repaired.obj"
          },
          "tool": {
            "type": "translate",
            "vector": [10.0, 0.0, 5.0],
            "child": {
              "type": "cylinder",
              "radius": 2.5,
              "height": 20.0,
              "center": [0.0, 0.0, 0.0],
              "axis": [0.0, 0.0, 1.0]
            }
          }
        }
        """
        let data = try XCTUnwrap(payload.data(using: .utf8))
        let node = try JSONCoding.makeDecoder().decode(ParametricCSGNode.self, from: data)

        guard case .difference(let target, let tool) = node else {
            return XCTFail("Expected difference root node.")
        }
        guard case .importedMesh(let path) = target else {
            return XCTFail("Expected imported_mesh target.")
        }
        XCTAssertEqual(path, "geometry/repaired.obj")

        guard case .translate(let vector, let child) = tool else {
            return XCTFail("Expected translate tool node.")
        }
        XCTAssertEqual(vector, ParametricVector3(10.0, 0.0, 5.0))

        guard case .cylinder(let radius, let height, let center, let axis) = child else {
            return XCTFail("Expected cylinder child node.")
        }
        XCTAssertEqual(radius, 2.5)
        XCTAssertEqual(height, 20.0)
        XCTAssertEqual(center, ParametricVector3(0.0, 0.0, 0.0))
        XCTAssertEqual(axis, ParametricVector3(0.0, 0.0, 1.0))
    }

    func testParametricCSGNodeRoundTripsViaJSONValue() throws {
        let original: ParametricCSGNode = .difference(
            target: .importedMesh(path: "geometry/repaired.obj"),
            tool: .translate(
                vector: ParametricVector3(1.0, 2.0, 3.0),
                child: .sphere(radius: 0.75, center: ParametricVector3(0.0, 0.0, 0.0))
            )
        )

        let encoded = try original.encodeToJSONValue()
        let decoded = try ParametricCSGNode.decode(from: encoded)
        XCTAssertEqual(decoded, original)
    }

    func testParametricCSGNodeRejectsUnknownType() throws {
        let payload: JSONValue = .object([
            "type": .string("capsule"),
            "radius": .number(1.0)
        ])

        XCTAssertThrowsError(try ParametricCSGNode.decode(from: payload)) { error in
            guard error is DecodingError else {
                return XCTFail("Expected DecodingError.")
            }
        }
    }

    func testParametricCSGSchemaContainsRecursiveNodeDefinitions() {
        guard case .object(let schema) = ParametricCSGNode.jsonSchema else {
            return XCTFail("Expected top-level object schema.")
        }
        guard case .object(let defs)? = schema["$defs"] else {
            return XCTFail("Expected $defs object.")
        }
        guard case .object(let nodeDef)? = defs["node"] else {
            return XCTFail("Expected node definition.")
        }
        guard case .array(let oneOf)? = nodeDef["oneOf"] else {
            return XCTFail("Expected oneOf array in node definition.")
        }
        XCTAssertEqual(oneOf.count, 9)

        guard case .object(let unionDef)? = defs["union"] else {
            return XCTFail("Expected union definition.")
        }
        guard case .object(let properties)? = unionDef["properties"] else {
            return XCTFail("Expected union.properties object.")
        }
        guard case .object(let children)? = properties["children"] else {
            return XCTFail("Expected union children schema.")
        }
        XCTAssertEqual(children["minItems"], .number(2))
    }

    func testSmoketestRuns() throws {
        guard NgSpiceRunner.isNgspiceInstalled() else {
            throw XCTSkip("ngspice not installed; skipping smoketest.")
        }

        let result = try NgSpiceRunner.runSmokeTest(timeoutS: 30)
        XCTAssertEqual(result.exitCode, 0)
        let parsed = result.parsed
        XCTAssertNotNil(parsed?.vectors["time"])
        XCTAssertTrue(parsed?.vectors.keys.contains(where: { $0.lowercased() == "v(out)" }) == true)
    }
}
