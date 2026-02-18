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

    public func writeSummary(for job: JobRecord) throws {
        let directoryURL = jobDirectoryURL(for: job.id)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        let summaryURL = directoryURL.appendingPathComponent("summary.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(job)
        try data.write(to: summaryURL, options: .atomic)
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

    public func createJob(toolName: String, input: JSONValue?) -> JobRecord {
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
    }

    public func getJob(id: String) -> JobRecord? {
        jobs[id]
    }

    private func inputSummary(_ input: JSONValue?) -> String? {
        guard let input = input else { return nil }
        if case .object(let dictionary) = input {
            return "Input keys: \(dictionary.keys.sorted().joined(separator: ", "))"
        }
        return "Input provided."
    }
}
