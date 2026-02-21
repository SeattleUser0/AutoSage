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

public func defaultRunsBaseURL() -> URL {
    let env = ProcessInfo.processInfo.environment["AUTOSAGE_RUNS_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let env, !env.isEmpty {
        return URL(fileURLWithPath: env, isDirectory: true)
    }
    return URL(fileURLWithPath: "./runs", isDirectory: true)
}

public func artifactMimeType(for filename: String) -> String {
    let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
    switch ext {
    case "json":
        return "application/json"
    case "log", "txt", "cir", "mesh":
        return "text/plain; charset=utf-8"
    case "csv":
        return "text/csv; charset=utf-8"
    case "vtk":
        return "model/vtk"
    case "raw":
        return "application/octet-stream"
    default:
        return "application/octet-stream"
    }
}

public struct RunDirectory {
    public let baseURL: URL
    private let fileManager: FileManager

    public init(baseURL: URL = defaultRunsBaseURL(), fileManager: FileManager = .default) {
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
            let name = url.lastPathComponent
            let size = values.fileSize ?? 0
            return JobArtifactFile(
                name: name,
                path: artifactRoutePath(jobID: jobID, artifactName: name),
                mimeType: artifactMimeType(for: name),
                bytes: size
            )
        }.sorted { $0.name < $1.name }
    }

    public func artifactURL(for jobID: String, artifactName: String) -> URL? {
        guard isValidArtifactName(artifactName) else { return nil }
        let url = jobDirectoryURL(for: jobID).appendingPathComponent(artifactName)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else {
            return nil
        }
        return url
    }

    public func readArtifact(jobID: String, artifactName: String) -> (data: Data, mimeType: String)? {
        guard let url = artifactURL(for: jobID, artifactName: artifactName),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return (data, artifactMimeType(for: artifactName))
    }

    public func loadJobs() throws -> [String: JobRecord] {
        guard fileManager.fileExists(atPath: baseURL.path) else { return [:] }
        let directoryContents = try fileManager.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var jobs: [String: JobRecord] = [:]
        let decoder = JSONCoding.makeDecoder()
        for url in directoryContents {
            guard url.lastPathComponent.hasPrefix("job_") else { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            let summaryURL = url.appendingPathComponent("summary.json")
            guard fileManager.fileExists(atPath: summaryURL.path),
                  let summaryData = try? Data(contentsOf: summaryURL),
                  let summary = try? decoder.decode(JobSummary.self, from: summaryData) else {
                continue
            }

            var result: JSONValue?
            var error: AutoSageError?
            let resultURL = url.appendingPathComponent("result.json")
            if fileManager.fileExists(atPath: resultURL.path),
               let data = try? Data(contentsOf: resultURL),
               let decoded = try? decoder.decode(JSONValue.self, from: data) {
                result = decoded
            }
            let errorURL = url.appendingPathComponent("error.json")
            if fileManager.fileExists(atPath: errorURL.path),
               let data = try? Data(contentsOf: errorURL),
               let decoded = try? decoder.decode(AutoSageError.self, from: data) {
                error = decoded
            }

            let status: JobStatus
            if error != nil {
                status = .failed
                result = nil
            } else if result != nil {
                status = .succeeded
            } else {
                status = summary.status
            }

            let record = JobRecord(
                id: summary.id,
                toolName: summary.toolName,
                createdAt: summary.createdAt,
                startedAt: summary.startedAt,
                finishedAt: summary.finishedAt,
                status: status,
                summary: summary.summary,
                result: result,
                error: error
            )
            jobs[record.id] = record
        }
        return jobs
    }

    public func highestJobIndex() -> Int {
        guard fileManager.fileExists(atPath: baseURL.path),
              let directoryContents = try? fileManager.contentsOfDirectory(
                  at: baseURL,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return 0
        }
        var maxIndex = 0
        for url in directoryContents {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true,
                  let index = parseJobIndex(url.lastPathComponent) else {
                continue
            }
            maxIndex = max(maxIndex, index)
        }
        return maxIndex
    }

    private func artifactRoutePath(jobID: String, artifactName: String) -> String {
        let encodedName = artifactName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? artifactName
        return "/v1/jobs/\(jobID)/artifacts/\(encodedName)"
    }

    private func isValidArtifactName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        if name.contains("/") || name.contains("\\") || name.contains("..") {
            return false
        }
        return URL(fileURLWithPath: name).lastPathComponent == name
    }

    private func parseJobIndex(_ jobID: String) -> Int? {
        guard jobID.hasPrefix("job_") else { return nil }
        let suffix = jobID.dropFirst(4)
        return Int(suffix)
    }
}

public actor JobStore {
    private var jobs: [String: JobRecord] = [:]
    private let idGenerator: RequestIDGenerator
    private let runDirectory: RunDirectory

    public init(
        idGenerator: RequestIDGenerator = RequestIDGenerator(),
        runDirectory: RunDirectory = RunDirectory(),
        loadFromDisk: Bool = true
    ) {
        self.idGenerator = idGenerator
        self.runDirectory = runDirectory
        var loadedJobs: [String: JobRecord] = [:]
        if loadFromDisk {
            loadedJobs = (try? runDirectory.loadJobs()) ?? [:]
        }
        self.jobs = loadedJobs
        idGenerator.seedJobCounterIfHigher(Self.maxJobIndex(loadedJobs: loadedJobs, runDirectory: runDirectory))
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

    public func readArtifact(id: String, name: String) -> (data: Data, mimeType: String)? {
        guard jobs[id] != nil else { return nil }
        return runDirectory.readArtifact(jobID: id, artifactName: name)
    }

    public func jobDirectoryURL(id: String) -> URL? {
        guard jobs[id] != nil else { return nil }
        return runDirectory.jobDirectoryURL(for: id)
    }

    private func inputSummary(_ input: JSONValue?) -> String? {
        guard let input = input else { return nil }
        if case .object(let dictionary) = input {
            return "Input keys: \(dictionary.keys.sorted().joined(separator: ", "))"
        }
        return "Input provided."
    }

    private static func maxJobIndex(loadedJobs: [String: JobRecord], runDirectory: RunDirectory) -> Int {
        var maxIndex = runDirectory.highestJobIndex()
        for id in loadedJobs.keys {
            guard id.hasPrefix("job_"),
                  let value = Int(id.dropFirst(4)) else {
                continue
            }
            maxIndex = max(maxIndex, value)
        }
        return maxIndex
    }
}
