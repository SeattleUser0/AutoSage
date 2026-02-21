import Foundation
import ArgumentParser
import AutoSageCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
#error("Unsupported C standard library")
#endif

enum LogLevel: String, CaseIterable, ExpressibleByArgument {
    case trace
    case debug
    case info
    case warn
    case error
}

struct ServerConfiguration {
    let host: String
    let port: Int
    let logLevel: LogLevel
    let verboseNativeFFI: Bool
}

final class HTTPServer {
    private let socketFD: Int32
    private let router = Router()
    private let queue = DispatchQueue(label: "autosage.server", qos: .userInitiated)

    init(configuration: ServerConfiguration) throws {
        socketFD = socket(AF_INET, Self.socketStreamTypeValue(), 0)
        guard socketFD >= 0 else {
            throw NSError(
                domain: "AutoSageServer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create socket."]
            )
        }

        var value: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &value, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(configuration.port).bigEndian)
        let inetStatus = configuration.host.withCString { hostCString in
            inet_pton(AF_INET, hostCString, &addr.sin_addr)
        }
        guard inetStatus == 1 else {
            close(socketFD)
            throw NSError(
                domain: "AutoSageServer",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid host address '\(configuration.host)'. Use an IPv4 address such as 127.0.0.1 or 0.0.0.0."]
            )
        }

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                bind(socketFD, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let errorCode = errno
            close(socketFD)
            if errorCode == EADDRINUSE {
                throw NSError(
                    domain: "AutoSageServer",
                    code: Int(EADDRINUSE),
                    userInfo: [NSLocalizedDescriptionKey: "\(configuration.host):\(configuration.port) is already in use."]
                )
            }
            throw NSError(
                domain: "AutoSageServer",
                code: Int(errorCode),
                userInfo: [NSLocalizedDescriptionKey: "Failed to bind \(configuration.host):\(configuration.port) (errno \(errorCode))."]
            )
        }

        guard listen(socketFD, SOMAXCONN) == 0 else {
            let errorCode = errno
            close(socketFD)
            throw NSError(
                domain: "AutoSageServer",
                code: Int(errorCode),
                userInfo: [NSLocalizedDescriptionKey: "Failed to listen on socket (errno \(errorCode))."]
            )
        }
    }

    func start() {
        queue.async { [socketFD, router] in
            while true {
                var addr = sockaddr()
                var len: socklen_t = socklen_t(MemoryLayout<sockaddr>.size)
                let clientFD = accept(socketFD, &addr, &len)
                if clientFD < 0 {
                    continue
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    Self.handleClient(clientFD: clientFD, router: router)
                }
            }
        }
    }

    private static func socketStreamTypeValue() -> Int32 {
        #if canImport(Darwin)
        return SOCK_STREAM
        #elseif canImport(Glibc) || canImport(Musl)
        return Int32(SOCK_STREAM.rawValue)
        #else
        return 1
        #endif
    }

    private static func handleClient(clientFD: Int32, router: Router) {
        defer { close(clientFD) }
        guard let request = readRequest(from: clientFD) else {
            return
        }
        let response = router.handle(request)
        sendResponse(response, to: clientFD)
    }

    private static func readRequest(from clientFD: Int32) -> HTTPRequest? {
        var buffer = Data()
        let maxBytes = 50_000_000

        while buffer.count < maxBytes {
            var temp = [UInt8](repeating: 0, count: 4096)
            let readCount = recv(clientFD, &temp, temp.count, 0)
            if readCount <= 0 {
                break
            }
            buffer.append(temp, count: readCount)
            if let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer.subdata(in: 0..<headerRange.lowerBound)
                var body = buffer.subdata(in: headerRange.upperBound..<buffer.count)
                let parsed = parseHeaders(headerData)
                guard let method = parsed.method, let path = parsed.path else { return nil }
                let expectedLength = parsed.contentLength
                while body.count < expectedLength && buffer.count < maxBytes {
                    var more = [UInt8](repeating: 0, count: 4096)
                    let extra = recv(clientFD, &more, more.count, 0)
                    if extra <= 0 { break }
                    body.append(more, count: extra)
                }
                let finalBody = expectedLength > 0 ? body.prefix(expectedLength) : Data()
                return HTTPRequest(
                    method: method,
                    path: path,
                    body: expectedLength > 0 ? Data(finalBody) : nil,
                    headers: parsed.headers
                )
            }
        }
        return nil
    }

    private static func parseHeaders(_ data: Data) -> (method: String?, path: String?, contentLength: Int, headers: [String: String]) {
        guard let headerString = String(data: data, encoding: .utf8) else {
            return (nil, nil, 0, [:])
        }
        let lines = headerString.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard let requestLine = lines.first else {
            return (nil, nil, 0, [:])
        }
        let parts = requestLine.split(separator: " ")
        var method: String? = nil
        var path: String? = nil
        if parts.count >= 2 {
            method = String(parts[0])
            path = String(parts[1])
        }
        var contentLength = 0
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let name = line[..<separatorIndex].trimmingCharacters(in: .whitespaces).lowercased()
            let valueStart = line.index(after: separatorIndex)
            let value = line[valueStart...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
            if name == "content-length", let length = Int(value) {
                contentLength = length
            }
        }
        return (method, path, contentLength, headers)
    }

    private static func sendResponse(_ response: HTTPResponse, to clientFD: Int32) {
        let statusText: String
        switch response.status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 413: statusText = "Payload Too Large"
        case 429: statusText = "Too Many Requests"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default: statusText = "OK"
        }

        var headers = response.headers
        headers["Connection"] = "close"

        var headerLines = ["HTTP/1.1 \(response.status) \(statusText)"]
        if response.stream == nil {
            headers["Content-Length"] = "\(response.body.count)"
        }
        for (key, value) in headers {
            headerLines.append("\(key): \(value)")
        }
        headerLines.append("")
        let headerData = Data((headerLines.joined(separator: "\r\n") + "\r\n").utf8)
        _ = headerData.withUnsafeBytes { send(clientFD, $0.baseAddress, headerData.count, 0) }
        if let stream = response.stream {
            stream { chunk in
                _ = chunk.withUnsafeBytes { send(clientFD, $0.baseAddress, chunk.count, 0) }
            }
        } else {
            _ = response.body.withUnsafeBytes { send(clientFD, $0.baseAddress, response.body.count, 0) }
        }
    }
}

@main
struct AutoSageServerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "AutoSageServer",
        abstract: "AutoSage Backend: A cross-platform CAD/CAE orchestration server",
        discussion: """
        If native shared libraries are not in the standard search path, set your loader environment before launch.
        macOS example: DYLD_LIBRARY_PATH=/path/to/native/libs swift run AutoSageServer
        Linux example: LD_LIBRARY_PATH=/path/to/native/libs swift run AutoSageServer
        """,
        helpNames: [.long, .customShort("?")]
    )

    @Option(name: .shortAndLong, help: "The port to listen on.")
    var port: Int = parsePort(ProcessInfo.processInfo.environment["AUTOSAGE_PORT"]) ?? 8080

    @Option(name: .shortAndLong, help: "The interface address to bind to.")
    var host: String = ProcessInfo.processInfo.environment["AUTOSAGE_HOST"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        ? ProcessInfo.processInfo.environment["AUTOSAGE_HOST"]!
        : "127.0.0.1"

    @Option(name: .long, help: "Set the logging level (trace, debug, info, warn, error).")
    var logLevel: LogLevel = .info

    @Flag(name: .long, help: "Enable verbose output for native FFI calls.")
    var verbose = false

    mutating func validate() throws {
        guard (1...65535).contains(port) else {
            throw ValidationError("port must be between 1 and 65535.")
        }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            throw ValidationError("host must be a non-empty IPv4 address.")
        }
        host = trimmedHost
    }

    mutating func run() async throws {
        if verbose {
            setenv("AUTOSAGE_NATIVE_VERBOSE", "1", 1)
        }

        let serverConfiguration = ServerConfiguration(
            host: host,
            port: port,
            logLevel: logLevel,
            verboseNativeFFI: verbose
        )

        let server = try HTTPServer(configuration: serverConfiguration)
        server.start()
        print("[\(serverConfiguration.logLevel.rawValue)] AutoSageServer listening on \(serverConfiguration.host):\(serverConfiguration.port)")
        if serverConfiguration.verboseNativeFFI {
            print("[debug] Native FFI verbose output enabled (AUTOSAGE_NATIVE_VERBOSE=1).")
        }

        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
    }
}
