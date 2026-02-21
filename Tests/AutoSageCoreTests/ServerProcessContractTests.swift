import Foundation
import XCTest
@testable import AutoSageCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
#error("Unsupported C standard library")
#endif

private let streamSocketType: Int32 = {
    #if canImport(Darwin)
    return SOCK_STREAM
    #else
    return Int32(SOCK_STREAM.rawValue)
    #endif
}()

private func pickFreeLocalPort() throws -> Int {
    let fd = socket(AF_INET, streamSocketType, 0)
    guard fd >= 0 else {
        throw AutoSageError(code: "test_setup_failed", message: "Failed to allocate socket for port discovery.")
    }
    defer { close(fd) }

    var value: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &value, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(0)
    let inetResult = "127.0.0.1".withCString { cString in
        inet_pton(AF_INET, cString, &addr.sin_addr)
    }
    guard inetResult == 1 else {
        throw AutoSageError(code: "test_setup_failed", message: "Failed to encode localhost address.")
    }

    let bindResult = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
            bind(fd, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else {
        throw AutoSageError(code: "test_setup_failed", message: "Failed to bind ephemeral localhost port.")
    }

    var bound = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let getResult = withUnsafeMutablePointer(to: &bound) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
            getsockname(fd, ptr, &length)
        }
    }
    guard getResult == 0 else {
        throw AutoSageError(code: "test_setup_failed", message: "Failed to read bound socket name.")
    }

    return Int(UInt16(bigEndian: bound.sin_port))
}

final class ServerProcessContractTests: XCTestCase {
    private var serverProcess: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    override func tearDownWithError() throws {
        if let process = serverProcess, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        serverProcess = nil
        stdoutPipe = nil
        stderrPipe = nil
        try super.tearDownWithError()
    }

    func testServerContractHealthToolsAndExecute() throws {
        let port = try pickFreeLocalPort()
        try startServer(port: port)
        try waitForServerReady(port: port, timeout: 6.0)

        let health = try sendRequest(port: port, method: "GET", path: "/healthz")
        XCTAssertEqual(health.response.statusCode, 200)
        XCTAssertNotNil(health.response.value(forHTTPHeaderField: "X-Request-Id"))
        let healthPayload = try JSONCoding.makeDecoder().decode(HealthResponse.self, from: health.data)
        XCTAssertEqual(healthPayload.status, "ok")
        XCTAssertEqual(healthPayload.name, "AutoSage")
        XCTAssertFalse(healthPayload.version.isEmpty)

        let openapi = try sendRequest(port: port, method: "GET", path: "/openapi.yaml")
        XCTAssertEqual(openapi.response.statusCode, 200)
        let openapiText = try XCTUnwrap(String(data: openapi.data, encoding: .utf8))
        XCTAssertTrue(openapiText.contains("openapi: 3."))
        XCTAssertTrue(openapiText.contains("/healthz:"))
        XCTAssertTrue(openapiText.contains("/v1/tools:"))
        XCTAssertTrue(openapiText.contains("/v1/tools/execute:"))

        let tools = try sendRequest(port: port, method: "GET", path: "/v1/tools")
        XCTAssertEqual(tools.response.statusCode, 200)
        XCTAssertNotNil(tools.response.value(forHTTPHeaderField: "X-Request-Id"))
        let toolsPayload = try JSONCoding.makeDecoder().decode(PublicToolsResponse.self, from: tools.data)
        let toolNames = toolsPayload.tools.map(\.name)
        XCTAssertTrue(toolNames.contains("echo_json"))
        XCTAssertTrue(toolNames.contains("write_text_artifact"))

        let executeRequest = ToolExecuteRequest(
            tool: "echo_json",
            input: .object(["message": .string("contract"), "n": .number(2)]),
            context: nil
        )
        let executeRequestBody = try JSONCoding.makeEncoder().encode(executeRequest)
        let executeOK = try sendRequest(
            port: port,
            method: "POST",
            path: "/v1/tools/execute",
            body: executeRequestBody
        )
        XCTAssertEqual(executeOK.response.statusCode, 200)
        XCTAssertNotNil(executeOK.response.value(forHTTPHeaderField: "X-Request-Id"))
        let executeOKPayload = try JSONCoding.makeDecoder().decode(ToolExecutionResult.self, from: executeOK.data)
        XCTAssertEqual(executeOKPayload.status, "ok")
        XCTAssertEqual(executeOKPayload.solver, "echo_json")
        XCTAssertEqual(executeOKPayload.exitCode, 0)
        XCTAssertNotNil(executeOKPayload.metrics["request_id"])
        guard case .object(let output)? = executeOKPayload.output else {
            return XCTFail("Expected output object from echo_json.")
        }
        XCTAssertEqual(output["message"], .string("contract"))

        let executeError = ToolExecuteRequest(tool: "unknown.tool", input: .object([:]), context: nil)
        let executeErrorBody = try JSONCoding.makeEncoder().encode(executeError)
        let executeErr = try sendRequest(
            port: port,
            method: "POST",
            path: "/v1/tools/execute",
            body: executeErrorBody
        )
        XCTAssertEqual(executeErr.response.statusCode, 404)
        let executeErrPayload = try JSONCoding.makeDecoder().decode(ToolExecutionResult.self, from: executeErr.data)
        XCTAssertEqual(executeErrPayload.status, "error")
        XCTAssertEqual(executeErrPayload.solver, "unknown.tool")
        XCTAssertEqual(executeErrPayload.exitCode, 1)
    }

    private func startServer(port: Int) throws {
        let executable = resolveServerExecutableURL()
        let process = Process()
        let out = Pipe()
        let err = Pipe()

        process.executableURL = executable
        process.arguments = [
            "--host", "127.0.0.1",
            "--port", String(port),
            "--log-level", "error"
        ]
        process.standardOutput = out
        process.standardError = err
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

        try process.run()
        serverProcess = process
        stdoutPipe = out
        stderrPipe = err
    }

    private func waitForServerReady(port: Int, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let health = try? sendRequest(port: port, method: "GET", path: "/healthz"),
               health.response.statusCode == 200 {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let stdout = stdoutPipe?.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe?.fileHandleForReading.readDataToEndOfFile()
        let stdoutText = stdout.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let stderrText = stderr.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        throw AutoSageError(
            code: "test_timeout",
            message: "AutoSageServer did not become ready in time. stdout=\(stdoutText) stderr=\(stderrText)"
        )
    }

    private func sendRequest(
        port: Int,
        method: String,
        path: String,
        body: Data? = nil
    ) throws -> (response: HTTPURLResponse, data: Data) {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var receivedData: Data?
        var receivedResponse: HTTPURLResponse?
        var receivedError: Error?

        URLSession.shared.dataTask(with: request) { data, response, error in
            receivedData = data
            receivedResponse = response as? HTTPURLResponse
            receivedError = error
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 6)

        if let receivedError {
            throw receivedError
        }
        guard let receivedResponse, let receivedData else {
            throw AutoSageError(code: "test_http_failed", message: "No HTTP response for \(method) \(path).")
        }
        return (receivedResponse, receivedData)
    }

    private func resolveServerExecutableURL() -> URL {
        let fileManager = FileManager.default
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let candidates: [URL] = [
            cwd.appendingPathComponent(".build/debug/AutoSageServer"),
            cwd.appendingPathComponent(".build/arm64-apple-macosx/debug/AutoSageServer"),
            cwd.appendingPathComponent(".build/x86_64-apple-macosx/debug/AutoSageServer")
        ]

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        XCTFail("AutoSageServer executable not found in expected .build paths.")
        return candidates[0]
    }
}
