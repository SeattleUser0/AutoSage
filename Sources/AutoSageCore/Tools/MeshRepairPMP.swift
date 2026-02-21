// SPDX-License-Identifier: MIT
// AutoSage mesh repair tool backed by PMP C FFI.

import Foundation
import CPMPFFI
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
#error("Unsupported C standard library")
#endif

private struct MeshRepairPMPInput: Codable, Equatable, Sendable {
    let inputPath: String
    let targetDecimationFaces: Int?
    let fillHoles: Bool?
    let resolveIntersections: Bool?

    enum CodingKeys: String, CodingKey {
        case inputPath = "input_path"
        case targetDecimationFaces = "target_decimation_faces"
        case fillHoles = "fill_holes"
        case resolveIntersections = "resolve_intersections"
    }
}

public struct MeshRepairPMPDefectReport: Equatable, Sendable {
    public let initialHoles: Int
    public let initialNonManifoldEdges: Int
    public let initialDegenerateFaces: Int
    public let unresolvedErrors: Int

    public init(
        initialHoles: Int,
        initialNonManifoldEdges: Int,
        initialDegenerateFaces: Int,
        unresolvedErrors: Int
    ) {
        self.initialHoles = initialHoles
        self.initialNonManifoldEdges = initialNonManifoldEdges
        self.initialDegenerateFaces = initialDegenerateFaces
        self.unresolvedErrors = unresolvedErrors
    }

    public var asJSONValue: JSONValue {
        .object([
            "initial_holes": .number(Double(initialHoles)),
            "initial_non_manifold_edges": .number(Double(initialNonManifoldEdges)),
            "initial_degenerate_faces": .number(Double(initialDegenerateFaces)),
            "unresolved_errors": .number(Double(unresolvedErrors))
        ])
    }
}

public struct MeshRepairPMPNativeResult: Equatable, Sendable {
    public let report: MeshRepairPMPDefectReport
    public let errorCode: Int32
    public let errorMessage: String?

    public init(report: MeshRepairPMPDefectReport, errorCode: Int32, errorMessage: String?) {
        self.report = report
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }
}

public typealias MeshRepairPMPInvoker = @Sendable (
    _ inputPath: String,
    _ repairedOutputPath: String,
    _ decimatedOutputPath: String,
    _ targetDecimationFaces: Int32,
    _ fillHoles: Bool,
    _ resolveIntersections: Bool
) throws -> MeshRepairPMPNativeResult

public struct MeshRepairPMPTool: Tool {
    public let name: String = "mesh_repair_pmp"
    public let version: String
    public let description: String
    public let jsonSchema: JSONValue = MeshRepairPMPTool.schema

    private let invoker: MeshRepairPMPInvoker

    public init(
        version: String = "0.1.0",
        description: String = "Repairs triangle meshes with PMP, including optional hole filling and decimation.",
        invoker: @escaping MeshRepairPMPInvoker = MeshRepairPMPTool.defaultInvoker
    ) {
        self.version = version
        self.description = description
        self.invoker = invoker
    }

    public func run(input: JSONValue?, context: ToolExecutionContext) throws -> JSONValue {
        let startedAt = Date()
        let decoded = try Self.decodeInput(input)

        let inputURL = URL(fileURLWithPath: decoded.inputPath)
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw AutoSageError(
                code: "invalid_input",
                message: "input_path does not exist.",
                details: ["input_path": .string(inputURL.path)]
            )
        }

        let targetFaces = decoded.targetDecimationFaces ?? 10_000
        guard targetFaces > 0 else {
            throw AutoSageError(
                code: "invalid_input",
                message: "target_decimation_faces must be > 0."
            )
        }

        let fillHoles = decoded.fillHoles ?? true
        let resolveIntersections = decoded.resolveIntersections ?? false

        try FileManager.default.createDirectory(
            at: context.jobDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let outputExtension = Self.preferredOutputExtension(for: inputURL)
        let repairedURL = context.jobDirectoryURL.appendingPathComponent("repaired_mesh.\(outputExtension)")
        let decimatedURL = context.jobDirectoryURL.appendingPathComponent("decimated_mesh.\(outputExtension)")

        let nativeResult = try invoker(
            inputURL.path,
            repairedURL.path,
            decimatedURL.path,
            Int32(targetFaces),
            fillHoles,
            resolveIntersections
        )

        if nativeResult.errorCode != Int32(PMP_SUCCESS.rawValue) {
            throw Self.mapNativeError(nativeResult)
        }

        guard FileManager.default.fileExists(atPath: repairedURL.path) else {
            throw AutoSageError(
                code: "ERR_MESH_PROCESSING_FAILED",
                message: "PMP processing did not produce repaired output file.",
                details: ["expected_path": .string(repairedURL.path)]
            )
        }

        guard FileManager.default.fileExists(atPath: decimatedURL.path) else {
            throw AutoSageError(
                code: "ERR_MESH_PROCESSING_FAILED",
                message: "PMP processing did not produce decimated output file.",
                details: ["expected_path": .string(decimatedURL.path)]
            )
        }

        let repairedArtifact = try Self.makeArtifact(
            for: repairedURL,
            jobID: context.jobID,
            maxArtifactBytes: context.limits.maxArtifactBytes
        )
        let decimatedArtifact = try Self.makeArtifact(
            for: decimatedURL,
            jobID: context.jobID,
            maxArtifactBytes: context.limits.maxArtifactBytes
        )

        let report = nativeResult.report
        let summary = "Repaired mesh with \(report.initialHoles) hole(s) and \(report.initialNonManifoldEdges) non-manifold edge issue(s)."
        let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)

        let outputPayload: JSONValue = .object([
            "repaired_file": .string(repairedArtifact.name),
            "decimated_file": .string(decimatedArtifact.name),
            "defect_report": report.asJSONValue
        ])

        let result = ToolExecutionResult(
            status: "ok",
            solver: "pmp",
            summary: Self.cappedSummary(summary, limit: context.limits.maxSummaryCharacters),
            stdout: "",
            stderr: "",
            exitCode: 0,
            artifacts: [repairedArtifact, decimatedArtifact],
            metrics: [
                "elapsed_ms": .number(Double(max(0, elapsedMS))),
                "job_id": .string(context.jobID),
                "initial_holes": .number(Double(report.initialHoles)),
                "initial_non_manifold_edges": .number(Double(report.initialNonManifoldEdges)),
                "initial_degenerate_faces": .number(Double(report.initialDegenerateFaces)),
                "unresolved_errors": .number(Double(report.unresolvedErrors))
            ],
            output: outputPayload
        )
        return try result.asJSONValue()
    }

    public static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "input_path": .object([
                "type": .string("string"),
                "description": .string("Path to an input mesh file readable by PMP.")
            ]),
            "target_decimation_faces": .object([
                "type": .string("integer"),
                "description": .string("Target face budget for decimated output.")
            ]),
            "fill_holes": .object([
                "type": .string("boolean"),
                "description": .string("Whether to run hole filling before decimation.")
            ]),
            "resolve_intersections": .object([
                "type": .string("boolean"),
                "description": .string("Whether to attempt topology cleanup for non-manifold geometry.")
            ])
        ]),
        "required": .stringArray(["input_path"]),
        "additionalProperties": .bool(false)
    ])

    public static let defaultInvoker: MeshRepairPMPInvoker = {
        inputPath,
        repairedOutputPath,
        decimatedOutputPath,
        targetDecimationFaces,
        fillHoles,
        resolveIntersections in

        guard let symbols = PMPLoader.shared else {
            throw AutoSageError(
                code: "ERR_MESH_PROCESSING_FAILED",
                message: "pmp_ffi dynamic library not found.",
                details: [
                    "hint": .string("Build Native/pmp_ffi and set AUTOSAGE_PMP_FFI_LIB to libpmp_ffi.dylib.")
                ]
            )
        }

        return try inputPath.withCString { cInputPath in
            try repairedOutputPath.withCString { cRepairedOutputPath in
                try decimatedOutputPath.withCString { cDecimatedOutputPath in
                    guard let resultPointer = symbols.pmpProcessMesh(
                        cInputPath,
                        cRepairedOutputPath,
                        cDecimatedOutputPath,
                        targetDecimationFaces,
                        fillHoles ? 1 : 0,
                        resolveIntersections ? 1 : 0
                    ) else {
                        throw AutoSageError(
                            code: "ERR_MESH_PROCESSING_FAILED",
                            message: "pmp_process_mesh returned null."
                        )
                    }

                    defer {
                        symbols.pmpFreeResult(resultPointer)
                    }

                    let result = resultPointer.pointee
                    let report = MeshRepairPMPDefectReport(
                        initialHoles: Int(result.report.initial_holes),
                        initialNonManifoldEdges: Int(result.report.initial_non_manifold_edges),
                        initialDegenerateFaces: Int(result.report.initial_degenerate_faces),
                        unresolvedErrors: Int(result.report.unresolved_errors)
                    )
                    let message = result.error_message.map { String(cString: $0) }

                    return MeshRepairPMPNativeResult(
                        report: report,
                        errorCode: Int32(result.error_code),
                        errorMessage: message
                    )
                }
            }
        }
    }

    private static func decodeInput(_ input: JSONValue?) throws -> MeshRepairPMPInput {
        guard let input else {
            throw AutoSageError(code: "invalid_input", message: "mesh_repair_pmp requires an input object.")
        }
        guard case .object = input else {
            throw AutoSageError(code: "invalid_input", message: "mesh_repair_pmp input must be an object.")
        }

        let data = try JSONCoding.makeEncoder().encode(input)
        let decoded = try JSONCoding.makeDecoder().decode(MeshRepairPMPInput.self, from: data)
        let trimmedPath = decoded.inputPath.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedPath.isEmpty else {
            throw AutoSageError(code: "invalid_input", message: "input_path must be a non-empty string.")
        }

        return MeshRepairPMPInput(
            inputPath: trimmedPath,
            targetDecimationFaces: decoded.targetDecimationFaces,
            fillHoles: decoded.fillHoles,
            resolveIntersections: decoded.resolveIntersections
        )
    }

    private static func mapNativeError(_ result: MeshRepairPMPNativeResult) -> AutoSageError {
        let message = result.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMessage = (message?.isEmpty == false) ? message! : "PMP mesh processing failed."

        let details: [String: JSONValue] = [
            "pmp_error_code": .number(Double(result.errorCode)),
            "defect_report": result.report.asJSONValue
        ]

        if result.report.unresolvedErrors > 0 || result.errorCode == Int32(PMP_ERR_NON_MANIFOLD_UNRESOLVABLE.rawValue) {
            return AutoSageError(
                code: "ERR_NON_MANIFOLD_UNRESOLVABLE",
                message: normalizedMessage,
                details: details
            )
        }

        if result.errorCode == Int32(PMP_ERR_HOLE_FILL_FAILED.rawValue) || normalizedMessage.lowercased().contains("hole") {
            return AutoSageError(
                code: "ERR_HOLE_TOO_LARGE",
                message: normalizedMessage,
                details: details
            )
        }

        if result.errorCode == Int32(PMP_ERR_INVALID_ARGUMENT.rawValue) {
            return AutoSageError(code: "invalid_input", message: normalizedMessage, details: details)
        }

        return AutoSageError(
            code: "ERR_MESH_PROCESSING_FAILED",
            message: normalizedMessage,
            details: details
        )
    }

    private static func preferredOutputExtension(for inputURL: URL) -> String {
        let extensionLower = inputURL.pathExtension.lowercased()
        if extensionLower.isEmpty {
            return "obj"
        }
        return extensionLower
    }

    private static func makeArtifact(for url: URL, jobID: String, maxArtifactBytes: Int) throws -> ToolArtifact {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
        if bytes > maxArtifactBytes {
            throw AutoSageError(
                code: "artifact_too_large",
                message: "Generated artifact exceeds max artifact size.",
                details: [
                    "artifact": .string(url.lastPathComponent),
                    "bytes": .number(Double(bytes)),
                    "max_artifact_bytes": .number(Double(maxArtifactBytes))
                ]
            )
        }

        let encodedName = url.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.lastPathComponent
        return ToolArtifact(
            name: url.lastPathComponent,
            path: "/v1/jobs/\(jobID)/artifacts/\(encodedName)",
            mimeType: mimeType(forExtension: url.pathExtension),
            bytes: bytes
        )
    }

    private static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "obj":
            return "text/plain; charset=utf-8"
        case "off":
            return "application/octet-stream"
        case "stl":
            return "model/stl"
        case "ply":
            return "application/octet-stream"
        default:
            return "application/octet-stream"
        }
    }

    private static func cappedSummary(_ summary: String, limit: Int) -> String {
        guard summary.count > limit else { return summary }
        return String(summary.prefix(max(3, limit - 3))) + "..."
    }
}

private struct PMPSymbols {
    let handle: UnsafeMutableRawPointer
    let pmpProcessMesh: @convention(c) (
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        Int32,
        Int32,
        Int32
    ) -> UnsafeMutablePointer<PmpResult>?
    let pmpFreeResult: @convention(c) (UnsafeMutablePointer<PmpResult>?) -> Void
}

private enum PMPLoader {
    static let shared: PMPSymbols? = load()

    private static func load() -> PMPSymbols? {
        var candidates: [String] = []
        if let configured = ProcessInfo.processInfo.environment["AUTOSAGE_PMP_FFI_LIB"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            candidates.append(configured)
        }

        let cwd = FileManager.default.currentDirectoryPath
        candidates.append(contentsOf: [
            "\(cwd)/Native/pmp_ffi/build/libpmp_ffi.dylib",
            "/opt/homebrew/lib/libpmp_ffi.dylib",
            "/usr/local/lib/libpmp_ffi.dylib",
            "libpmp_ffi.dylib"
        ])

        for path in candidates {
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
                continue
            }

            guard let processSymbol = dlsym(handle, "pmp_process_mesh"),
                  let freeSymbol = dlsym(handle, "pmp_free_result") else {
                dlclose(handle)
                continue
            }

            let process = unsafeBitCast(
                processSymbol,
                to: (@convention(c) (
                    UnsafePointer<CChar>?,
                    UnsafePointer<CChar>?,
                    UnsafePointer<CChar>?,
                    Int32,
                    Int32,
                    Int32
                ) -> UnsafeMutablePointer<PmpResult>?).self
            )
            let free = unsafeBitCast(
                freeSymbol,
                to: (@convention(c) (UnsafeMutablePointer<PmpResult>?) -> Void).self
            )

            return PMPSymbols(handle: handle, pmpProcessMesh: process, pmpFreeResult: free)
        }

        return nil
    }
}
