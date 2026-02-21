import Foundation

public struct SessionMessage: Codable, Equatable, Sendable {
    public let role: String
    public let content: String
    public let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case createdAt = "created_at"
    }

    public init(role: String, content: String, createdAt: Date) {
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

public struct SessionManifest: Codable, Equatable, Sendable {
    public let sessionID: String
    public let createdAt: Date
    public let updatedAt: Date
    public let status: String
    public let stage: String
    public let directories: [String: String]
    public let assets: [String]
    public let plannedTool: String?
    public let messages: [SessionMessage]

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case status
        case stage
        case directories
        case assets
        case plannedTool = "planned_tool"
        case messages
    }

    public init(
        sessionID: String,
        createdAt: Date,
        updatedAt: Date,
        status: String,
        stage: String,
        directories: [String: String],
        assets: [String],
        plannedTool: String?,
        messages: [SessionMessage]
    ) {
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
        self.stage = stage
        self.directories = directories
        self.assets = assets
        self.plannedTool = plannedTool
        self.messages = messages
    }
}

public struct SessionCreateResponse: Codable, Equatable, Sendable {
    public let sessionID: String
    public let state: SessionManifest

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case state
    }

    public init(sessionID: String, state: SessionManifest) {
        self.sessionID = sessionID
        self.state = state
    }
}

public struct SessionChatRequest: Codable, Equatable, Sendable {
    public let prompt: String
    public let stream: Bool?

    public init(prompt: String, stream: Bool?) {
        self.prompt = prompt
        self.stream = stream
    }
}

public struct SessionChatResponse: Codable, Equatable, Sendable {
    public let sessionID: String
    public let reply: String
    public let state: SessionManifest

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case reply
        case state
    }

    public init(sessionID: String, reply: String, state: SessionManifest) {
        self.sessionID = sessionID
        self.reply = reply
        self.state = state
    }
}

public struct SessionAsset: Sendable {
    public let data: Data
    public let mimeType: String

    public init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

public struct MultipartUpload: Sendable {
    public let fieldName: String
    public let filename: String
    public let contentType: String?
    public let data: Data

    public init(fieldName: String, filename: String, contentType: String?, data: Data) {
        self.fieldName = fieldName
        self.filename = filename
        self.contentType = contentType
        self.data = data
    }
}

public func defaultSessionsBaseURL() -> URL {
    let env = ProcessInfo.processInfo.environment["AUTOSAGE_SESSIONS_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let env, !env.isEmpty {
        return URL(fileURLWithPath: env, isDirectory: true)
    }
    return URL(fileURLWithPath: "/workspace/autosage/sessions", isDirectory: true)
}

public enum MultipartFormParser {
    public static func parseFirstFile(data: Data, contentType: String) throws -> MultipartUpload {
        guard let boundary = boundary(from: contentType) else {
            throw AutoSageError(
                code: "invalid_request",
                message: "Content-Type must be multipart/form-data with a boundary."
            )
        }
        guard let body = String(data: data, encoding: .utf8) else {
            throw AutoSageError(
                code: "invalid_request",
                message: "Multipart request body must be UTF-8 encoded text."
            )
        }

        let delimiter = "--\(boundary)"
        let segments = body.components(separatedBy: delimiter)
        for rawSegment in segments {
            let segment = rawSegment.trimmingCharacters(in: .whitespacesAndNewlines)
            if segment.isEmpty || segment == "--" {
                continue
            }
            guard let split = segment.range(of: "\r\n\r\n") else {
                continue
            }
            let headerBlock = String(segment[..<split.lowerBound])
            var content = String(segment[split.upperBound...])
            if content.hasSuffix("\r\n") {
                content.removeLast(2)
            }

            let headers = parseHeaders(headerBlock)
            guard let disposition = headers["content-disposition"] else {
                continue
            }
            let attributes = parseContentDispositionAttributes(disposition)
            guard let name = attributes["name"], let filename = attributes["filename"] else {
                continue
            }

            let normalizedName = filename.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedName.isEmpty else {
                continue
            }

            return MultipartUpload(
                fieldName: name,
                filename: normalizedName,
                contentType: headers["content-type"],
                data: Data(content.utf8)
            )
        }

        throw AutoSageError(
            code: "invalid_request",
            message: "Multipart body did not contain an uploaded file."
        )
    }

    private static func boundary(from contentType: String) -> String? {
        let segments = contentType.split(separator: ";")
        guard let boundaryPart = segments.first(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("boundary=")
        }) else {
            return nil
        }
        var value = boundaryPart.trimmingCharacters(in: .whitespacesAndNewlines)
        value = String(value.dropFirst("boundary=".count))
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }

    private static func parseHeaders(_ headerBlock: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in headerBlock.components(separatedBy: "\r\n") {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }
        return headers
    }

    private static func parseContentDispositionAttributes(_ value: String) -> [String: String] {
        var attributes: [String: String] = [:]
        let parts = value.split(separator: ";")
        for raw in parts.dropFirst() {
            let piece = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let keyValue = piece.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard keyValue.count == 2 else { continue }
            let key = String(keyValue[0]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var rawValue = String(keyValue[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if rawValue.hasPrefix("\""), rawValue.hasSuffix("\""), rawValue.count >= 2 {
                rawValue = String(rawValue.dropFirst().dropLast())
            }
            attributes[key] = rawValue
        }
        return attributes
    }
}

public actor SessionStore {
    private let baseURL: URL
    private let fileManager: FileManager
    private var adminLogs: [String] = []
    private let maxAdminLogs = 1_000

    public init(baseURL: URL = defaultSessionsBaseURL(), fileManager: FileManager = .default) {
        self.baseURL = baseURL
        self.fileManager = fileManager
        self.adminLogs = ["[\(iso8601String(from: Date()))] Session store ready at \(baseURL.path)"]
    }

    public func createSession(uploadFilename: String, uploadData: Data, uploadContentType: String?) throws -> SessionManifest {
        let sessionID = "session_" + UUID().uuidString.lowercased()
        let workspace = workspaceURL(for: sessionID)
        let directories = sessionDirectories(for: workspace)

        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: nil)
        for (_, directoryURL) in directories {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        }

        let safeFilename = sanitizeFilename(uploadFilename)
        let inputRelativePath = "input/\(safeFilename)"
        let inputURL = workspace.appendingPathComponent(inputRelativePath)
        try uploadData.write(to: inputURL, options: .atomic)

        let now = Date()
        let manifest = SessionManifest(
            sessionID: sessionID,
            createdAt: now,
            updatedAt: now,
            status: "idle",
            stage: "created",
            directories: directories.mapValues { relativePath(from: workspace, to: $0) },
            assets: [inputRelativePath],
            plannedTool: nil,
            messages: []
        )
        try writeManifest(manifest)
        return manifest
    }

    public func getSession(id: String) throws -> SessionManifest? {
        guard isValidSessionID(id) else {
            throw AutoSageError(code: "invalid_request", message: "Invalid session identifier.")
        }
        let manifestURL = self.manifestURL(for: id)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: manifestURL)
        return try JSONCoding.makeDecoder().decode(SessionManifest.self, from: data)
    }

    public func appendUserPrompt(id: String, prompt: String) throws -> SessionManifest {
        guard var manifest = try getSession(id: id) else {
            throw AutoSageError(code: "not_found", message: "Session not found: \(id).")
        }
        var messages = manifest.messages
        messages.append(SessionMessage(role: "user", content: prompt, createdAt: Date()))
        manifest = SessionManifest(
            sessionID: manifest.sessionID,
            createdAt: manifest.createdAt,
            updatedAt: Date(),
            status: "processing",
            stage: manifest.stage,
            directories: manifest.directories,
            assets: manifest.assets,
            plannedTool: manifest.plannedTool,
            messages: messages
        )
        try writeManifest(manifest)
        return manifest
    }

    public func appendAssistantMessage(id: String, message: String, plannedTool: String?, stage: String) throws -> SessionManifest {
        guard var manifest = try getSession(id: id) else {
            throw AutoSageError(code: "not_found", message: "Session not found: \(id).")
        }
        var messages = manifest.messages
        messages.append(SessionMessage(role: "assistant", content: message, createdAt: Date()))
        manifest = SessionManifest(
            sessionID: manifest.sessionID,
            createdAt: manifest.createdAt,
            updatedAt: Date(),
            status: "idle",
            stage: stage,
            directories: manifest.directories,
            assets: manifest.assets,
            plannedTool: plannedTool,
            messages: messages
        )
        try writeManifest(manifest)
        return manifest
    }

    public func applyStateTransition(
        id: String,
        status: String,
        stage: String,
        plannedTool: String?,
        assistantMessage: String?,
        appendAssets: [String]
    ) throws -> SessionManifest {
        guard var manifest = try getSession(id: id) else {
            throw AutoSageError(code: "not_found", message: "Session not found: \(id).")
        }

        var nextAssets = manifest.assets
        for rawPath in appendAssets {
            guard let normalized = normalizeAssetPath(rawPath) else {
                continue
            }
            if !nextAssets.contains(normalized) {
                nextAssets.append(normalized)
            }
        }

        var nextMessages = manifest.messages
        if let assistantMessage {
            let trimmed = assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                nextMessages.append(SessionMessage(role: "assistant", content: trimmed, createdAt: Date()))
            }
        }

        manifest = SessionManifest(
            sessionID: manifest.sessionID,
            createdAt: manifest.createdAt,
            updatedAt: Date(),
            status: status,
            stage: stage,
            directories: manifest.directories,
            assets: nextAssets,
            plannedTool: plannedTool,
            messages: nextMessages
        )
        try writeManifest(manifest)
        return manifest
    }

    public func readAsset(id: String, assetPath: String) throws -> SessionAsset? {
        guard let fileURL = try resolveAssetURL(id: id, assetPath: assetPath) else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        return SessionAsset(data: data, mimeType: sessionAssetMimeType(for: fileURL.lastPathComponent))
    }

    public func clearJobs() throws -> SessionCleanupSummary {
        var deletedJobs = 0
        var reclaimedBytes: Int64 = 0

        if !fileManager.fileExists(atPath: baseURL.path) {
            try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true, attributes: nil)
            appendAdminLog("Clear jobs requested; sessions root did not exist and was created: \(baseURL.path)")
            return SessionCleanupSummary(
                deletedJobs: 0,
                reclaimedBytes: 0,
                sessionsRoot: baseURL.path
            )
        }

        let entries = try fileManager.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for entry in entries {
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                continue
            }
            guard entry.lastPathComponent.hasPrefix("session_") else {
                continue
            }
            reclaimedBytes += directorySize(at: entry)
            try fileManager.removeItem(at: entry)
            deletedJobs += 1
        }

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let human = formatter.string(fromByteCount: reclaimedBytes)
        appendAdminLog("Cleared \(deletedJobs) session director\(deletedJobs == 1 ? "y" : "ies"), reclaimed \(human).")

        return SessionCleanupSummary(
            deletedJobs: deletedJobs,
            reclaimedBytes: reclaimedBytes,
            sessionsRoot: baseURL.path
        )
    }

    public func recentAdminLogs(limit: Int = 200) -> [String] {
        let boundedLimit = max(1, min(limit, maxAdminLogs))
        if adminLogs.count <= boundedLimit {
            return adminLogs
        }
        return Array(adminLogs.suffix(boundedLimit))
    }

    public func workspaceURLForSession(id: String) throws -> URL {
        guard isValidSessionID(id) else {
            throw AutoSageError(code: "invalid_request", message: "Invalid session identifier.")
        }
        return workspaceURL(for: id)
    }

    private func resolveAssetURL(id: String, assetPath: String) throws -> URL? {
        guard isValidSessionID(id) else {
            throw AutoSageError(code: "invalid_request", message: "Invalid session identifier.")
        }
        let trimmedPath = assetPath.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "/")
        guard !trimmedPath.isEmpty else { return nil }

        let segments = trimmedPath.split(separator: "/").map(String.init)
        guard !segments.isEmpty else { return nil }
        for segment in segments {
            if segment.isEmpty || segment == "." || segment == ".." {
                return nil
            }
        }

        let root = workspaceURL(for: id).standardizedFileURL
        var candidate = root
        for segment in segments {
            candidate.appendPathComponent(segment)
        }
        candidate = candidate.standardizedFileURL

        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPath) else {
            return nil
        }

        guard fileManager.fileExists(atPath: candidate.path) else {
            return nil
        }
        let values = try candidate.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            return nil
        }
        return candidate
    }

    private func writeManifest(_ manifest: SessionManifest) throws {
        let data = try JSONCoding.makeEncoder(prettyPrinted: true).encode(manifest)
        try data.write(to: manifestURL(for: manifest.sessionID), options: .atomic)
    }

    private func sessionDirectories(for workspace: URL) -> [String: URL] {
        [
            "input": workspace.appendingPathComponent("input", isDirectory: true),
            "geometry": workspace.appendingPathComponent("geometry", isDirectory: true),
            "mesh": workspace.appendingPathComponent("mesh", isDirectory: true),
            "solve": workspace.appendingPathComponent("solve", isDirectory: true),
            "render": workspace.appendingPathComponent("render", isDirectory: true),
            "logs": workspace.appendingPathComponent("logs", isDirectory: true)
        ]
    }

    private func workspaceURL(for sessionID: String) -> URL {
        baseURL.appendingPathComponent(sessionID, isDirectory: true)
    }

    private func manifestURL(for sessionID: String) -> URL {
        workspaceURL(for: sessionID).appendingPathComponent("manifest.json")
    }

    private func relativePath(from root: URL, to child: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        if childPath.hasPrefix(rootPath + "/") {
            return String(childPath.dropFirst(rootPath.count + 1))
        }
        return child.lastPathComponent
    }

    private func sanitizeFilename(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = URL(fileURLWithPath: trimmed).lastPathComponent
        guard !filename.isEmpty, filename != ".", filename != ".." else {
            return "upload.dat"
        }
        return filename
    }

    private func normalizeAssetPath(_ rawPath: String) -> String? {
        let normalized = rawPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty else {
            return nil
        }
        let parts = normalized.split(separator: "/").map(String.init)
        guard !parts.isEmpty else {
            return nil
        }
        for segment in parts {
            if segment.isEmpty || segment == "." || segment == ".." {
                return nil
            }
        }
        return parts.joined(separator: "/")
    }

    private func isValidSessionID(_ id: String) -> Bool {
        guard id.hasPrefix("session_"), !id.contains("/"), !id.contains("\\"), !id.contains("..") else {
            return false
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return id.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private func appendAdminLog(_ message: String) {
        let line = "[\(iso8601String(from: Date()))] \(message)"
        adminLogs.append(line)
        let overflow = adminLogs.count - maxAdminLogs
        if overflow > 0 {
            adminLogs.removeFirst(overflow)
        }
    }

    private func directorySize(at rootURL: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
                .totalFileSizeKey,
                .fileSizeKey
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .totalFileAllocatedSizeKey,
                    .fileAllocatedSizeKey,
                    .totalFileSizeKey,
                    .fileSizeKey
                ]
            ) else {
                continue
            }
            guard values.isRegularFile == true else {
                continue
            }
            if let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.totalFileSize ?? values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}

public struct SessionCleanupSummary: Equatable, Sendable {
    public let deletedJobs: Int
    public let reclaimedBytes: Int64
    public let sessionsRoot: String

    public init(deletedJobs: Int, reclaimedBytes: Int64, sessionsRoot: String) {
        self.deletedJobs = deletedJobs
        self.reclaimedBytes = reclaimedBytes
        self.sessionsRoot = sessionsRoot
    }
}

private func iso8601String(from date: Date) -> String {
    sessionsISO8601Formatter.string(from: date)
}

private let sessionsISO8601Formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
}()

public func sessionAssetMimeType(for filename: String) -> String {
    let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
    switch ext {
    case "png":
        return "image/png"
    case "jpg", "jpeg":
        return "image/jpeg"
    case "glb":
        return "model/gltf-binary"
    case "gltf":
        return "model/gltf+json"
    case "obj":
        return "text/plain; charset=utf-8"
    case "stl":
        return "model/stl"
    case "pvd", "vtu", "vtk":
        return "application/xml"
    case "step", "stp", "json":
        return "application/json"
    case "txt", "log", "csv":
        return "text/plain; charset=utf-8"
    default:
        return "application/octet-stream"
    }
}
