import Foundation
import AutoSageCore
import Darwin

final class HTTPServer {
    private let socketFD: Int32
    private let router = Router()
    private let queue = DispatchQueue(label: "autosage.server", qos: .userInitiated)

    init(port: Int) throws {
        socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw NSError(domain: "AutoSageServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create socket"]) 
        }

        var value: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &value, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                Darwin.bind(socketFD, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let errorCode = errno
            close(socketFD)
            if errorCode == EADDRINUSE {
                let message = "AutoSageServer error: 127.0.0.1:\(port) is already in use.\n"
                fputs(message, stderr)
                exit(1)
            }
            let message = "AutoSageServer error: failed to bind 127.0.0.1:\(port) (errno \(errorCode)).\n"
            fputs(message, stderr)
            exit(1)
        }

        guard listen(socketFD, SOMAXCONN) == 0 else {
            close(socketFD)
            throw NSError(domain: "AutoSageServer", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to listen on socket"]) 
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
                    handleClient(clientFD: clientFD, router: router)
                }
            }
        }
    }
}

private func handleClient(clientFD: Int32, router: Router) {
    defer { close(clientFD) }
    guard let request = readRequest(from: clientFD) else {
        return
    }
    let response = router.handle(request)
    sendResponse(response, to: clientFD)
}

private func readRequest(from clientFD: Int32) -> HTTPRequest? {
    var buffer = Data()
    let maxBytes = 1_048_576

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
            return HTTPRequest(method: method, path: path, body: expectedLength > 0 ? Data(finalBody) : nil)
        }
    }
    return nil
}

private func parseHeaders(_ data: Data) -> (method: String?, path: String?, contentLength: Int) {
    guard let headerString = String(data: data, encoding: .utf8) else {
        return (nil, nil, 0)
    }
    let lines = headerString.components(separatedBy: "\r\n").filter { !$0.isEmpty }
    guard let requestLine = lines.first else {
        return (nil, nil, 0)
    }
    let parts = requestLine.split(separator: " ")
    var method: String? = nil
    var path: String? = nil
    if parts.count >= 2 {
        method = String(parts[0])
        path = String(parts[1])
    }
    var contentLength = 0
    for line in lines.dropFirst() {
        guard let separatorIndex = line.firstIndex(of: ":") else { continue }
        let name = line[..<separatorIndex].trimmingCharacters(in: .whitespaces).lowercased()
        let valueStart = line.index(after: separatorIndex)
        let value = line[valueStart...].trimmingCharacters(in: .whitespaces)
        if name == "content-length", let length = Int(value) {
            contentLength = length
        }
    }
    return (method, path, contentLength)
}

private func sendResponse(_ response: HTTPResponse, to clientFD: Int32) {
    let statusText: String
    switch response.status {
    case 200: statusText = "OK"
    case 400: statusText = "Bad Request"
    case 404: statusText = "Not Found"
    default: statusText = "OK"
    }

    var headers = response.headers
    headers["Content-Length"] = "\(response.body.count)"
    headers["Connection"] = "close"

    var headerLines = ["HTTP/1.1 \(response.status) \(statusText)"]
    for (key, value) in headers {
        headerLines.append("\(key): \(value)")
    }
    headerLines.append("")
    let headerData = Data((headerLines.joined(separator: "\r\n") + "\r\n").utf8)
    _ = headerData.withUnsafeBytes { send(clientFD, $0.baseAddress, headerData.count, 0) }
    _ = response.body.withUnsafeBytes { send(clientFD, $0.baseAddress, response.body.count, 0) }
}

let port = parsePort(ProcessInfo.processInfo.environment["AUTOSAGE_PORT"]) ?? 8080
let server = try HTTPServer(port: port)
server.start()
print("AutoSageServer listening on 127.0.0.1:\(port)")
RunLoop.main.run()
