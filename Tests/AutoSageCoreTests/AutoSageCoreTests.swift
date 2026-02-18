import Foundation
import XCTest
@testable import AutoSageCore

final class AutoSageCoreTests: XCTestCase {
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
        let router = Router()
        let body = Data(#"{"model":"autosage-0.1","tool_choice":"fea.solve"}"#.utf8)

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

    func testParsePort() {
        XCTAssertNil(parsePort(nil))
        XCTAssertNil(parsePort(""))
        XCTAssertNil(parsePort("not-a-number"))
        XCTAssertNil(parsePort("0"))
        XCTAssertNil(parsePort("70000"))
        XCTAssertEqual(parsePort("8081"), 8081)
        XCTAssertEqual(parsePort(" 9090 "), 9090)
    }

    func testJobStoreLifecycleTransitions() async {
        let store = JobStore()
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
        let store = JobStore(runDirectory: runDirectory)

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
        let store = JobStore(runDirectory: runDirectory)

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
        let store = JobStore(runDirectory: runDirectory)

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

    func testJobsEndpointsCreateAndFetch() throws {
        let fileManager = FileManager.default
        let tempBase = fileManager.temporaryDirectory.appendingPathComponent("autosage-endpoint-runs-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempBase) }
        let router = Router(jobStore: JobStore(runDirectory: RunDirectory(baseURL: tempBase, fileManager: fileManager)))
        let createBody = Data(#"{"tool_name":"fea.solve","input":{"mesh":"beam.msh"}}"#.utf8)
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
}
