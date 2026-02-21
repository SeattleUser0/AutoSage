import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
#error("Unsupported C standard library")
#endif

public struct FEADriverExecutionResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let elapsedMS: Int

    public init(exitCode: Int32, stdout: String, stderr: String, elapsedMS: Int) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.elapsedMS = elapsedMS
    }
}

public typealias FEADriverRunner = @Sendable (
    _ driverExecutable: String,
    _ inputURL: URL,
    _ resultURL: URL,
    _ summaryURL: URL,
    _ vtkURL: URL,
    _ workingDirectoryURL: URL,
    _ limits: ToolExecutionLimits
) throws -> FEADriverExecutionResult

public struct FEATool: Tool {
    public let name: String = "fea.solve"
    public let version: String
    public let description: String
    public let jsonSchema: JSONValue = FEATool.schema

    private let driverRunner: FEADriverRunner
    private let driverResolver: @Sendable () -> String?

    public init(
        version: String = "0.3.0",
        description: String = "Finite element analysis via MFEM driver binary.",
        driverRunner: @escaping FEADriverRunner = FEATool.defaultDriverRunner,
        driverResolver: @escaping @Sendable () -> String? = FEATool.defaultDriverResolverClosure
    ) {
        self.version = version
        self.description = description
        self.driverRunner = driverRunner
        self.driverResolver = driverResolver
    }

    public func run(input: JSONValue?, context: ToolExecutionContext) throws -> JSONValue {
        let normalizedInput = try Self.decodeAndValidateInput(input)
        try FileManager.default.createDirectory(
            at: context.jobDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let inputURL = context.jobDirectoryURL.appendingPathComponent("job_input.json")
        let resultURL = context.jobDirectoryURL.appendingPathComponent("job_result.json")
        let summaryURL = context.jobDirectoryURL.appendingPathComponent("job_summary.json")
        let vtkURL = context.jobDirectoryURL.appendingPathComponent("solution.vtk")

        let inputData = try JSONCoding.makeEncoder(prettyPrinted: true).encode(JSONValue.object(normalizedInput))
        try inputData.write(to: inputURL, options: .atomic)

        let driverExecutable = try Self.resolveDriverExecutable(driverResolver())
        let processResult = try driverRunner(
            driverExecutable,
            inputURL,
            resultURL,
            summaryURL,
            vtkURL,
            context.jobDirectoryURL,
            context.limits
        )

        if processResult.exitCode != 0 {
            throw AutoSageError(
                code: "solver_failed",
                message: "mfem-driver exited with status \(processResult.exitCode).",
                details: [
                    "exit_code": .number(Double(processResult.exitCode)),
                    "stdout_tail": .string(Self.lastLines(in: processResult.stdout, count: 40, maxCharacters: 6_000)),
                    "stderr_tail": .string(Self.lastLines(in: processResult.stderr, count: 40, maxCharacters: 6_000))
                ]
            )
        }

        guard FileManager.default.fileExists(atPath: summaryURL.path) else {
            throw AutoSageError(
                code: "solver_failed",
                message: "mfem-driver did not produce job_summary.json.",
                details: ["expected_path": .string(summaryURL.path)]
            )
        }

        let summaryJSON = try Self.readJSONValue(from: summaryURL)
        let resultJSON = FileManager.default.fileExists(atPath: resultURL.path)
            ? (try? Self.readJSONValue(from: resultURL))
            : nil
        let mergedOutput = Self.mergeResultAndSummary(result: resultJSON, summary: summaryJSON)

        let artifacts = Self.collectArtifacts(
            in: context.jobDirectoryURL,
            jobID: context.jobID,
            maxArtifactBytes: context.limits.maxArtifactBytes,
            maxArtifacts: context.limits.maxArtifacts
        )
        let metrics = Self.metrics(from: summaryJSON, elapsedMS: processResult.elapsedMS, jobID: context.jobID)
        let summaryText = Self.summaryText(from: summaryJSON, fallback: "MFEM solve completed.")

        let executionResult = ToolExecutionResult(
            status: "ok",
            solver: "mfem",
            summary: Self.cappedSummary(summaryText, limit: context.limits.maxSummaryCharacters),
            stdout: processResult.stdout,
            stderr: processResult.stderr,
            exitCode: Int(processResult.exitCode),
            artifacts: artifacts,
            metrics: metrics,
            output: mergedOutput
        )
        return try executionResult.asJSONValue()
    }

    public static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "solver_class": .object([
                "type": .string("string"),
                "description": .string("Class name understood by mfem-driver, for example LinearElasticity or Poisson.")
            ]),
            "mesh": .object([
                "type": .string("object"),
                "description": .string("Mesh definition consumed by mfem-driver."),
                "properties": .object([
                    "type": .object([
                        "type": .string("string"),
                        "enum": .stringArray(["inline_mfem", "file"])
                    ]),
                    "data": .object([
                        "type": .string("string"),
                        "description": .string("Inline mesh text when type=inline_mfem.")
                    ]),
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Absolute or job-relative mesh file path when type=file.")
                    ]),
                    "encoding": .object([
                        "type": .string("string"),
                        "enum": .stringArray(["plain", "base64"])
                    ])
                ]),
                "required": .stringArray(["type"]),
                "additionalProperties": .bool(true)
            ]),
            "config": .object([
                "type": .string("object"),
                "description": .string("Opaque solver configuration passed directly to mfem-driver."),
                "additionalProperties": .bool(true)
            ])
        ]),
        "required": .stringArray(["solver_class", "mesh", "config"]),
        "additionalProperties": .bool(true)
    ])

    public static let defaultDriverRunner: FEADriverRunner = {
        driverExecutable, inputURL, resultURL, summaryURL, vtkURL, workingDirectoryURL, limits in
        try defaultRunner(
            driverExecutable: driverExecutable,
            inputURL: inputURL,
            resultURL: resultURL,
            summaryURL: summaryURL,
            vtkURL: vtkURL,
            workingDirectoryURL: workingDirectoryURL,
            limits: limits
        )
    }

    public static let defaultDriverResolverClosure: @Sendable () -> String? = {
        defaultDriverResolver()
    }

    public static func defaultDriverResolver() -> String? {
        let env = ProcessInfo.processInfo.environment["AUTOSAGE_MFEM_DRIVER"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let env, !env.isEmpty {
            return env
        }
        return "mfem-driver"
    }

    public static func defaultRunner(
        driverExecutable: String,
        inputURL: URL,
        resultURL: URL,
        summaryURL: URL,
        vtkURL: URL,
        workingDirectoryURL: URL,
        limits: ToolExecutionLimits
    ) throws -> FEADriverExecutionResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            driverExecutable,
            "--input", inputURL.path,
            "--result", resultURL.path,
            "--summary", summaryURL.path,
            "--vtk", vtkURL.path
        ]
        process.currentDirectoryURL = workingDirectoryURL

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let startedAt = Date()
        do {
            try process.run()
        } catch {
            throw AutoSageError(
                code: "solver_not_installed",
                message: "mfem-driver is not installed or not executable.",
                details: ["driver": .string(driverExecutable)]
            )
        }

        let timeoutSeconds = Double(max(1, limits.timeoutMS)) / 1_000.0
        if !waitForProcess(process, timeoutS: timeoutSeconds) {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.25)
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
            }
            throw AutoSageError(
                code: "timeout",
                message: "mfem-driver timed out after \(limits.timeoutMS)ms."
            )
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return FEADriverExecutionResult(
            exitCode: process.terminationStatus,
            stdout: decodeAndCap(
                data: stdoutData,
                maxBytes: limits.maxStdoutBytes,
                suffix: "\n[stdout truncated]"
            ),
            stderr: decodeAndCap(
                data: stderrData,
                maxBytes: limits.maxStderrBytes,
                suffix: "\n[stderr truncated]"
            ),
            elapsedMS: Int(Date().timeIntervalSince(startedAt) * 1_000)
        )
    }

    private static func decodeAndValidateInput(_ input: JSONValue?) throws -> [String: JSONValue] {
        guard let input else {
            throw AutoSageError(
                code: "invalid_input",
                message: "fea.solve requires an input object."
            )
        }
        guard case .object(let object) = input else {
            throw AutoSageError(
                code: "invalid_input",
                message: "fea.solve input must be an object."
            )
        }

        guard case .string(let solverClassRaw)? = object["solver_class"] else {
            throw AutoSageError(
                code: "invalid_input",
                message: "solver_class is required and must be a string."
            )
        }
        let solverClass = solverClassRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !solverClass.isEmpty else {
            throw AutoSageError(
                code: "invalid_input",
                message: "solver_class must be a non-empty string."
            )
        }

        guard case .object(let meshObject)? = object["mesh"] else {
            throw AutoSageError(
                code: "invalid_input",
                message: "mesh is required and must be an object."
            )
        }
        guard case .string(let meshTypeRaw)? = meshObject["type"] else {
            throw AutoSageError(
                code: "invalid_input",
                message: "mesh.type is required and must be a string."
            )
        }
        let meshType = meshTypeRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard meshType == "inline_mfem" || meshType == "file" else {
            throw AutoSageError(
                code: "invalid_input",
                message: "mesh.type must be inline_mfem or file."
            )
        }
        if meshType == "inline_mfem" {
            guard case .string(let meshData)? = meshObject["data"],
                  !meshData.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AutoSageError(
                    code: "invalid_input",
                    message: "mesh.data is required for mesh.type=inline_mfem."
                )
            }
        } else {
            guard case .string(let meshPath)? = meshObject["path"],
                  !meshPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AutoSageError(
                    code: "invalid_input",
                    message: "mesh.path is required for mesh.type=file."
                )
            }
        }
        if let encodingValue = meshObject["encoding"] {
            guard case .string(let encodingRaw) = encodingValue else {
                throw AutoSageError(
                    code: "invalid_input",
                    message: "mesh.encoding must be a string when provided."
                )
            }
            let encoding = encodingRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard encoding == "plain" || encoding == "base64" else {
                throw AutoSageError(
                    code: "invalid_input",
                    message: "mesh.encoding must be plain or base64."
                )
            }
        }

        guard case .object = object["config"] else {
            throw AutoSageError(
                code: "invalid_input",
                message: "config is required and must be an object."
            )
        }

        var normalizedObject = object
        normalizedObject["solver_class"] = .string(solverClass)
        var normalizedMeshObject = meshObject
        normalizedMeshObject["type"] = .string(meshType)
        if case .string(let encodingRaw)? = meshObject["encoding"] {
            normalizedMeshObject["encoding"] = .string(
                encodingRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            )
        }
        normalizedObject["mesh"] = .object(normalizedMeshObject)
        return normalizedObject
    }

    private static func resolveDriverExecutable(_ value: String?) throws -> String {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw AutoSageError(
                code: "solver_not_installed",
                message: "mfem-driver is not configured."
            )
        }
        let basename = URL(fileURLWithPath: value).lastPathComponent
        guard basename == "mfem-driver" else {
            throw AutoSageError(
                code: "invalid_configuration",
                message: "AUTOSAGE_MFEM_DRIVER must point to mfem-driver binary.",
                details: ["driver": .string(value)]
            )
        }
        return value
    }

    private static func readJSONValue(from url: URL) throws -> JSONValue {
        let data = try Data(contentsOf: url)
        return try JSONCoding.makeDecoder().decode(JSONValue.self, from: data)
    }

    private static func mergeResultAndSummary(result: JSONValue?, summary: JSONValue) -> JSONValue {
        switch (result, summary) {
        case (.object(let resultObject)?, .object(let summaryObject)):
            var merged = resultObject
            for (key, value) in summaryObject where merged[key] == nil {
                merged[key] = value
            }
            merged["summary_fields"] = .object(summaryObject)
            return .object(merged)
        default:
            return summary
        }
    }

    private static func metrics(from summary: JSONValue, elapsedMS: Int, jobID: String) -> [String: JSONValue] {
        var metrics: [String: JSONValue] = [
            "elapsed_ms": .number(Double(max(0, elapsedMS))),
            "job_id": .string(jobID)
        ]
        if case .object(let summaryObject) = summary {
            if case .number(let iterations)? = summaryObject["iterations"] {
                metrics["iterations"] = .number(iterations)
            }
            if case .number(let energy)? = summaryObject["energy"] {
                metrics["energy"] = .number(energy)
            }
            if case .number(let errorNorm)? = summaryObject["error_norm"] {
                metrics["error_norm"] = .number(errorNorm)
            }
        }
        return metrics
    }

    private static func summaryText(from summary: JSONValue, fallback: String) -> String {
        guard case .object(let summaryObject) = summary else { return fallback }
        if case .string(let message)? = summaryObject["summary"], !message.isEmpty {
            return message
        }
        let solverValue = summaryObject["solver_class"] ?? summaryObject["analysis_type"] ?? .string("solver")
        let solver = solverValue.descriptionForSummary
        if case .number(let iterations)? = summaryObject["iterations"] {
            return "\(solver) solve converged in \(Int(iterations)) iterations."
        }
        return "\(solver) solve completed."
    }

    private static func cappedSummary(_ summary: String, limit: Int) -> String {
        guard summary.count > limit else { return summary }
        return String(summary.prefix(max(3, limit - 3))) + "..."
    }

    private static func collectArtifacts(
        in directoryURL: URL,
        jobID: String,
        maxArtifactBytes: Int,
        maxArtifacts: Int
    ) -> [ToolArtifact] {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var artifacts: [ToolArtifact] = []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard artifacts.count < maxArtifacts else { break }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                continue
            }
            let bytes = values.fileSize ?? 0
            guard bytes <= maxArtifactBytes else { continue }
            let name = url.lastPathComponent
            let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            artifacts.append(
                ToolArtifact(
                    name: name,
                    path: "/v1/jobs/\(jobID)/artifacts/\(encodedName)",
                    mimeType: artifactMimeType(for: name),
                    bytes: bytes
                )
            )
        }
        return artifacts
    }

    private static func decodeAndCap(data: Data, maxBytes: Int, suffix: String) -> String {
        guard data.count > maxBytes else {
            return String(data: data, encoding: .utf8) ?? ""
        }
        let prefix = data.prefix(max(0, maxBytes))
        return (String(data: prefix, encoding: .utf8) ?? "") + suffix
    }

    private static func waitForProcess(_ process: Process, timeoutS: TimeInterval) -> Bool {
        if !process.isRunning {
            return true
        }
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        if !process.isRunning {
            return true
        }
        return semaphore.wait(timeout: .now() + timeoutS) == .success
    }

    private static func lastLines(in text: String, count: Int, maxCharacters: Int) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let tail = lines.suffix(count).joined(separator: "\n")
        if tail.count <= maxCharacters {
            return tail
        }
        return String(tail.suffix(maxCharacters))
    }
}

private extension JSONValue {
    var descriptionForSummary: String {
        switch self {
        case .string(let text):
            return text
        default:
            return "solver"
        }
    }
}
