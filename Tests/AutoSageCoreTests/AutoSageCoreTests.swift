import XCTest
@testable import AutoSageCore

final class AutoSageCoreTests: XCTestCase {
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
