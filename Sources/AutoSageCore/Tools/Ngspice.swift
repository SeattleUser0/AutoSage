// SPDX-License-Identifier: MIT
// AutoSage ngspice shared-library tool backed by ngspice_ffi C ABI.

import Foundation
import CNgspiceFFI
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
#error("Unsupported C standard library")
#endif

private struct CircuitSimulateNgspiceInput: Codable, Equatable, Sendable {
    let netlistPath: String
    let targetVectors: [String]?

    enum CodingKeys: String, CodingKey {
        case netlistPath = "netlist_path"
        case targetVectors = "target_vectors"
    }
}

public struct NgspiceNativeVector: Equatable, Sendable {
    public let name: String
    public let data: [Double]

    public init(name: String, data: [Double]) {
        self.name = name
        self.data = data
    }
}

public struct NgspiceNativeResult: Equatable, Sendable {
    public let vectors: [NgspiceNativeVector]
    public let errorCode: Int32
    public let errorMessage: String?
    public let stdoutLog: String
    public let stderrLog: String

    public init(
        vectors: [NgspiceNativeVector],
        errorCode: Int32,
        errorMessage: String?,
        stdoutLog: String,
        stderrLog: String
    ) {
        self.vectors = vectors
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.stdoutLog = stdoutLog
        self.stderrLog = stderrLog
    }
}

public typealias NgspiceFFIInvoker = @Sendable (
    _ netlistPath: String,
    _ targetVectors: [String]
) throws -> NgspiceNativeResult

public struct CircuitSimulateNgspiceTool: Tool {
    public let name: String = "circuit_simulate_ngspice"
    public let version: String
    public let description: String
    public let jsonSchema: JSONValue = CircuitSimulateNgspiceTool.schema

    private let invoker: NgspiceFFIInvoker

    public init(
        version: String = "0.1.0",
        description: String = "Simulates a SPICE netlist via ngspice shared library and returns requested vectors.",
        invoker: @escaping NgspiceFFIInvoker = CircuitSimulateNgspiceTool.defaultInvoker
    ) {
        self.version = version
        self.description = description
        self.invoker = invoker
    }

    public func run(input: JSONValue?, context: ToolExecutionContext) throws -> JSONValue {
        let startedAt = Date()
        let decoded = try Self.decodeInput(input)
        let netlistURL = try Self.resolveNetlistURL(decoded.netlistPath, context: context)

        guard FileManager.default.fileExists(atPath: netlistURL.path) else {
            throw AutoSageError(
                code: "invalid_input",
                message: "netlist_path does not exist.",
                details: ["netlist_path": .string(netlistURL.path)]
            )
        }

        let targetVectors = try Self.normalizeTargetVectors(decoded.targetVectors)
        let native = try invoker(netlistURL.path, targetVectors)

        if native.errorCode != 0 {
            throw Self.mapNativeError(native)
        }

        if native.vectors.isEmpty {
            throw AutoSageError(
                code: "solver_failed",
                message: "ngspice shared simulation returned no vectors."
            )
        }

        try FileManager.default.createDirectory(
            at: context.jobDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let simulationDir = context.jobDirectoryURL.appendingPathComponent("simulation", isDirectory: true)
        try FileManager.default.createDirectory(
            at: simulationDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let cappedVectors = native.vectors.prefix(64).map { vector in
            NgspiceNativeVector(
                name: vector.name,
                data: Self.capSeries(vector.data, maxPoints: 2000)
            )
        }

        var vectorMap: [String: JSONValue] = [:]
        for vector in cappedVectors {
            vectorMap[vector.name] = .numberArray(vector.data)
        }

        let outputFileURL = simulationDir.appendingPathComponent("vectors.json")
        let filePayload: JSONValue = .object([
            "netlist_path": .string(netlistURL.path),
            "vectors": .object(vectorMap)
        ])
        let fileData = try JSONCoding.makeEncoder(prettyPrinted: true).encode(filePayload)
        try fileData.write(to: outputFileURL, options: .atomic)

        let artifact = try Self.makeArtifact(
            fileURL: outputFileURL,
            jobID: context.jobID,
            maxArtifactBytes: context.limits.maxArtifactBytes
        )

        let elapsedMS = max(1, Int(Date().timeIntervalSince(startedAt) * 1000))
        let totalPoints = cappedVectors.reduce(0) { partial, vector in
            partial + vector.data.count
        }

        let summary = "Simulated netlist and extracted \(cappedVectors.count) vector(s)."
        let result = ToolExecutionResult(
            status: "ok",
            solver: "ngspice_shared",
            summary: Self.cappedSummary(summary, limit: context.limits.maxSummaryCharacters),
            stdout: Self.capLog(native.stdoutLog, maxBytes: context.limits.maxStdoutBytes),
            stderr: Self.capLog(native.stderrLog, maxBytes: context.limits.maxStderrBytes),
            exitCode: 0,
            artifacts: [artifact],
            metrics: [
                "elapsed_ms": .number(Double(elapsedMS)),
                "job_id": .string(context.jobID),
                "vector_count": .number(Double(cappedVectors.count)),
                "total_points": .number(Double(totalPoints)),
                "simulation_relpath": .string("simulation/vectors.json")
            ],
            output: .object([
                "simulation_path": .string("simulation/vectors.json"),
                "vector_file": .string(artifact.path),
                "vectors": .object(vectorMap)
            ])
        )

        return try result.asJSONValue()
    }

    public static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "netlist_path": .object([
                "type": .string("string"),
                "description": .string("Path to a .cir/.sp netlist file. Relative paths resolve from server workspace.")
            ]),
            "target_vectors": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("string")
                ]),
                "description": .string("Optional list of vectors to extract (e.g. time, v(out), i(r1)).")
            ])
        ]),
        "required": .stringArray(["netlist_path"]),
        "additionalProperties": .bool(false)
    ])

    public static let defaultInvoker: NgspiceFFIInvoker = { netlistPath, targetVectors in
        guard let symbols = NgspiceFFILoader.shared else {
            throw AutoSageError(
                code: "solver_not_installed",
                message: "ngspice_ffi dynamic library not found.",
                details: [
                    "hint": .string("Build Native/ngspice_ffi and set AUTOSAGE_NGSPICE_FFI_LIB to libngspice_ffi.dylib.")
                ]
            )
        }

        var duplicatedVectors: [UnsafeMutablePointer<CChar>] = []
        duplicatedVectors.reserveCapacity(targetVectors.count)
        for vector in targetVectors {
            guard let pointer = strdup(vector) else {
                throw AutoSageError(code: "internal_error", message: "Failed to allocate C string for target vector.")
            }
            duplicatedVectors.append(pointer)
        }
        defer {
            duplicatedVectors.forEach { free($0) }
        }

        var cVectorPointers: [UnsafePointer<CChar>?] = duplicatedVectors.map { UnsafePointer($0) }

        return try netlistPath.withCString { cNetlistPath in
            let resultPtr = cVectorPointers.withUnsafeBufferPointer { pointerBuffer in
                symbols.ngspiceRunNetlist(
                    cNetlistPath,
                    pointerBuffer.baseAddress,
                    Int32(targetVectors.count)
                )
            }

            guard let resultPtr else {
                throw AutoSageError(code: "solver_failed", message: "ngspice_run_netlist returned null.")
            }
            defer {
                symbols.ngspiceFreeResult(resultPtr)
            }

            let native = resultPtr.pointee
            let message = native.error_message.map { String(cString: $0) }
            let stdoutLog = native.stdout_log.map { String(cString: $0) } ?? ""
            let stderrLog = native.stderr_log.map { String(cString: $0) } ?? ""

            let vectorCount = max(0, Int(native.vector_count))
            var vectors: [NgspiceNativeVector] = []
            vectors.reserveCapacity(vectorCount)

            if let vectorPointer = native.vectors, vectorCount > 0 {
                for index in 0..<vectorCount {
                    let item = vectorPointer[index]
                    let name = item.name.map { String(cString: $0) } ?? "vector_\(index)"
                    let length = max(0, Int(item.length))
                    let data: [Double]
                    if let values = item.data, length > 0 {
                        data = Array(UnsafeBufferPointer(start: values, count: length))
                    } else {
                        data = []
                    }
                    vectors.append(NgspiceNativeVector(name: name, data: data))
                }
            }

            return NgspiceNativeResult(
                vectors: vectors,
                errorCode: Int32(native.error_code),
                errorMessage: message,
                stdoutLog: stdoutLog,
                stderrLog: stderrLog
            )
        }
    }

    private static func decodeInput(_ input: JSONValue?) throws -> CircuitSimulateNgspiceInput {
        guard let input else {
            throw AutoSageError(code: "invalid_input", message: "circuit_simulate_ngspice requires an input object.")
        }
        guard case .object = input else {
            throw AutoSageError(code: "invalid_input", message: "circuit_simulate_ngspice input must be an object.")
        }

        let data = try JSONCoding.makeEncoder().encode(input)
        let decoded = try JSONCoding.makeDecoder().decode(CircuitSimulateNgspiceInput.self, from: data)
        let trimmedPath = decoded.netlistPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw AutoSageError(code: "invalid_input", message: "netlist_path must be a non-empty string.")
        }

        return CircuitSimulateNgspiceInput(netlistPath: trimmedPath, targetVectors: decoded.targetVectors)
    }

    private static func normalizeTargetVectors(_ vectors: [String]?) throws -> [String] {
        let source = vectors ?? ["time"]
        var normalized: [String] = []
        normalized.reserveCapacity(source.count)

        for value in source {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw AutoSageError(code: "invalid_input", message: "target_vectors entries must be non-empty strings.")
            }
            if !normalized.contains(trimmed) {
                normalized.append(trimmed)
            }
        }

        if normalized.count > 256 {
            throw AutoSageError(code: "invalid_input", message: "target_vectors may contain at most 256 entries.")
        }

        return normalized
    }

    private static func resolveNetlistURL(_ path: String, context: ToolExecutionContext) throws -> URL {
        let netlistURL = URL(fileURLWithPath: path)
        if netlistURL.path.hasPrefix("/") {
            return netlistURL.standardizedFileURL
        }

        let cwdURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let candidateFromCWD = cwdURL.appendingPathComponent(path).standardizedFileURL
        if FileManager.default.fileExists(atPath: candidateFromCWD.path) {
            return candidateFromCWD
        }

        let candidateFromJob = context.jobDirectoryURL.appendingPathComponent(path).standardizedFileURL
        if FileManager.default.fileExists(atPath: candidateFromJob.path) {
            return candidateFromJob
        }

        return candidateFromCWD
    }

    private static func mapNativeError(_ result: NgspiceNativeResult) -> AutoSageError {
        let message = result.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (message?.isEmpty == false) ? message! : "ngspice shared simulation failed."

        let details: [String: JSONValue] = [
            "ngspice_error_code": .number(Double(result.errorCode)),
            "stdout_tail": .string(lastCharacters(result.stdoutLog, maxCharacters: 2000)),
            "stderr_tail": .string(lastCharacters(result.stderrLog, maxCharacters: 2000))
        ]

        switch result.errorCode {
        case 1:
            return AutoSageError(code: "invalid_input", message: normalized, details: details)
        case 2:
            return AutoSageError(code: "solver_not_installed", message: normalized, details: details)
        case 4:
            return AutoSageError(code: "invalid_input", message: normalized, details: details)
        default:
            return AutoSageError(code: "solver_failed", message: normalized, details: details)
        }
    }

    private static func makeArtifact(fileURL: URL, jobID: String, maxArtifactBytes: Int) throws -> ToolArtifact {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let bytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
        if bytes > maxArtifactBytes {
            throw AutoSageError(
                code: "artifact_too_large",
                message: "Generated artifact exceeds max artifact size.",
                details: [
                    "artifact": .string(fileURL.lastPathComponent),
                    "bytes": .number(Double(bytes)),
                    "max_artifact_bytes": .number(Double(maxArtifactBytes))
                ]
            )
        }

        let name = fileURL.lastPathComponent
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        return ToolArtifact(
            name: name,
            path: "/v1/jobs/\(jobID)/artifacts/\(encodedName)",
            mimeType: "application/json",
            bytes: bytes
        )
    }

    private static func capSeries(_ values: [Double], maxPoints: Int) -> [Double] {
        guard values.count > maxPoints else {
            return values
        }
        guard maxPoints > 1 else {
            return [values.first ?? 0.0]
        }

        let step = Double(values.count - 1) / Double(maxPoints - 1)
        var output: [Double] = []
        output.reserveCapacity(maxPoints)

        var previousIndex = -1
        for index in 0..<maxPoints {
            let mapped = Int((Double(index) * step).rounded())
            let clamped = min(max(mapped, 0), values.count - 1)
            if clamped != previousIndex {
                output.append(values[clamped])
                previousIndex = clamped
            }
        }

        return output
    }

    private static func capLog(_ value: String, maxBytes: Int) -> String {
        let data = Data(value.utf8)
        guard data.count > maxBytes else {
            return value
        }
        let prefix = data.prefix(max(0, maxBytes))
        let text = String(data: prefix, encoding: .utf8) ?? ""
        return text + "\n[truncated]"
    }

    private static func cappedSummary(_ summary: String, limit: Int) -> String {
        guard summary.count > limit else { return summary }
        return String(summary.prefix(max(3, limit - 3))) + "..."
    }

    private static func lastCharacters(_ value: String, maxCharacters: Int) -> String {
        guard value.count > maxCharacters else {
            return value
        }
        return String(value.suffix(maxCharacters))
    }
}

private struct NgspiceFFISymbols {
    let handle: UnsafeMutableRawPointer
    let ngspiceRunNetlist: @convention(c) (
        UnsafePointer<CChar>?,
        UnsafePointer<UnsafePointer<CChar>?>?,
        Int32
    ) -> UnsafeMutablePointer<NgspiceResult>?
    let ngspiceFreeResult: @convention(c) (UnsafeMutablePointer<NgspiceResult>?) -> Void
}

private enum NgspiceFFILoader {
    static let shared: NgspiceFFISymbols? = load()

    private static func load() -> NgspiceFFISymbols? {
        var candidates: [String] = []
        if let configured = ProcessInfo.processInfo.environment["AUTOSAGE_NGSPICE_FFI_LIB"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            candidates.append(configured)
        }

        let cwd = FileManager.default.currentDirectoryPath
        candidates.append(contentsOf: [
            "\(cwd)/Native/ngspice_ffi/build/libngspice_ffi.dylib",
            "/opt/homebrew/lib/libngspice_ffi.dylib",
            "/usr/local/lib/libngspice_ffi.dylib",
            "libngspice_ffi.dylib"
        ])

        for path in candidates {
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
                continue
            }

            guard let runSymbol = dlsym(handle, "ngspice_run_netlist"),
                  let freeSymbol = dlsym(handle, "ngspice_free_result") else {
                dlclose(handle)
                continue
            }

            let run = unsafeBitCast(
                runSymbol,
                to: (@convention(c) (
                    UnsafePointer<CChar>?,
                    UnsafePointer<UnsafePointer<CChar>?>?,
                    Int32
                ) -> UnsafeMutablePointer<NgspiceResult>?).self
            )
            let free = unsafeBitCast(
                freeSymbol,
                to: (@convention(c) (UnsafeMutablePointer<NgspiceResult>?) -> Void).self
            )

            return NgspiceFFISymbols(handle: handle, ngspiceRunNetlist: run, ngspiceFreeResult: free)
        }

        return nil
    }
}
