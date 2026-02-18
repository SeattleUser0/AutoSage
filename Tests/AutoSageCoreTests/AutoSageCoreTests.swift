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
        let body = Data("{}".utf8)

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
        let body = Data(#"{"tool_choice":"fea.solve"}"#.utf8)

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

    func testParsePort() {
        XCTAssertNil(parsePort(nil))
        XCTAssertNil(parsePort(""))
        XCTAssertNil(parsePort("not-a-number"))
        XCTAssertNil(parsePort("0"))
        XCTAssertNil(parsePort("70000"))
        XCTAssertEqual(parsePort("8081"), 8081)
        XCTAssertEqual(parsePort(" 9090 "), 9090)
    }
}
