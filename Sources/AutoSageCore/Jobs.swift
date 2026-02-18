import Foundation

public enum JobStatus: String, Codable, Equatable, Sendable {
    case queued
    case running
    case succeeded
    case failed
}

public struct JobRecord: Codable, Equatable, Sendable {
    public let id: String
    public let toolName: String
    public let createdAt: Date
    public let startedAt: Date?
    public let finishedAt: Date?
    public let status: JobStatus
    public let summary: String?
    public let result: JSONValue?
    public let error: AutoSageError?

    enum CodingKeys: String, CodingKey {
        case id
        case toolName = "tool_name"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case status
        case summary
        case result
        case error
    }

    public init(
        id: String,
        toolName: String,
        createdAt: Date,
        startedAt: Date?,
        finishedAt: Date?,
        status: JobStatus,
        summary: String?,
        result: JSONValue?,
        error: AutoSageError?
    ) {
        self.id = id
        self.toolName = toolName
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.summary = summary
        self.result = result
        self.error = error
    }
}

public struct JobSummary: Codable, Equatable, Sendable {
    public let id: String
    public let toolName: String
    public let createdAt: Date
    public let startedAt: Date?
    public let finishedAt: Date?
    public let status: JobStatus
    public let summary: String?

    enum CodingKeys: String, CodingKey {
        case id
        case toolName = "tool_name"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case status
        case summary
    }

    public init(
        id: String,
        toolName: String,
        createdAt: Date,
        startedAt: Date?,
        finishedAt: Date?,
        status: JobStatus,
        summary: String?
    ) {
        self.id = id
        self.toolName = toolName
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.summary = summary
    }
}

public struct RunDirectory {
    public let baseURL: URL
    private let fileManager: FileManager

    public init(baseURL: URL = URL(fileURLWithPath: "./runs", isDirectory: true), fileManager: FileManager = .default) {
        self.baseURL = baseURL
        self.fileManager = fileManager
    }

    public func jobDirectoryURL(for jobID: String) -> URL {
        baseURL.appendingPathComponent(jobID, isDirectory: true)
    }

    public func writeRequest(jobID: String, body: Data) throws {
        let directoryURL = jobDirectoryURL(for: jobID)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        let requestURL = directoryURL.appendingPathComponent("request.json")
        try body.write(to: requestURL, options: .atomic)
    }

    public func writeSummary(for job: JobRecord) throws {
        let directoryURL = jobDirectoryURL(for: job.id)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        let summaryURL = directoryURL.appendingPathComponent("summary.json")
        let summary = JobSummary(
            id: job.id,
            toolName: job.toolName,
            createdAt: job.createdAt,
            startedAt: job.startedAt,
            finishedAt: job.finishedAt,
            status: job.status,
            summary: job.summary
        )
        let encoder = JSONCoding.makeEncoder(prettyPrinted: true)
        let data = try encoder.encode(summary)
        try data.write(to: summaryURL, options: .atomic)
    }

    public func writeResult(jobID: String, result: JSONValue) throws {
        let directoryURL = jobDirectoryURL(for: jobID)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        let resultURL = directoryURL.appendingPathComponent("result.json")
        let encoder = JSONCoding.makeEncoder(prettyPrinted: true)
        let data = try encoder.encode(result)
        try data.write(to: resultURL, options: .atomic)
    }

    public func writeError(jobID: String, error: AutoSageError) throws {
        let directoryURL = jobDirectoryURL(for: jobID)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        let errorURL = directoryURL.appendingPathComponent("error.json")
        let encoder = JSONCoding.makeEncoder(prettyPrinted: true)
        let data = try encoder.encode(error)
        try data.write(to: errorURL, options: .atomic)
    }

    public func listArtifacts(for jobID: String) throws -> [JobArtifactFile] {
        let directoryURL = jobDirectoryURL(for: jobID)
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        let contents = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        return contents.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                return nil
            }
            let size = values.fileSize ?? 0
            return JobArtifactFile(name: url.lastPathComponent, bytes: size)
        }.sorted { $0.name < $1.name }
    }
}

public actor JobStore {
    private var jobs: [String: JobRecord] = [:]
    private let idGenerator: RequestIDGenerator
    private let runDirectory: RunDirectory

    public init(idGenerator: RequestIDGenerator = RequestIDGenerator(), runDirectory: RunDirectory = RunDirectory()) {
        self.idGenerator = idGenerator
        self.runDirectory = runDirectory
    }

    public func createJob(toolName: String, input: JSONValue?, requestBody: Data? = nil) -> JobRecord {
        let now = Date()
        let job = JobRecord(
            id: idGenerator.nextJobID(),
            toolName: toolName,
            createdAt: now,
            startedAt: nil,
            finishedAt: nil,
            status: .queued,
            summary: inputSummary(input),
            result: nil,
            error: nil
        )
        jobs[job.id] = job
        let requestData = requestBody ?? Data("null".utf8)
        try? runDirectory.writeRequest(jobID: job.id, body: requestData)
        try? runDirectory.writeSummary(for: job)
        return job
    }

    public func startJob(id: String) {
        guard var job = jobs[id], job.status == .queued else { return }
        job = JobRecord(
            id: job.id,
            toolName: job.toolName,
            createdAt: job.createdAt,
            startedAt: Date(),
            finishedAt: nil,
            status: .running,
            summary: job.summary,
            result: nil,
            error: nil
        )
        jobs[id] = job
        try? runDirectory.writeSummary(for: job)
    }

    public func completeJob(id: String, result: JSONValue, summary: String) {
        guard let job = jobs[id] else { return }
        let completed = JobRecord(
            id: job.id,
            toolName: job.toolName,
            createdAt: job.createdAt,
            startedAt: job.startedAt ?? Date(),
            finishedAt: Date(),
            status: .succeeded,
            summary: summary,
            result: result,
            error: nil
        )
        jobs[id] = completed
        try? runDirectory.writeSummary(for: completed)
        try? runDirectory.writeResult(jobID: completed.id, result: result)
    }

    public func failJob(id: String, error: AutoSageError) {
        guard let job = jobs[id] else { return }
        let failed = JobRecord(
            id: job.id,
            toolName: job.toolName,
            createdAt: job.createdAt,
            startedAt: job.startedAt ?? Date(),
            finishedAt: Date(),
            status: .failed,
            summary: nil,
            result: nil,
            error: error
        )
        jobs[id] = failed
        try? runDirectory.writeSummary(for: failed)
        try? runDirectory.writeError(jobID: failed.id, error: error)
    }

    public func getJob(id: String) -> JobRecord? {
        jobs[id]
    }

    public func listArtifacts(id: String) -> [JobArtifactFile]? {
        guard jobs[id] != nil else { return nil }
        return (try? runDirectory.listArtifacts(for: id)) ?? []
    }

    private func inputSummary(_ input: JSONValue?) -> String? {
        guard let input = input else { return nil }
        if case .object(let dictionary) = input {
            return "Input keys: \(dictionary.keys.sorted().joined(separator: ", "))"
        }
        return "Input provided."
    }
}
